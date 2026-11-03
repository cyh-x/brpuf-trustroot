# ps_ocm_boot.tcl — OCM 路径启动 (不依赖 DDR)
#   实测: DDR 控制器在系统复位后处于 reset, 且 OCM 高别名 0xFFFC1000 访问触发外部中止
#         => OCM 映射在低端 0x0-0x3FFFF, 直接跑到 0x0 的应用即可, 完全绕开 DDR。
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_uartfix.tcl
set bit    $root/pr_out/trustroot_uart.bit
set elf    $root/ps_app/ps_uart_ocm.elf
set BEACON 0x00020000

proc rd {a} { return [expr {"0x[lindex [mrd -force $a 1] 1]"}] }
proc wr {a v} { mwr -force -bypass-cache-sync $a 1 $v }
proc pcget {} {
    if {![catch {set v [lindex [rrd pc] 1]}]} { return [expr {"0x$v"}] }
    return 0xDEADBEEF
}

connect
set ok 0
for {set i 0} {$i < 4} {incr i} {
    if {![catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}}]} { set ok 1; break }
    catch {targets 1; rst}; after 2500
}
if {!$ok} { puts ">> SEL_FAIL"; exit 1 }
puts ">> TARGET_OK"

catch { rst -processor }; after 400
catch { stop }; after 200
puts ">> DIAG PC_core_rst = [format 0x%08X [pcget]]"

# --- ps7_init: PLL/时钟/MIO/外设 (跳过 DDR) ---
uplevel #0 [list source $ps7tcl]
foreach p {ps7_pll_init_data_3_0 ps7_clock_init_data_3_0 ps7_mio_init_data_3_0 ps7_peripherals_init_data_3_0} {
    if {[catch {$p} e]} { puts ">> $p FAIL: $e"; exit 1 }
    puts ">> $p OK"
}

# --- OCM 读写验证 (0x00020000 信标区) ---
if {[catch {
    wr 0x00020000 0x13572468
    set v [rd 0x00020000]
    puts ">> DIAG OCM rw = 0x[format %08X $v]"
    if {$v != 0x13572468} { puts ">> OCM_BROKEN"; exit 1 }
} e]} { puts ">> OCM access error: $e"; exit 1 }
puts ">> OCM_OK"
puts ">> DIAG UART cr=0x[format %08X [rd 0xE0001000]] baud=0x[format %08X [rd 0xE0001018]] sr=0x[format %08X [rd 0xE000102C]]"

# --- 位流 + level shifter ---
targets -set -filter {name =~ "*xc7z020*"}
fpga $bit; after 1000
puts ">> FPGA_LOADED"
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
if {[catch { ps7_post_config } e]} { puts ">> post_config: $e" } else { puts ">> ps7_post_config OK" }

# --- 加载应用到 OCM ---
catch { rst -processor }; after 400
catch { stop }; after 200
if {[catch {dow -force -bypass-cache-sync $elf} e]} { puts ">> DOW_FAIL $e"; exit 1 }
puts ">> DIAG after dow PC = [format 0x%08X [pcget]] (expect 0x00000020)"
puts ">> DIAG OCM@0 = 0x[format %08X [rd 0x00000000]]  OCM@0x20 = 0x[format %08X [rd 0x00000020]] (应 0xE10F0000)"

con
after 2000
catch { stop }; after 200
puts ">> RUN PC = [format 0x%08X [pcget]]"
catch { puts ">> RUN beacon=[format 0x%08X [rd $BEACON]] hb=[format 0x%08X [rd [expr {$BEACON+4}]]] cr=[format 0x%08X [rd [expr {$BEACON+8}]]] pufver=[format 0x%08X [rd [expr {$BEACON+24}]]]" }
catch { puts ">> RUN UART cr=0x[format %08X [rd 0xE0001000]] mr=0x[format %08X [rd 0xE0001004]] baud=0x[format %08X [rd 0xE0001018]] sr=0x[format %08X [rd 0xE000102C]]" }
catch { con }
puts ">> RUNNING"
exit
