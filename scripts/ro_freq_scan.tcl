# ro_freq_scan.tcl — 诊断: 逐 RO 读窗口计数值 (RO_SEL/RO_CNT 调试口)
# 用法: xsdb.bat scripts\ro_freq_scan.tcl <cable> [first] [last]
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ip_pr.gen/sources_1/ip/ps7_0/ps7_init.tcl
if {![file exists $ps7tcl]} { set ps7tcl $root/pr_out/ps7_init.tcl }
set bit $root/pr_out/ropuf_ax7020.bit
set cab "210512180081"
set first 0
set last  32
if {$argc >= 1} { set cab [lindex $argv 0] }
if {$argc >= 2} { set first [lindex $argv 1] }
if {$argc >= 3} { set last [lindex $argv 2] }

connect
targets -set -filter "name =~ \"*Cortex-A9 MPCore #0*\" && jtag_cable_name =~ \"*$cab*\""
catch { rst -processor }; catch { stop }; after 200
uplevel #0 [list source $ps7tcl]
ps7_init
catch { ps7_post_config }
targets -set -filter "name =~ \"*xc7z020*\" && jtag_cable_name =~ \"*$cab*\""
fpga $bit
after 500
targets -set -filter "name =~ \"*JTAG2AXI*\" && jtag_cable_name =~ \"*$cab*\""

proc rd {a} { return [expr {"0x[lindex [mrd -force $a] 1]"}] }
set ver [rd 0x40000000]
puts ">> VERSION=[format 0x%08X $ver]"
if {$ver != 0x00040000} { error "slave not responding" }

mwr -force 0x40000028 20          ;# WIN_LOG2=20 (1.05M 拍窗口)
mwr -force 0x40000010 3           ;# REPS=3 (只需触发一次窗口)
puts ">> RO frequency scan (window=2^20 @100MHz, count = edges = f_out/100M*2^20):"
for {set i $first} {$i <= $last} {incr i} {
    mwr -force 0x4000002C $i      ;# RO_SEL = i
    mwr -force 0x40000020 $i      ;# CH_A
    mwr -force 0x40000024 [expr {($i+1)%256}]
    mwr -force 0x40000008 4       ;# single shot
    set t 0
    while {1} {
        set st [rd 0x4000000C]
        if {[expr {$st & 2}]} break
        after 10; incr t
        if {$t > 2000} { error "timeout" }
    }
    set cnt [rd 0x40000030]
    # f_out(MHz) = cnt/1048576*100
    set fmh [expr {double($cnt & 0xFFFFFF)/10485.76}]
    puts [format "RO %3d : cnt=%7d  f_out=%6.2f MHz" $i [expr {$cnt & 0xFFFFFF}] $fmh]
}
exit
