// M extension: multiply and divide, including the RISC-V edge cases.
#include "test.h"

	.text
	.globl _start
_start:
	li	a1, 7
	li	a2, -3
	mul	a3, a1, a2
	CHECK	1, a3, -21
	mulh	a3, a1, a2
	CHECK	2, a3, -1
	mulhu	a3, a1, a2
	CHECK	3, a3, 6
	mulhsu	a3, a2, a1
	CHECK	4, a3, -1
	mulhsu	a3, a1, a2
	CHECK	5, a3, 6
	li	t0, 0x7FFFFFFFFFFFFFFF
	mulh	a3, t0, t0
	CHECK	6, a3, 0x3FFFFFFFFFFFFFFF

	div	a3, a1, a2
	CHECK	7, a3, -2
	rem	a3, a1, a2
	CHECK	8, a3, 1
	divu	a3, a2, a1
	CHECK	9, a3, 2635249153387078801
	remu	a3, a2, a1
	CHECK	10, a3, 6

	// division by zero
	div	a3, a1, zero
	CHECK	11, a3, -1
	divu	a3, a1, zero
	CHECK	12, a3, -1
	rem	a3, a1, zero
	CHECK	13, a3, 7
	remu	a3, a1, zero
	CHECK	14, a3, 7

	// signed overflow
	li	t0, 0x8000000000000000
	li	t1, -1
	div	a3, t0, t1
	CHECK	15, a3, 0x8000000000000000
	rem	a3, t0, t1
	CHECK	16, a3, 0

	// 32-bit variants
	li	a1, 0x10000
	mulw	a3, a1, a1
	CHECK	17, a3, 0
	li	a1, 0x7FFFFFFF
	li	a2, 2
	mulw	a3, a1, a2
	CHECK	18, a3, -2
	li	a1, -7
	divw	a3, a1, a2
	CHECK	19, a3, -3
	remw	a3, a1, a2
	CHECK	20, a3, -1
	li	a1, -1
	divuw	a3, a1, a2
	CHECK	21, a3, 0x7FFFFFFF
	remuw	a3, a1, a2
	CHECK	22, a3, 1
	li	a1, -7
	divw	a3, a1, zero
	CHECK	23, a3, -1
	divuw	a3, a1, zero
	CHECK	24, a3, -1
	remw	a3, a1, zero
	CHECK	25, a3, -7
	lui	a1, 0x80000
	li	a2, -1
	divw	a3, a1, a2
	CHECK	26, a3, 0xFFFFFFFF80000000
	remw	a3, a1, a2
	CHECK	27, a3, 0
	li	a1, 0x100000005	// upper bits are ignored
	li	a2, 2
	divw	a3, a1, a2
	CHECK	28, a3, 2

	PASS
