connect
set out [jtag targets]
puts ">>RAW_BEGIN"
foreach line [split $out "\n"] { puts ">>J $line" }
puts ">>RAW_END"
exit
