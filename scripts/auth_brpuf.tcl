# auth_brpuf.tcl — BR-PUF 认证会话: 下发会话挑战子集并现场测量
# 用法: xsdb.bat scripts\auth_brpuf.tcl <cable> <session_chal_file> <outfile> [reps]
#   session_chal_file: 每行 "orig_idx,chal_word" (服务器端按会话种子抽取)
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ip_pr.gen/sources_1/ip/ps7_0/ps7_init.tcl
if {![file exists $ps7tcl]} { set ps7tcl $root/pr_out/ps7_init.tcl }
set bit $root/pr_out/brpuf2_ax7020.bit
set cab [lindex $argv 0]
set chalf [lindex $argv 1]
set outfile [lindex $argv 2]
set reps 15
if {$argc >= 4} { set reps [lindex $argv 3] }

proc ev_select {pat} {
    global cab
    set f "name =~ \"$pat\" && jtag_cable_name =~ \"*$cab*\""
    if {[catch {targets -set -filter $f} e]} { error "cannot select '$pat': $e" }
}
proc ev_rd {a} { return [expr {"0x[lindex [mrd -force $a] 1]"}] }
proc ev_wr {a v} { mwr -force $a $v }
proc hex8 {v} { return [format %08X [expr {$v & 0xFFFFFFFF}]] }

# 读会话挑战子集
set idxs {}; set chals {}
foreach line [split [read [open $chalf r]] "\n"] {
    set line [string trim $line]
    if {$line eq "" || [string index $line 0] eq "#"} { continue }
    lassign [split $line ","] oi cv
    lappend idxs $oi
    lappend chals $cv
}
set n [llength $chals]
puts ">> AUTH_SESSION cable=$cab challenges=$n reps=$reps"

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
if {$ver != 0x00090000} { error "VERSION mismatch [format 0x%08X $ver]" }
puts ">> SELFTEST OK"

for {set i 0} {$i < $n} {incr i} {
    ev_wr 0x40000020 [lindex $chals $i]
    ev_wr 0x40000034 [expr {($i << 2) | 1}]
}
ev_wr 0x40000010 $reps
ev_wr 0x40000014 $n
ev_wr 0x40000008 1
set t 0
while {1} {
    set st [ev_rd 0x4000000C]
    if {[expr {$st & 2}]} break
    after 20; incr t
    if {$t > 8000} { error "timeout" }
}
set fh [open $outfile w]
puts $fh "meta,cable,$cab"
puts $fh "meta,chalf,$chalf"
puts $fh "meta,reps,$reps"
puts $fh "meta,date,[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
for {set i 0} {$i < $n} {incr i} {
    set w [ev_rd [expr {0x40000100 + 4*$i}]]
    puts $fh "resp,[lindex $idxs $i],$w"
}
close $fh
puts ">> AUTH_MEASURE_DONE $outfile"
exit
