// For the GDB stub tests: stops on an ebreak, then exits with 7 plus the
// dword at `value`, which a debugger may change. a2 holds the address of
// `target` (a breakpoint spot) and a3 the address of `value`.
#include "test.h"
	.text
	.globl _start
_start:
	la	a2, target
	la	a3, value
	li	a0, 1
	li	a1, 2
	ebreak
	add	a0, a0, a1
target:
	addi	a0, a0, 4
	ld	a4, 0(a3)
	add	a0, a0, a4
	li	a7, SYS_EXIT
	ecall

	.data
	.balign 8
value:
	.dword	0
