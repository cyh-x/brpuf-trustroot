set cab [lindex $argv 0]
connect
targets -set -filter "name =~ \"*JTAG2AXI*\" && jtag_cable_name =~ \"*$cab*\""
proc rd {a} { return [expr {"0x[lindex [mrd -force $a] 1]"}] }
proc wr {a v} { mwr -force $a $v }
set MB 0x1F000000
puts ">> RSP[0] = [format 0x%08X [rd [expr {$MB+16}]]]  (expect 0x00000100 = PS 就绪)"
# PING (cmd=1), 首笔写两遍
wr $MB 0xA5A50001
after 20
wr $MB 0xA5A50001
wr [expr {$MB+4}] 1
after 500
puts ">> PING rsp: st=[format 0x%08X [rd [expr {$MB+16}]]] tag=[format 0x%08X [rd [expr {$MB+20}]]] PUF=[format 0x%08X [rd [expr {$MB+24}]]] AES=[format 0x%08X [rd [expr {$MB+28}]]] TRNG=[format 0x%08X [rd [expr {$MB+32}]]] mark=[format 0x%08X [rd [expr {$MB+48}]]]"
puts ">> MB[0] = [format 0x%08X [rd $MB]] (expect 0 = 已消费)"
# TRNG (cmd=3)
wr $MB 0xA5A50003
wr [expr {$MB+4}] 3
after 1500
puts ">> TRNG key: [format 0x%08X [rd [expr {$MB+16}]]] [format 0x%08X [rd [expr {$MB+20}]]] [format 0x%08X [rd [expr {$MB+24}]]] [format 0x%08X [rd [expr {$MB+28}]]]"
exit
