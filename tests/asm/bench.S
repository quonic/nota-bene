// Interpreter benchmark. Never terminates; the host's instruction budget stops
// it. Each pass runs a sieve (byte loads and stores, branches), a recursive
// fib (calls, returns, the stack), an integer hash (mul, div, rem, OP-32) and
// a floating-point loop, and checks every result, so a decoder bug exits
// with the failing check's number instead of looping.
//
//   time build/nbrun --budget 1000000000 build/tests/bench.c.elf
#include "test.h"

#define N 8192

	.text
	.globl _start
_start:
pass:
	// Sieve of Eratosthenes: count the primes below N.
	la	s0, sieve
	li	s1, N
	li	a6, 1
	mv	t0, s0
	add	t1, s0, s1
1:	sb	zero, 0(t0)
	addi	t0, t0, 1
	bltu	t0, t1, 1b
	li	t0, 2
	li	s2, 0
2:	add	t2, s0, t0
	lbu	t3, 0(t2)
	bnez	t3, 4f
	addi	s2, s2, 1
	mul	t4, t0, t0
	bgeu	t4, s1, 4f
3:	add	t5, s0, t4
	sb	a6, 0(t5)
	add	t4, t4, t0
	bltu	t4, s1, 3b
4:	addi	t0, t0, 1
	bltu	t0, s1, 2b
	CHECK	1, s2, 1028

	li	a0, 15
	call	fib
	CHECK	2, a0, 610

	// 64-bit LCG folded into an accumulator.
	li	a1, 12345
	li	a2, 0
	li	a3, 6364136223846793005
	li	a4, 1442695040888963407
	li	a5, 1000003
	li	t3, 977
	li	t0, 1000
5:	mul	a1, a1, a3
	add	a1, a1, a4
	divu	t1, a1, a5
	add	a2, a2, t1
	remu	t2, a1, t3
	xor	a2, a2, t2
	addw	t4, a2, t1
	srai	t4, t4, 3
	add	a2, a2, t4
	addi	t0, t0, -1
	bnez	t0, 5b
	CHECK	3, a2, 0x217ac5606b0efa

	// sum of i * 0.5 for i in 0..999
	fcvt.d.l	fa0, zero
	li	t0, 0x3FE0000000000000
	fmv.d.x	fa1, t0
	li	t0, 1000
	li	t1, 0
6:	fcvt.d.l	fa2, t1
	fmadd.d	fa0, fa2, fa1, fa0
	addi	t1, t1, 1
	blt	t1, t0, 6b
	fcvt.l.d	t2, fa0, rtz
	CHECK	4, t2, 249750

	j	pass

fib:
	li	t0, 2
	bltu	a0, t0, 9f
	addi	sp, sp, -32
	sd	ra, 24(sp)
	sd	s0, 16(sp)
	sd	s1, 8(sp)
	mv	s0, a0
	addi	a0, s0, -1
	call	fib
	mv	s1, a0
	addi	a0, s0, -2
	call	fib
	add	a0, a0, s1
	ld	s1, 8(sp)
	ld	s0, 16(sp)
	ld	ra, 24(sp)
	addi	sp, sp, 32
9:	ret

	.bss
sieve:
	.zero	N
