// Storage syscalls with a 64-byte quota (see storage.manifest). Run by
// tests/host, which then checks what was persisted.
#include "test.h"

#define SYS_STORAGE_GET    0x400
#define SYS_STORAGE_SET    0x401
#define SYS_STORAGE_DELETE 0x402
#define SYS_STORAGE_USAGE  0x403
#define E_NOENT -10
#define E_NOSPC -11

.macro SET n, key, klen, val, vlen, want
	la	a0, \key
	li	a1, \klen
	la	a2, \val
	li	a3, \vlen
	SYSCALL	SYS_STORAGE_SET
	CHECK	\n, a0, \want
.endm

	.text
	.globl _start
_start:
	SYSCALL	SYS_STORAGE_USAGE
	CHECK	1, a0, 0
	la	a0, k
	li	a1, 1
	la	a2, buf
	li	a3, 16
	SYSCALL	SYS_STORAGE_GET
	CHECK	2, a0, E_NOENT

	SET	3, k, 1, hello, 5, 0
	SYSCALL	SYS_STORAGE_USAGE
	CHECK	4, a0, 6
	la	a0, k			// partial read: full length back, only 2 bytes copied
	li	a1, 1
	la	a2, buf
	li	a3, 2
	SYSCALL	SYS_STORAGE_GET
	CHECK	5, a0, 5
	la	t0, buf
	lbu	t1, 1(t0)
	CHECK	6, t1, 'e'
	lbu	t1, 2(t0)
	CHECK	7, t1, 0

	SET	8, k, 0, hello, 5, E_INVAL	// empty key
	SET	9, long, 300, hello, 5, E_RANGE	// key over 256 bytes
	SET	10, big, 3, filler, 62, E_NOSPC	// 6 + 3 + 62 > 64
	SET	11, k, 1, filler, 60, 0		// replacing frees the old value first
	SYSCALL	SYS_STORAGE_USAGE
	CHECK	12, a0, 61

	la	a0, nope
	li	a1, 4
	SYSCALL	SYS_STORAGE_DELETE
	CHECK	13, a0, E_NOENT
	la	a0, k
	li	a1, 1
	SYSCALL	SYS_STORAGE_DELETE
	CHECK	14, a0, 0
	SYSCALL	SYS_STORAGE_USAGE
	CHECK	15, a0, 0

	SET	16, persist, 7, yes, 3, 0
	PASS

	.section .rodata
k:	.ascii	"k"
hello:	.ascii	"hello"
big:	.ascii	"big"
nope:	.ascii	"nope"
persist: .ascii	"persist"
yes:	.ascii	"yes"
long:	.fill	300, 1, 'x'
filler:	.fill	62, 1, 'f'

	.data
	.balign 16
buf:
	.zero	16
