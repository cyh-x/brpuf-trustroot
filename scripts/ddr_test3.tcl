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
# 用一个全新区域, 写 8 个递增 magic, 再整体回读
set base 0x0E000000
puts ">> 写 8 拍到 [format 0x%08X $base]"
wr $base 0x11111111
wr [expr {$base+4}] 0x22222222
wr [expr {$base+8}] 0x33333333
puts ">> 首读:"
puts ">>   A+0 = [format 0x%08X [rd $base]]"
puts ">> 重写 A 再读:"
wr $base 0x44444444
after 20
puts ">>   A+0 = [format 0x%08X [rd $base]]  (expect 0x44444444)"
puts ">> 逐笔写读校验 8 笔:"
for {set i 0} {$i < 8} {incr i} {
    set aa [expr {$base + 0x100 + $i*4}]
    wr $aa [expr {0x77000000 + $i}]
    after 5
    set back [rd $aa]
    if {$back != (0x77000000+$i)} { after 10; set back [rd $aa] }
    puts ">>   [$i] exp=[format 0x%08X [expr {0x77000000+$i}]] got=[format 0x%08X $back] [expr {$back==(0x77000000+$i)?{OK}:{BAD}}]"
}

exit
