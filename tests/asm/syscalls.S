// Syscall ABI behaviour, especially the error paths. Run by tests/host.
#include "test.h"

	.text
	.globl _start
_start:
	SYSCALL	SYS_ABI_VERSION
	CHECK	1, a0, 1

	// unknown syscall numbers
	SYSCALL	0x999
	CHECK	2, a0, E_NOSYS
	li	a7, 1
	slli	a7, a7, 40
	ecall
	CHECK	3, a0, E_NOSYS

	// Debug_Log validates its buffer, length and level
	li	a0, 0
	li	a1, 5
	li	a2, 0
	SYSCALL	SYS_DEBUG_LOG
	CHECK	4, a0, E_FAULT
	la	a0, msg
	li	a1, 0x100000
	li	a2, 0
	SYSCALL	SYS_DEBUG_LOG
	CHECK	5, a0, E_RANGE
	la	a0, msg
	li	a1, 2
	li	a2, 7
	SYSCALL	SYS_DEBUG_LOG
	CHECK	6, a0, E_INVAL
	la	a0, msg
	li	a1, 2
	li	a2, 0
	SYSCALL	SYS_DEBUG_LOG
	CHECK	7, a0, 0

	// handles
	li	a0, 12345
	SYSCALL	SYS_HANDLE_CLOSE
	CHECK	8, a0, E_BADH
	li	a0, 99
	SYSCALL	SYS_NODE_CREATE
	CHECK	9, a0, E_INVAL
	li	a0, 0			// Box
	SYSCALL	SYS_NODE_CREATE
	blez	a0, fail
	mv	s1, a0
	li	a0, 1			// Text
	SYSCALL	SYS_NODE_CREATE
	blez	a0, fail
	mv	s2, a0

	// text must be valid UTF-8 and readable
	mv	a0, s2
	la	a1, bad_utf8
	li	a2, 2
	SYSCALL	SYS_NODE_SET_TEXT
	CHECK	10, a0, E_INVAL
	mv	a0, s2
	li	a1, 0x10
	li	a2, 4
	SYSCALL	SYS_NODE_SET_TEXT
	CHECK	11, a0, E_FAULT
	mv	a0, s2
	la	a1, msg
	li	a2, 2
	SYSCALL	SYS_NODE_SET_TEXT
	CHECK	12, a0, 0
	mv	a0, s2
	li	a1, 999			// unknown attribute
	la	a2, msg
	li	a3, 2
	SYSCALL	SYS_NODE_SET_ATTR
	CHECK	13, a0, E_INVAL

	// tree structure: no cycles, no self-append
	mv	a0, s1
	mv	a1, s1
	SYSCALL	SYS_NODE_APPEND
	CHECK	14, a0, E_INVAL
	mv	a0, s1
	mv	a1, s2
	SYSCALL	SYS_NODE_APPEND
	CHECK	15, a0, 0
	mv	a0, s2
	mv	a1, s1
	SYSCALL	SYS_NODE_APPEND
	CHECK	16, a0, E_INVAL
	mv	a0, s2			// a node with a parent cannot be the root
	SYSCALL	SYS_ROOT_SET
	CHECK	17, a0, E_INVAL
	mv	a0, s1
	SYSCALL	SYS_ROOT_SET
	CHECK	18, a0, 0

	// closed handles go stale, even if the slot is reused
	mv	a0, s2
	SYSCALL	SYS_HANDLE_CLOSE
	CHECK	19, a0, 0
	mv	a0, s2
	SYSCALL	SYS_HANDLE_CLOSE
	CHECK	20, a0, E_BADH
	li	a0, 1
	SYSCALL	SYS_NODE_CREATE		// reuses s2's slot with a new generation
	blez	a0, fail
	beq	a0, s2, fail
	mv	a0, s2
	la	a1, msg
	li	a2, 2
	SYSCALL	SYS_NODE_SET_TEXT
	CHECK	21, a0, E_BADH

	// Mem_Grow
	li	a0, 0
	SYSCALL	SYS_MEM_GROW
	mv	s3, a0
	li	a0, 1
	SYSCALL	SYS_MEM_GROW
	CHECKR	22, a0, s3
	li	a0, 0
	SYSCALL	SYS_MEM_GROW
	sub	t0, a0, s3
	CHECK	23, t0, 4096
	li	t0, 0x5A
	sb	t0, 0(s3)		// the new page is writable
	li	t1, 4095
	add	t1, t1, s3
	sb	t0, 0(t1)
	li	a0, 1
	slli	a0, a0, 40
	SYSCALL	SYS_MEM_GROW
	CHECK	24, a0, E_NOMEM
	li	a0, -1
	SYSCALL	SYS_MEM_GROW
	CHECK	25, a0, E_INVAL

	// Random needs writable memory
	la	a0, buf
	li	a1, 16
	SYSCALL	SYS_RANDOM
	CHECK	26, a0, 16
	la	a0, _start
	li	a1, 16
	SYSCALL	SYS_RANDOM
	CHECK	27, a0, E_FAULT
	la	a0, buf
	li	a1, 0x100000
	SYSCALL	SYS_RANDOM
	CHECK	28, a0, E_RANGE

	// Wait_Event: bad pointer, then a poll with nothing queued
	li	a0, 0
	li	a1, 0
	SYSCALL	SYS_WAIT_EVENT
	CHECK	29, a0, E_FAULT
	la	a0, buf
	li	a1, 0
	SYSCALL	SYS_WAIT_EVENT
	CHECK	30, a0, 0

	// Time_Now is quantised to whole milliseconds
	SYSCALL	SYS_TIME_NOW
	bltz	a0, fail
	li	t0, 1000000
	rem	t1, a0, t0
	CHECK	31, t1, 0

	// No storage quota in the manifest: no storage
	SYSCALL	0x403
	CHECK	32, a0, E_PERM

	PASS

fail:
	FAIL	99

	.section .rodata
msg:
	.ascii	"ok"
bad_utf8:
	.byte	0xFF, 0xFE

	.data
	.balign 16
buf:
	.zero	64
