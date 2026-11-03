connect
puts ">> AFTER CONNECT:"
foreach t [targets] { puts ">>   [string trim $t]" }
if {[catch {jtag targets} e]} { puts ">> JTAGTGT_ERR: $e" } else {
    puts ">> JTAG TARGETS:"
    foreach l [split [jtag targets] "\n"] { if {[string trim $l] ne ""} { puts ">>   [string trim $l]" } }
}
exit
