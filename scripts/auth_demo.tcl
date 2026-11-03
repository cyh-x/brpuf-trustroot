# auth_demo.tcl — PDL-RO 认证演示: 现场测量 + 身份判决
# 用法: xsdb.bat scripts\auth_demo.tcl <cable> <outfile> <reps>
#   重新生成注册时的同一组随机挑战 (种子固定), 现场采一轮, 输出 CSV 供 authenticate.py 判决
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ip_pr.gen/sources_1/ip/ps7_0/ps7_init.tcl
if {![file exists $ps7tcl]} { set ps7tcl $root/pr_out/ps7_init.tcl }
set bit $root/pr_out/pdlro_ax7020.bit
set cab [lindex $argv 0]
set outfile [lindex $argv 1]
set reps 15
if {$argc >= 3} { set reps [lindex $argv 2] }
if {![file isdirectory [file dirname $outfile]]} {
    set outfile [file join $root [file tail $outfile]]
}
puts ">> AUTH_DEMO cable=$cab reps=$reps out=$outfile"

proc ev_select {pat} {
    global cab
    set f "name =~ \"$pat\" && jtag_cable_name =~ \"*$cab*\""
    if {[catch {targets -set -filter $f} e]} { error "cannot select '$pat': $e" }
}
proc ev_rd {a} { return [expr {"0x[lindex [mrd -force $a] 1]"}] }
proc ev_wr {a v} { mwr -force $a $v }
proc hex8 {v} { return [format %08X [expr {$v & 0xFFFFFFFF}]] }

# 与 run_eval_pdlro.tcl 完全一致的挑战生成 (rand 模式, 种子 88172645463325252)
set xs 88172645463325252
proc xs64 {} {
    global xs
    set x $xs
    set x [expr {$x ^ ($x << 13)}]
    set x [expr {$x ^ (($x >> 7) & 0xFFFFFFFFFFFFFFFF)}]
    set x [expr {$x ^ ($x << 17)}]
    set xs [expr {$x & 0xFFFFFFFFFFFFFFFF}]
    return $xs
}

connect
ev_select "*Cortex-A9 MPCore #0*"
catch { rst -processor }; catch { stop }; after 200
uplevel #0 [list source $ps7tcl]
ps7_init
catch { ps7_post_config }
ev_select "*xc7z020*"
fpga $bit
after 500
ev_select "*JTAG2AXI*"
set ver [ev_rd 0x40000000]
if {$ver != 0x00060000} { error "VERSION mismatch [format 0x%08X $ver]" }
puts ">> SELFTEST OK"

set n 256
for {set i 0} {$i < $n} {incr i} {
    foreach which {0 1} {
        set v [xs64]
        ev_wr 0x40000020 [expr {$v & 0xFFFFFFFF}]
        ev_wr 0x40000024 [expr {($v >> 32) & 0xFFFFFFFF}]
        ev_wr 0x40000034 [expr {(2*$i + $which) << 2 | 1}]
    }
}
ev_wr 0x4000002C 1
ev_wr 0x40000028 20
ev_wr 0x40000010 $reps
ev_wr 0x40000014 $n
ev_wr 0x40000008 1
set t 0
while {1} {
    set st [ev_rd 0x4000000C]
    if {[expr {$st & 2}]} break
    after 50; incr t
    if {$t > 6000} { error "timeout" }
}
set fh [open $outfile w]
puts $fh "meta,board,live"
puts $fh "meta,reps,$reps"
for {set i 0} {$i < $n} {incr i} {
    set w [ev_rd [expr {0x40000100 + 4*$i}]]
    puts $fh "resp,0,$i,[hex8 $w]"
}
close $fh
puts ">> AUTH_MEASURE_DONE $outfile"
exit
