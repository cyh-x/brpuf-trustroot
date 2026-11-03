set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_gp0.tcl
set bit $root/pr_out/trustroot_ax7020.bit
set cab [lindex $argv 0]
connect
targets -set -filter "name =~ \"*Cortex-A9 MPCore #0*\" && jtag_cable_name =~ \"*$cab*\""
catch { rst -processor }; catch { stop }; after 200
uplevel #0 [list source $ps7tcl]; ps7_init; catch { ps7_post_config }
targets -set -filter "name =~ \"*xc7z020*\" && jtag_cable_name =~ \"*$cab*\""
fpga $bit; after 500
targets -set -filter "name =~ \"*JTAG2AXI*\" && jtag_cable_name =~ \"*$cab*\""
proc rd {a} { return [expr {"0x[lindex [mrd -force $a] 1]"}] }
proc wr {a v} { mwr -force $a $v }
puts ">> 四次独立写 + 逐笔校验"
for {set i 0} {$i < 4} {incr i} {
    wr [expr {0x00200000 + $i*4}] [expr {0xAA000000 + $i}]
    set back [rd [expr {0x00200000 + $i*4}]]
    puts ">>   write-read [format 0x%08X [expr {0xAA000000+$i}]] : back=[format 0x%08X $back]  [expr {$back==(0xAA000000+$i) ? {OK} : {MISMATCH}}]"
}
after 50
for {set i 0} {$i < 6} {incr i} {
    puts ">>   read  [format 0x%08X [expr {0x00200000 + $i*4}]] = [format 0x%08X [rd [expr {0x00200000+$i*4}]]]"
}
exit
