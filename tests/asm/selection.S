// Input_Get_Selection, Input_Set_Selection and Input_Focus, on an Input and
// a Text_Area. Run by
// tests/host, which also checks the node and the focus request left behind.
#include "test.h"

#define SYS_INPUT_GET_SELECTION 0x107
#define SYS_INPUT_SET_SELECTION 0x108
#define SYS_INPUT_FOCUS         0x109

	.text
	.globl _start
_start:
	li	a0, 6			// Input
	SYSCALL	SYS_NODE_CREATE
	blez	a0, fail
	mv	s1, a0
	li	a0, 0			// Box
	SYSCALL	SYS_NODE_CREATE
	blez	a0, fail
	mv	s2, a0

	// a new Input has its caret at 0
	mv	a0, s1
	la	a1, sel
	SYSCALL	SYS_INPUT_GET_SELECTION
	CHECK	1, a0, 0
	la	t0, sel
	ld	t1, 0(t0)
	CHECK	2, t1, 0
	ld	t1, 8(t0)
	CHECK	3, t1, 0

	mv	a0, s1
	la	a1, text		// "aé!": é is bytes 1..2
	li	a2, 4
	SYSCALL	SYS_NODE_SET_TEXT
	CHECK	4, a0, 0

	// anchor and caret come back as set, in either order
	mv	a0, s1
	li	a1, 4
	li	a2, 1
	SYSCALL	SYS_INPUT_SET_SELECTION
	CHECK	5, a0, 0
	mv	a0, s1
	la	a1, sel
	SYSCALL	SYS_INPUT_GET_SELECTION
	CHECK	6, a0, 0
	la	t0, sel
	ld	t1, 0(t0)
	CHECK	7, t1, 4
	ld	t1, 8(t0)
	CHECK	8, t1, 1

	// bad offsets leave the selection alone
	mv	a0, s1
	li	a1, 0
	li	a2, 5			// past the end
	SYSCALL	SYS_INPUT_SET_SELECTION
	CHECK	9, a0, E_RANGE
	mv	a0, s1
	li	a1, -1
	li	a2, 0
	SYSCALL	SYS_INPUT_SET_SELECTION
	CHECK	10, a0, E_RANGE
	mv	a0, s1
	li	a1, 2			// inside é
	li	a2, 0
	SYSCALL	SYS_INPUT_SET_SELECTION
	CHECK	11, a0, E_INVAL

	// only Inputs have a selection
	mv	a0, s2
	li	a1, 0
	li	a2, 0
	SYSCALL	SYS_INPUT_SET_SELECTION
	CHECK	12, a0, E_INVAL
	mv	a0, s2
	la	a1, sel
	SYSCALL	SYS_INPUT_GET_SELECTION
	CHECK	13, a0, E_INVAL
	li	a0, 12345
	la	a1, sel
	SYSCALL	SYS_INPUT_GET_SELECTION
	CHECK	14, a0, E_BADH
	mv	a0, s1
	la	a1, _start		// read-only
	SYSCALL	SYS_INPUT_GET_SELECTION
	CHECK	15, a0, E_FAULT

	// shorter text pulls the selection back inside it
	mv	a0, s1
	la	a1, text
	li	a2, 1			// "a"
	SYSCALL	SYS_NODE_SET_TEXT
	CHECK	16, a0, 0
	mv	a0, s1
	la	a1, sel
	SYSCALL	SYS_INPUT_GET_SELECTION
	la	t0, sel
	ld	t1, 0(t0)
	CHECK	17, t1, 1
	ld	t1, 8(t0)
	CHECK	18, t1, 1

	// only an Input in the tree under the root can take focus
	mv	a0, s1
	SYSCALL	SYS_INPUT_FOCUS
	CHECK	19, a0, E_INVAL		// detached
	mv	a0, s2
	SYSCALL	SYS_ROOT_SET
	CHECK	20, a0, 0
	mv	a0, s2
	mv	a1, s1
	SYSCALL	SYS_NODE_APPEND
	CHECK	21, a0, 0
	mv	a0, s2
	SYSCALL	SYS_INPUT_FOCUS
	CHECK	22, a0, E_INVAL		// a Box
	li	a0, 12345
	SYSCALL	SYS_INPUT_FOCUS
	CHECK	23, a0, E_BADH
	li	a0, 0			// focus off the page's Inputs
	SYSCALL	SYS_INPUT_FOCUS
	CHECK	24, a0, 0
	mv	a0, s1
	SYSCALL	SYS_INPUT_FOCUS
	CHECK	25, a0, 0

	// a Text_Area takes the same calls; offsets run across its lines
	li	a0, 14			// Text_Area
	SYSCALL	SYS_NODE_CREATE
	blez	a0, fail
	mv	s3, a0
	mv	a0, s3
	la	a1, lines		// "a\nb"
	li	a2, 3
	SYSCALL	SYS_NODE_SET_TEXT
	CHECK	26, a0, 0
	mv	a0, s3
	li	a1, 3
	li	a2, 1
	SYSCALL	SYS_INPUT_SET_SELECTION
	CHECK	27, a0, 0
	mv	a0, s3
	la	a1, sel
	SYSCALL	SYS_INPUT_GET_SELECTION
	CHECK	28, a0, 0
	la	t0, sel
	ld	t1, 0(t0)
	CHECK	29, t1, 3
	ld	t1, 8(t0)
	CHECK	30, t1, 1
	mv	a0, s3
	SYSCALL	SYS_INPUT_FOCUS
	CHECK	31, a0, E_INVAL		// detached, so the Input keeps the request

	PASS
fail:
	FAIL	99

	.section .rodata
text:	.ascii	"a\303\251!"
lines:	.ascii	"a\nb"

	.data
	.balign 16
sel:
	.zero	16
