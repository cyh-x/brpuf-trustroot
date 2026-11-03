# run_rel_brpuf.tcl — BR-PUF 大规模重复采集可靠性数据
# 用法: xsdb.bat scripts\run_rel_brpuf.tcl <chalfile> <runs> <reps> <tag> <cable>
#   挑战推一次, 连续 runs 轮批量 (每轮 = 全挑战 x reps 票决), CSV 同标准格式
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ip_pr.gen/sources_1/ip/ps7_0/ps7_init.tcl
if {![file exists $ps7tcl]} { set ps7tcl $root/pr_out/ps7_init.tcl }
set bit $root/pr_out/brpuf2_ax7020.bit
set chalf [lindex $argv 0]
set runs  [lindex $argv 1]
set reps  [lindex $argv 2]
set tag   [lindex $argv 3]
set cab   [lindex $argv 4]
set outfile "logs/brpuf_rel_${tag}.csv"
puts ">> REL_BRPUF chal=$chalf runs=$runs reps=$reps tag=$tag"

proc ev_select {pat} {
    global cab
    set f "name =~ \"$pat\" && jtag_cable_name =~ \"*$cab*\""
    if {[catch {targets -set -filter $f} e]} { error "cannot select '$pat': $e" }
}
proc ev_rd {a} { return [expr {"0x[lindex [mrd -force $a] 1]"}] }
proc ev_wr {a v} { mwr -force $a $v }
proc hex8 {v} { return [format %08X [expr {$v & 0xFFFFFFFF}]] }

set idxs {}; set chals {}
foreach line [split [read [open $chalf r]] "\n"] {
    set line [string trim $line]
    if {$line eq "" || [string index $line 0] eq "#"} { continue }
    lassign [split $line ","] oi cv
    lappend idxs $oi; lappend chals $cv
}
set n [llength $chals]
puts ">> loaded $n challenges"

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
if {[ev_rd 0x40000000] != 0x00090000} { error "VERSION mismatch" }
puts ">> SELFTEST OK"

for {set i 0} {$i < $n} {incr i} {
    ev_wr 0x40000020 [lindex $chals $i]
    ev_wr 0x40000034 [expr {($i << 2) | 1}]
}
ev_wr 0x40000010 $reps
ev_wr 0x40000014 $n

set fh [open $outfile w]
puts $fh "meta,board,$tag"
puts $fh "meta,n_chal,$n"
puts $fh "meta,reps,$reps"
puts $fh "meta,runs,$runs"
for {set i 0} {$i < $n} {incr i} { puts $fh "chal,$i,[lindex $idxs $i]" }
set t0 [clock seconds]
for {set u 0} {$u < $runs} {incr u} {
    ev_wr 0x40000008 1
    set t 0
    while {1} {
        if {[expr {[ev_rd 0x4000000C] & 2}]} break
        after 20; incr t
        if {$t > 8000} { error "timeout run $u" }
    }
    for {set i 0} {$i < $n} {incr i} {
        set w [ev_rd [expr {0x40000100 + 4*$i}]]
        puts $fh "resp,$u,$i,[hex8 $w]"
    }
    puts ">> run $u / $runs done ([expr {[clock seconds]-$t0}]s)"
}
close $fh
puts ">> REL_BRPUF_DONE $outfile"
exit
