connect
puts ">> T0"
foreach t [targets] { puts ">>   [string trim $t]" }
if {[catch {targets -set -filter {name =~ "*APU*" || name =~ "*DAP*"}} e]} { puts ">> SEL: $e" }
if {[catch {rst -system} e]} { puts ">> RST_SYS: $e" } else { puts ">> rst -system OK" }
after 1500
puts ">> T1"
foreach t [targets] { puts ">>   [string trim $t]" }
exit
