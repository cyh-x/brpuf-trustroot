# last_raw_probe.tcl — 区分实验: or 版反相链 RO 的 LAST_RAW (走 diff 主通路)
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ip_pr.gen/sources_1/ip/ps7_0/ps7_init.tcl
if {![file exists $ps7tcl]} { set ps7tcl $root/pr_out/ps7_init.tcl }
set cab 210512180081
connect
targets -set -filter "name =~ \"*Cortex-A9 MPCore #0*\" && jtag_cable_name =~ \"*$cab*\""
catch { rst -processor }; catch { stop }; after 200
uplevel #0 [list source $ps7tcl]
ps7_init
catch { ps7_post_config }
targets -set -filter "name =~ \"*xc7z020*\" && jtag_cable_name =~ \"*$cab*\""
fpga $root/pr_out/ropuf_ax7020.bit
after 600
targets -set -filter "name =~ \"*JTAG2AXI*\" && jtag_cable_name =~ \"*$cab*\""
puts "VER [mrd -force 0x40000000]"
mwr -force 0x40000028 20
mwr -force 0x40000010 3
foreach {a b} {0 1 0 128 5 200 100 101} {
    mwr -force 0x40000020 $a
    mwr -force 0x40000024 $b
    mwr -force 0x40000008 4
    set t 0
    while {1} {
        set st [mrd -force 0x4000000C]
        if {[expr {[lindex $st 1] & 2}]} break
        after 20; incr t
        if {$t > 500} { puts "PAIR $a,$b TIMEOUT"; break }
    }
    puts "PAIR $a,$b LAST_RAW=[mrd -force 0x4000001C]  RO_CNT(sel=$a)=[mrd -force 0x40000030]"
}
exit
