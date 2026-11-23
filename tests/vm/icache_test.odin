package vm_test

import "core:testing"

import "../../src/vm"

// Instruction cache tests. Code is placed by hand in a small memory, from
// page 1 (0x1000) on, the way the loader maps .text.

ADDI_A0_1 :: u32(0x00100513) // addi a0, x0, 1
EBREAK    :: u32(0x00100073)
C_LI_A0_3 :: u16(0x450D)     // c.li a0, 3
C_NOP     :: u16(0x0001)

put16 :: proc(m: ^vm.Memory, addr: u64, v: u16) {
	m.data[addr] = u8(v)
	m.data[addr + 1] = u8(v >> 8)
}

put32 :: proc(m: ^vm.Memory, addr: u64, v: u32) {
	put16(m, addr, u16(v))
	put16(m, addr + 2, u16(v >> 16))
}

// Catches: memory_protect leaving a stale decoding in the cache, so patched
// code keeps running the old instruction.
@(test)
test_icache_patched_code_runs :: proc(t: ^testing.T) {
	cpu: vm.Cpu
	if !testing.expect(t, vm.memory_init(&cpu.mem, 4 * vm.PAGE_SIZE) == nil) {
		return
	}
	defer vm.memory_destroy(&cpu.mem)
	put32(&cpu.mem, 0x1000, ADDI_A0_1)
	put32(&cpu.mem, 0x1004, EBREAK)
	testing.expect(t, vm.memory_protect(&cpu.mem, 0x1000, vm.PAGE_SIZE, vm.PERMS_RX))

	cpu.pc = 0x1000
	reason, executed := vm.run(&cpu, 10)
	testing.expect_value(t, reason, vm.Stop_Reason.Ebreak)
	testing.expect_value(t, executed, 2)
	testing.expect_value(t, cpu.x[vm.REG_A0], 1)

	// Replace the 4-byte addi with two compressed instructions, as a debugger
	// would: through a writable mapping, never writable and executable at once.
	testing.expect(t, vm.memory_protect(&cpu.mem, 0x1000, vm.PAGE_SIZE, vm.PERMS_RW))
	code, ok := vm.memory_slice(&cpu.mem, 0x1000, 4, {.Write})
	if !testing.expect(t, ok) {
		return
	}
	code[0], code[1] = u8(C_LI_A0_3 & 0xFF), u8(C_LI_A0_3 >> 8)
	code[2], code[3] = u8(C_NOP & 0xFF), u8(C_NOP >> 8)
	testing.expect(t, vm.memory_protect(&cpu.mem, 0x1000, vm.PAGE_SIZE, vm.PERMS_RX))

	cpu.pc = 0x1000
	reason, executed = vm.run(&cpu, 10)
	testing.expect_value(t, reason, vm.Stop_Reason.Ebreak)
	testing.expect_value(t, executed, 3) // c.li, c.nop, ebreak
	testing.expect_value(t, cpu.x[vm.REG_A0], 3)
	testing.expect_value(t, cpu.pc, 0x1004)
}

// Catches: cached code still running after its page lost Exec.
@(test)
test_icache_exec_removed :: proc(t: ^testing.T) {
	cpu: vm.Cpu
	if !testing.expect(t, vm.memory_init(&cpu.mem, 4 * vm.PAGE_SIZE) == nil) {
		return
	}
	defer vm.memory_destroy(&cpu.mem)
	put32(&cpu.mem, 0x1000, EBREAK)
	vm.memory_protect(&cpu.mem, 0x1000, vm.PAGE_SIZE, vm.PERMS_RX)
	cpu.pc = 0x1000
	reason, _ := vm.run(&cpu, 1)
	testing.expect_value(t, reason, vm.Stop_Reason.Ebreak)

	vm.memory_protect(&cpu.mem, 0x1000, vm.PAGE_SIZE, vm.PERMS_R)
	reason, _ = vm.run(&cpu, 1)
	testing.expect_value(t, reason, vm.Stop_Reason.Fault)
	testing.expect_value(t, cpu.fault, vm.Fault{kind = .Fetch_Access, pc = 0x1000, addr = 0x1000})
}

// Catches: a 4-byte instruction whose upper half is on a non-executable page
// running (or faulting at the wrong address), both before it was ever cached
// and after the second page lost Exec. The fault reports the lower half.
@(test)
test_icache_straddling_fetch :: proc(t: ^testing.T) {
	cpu: vm.Cpu
	if !testing.expect(t, vm.memory_init(&cpu.mem, 4 * vm.PAGE_SIZE) == nil) {
		return
	}
	defer vm.memory_destroy(&cpu.mem)
	put32(&cpu.mem, 0x1FFE, ADDI_A0_1)
	put32(&cpu.mem, 0x2002, EBREAK)
	vm.memory_protect(&cpu.mem, 0x1000, vm.PAGE_SIZE, vm.PERMS_RX)
	vm.memory_protect(&cpu.mem, 0x2000, vm.PAGE_SIZE, vm.PERMS_R)
	want := vm.Fault{kind = .Fetch_Access, pc = 0x1FFE, addr = 0x2000, inst = ADDI_A0_1 & 0xFFFF}

	cpu.pc = 0x1FFE
	reason, executed := vm.run(&cpu, 10)
	testing.expect_value(t, reason, vm.Stop_Reason.Fault)
	testing.expect_value(t, executed, 0)
	testing.expect_value(t, cpu.fault, want)

	vm.memory_protect(&cpu.mem, 0x2000, vm.PAGE_SIZE, vm.PERMS_RX)
	reason, executed = vm.run(&cpu, 10)
	testing.expect_value(t, reason, vm.Stop_Reason.Ebreak)
	testing.expect_value(t, executed, 2)
	testing.expect_value(t, cpu.x[vm.REG_A0], 1)

	vm.memory_protect(&cpu.mem, 0x2000, vm.PAGE_SIZE, vm.PERMS_R)
	cpu.pc = 0x1FFE
	cpu.x[vm.REG_A0] = 0
	cpu.fault = {}
	instret := cpu.instret
	reason, executed = vm.run(&cpu, 10)
	testing.expect_value(t, reason, vm.Stop_Reason.Fault)
	testing.expect_value(t, executed, 0)
	testing.expect_value(t, cpu.instret, instret)
	testing.expect_value(t, cpu.fault, want)
	testing.expect_value(t, cpu.x[vm.REG_A0], 0)
}

// Catches: the cache, which spans the first to the last executable page,
// letting code run from a non-executable page between them.
@(test)
test_icache_gap_page_faults :: proc(t: ^testing.T) {
	cpu: vm.Cpu
	if !testing.expect(t, vm.memory_init(&cpu.mem, 4 * vm.PAGE_SIZE) == nil) {
		return
	}
	defer vm.memory_destroy(&cpu.mem)
	put32(&cpu.mem, 0x1000, EBREAK)
	put32(&cpu.mem, 0x2000, EBREAK)
	put32(&cpu.mem, 0x3000, EBREAK)
	vm.memory_protect(&cpu.mem, 0x1000, vm.PAGE_SIZE, vm.PERMS_RX)
	vm.memory_protect(&cpu.mem, 0x2000, vm.PAGE_SIZE, vm.PERMS_R)
	vm.memory_protect(&cpu.mem, 0x3000, vm.PAGE_SIZE, vm.PERMS_RX)

	for pc in ([]u64{0x1000, 0x3000}) {
		cpu.pc = pc
		reason, _ := vm.run(&cpu, 1)
		testing.expectf(t, reason == .Ebreak, "pc 0x%x: %v", pc, reason)
	}
	cpu.pc = 0x2000
	reason, _ := vm.run(&cpu, 1)
	testing.expect_value(t, reason, vm.Stop_Reason.Fault)
	testing.expect_value(t, cpu.fault, vm.Fault{kind = .Fetch_Access, pc = 0x2000, addr = 0x2000})
}

// Catches: memory_protect creating a writable and executable page, which
// would let stores change code the cache has already decoded.
@(test)
test_memory_protect_refuses_wx :: proc(t: ^testing.T) {
	m: vm.Memory
	testing.expect(t, vm.memory_init(&m, 2 * vm.PAGE_SIZE) == nil)
	defer vm.memory_destroy(&m)
	testing.expect(t, !vm.memory_protect(&m, 0, vm.PAGE_SIZE, {.Read, .Write, .Exec}))
	testing.expect(t, !vm.memory_protect(&m, 0, vm.PAGE_SIZE, {.Write, .Exec}))
	testing.expect(t, !vm.memory_check(&m, 0, 2, {.Exec}))
}

Cpu_State :: struct {
	x, f:    [32]u64,
	pc:      u64,
	fcsr:    u32,
	instret: u64,
}

cpu_state :: proc(cpu: ^vm.Cpu) -> Cpu_State {
	return {x = cpu.x, f = cpu.f, pc = cpu.pc, fcsr = cpu.fcsr, instret = cpu.instret}
}

// Catches: cached and freshly decoded execution disagreeing. The same
// program must end in the same state whether it runs in one go, or with the
// cache flushed halfway and then one instruction per run, as nbrun's
// --trace-inst does.
@(test)
test_icache_repeated_runs_agree :: proc(t: ^testing.T) {
	TOTAL :: 3_000_000
	SINGLE :: 5_000
	for variant in ([]string{"bench.c", "bench.nc"}) {
		a, b: vm.Cpu
		if !load_fixture(t, &a, variant) {
			return
		}
		defer vm.memory_destroy(&a.mem)
		if !load_fixture(t, &b, variant) {
			return
		}
		defer vm.memory_destroy(&b.mem)

		reason, executed := vm.run(&a, TOTAL)
		testing.expectf(t, reason == .Budget && executed == TOTAL, "%s: %v after %d", variant, reason, executed)

		text := b.pc &~ (vm.PAGE_SIZE - 1)
		vm.run(&b, TOTAL / 2)
		testing.expect(t, vm.memory_protect(&b.mem, text, vm.PAGE_SIZE, vm.PERMS_RX)) // flushes the cache
		for _ in 0 ..< SINGLE {
			vm.run(&b, 1)
		}
		reason, _ = vm.run(&b, TOTAL - TOTAL / 2 - SINGLE)
		testing.expectf(t, reason == .Budget, "%s: %v", variant, reason)

		testing.expectf(t, cpu_state(&a) == cpu_state(&b), "%s: runs disagree:\n%v\n%v", variant, cpu_state(&a), cpu_state(&b))
		testing.expect_value(t, a.instret, TOTAL)
	}
}
