# apuf_diag.tcl — 仲裁 PUF 结构自诊断
#   1) 全 0 / 全 1 挑战: 响应应相反 (证明链在翻转、步进在起作用)
#   2) popcount 扫描: 响应 = sign(step·(2p-64)·s + Δ + 失配), 找翻转点 p* => 偏置 Δ
#   3) 平衡 popcount 处 TUNE_B 扫描
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ip_pr.gen/sources_1/ip/ps7_0/ps7_init.tcl
if {![file exists $ps7tcl]} { set ps7tcl $root/pr_out/ps7_init.tcl }
set bit $root/pr_out/apuf_ax7020.bit
set cab [lindex $argv 0]
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
proc wr {a v} { mwr -force $a $v }
proc wait_done {} {
    set t 0
    while {1} {
        if {[expr {[rd 0x4000000C] & 2}]} break
        after 10; incr t
        if {$t > 3000} { error "timeout" }
    }
}
proc mkchal {p} {
    # 前 p 位为 1 (高位在 CH_HI)
    set v 0
    for {set i 0} {$i < $p} {incr i} { set v [expr {$v | (1 << $i)}] }
    return $v
}
proc single {lo hi} {
    wr 0x40000020 $lo
    wr 0x40000024 $hi
    wr 0x40000008 4
    wait_done
    return [rd 0x4000001C]
}
puts ">> VERSION [format 0x%08X [rd 0x40000000]]"

# step 扫描 x popcount 扫描
foreach step {31 20 10 5 2 1} {
    wr 0x40000028 $step
    wr 0x4000002C 0
    wr 0x40000030 0
    wr 0x40000010 15
    set line "STEP=$step :"
    foreach p {0 8 16 24 28 30 32 34 36 40 48 56 64} {
        set hi [expr {[mkchal $p] >> 32}]
        # 64 位: 生成低 32 / 高 32
        set v [mkchal $p]
        set lo [expr {$v & 0xFFFFFFFF}]
        set hi [expr {($v >> 32) & 0xFFFFFFFF}]
        set w [single $lo $hi]
        set vote [expr {$w & 1}]
        set ones [expr {($w >> 2) & 0x3F}]
        append line "  p$p=${vote}(${ones}/15)"
    }
    puts ">> $line"
}
exit
