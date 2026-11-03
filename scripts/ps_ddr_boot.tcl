# ps_ddr_boot.tcl — DDR 路径启动 v14 UART 应用
#   完整 ps7_init (含 DDR) -> 位流 -> ps7_post_config -> rst -processor -> dow -> con
#   应用内埋了 DDR 信标 0x001FF000: [0]=magic 5AA5C0DE, [1]=心跳, [2..5]=UART CR/MR/BAUD/SR, [6]=PUF ver
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_uartfix.tcl
set bit    $root/pr_out/trustroot_uart.bit
set elf    $root/ps_app/ps_uart_app.elf
set BEACON 0x001FF000

proc rd {a} { return [expr {"0x[lindex [mrd -force $a 1] 1]"}] }
proc pcget {} {
    if {![catch {set v [lindex [rrd pc] 1]}]} { return [expr {"0x$v"}] }
    if {[info exists ::pc]} { return $::pc }
    return 0xDEADBEEF
}

connect
set ok 0
for {set i 0} {$i < 8} {incr i} {
    if {![catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}}]} { set ok 1; break }
    if {![catch {targets 1}]} { catch { rst -system }; after 800 }
    after 2000
}
if {!$ok} { puts ">> DAP_DEAD"; exit 1 }
puts ">> TARGET_OK"

catch { stop }; after 300
puts ">> DIAG PC_before = [format 0x%08X [pcget]]"
if {[catch {puts ">> DIAG APER=0x[format %08X [rd 0xF8000120]] DDRPHY=0x[format %08X [rd 0xF8006048]]"} e]} { puts ">> DIAG slcr read fail: $e" }

uplevel #0 [list source $ps7tcl]
foreach p {ps7_pll_init_data_3_0 ps7_clock_init_data_3_0 ps7_ddr_init_data_3_0 ps7_mio_init_data_3_0 ps7_peripherals_init_data_3_0} {
    if {[catch {$p} e]} { puts ">> $p FAIL: $e"; exit 1 }
    puts ">> $p OK"
}

# DDR 读写验证 (app 加载地址 0x00100000)
if {[catch {
    mwr -force 0x00100000 1 0x12345678
    set v [rd 0x00100000]
    puts ">> DIAG DDR rw = 0x[format %08X $v]"
    if {$v != 0x12345678} { puts ">> DDR_BROKEN"; exit 1 }
} e]} { puts ">> DDR access error: $e"; exit 1 }

targets -set -filter {name =~ "*xc7z020*"}
fpga $bit; after 1000
puts ">> FPGA loaded"
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
if {[catch { ps7_post_config } e]} { puts ">> post_config: $e" } else { puts ">> ps7_post_config OK" }
catch { rst -processor }; after 500
catch { stop }; after 200

dow -force $elf
set epc [pcget]
puts ">> DIAG after dow PC = [format 0x%08X $epc] (expect 0x00100020)"
if {$epc != 0x00100020} {
    catch { rwr pc 0x00100020 }
    puts ">> DIAG PC forced -> [format 0x%08X [pcget]]"
}

con
after 1500
catch { stop }; after 200
puts ">> RUN PC = [format 0x%08X [pcget]]"
catch { puts ">> RUN beacon=[format 0x%08X [rd $BEACON]] hb=[format 0x%08X [rd [expr {$BEACON+4}]]] pufver=[format 0x%08X [rd [expr {$BEACON+24}]]]" }
catch { puts ">> RUN UART cr=0x[format %08X [rd 0xE0001000]] mr=0x[format %08X [rd 0xE0001004]] baud=0x[format %08X [rd 0xE0001018]] sr=0x[format %08X [rd 0xE000102C]]" }
catch { con }
puts ">> RUNNING"
exit
