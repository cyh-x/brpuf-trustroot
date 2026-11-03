set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_gp0.tcl
set bit $root/pr_out/trustroot_ax7020.bit
set elf $root/ps_app/ps_app.elf
set cab [lindex $argv 0]
connect
proc sel_ok {pat cab} { return [expr {![catch {targets -set -filter "name =~ \"$pat\" && jtag_cable_name =~ \"*$cab*\""}]}] }
set ok 0
for {set i 0} {$i < 4} {incr i} {
    if {[sel_ok "*Cortex-A9 MPCore #0*" $cab]} { set ok 1; break }
    catch {targets -set -filter {name =~ "*DAP*"}}
    catch {rst -system}
    after 1200
}
if {!$ok} { puts ">> DAP_UNRECOVERED"; exit 1 }
catch { rst -processor }; catch { stop }; after 300
uplevel #0 [list source $ps7tcl]; catch { ps7_init }; catch { ps7_post_config }
targets -set -filter "name =~ \"*xc7z020*\" && jtag_cable_name =~ \"*$cab*\""
fpga $bit; after 800
targets -set -filter "name =~ \"*Cortex-A9 MPCore #0*\" && jtag_cable_name =~ \"*$cab*\""
catch { stop }
dow -force $elf
puts ">> APP_LOADED"
if {[catch {set pcv $pc} e]} { puts ">> (pc var n/a)" } else { puts ">> PC=[format 0x%08X $pcv]" }
after 200
con
puts ">> APP_RUNNING"
exit
