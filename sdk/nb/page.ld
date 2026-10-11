/*
 * Linker script for pages. Matches the layout the browser's loader expects:
 * nothing below 0x10000 (null guard), and text, read-only data and writable
 * data on separate pages so each can be protected RX, R or RW.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
	. = 0x10000;

	.text : ALIGN(4096) {
		*(.text._start)
		*(.text .text.*)
	}

	. = ALIGN(4096);
	.rodata : {
		*(.rodata .rodata.* .srodata .srodata.*)
		*(.odinti)
	}
	.eh_frame : { *(.eh_frame) }

	. = ALIGN(4096);
	.data : {
		*(.data .data.* .sdata .sdata.*)
	}
	.bss : {
		*(.sbss .sbss.* .bss .bss.* COMMON)
	}
	_end = .;

	/DISCARD/ : { *(.comment) *(.note .note.*) }
}
