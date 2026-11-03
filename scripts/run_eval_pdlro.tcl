# run_eval_pdlro.tcl — PDL-RO Strong PUF 板上评估 (xsdb)
# 用法: xsdb.bat scripts\run_eval_pdlro.tcl <outfile> <n_pair> <reps> <runs> <tag> <cable> [step]
#   挑战 = 固定种子随机 64bit 图案对 (A,B); resp w[0]=vote w[1]=unst w[9:2]=|Δcnt|>>8
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ip_pr.gen/sources_1/ip/ps7_0/ps7_init.tcl
if {![file exists $ps7tcl]} { set ps7tcl $root/pr_out/ps7_init.tcl }
set bit $root/pr_out/pdlro_ax7020.bit

set outfile [lindex $argv 0]
set n_pair  [lindex $argv 1]
set reps    [lindex $argv 2]
set runs    [lindex $argv 3]
set board_tag [lindex $argv 4]
set cab [lindex $argv 5]
set step 1
if {$argc >= 7} { set step [lindex $argv 6] }
set chmode "rand"
if {$argc >= 8} { set chmode [lindex $argv 7] }
# near 模式: B = A 翻转 1 位 (汉明距 1 -> 结构性近平局, Δ 只由该级 LUT 路径差决定)
proc mknear {v} {
    set b [expr {int(rand()*64)}]
    set v [expr {$v ^ (1 << $b)}]
    if {$::chmode eq "near2"} {
        set c $b
        while {$c == $b} { set c [expr {int(rand()*64)}] }
        set v [expr {$v ^ (1 << $c)}]
    }
    return $v
}
if {![file isdirectory [file dirname $outfile]]} {
    set outfile [file join $root [file tail $outfile]]
}
puts ">> PDLRO_EVAL OUT=$outfile N=$n_pair REPS=$reps RUNS=$runs TAG=$board_tag STEP=$step"

proc ev_select {pat} {
    global cab
    set f "name =~ \"$pat\" && jtag_cable_name =~ \"*$cab*\""
    if {[catch {targets -set -filter $f} e]} { error "cannot select '$pat': $e" }
}
proc ev_rd {addr} { return [expr {"0x[lindex [mrd -force $addr] 1]"}] }
proc ev_wr {addr val} { mwr -force $addr $val }
proc hex8 {v} { return [format %08X [expr {$v & 0xFFFFFFFF}]] }

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
set mag [ev_rd 0x40000018]
puts ">> SELFTEST VERSION=[format 0x%08X $ver] (expect 00060000)  MAGIC=[format 0x%08X $mag]"
if {$ver != 0x00060000} { error "VERSION mismatch" }
if {[expr {$mag & 0xFFFF0000}] != 0x5A5A0000} { error "MAGIC mismatch" }

# ---- 推图案对: 配对 i 的 A 在 2i, B 在 2i+1 ----
# bal 模式: A/B 均取 popcount=32 (popcount 系统项相消, 只剩位置相关失配)
proc mkbal {} {
    set pos {}
    while {[llength $pos] < 32} {
        set r [expr {int(rand()*64)}]
        if {[lsearch -integer $pos $r] < 0} { lappend pos $r }
    }
    set v 0
    foreach x $pos { set v [expr {$v | (1 << $x)}] }
    return $v
}
if {$chmode eq "bal" || $chmode eq "near"} { expr {srand(12345)} }
set xs 88172645463325252
set fh [open $outfile w]
puts $fh "meta,board,$board_tag"
puts $fh "meta,bit,$bit"
puts $fh "meta,date,[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
puts $fh "meta,n_chal,$n_pair"
puts $fh "meta,reps,$reps"
puts $fh "meta,runs,$runs"
puts $fh "meta,step,$step"

for {set i 0} {$i < $n_pair} {incr i} {
    foreach which {0 1} {
        if {$chmode eq "bal"} { set v [mkbal] } else { set v [xs64] }
        if {$chmode eq "near" && $which == 0} { set ::pvA $v }
        if {$chmode eq "near" && $which == 1} { set v [mknear $::pvA] }
        set lo [expr {$v & 0xFFFFFFFF}]
        set hi [expr {($v >> 32) & 0xFFFFFFFF}]
        ev_wr 0x40000020 $lo
        ev_wr 0x40000024 $hi
        ev_wr 0x40000034 [expr {(2*$i + $which) << 2 | 1}]
    }
    # CSV 记录 (analyze_ro 兼容 4 字段: 取 A/B 的 lo32)
    set av [ev_rd 0x40000020]
    puts $fh "chal,$i,$av,0"
    if {$i % 64 == 0} { puts ">> push pair $i / $n_pair" }
}
ev_wr 0x4000002C $step
ev_wr 0x40000028 20
ev_wr 0x40000010 $reps
ev_wr 0x40000014 $n_pair
for {set u 0} {$u < $runs} {incr u} {
    ev_wr 0x40000008 1
    set t 0
    while {1} {
        set st [ev_rd 0x4000000C]
        if {[expr {$st & 2}]} break
        after 50; incr t
        if {$t > 6000} { error "batch timeout" }
    }
    for {set i 0} {$i < $n_pair} {incr i} {
        set w [ev_rd [expr {0x40000100 + 4*$i}]]
        puts $fh "resp,$u,$i,[hex8 $w]"
    }
    puts ">> batch run $u / $runs done"
}
close $fh
puts ">> PDLRO_EVAL_DONE $outfile"
exit
