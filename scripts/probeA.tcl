# probeA.tcl — 决定性诊断: A9 调试通路的内存写为何失败
#   记录 CPSR/SCTLR/TTBR0/DFAR/DFSR (核状态 + 数据中止地址), TrustZone OCM/DDR 配置,
#   然后做一次 OCM 写测试并再抓 DFAR/DFSR。失败会把 DAP 打死, 但信息已全部打印。
proc rd {a} { return [expr {"0x[lindex [mrd -force $a 1] 1]"}] }
proc rr {n} { if {[catch {set v [lindex [rrd $n] 1]} e]} { return "n/a" }; return "0x$v" }
proc dump {} {
    puts ">>   PC=[rr pc] CPSR=[rr cpsr] SCTLR=[rr sctlr] TTBR0=[rr ttbr0] DFAR=[rr dfar] DFSR=[rr dfsr]"
}

connect
# --- 恢复 DAP ---
set ok 0
for {set i 0} {$i < 6} {incr i} {
    if {![catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}}]} { set ok 1; break }
    puts ">> recover attempt $i"
    catch {targets 1; rst}
    after 5000
}
if {!$ok} { puts ">> SEL_FAIL (需要断电重启)"; exit 1 }
puts ">> TARGET_OK"

# --- 1. BootROM 运行中 (MMU 状态未知) ---
catch {stop}; after 300
puts ">> STATE1 halted-in-bootrom:"
dump
if {[catch {puts ">>   TZ_DDR_RAM(0xF8000900)=0x[format %08X [rd 0xF8000900]] TZ_OCM(0xF8000910)=0x[format %08X [rd 0xF8000910]]"} e]} { puts ">>   TZ read fail: $e" }

# --- 2. 核复位后 ---
catch {rst -processor}; after 400
catch {stop}; after 200
puts ">> STATE2 after core reset:"
dump
if {[catch {puts ">>   TZ_DDR_RAM=0x[format %08X [rd 0xF8000900]] TZ_OCM=0x[format %08X [rd 0xF8000910]]"} e]} { puts ">>   TZ read fail2: $e" }

# --- 3. OCM 读测试 (读一般不打死 DAP) ---
foreach a {0x00000000 0x00020000 0x00030000} {
    if {[catch {puts ">>   RD $a = 0x[format %08X [rd $a]]"} e]} { puts ">>   RD $a FAIL: $e" }
}

# --- 4. 单次 OCM 写测试 (最后做) ---
if {[catch {mwr -force 0x00020000 1 0x13572468; puts ">> OCM_WR_OK rw=0x[format %08X [rd 0x00020000]]"} e]} {
    puts ">> OCM_WR_FAIL: $e"
    catch {puts ">>   DFAR=[rr dfar] DFSR=[rr dfsr] SCTLR=[rr sctlr]"}
}
exit
