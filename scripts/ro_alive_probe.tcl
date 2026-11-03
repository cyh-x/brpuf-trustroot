# ro_alive_probe.tcl — 判定 RO 是否翻转/使能/计数窗口是否运行
#   0x38 DBG_RO = {any1, any0, ro_en, 13'd0, cnt_b[15:0]}
#        any1=1 且 any0=1 -> cur_a 的 ro_raw 在窗口内既出现 1 也出现 0 = 在翻转
#        any1=0 且 any0=1 -> 恒 0 (环没振荡 或 使能没给)
#        ro_en=0         -> 测量期间使能根本没给
#   0x3C DBG_REF = 窗口内 AXI 时钟计数 (等于 win_cycles 说明 counting 门控正常)
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ip_pr.gen/sources_1/ip/ps7_0/ps7_init.tcl
if {![file exists $ps7tcl]} { set ps7tcl $root/pr_out/ps7_init.tcl }
set bit $root/pr_out/ropuf_ax7020.bit
set cab "210512180081"
if {$argc >= 1} { set cab [lindex $argv 0] }

connect
targets -set -filter "name =~ \"*Cortex-A9 MPCore #0*\" && jtag_cable_name =~ \"*$cab*\""
catch { rst -processor }; catch { stop }; after 200
uplevel #0 [list source $ps7tcl]
ps7_init
catch { ps7_post_config }
targets -set -filter "name =~ \"*xc7z020*\" && jtag_cable_name =~ \"*$cab*\""
fpga $bit
after 500
targets -set -filter "name =~ \"*JTAG2AXI*\" && jtag_cable_name =~ \"*$cab*\""

proc rd {a} { return [expr {"0x[lindex [mrd -force $a] 1]"}] }

puts ">> VERSION=[format 0x%08X [rd 0x40000000]]  CAP=[format 0x%08X [rd 0x40000004]]"
mwr -force 0x40000028 20          ;# WIN_LOG2=20 (2^20 拍)
mwr -force 0x40000010 1           ;# REPS=1
puts ">> WIN_LOG2 readback=[expr {[rd 0x40000028] & 0x1F}] (expect 20)"

foreach pair {0 1} {
    mwr -force 0x40000020 $pair
    mwr -force 0x40000024 [expr {($pair+1)%256}]
    mwr -force 0x4000002C $pair
    mwr -force 0x40000008 4       ;# single shot
    set t 0
    while {1} {
        set st [rd 0x4000000C]
        if {[expr {$st & 2}]} break
        after 10; incr t
        if {$t > 3000} { puts ">> TIMEOUT"; break }
    }
    set dbg [rd 0x40000038]
    set ref [rd 0x4000003C]
    set cnt [rd 0x40000030]
    set any1 [expr {($dbg >> 31) & 1}]
    set any0 [expr {($dbg >> 30) & 1}]
    set en   [expr {($dbg >> 29) & 1}]
    set cntb [expr {$dbg & 0xFFFF}]
    puts [format ">> PAIR %d/%d  cnt_a=%d  cnt_b_lo16=%d  ro_en=%d  saw1=%d saw0=%d  ref_win=%d  toggling=%s" \
          $pair [expr {($pair+1)%256}] [expr {$cnt & 0xFFFFFF}] $cntb $en $any1 $any0 [expr {$ref & 0xFFFFFF}] \
          [expr {($any1==1 && $any0==1) ? "YES" : "NO"}]]
}
exit
