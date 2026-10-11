// Fetch syscalls against fetch.manifest. Run by tests/host, which plays the
// network: the page is loaded from nb://site.example/app/page, and every
// request is answered when the page waits (200 "hello", then 404 "nope",
// then 200 for a stream the page has already closed).
#include "test.h"

#define SYS_FETCH_OPEN 0x300
#define SYS_FETCH_READ 0x301
#define E_AGAIN -7
#define EV_FETCH 7
#define MAX_FETCHES 16

// a0 = Fetch_Open(\url, \len)
.macro OPEN url, len
	la	a0, \url
	.option push
	.option norvc			// c.li cannot hold every length
	li	a1, \len
	.option pop
	SYSCALL	SYS_FETCH_OPEN
.endm

// a0 = Fetch_Read(\h, buf, \cap)
.macro READ h, cap
	mv	a0, \h
	la	a1, buf
	li	a2, \cap
	SYSCALL	SYS_FETCH_READ
.endm

// Waits for an event and checks it is a Fetch event for stream \h with
// status \status and body length \len.
.macro EXPECT_FETCH n, h, status, len
	la	a0, ev
	li	a1, -1
	SYSCALL	SYS_WAIT_EVENT
	CHECK	\n, a0, 1
	la	t0, ev
	lwu	t1, 0(t0)
	CHECK	\n, t1, EV_FETCH
	lwu	t1, 4(t0)
	CHECKR	\n, t1, \h
	ld	t1, 8(t0)
	CHECK	\n, t1, \status
	ld	t1, 16(t0)
	CHECK	\n, t1, \len
.endm

// Lengths are computed here, before the code that loads them with li.
	.section .rodata
ok:	.ascii	"nb://allowed.example/data/x"
	.equ	ok_len, . - ok
other:	.ascii	"nb://other.example/data/x"
	.equ	other_len, . - other
datax:	.ascii	"nb://allowed.example/datax"
	.equ	datax_len, . - datax
dotdot:	.ascii	"nb://allowed.example/data/../secret"
	.equ	dotdot_len, . - dotdot
http:	.ascii	"http://allowed.example/data/x"
	.equ	http_len, . - http
rel:	.ascii	"rel/y"
	.equ	rel_len, . - rel
up:	.ascii	"../z"
	.equ	up_len, . - up
keyed:	.ascii	"nb://KEYED.example/k"
	.equ	keyed_len, . - keyed

	.text
	.globl _start
_start:
	OPEN	ok, ok_len		// under nb://allowed.example/data
	blez	a0, fail1
	mv	s0, a0
	OPEN	other, other_len	// a server the manifest does not name
	CHECK	2, a0, E_PERM
	OPEN	datax, datax_len	// /datax is not under /data
	CHECK	3, a0, E_PERM
	OPEN	dotdot, dotdot_len	// /data/../secret is /secret
	CHECK	4, a0, E_PERM
	OPEN	http, http_len		// only nb://
	CHECK	5, a0, E_INVAL
	OPEN	rel, rel_len		// relative: nb://site.example/app/rel/y
	blez	a0, fail6
	mv	s1, a0
	OPEN	up, up_len		// relative, but outside /app
	CHECK	7, a0, E_PERM
	OPEN	keyed, keyed_len	// gets the manifest's key
	blez	a0, fail8
	li	a7, SYS_HANDLE_CLOSE	// cancelled: its answer must never arrive
	ecall
	CHECK	9, a0, 0

	READ	s0, 16			// not answered yet
	CHECK	10, a0, E_AGAIN
	li	a0, 12345
	la	a1, buf
	li	a2, 16
	SYSCALL	SYS_FETCH_READ
	CHECK	11, a0, E_BADH

	EXPECT_FETCH 12, s0, 200, 5
	READ	s0, 2			// the body in parts
	CHECK	13, a0, 2
	la	t0, buf
	lbu	t1, 1(t0)
	CHECK	14, t1, 'e'
	READ	s0, 16
	CHECK	15, a0, 3
	la	t0, buf
	lbu	t1, 0(t0)
	CHECK	16, t1, 'l'
	READ	s0, 16			// end of the body
	CHECK	17, a0, 0

	EXPECT_FETCH 18, s1, 404, 4	// the cancelled stream sends nothing
	mv	a0, s0
	li	a7, SYS_HANDLE_CLOSE
	ecall
	mv	a0, s1
	li	a7, SYS_HANDLE_CLOSE
	ecall
	READ	s0, 16			// closed
	CHECK	19, a0, E_BADH

	li	s2, 0			// at most MAX_FETCHES requests in flight
1:	OPEN	ok, ok_len
	blez	a0, 2f
	addi	s2, s2, 1
	j	1b
2:	CHECK	20, a0, E_AGAIN
	CHECK	21, s2, MAX_FETCHES
	PASS

fail1:	FAIL	1
fail6:	FAIL	6
fail8:	FAIL	8

	.data
	.balign 16
ev:	.zero	32
buf:	.zero	16
