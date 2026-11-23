package vm

// Pre-decoded instruction cache.
//
// Each instruction is fetched, expanded and decoded once, on its first
// execution, and kept as a Decoded in a slot per 2-byte code address. Later
// executions skip the fetch, the permission checks and the field decoding.
//
// This is safe because no page is ever both writable and executable, so
// neither the guest nor the host (which writes guest memory only through
// {.Write} checks) can change code that has been cached. Only memory_protect
// can make code writable; any permission change that touches an executable
// page, to or from Exec, drops the whole cache.
//
// The cache has one 16-byte slot per 2 bytes of the executable range, from
// the first to the last executable page, so it is 8 times the size of the
// code, never of all guest memory. It is allocated zeroed on the first fill;
// the system allocator hands out large zeroed blocks as untouched pages, so
// physical memory follows the code that actually runs.

// What a decoded slot does. The common integer instructions have their own
// op; everything else (CSRs, atomics, F and D, illegal encodings) is Legacy
// and runs through `execute`, which also produces its faults.
@(private)
Op :: enum u8 {
	None, // slot not decoded yet
	Legacy,
	Lui, Auipc, Jal, Jalr,
	Beq, Bne, Blt, Bge, Bltu, Bgeu,
	Lb, Lh, Lw, Ld, Lbu, Lhu, Lwu,
	Sb, Sh, Sw, Sd,
	Addi, Slti, Sltiu, Xori, Ori, Andi, Slli, Srli, Srai,
	Add, Sub, Sll, Slt, Sltu, Xor, Srl, Sra, Or, And,
	Mul, Mulh, Mulhsu, Mulhu, Div, Divu, Rem, Remu,
	Addiw, Slliw, Srliw, Sraiw,
	Addw, Subw, Sllw, Srlw, Sraw,
	Mulw, Divw, Divuw, Remw, Remuw,
	Fence,
	Ecall, Ebreak,
}

@(private)
Decoded :: struct {
	op:   Op,
	rd:   u8,
	rs1:  u8,
	rs2:  u8,
	size: u8,  // 2 or 4 bytes
	imm:  i32, // sign-extended immediate, or the shift amount
	inst: u32, // the 32-bit (expanded) instruction, for Legacy and faults
}
#assert(size_of(Decoded) == 16)

@(private)
Code_Cache :: struct {
	base:  u64,       // address of the first executable page
	size:  u64,       // bytes from base to the end of the last executable page
	slots: []Decoded, // one per 2 bytes from base
	built: bool,      // false: find the executable range again before the next fill
}

// The cached instruction at pc, or nil.
@(private)
cache_lookup :: #force_inline proc "contextless" (c: ^Code_Cache, pc: u64) -> ^Decoded #no_bounds_check {
	off := pc - c.base // wraps for pc < base, so one compare covers both ends
	if off >= c.size || off & 1 != 0 {
		return nil
	}
	d := &c.slots[off >> 1]
	if d.op == .None {
		return nil
	}
	return d
}

// The slot for pc. nil when pc is outside the executable range or memory is
// short; the instruction then runs uncached.
@(private)
cache_slot :: proc(m: ^Memory, pc: u64) -> ^Decoded {
	c := &m.code
	if !c.built {
		cache_build(m)
	}
	off := pc - c.base
	if off >= c.size || off & 1 != 0 {
		return nil
	}
	return &c.slots[off >> 1]
}

@(private)
cache_build :: proc(m: ^Memory) {
	cache_reset(m)
	c := &m.code
	c.built = true
	lo, hi := -1, -1
	for p, i in m.perms {
		if .Exec in p {
			if lo < 0 {
				lo = i
			}
			hi = i
		}
	}
	if lo < 0 {
		return
	}
	size := u64(hi - lo + 1) << PAGE_SHIFT
	slots, err := make([]Decoded, size / 2, m.allocator)
	if err != nil || slots == nil {
		return // stays empty, so everything runs uncached
	}
	c.base = u64(lo) << PAGE_SHIFT
	c.size = size
	c.slots = slots
}

// Frees the cache. The next fill finds the executable range again.
@(private)
cache_reset :: proc(m: ^Memory) {
	delete(m.code.slots, m.allocator)
	m.code = {}
}

// Decodes a 32-bit (or expanded compressed) instruction. Every encoding
// `execute` would reject stays Legacy, so `execute` reports the fault exactly
// as before.
@(private)
decode :: proc "contextless" (inst: u32, size: u64) -> Decoded {
	d := Decoded {
		op   = .Legacy,
		rd   = u8((inst >> 7) & 31),
		rs1  = u8((inst >> 15) & 31),
		rs2  = u8((inst >> 20) & 31),
		size = u8(size),
		inst = inst,
	}
	f3 := (inst >> 12) & 7
	f7 := inst >> 25
	imm_i := i32(inst) >> 20

	switch inst & 0x7F {
	case 0x37:
		d.op, d.imm = .Lui, i32(inst & 0xFFFFF000)
	case 0x17:
		d.op, d.imm = .Auipc, i32(inst & 0xFFFFF000)
	case 0x6F:
		d.op = .Jal
		d.imm = (i32(inst) >> 31) << 20 | i32((inst >> 12) & 0xFF) << 12 | i32((inst >> 20) & 1) << 11 | i32((inst >> 21) & 0x3FF) << 1
	case 0x67:
		if f3 == 0 {
			d.op, d.imm = .Jalr, imm_i
		}
	case 0x63:
		d.imm = (i32(inst) >> 31) << 12 | i32((inst >> 7) & 1) << 11 | i32((inst >> 25) & 0x3F) << 5 | i32((inst >> 8) & 0xF) << 1
		switch f3 {
		case 0: d.op = .Beq
		case 1: d.op = .Bne
		case 4: d.op = .Blt
		case 5: d.op = .Bge
		case 6: d.op = .Bltu
		case 7: d.op = .Bgeu
		}
	case 0x03:
		d.imm = imm_i
		switch f3 {
		case 0: d.op = .Lb
		case 1: d.op = .Lh
		case 2: d.op = .Lw
		case 3: d.op = .Ld
		case 4: d.op = .Lbu
		case 5: d.op = .Lhu
		case 6: d.op = .Lwu
		}
	case 0x23:
		d.imm = (i32(inst) >> 25) << 5 | i32((inst >> 7) & 0x1F)
		switch f3 {
		case 0: d.op = .Sb
		case 1: d.op = .Sh
		case 2: d.op = .Sw
		case 3: d.op = .Sd
		}
	case 0x13:
		d.imm = imm_i
		switch f3 {
		case 0: d.op = .Addi
		case 1:
			if inst >> 26 == 0 {
				d.op, d.imm = .Slli, imm_i & 63
			}
		case 2: d.op = .Slti
		case 3: d.op = .Sltiu
		case 4: d.op = .Xori
		case 5:
			switch inst >> 26 {
			case 0x00: d.op, d.imm = .Srli, imm_i & 63
			case 0x10: d.op, d.imm = .Srai, imm_i & 63
			}
		case 6: d.op = .Ori
		case 7: d.op = .Andi
		}
	case 0x33:
		switch f7 {
		case 0x00:
			switch f3 {
			case 0: d.op = .Add
			case 1: d.op = .Sll
			case 2: d.op = .Slt
			case 3: d.op = .Sltu
			case 4: d.op = .Xor
			case 5: d.op = .Srl
			case 6: d.op = .Or
			case 7: d.op = .And
			}
		case 0x20:
			switch f3 {
			case 0: d.op = .Sub
			case 5: d.op = .Sra
			}
		case 0x01:
			switch f3 {
			case 0: d.op = .Mul
			case 1: d.op = .Mulh
			case 2: d.op = .Mulhsu
			case 3: d.op = .Mulhu
			case 4: d.op = .Div
			case 5: d.op = .Divu
			case 6: d.op = .Rem
			case 7: d.op = .Remu
			}
		}
	case 0x1B:
		switch f3 {
		case 0: d.op, d.imm = .Addiw, imm_i
		case 1:
			if f7 == 0 {
				d.op, d.imm = .Slliw, imm_i & 31
			}
		case 5:
			switch f7 {
			case 0x00: d.op, d.imm = .Srliw, imm_i & 31
			case 0x20: d.op, d.imm = .Sraiw, imm_i & 31
			}
		}
	case 0x3B:
		switch f7 {
		case 0x00:
			switch f3 {
			case 0: d.op = .Addw
			case 1: d.op = .Sllw
			case 5: d.op = .Srlw
			}
		case 0x20:
			switch f3 {
			case 0: d.op = .Subw
			case 5: d.op = .Sraw
			}
		case 0x01:
			switch f3 {
			case 0: d.op = .Mulw
			case 4: d.op = .Divw
			case 5: d.op = .Divuw
			case 6: d.op = .Remw
			case 7: d.op = .Remuw
			}
		}
	case 0x0F:
		if f3 <= 1 {
			d.op = .Fence
		}
	case 0x73:
		switch inst {
		case 0x00000073: d.op = .Ecall
		case 0x00100073: d.op = .Ebreak
		}
	}
	return d
}
