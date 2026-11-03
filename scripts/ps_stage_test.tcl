# 分段执行 ps7_init, 定位哪一段拉挂 DAP
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_uart.tcl
connect
set ok 0
for {set i 0} {$i < 8} {incr i} {
    if {![catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}}]} { set ok 1; break }
    if {![catch {targets 1}]} { catch { rst -system }; after 500; catch { rst -system } }
    after 2000
}
if {!$ok} { puts ">> DAP_DEAD"; exit 1 }
catch { rst -processor }; catch { stop }; after 300
uplevel #0 [list source $ps7tcl]

puts ">> [ST1] ps7_pll_init_data_3_0"
if {[catch { ps7_pll_init_data_3_0 } e]} { puts ">> FAIL: $e"; exit 1 }
puts ">> alive: [lindex [mrd -force 0xF8000120 1] 1]"

puts ">> [ST2] ps7_clock_init_data_3_0"
if {[catch { ps7_clock_init_data_3_0 } e]} { puts ">> FAIL: $e"; exit 1 }
puts ">> alive: [lindex [mrd -force 0xF8000120 1] 1]"

puts ">> [ST3] ps7_ddr_init_data_3_0"
if {[catch { ps7_ddr_init_data_3_0 } e]} { puts ">> FAIL: $e"; exit 1 }
puts ">> alive: [lindex [mrd -force 0xF8000120 1] 1]"

puts ">> [ST4] ps7_peripherals_init_data_3_0"
if {[catch { ps7_peripherals_init_data_3_0 } e]} { puts ">> FAIL: $e"; exit 1 }
puts ">> alive: [lindex [mrd -force 0xF8000120 1] 1]"
puts ">> ALL_STAGES_OK"
exit
