connect
puts ">> TARGETS:"
foreach t [targets] { puts ">>   [string trim $t]" }
puts ">> try select A9"
if {[catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}} e]} { puts ">> SEL_FAIL: $e" } else { puts ">> A9 selected" }
if {[catch {stop} e]} { puts ">> STOP_FAIL: $e" } else { puts ">> stopped" }
after 300
if {[catch {mrd -force 0xF8007080} r]} { puts ">> MRD_FAIL: $r" } else { puts ">> SLCR = $r" }
exit
