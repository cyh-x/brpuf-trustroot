# run_reliability.tcl — 大量重复采集可靠性数据 (配对筛选挑战集)
# 用法: xsdb.bat scripts\run_reliability.tcl <outfile> <chalfile> <runs_total> <repro_every> <board_tag> <cable> [reps]
#   每轮 = 完整批量 CRP (n_chal 对 x reps 次表决); 每 repro_every 轮重烧位流
#   (模拟上电/重配, 挑战RAM与寄存器随之清空, 重烧后自动重推)
# CSV 与 run_eval_ro.tcl 同格式: meta,* / chal,i,a,b / resp,run,idx,w / single,run,w
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ip_pr.gen/sources_1/ip/ps7_0/ps7_init.tcl
if {![file exists $ps7tcl]} { set ps7tcl $root/pr_out/ps7_init.tcl }
set bit $root/pr_out/ropuf_ax7020.bit

set outfile [lindex $argv 0]
set chalfile [lindex $argv 1]
set runs_total [lindex $argv 2]
set repro_every [lindex $argv 3]
set board_tag [lindex $argv 4]
set cab [lindex $argv 5]
set reps 15
if {$argc >= 7} { set reps [lindex $argv 6] }
if {![file isdirectory [file dirname $outfile]]} {
    set outfile [file join $root [file tail $outfile]]
}
puts ">> RELIABILITY OUT=$outfile CHAL=$chalfile RUNS=$runs_total REPRO_EVERY=$repro_every TAG=$board_tag CABLE=$cab REPS=$reps"

proc ev_select {pat} {
    set f "name =~ \"$pat\" && jtag_cable_name =~ \"*$::cab*\""
    if {[catch {targets -set -filter $f} e]} {
        puts ">> targets now:"
        foreach ln [split [string trim [targets]] \n] {
            set ln [string trim $ln]
            if {$ln ne ""} { puts ">>   $ln" }
        }
        error "cannot select '$pat': $e"
    }
}
proc ev_rd {addr} { return [expr {"0x[lindex [mrd -force $addr] 1]"}] }
proc ev_wr {addr val} { mwr -force $addr $val }
proc hex8 {v} { return [format %08X [expr {$v & 0xFFFFFFFF}]] }

# ---- 读挑战文件 ----
set challs {}
set cf [open $chalfile r]
foreach line [split [read $cf] "\n"] {
    set line [string trim $line]
    if {$line eq "" || [string index $line 0] eq "#"} { continue }
    lassign [split $line ","] _idx a b
    lappend challs [list $a $b]
}
close $cf
set n_chal [llength $challs]
puts ">> loaded $n_chal challenges"

proc wait_done {} {
    set t 0
    while {1} {
        set st [ev_rd 0x4000000C]
        if {[expr {$st & 2}]} break
        after 20
        incr t
        if {$t > 6000} { error "batch timeout (STATUS=[format 0x%08X $st])" }
    }
}
proc push_chals {} {
    global challs n_chal
    for {set i 0} {$i < $n_chal} {incr i} {
        lassign [lindex $challs $i] a b
        ev_wr 0x40000020 $a
        ev_wr 0x40000024 $b
        ev_wr 0x40000034 [expr {($i << 2) | 1}]
    }
}
proc cfg_regs {} {
    global reps
    ev_wr 0x40000028 20          ;# WIN_LOG2=20
    ev_wr 0x40000010 $reps
    ev_wr 0x40000014 $::n_chal
}

# ---- 连接 + 首次编程 ----
connect
ev_select "*Cortex-A9 MPCore #0*"
catch { rst -processor }; catch { stop }; after 200
uplevel #0 [list source $ps7tcl]
ps7_init
catch { ps7_post_config }
puts ">> FCLK0_CTRL = [mrd -force 0xF8000170]   (expect 00400400 => 100MHz)"
ev_select "*xc7z020*"
fpga $bit
after 600
ev_select "*JTAG2AXI*"
set ver [ev_rd 0x40000000]
if {$ver != 0x00040000} { error "VERSION mismatch: [format 0x%08X $ver]" }
puts ">> SELFTEST OK"
cfg_regs
push_chals
puts ">> initial challenge push done ([llength $challs] pairs)"

proc reprogram {} {
    global bit
    ev_select "*xc7z020*"
    fpga $bit
    after 800
    ev_select "*JTAG2AXI*"
    set ver [ev_rd 0x40000000]
    if {$ver != 0x00040000} { error "reprogram VERSION mismatch" }
}

# ---- 主循环 ----
set fh [open $outfile w]
puts $fh "meta,board,$board_tag"
puts $fh "meta,bit,$bit"
puts $fh "meta,date,[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
puts $fh "meta,n_chal,$n_chal"
puts $fh "meta,reps,$reps"
puts $fh "meta,runs,$runs_total"
puts $fh "meta,repro_every,$repro_every"
for {set i 0} {$i < $n_chal} {incr i} {
    lassign [lindex $challs $i] a b
    puts $fh "chal,$i,$a,$b"
}
set repro_at {}
set t0 [clock seconds]
for {set u 0} {$u < $runs_total} {incr u} {
    if {$u > 0 && [expr {$u % $repro_every}] == 0} {
        reprogram
        cfg_regs
        push_chals
        lappend repro_at $u
        puts ">> reprogram before run $u"
    }
    set ts [clock format [clock seconds] -format {%H:%M:%S}]
    ev_wr 0x40000008 1
    wait_done
    for {set i 0} {$i < $n_chal} {incr i} {
        set w [ev_rd [expr {0x40000100 + 4*$i}]]
        puts $fh "resp,$u,$i,[hex8 $w]"
    }
    puts ">> run $u / $runs_total done @ $ts  (elapsed [expr {[clock seconds]-$t0}]s)"
}
puts $fh "meta,repro_at,[join $repro_at { }]"
close $fh
puts ">> RELIABILITY_DONE $outfile  repro_at=[join $repro_at { }]"
exit
