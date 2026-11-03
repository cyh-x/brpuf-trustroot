# run_eval_brpuf2.tcl — 双稳环阵列 Strong PUF v9 板上评估
# 用法: xsdb.bat scripts\run_eval_brpuf.tcl <outfile> <n_chal> <reps> <runs> <tag> <cable> [mode]
#   mode: rand (默认, 随机偶反转数挑战) | bif | zero | full
#   挑战约束: popcount 必须为偶数 (否则环振荡而非双稳)
# CSV: meta,* / chal,i,lo32 / resp,run,i,w  (w[0]=vote w[1]=unst w[7:2]=ones)
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ip_pr.gen/sources_1/ip/ps7_0/ps7_init.tcl
if {![file exists $ps7tcl]} { set ps7tcl $root/pr_out/ps7_init.tcl }
set bit $root/pr_out/brpuf2_ax7020.bit

set outfile [lindex $argv 0]
set n_chal  [lindex $argv 1]
set reps    [lindex $argv 2]
set runs    [lindex $argv 3]
set tag     [lindex $argv 4]
set cab     [lindex $argv 5]
set mode "rand"
if {$argc >= 7} { set mode [lindex $argv 6] }
if {![file isdirectory [file dirname $outfile]]} {
    set outfile [file join $root [file tail $outfile]]
}
puts ">> BRPUF_EVAL OUT=$outfile N=$n_chal REPS=$reps RUNS=$runs TAG=$tag MODE=$mode"

proc ev_select {pat} {
    global cab
    set f "name =~ \"$pat\" && jtag_cable_name =~ \"*$cab*\""
    if {[catch {targets -set -filter $f} e]} { error "cannot select '$pat': $e" }
}
proc ev_rd {a} { return [expr {"0x[lindex [mrd -force $a] 1]"}] }
proc ev_wr {a v} { mwr -force $a $v }
proc hex8 {v} { return [format %08X [expr {$v & 0xFFFFFFFF}]] }

set xs 12345678901234567
proc xs64 {} {
    global xs
    set x $xs
    set x [expr {$x ^ ($x << 13)}]
    set x [expr {$x ^ (($x >> 7) & 0xFFFFFFFFFFFFFFFF)}]
    set x [expr {$x ^ ($x << 17)}]
    set xs [expr {$x & 0xFFFFFFFFFFFFFFFF}]
    return $xs
}
proc par64 {v} {
    set p 0
    for {set b 0} {$b < 64} {incr b} { incr p [expr {($v >> $b) & 1}] }
    return [expr {$p % 2}]
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
puts ">> SELFTEST VERSION=[format 0x%08X $ver] (expect 00080000)  MAGIC=[format 0x%08X $mag]"
if {$ver != 0x00090000} { error "VERSION mismatch" }
if {[expr {$mag & 0xFFFF0000}] != 0x5A5A0000} { error "MAGIC mismatch" }

# ---- 生成挑战 (保证偶数反转) ----
proc par16 {v} {
    set p 0
    for {set b 0} {$b < 16} {incr b} { incr p [expr {($v >> $b) & 1}] }
    return [expr {$p % 2}]
}
set chals {}
if {[string range $mode 0 4] eq "file:"} {
    set cf [open [string range $mode 5 end] r]
    foreach line [split [read $cf] "
"] {
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#"} { continue }
        lassign [split $line ","] _idx v
        lappend chals $v
    }
    close $cf
    puts ">> CHAL_FILE loaded [llength $chals]"
} elseif {$mode eq "sweep"} {
    # 每环一个固定图案 (0x3): 64 挑战
    for {set r 0} {$r < 64} {incr r} { lappend chals [expr {($r << 16) | 0x3}] }
} else {
    while {[llength $chals] < $n_chal} {
        set r [expr {[xs64] % 64}]
        set v [expr {[xs64] & 0xFFFF}]
        if {[par16 $v] == 0} { lappend chals [expr {($r << 16) | $v}] }
    }
}
set n [llength $chals]
puts ">> challenges generated: $n (all even parity)"

set fh [open $outfile w]
puts $fh "meta,board,$tag"
puts $fh "meta,bit,$bit"
puts $fh "meta,date,[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
puts $fh "meta,n_chal,$n"
puts $fh "meta,reps,$reps"
puts $fh "meta,runs,$runs"
puts $fh "meta,mode,$mode"

for {set i 0} {$i < $n} {incr i} {
    set v [lindex $chals $i]
    ev_wr 0x40000020 $v
    ev_wr 0x40000034 [expr {($i << 2) | 1}]
    puts $fh "chal,$i,$v"
    if {$i % 128 == 0} { puts ">> push $i / $n" }
}
ev_wr 0x40000010 $reps
ev_wr 0x40000014 $n
for {set u 0} {$u < $runs} {incr u} {
    ev_wr 0x40000008 1
    set t 0
    while {1} {
        set st [ev_rd 0x4000000C]
        if {[expr {$st & 2}]} break
        after 50; incr t
        if {$t > 8000} { error "timeout at run $u" }
    }
    for {set i 0} {$i < $n} {incr i} {
        set w [ev_rd [expr {0x40000100 + 4*$i}]]
        puts $fh "resp,$u,$i,[hex8 $w]"
    }
    puts ">> run $u / $runs done"
}
close $fh
puts ">> BRPUF_EVAL_DONE $outfile"
exit
