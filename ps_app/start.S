    .section .vectors, "ax"
    .global _vectors
_vectors:
    b   _start              @ reset
    b   _hang               @ undef
    b   _hang               @ svc
    b   _hang               @ prefetch abort
    b   skip_abort          @ data abort  -> 跳过故障指令后一条, 继续执行
    b   _hang               @ reserved
    b   _hang               @ irq
    b   _hang               @ fiq

    .text
    .global _start
_start:
    /* 关闭 bootloader 遗留的 MMU/cache, 回物理地址 */
    mrc p15, 0, r0, c1, c0, 0
    bic r0, r0, #0x1
    bic r0, r0, #0x4
    bic r0, r0, #0x1000
    mcr p15, 0, r0, c1, c0, 0
    isb
    mrs r0, cpsr
    bic r0, r0, #0x1F
    orr r0, r0, #0x13
    msr cpsr, r0
    ldr sp, =_stack_top
    bl  main
_hang:
    b   _hang

/* data abort 跳过处理: 入口 LR_abt = 故障指令+4; 返回 LR+4 = 故障+8,
   即跳过故障指令的下一条 (配合 puf_version 里的 NOP 填充, 函数仍能正常返回) */
skip_abort:
    adds pc, lr, #4
