# run_eval_ro.tcl — 配对型 RO Strong PUF AX7020 板上评估 (xsdb, 免 Vitis)
# 用法: xsdb.bat scripts\run_eval_ro.tcl [outfile] [n_chal] [reps] [runs] [board_tag] [cable]
# 寄存器: 0x00 VERSION(0x00040000) 0x08 CTRL(b0=batch,b1=soft_rst,b2=single)
#         0x0C STATUS 0x10 REPS 0x14 NCHAL 0x18 MAGIC 0x1C LAST_RAW
#         0x20 CH_A 0x24 CH_B 0x28 WIN_LOG2 0x2C RO_SEL 0x30 RO_CNT
#         0x34 CH_PUSH(1: (CH_A,CH_B)->挑战RAM[WDATA[11:2]]) 0x100+4i RESP[i]
# CSV: meta,* / chal,idx,a,b / resp,run,idx,w / single,run,w
#   resp w: [0]=vote [1]=unstable [15:8]=|Δcnt|>>16 截断 (诊断配对距离)

set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ip_pr.gen/sources_1/ip/ps7_0/ps7_init.tcl
if {![file exists $ps7tcl]} { set ps7tcl $root/pr_out/ps7_init.tcl }
set bit $root/pr_out/ropuf_ax7020.bit

set outfile "logs/ropuf_eval.csv"
set n_chal 256
set reps   9
set runs   3
set board_tag "board0"
if {$argc >= 1} { set outfile  [lindex $argv 0] }
if {$argc >= 2} { set n_chal   [lindex $argv 1] }
if {$argc >= 3} { set reps     [lindex $argv 2] }
if {$argc >= 4} { set runs     [lindex $argv 3] }
if {$argc >= 5} { set board_tag [lindex $argv 4] }
if {$argc >= 6} { set ::ev_a9_sel [lindex $argv 5]; set ::ev_axi_sel [lindex $argv 5] }
if {![file isdirectory [file dirname $outfile]]} {
    set outfile [file join $root [file tail $outfile]]
}
puts ">> OUTFILE=$outfile N_CHAL=$n_chal REPS=$reps RUNS=$runs TAG=$board_tag"

proc ev_find {pat} {
    set hits {}
    foreach ln [split [string trim [targets]] \n] {
        set ln [string trim $ln]
        if {$ln eq ""} continue
        if {[string match $pat $ln]} { lappend hits [lindex $ln 0] }
    }
    return $hits
}
proc ev_select {pat {override ""}} {
    set f "name =~ \"$pat\""
    if {$override ne ""} { set f "$f && jtag_cable_name =~ \"*$override*\"" }
    if {![catch {targets -set -filter $f} e]} { return $f }
    puts ">> EV_SELECT_ERR filter {$f}: $e"
    foreach ln [split [string trim [targets]] \n] {
        set ln [string trim $ln]
        if {$ln ne ""} { puts ">>   $ln" }
    }
    error "cannot select JTAG target with filter '$f'"
}

proc ev_init {} {
    global ps7tcl bit
    connect
    set ov ""
    if {[info exists ::ev_a9_sel]} { set ov $::ev_a9_sel }
    ev_select "*Cortex-A9 MPCore #0*" $ov
    catch { stop }
    after 200
    puts ">> ps7_init (FCLK_CLK0=100MHz) ..."
    uplevel #0 [list source $ps7tcl]
    ps7_init
    catch { ps7_post_config }
    puts ">> FCLK0_CTRL = [mrd -force 0xF8000170]   (expect 00400400 => 100MHz)"
    ev_select "*xc7z020*" $ov
    puts ">> programming bitstream $bit ..."
    fpga $bit
    after 500
    ev_select "*JTAG2AXI*" [expr {[info exists ::ev_axi_sel] ? $::ev_axi_sel : ""}]
    puts ">> ev_init done"
}

proc ev_rd {addr} {
    if {[catch {mrd -force $addr} r]} { error "mrd [format 0x%08X $addr] failed: $r" }
    return [expr {"0x[lindex $r 1]"}]
}
proc ev_wr {addr val} { mwr -force $addr $val }
proc hex8 {v} { return [format %08X [expr {$v & 0xFFFFFFFF}]] }

# xorshift32 挑战 PRNG (固定种子 -> 双板同一挑战集)
set xs_state 0x87654321
proc xs32 {} {
    global xs_state
    set x $xs_state
    set x [expr {$x ^ (($x << 13) & 0xFFFFFFFF)}]
    set x [expr {$x ^ ($x >> 17)}]
    set x [expr {$x ^ (($x << 5) & 0xFFFFFFFF)}]
    set xs_state [expr {$x & 0xFFFFFFFF}]
    return $xs_state
}

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

# ============================ 主流程 ============================
ev_init

set ver [ev_rd 0x40000000]
set cap [ev_rd 0x40000004]
set mag [ev_rd 0x40000018]
puts ">> SELFTEST VERSION=[format 0x%08X $ver] (expect 00040000)  CAP=[format 0x%08X $cap]  MAGIC=[format 0x%08X $mag]"
if {$ver != 0x00040000} { error "VERSION mismatch: ropuf slave not responding" }
if {[expr {$mag & 0xFFFF0000}] != 0x5A5A0000} { error "MAGIC mismatch: read path broken" }

set fh [open $outfile w]
puts $fh "meta,board,$board_tag"
puts $fh "meta,bit,$bit"
puts $fh "meta,date,[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
puts $fh "meta,n_chal,$n_chal"
puts $fh "meta,reps,$reps"
puts $fh "meta,runs,$runs"

# 1) 挑战集: 固定种子随机 (a,b) 对, a != b
#    模式 adj: 只用相邻对 (2k,2k+1) —— 硬宏布局下配对的两 RO 几何对称, 系统性差异最小
set mode "rand"
if {$argc >= 7} { set mode [lindex $argv 6] }
puts ">> CHAL_MODE=$mode"
set ::xs_state 0x87654321
set challs {}
if {$mode eq "adj"} {
    for {set i 0} {$i < $n_chal} {incr i} {
        set a [expr {(2 * $i) % 256}]
        set b [expr {(2 * $i + 1) % 256}]
        lappend challs [list $a $b]
    }
} elseif {[string range $mode 0 4] eq "file:"} {
    # file:<路径> — 每行 "idx,a,b", 注册期用板1频率表筛选出的 |Δf| 小的配对
    set cf [open [string range $mode 5 end] r]
    foreach line [split [read $cf] "\n"] {
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#"} { continue }
        lassign [split $line ","] _idx a b
        lappend challs [list $a $b]
    }
    close $cf
    set n_chal [llength $challs]
    puts ">> CHAL_FILE loaded [llength $challs] pairs"
} else {
for {set i 0} {$i < $n_chal} {incr i} {
    set a [expr {[xs32] % 256}]
    set b [expr {[xs32] % 256}]
    if {$a == $b} { set b [expr {($a + 1) % 256}] }
    lappend challs [list $a $b]
}
}
for {set i 0} {$i < $n_chal} {incr i} {
    lassign [lindex $challs $i] a b
    puts $fh "chal,$i,$a,$b"
    ev_wr 0x40000020 $a
    ev_wr 0x40000024 $b
    ev_wr 0x40000034 [expr {($i << 2) | 1}]
    if {$i % 64 == 0} { puts ">> chal push $i / $n_chal" }
}

# 2) 单发自检 x3 (RO 0 vs 1) + 测量窗口设 2^20 (频率分辨率 0.095MHz, 筛选配对 |Δf|~0.02-0.10 需要)
ev_wr 0x40000028 20
ev_wr 0x40000010 $reps
for {set u 0} {$u < 3} {incr u} {
    ev_wr 0x40000020 0
    ev_wr 0x40000024 1
    ev_wr 0x40000008 4
    wait_done
    set lr [ev_rd 0x4000001C]
    puts $fh "single,$u,[hex8 $lr]"
    puts ">> single run $u: LAST_RAW=[format 0x%08X $lr]"
}

# 3) 批量 CRP x runs 轮
ev_wr 0x40000014 $n_chal
for {set u 0} {$u < $runs} {incr u} {
    ev_wr 0x40000008 1
    wait_done
    for {set i 0} {$i < $n_chal} {incr i} {
        set w [ev_rd [expr {0x40000100 + 4*$i}]]
        puts $fh "resp,$u,$i,[hex8 $w]"
    }
    puts ">> batch run $u / $runs done"
}

close $fh
puts ">> EVAL_DONE $outfile"
exit
