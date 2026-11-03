# crypto_test.tcl — 集成信任根上板测试: PUF 自检 + AES KAT + TRNG 采样
# 用法: xsdb.bat scripts\crypto_test.tcl <cable>
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_66m.tcl
set bit $root/pr_out/crypto_ax7020.bit
set cab [lindex $argv 0]

proc rd {a} { return [expr {"0x[lindex [mrd -force $a] 1]"}] }
proc wr {a v} { mwr -force $a $v }

connect
targets -set -filter "name =~ \"*Cortex-A9 MPCore #0*\" && jtag_cable_name =~ \"*$cab*\""
catch { rst -processor }; catch { stop }; after 200
uplevel #0 [list source $ps7tcl]
ps7_init
catch { ps7_post_config }
puts ">> FCLK0_CTRL = [format 0x%08X [rd 0xF8000170]] (00400606 = 66.7MHz)"
targets -set -filter "name =~ \"*xc7z020*\" && jtag_cable_name =~ \"*$cab*\""
fpga $bit
after 500
targets -set -filter "name =~ \"*JTAG2AXI*\" && jtag_cable_name =~ \"*$cab*\""

# ==== 1. 三从机自检 (经 demux) ====
puts ">> [1] PUF  @0x40000000 VERSION = [format 0x%08X [rd 0x40000000]] (expect 00090000)"
puts ">>     PUF  MAGIC = [format 0x%08X [rd 0x40000018]] (expect 5A5Axxxx)"
# AES 有无 ID 寄存器未知, 先读 CTRL/STATUS
puts ">>     AES  @0x40010000 STATUS(0x34) = [format 0x%08X [rd 0x40010034]]"
puts ">>     TRNG @0x40020000 STATUS(0x04) = [format 0x%08X [rd 0x40020004]]"

# ==== 2. AES-256 已知答案测试 (NIST ECB-256 向量) ====
# 流式接口: CTRL[0]=start [1]=encrypt [2]=in_valid [3]=in_last [31:16]=keep
# STATUS:   [0]=busy [1]=done [2]=in_ready [3]=out_valid
puts ">> [2] AES-256 KAT"
set key [list 0x603deb10 0x15ca71be 0x2b73aef0 0x857d7781 0x1f352c07 0x3b6108d7 0x2d9810a3 0x0914dff4]
set pt  [list 0x6bc1bee2 0x2e409f96 0xe93d7e11 0x7393172a]
set ct_exp [list 0xf3eed1bd 0xb5d2a03c 0x064b5a7e 0x3db181f8]
for {set i 0} {$i < 8} {incr i} { wr [expr {0x40010000 + $i*4}] [lindex $key $i] }
# start 脉冲 (encrypt=1)
wr 0x40010030 0x03
wr 0x40010030 0x02
set t 0
while {([rd 0x40010034] & 4) == 0} { after 5; incr t; if {$t > 400} { puts ">> AES in_ready 超时 STATUS=[format 0x%08X [rd 0x40010034]]"; break } }
puts ">>     in_ready OK (STATUS=[format 0x%08X [rd 0x40010034]])"
for {set i 0} {$i < 4} {incr i} { wr [expr {0x40010020 + $i*4}] [lindex $pt $i] }
# 15 字节有效: keep=0xFFFE, in_last=1, in_valid=1, encrypt=1 -> (0xFFFE<<16)|0x0E
set enc_ctrl 0xFFFE000E
wr 0x40010030 $enc_ctrl
wr 0x40010030 0xFFFE000A
set t 0
while {[rd 0x40010034] & 1} { after 5; incr t; if {$t > 800} { break } }
set st [rd 0x40010034]
puts ">>     done STATUS=[format 0x%08X $st] (bit1=done bit3=out_valid)"
set ct {}
for {set i 0} {$i < 4} {incr i} { lappend ct [rd [expr {0x40010038 + $i*4}]] }
puts ">>     ct     = [format %08X%08X%08X%08X {*}$ct]"
puts ">>     expect = [format %08X%08X%08X%08X {*}$ct_exp]"
set ok 1
for {set i 0} {$i < 4} {incr i} { if {[lindex $ct $i] != [lindex $ct_exp $i]} { set ok 0 } }
puts ">>     AES KAT: [expr {$ok ? "PASS" : "FAIL"}]"
# 解密回路验证
wr 0x40010030 0x01
wr 0x40010030 0x00
set t 0
while {([rd 0x40010034] & 4) == 0} { after 5; incr t; if {$t > 400} { break } }
for {set i 0} {$i < 4} {incr i} { wr [expr {0x40010020 + $i*4}] [lindex $ct $i] }
set dec_ctrl 0xFFFF000C
wr 0x40010030 $dec_ctrl
wr 0x40010030 0xFFFF0008
set t 0
while {[rd 0x40010034] & 1} { after 5; incr t; if {$t > 800} { break } }
set pt2 {}
for {set i 0} {$i < 4} {incr i} { lappend pt2 [rd [expr {0x40010038 + $i*4}]] }
set okd 1
for {set i 0} {$i < 4} {incr i} { if {[lindex $pt2 $i] != [lindex $pt $i]} { set okd 0 } }
puts ">>     解密回环: [expr {$okd ? "PASS" : "FAIL"}] (pt=[format %08X%08X%08X%08X {*}$pt2])"

# ==== 3. TRNG 采样 128 字节 ====
puts ">> [3] TRNG 采样"
wr 0x40020000 0x01   ;# enable
set keys {}
set nkeys 8
for {set k 0} {$k < $nkeys} {incr k} {
    set t 0
    while {([rd 0x40020004] & 2) == 0} { after 10; incr t; if {$t > 5000} { puts ">> TRNG key_valid 超时"; break } }
    set w0 {}
    for {set i 0} {$i < 8} {incr i} { lappend w0 [rd [expr {0x40020010 + $i*4}]] }
    lappend keys $w0
    wr 0x40020000 0x02   ;# key_ready 脉冲 (bit1), 使能位 bit0 保持 0? -> 写 0x02: bit0=0 会关 TRNG!
    wr 0x40020000 0x03   ;# 立即回 enable+ack? 参考: 单拍 ACK 由 bit1 写脉冲产生
    after 5
    wr 0x40020000 0x01
    after 30
}
puts ">>     采集 [llength $keys] 个 256-bit 密钥:"
set fh [open $root/logs/trng_sample.csv w]
foreach w0 $keys {
    set line ""
    foreach x $w0 { append line [format %08X $x] }
    puts $fh $line
    puts ">>     $line"
}
close $fh
set fh [open $root/logs/trng_sample.csv w]
foreach w0 $bytes { puts $fh [format %08X $w0] }
close $fh
puts ">> CRYPTO_TEST_DONE"
exit
