ENTRY(_start)
MEMORY { OCM : ORIGIN = 0x00000000, LENGTH = 0x00030000 }
SECTIONS {
    .vectors : { *(.vectors) } > OCM
    .text    : { *(.text*)   } > OCM
    .rodata  : { *(.rodata*) } > OCM
    .data    : { *(.data*)   } > OCM
    .bss     : { *(.bss*) *(COMMON) } > OCM
    _stack_top = 0x0002F000;
}
