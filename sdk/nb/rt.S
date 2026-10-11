// Page runtime support that Odin cannot express on freestanding_riscv64:
// the syscall trap (Odin has no inline asm for riscv64 and refuses
// intrinsics.syscall on freestanding targets) and the libc memory routines
// LLVM emits calls to. These are written in assembly so the compiler cannot
// turn their loops back into calls to themselves.

	.option nopic
	.text

// isize nb_syscall(usize nr, usize a0, a1, a2, a3, a4, a5)
// Linux RISC-V convention: number in a7, arguments in a0..a5, result in a0.
	.globl nb_syscall
	.type nb_syscall, @function
nb_syscall:
	mv	t0, a0
	mv	a0, a1
	mv	a1, a2
	mv	a2, a3
	mv	a3, a4
	mv	a4, a5
	mv	a5, a6
	mv	a7, t0
	ecall
	ret
	.size nb_syscall, . - nb_syscall

// void *memset(void *dst, int c, size_t n)
	.globl memset
	.type memset, @function
memset:
	mv	t0, a0
	beqz	a2, 2f
1:	sb	a1, 0(t0)
	addi	t0, t0, 1
	addi	a2, a2, -1
	bnez	a2, 1b
2:	ret
	.size memset, . - memset

// void *memcpy(void *dst, const void *src, size_t n)
// void *memmove(void *dst, const void *src, size_t n)
// One routine for both: copies forwards unless dst overlaps src from above.
	.globl memcpy
	.type memcpy, @function
	.globl memmove
	.type memmove, @function
memcpy:
memmove:
	beq	a0, a1, 3f
	bltu	a1, a0, 4f
	mv	t0, a0
1:	beqz	a2, 3f
	lbu	t1, 0(a1)
	sb	t1, 0(t0)
	addi	a1, a1, 1
	addi	t0, t0, 1
	addi	a2, a2, -1
	j	1b
4:	add	t0, a0, a2
	add	a1, a1, a2
5:	beqz	a2, 3f
	addi	a1, a1, -1
	addi	t0, t0, -1
	lbu	t1, 0(a1)
	sb	t1, 0(t0)
	addi	a2, a2, -1
	j	5b
3:	ret
	.size memcpy, . - memcpy

// int memcmp(const void *a, const void *b, size_t n)
	.globl memcmp
	.type memcmp, @function
memcmp:
	beqz	a2, 2f
1:	lbu	t0, 0(a0)
	lbu	t1, 0(a1)
	bne	t0, t1, 3f
	addi	a0, a0, 1
	addi	a1, a1, 1
	addi	a2, a2, -1
	bnez	a2, 1b
2:	li	a0, 0
	ret
3:	sub	a0, t0, t1
	ret
	.size memcmp, . - memcmp
