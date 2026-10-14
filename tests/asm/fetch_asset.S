// Fetch_Open answered from the page's bundle. Run by tests/host, which loads
// the page from nb://site.example/app/page with the asset "img/a.txt" =
// "asset". The manifest has no fetch lines, and the test fails any request
// that reaches the network.
#include "test.h"

#define SYS_FETCH_OPEN 0x300
#define SYS_FETCH_READ 0x301
#define EV_FETCH 7

// a0 = Fetch_Open(\url, \len)
.macro OPEN url, len
	la	a0, \url
	.option push
	.option norvc
	li	a1, \len
	.option pop
	SYSCALL	SYS_FETCH_OPEN
.endm

	.section .rodata
asset:	.ascii	"img/a.txt"
	.equ	asset_len, . - asset
dotted:	.ascii	"./img/../img/a.txt"
	.equ	dotted_len, . - dotted
missing:	.ascii	"img/b.txt"
	.equ	missing_len, . - missing
absolute:	.ascii	"nb://site.example/app/img/a.txt"
	.equ	absolute_len, . - absolute

	.text
	.globl _start
_start:
	OPEN	asset, asset_len	// in the bundle: no manifest line needed
	blez	a0, fail1
	mv	s0, a0
	la	a0, ev			// the answer is already there
	li	a1, 0
	SYSCALL	SYS_WAIT_EVENT
	CHECK	2, a0, 1
	la	t0, ev
	lwu	t1, 0(t0)
	CHECK	3, t1, EV_FETCH
	lwu	t1, 4(t0)
	CHECKR	4, t1, s0
	ld	t1, 8(t0)
	CHECK	5, t1, 200
	ld	t1, 16(t0)
	CHECK	6, t1, 5
	mv	a0, s0
	la	a1, buf
	li	a2, 16
	SYSCALL	SYS_FETCH_READ
	CHECK	7, a0, 5
	la	t0, buf
	lbu	t1, 0(t0)
	CHECK	8, t1, 'a'

	OPEN	dotted, dotted_len	// folds to the same file
	blez	a0, fail9
	OPEN	missing, missing_len	// not bundled, and no manifest line
	CHECK	10, a0, E_PERM
	OPEN	absolute, absolute_len	// absolute addresses always go to the network
	CHECK	11, a0, E_PERM
	PASS

fail1:	FAIL	1
fail9:	FAIL	9

	.data
	.balign 16
ev:	.zero	32
buf:	.zero	16
