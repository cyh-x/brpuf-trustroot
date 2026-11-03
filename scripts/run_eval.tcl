# run_eval.tcl — Strong PUF (4x4 APUF) AX7020 板上评估 (xsdb, 免 Vitis)
# 用法: xsdb.bat scripts\run_eval.tcl [outfile] [n_chal] [reps] [runs] [board_tag] [cable]
#   n_chal : 批内挑战数 (默认 256, <=1024)
#   reps   : 每挑战片上重复表决次数 R (默认 15, 奇数)
#   runs   : 整批重复次数 (默认 3, 供板内可靠性统计)
# CSV 行格式 (逗号分隔, 全 ASCII):
#   meta,board,<标签>          meta,bit,<位流路径>       meta,n_chal,<N>
#   meta,reps,<R>              meta,runs,<B>
#   chal,<idx>,<w0>,<w1>,<w2>,<w3>          128bit 挑战 (w3 高 8 位为 0)
#   resp,<run>,<idx>,<w>       表决字 [5:0]=vote [11:6]=不稳定掩码
#   single,<run>,<w0>,<w3>     单发自检 (固定全 0 挑战) 的 LAST_RAW
# 寄存器见 spuf_axi.v 头注释; 挑战用 xorshift32 固定种子生成 -> 双板可比

set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ip_pr.gen/sources_1/ip/ps7_0/ps7_init.tcl
if {![file exists $ps7tcl]} { set ps7tcl $root/pr_out/ps7_init.tcl }
set bit $root/pr_out/spuf_ax7020.bit

set outfile "logs/spuf_eval.csv"
set n_chal 256
set reps   15
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

# ---- target 选择 (复用 ax7020_port 已验证套路, cable 过滤是 glob 需 * 包裹) ----
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

# ---- xorshift32 挑战 PRNG (固定种子 -> 双板同一挑战集) ----
set xs_state 0x12345678
proc xs32 {} {
    global xs_state
    set x $xs_state
    set x [expr {$x ^ (($x << 13) & 0xFFFFFFFF)}]
    set x [expr {$x ^ ($x >> 17)}]
    set x [expr {$x ^ (($x << 5) & 0xFFFFFFFF)}]
    set xs_state [expr {$x & 0xFFFFFFFF}]
    return $xs_state
}

# 生成 24 级挑战 (每级 5bit, 值 0..23), 拼成 120bit -> 4 字
proc gen_chal {} {
    set v 0
    for {set s 0} {$s < 24} {incr s} {
        set st [expr {[xs32] % 24}]
        set v [expr {$v | ($st << (5*$s))}]
    }
    set w0 [expr {$v & 0xFFFFFFFF}]
    set w1 [expr {($v >> 32) & 0xFFFFFFFF}]
    set w2 [expr {($v >> 64) & 0xFFFFFFFF}]
    set w3 [expr {($v >> 96) & 0xFFFFFFFF}]
    return [list $w0 $w1 $w2 $w3]
}

proc wait_done {} {
    set t 0
    while {1} {
        set st [ev_rd 0x4000000C]
        if {[expr {$st & 2}]} break
        after 10
        incr t
        if {$t > 3000} { error "batch timeout (STATUS=[format 0x%08X $st])" }
    }
}

# ============================ 主流程 ============================
ev_init

set ver [ev_rd 0x40000000]
set cap [ev_rd 0x40000004]
set mag [ev_rd 0x40000018]
puts ">> SELFTEST VERSION=[format 0x%08X $ver] (expect 00030000)  CAP=[format 0x%08X $cap]  MAGIC=[format 0x%08X $mag]"
if {$ver != 0x00030000} { error "VERSION mismatch: spuf slave not responding" }
if {[expr {$mag & 0xFFFF0000}] != 0x5A5A0000} { error "MAGIC mismatch: read path broken" }

set fh [open $outfile w]
puts $fh "meta,board,$board_tag"
puts $fh "meta,bit,$bit"
puts $fh "meta,date,[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
puts $fh "meta,n_chal,$n_chal"
puts $fh "meta,reps,$reps"
puts $fh "meta,runs,$runs"

# 1) 生成挑战集 (固定种子) 并写入挑战 RAM
set ::xs_state 0x12345678
set challs {}
for {set i 0} {$i < $n_chal} {incr i} {
    lappend challs [gen_chal]
}
foreach c $challs { puts -nonewline $fh "" }
for {set i 0} {$i < $n_chal} {incr i} {
    lassign [lindex $challs $i] w0 w1 w2 w3
    puts $fh "chal,$i,[hex8 $w0],[hex8 $w1],[hex8 $w2],[hex8 $w3]"
    ev_wr 0x40000020 $w0
    ev_wr 0x40000024 $w1
    ev_wr 0x40000028 $w2
    ev_wr 0x4000002C $w3
    ev_wr 0x40000030 [expr {($i << 2) | 1}]
    if {$i % 64 == 0} { puts ">> chal push $i / $n_chal" }
}

# 2) 单发自检 x3 (全 0 挑战 = 每级恒等置换)
ev_wr 0x40000010 $reps
for {set u 0} {$u < 3} {incr u} {
    ev_wr 0x40000020 0
    ev_wr 0x40000024 0
    ev_wr 0x40000028 0
    ev_wr 0x4000002C 0
    ev_wr 0x40000008 4
    wait_done
    set lr [ev_rd 0x4000001C]
    puts $fh "single,$u,[hex8 $lr],0"
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
    puts ">> batch run $u / $runs done (read back $n_chal words)"
}

close $fh
puts ">> EVAL_DONE $outfile"
exit
