connect
puts ">> T1"
foreach t [targets] { puts ">>   [string trim $t]" }
puts ">> try jtag targets -rescan"
if {[catch {jtag targets -rescan} e]} { puts ">> RESCAN_ERR: $e" } else { puts ">> rescan ok" }
puts ">> T2"
foreach l [split [jtag targets] "\n"] { if {[string trim $l] ne ""} { puts ">>   [string trim $l]" } }
puts ">> try fpga program blindly"
if {[catch {fpga $root/pr_out/sram_ax7020.bit} e]} { puts ">> FPGA_ERR: $e" } else { puts ">> fpga program OK" }
puts ">> T3"
foreach t [targets] { puts ">>   [string trim $t]" }
exit
