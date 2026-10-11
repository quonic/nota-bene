package loader_test

import "core:fmt"
import "core:os"
import "core:testing"

import "../../src/loader"
import "../../src/vm"

FIXTURES :: #config(FIXTURES, "build/tests")

read_fixture :: proc(t: ^testing.T, name: string) -> []u8 {
	path := fmt.tprintf("%s/%s.elf", FIXTURES, name)
	data, err := os.read_entire_file(path, context.allocator)
	testing.expectf(t, err == nil, "cannot read %s (run ./build.sh fixtures): %v", path, err)
	return data
}

try_load :: proc(data: []u8, cfg := loader.DEFAULT_CONFIG) -> loader.Error {
	cpu: vm.Cpu
	img, err := loader.load(&cpu, data, cfg)
	if err == nil {
		loader.manifest_destroy(&img.manifest)
		vm.memory_destroy(&cpu.mem)
	}
	return err
}

// Patches the p_flags of the first PT_LOAD with the given flags (PF_X=1, PF_W=2, PF_R=4).
patch_first_load_flags :: proc(data: []u8, flags: u32) {
	phoff := int(data[32]) | int(data[33]) << 8
	phnum := int(data[56])
	for i in 0 ..< phnum {
		ph := phoff + i * 56
		if data[ph] == 1 { // PT_LOAD
			data[ph + 4] = u8(flags)
			return
		}
	}
}

@(test)
test_load_layout :: proc(t: ^testing.T) {
	data := read_fixture(t, "rv64i.nc")
	defer delete(data)
	cpu: vm.Cpu
	img, err := loader.load(&cpu, data)
	testing.expect_value(t, err, loader.Error.None)
	defer loader.manifest_destroy(&img.manifest)
	defer vm.memory_destroy(&cpu.mem)

	cfg := loader.DEFAULT_CONFIG
	testing.expect_value(t, cpu.pc, img.entry)
	testing.expect_value(t, img.stack_top, cfg.mem_size)
	testing.expect_value(t, cpu.x[vm.REG_SP], cfg.mem_size - 16)
	testing.expect(t, img.brk % vm.PAGE_SIZE == 0)
	testing.expect(t, img.brk < img.heap_limit)

	m := &cpu.mem
	testing.expect(t, !vm.memory_check(m, 0, 1, vm.PERMS_R), "null guard is mapped")
	testing.expect(t, vm.memory_check(m, img.entry, 4, vm.PERMS_RX), "entry is not executable")
	testing.expect(t, !vm.memory_check(m, img.entry, 4, {.Write}), "text is writable")
	testing.expect(t, vm.memory_check(m, img.stack_lo, 16, vm.PERMS_RW), "stack is not writable")
	testing.expect(t, !vm.memory_check(m, img.stack_lo - 8, 8, vm.PERMS_R), "stack guard is mapped")
	testing.expect(t, !vm.memory_check(m, img.brk, 1, vm.PERMS_R), "heap mapped before Mem_Grow")
}

@(test)
test_reject_bad_headers :: proc(t: ^testing.T) {
	data := read_fixture(t, "rv64i.nc")
	defer delete(data)

	testing.expect_value(t, try_load(data[:40]), loader.Error.Too_Small)

	bad := make([]u8, len(data))
	defer delete(bad)

	copy(bad, data); bad[1] = 'X'
	testing.expect_value(t, try_load(bad), loader.Error.Bad_Magic)
	copy(bad, data); bad[4] = 1
	testing.expect_value(t, try_load(bad), loader.Error.Not_64_Bit)
	copy(bad, data); bad[5] = 2
	testing.expect_value(t, try_load(bad), loader.Error.Not_Little_Endian)
	copy(bad, data); bad[18] = 62 // EM_X86_64
	testing.expect_value(t, try_load(bad), loader.Error.Not_RISCV)
	copy(bad, data); bad[16] = 3 // ET_DYN
	testing.expect_value(t, try_load(bad), loader.Error.Not_Executable)
	copy(bad, data); bad[48] |= 0x8 // RVE
	testing.expect_value(t, try_load(bad), loader.Error.Unsupported_Flags)
	copy(bad, data); bad[56] = 200 // phnum runs past the end of the file
	testing.expect_value(t, try_load(bad), loader.Error.Bad_Header)
}

@(test)
test_reject_write_exec :: proc(t: ^testing.T) {
	data := read_fixture(t, "rv64i.nc")
	defer delete(data)
	patch_first_load_flags(data, 7) // RWX
	testing.expect_value(t, try_load(data), loader.Error.Write_And_Exec)
}

@(test)
test_reject_bad_config :: proc(t: ^testing.T) {
	data := read_fixture(t, "rv64i.nc")
	defer delete(data)
	testing.expect_value(t, try_load(data, {mem_size = 12345, stack_size = 4096}), loader.Error.Bad_Config)
	testing.expect_value(t, try_load(data, {mem_size = 2 * loader.GiB, stack_size = 4096}), loader.Error.Bad_Config)
	testing.expect_value(t, try_load(data, {mem_size = 64 * loader.KiB, stack_size = 64 * loader.KiB}), loader.Error.Bad_Config)
	// A memory size too small for the segments.
	testing.expect_value(t, try_load(data, {mem_size = 0x11000 + 2 * vm.PAGE_SIZE, stack_size = vm.PAGE_SIZE}), loader.Error.Segment_Out_Of_Range)
}

@(test)
test_manifest_section :: proc(t: ^testing.T) {
	data := read_fixture(t, "manifest_ok")
	defer delete(data)
	cpu: vm.Cpu
	img, err := loader.load(&cpu, data)
	testing.expect_value(t, err, loader.Error.None)
	defer loader.manifest_destroy(&img.manifest)
	defer vm.memory_destroy(&cpu.mem)

	mf := img.manifest
	testing.expect_value(t, mf.abi, 1)
	testing.expect_value(t, mf.title, "Fixture")
	testing.expect_value(t, len(mf.fetch), 2)
	if len(mf.fetch) == 2 {
		testing.expect_value(t, mf.fetch[0], "nb://a.example")
		testing.expect_value(t, mf.fetch[1], "nb://b.example")
	}
	testing.expect_value(t, mf.storage, 2 * loader.MiB)
	testing.expect_value(t, len(mf.unknown), 1)
}

@(test)
test_manifest_rejections :: proc(t: ^testing.T) {
	future := read_fixture(t, "manifest_future")
	defer delete(future)
	testing.expect_value(t, try_load(future), loader.Error.Unsupported_ABI)

	bad := read_fixture(t, "manifest_bad")
	defer delete(bad)
	testing.expect_value(t, try_load(bad), loader.Error.Bad_Manifest)
}

@(test)
test_no_manifest_defaults :: proc(t: ^testing.T) {
	data := read_fixture(t, "rv64i.c")
	defer delete(data)
	cpu: vm.Cpu
	img, err := loader.load(&cpu, data)
	testing.expect_value(t, err, loader.Error.None)
	defer loader.manifest_destroy(&img.manifest)
	defer vm.memory_destroy(&cpu.mem)
	testing.expect_value(t, img.manifest.abi, 1)
	testing.expect_value(t, len(img.manifest.fetch), 0)
}

@(test)
test_parse_manifest :: proc(t: ^testing.T) {
	mf, ok := loader.parse_manifest("# comment\n\n  abi 1  \ntitle   Spaced   out\r\nfetch nb://x\n")
	testing.expect(t, ok)
	defer loader.manifest_destroy(&mf)
	testing.expect_value(t, mf.title, "Spaced   out")
	testing.expect_value(t, len(mf.fetch), 1)

	_, ok = loader.parse_manifest("abi -1\n")
	testing.expect(t, !ok)
	_, ok = loader.parse_manifest("fetch\n")
	testing.expect(t, !ok)
}

@(test)
test_parse_size :: proc(t: ^testing.T) {
	Case :: struct {
		s:  string,
		v:  u64,
		ok: bool,
	}
	cases := []Case{
		{"4096", 4096, true},
		{"64K", 64 * 1024, true},
		{"64M", 64 * 1024 * 1024, true},
		{"1g", 1024 * 1024 * 1024, true},
		{"", 0, false},
		{"M", 0, false},
		{"12Q", 0, false},
		{"99999999999999999G", 0, false},
	}
	for c in cases {
		v, ok := loader.parse_size(c.s)
		testing.expectf(t, ok == c.ok && v == c.v, "parse_size(%q) = %d, %v; want %d, %v", c.s, v, ok, c.v, c.ok)
	}
}
