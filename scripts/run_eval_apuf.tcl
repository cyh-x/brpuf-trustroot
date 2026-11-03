# run_eval_apuf.tcl — PDL 仲裁 PUF 板上评估 (xsdb)
# 用法: xsdb.bat scripts\run_eval_apuf.tcl <outfile> <n_chal> <reps> <runs> <board_tag> <cable> [mode]
#   mode = sweep        : TUNE_B 0..31 扫描, 每档 64 随机挑战, 输出响应平衡度
#         rand (默认)  : 随机 64bit 挑战批量评估
# 寄存器: 0x00 VER(0x00050000) 0x08 CTRL 0x0C STATUS 0x10 REPS 0x14 NCHAL
#         0x18 MAGIC 0x1C LAST_RAW 0x20 CH_LO 0x24 CH_HI 0x28 STEP
#         0x2C TUNE_T 0x30 TUNE_B 0x34 CH_PUSH 0x100+4i RESP[i]
# CSV: meta,* / chal,i,lo,hi / resp,run,idx,w   w[0]=vote w[1]=unst w[7:2]=ones(裕量)
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ip_pr.gen/sources_1/ip/ps7_0/ps7_init.tcl
if {![file exists $ps7tcl]} { set ps7tcl $root/pr_out/ps7_init.tcl }
set bit $root/pr_out/apuf_ax7020.bit

set outfile [lindex $argv 0]
set n_chal  [lindex $argv 1]
set reps    [lindex $argv 2]
set runs    [lindex $argv 3]
set board_tag [lindex $argv 4]
set cab [lindex $argv 5]
set mode "rand"
if {$argc >= 7} { set mode [lindex $argv 6] }
if {![file isdirectory [file dirname $outfile]]} {
    set outfile [file join $root [file tail $outfile]]
}
puts ">> APUF_EVAL OUT=$outfile N=$n_chal REPS=$reps RUNS=$runs TAG=$board_tag MODE=$mode"

proc ev_select {pat} {
    global cab
    set f "name =~ \"$pat\" && jtag_cable_name =~ \"*$cab*\""
    if {[catch {targets -set -filter $f} e]} { error "cannot select '$pat': $e" }
}
proc ev_rd {addr} { return [expr {"0x[lindex [mrd -force $addr] 1]"}] }
proc ev_wr {addr val} { mwr -force $addr $val }
proc hex8 {v} { return [format %08X [expr {$v & 0xFFFFFFFF}]] }

# xorshift64 挑战 PRNG (固定种子 -> 双板同挑战)
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
puts ">> SELFTEST VERSION=[format 0x%08X $ver] (expect 00050000)  MAGIC=[format 0x%08X $mag]"
if {$ver != 0x00050000} { error "VERSION mismatch" }
if {[expr {$mag & 0xFFFF0000}] != 0x5A5A0000} { error "MAGIC mismatch" }

proc push_challs {n} {
    global xs
    set xs 88172645463325252
    set lo [list]; set hi [list]
    for {set i 0} {$i < $n} {incr i} {
        set v [xs64]
        lappend lo [expr {$v & 0xFFFFFFFF}]
        lappend hi [expr {($v >> 32) & 0xFFFFFFFF}]
    }
    for {set i 0} {$i < $n} {incr i} {
        ev_wr 0x40000020 [lindex $lo $i]
        ev_wr 0x40000024 [lindex $hi $i]
        ev_wr 0x40000034 [expr {($i << 2) | 1}]
    }
    return [list $lo $hi]
}
proc wait_done {} {
    set t 0
    while {1} {
        set st [ev_rd 0x4000000C]
        if {[expr {$st & 2}]} break
        after 10; incr t
        if {$t > 3000} { error "timeout" }
    }
}

if {$mode eq "sweep"} {
    puts ">> TUNE_B sweep (64 chals x 15 reps each):"
    set n 64
    push_challs $n
    ev_wr 0x40000010 15
    ev_wr 0x40000014 $n
    foreach tt {0} tb {0 4 8 12 16 20 24 28 31} {
        ev_wr 0x4000002C $tt
        ev_wr 0x40000030 $tb
        ev_wr 0x40000008 1
        wait_done
        set ones 0
        for {set i 0} {$i < $n} {incr i} {
            set w [ev_rd [expr {0x40000100 + 4*$i}]]
            if {[expr {$w & 1}]} { incr ones }
        }
        puts ">> TUNE_T=$tt TUNE_B=$tb  balance(=1) $ones/$n = [expr {round(1000.0*$ones/$n)/10.0}]%"
    }
    exit
}

# ---- rand 全量评估 ----
set fh [open $outfile w]
puts $fh "meta,board,$board_tag"
puts $fh "meta,bit,$bit"
puts $fh "meta,date,[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
puts $fh "meta,n_chal,$n_chal"
puts $fh "meta,reps,$reps"
puts $fh "meta,runs,$runs"

lassign [push_challs $n_chal] los his
for {set i 0} {$i < $n_chal} {incr i} {
    puts $fh "chal,$i,[hex8 [lindex $his $i]],[hex8 [lindex $los $i]]"
}
ev_wr 0x40000010 $reps
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
puts ">> APUF_EVAL_DONE $outfile"
exit
