connect
puts ">> raw jtag:"
foreach l [split [jtag targets] "\n"] { if {[string trim $l] ne ""} { puts ">>  [string trim $l]" } }
puts ">> raw targets:"
foreach t [targets] { puts ">>  [string trim $t]" }
exit
