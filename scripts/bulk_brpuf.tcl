# bulk_brpuf.tcl — BR-PUF 批量 CRP 采集 (单连接多批, 用于建模攻击研究)
# 用法: xsdb.bat scripts\bulk_brpuf.tcl <cable> <tag> <nbatches> [batch_size] [seed]
#   每批独立随机挑战 (偶校验), 连续采集, 输出 logs/brpuf_bulk_<tag>.csv
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ip_pr.gen/sources_1/ip/ps7_0/ps7_init.tcl
if {![file exists $ps7tcl]} { set ps7tcl $root/pr_out/ps7_init.tcl }
set bit $root/pr_out/brpuf2_ax7020.bit
set cab [lindex $argv 0]
set tag [lindex $argv 1]
set nb  [lindex $argv 2]
set bs  1000
if {$argc >= 4} { set bs [lindex $argv 3] }
set sd  987654321
if {$argc >= 5} { set sd [lindex $argv 4] }
set outfile "logs/brpuf_bulk_${tag}.csv"
puts ">> BULK tag=$tag batches=$nb x $bs seed=$sd"

proc ev_select {pat} {
    global cab
    set f "name =~ \"$pat\" && jtag_cable_name =~ \"*$cab*\""
    if {[catch {targets -set -filter $f} e]} { error "cannot select '$pat': $e" }
}
proc ev_rd {a} { return [expr {"0x[lindex [mrd -force $a] 1]"}] }
proc ev_wr {a v} { mwr -force $a $v }
proc hex8 {v} { return [format %08X [expr {$v & 0xFFFFFFFF}]] }

set xs $sd
proc xs64 {} {
    global xs
    set x $xs
    set x [expr {$x ^ ($x << 13)}]
    set x [expr {$x ^ (($x >> 7) & 0xFFFFFFFFFFFFFFFF)}]
    set x [expr {$x ^ ($x << 17)}]
    set xs [expr {$x & 0xFFFFFFFFFFFFFFFF}]
    return $xs
}
proc par16 {v} {
    set p 0
    for {set b 0} {$b < 16} {incr b} { incr p [expr {($v >> $b) & 1}] }
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
if {[ev_rd 0x40000000] != 0x00090000} { error "VERSION mismatch" }
puts ">> SELFTEST OK"

set fh [open $outfile w]
puts $fh "meta,board,$tag"
puts $fh "meta,batches,$nb"
puts $fh "meta,batch_size,$bs"
set t0 [clock seconds]
set total 0
for {set u 0} {$u < $nb} {incr u} {
    # 生成本批挑战
    set chals {}
    while {[llength $chals] < $bs} {
        set r [expr {[xs64] % 64}]
        set v [expr {[xs64] & 0xFFFF}]
        if {[par16 $v] == 0} { lappend chals [expr {($r << 16) | $v}] }
    }
    for {set i 0} {$i < $bs} {incr i} {
        ev_wr 0x40000020 [lindex $chals $i]
        ev_wr 0x40000034 [expr {($i << 2) | 1}]
    }
    ev_wr 0x40000010 15
    ev_wr 0x40000014 $bs
    ev_wr 0x40000008 1
    set t 0
    while {1} {
        if {[expr {[ev_rd 0x4000000C] & 2}]} break
        after 20; incr t
        if {$t > 8000} { error "timeout batch $u" }
    }
    for {set i 0} {$i < $bs} {incr i} {
        set w [ev_rd [expr {0x40000100 + 4*$i}]]
        puts $fh "crp,$u,$i,[lindex $chals $i],[hex8 $w]"
        incr total
    }
    puts ">> batch $u / $nb done ($total CRPs, [expr {[clock seconds]-$t0}]s)"
}
close $fh
puts ">> BULK_DONE $outfile ($total CRPs)"
exit
