set cab [lindex $argv 0]
connect
targets -set -filter {name =~ "*JTAG2AXI*"}
set MB 0x40030000
# T0: 状态字
puts ">> T0 MB16 = [lindex [mrd -force [expr {$MB+64}] 1] 1]"
# T1: PING
mwr -force $MB 1 0xA5A50001
after 500
puts ">> T1 PING rsp=[lindex [mrd -force [expr {$MB+68}] 1] 1] st=[lindex [mrd -force [expr {$MB+64}] 1] 1] cmd=[lindex [mrd -force $MB 1] 1]"
# T3: PUF ver
mwr -force $MB 1 0xA5A50005
after 500
puts ">> T3 PUFver=[lindex [mrd -force [expr {$MB+68}] 1] 1]"
# T2: TRNG
mwr -force $MB 1 0xA5A50003
after 2000
puts ">> T2 TRNG=[lindex [mrd -force [expr {$MB+68}] 1] 1] [lindex [mrd -force [expr {$MB+72}] 1] 1]"
exit
