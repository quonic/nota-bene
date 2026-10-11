// Canvas and Node_Get_Text syscalls. Run by tests/host, which also checks
// the resulting pixels.
#include "test.h"

#define SYS_NODE_GET_TEXT     0x106
#define SYS_CANVAS_CLEAR      0x200
#define SYS_CANVAS_FILL_RECT  0x201
#define SYS_CANVAS_PUT_PIXELS 0x202

	.text
	.globl _start
_start:
	li	a0, 8			// Canvas
	SYSCALL	SYS_NODE_CREATE
	blez	a0, fail
	mv	s1, a0
	mv	a0, s1
	li	a1, 9			// Width
	la	a2, four
	li	a3, 1
	SYSCALL	SYS_NODE_SET_ATTR
	CHECK	1, a0, 0
	mv	a0, s1
	li	a1, 10			// Height
	la	a2, two
	li	a3, 1
	SYSCALL	SYS_NODE_SET_ATTR
	CHECK	2, a0, 0
	li	a0, 0			// Box
	SYSCALL	SYS_NODE_CREATE
	blez	a0, fail
	mv	s2, a0

	// canvas calls need a canvas
	mv	a0, s2
	li	a1, 0
	SYSCALL	SYS_CANVAS_CLEAR
	CHECK	3, a0, E_INVAL
	li	a0, 12345
	li	a1, 0
	SYSCALL	SYS_CANVAS_CLEAR
	CHECK	4, a0, E_BADH

	mv	a0, s1
	li	a1, 0x11223344
	SYSCALL	SYS_CANVAS_CLEAR
	CHECK	5, a0, 0
	mv	a0, s1			// pixels (1,0) and (2,0)
	li	a1, 1
	li	a2, 0
	li	a3, 2
	li	a4, 1
	li	a5, 0xAABBCCDD
	SYSCALL	SYS_CANVAS_FILL_RECT
	CHECK	6, a0, 0
	mv	a0, s1			// entirely clipped: a no-op, not an error
	li	a1, -50
	li	a2, -50
	li	a3, 10
	li	a4, 10
	li	a5, 0
	SYSCALL	SYS_CANVAS_FILL_RECT
	CHECK	7, a0, 0
	mv	a0, s1			// 4x2 canvas needs exactly 32 bytes
	la	a1, buf
	li	a2, 31
	SYSCALL	SYS_CANVAS_PUT_PIXELS
	CHECK	8, a0, E_INVAL
	mv	a0, s1
	li	a1, 0x10		// unmapped
	li	a2, 32
	SYSCALL	SYS_CANVAS_PUT_PIXELS
	CHECK	9, a0, E_FAULT

	// Node_Get_Text returns the full length and copies what fits
	mv	a0, s2
	la	a1, hello
	li	a2, 5
	SYSCALL	SYS_NODE_SET_TEXT
	CHECK	10, a0, 0
	mv	a0, s2
	la	a1, buf
	li	a2, 3
	SYSCALL	SYS_NODE_GET_TEXT
	CHECK	11, a0, 5
	la	t0, buf
	lbu	t1, 2(t0)
	CHECK	12, t1, 'l'
	lbu	t1, 3(t0)
	CHECK	13, t1, 0		// nothing written past the capacity
	mv	a0, s2
	li	a1, 0
	li	a2, 0
	SYSCALL	SYS_NODE_GET_TEXT
	CHECK	14, a0, 5
	mv	a0, s2
	la	a1, _start		// read-only
	li	a2, 5
	SYSCALL	SYS_NODE_GET_TEXT
	CHECK	15, a0, E_FAULT

	PASS
fail:
	FAIL	99

	.section .rodata
four:	.ascii	"4"
two:	.ascii	"2"
hello:	.ascii	"hello"

	.data
	.balign 16
buf:
	.zero	64
