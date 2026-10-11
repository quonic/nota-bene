// Jumping into writable data must fault (W^X).
#include "test.h"
	.text
	.globl _start
_start:
	la	t0, code
	jr	t0
	PASS
	.data
	.balign 4
code:
	.word	0x00000013	// a valid nop, but in a non-executable page
