SECTIONS
{

    ROM_BASE = 0x10000; /* ... but actually position independent, maxilla */
    ROM_SIZE = 0x10000;
    STACK_TOP = 0x88010000;

    . = ROM_BASE;
    .text.hang : { *(.text.hang) }

    . = ROM_BASE + 0x40;
    .text.start : { *(.text.start) }

    . = ROM_BASE + 0x80;
    .text.hang80 : { *(.text.hang80) }

    . = ROM_BASE + 0x100;
    .text.hang100 : { *(.text.hang100) }

    . = ALIGN(8);

    /* C code goes after the fixed boot slots */
    .text : {
        *(.text*)
    }

    . = ALIGN(8);

    /* constants from C */
    .rodata : {
        *(.rodata*)
    }

    . = ALIGN(8);

    /* globals that start with a value */
    .data : {
        *(.data*)
    }

    . = ALIGN(8);

    /* globals that should start as zero */
    __bss_start = .;
    .bss : {
        *(.bss*)
        *(COMMON)
    }
    __bss_end = .;

    /* stack address used before calling bootrom_main */
    _stack_top = STACK_TOP;
}