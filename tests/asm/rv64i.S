// RV64I base integer instructions.
#include "test.h"

	.text
	.globl _start
_start:
	// register-register arithmetic and logic
	li	a1, 5
	li	a2, -3
	add	a3, a1, a2
	CHECK	1, a3, 2
	sub	a3, a1, a2
	CHECK	2, a3, 8
	slt	a3, a2, a1
	CHECK	3, a3, 1
	sltu	a3, a2, a1
	CHECK	4, a3, 0
	xor	a3, a1, a2
	CHECK	5, a3, -8
	or	a3, a1, a2
	CHECK	6, a3, -3
	and	a3, a1, a2
	CHECK	7, a3, 5

	// shifts
	li	a4, 1
	slli	a3, a4, 63
	CHECK	8, a3, 0x8000000000000000
	srai	a5, a3, 63
	CHECK	9, a5, -1
	srli	a5, a3, 63
	CHECK	10, a5, 1
	li	a4, 4
	sll	a5, a1, a4
	CHECK	11, a5, 80
	sra	a5, a2, a4
	CHECK	12, a5, -1
	srl	a5, a2, a4
	CHECK	13, a5, 0x0FFFFFFFFFFFFFFF
	li	a4, 68		// shift amounts use the low 6 bits only
	sll	a5, a1, a4
	CHECK	14, a5, 80

	// immediates
	addi	a5, a1, -10
	CHECK	15, a5, -5
	slti	a5, a1, 6
	CHECK	16, a5, 1
	sltiu	a5, a2, 1
	CHECK	17, a5, 0
	xori	a5, a1, -1
	CHECK	18, a5, -6
	ori	a5, a1, 0x70
	CHECK	19, a5, 0x75
	andi	a5, a2, 0xF
	CHECK	20, a5, 0xD
	lui	a5, 0x80000
	CHECK	21, a5, 0xFFFFFFFF80000000
1:	auipc	a5, 0
	la	a6, 1b
	CHECKR	22, a5, a6

	// 32-bit (W) operations sign-extend their results
	li	a1, 0x7FFFFFFF
	addiw	a5, a1, 1
	CHECK	23, a5, 0xFFFFFFFF80000000
	addw	a5, a1, a1
	CHECK	24, a5, -2
	subw	a5, zero, a1
	CHECK	25, a5, -0x7FFFFFFF
	li	a1, 1
	slliw	a5, a1, 31
	CHECK	26, a5, 0xFFFFFFFF80000000
	sraiw	a6, a5, 31
	CHECK	27, a6, -1
	srliw	a6, a5, 31
	CHECK	28, a6, 1
	li	a4, 33
	sllw	a6, a1, a4
	CHECK	29, a6, 2
	srlw	a6, a5, a4
	CHECK	30, a6, 0x40000000
	sraw	a6, a5, a4
	CHECK	31, a6, 0xFFFFFFFFC0000000
	li	a1, 0x100000005	// upper bits are ignored
	addiw	a5, a1, 0
	CHECK	32, a5, 5

	// loads and stores, sign and zero extension
	la	s0, buf
	li	a1, -2
	sd	a1, 0(s0)
	lb	a5, 0(s0)
	CHECK	33, a5, -2
	lbu	a5, 0(s0)
	CHECK	34, a5, 0xFE
	lh	a5, 0(s0)
	CHECK	35, a5, -2
	lhu	a5, 0(s0)
	CHECK	36, a5, 0xFFFE
	lw	a5, 0(s0)
	CHECK	37, a5, -2
	lwu	a5, 0(s0)
	CHECK	38, a5, 0xFFFFFFFE
	ld	a5, 0(s0)
	CHECK	39, a5, -2
	sb	zero, 1(s0)
	lhu	a5, 0(s0)
	CHECK	40, a5, 0xFE
	li	a1, 0x12345678
	sw	a1, 8(s0)
	lw	a5, 8(s0)
	CHECK	41, a5, 0x12345678
	sh	a1, 12(s0)
	lhu	a5, 12(s0)
	CHECK	42, a5, 0x5678
	li	a1, 0x1122334455667788	// misaligned access is allowed
	sd	a1, 19(s0)
	ld	a5, 19(s0)
	CHECKR	43, a5, a1
	lbu	a5, 19(s0)
	CHECK	44, a5, 0x88

	// branches, not taken
	li	a1, 1
	li	a2, 2
	li	a3, -1
	beq	a1, a2, fail
	bne	a1, a1, fail
	blt	a2, a1, fail
	bge	a1, a2, fail
	bltu	a3, a1, fail
	bgeu	a1, a3, fail
	// branches, taken
	beq	a1, a1, 2f
	FAIL	45
2:	bne	a1, a2, 2f
	FAIL	46
2:	blt	a3, a1, 2f
	FAIL	47
2:	bge	a1, a3, 2f
	FAIL	48
2:	bltu	a1, a3, 2f
	FAIL	49
2:	bgeu	a3, a1, 2f
	FAIL	50
2:
	// jumps and links
	li	a5, 0
	jal	ra, set77
	CHECK	51, a5, 77
	la	t0, set88
	li	a5, 0
	jalr	ra, 0(t0)
	CHECK	52, a5, 88
	la	t0, set77
	addi	t0, t0, 1	// jalr clears bit 0 of the target
	li	a5, 0
	jalr	ra, 0(t0)
	CHECK	53, a5, 77
	addi	a5, zero, 9	// writes to x0 are discarded
	addi	zero, zero, 9
	CHECK	54, zero, 0

	fence
	fence.i
	PASS

fail:
	FAIL	99

set77:
	li	a5, 77
	ret
set88:
	li	a5, 88
	ret

	.data
	.balign 16
buf:
	.zero	64
