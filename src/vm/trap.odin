package vm

import "core:fmt"

// Human-readable description of a fault, for logs and the runner.
describe_fault :: proc(f: Fault, allocator := context.allocator) -> string {
	switch f.kind {
	case .None:
		return fmt.aprintf("no fault", allocator = allocator)
	case .Illegal_Instruction:
		hint := ""
		if f.inst == 0 || f.inst == 0xC0001073 {
			hint = " (unimp: an Odin runtime trap, e.g. a failed bounds check)"
		}
		return fmt.aprintf("illegal instruction %s at pc 0x%x%s", inst_hex(f.inst), f.pc, hint, allocator = allocator)
	case .Fetch_Access:
		return fmt.aprintf("instruction fetch from non-executable address 0x%x (pc 0x%x)", f.addr, f.pc, allocator = allocator)
	case .Load_Access:
		return fmt.aprintf("load from 0x%x not permitted (pc 0x%x, %s)", f.addr, f.pc, inst_hex(f.inst), allocator = allocator)
	case .Store_Access:
		return fmt.aprintf("store to 0x%x not permitted (pc 0x%x, %s)", f.addr, f.pc, inst_hex(f.inst), allocator = allocator)
	case .Misaligned_Atomic:
		return fmt.aprintf("misaligned atomic access at 0x%x (pc 0x%x)", f.addr, f.pc, allocator = allocator)
	}
	return ""
}

@(private)
inst_hex :: proc(inst: u32) -> string {
	if inst & 3 != 3 && inst <= 0xFFFF {
		return fmt.tprintf("0x%04x", inst)
	}
	return fmt.tprintf("0x%08x", inst)
}
