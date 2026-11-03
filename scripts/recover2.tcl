connect
puts ">> T"
foreach t [targets] { puts ">>   [string trim $t]" }
if {[catch {targets -set -filter {name =~ "*JTAG2AXI*"}} e]} { puts ">> J2A_FAIL: $e" } else { puts ">> JTAG2AXI selected" }
if {[catch {mrd -force 0x40000000} r]} { puts ">> VER_FAIL: $r" } else { puts ">> VERSION = $r" }
exit
