// Event delivery: waits once with a timeout, then forever, and exits with
// the kind of the event it received (so a Quit event exits with 1).
#include "test.h"
	.text
	.globl _start
_start:
	la	a0, ev
	li	a1, 50			// 50 ms timeout
	SYSCALL	SYS_WAIT_EVENT
	CHECK	100, a0, 0		// nothing pushed: times out
	la	a0, ev
	li	a1, -1
	SYSCALL	SYS_WAIT_EVENT
	CHECK	101, a0, 1
	la	t0, ev
	lwu	a0, 0(t0)		// Event.kind
	ld	t1, 8(t0)		// Event.a
	CHECK	102, t1, 42
	li	a7, SYS_EXIT
	ecall

	.data
	.balign 16
ev:
	.zero	32
