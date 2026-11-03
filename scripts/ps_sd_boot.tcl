# ps_sd_boot.tcl — SD 启动模式下的应用加载 (已知可用路径)
#   前提: 拨码 = SD 启动, 卡里有能跑的 BOOT.BIN -> FSBL 已初始化 DDR/PLL
#   本脚本: JTAG 附上 -> 补 UART 时钟 -> 下载位流 -> 应用下载到 DDR 0x100000 -> 运行
#   应用内埋 DDR 信标 0x001FF000: [0]=5AA5C0DE [1]=心跳 [2..5]=UART CR/MR/BAUD/SR [6]=PUF ver
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_uartfix.tcl
set bit    $root/pr_out/trustroot_uart.bit
set elf    $root/ps_app/ps_uart_app.elf
set BEACON 0x001FF000

proc rd {a} { return [expr {"0x[lindex [mrd -force $a 1] 1]"}] }
proc wr {a v} { mwr -force -bypass-cache-sync $a 1 $v }
proc pcget {} {
    if {![catch {set v [lindex [rrd pc] 1]}]} { return [expr {"0x$v"}] }
    return 0xDEADBEEF
}

connect
set ok 0
for {set i 0} {$i < 5} {incr i} {
    if {![catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}}]} { set ok 1; break }
    catch {targets 1; rst}; after 4000
}
if {!$ok} { puts ">> SEL_FAIL"; exit 1 }
puts ">> TARGET_OK"

catch {stop}; after 300
puts ">> DIAG PC = [format 0x%08X [pcget]]"
if {[catch {puts ">> DIAG APER=0x[format %08X [rd 0xF8000120]]"} e]} { puts ">> DIAG slcr: $e" }

# --- 补时钟/MIO/UART (跳过 DDR: FSBL 已初始化) ---
uplevel #0 [list source $ps7tcl]
foreach p {ps7_pll_init_data_3_0 ps7_clock_init_data_3_0 ps7_mio_init_data_3_0 ps7_peripherals_init_data_3_0} {
    if {[catch {$p} e]} { puts ">> $p FAIL: $e"; exit 1 }
    puts ">> $p OK"
}

# --- DDR 可用性 (FSBL 已配好) ---
if {[catch {
    wr 0x00100000 0x12345678
    set v [rd 0x00100000]
    puts ">> DIAG DDR rw = 0x[format %08X $v]"
    if {$v != 0x12345678} { puts ">> DDR_BROKEN"; exit 1 }
} e]} { puts ">> DDR error: $e"; exit 1 }
puts ">> DDR_OK"
puts ">> DIAG UART cr=0x[format %08X [rd 0xE0001000]] baud=0x[format %08X [rd 0xE0001018]] sr=0x[format %08X [rd 0xE000102C]]"

# --- 位流 ---
targets -set -filter {name =~ "*xc7z020*"}
fpga $bit; after 1000
puts ">> FPGA_LOADED"
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
if {[catch { ps7_post_config } e]} { puts ">> post_config: $e" } else { puts ">> ps7_post_config OK" }

# --- 应用下载到 DDR ---
catch {stop}; after 200
if {[catch {dow -force -bypass-cache-sync $elf} e]} { puts ">> DOW_FAIL $e"; exit 1 }
puts ">> DIAG after dow PC = [format 0x%08X [pcget]] (expect 0x00100020)"
puts ">> DIAG DDR@0x100000 = 0x[format %08X [rd 0x00100000]] (应 0xEAxxxxxx)"

con
after 2000
catch {stop}; after 200
puts ">> RUN PC = [format 0x%08X [pcget]]"
catch { puts ">> RUN beacon=[format 0x%08X [rd $BEACON]] hb=[format 0x%08X [rd [expr {$BEACON+4}]]] cr=[format 0x%08X [rd [expr {$BEACON+8}]]] sr=[format 0x%08X [rd [expr {$BEACON+20}]]] pufver=[format 0x%08X [rd [expr {$BEACON+24}]]]" }
catch { puts ">> RUN UART cr=0x[format %08X [rd 0xE0001000]] mr=0x[format %08X [rd 0xE0001004]] baud=0x[format %08X [rd 0xE0001018]] sr=0x[format %08X [rd 0xE000102C]]" }
catch { con }
puts ">> RUNNING"
exit
