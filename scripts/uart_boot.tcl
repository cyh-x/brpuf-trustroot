set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_v14b.tcl
set bit $root/pr_out/trustroot_uart.bit
set elf $root/ps_app/ps_uart_app.elf
set cab [lindex $argv 0]
connect

# DAP 恢复
set ok 0
for {set i 0} {$i < 5} {incr i} {
    if {![catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}}]} { set ok 1; break }
    catch { targets 1 }
    catch { rst -system }
    after 1800
}
if {!$ok} { puts ">> DAP_DEAD"; exit 1 }

catch { rst -processor }; catch { stop }; after 300
uplevel #0 [list source $ps7tcl]
if {[catch { ps7_init } e1]} { puts ">> PS7_FAIL: $e1"; exit 1 }
catch { ps7_post_config }
puts ">> ps7_init OK (含 UART MIO 48/49)"

targets -set -filter {name =~ "*xc7z020*"}
fpga $bit
after 800
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch { rst -processor }
after 300

if {[catch { dow -force $elf } e2]} { puts ">> DOW_FAIL: $e2"; exit 1 }
puts ">> APP LOADED"
con
puts ">> APP RUNNING (UART 应有输出)"
exit
