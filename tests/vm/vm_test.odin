package vm_test

import "core:fmt"
import "core:os"
import "core:testing"

import "../../src/loader"
import "../../src/vm"

FIXTURES :: #config(FIXTURES, "build/tests")

// Loads a fixture ELF into a fresh CPU. The caller destroys cpu.mem.
load_fixture :: proc(t: ^testing.T, cpu: ^vm.Cpu, name: string) -> bool {
	path := fmt.tprintf("%s/%s.elf", FIXTURES, name)
	data, err := os.read_entire_file(path, context.allocator)
	if !testing.expectf(t, err == nil, "cannot read %s (run ./build.sh fixtures): %v", path, err) {
		return false
	}
	defer delete(data)
	img, lerr := loader.load(cpu, data)
	if !testing.expectf(t, lerr == nil, "cannot load %s: %v", path, lerr) {
		return false
	}
	loader.manifest_destroy(&img.manifest)
	return true
}

// Runs a fixture, treating ecall as the only syscall it may make: Exit(a0).
run_fixture :: proc(t: ^testing.T, name: string, budget: u64 = 10_000_000) -> (reason: vm.Stop_Reason, exit_code: u64, cpu: vm.Cpu) {
	if !load_fixture(t, &cpu, name) {
		return .Fault, 0, cpu
	}
	reason, _ = vm.run(&cpu, budget)
	if reason == .Ecall {
		testing.expectf(t, cpu.x[vm.REG_A7] == 0, "%s: unexpected syscall %d", name, cpu.x[vm.REG_A7])
		exit_code = cpu.x[vm.REG_A0]
	}
	return
}

expect_pass :: proc(t: ^testing.T, base: string) {
	for variant in ([]string{"c", "nc"}) {
		name := fmt.tprintf("%s.%s", base, variant)
		reason, code, cpu := run_fixture(t, name)
		defer vm.memory_destroy(&cpu.mem)
		if reason == .Fault {
			testing.expectf(t, false, "%s: %s", name, vm.describe_fault(cpu.fault, context.temp_allocator))
			continue
		}
		testing.expectf(t, reason == .Ecall, "%s: stopped with %v", name, reason)
		testing.expectf(t, code == 0, "%s: CHECK %d failed", name, code)
	}
}

expect_fault :: proc(t: ^testing.T, base: string, kind: vm.Fault_Kind) -> (addr: u64) {
	for variant in ([]string{"c", "nc"}) {
		name := fmt.tprintf("%s.%s", base, variant)
		reason, _, cpu := run_fixture(t, name)
		defer vm.memory_destroy(&cpu.mem)
		testing.expectf(t, reason == .Fault, "%s: expected a fault, got %v", name, reason)
		testing.expectf(t, cpu.fault.kind == kind, "%s: expected %v, got %v", name, kind, cpu.fault.kind)
		addr = cpu.fault.addr
	}
	return
}

@(test) test_rv64i  :: proc(t: ^testing.T) { expect_pass(t, "rv64i") }
@(test) test_rv64m  :: proc(t: ^testing.T) { expect_pass(t, "rv64m") }
@(test) test_rv64a  :: proc(t: ^testing.T) { expect_pass(t, "rv64a") }
@(test) test_rv64fd :: proc(t: ^testing.T) { expect_pass(t, "rv64fd") }

@(test)
test_fault_null :: proc(t: ^testing.T) {
	addr := expect_fault(t, "fault_null", .Load_Access)
	testing.expect_value(t, addr, 0)
}

@(test)
test_fault_text_write :: proc(t: ^testing.T) {
	expect_fault(t, "fault_text_write", .Store_Access)
}

@(test)
test_fault_exec_data :: proc(t: ^testing.T) {
	expect_fault(t, "fault_exec_data", .Fetch_Access)
}

@(test)
test_fault_illegal :: proc(t: ^testing.T) {
	expect_fault(t, "fault_illegal", .Illegal_Instruction)
}

@(test)
test_fault_out_of_bounds :: proc(t: ^testing.T) {
	expect_fault(t, "fault_oob", .Store_Access)
}

@(test)
test_fault_stack_overflow :: proc(t: ^testing.T) {
	addr := expect_fault(t, "fault_stack_overflow", .Store_Access)
	stack_lo := loader.DEFAULT_CONFIG.mem_size - loader.DEFAULT_CONFIG.stack_size
	testing.expectf(t, addr < stack_lo && addr >= stack_lo - vm.PAGE_SIZE, "fault at 0x%x is not in the stack guard page", addr)
}

@(test)
test_budget :: proc(t: ^testing.T) {
	cpu: vm.Cpu
	if !load_fixture(t, &cpu, "loop.c") {
		return
	}
	defer vm.memory_destroy(&cpu.mem)
	reason, executed := vm.run(&cpu, 12345)
	testing.expect_value(t, reason, vm.Stop_Reason.Budget)
	testing.expect_value(t, executed, 12345)
	testing.expect_value(t, cpu.instret, 12345)
	// Execution resumes where it stopped.
	reason, executed = vm.run(&cpu, 5)
	testing.expect_value(t, reason, vm.Stop_Reason.Budget)
	testing.expect_value(t, cpu.instret, 12350)
}

@(test)
test_ebreak :: proc(t: ^testing.T) {
	cpu: vm.Cpu
	if !load_fixture(t, &cpu, "ebreak.nc") {
		return
	}
	defer vm.memory_destroy(&cpu.mem)
	pc := cpu.pc
	reason, _ := vm.run(&cpu, 10)
	testing.expect_value(t, reason, vm.Stop_Reason.Ebreak)
	testing.expect_value(t, cpu.pc, pc) // left pointing at the ebreak
}

@(test)
test_compressed_expansion :: proc(t: ^testing.T) {
	Case :: struct {
		half: u16,
		want: u32,
	}
	cases := []Case{
		{0x4501, 0x00000513}, // c.li a0, 0        -> addi a0, x0, 0
		{0x1141, 0xff010113}, // c.addi sp, -16    -> addi sp, sp, -16
		{0x7139, 0xfc010113}, // c.addi16sp -64    -> addi sp, sp, -64
		{0x8082, 0x00008067}, // c.jr ra           -> jalr x0, 0(ra)
		{0x9002, 0x00100073}, // c.ebreak
		{0x77fd, 0xfffff7b7}, // c.lui a5, 0xfffff -> lui a5, 0xfffff
		{0xa001, 0x0000006f}, // c.j .             -> jal x0, 0
		{0xe406, 0x00113423}, // c.sdsp ra, 8(sp)  -> sd ra, 8(sp)
		{0x60a2, 0x00813083}, // c.ldsp ra, 8(sp)  -> ld ra, 8(sp)
	}
	for c in cases {
		got, ok := vm.expand_compressed(c.half)
		testing.expectf(t, ok, "0x%04x: rejected", c.half)
		testing.expectf(t, got == c.want, "0x%04x: expanded to 0x%08x, want 0x%08x", c.half, got, c.want)
	}
	// Reserved encodings.
	for half in ([]u16{0x0000, 0x8002 /* c.jr x0 */, 0x6001 /* c.lui x0? -> c.lui with imm 0 */}) {
		_, ok := vm.expand_compressed(half)
		testing.expectf(t, !ok, "0x%04x: should be illegal", half)
	}
}

@(test)
test_memory_permissions :: proc(t: ^testing.T) {
	m: vm.Memory
	testing.expect(t, vm.memory_init(&m, 4 * vm.PAGE_SIZE) == nil)
	defer vm.memory_destroy(&m)
	vm.memory_protect(&m, vm.PAGE_SIZE, vm.PAGE_SIZE, vm.PERMS_RW)
	vm.memory_protect(&m, 2 * vm.PAGE_SIZE, vm.PAGE_SIZE, vm.PERMS_R)

	testing.expect(t, !vm.memory_check(&m, 0, 1, vm.PERMS_R))                  // unmapped
	testing.expect(t, vm.memory_check(&m, vm.PAGE_SIZE, 8, {.Write}))
	testing.expect(t, !vm.memory_check(&m, 2 * vm.PAGE_SIZE - 4, 8, {.Write}))  // spans into read-only
	testing.expect(t, vm.memory_check(&m, 2 * vm.PAGE_SIZE - 4, 8, vm.PERMS_R)) // spans two readable pages
	testing.expect(t, !vm.memory_check(&m, 4 * vm.PAGE_SIZE - 4, 8, vm.PERMS_R)) // past the end
	testing.expect(t, !vm.memory_check(&m, max(u64) - 3, 8, vm.PERMS_R))        // address wraps
}
