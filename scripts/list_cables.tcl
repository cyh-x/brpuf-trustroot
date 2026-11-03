# list_cables.tcl — 枚举当前连接的 JTAG 线缆与目标
connect
puts ">> JTAG CABLES:"
foreach c [jtag targets] {
    puts ">>   [string trim $c]"
}
puts ">> TARGETS:"
foreach t [targets] {
    puts ">>   [string trim $t]"
}
exit
