# pdlro_diag.tcl — PDL-RO 自证: 环振存活 + 挑战-频率耦合
#   单发模式测 (A, ~A): A 的 popcount=p, ~A 为 64-p -> |Δcount| 应随 |2p-64| 增长
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ip_pr.gen/sources_1/ip/ps7_0/ps7_init.tcl
if {![file exists $ps7tcl]} { set ps7tcl $root/pr_out/ps7_init.tcl }
set bit $root/pr_out/pdlro_ax7020.bit
set cab [lindex $argv 0]
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
proc wr {a v} { mwr -force $a $v }
proc wait_done {} {
    set t 0
    while {1} {
        if {[expr {[rd 0x4000000C] & 2}]} break
        after 10; incr t
        if {$t > 4000} { error "timeout" }
    }
}
puts ">> VERSION [format 0x%08X [rd 0x40000000]]  MAGIC [format 0x%08X [rd 0x40000018]]"
wr 0x40000028 20      ;# WIN_LOG2=20
wr 0x40000010 15      ;# REPS=15

foreach step {31 15 5 1} {
    wr 0x4000002C $step
    set line "STEP=$step :"
    foreach p {0 8 16 24 32 40 48 56 64} {
        set lo 0; set hi 0
        if {$p >= 32} { set hi [expr {($p==32)?0xFFFFFFFF:(1<<($p-32))-1}]; set lo 0xFFFFFFFF }
        if {$p < 32}  { set lo [expr {(1<<$p)-1}] }
        wr 0x40000020 $lo
        wr 0x40000024 $hi
        wr 0x40000008 4
        wait_done
        set lr [rd 0x4000001C]
        set dbg [rd 0x40000038]
        set ref [rd 0x4000003C]
        set vote [expr {$lr & 1}]
        set dlog [expr {($lr >> 8) & 0xFF}]
        set any1 [expr {($dbg >> 31) & 1}]
        set any0 [expr {($dbg >> 30) & 1}]
        append line "  p$p: dlog=$dlog cntB=[expr {$dbg & 0xFFFF}] osc=[expr {($any1&&$any0)?"Y":"N"}]"
    }
    puts ">> $line"
}
exit
