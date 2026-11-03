connect
puts ">> JTAG chain:"
foreach t [jtag targets] { puts ">>J [string trim $t]" }
exit
