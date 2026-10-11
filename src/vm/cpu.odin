// Package vm is a user-mode RV64GC (IMAFDC + Zicsr) interpreter.
//
// It knows nothing about syscalls, pages or the browser: `run` executes until
// the instruction budget is spent, an `ecall`/`ebreak` is reached, or a fault
// occurs, and returns to the caller, which decides what happens next.
package vm

Stop_Reason :: enum u8 {
	Budget, // executed `budget` instructions; call run again to continue
	Ecall,  // pc already points past the ecall; handle it, set a0, call run again
	Ebreak, // pc points at the ebreak
	Fault,  // see Cpu.fault; the page cannot continue
}

Fault_Kind :: enum u8 {
	None,
	Illegal_Instruction,
	Fetch_Access,
	Load_Access,
	Store_Access,
	Misaligned_Atomic,
}

Fault :: struct {
	kind: Fault_Kind,
	pc:   u64,
	addr: u64, // faulting data address, for access faults
	inst: u32, // raw instruction (16-bit compressed instructions are zero-extended)
}

Cpu :: struct {
	x:           [32]u64,
	f:           [32]u64, // raw bits; singles are NaN-boxed
	pc:          u64,
	fcsr:        u32,     // frm in bits 7:5, fflags in bits 4:0
	reservation: u64,
	reserved:    bool,
	instret:     u64,
	mem:         Memory,
	fault:       Fault,
}

// ABI register numbers.
REG_RA :: 1
REG_SP :: 2
REG_GP :: 3
REG_TP :: 4
REG_A0 :: 10
REG_A1 :: 11
REG_A2 :: 12
REG_A3 :: 13
REG_A4 :: 14
REG_A5 :: 15
REG_A7 :: 17

// Runs until one of the Stop_Reasons. `executed` counts retired instructions,
// including a final ecall.
run :: proc(cpu: ^Cpu, budget: u64) -> (reason: Stop_Reason, executed: u64) {
	for executed < budget {
		r, stopped := step(cpu)
		if r != .Fault {
			executed += 1
		}
		if stopped {
			cpu.instret += executed
			return r, executed
		}
	}
	cpu.instret += executed
	return .Budget, executed
}

// Executes one instruction. `stopped` is false when execution can simply continue.
step :: proc(cpu: ^Cpu) -> (reason: Stop_Reason, stopped: bool) {
	pc := cpu.pc
	lo, ok := fetch16(&cpu.mem, pc)
	if !ok {
		return set_fault(cpu, .Fetch_Access, 0, pc), true
	}
	if lo & 3 != 3 {
		inst, valid := expand_compressed(lo)
		if !valid {
			return set_fault(cpu, .Illegal_Instruction, u32(lo)), true
		}
		return execute(cpu, inst, 2)
	}
	hi, ok2 := fetch16(&cpu.mem, pc + 2)
	if !ok2 {
		return set_fault(cpu, .Fetch_Access, u32(lo), pc + 2), true
	}
	return execute(cpu, u32(lo) | u32(hi) << 16, 4)
}

@(private)
set_fault :: proc "contextless" (cpu: ^Cpu, kind: Fault_Kind, inst: u32, addr: u64 = 0) -> Stop_Reason {
	cpu.fault = {kind = kind, pc = cpu.pc, addr = addr, inst = inst}
	return .Fault
}

@(private)
sext32 :: #force_inline proc "contextless" (v: u64) -> u64 {
	return u64(i64(i32(u32(v))))
}

@(private)
execute :: proc(cpu: ^Cpu, inst: u32, length: u64) -> (Stop_Reason, bool) {
	opcode := inst & 0x7F
	rd := (inst >> 7) & 31
	f3 := (inst >> 12) & 7
	rs1 := (inst >> 15) & 31
	rs2 := (inst >> 20) & 31
	f7 := inst >> 25

	x := &cpu.x
	a := x[rs1]
	b := x[rs2]
	pc := cpu.pc
	next := pc + length
	result: u64
	write := true

	imm_i := u64(i64(i32(inst)) >> 20)

	illegal :: #force_inline proc "contextless" (cpu: ^Cpu, inst: u32) -> (Stop_Reason, bool) {
		return set_fault(cpu, .Illegal_Instruction, inst), true
	}

	switch opcode {
	case 0x37: // LUI
		result = u64(i64(i32(inst & 0xFFFFF000)))

	case 0x17: // AUIPC
		result = pc + u64(i64(i32(inst & 0xFFFFF000)))

	case 0x6F: // JAL
		imm := (i64(i32(inst)) >> 31) << 20 | i64((inst >> 12) & 0xFF) << 12 | i64((inst >> 20) & 1) << 11 | i64((inst >> 21) & 0x3FF) << 1
		result = next
		next = pc + u64(imm)

	case 0x67: // JALR
		if f3 != 0 {
			return illegal(cpu, inst)
		}
		result = next
		next = (a + imm_i) &~ 1

	case 0x63: // BRANCH
		imm := (i64(i32(inst)) >> 31) << 12 | i64((inst >> 7) & 1) << 11 | i64((inst >> 25) & 0x3F) << 5 | i64((inst >> 8) & 0xF) << 1
		taken: bool
		switch f3 {
		case 0: taken = a == b
		case 1: taken = a != b
		case 4: taken = i64(a) < i64(b)
		case 5: taken = i64(a) >= i64(b)
		case 6: taken = a < b
		case 7: taken = a >= b
		case:   return illegal(cpu, inst)
		}
		if taken {
			next = pc + u64(imm)
		}
		write = false

	case 0x03: // LOAD
		addr := a + imm_i
		ok: bool
		switch f3 {
		case 0: result, ok = load(&cpu.mem, addr, 1); result = u64(i64(i8(u8(result))))
		case 1: result, ok = load(&cpu.mem, addr, 2); result = u64(i64(i16(u16(result))))
		case 2: result, ok = load(&cpu.mem, addr, 4); result = sext32(result)
		case 3: result, ok = load(&cpu.mem, addr, 8)
		case 4: result, ok = load(&cpu.mem, addr, 1)
		case 5: result, ok = load(&cpu.mem, addr, 2)
		case 6: result, ok = load(&cpu.mem, addr, 4)
		case:   return illegal(cpu, inst)
		}
		if !ok {
			return set_fault(cpu, .Load_Access, inst, addr), true
		}

	case 0x23: // STORE
		imm := u64((i64(i32(inst)) >> 25) << 5 | i64((inst >> 7) & 0x1F))
		addr := a + imm
		ok: bool
		switch f3 {
		case 0: ok = store(&cpu.mem, addr, b, 1)
		case 1: ok = store(&cpu.mem, addr, b, 2)
		case 2: ok = store(&cpu.mem, addr, b, 4)
		case 3: ok = store(&cpu.mem, addr, b, 8)
		case:   return illegal(cpu, inst)
		}
		if !ok {
			return set_fault(cpu, .Store_Access, inst, addr), true
		}
		write = false

	case 0x13: // OP-IMM
		shamt := imm_i & 63
		switch f3 {
		case 0: result = a + imm_i
		case 1:
			if inst >> 26 != 0 {
				return illegal(cpu, inst)
			}
			result = a << shamt
		case 2: result = 1 if i64(a) < i64(imm_i) else 0
		case 3: result = 1 if a < imm_i else 0
		case 4: result = a ~ imm_i
		case 5:
			switch inst >> 26 {
			case 0x00: result = a >> shamt
			case 0x10: result = u64(i64(a) >> shamt)
			case:      return illegal(cpu, inst)
			}
		case 6: result = a | imm_i
		case 7: result = a & imm_i
		}

	case 0x33: // OP
		switch f7 {
		case 0x00:
			switch f3 {
			case 0: result = a + b
			case 1: result = a << (b & 63)
			case 2: result = 1 if i64(a) < i64(b) else 0
			case 3: result = 1 if a < b else 0
			case 4: result = a ~ b
			case 5: result = a >> (b & 63)
			case 6: result = a | b
			case 7: result = a & b
			}
		case 0x20:
			switch f3 {
			case 0: result = a - b
			case 5: result = u64(i64(a) >> (b & 63))
			case:   return illegal(cpu, inst)
			}
		case 0x01: // M
			switch f3 {
			case 0: result = a * b
			case 1: result = u64((i128(i64(a)) * i128(i64(b))) >> 64)
			case 2: result = u64((i128(i64(a)) * i128(b)) >> 64)
			case 3: result = u64((u128(a) * u128(b)) >> 64)
			case 4: result = u64(div_signed(i64(a), i64(b)))
			case 5: result = b == 0 ? max(u64) : a / b
			case 6: result = u64(rem_signed(i64(a), i64(b)))
			case 7: result = b == 0 ? a : a % b
			}
		case:
			return illegal(cpu, inst)
		}

	case 0x1B: // OP-IMM-32
		shamt := imm_i & 31
		switch f3 {
		case 0: result = sext32(a + imm_i)
		case 1:
			if f7 != 0 {
				return illegal(cpu, inst)
			}
			result = sext32(u64(u32(a) << shamt))
		case 5:
			switch f7 {
			case 0x00: result = sext32(u64(u32(a) >> shamt))
			case 0x20: result = u64(i64(i32(u32(a)) >> shamt))
			case:      return illegal(cpu, inst)
			}
		case:
			return illegal(cpu, inst)
		}

	case 0x3B: // OP-32
		a32, b32 := u32(a), u32(b)
		switch f7 {
		case 0x00:
			switch f3 {
			case 0: result = sext32(u64(a32 + b32))
			case 1: result = sext32(u64(a32 << (b32 & 31)))
			case 5: result = sext32(u64(a32 >> (b32 & 31)))
			case:   return illegal(cpu, inst)
			}
		case 0x20:
			switch f3 {
			case 0: result = sext32(u64(a32 - b32))
			case 5: result = u64(i64(i32(a32) >> (b32 & 31)))
			case:   return illegal(cpu, inst)
			}
		case 0x01:
			switch f3 {
			case 0: result = sext32(u64(a32 * b32))
			case 4: result = u64(i64(div_signed32(i32(a32), i32(b32))))
			case 5: result = sext32(u64(b32 == 0 ? max(u32) : a32 / b32))
			case 6: result = u64(i64(rem_signed32(i32(a32), i32(b32))))
			case 7: result = sext32(u64(b32 == 0 ? a32 : a32 % b32))
			case:   return illegal(cpu, inst)
			}
		case:
			return illegal(cpu, inst)
		}

	case 0x0F: // MISC-MEM: fence, fence.i. Single hart, no caches: nothing to do.
		if f3 > 1 {
			return illegal(cpu, inst)
		}
		write = false

	case 0x73: // SYSTEM
		switch f3 {
		case 0:
			cpu.pc = next
			switch inst {
			case 0x00000073: return .Ecall, true
			case 0x00100073:
				cpu.pc = pc
				return .Ebreak, true
			}
			cpu.pc = pc
			return illegal(cpu, inst)
		case 4:
			return illegal(cpu, inst)
		case:
			csr := inst >> 20
			src := u64(rs1) if f3 >= 5 else a
			old, readable := csr_read(cpu, csr)
			if !readable {
				return illegal(cpu, inst)
			}
			new_val: u64
			do_write := true
			switch f3 & 3 {
			case 1: new_val = src
			case 2: new_val = old | src;  do_write = rs1 != 0
			case 3: new_val = old &~ src; do_write = rs1 != 0
			}
			if do_write && !csr_write(cpu, csr, new_val) {
				return illegal(cpu, inst)
			}
			result = old
		}

	case 0x2F: // AMO
		r, s := exec_amo(cpu, inst, rd, f3, a, b)
		if s {
			return r, true
		}
		write = false

	case 0x07, 0x27, 0x43, 0x47, 0x4B, 0x4F, 0x53: // F and D
		r, s := exec_fp(cpu, inst, opcode)
		if s {
			return r, true
		}
		write = false

	case:
		return illegal(cpu, inst)
	}

	if write && rd != 0 {
		x[rd] = result
	}
	cpu.pc = next
	return .Budget, false
}

@(private)
div_signed :: #force_inline proc "contextless" (a, b: i64) -> i64 {
	if b == 0 { return -1 }
	if a == min(i64) && b == -1 { return a }
	return a / b
}

@(private)
rem_signed :: #force_inline proc "contextless" (a, b: i64) -> i64 {
	if b == 0 { return a }
	if a == min(i64) && b == -1 { return 0 }
	return a % b
}

@(private)
div_signed32 :: #force_inline proc "contextless" (a, b: i32) -> i32 {
	if b == 0 { return -1 }
	if a == min(i32) && b == -1 { return a }
	return a / b
}

@(private)
rem_signed32 :: #force_inline proc "contextless" (a, b: i32) -> i32 {
	if b == 0 { return a }
	if a == min(i32) && b == -1 { return 0 }
	return a % b
}

CSR_FFLAGS  :: 0x001
CSR_FRM     :: 0x002
CSR_FCSR    :: 0x003
CSR_CYCLE   :: 0xC00
CSR_INSTRET :: 0xC02

// `cycle` reports retired instructions so execution stays deterministic and
// pages get no high-resolution clock. `time` is deliberately absent.
@(private)
csr_read :: proc "contextless" (cpu: ^Cpu, csr: u32) -> (u64, bool) {
	switch csr {
	case CSR_FFLAGS:             return u64(cpu.fcsr & 0x1F), true
	case CSR_FRM:                return u64((cpu.fcsr >> 5) & 7), true
	case CSR_FCSR:               return u64(cpu.fcsr & 0xFF), true
	case CSR_CYCLE, CSR_INSTRET: return cpu.instret, true
	}
	return 0, false
}

@(private)
csr_write :: proc "contextless" (cpu: ^Cpu, csr: u32, v: u64) -> bool {
	switch csr {
	case CSR_FFLAGS: cpu.fcsr = (cpu.fcsr &~ 0x1F) | u32(v & 0x1F)
	case CSR_FRM:    cpu.fcsr = (cpu.fcsr &~ 0xE0) | u32(v & 7) << 5
	case CSR_FCSR:   cpu.fcsr = u32(v & 0xFF)
	case:            return false
	}
	return true
}

@(private)
exec_amo :: proc(cpu: ^Cpu, inst, rd, f3: u32, a, b: u64) -> (Stop_Reason, bool) {
	size: u64
	switch f3 {
	case 2: size = 4
	case 3: size = 8
	case:   return set_fault(cpu, .Illegal_Instruction, inst), true
	}
	if a & (size - 1) != 0 {
		return set_fault(cpu, .Misaligned_Atomic, inst, a), true
	}
	funct5 := inst >> 27

	read :: proc "contextless" (cpu: ^Cpu, addr, size: u64) -> (u64, bool) {
		if size == 4 {
			v, ok := load(&cpu.mem, addr, 4)
			return sext32(v), ok
		}
		return load(&cpu.mem, addr, 8)
	}
	write_mem :: proc "contextless" (cpu: ^Cpu, addr, v, size: u64) -> bool {
		if size == 4 {
			return store(&cpu.mem, addr, v, 4)
		}
		return store(&cpu.mem, addr, v, 8)
	}

	result: u64
	switch funct5 {
	case 0x02: // LR
		if (inst >> 20) & 31 != 0 {
			return set_fault(cpu, .Illegal_Instruction, inst), true
		}
		v, ok := read(cpu, a, size)
		if !ok {
			return set_fault(cpu, .Load_Access, inst, a), true
		}
		cpu.reservation = a
		cpu.reserved = true
		result = v
	case 0x03: // SC
		if cpu.reserved && cpu.reservation == a {
			if !write_mem(cpu, a, b, size) {
				return set_fault(cpu, .Store_Access, inst, a), true
			}
			result = 0
		} else {
			result = 1
		}
		cpu.reserved = false
	case:
		old, ok := read(cpu, a, size)
		if !ok {
			return set_fault(cpu, .Load_Access, inst, a), true
		}
		bb := b
		if size == 4 {
			bb = sext32(b)
		}
		v: u64
		switch funct5 {
		case 0x01: v = bb
		case 0x00: v = old + bb
		case 0x04: v = old ~ bb
		case 0x0C: v = old & bb
		case 0x08: v = old | bb
		case 0x10: v = old if i64(old) < i64(bb) else bb
		case 0x14: v = old if i64(old) > i64(bb) else bb
		case 0x18:
			if size == 4 {
				v = old if u32(old) < u32(bb) else bb
			} else {
				v = old if old < bb else bb
			}
		case 0x1C:
			if size == 4 {
				v = old if u32(old) > u32(bb) else bb
			} else {
				v = old if old > bb else bb
			}
		case:
			return set_fault(cpu, .Illegal_Instruction, inst), true
		}
		if !write_mem(cpu, a, v, size) {
			return set_fault(cpu, .Store_Access, inst, a), true
		}
		result = old
	}
	if rd != 0 {
		cpu.x[rd] = result
	}
	return .Budget, false
}
