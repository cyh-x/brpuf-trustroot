# run_eval_sram.tcl — 锁存型 SRAM-类 PUF 板上评估 (xsdb)
# 用法: xsdb.bat scripts\run_eval_sram.tcl <outfile> <runs> <board_tag> <cable>
#   每轮 = 强制->释放->稳定->扫描 256 单元; CSV: resp,run,cell,bit
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ip_pr.gen/sources_1/ip/ps7_0/ps7_init.tcl
if {![file exists $ps7tcl]} { set ps7tcl $root/pr_out/ps7_init.tcl }
set bit $root/pr_out/sram_ax7020.bit
set outfile [lindex $argv 0]
set runs    [lindex $argv 1]
set board_tag [lindex $argv 2]
set cab [lindex $argv 3]
if {![file isdirectory [file dirname $outfile]]} {
    set outfile [file join $root [file tail $outfile]]
}
puts ">> SRAM_EVAL OUT=$outfile RUNS=$runs TAG=$board_tag"

proc ev_select {pat} {
    global cab
    set f "name =~ \"$pat\" && jtag_cable_name =~ \"*$cab*\""
    if {[catch {targets -set -filter $f} e]} { error "cannot select '$pat': $e" }
}
proc ev_rd {addr} { return [expr {"0x[lindex [mrd -force $addr] 1]"}] }
proc ev_wr {addr val} { mwr -force $addr $val }

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
puts ">> SELFTEST VERSION=[format 0x%08X $ver] (expect 00070000)  MAGIC=[format 0x%08X $mag]"
if {$ver != 0x00070000} { error "VERSION mismatch" }

set fh [open $outfile w]
puts $fh "meta,board,$board_tag"
puts $fh "meta,bit,$bit"
puts $fh "meta,date,[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
puts $fh "meta,n_chal,256"
puts $fh "meta,reps,1"
puts $fh "meta,runs,$runs"
for {set i 0} {$i < 256} {incr i} { puts $fh "chal,$i,$i,0" }

for {set u 0} {$u < $runs} {incr u} {
    ev_wr 0x40000008 1
    set t 0
    while {1} {
        set st [ev_rd 0x4000000C]
        if {[expr {$st & 2}]} break
        after 10; incr t
        if {$t > 2000} { error "timeout" }
    }
    for {set i 0} {$i < 256} {incr i} {
        set w [ev_rd [expr {0x40000100 + 4*$i}]]
        puts $fh "resp,$u,$i,[format %08X [expr {$w & 0xFFFFFFFF}]]"
    }
    puts ">> run $u / $runs done"
}
close $fh
puts ">> SRAM_EVAL_DONE $outfile"
exit
