package vm

import "base:intrinsics"
import "core:math"

// F and D extensions.
//
// Arithmetic uses the host's IEEE-754 round-to-nearest-even; the rounding mode
// field is honoured for float -> int conversions, which is where compilers rely
// on it (casts use RTZ). NaN results are always canonical so execution is
// identical on every host. fflags tracks NV and DZ; NX/OF/UF are not raised.

@(private) CANON_NAN_S :: u32(0x7FC00000)
@(private) CANON_NAN_D :: u64(0x7FF8000000000000)
@(private) BOX_S       :: u64(0xFFFFFFFF_00000000)

@(private) FLAG_NX :: u32(1 << 0)
@(private) FLAG_UF :: u32(1 << 1)
@(private) FLAG_OF :: u32(1 << 2)
@(private) FLAG_DZ :: u32(1 << 3)
@(private) FLAG_NV :: u32(1 << 4)

// Single-precision bits of a register; improperly NaN-boxed values read as canonical NaN.
@(private)
bits_s :: #force_inline proc "contextless" (cpu: ^Cpu, r: u32) -> u32 {
	v := cpu.f[r]
	if v & BOX_S != BOX_S {
		return CANON_NAN_S
	}
	return u32(v)
}

@(private) get_s :: #force_inline proc "contextless" (cpu: ^Cpu, r: u32) -> f32 { return transmute(f32)bits_s(cpu, r) }
@(private) get_d :: #force_inline proc "contextless" (cpu: ^Cpu, r: u32) -> f64 { return transmute(f64)cpu.f[r] }

@(private)
put_s :: #force_inline proc "contextless" (cpu: ^Cpu, r: u32, v: f32) {
	bits := transmute(u32)v
	if v != v {
		bits = CANON_NAN_S
	}
	cpu.f[r] = BOX_S | u64(bits)
}

@(private)
put_d :: #force_inline proc "contextless" (cpu: ^Cpu, r: u32, v: f64) {
	bits := transmute(u64)v
	if v != v {
		bits = CANON_NAN_D
	}
	cpu.f[r] = bits
}

@(private)
is_nan :: #force_inline proc "contextless" (v: $T) -> bool {
	return v != v
}

@(private)
is_snan_s :: #force_inline proc "contextless" (bits: u32) -> bool {
	return bits & 0x7F800000 == 0x7F800000 && bits & 0x007FFFFF != 0 && bits & 0x00400000 == 0
}

@(private)
is_snan_d :: #force_inline proc "contextless" (bits: u64) -> bool {
	return bits & 0x7FF0000000000000 == 0x7FF0000000000000 && bits & 0x000FFFFFFFFFFFFF != 0 && bits & 0x0008000000000000 == 0
}

// Raises NV when an operation on non-NaN inputs produced NaN (inf-inf, 0/0, sqrt(-1), ...).
@(private)
check_invalid :: #force_inline proc "contextless" (cpu: ^Cpu, r: $T, inputs: ..T) {
	if !is_nan(r) {
		return
	}
	for v in inputs {
		if is_nan(v) {
			return
		}
	}
	cpu.fcsr |= FLAG_NV
}

@(private)
round_mode :: #force_inline proc "contextless" (cpu: ^Cpu, rm: u32) -> (u32, bool) {
	m := rm
	if m == 7 {
		m = (cpu.fcsr >> 5) & 7
	}
	return m, m <= 4
}

@(private)
round_to_int :: proc "contextless" (v: f64, rm: u32) -> f64 {
	switch rm {
	case 1: return math.trunc(v)
	case 2: return math.floor(v)
	case 3: return math.ceil(v)
	case 4: return math.round(v) // ties away from zero
	}
	// Ties to even.
	f := math.floor(v)
	d := v - f
	if d > 0.5 || (d == 0.5 && math.mod(f, 2) != 0) {
		return f + 1
	}
	return f
}

// Float -> integer with RISC-V saturation rules. `signed`/`bits` select W, WU, L, LU.
@(private)
fcvt_to_int :: proc "contextless" (cpu: ^Cpu, v: f64, rm: u32, signed: bool, bits: uint) -> u64 {
	if is_nan(v) {
		cpu.fcsr |= FLAG_NV
		if signed {
			return bits == 32 ? sext32(u64(max(i32))) : u64(max(i64))
		}
		return max(u64) // sign-extended all-ones for WU as well
	}
	r := round_to_int(v, rm)
	if r != v {
		cpu.fcsr |= FLAG_NX
	}
	if signed {
		lo := -math.pow(2, f64(bits - 1))
		hi := math.pow(2, f64(bits - 1))
		if r < lo {
			cpu.fcsr |= FLAG_NV
			return bits == 32 ? transmute(u64)i64(min(i32)) : transmute(u64)min(i64)
		}
		if r >= hi {
			cpu.fcsr |= FLAG_NV
			return bits == 32 ? sext32(u64(max(i32))) : u64(max(i64))
		}
		return bits == 32 ? sext32(u64(u32(i32(r)))) : u64(i64(r))
	}
	hi := math.pow(2, f64(bits))
	if r < 0 {
		cpu.fcsr |= FLAG_NV
		return 0
	}
	if r >= hi {
		cpu.fcsr |= FLAG_NV
		return max(u64)
	}
	if bits == 32 {
		return sext32(u64(u32(r)))
	}
	if r >= 9223372036854775808.0 {
		return u64(r - 9223372036854775808.0) | (1 << 63)
	}
	return u64(r)
}

@(private)
fmin_max :: proc "contextless" (cpu: ^Cpu, a, b: $T, want_max: bool) -> T {
	if is_nan(a) && is_nan(b) {
		return transmute(T)(CANON_NAN_S when T == f32 else CANON_NAN_D)
	}
	if is_nan(a) { return b }
	if is_nan(b) { return a }
	if a == b {
		// -0 < +0
		neg_a := math.sign_bit(a)
		if want_max {
			return b if neg_a else a
		}
		return a if neg_a else b
	}
	if want_max {
		return a if a > b else b
	}
	return a if a < b else b
}

@(private)
fclass :: proc "contextless" (sign: bool, exp_all_ones, exp_zero, mant_zero, quiet: bool) -> u64 {
	if exp_all_ones {
		if mant_zero {
			return sign ? 1 << 0 : 1 << 7
		}
		return quiet ? 1 << 9 : 1 << 8
	}
	if exp_zero {
		if mant_zero {
			return sign ? 1 << 3 : 1 << 4
		}
		return sign ? 1 << 2 : 1 << 5
	}
	return sign ? 1 << 1 : 1 << 6
}

@(private)
exec_fp :: proc(cpu: ^Cpu, inst, opcode: u32) -> (Stop_Reason, bool) {
	rd := (inst >> 7) & 31
	rm := (inst >> 12) & 7
	rs1 := (inst >> 15) & 31
	rs2 := (inst >> 20) & 31
	f7 := inst >> 25
	x := &cpu.x

	illegal :: #force_inline proc "contextless" (cpu: ^Cpu, inst: u32) -> (Stop_Reason, bool) {
		return set_fault(cpu, .Illegal_Instruction, inst), true
	}
	set_x :: #force_inline proc "contextless" (cpu: ^Cpu, rd: u32, v: u64) {
		if rd != 0 {
			cpu.x[rd] = v
		}
	}

	switch opcode {
	case 0x07: // LOAD-FP
		addr := x[rs1] + u64(i64(i32(inst)) >> 20)
		switch rm {
		case 2:
			v, ok := load(&cpu.mem, addr, 4)
			if !ok { return set_fault(cpu, .Load_Access, inst, addr), true }
			cpu.f[rd] = BOX_S | v
		case 3:
			v, ok := load(&cpu.mem, addr, 8)
			if !ok { return set_fault(cpu, .Load_Access, inst, addr), true }
			cpu.f[rd] = v
		case:
			return illegal(cpu, inst)
		}
		return .Budget, false

	case 0x27: // STORE-FP
		imm := u64((i64(i32(inst)) >> 25) << 5 | i64((inst >> 7) & 0x1F))
		addr := x[rs1] + imm
		ok: bool
		switch rm {
		case 2: ok = store(&cpu.mem, addr, cpu.f[rs2], 4)
		case 3: ok = store(&cpu.mem, addr, cpu.f[rs2], 8)
		case:   return illegal(cpu, inst)
		}
		if !ok { return set_fault(cpu, .Store_Access, inst, addr), true }
		return .Budget, false

	case 0x43, 0x47, 0x4B, 0x4F: // FMADD, FMSUB, FNMSUB, FNMADD
		rs3 := inst >> 27
		neg_prod := opcode == 0x4B || opcode == 0x4F
		neg_add := opcode == 0x47 || opcode == 0x4F
		switch f7 & 3 {
		case 0:
			a, b, c := get_s(cpu, rs1), get_s(cpu, rs2), get_s(cpu, rs3)
			if neg_prod { a = -a }
			if neg_add { c = -c }
			r := intrinsics.fused_mul_add(a, b, c)
			check_invalid(cpu, r, a, b, c)
			put_s(cpu, rd, r)
		case 1:
			a, b, c := get_d(cpu, rs1), get_d(cpu, rs2), get_d(cpu, rs3)
			if neg_prod { a = -a }
			if neg_add { c = -c }
			r := intrinsics.fused_mul_add(a, b, c)
			check_invalid(cpu, r, a, b, c)
			put_d(cpu, rd, r)
		case:
			return illegal(cpu, inst)
		}
		return .Budget, false
	}

	// OP-FP
	switch f7 {
	case 0x00, 0x04, 0x08, 0x0C: // FADD/FSUB/FMUL/FDIV.S
		a, b := get_s(cpu, rs1), get_s(cpu, rs2)
		r: f32
		switch f7 {
		case 0x00: r = a + b
		case 0x04: r = a - b
		case 0x08: r = a * b
		case 0x0C:
			if b == 0 && a == a && a != 0 && !math.is_inf(a) { cpu.fcsr |= FLAG_DZ }
			r = a / b
		}
		check_invalid(cpu, r, a, b)
		put_s(cpu, rd, r)

	case 0x01, 0x05, 0x09, 0x0D: // FADD/FSUB/FMUL/FDIV.D
		a, b := get_d(cpu, rs1), get_d(cpu, rs2)
		r: f64
		switch f7 {
		case 0x01: r = a + b
		case 0x05: r = a - b
		case 0x09: r = a * b
		case 0x0D:
			if b == 0 && a == a && a != 0 && !math.is_inf(a) { cpu.fcsr |= FLAG_DZ }
			r = a / b
		}
		check_invalid(cpu, r, a, b)
		put_d(cpu, rd, r)

	case 0x2C: // FSQRT.S
		if rs2 != 0 { return illegal(cpu, inst) }
		a := get_s(cpu, rs1)
		r := math.sqrt(a)
		check_invalid(cpu, r, a)
		put_s(cpu, rd, r)

	case 0x2D: // FSQRT.D
		if rs2 != 0 { return illegal(cpu, inst) }
		a := get_d(cpu, rs1)
		r := math.sqrt(a)
		check_invalid(cpu, r, a)
		put_d(cpu, rd, r)

	case 0x10: // FSGNJ[N|X].S
		a, b := bits_s(cpu, rs1), bits_s(cpu, rs2)
		sign: u32
		switch rm {
		case 0: sign = b & 0x80000000
		case 1: sign = ~b & 0x80000000
		case 2: sign = (a ~ b) & 0x80000000
		case:   return illegal(cpu, inst)
		}
		cpu.f[rd] = BOX_S | u64((a & 0x7FFFFFFF) | sign)

	case 0x11: // FSGNJ[N|X].D
		a, b := cpu.f[rs1], cpu.f[rs2]
		SIGN :: u64(1) << 63
		sign: u64
		switch rm {
		case 0: sign = b & SIGN
		case 1: sign = ~b & SIGN
		case 2: sign = (a ~ b) & SIGN
		case:   return illegal(cpu, inst)
		}
		cpu.f[rd] = (a &~ SIGN) | sign

	case 0x14: // FMIN/FMAX.S
		if rm > 1 { return illegal(cpu, inst) }
		if is_snan_s(bits_s(cpu, rs1)) || is_snan_s(bits_s(cpu, rs2)) { cpu.fcsr |= FLAG_NV }
		put_s(cpu, rd, fmin_max(cpu, get_s(cpu, rs1), get_s(cpu, rs2), rm == 1))

	case 0x15: // FMIN/FMAX.D
		if rm > 1 { return illegal(cpu, inst) }
		if is_snan_d(cpu.f[rs1]) || is_snan_d(cpu.f[rs2]) { cpu.fcsr |= FLAG_NV }
		put_d(cpu, rd, fmin_max(cpu, get_d(cpu, rs1), get_d(cpu, rs2), rm == 1))

	case 0x20: // FCVT.S.D
		if rs2 != 1 { return illegal(cpu, inst) }
		if is_snan_d(cpu.f[rs1]) { cpu.fcsr |= FLAG_NV }
		put_s(cpu, rd, f32(get_d(cpu, rs1)))

	case 0x21: // FCVT.D.S
		if rs2 != 0 { return illegal(cpu, inst) }
		if is_snan_s(bits_s(cpu, rs1)) { cpu.fcsr |= FLAG_NV }
		put_d(cpu, rd, f64(get_s(cpu, rs1)))

	case 0x50, 0x51: // FEQ/FLT/FLE
		a, b: f64
		snan: bool
		if f7 == 0x50 {
			a, b = f64(get_s(cpu, rs1)), f64(get_s(cpu, rs2))
			snan = is_snan_s(bits_s(cpu, rs1)) || is_snan_s(bits_s(cpu, rs2))
		} else {
			a, b = get_d(cpu, rs1), get_d(cpu, rs2)
			snan = is_snan_d(cpu.f[rs1]) || is_snan_d(cpu.f[rs2])
		}
		any_nan := is_nan(a) || is_nan(b)
		r: bool
		switch rm {
		case 2:
			if snan { cpu.fcsr |= FLAG_NV }
			r = a == b
		case 1:
			if any_nan { cpu.fcsr |= FLAG_NV }
			r = a < b
		case 0:
			if any_nan { cpu.fcsr |= FLAG_NV }
			r = a <= b
		case:
			return illegal(cpu, inst)
		}
		set_x(cpu, rd, 1 if r else 0)

	case 0x60, 0x61: // FCVT.{W,WU,L,LU}.{S,D}
		mode, ok := round_mode(cpu, rm)
		if !ok || rs2 > 3 { return illegal(cpu, inst) }
		v := f64(get_s(cpu, rs1)) if f7 == 0x60 else get_d(cpu, rs1)
		set_x(cpu, rd, fcvt_to_int(cpu, v, mode, rs2 & 1 == 0, 32 if rs2 < 2 else 64))

	case 0x68: // FCVT.S.{W,WU,L,LU}
		a := x[rs1]
		r: f32
		switch rs2 {
		case 0: r = f32(i32(u32(a)))
		case 1: r = f32(u32(a))
		case 2: r = f32(i64(a))
		case 3: r = f32(a)
		case:   return illegal(cpu, inst)
		}
		put_s(cpu, rd, r)

	case 0x69: // FCVT.D.{W,WU,L,LU}
		a := x[rs1]
		r: f64
		switch rs2 {
		case 0: r = f64(i32(u32(a)))
		case 1: r = f64(u32(a))
		case 2: r = f64(i64(a))
		case 3: r = f64(a)
		case:   return illegal(cpu, inst)
		}
		put_d(cpu, rd, r)

	case 0x70: // FMV.X.W / FCLASS.S
		if rs2 != 0 { return illegal(cpu, inst) }
		switch rm {
		case 0: set_x(cpu, rd, sext32(cpu.f[rs1]))
		case 1:
			v := bits_s(cpu, rs1)
			set_x(cpu, rd, fclass(v >> 31 != 0, v & 0x7F800000 == 0x7F800000, v & 0x7F800000 == 0, v & 0x7FFFFF == 0, v & 0x400000 != 0))
		case:
			return illegal(cpu, inst)
		}

	case 0x71: // FMV.X.D / FCLASS.D
		if rs2 != 0 { return illegal(cpu, inst) }
		v := cpu.f[rs1]
		switch rm {
		case 0: set_x(cpu, rd, v)
		case 1:
			EXP :: u64(0x7FF0000000000000)
			MANT :: u64(0x000FFFFFFFFFFFFF)
			set_x(cpu, rd, fclass(v >> 63 != 0, v & EXP == EXP, v & EXP == 0, v & MANT == 0, v & 0x0008000000000000 != 0))
		case:
			return illegal(cpu, inst)
		}

	case 0x78: // FMV.W.X
		if rs2 != 0 || rm != 0 { return illegal(cpu, inst) }
		cpu.f[rd] = BOX_S | (x[rs1] & 0xFFFFFFFF)

	case 0x79: // FMV.D.X
		if rs2 != 0 || rm != 0 { return illegal(cpu, inst) }
		cpu.f[rd] = x[rs1]

	case:
		return illegal(cpu, inst)
	}
	return .Budget, false
}
