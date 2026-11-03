ENTRY(_start)
MEMORY { DDR : ORIGIN = 0x00100000, LENGTH = 0x00100000 }
SECTIONS {
    .vectors : { *(.vectors) } > DDR
    .text    : { *(.text*)   } > DDR
    .rodata  : { *(.rodata*) } > DDR
    .data    : { *(.data*)   } > DDR
    .bss     : { *(.bss*) *(COMMON) } > DDR
    _stack_top = 0x001F0000;
}
