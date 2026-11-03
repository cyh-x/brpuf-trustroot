# board_ping.tcl — 只读活性检查, 不重烧位流
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ip_pr.gen/sources_1/ip/ps7_0/ps7_init.tcl
if {![file exists $ps7tcl]} { set ps7tcl $root/pr_out/ps7_init.tcl }
set cab "210512180081"
if {$argc >= 1} { set cab [lindex $argv 0] }
connect
targets -set -filter "name =~ \"*Cortex-A9 MPCore #0*\" && jtag_cable_name =~ \"*$cab*\""
catch { rst -processor }; catch { stop }; after 200
uplevel #0 [list source $ps7tcl]
ps7_init
catch { ps7_post_config }
targets -set -filter "name =~ \"*JTAG2AXI*\" && jtag_cable_name =~ \"*$cab*\""
if {[catch {
    set v [expr {"0x[lindex [mrd -force 0x40000000] 1]"}]
    set m [expr {"0x[lindex [mrd -force 0x40000018] 1]"}]
    puts [format ">> CABLE %s  VERSION=0x%08X  MAGIC=0x%08X  %s" $cab $v $m [expr {($v==0x00040000 && ($m & 0xFFFF0000)==0x5A5A0000) ? "ALIVE_BITSTREAM_LOADED" : "NEED_REPROGRAM"}]]
} e]} {
    puts ">> CABLE $cab  READ_FAIL: $e  (need reprogram)"
}
exit
