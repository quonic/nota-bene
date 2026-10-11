// F and D extensions.
#include "test.h"

	.text
	.globl _start
_start:
	li	a1, 3
	fcvt.d.l fa0, a1		// 3.0
	li	a1, 4
	fcvt.d.l fa1, a1		// 4.0

	fadd.d	fa2, fa0, fa1
	fcvt.l.d a5, fa2, rtz
	CHECK	1, a5, 7
	fmul.d	fa2, fa0, fa1
	fcvt.l.d a5, fa2, rtz
	CHECK	2, a5, 12
	fdiv.d	fa2, fa1, fa0		// 1.333...
	fcvt.l.d a5, fa2, rtz
	CHECK	3, a5, 1
	fcvt.l.d a5, fa2, rup
	CHECK	4, a5, 2
	fsub.d	fa2, fa0, fa1
	fcvt.l.d a5, fa2, rtz
	CHECK	5, a5, -1
	fsqrt.d	fa2, fa1
	fcvt.l.d a5, fa2, rtz
	CHECK	6, a5, 2
	fmadd.d	fa2, fa0, fa1, fa0	// 3*4+3
	fcvt.l.d a5, fa2, rtz
	CHECK	7, a5, 15
	fmsub.d	fa2, fa0, fa1, fa0	// 3*4-3
	fcvt.l.d a5, fa2, rtz
	CHECK	8, a5, 9
	fnmsub.d fa2, fa0, fa1, fa0	// -(3*4)+3
	fcvt.l.d a5, fa2, rtz
	CHECK	9, a5, -9
	fnmadd.d fa2, fa0, fa1, fa0	// -(3*4)-3
	fcvt.l.d a5, fa2, rtz
	CHECK	10, a5, -15

	// rounding modes on 2.5 and -2.5
	li	a1, 5
	fcvt.d.l fa3, a1
	li	a1, 2
	fcvt.d.l fa4, a1
	fdiv.d	fa5, fa3, fa4
	fcvt.l.d a5, fa5, rne
	CHECK	11, a5, 2
	fcvt.l.d a5, fa5, rmm
	CHECK	12, a5, 3
	fcvt.l.d a5, fa5, rdn
	CHECK	13, a5, 2
	fcvt.l.d a5, fa5, rup
	CHECK	14, a5, 3
	fcvt.l.d a5, fa5, rtz
	CHECK	15, a5, 2
	fneg.d	fa5, fa5
	fcvt.l.d a5, fa5, rne
	CHECK	16, a5, -2
	fcvt.l.d a5, fa5, rmm
	CHECK	17, a5, -3
	fcvt.l.d a5, fa5, rdn
	CHECK	18, a5, -3
	fcvt.l.d a5, fa5, rup
	CHECK	19, a5, -2
	fcvt.l.d a5, fa5, rtz
	CHECK	20, a5, -2

	// dynamic rounding mode from frm
	fneg.d	fa5, fa5		// 2.5 again
	fsrmi	1			// rtz
	fcvt.l.d a5, fa5, dyn
	CHECK	21, a5, 2
	fsrmi	3			// rup
	fcvt.l.d a5, fa5, dyn
	CHECK	22, a5, 3
	frrm	a5
	CHECK	23, a5, 3
	fsrmi	0

	// saturating conversions raise NV
	fsflags	zero
	li	a1, 1
	slli	a1, a1, 40
	fcvt.d.l fa6, a1
	fcvt.w.d a5, fa6, rtz
	CHECK	24, a5, 0x7FFFFFFF
	frflags	a5
	andi	a5, a5, 0x10
	CHECK	25, a5, 0x10
	fcvt.wu.d a5, fa2, rtz		// -15 -> 0
	CHECK	26, a5, 0
	li	a1, 1
	slli	a1, a1, 63
	fcvt.d.lu fa6, a1
	fcvt.lu.d a5, fa6, rtz
	CHECKR	27, a5, a1
	li	a1, -1
	fcvt.d.lu fa6, a1		// rounds to 2^64
	fcvt.lu.d a5, fa6, rtz
	CHECK	28, a5, -1

	// NaN is canonical, compares false, raises NV
	fsflags	zero
	fcvt.d.l fs1, zero
	fdiv.d	fa7, fs1, fs1
	fmv.x.d	a5, fa7
	CHECK	29, a5, 0x7FF8000000000000
	frflags	a5
	CHECK	30, a5, 0x10
	fclass.d a5, fa7
	CHECK	31, a5, 0x200
	fcvt.l.d a5, fa7, rtz
	CHECK	32, a5, 0x7FFFFFFFFFFFFFFF
	feq.d	a5, fa7, fa7
	CHECK	33, a5, 0
	flt.d	a5, fa0, fa1
	CHECK	34, a5, 1
	fle.d	a5, fa1, fa0
	CHECK	35, a5, 0
	feq.d	a5, fa0, fa0
	CHECK	36, a5, 1

	// min/max, including NaN and signed zero
	fmin.d	fa2, fa0, fa7
	feq.d	a5, fa2, fa0
	CHECK	37, a5, 1
	fmax.d	fa2, fa0, fa1
	feq.d	a5, fa2, fa1
	CHECK	38, a5, 1
	fneg.d	fs2, fs1
	fmin.d	fa2, fs1, fs2
	fmv.x.d	a5, fa2
	CHECK	39, a5, 0x8000000000000000
	fmax.d	fa2, fs2, fs1
	fmv.x.d	a5, fa2
	CHECK	40, a5, 0

	fclass.d a5, fa0
	CHECK	41, a5, 0x40
	fclass.d a5, fs1
	CHECK	42, a5, 0x10
	fclass.d a5, fs2
	CHECK	43, a5, 0x08
	fdiv.d	fa2, fa0, fs1		// +inf, raises DZ
	fclass.d a5, fa2
	CHECK	44, a5, 0x80
	frflags	a5
	andi	a5, a5, 0x08
	CHECK	45, a5, 0x08

	// single precision
	li	a1, 0x40400000		// 3.0f
	fmv.w.x	ft0, a1
	li	a1, 0x40800000		// 4.0f
	fmv.w.x	ft1, a1
	fadd.s	ft2, ft0, ft1
	fmv.x.w	a5, ft2
	CHECK	46, a5, 0x40E00000
	fcvt.w.s a5, ft2, rtz
	CHECK	47, a5, 7
	fmv.x.d	a5, ft2			// NaN-boxed
	CHECK	48, a5, 0xFFFFFFFF40E00000
	fmv.d.x	ft3, a1			// not NaN-boxed: reads as canonical NaN
	fadd.s	ft4, ft3, ft0
	fmv.x.w	a5, ft4
	CHECK	49, a5, 0x7FC00000
	fcvt.d.s fa2, ft2
	fcvt.l.d a5, fa2, rtz
	CHECK	50, a5, 7
	fcvt.s.d ft5, fa1
	fmv.x.w	a5, ft5
	CHECK	51, a5, 0x40800000
	fsgnjx.s ft6, ft0, ft0
	fmv.x.w	a5, ft6
	CHECK	52, a5, 0x40400000
	fsgnjn.s ft6, ft0, ft0
	fmv.x.w	a5, ft6
	CHECK	53, a5, 0xFFFFFFFFC0400000
	fmul.s	ft6, ft0, ft1
	fdiv.s	ft6, ft6, ft1
	feq.s	a5, ft6, ft0
	CHECK	54, a5, 1
	fmadd.s	ft6, ft0, ft1, ft0
	fcvt.w.s a5, ft6, rtz
	CHECK	55, a5, 15
	li	a1, -9
	fcvt.s.w ft6, a1
	fcvt.l.s a5, ft6, rtz
	CHECK	56, a5, -9
	fmin.s	ft6, ft0, ft1
	feq.s	a5, ft6, ft0
	CHECK	57, a5, 1
	fclass.s a5, ft0
	CHECK	58, a5, 0x40
	flt.s	a5, ft1, ft0
	CHECK	59, a5, 0

	// FP loads and stores
	la	s0, buf
	fsd	fa1, 0(s0)
	ld	a5, 0(s0)
	CHECK	60, a5, 0x4010000000000000
	fsw	ft0, 8(s0)
	lwu	a5, 8(s0)
	CHECK	61, a5, 0x40400000
	flw	ft7, 8(s0)
	fmv.x.d	a5, ft7
	CHECK	62, a5, 0xFFFFFFFF40400000
	fld	fs0, 0(s0)
	feq.d	a5, fs0, fa1
	CHECK	63, a5, 1

	// fcsr holds frm and fflags together
	li	a1, 0x7F
	fscsr	a1
	frcsr	a5
	CHECK	64, a5, 0x7F
	frrm	a5
	CHECK	65, a5, 3
	frflags	a5
	CHECK	66, a5, 0x1F
	fscsr	zero

	PASS

	.data
	.balign 16
buf:
	.zero	32
