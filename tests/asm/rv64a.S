// A extension: LR/SC and AMOs on a single hart.
#include "test.h"

	.text
	.globl _start
_start:
	la	s0, buf
	li	a1, 10
	sd	a1, 0(s0)
	lr.d	a2, (s0)
	CHECK	1, a2, 10
	li	a3, 20
	sc.d	a4, a3, (s0)
	CHECK	2, a4, 0
	ld	a5, 0(s0)
	CHECK	3, a5, 20
	sc.d	a4, a3, (s0)	// reservation was consumed
	CHECK	4, a4, 1

	amoswap.d a2, a1, (s0)
	CHECK	5, a2, 20
	amoadd.d a2, a1, (s0)
	CHECK	6, a2, 10
	li	a1, 6
	amoand.d a2, a1, (s0)
	CHECK	7, a2, 20
	amoor.d	a2, a1, (s0)
	CHECK	8, a2, 4
	li	a1, 3
	amoxor.d a2, a1, (s0)
	CHECK	9, a2, 6
	li	a1, -1
	amomin.d a2, a1, (s0)
	CHECK	10, a2, 5
	li	a1, 3
	amomax.d a2, a1, (s0)
	CHECK	11, a2, -1
	li	a1, -1
	amominu.d a2, a1, (s0)
	CHECK	12, a2, 3
	amomaxu.d a2, a1, (s0)
	CHECK	13, a2, 3
	ld	a5, 0(s0)
	CHECK	14, a5, -1

	// word forms sign-extend
	li	a1, 0x7FFFFFFF
	sw	a1, 8(s0)
	addi	s1, s0, 8
	li	a3, 1
	amoadd.w a2, a3, (s1)
	CHECK	15, a2, 0x7FFFFFFF
	lw	a5, 8(s0)
	CHECK	16, a5, 0xFFFFFFFF80000000
	lr.w	a2, (s1)
	CHECK	17, a2, 0xFFFFFFFF80000000
	li	a3, 5
	sc.w	a4, a3, (s1)
	CHECK	18, a4, 0
	lw	a5, 8(s0)
	CHECK	19, a5, 5
	li	a3, -1
	amominu.w a2, a3, (s1)
	CHECK	20, a2, 5
	amomax.w a2, a3, (s1)
	CHECK	21, a2, 5
	amomin.w a2, a3, (s1)
	CHECK	22, a2, 5
	lw	a5, 8(s0)
	CHECK	23, a5, -1

	PASS

	.data
	.balign 16
buf:
	.zero	32
