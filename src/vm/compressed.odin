package vm

// RV64C: each 16-bit instruction is expanded to its 32-bit equivalent so the
// executor only has one decoder. Returns false for reserved/illegal encodings.

@(private="file") enc_r :: #force_inline proc "contextless" (op, rd, f3, rs1, rs2, f7: u32) -> u32 {
	return f7 << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op
}
@(private="file") enc_i :: #force_inline proc "contextless" (op, rd, f3, rs1: u32, imm: i32) -> u32 {
	return (u32(imm) & 0xFFF) << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op
}
@(private="file") enc_s :: #force_inline proc "contextless" (op, f3, rs1, rs2: u32, imm: i32) -> u32 {
	u := u32(imm)
	return ((u >> 5) & 0x7F) << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | (u & 0x1F) << 7 | op
}
@(private="file") enc_b :: #force_inline proc "contextless" (f3, rs1, rs2: u32, imm: i32) -> u32 {
	u := u32(imm)
	return ((u >> 12) & 1) << 31 | ((u >> 5) & 0x3F) << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | ((u >> 1) & 0xF) << 8 | ((u >> 11) & 1) << 7 | 0x63
}
@(private="file") enc_j :: #force_inline proc "contextless" (rd: u32, imm: i32) -> u32 {
	u := u32(imm)
	return ((u >> 20) & 1) << 31 | ((u >> 1) & 0x3FF) << 21 | ((u >> 11) & 1) << 20 | ((u >> 12) & 0xFF) << 12 | rd << 7 | 0x6F
}

// Bit field c[hi:lo] of the 16-bit instruction.
@(private="file") bits :: #force_inline proc "contextless" (c: u32, hi, lo: u32) -> u32 {
	return (c >> lo) & ((1 << (hi - lo + 1)) - 1)
}

// Sign-extends the low `n` bits.
@(private="file") sext :: #force_inline proc "contextless" (v: u32, n: u32) -> i32 {
	s := 32 - n
	return i32(v << s) >> s
}

OP_LOAD    :: 0x03
OP_LOAD_FP :: 0x07
OP_IMM     :: 0x13
OP_IMM_32  :: 0x1B
OP_STORE   :: 0x23
OP_STORE_FP :: 0x27
OP_OP      :: 0x33
OP_LUI     :: 0x37
OP_OP_32   :: 0x3B
OP_JALR    :: 0x67

expand_compressed :: proc "contextless" (half: u16) -> (u32, bool) {
	c := u32(half)
	if c == 0 {
		return 0, false // defined illegal instruction
	}
	f3 := bits(c, 15, 13)
	rd := bits(c, 11, 7) // also rs1 in many forms
	rs2 := bits(c, 6, 2)
	rdp := bits(c, 4, 2) + 8 // rd' / rs2'
	rs1p := bits(c, 9, 7) + 8 // rs1' / rd'

	switch c & 3 {
	case 0:
		switch f3 {
		case 0: // C.ADDI4SPN
			imm := bits(c, 12, 11) << 4 | bits(c, 10, 7) << 6 | bits(c, 6, 6) << 2 | bits(c, 5, 5) << 3
			if imm == 0 { return 0, false }
			return enc_i(OP_IMM, rdp, 0, REG_SP, i32(imm)), true
		case 1: // C.FLD
			imm := bits(c, 12, 10) << 3 | bits(c, 6, 5) << 6
			return enc_i(OP_LOAD_FP, rdp, 3, rs1p, i32(imm)), true
		case 2: // C.LW
			imm := bits(c, 12, 10) << 3 | bits(c, 6, 6) << 2 | bits(c, 5, 5) << 6
			return enc_i(OP_LOAD, rdp, 2, rs1p, i32(imm)), true
		case 3: // C.LD
			imm := bits(c, 12, 10) << 3 | bits(c, 6, 5) << 6
			return enc_i(OP_LOAD, rdp, 3, rs1p, i32(imm)), true
		case 5: // C.FSD
			imm := bits(c, 12, 10) << 3 | bits(c, 6, 5) << 6
			return enc_s(OP_STORE_FP, 3, rs1p, rdp, i32(imm)), true
		case 6: // C.SW
			imm := bits(c, 12, 10) << 3 | bits(c, 6, 6) << 2 | bits(c, 5, 5) << 6
			return enc_s(OP_STORE, 2, rs1p, rdp, i32(imm)), true
		case 7: // C.SD
			imm := bits(c, 12, 10) << 3 | bits(c, 6, 5) << 6
			return enc_s(OP_STORE, 3, rs1p, rdp, i32(imm)), true
		}
		return 0, false

	case 1:
		imm6 := sext(bits(c, 12, 12) << 5 | bits(c, 6, 2), 6)
		switch f3 {
		case 0: // C.ADDI / C.NOP
			return enc_i(OP_IMM, rd, 0, rd, imm6), true
		case 1: // C.ADDIW
			if rd == 0 { return 0, false }
			return enc_i(OP_IMM_32, rd, 0, rd, imm6), true
		case 2: // C.LI
			return enc_i(OP_IMM, rd, 0, 0, imm6), true
		case 3:
			if rd == REG_SP { // C.ADDI16SP
				imm := sext(bits(c, 12, 12) << 9 | bits(c, 6, 6) << 4 | bits(c, 5, 5) << 6 | bits(c, 4, 3) << 7 | bits(c, 2, 2) << 5, 10)
				if imm == 0 { return 0, false }
				return enc_i(OP_IMM, REG_SP, 0, REG_SP, imm), true
			}
			// C.LUI
			if imm6 == 0 { return 0, false }
			return u32(imm6) << 12 | rd << 7 | OP_LUI, true
		case 4:
			switch bits(c, 11, 10) {
			case 0: // C.SRLI
				shamt := bits(c, 12, 12) << 5 | bits(c, 6, 2)
				return enc_i(OP_IMM, rs1p, 5, rs1p, i32(shamt)), true
			case 1: // C.SRAI
				shamt := bits(c, 12, 12) << 5 | bits(c, 6, 2)
				return enc_i(OP_IMM, rs1p, 5, rs1p, i32(shamt | 0x400)), true
			case 2: // C.ANDI
				return enc_i(OP_IMM, rs1p, 7, rs1p, imm6), true
			case 3:
				op2 := bits(c, 6, 5)
				if bits(c, 12, 12) == 0 {
					switch op2 {
					case 0: return enc_r(OP_OP, rs1p, 0, rs1p, rdp, 0x20), true // C.SUB
					case 1: return enc_r(OP_OP, rs1p, 4, rs1p, rdp, 0), true    // C.XOR
					case 2: return enc_r(OP_OP, rs1p, 6, rs1p, rdp, 0), true    // C.OR
					case 3: return enc_r(OP_OP, rs1p, 7, rs1p, rdp, 0), true    // C.AND
					}
				} else {
					switch op2 {
					case 0: return enc_r(OP_OP_32, rs1p, 0, rs1p, rdp, 0x20), true // C.SUBW
					case 1: return enc_r(OP_OP_32, rs1p, 0, rs1p, rdp, 0), true    // C.ADDW
					}
				}
			}
			return 0, false
		case 5: // C.J
			imm := sext(bits(c, 12, 12) << 11 | bits(c, 11, 11) << 4 | bits(c, 10, 9) << 8 | bits(c, 8, 8) << 10 | bits(c, 7, 7) << 6 | bits(c, 6, 6) << 7 | bits(c, 5, 3) << 1 | bits(c, 2, 2) << 5, 12)
			return enc_j(0, imm), true
		case 6, 7: // C.BEQZ, C.BNEZ
			imm := sext(bits(c, 12, 12) << 8 | bits(c, 11, 10) << 3 | bits(c, 6, 5) << 6 | bits(c, 4, 3) << 1 | bits(c, 2, 2) << 5, 9)
			return enc_b(f3 - 6, rs1p, 0, imm), true
		}
		return 0, false

	case 2:
		switch f3 {
		case 0: // C.SLLI
			shamt := bits(c, 12, 12) << 5 | bits(c, 6, 2)
			return enc_i(OP_IMM, rd, 1, rd, i32(shamt)), true
		case 1: // C.FLDSP
			imm := bits(c, 12, 12) << 5 | bits(c, 6, 5) << 3 | bits(c, 4, 2) << 6
			return enc_i(OP_LOAD_FP, rd, 3, REG_SP, i32(imm)), true
		case 2: // C.LWSP
			if rd == 0 { return 0, false }
			imm := bits(c, 12, 12) << 5 | bits(c, 6, 4) << 2 | bits(c, 3, 2) << 6
			return enc_i(OP_LOAD, rd, 2, REG_SP, i32(imm)), true
		case 3: // C.LDSP
			if rd == 0 { return 0, false }
			imm := bits(c, 12, 12) << 5 | bits(c, 6, 5) << 3 | bits(c, 4, 2) << 6
			return enc_i(OP_LOAD, rd, 3, REG_SP, i32(imm)), true
		case 4:
			if bits(c, 12, 12) == 0 {
				if rs2 == 0 { // C.JR
					if rd == 0 { return 0, false }
					return enc_i(OP_JALR, 0, 0, rd, 0), true
				}
				return enc_r(OP_OP, rd, 0, 0, rs2, 0), true // C.MV
			}
			if rs2 == 0 {
				if rd == 0 { return 0x00100073, true } // C.EBREAK
				return enc_i(OP_JALR, REG_RA, 0, rd, 0), true // C.JALR
			}
			return enc_r(OP_OP, rd, 0, rd, rs2, 0), true // C.ADD
		case 5: // C.FSDSP
			imm := bits(c, 12, 10) << 3 | bits(c, 9, 7) << 6
			return enc_s(OP_STORE_FP, 3, REG_SP, rs2, i32(imm)), true
		case 6: // C.SWSP
			imm := bits(c, 12, 9) << 2 | bits(c, 8, 7) << 6
			return enc_s(OP_STORE, 2, REG_SP, rs2, i32(imm)), true
		case 7: // C.SDSP
			imm := bits(c, 12, 10) << 3 | bits(c, 9, 7) << 6
			return enc_s(OP_STORE, 3, REG_SP, rs2, i32(imm)), true
		}
	}
	return 0, false
}
