set cab [lindex $argv 0]
connect
targets -set -filter {name =~ "*JTAG2AXI*"}
set MB 0x40030000
puts ">> (T0) MB16"
set v [mrd -force [expr {$MB+64}] 1]
puts ">> MB16 = $v"
exit
