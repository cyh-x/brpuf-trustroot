set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_gp0.tcl
set bit $root/pr_out/trustroot_ax7020.bit
set cab [lindex $argv 0]
connect
set ok 0
for {set i 0} {$i < 5} {incr i} {
    if {![catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}}]} { set ok 1; break }
    if {![catch {targets 1}]} { catch { rst -system } }
    after 1800
}
if {!$ok} { puts ">> DAP_DEAD"; exit 1 }
catch { rst -processor }; catch { stop }; after 300
uplevel #0 [list source $ps7tcl]; ps7_init; catch { ps7_post_config }
targets -set -filter "name =~ \"*xc7z020*\" && jtag_cable_name =~ \"*$cab*\""
fpga $bit; after 800
targets -set -filter "name =~ \"*JTAG2AXI*\" && jtag_cable_name =~ \"*$cab*\""
proc rd {a} { return [expr {"0x[lindex [mrd -force $a 1] 1]"}] }
proc wr {a v} { mwr -force $a 1 $v }
set X 0x0D000100
puts ">> 单笔写 V=0xCAFED00D @ [format 0x%08X $X]"
wr $X 0xCAFED00D
after 100
foreach off {-12 -8 -4 0 4 8 12} {
    set a [expr {$X + $off}]
    set v [rd $a]
    set tag [expr {$v == 0xCAFED00D ? "  <== VALUE HERE" : ""}]
    puts ">>   [format 0x%08X $a] (X[format %+d $off]) = [format 0x%08X $v]$tag"
}
exit
