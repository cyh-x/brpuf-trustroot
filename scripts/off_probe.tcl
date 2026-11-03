set cab [lindex $argv 0]
connect
targets -set -filter "name =~ \"*JTAG2AXI*\" && jtag_cable_name =~ \"*$cab*\""
proc rd {a} { return [expr {"0x[lindex [mrd -force $a] 1]"}] }
proc wr {a v} { mwr -force $a $v }
set B 0x1E000200
wr $B 0xCAFED00D
wr $B 0xCAFED00D
after 30
puts ">> 写入 0xCAFED00D 于 [format 0x%08X $B]"
foreach off {-8 -4 0 4 8} {
    puts ">>   rd B[format %+d $off] = [format 0x%08X [rd [expr {$B+$off}]]]"
}
exit
