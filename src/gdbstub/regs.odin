package gdbstub

import "core:fmt"
import "core:strings"

import "../vm"

// Register numbers as GDB's riscv target numbers them: x0..x31, pc, f0..f31,
// then the CSRs at 65 + their CSR number (fflags 0x001, frm 0x002, fcsr 0x003).
REG_PC     :: 32
REG_F0     :: 33
REG_FFLAGS :: 66
REG_FRM    :: 67
REG_FCSR   :: 68

// The `g` packet holds every register in number order, with no gap for 65.
G_REGS :: [?]int{
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
	16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
	REG_PC,
	33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48,
	49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64,
	REG_FFLAGS, REG_FRM, REG_FCSR,
}

@(private)
X_NAMES := [32]string{
	"zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "fp", "s1",
	"a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7",
	"s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11",
	"t3", "t4", "t5", "t6",
}

@(private)
F_NAMES := [32]string{
	"ft0", "ft1", "ft2", "ft3", "ft4", "ft5", "ft6", "ft7", "fs0", "fs1",
	"fa0", "fa1", "fa2", "fa3", "fa4", "fa5", "fa6", "fa7",
	"fs2", "fs3", "fs4", "fs5", "fs6", "fs7", "fs8", "fs9", "fs10", "fs11",
	"ft8", "ft9", "ft10", "ft11",
}

// Byte size of register n in packets, or 0 if there is no such register.
reg_size :: proc(n: int) -> int {
	switch n {
	case 0 ..= 64:                 return 8
	case REG_FFLAGS ..= REG_FCSR:  return 4
	}
	return 0
}

reg_get :: proc(cpu: ^vm.Cpu, n: int) -> u64 {
	switch n {
	case 0 ..< 32:      return cpu.x[n]
	case REG_PC:        return cpu.pc
	case REG_F0 ..= 64: return cpu.f[n - REG_F0]
	case REG_FFLAGS:    return u64(cpu.fcsr & 0x1f)
	case REG_FRM:       return u64(cpu.fcsr >> 5 & 7)
	case REG_FCSR:      return u64(cpu.fcsr & 0xff)
	}
	return 0
}

reg_set :: proc(cpu: ^vm.Cpu, n: int, v: u64) {
	switch n {
	case 1 ..< 32:      cpu.x[n] = v // x0 stays zero
	case REG_PC:        cpu.pc = v
	case REG_F0 ..= 64: cpu.f[n - REG_F0] = v
	case REG_FFLAGS:    cpu.fcsr = cpu.fcsr & ~u32(0x1f) | u32(v) & 0x1f
	case REG_FRM:       cpu.fcsr = cpu.fcsr & ~u32(0xe0) | (u32(v) & 7) << 5
	case REG_FCSR:      cpu.fcsr = u32(v) & 0xff
	}
}

// The target description GDB fetches with qXfer:features:read. Feature and
// register names follow GDB's own features/riscv/64bit-{cpu,fpu}.xml.
target_xml :: proc(allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, `<?xml version="1.0"?>
<!DOCTYPE target SYSTEM "gdb-target.dtd">
<target version="1.0">
<architecture>riscv:rv64</architecture>
<feature name="org.gnu.gdb.riscv.cpu">
`)
	for name, i in X_NAMES {
		type := "int"
		switch i {
		case 1:    type = "code_ptr"
		case 2..=4: type = "data_ptr"
		}
		fmt.sbprintf(&sb, "<reg name=\"%s\" bitsize=\"64\" type=\"%s\" regnum=\"%d\"/>\n", name, type, i)
	}
	fmt.sbprintf(&sb, "<reg name=\"pc\" bitsize=\"64\" type=\"code_ptr\" regnum=\"%d\"/>\n", REG_PC)
	strings.write_string(&sb, `</feature>
<feature name="org.gnu.gdb.riscv.fpu">
<union id="riscv_double"><field name="float" type="ieee_single"/><field name="double" type="ieee_double"/></union>
`)
	for name, i in F_NAMES {
		fmt.sbprintf(&sb, "<reg name=\"%s\" bitsize=\"64\" type=\"riscv_double\" regnum=\"%d\"/>\n", name, REG_F0 + i)
	}
	fmt.sbprintf(&sb, "<reg name=\"fflags\" bitsize=\"32\" type=\"int\" regnum=\"%d\"/>\n", REG_FFLAGS)
	fmt.sbprintf(&sb, "<reg name=\"frm\" bitsize=\"32\" type=\"int\" regnum=\"%d\"/>\n", REG_FRM)
	fmt.sbprintf(&sb, "<reg name=\"fcsr\" bitsize=\"32\" type=\"int\" regnum=\"%d\"/>\n", REG_FCSR)
	strings.write_string(&sb, "</feature>\n</target>\n")
	return strings.to_string(sb)
}
