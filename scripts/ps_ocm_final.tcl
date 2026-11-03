# OCM 应用最终启动: dow 后手动设置 PC 到入口并启动 (rst -processor 不再执行)
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_uartfix.tcl
set bit $root/pr_out/trustroot_uart.bit
set elf $root/ps_app/ps_uart_ocm.elf
proc rd {a} { return [expr {"0x[lindex [mrd -force $a 1] 1]"}] }
proc wr {a v} { mwr -force $a 1 $v }
connect
set ok 0
for {set i 0} {$i < 8} {incr i} {
    if {![catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}}]} { set ok 1; break }
    if {![catch {targets 1}]} { catch { rst -system }; after 500; catch { rst -system } }
    after 2500
}
if {!$ok} { puts ">> DAP_DEAD"; exit 1 }
catch { rst -processor }; catch { stop }; after 300
uplevel #0 [list source $ps7tcl]
if {[catch { ps7_init } e]} { puts ">> PS7_FAIL $e"; exit 1 }
targets -set -filter {name =~ "*xc7z020*"}
fpga $bit; after 800
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
# 不要 rst! 直接 dow (会设置 PC 到 entry)
dow -force $elf
puts ">> loaded, PC set to entry"
# 确认 PC
catch { stop }
puts ">> PC check"
con
puts ">> running"
exit
