// Package loader maps a RISC-V ELF64 page executable into a fresh VM.
//
// Accepted input: little-endian ELF64, EM_RISCV, ET_EXEC (statically linked,
// non-PIC; the SDK build produces this). PT_LOAD segments are copied in and
// their pages protected R, RX or RW; a segment that is both W and X, or that
// shares a page with one so that a page would become W+X, is rejected.
//
// Guest memory layout:
//
//   0x0 .. NULL_GUARD         unmapped (null dereferences fault)
//   segments ..               text RX, rodata R, data/bss RW
//   brk .. heap_limit         heap, grown with Mem_Grow
//   one page                  unmapped stack guard
//   stack_lo .. mem_size      stack, sp starts at the top
package loader

import "core:strconv"
import "core:strings"

import "../abi"
import "../vm"

KiB :: 1024
MiB :: 1024 * KiB
GiB :: 1024 * MiB

NULL_GUARD   :: 0x10000
MAX_MEM_SIZE :: 1 * GiB

Config :: struct {
	mem_size:   u64,
	stack_size: u64,
}

DEFAULT_CONFIG :: Config {
	mem_size   = 64 * MiB,
	stack_size = 1 * MiB,
}

Image :: struct {
	entry:      u64,
	brk:        u64, // current program break; the heap is [initial brk, brk)
	heap_limit: u64,
	stack_lo:   u64,
	stack_top:  u64,
	manifest:   Manifest,
}

Error :: enum {
	None,
	Bad_Config,
	Too_Small,
	Bad_Magic,
	Not_64_Bit,
	Not_Little_Endian,
	Not_RISCV,
	Not_Executable, // ET_DYN / ET_REL: build with -reloc-mode:static
	Unsupported_Flags,
	Bad_Header,
	Bad_Segment,
	Segment_Out_Of_Range,
	Write_And_Exec,
	Bad_Entry,
	No_Memory,
	Bad_Manifest,
	Unsupported_ABI,
}

@(private) ET_EXEC  :: 2
@(private) EM_RISCV :: 243
@(private) PT_LOAD  :: 1
@(private) PF_X     :: 1
@(private) PF_W     :: 2
@(private) PF_R     :: 4
@(private) EF_RISCV_RVE :: 0x8

MANIFEST_SECTION :: ".nb_manifest"

@(private) le16 :: #force_inline proc "contextless" (b: []u8, o: u64) -> u64 { return u64(b[o]) | u64(b[o + 1]) << 8 }
@(private) le32 :: #force_inline proc "contextless" (b: []u8, o: u64) -> u64 { return le16(b, o) | le16(b, o + 2) << 16 }
@(private) le64 :: #force_inline proc "contextless" (b: []u8, o: u64) -> u64 { return le32(b, o) | le32(b, o + 4) << 32 }

@(private)
in_file :: proc "contextless" (file: []u8, off, size: u64) -> bool {
	end := off + size
	return end >= off && end <= u64(len(file))
}

@(private)
align_up :: proc "contextless" (v, a: u64) -> u64 {
	return (v + a - 1) &~ (a - 1)
}

// Allocates guest memory in `cpu`, maps the executable and sets pc and sp.
// On error the cpu's memory is released again.
load :: proc(cpu: ^vm.Cpu, file: []u8, cfg := DEFAULT_CONFIG, allocator := context.allocator) -> (img: Image, err: Error) {
	if cfg.mem_size == 0 || cfg.mem_size % vm.PAGE_SIZE != 0 || cfg.mem_size > MAX_MEM_SIZE ||
	   cfg.stack_size == 0 || cfg.stack_size % vm.PAGE_SIZE != 0 ||
	   cfg.stack_size + vm.PAGE_SIZE + NULL_GUARD >= cfg.mem_size {
		return {}, .Bad_Config
	}

	if len(file) < 64 { return {}, .Too_Small }
	if file[0] != 0x7F || file[1] != 'E' || file[2] != 'L' || file[3] != 'F' { return {}, .Bad_Magic }
	if file[4] != 2 { return {}, .Not_64_Bit }
	if file[5] != 1 { return {}, .Not_Little_Endian }
	if le16(file, 18) != EM_RISCV { return {}, .Not_RISCV }
	if le16(file, 16) != ET_EXEC { return {}, .Not_Executable }
	if le32(file, 48) & EF_RISCV_RVE != 0 { return {}, .Unsupported_Flags }

	entry := le64(file, 24)
	phoff := le64(file, 32)
	phentsize := le16(file, 54)
	phnum := le16(file, 56)
	if phentsize != 56 || phnum == 0 || !in_file(file, phoff, phnum * 56) {
		return {}, .Bad_Header
	}

	if vm.memory_init(&cpu.mem, cfg.mem_size, allocator) != nil {
		return {}, .No_Memory
	}
	defer if err != nil {
		vm.memory_destroy(&cpu.mem, allocator)
	}
	m := &cpu.mem

	img.stack_top = cfg.mem_size
	img.stack_lo = cfg.mem_size - cfg.stack_size
	img.heap_limit = img.stack_lo - vm.PAGE_SIZE

	max_end: u64 = NULL_GUARD
	for i in 0 ..< phnum {
		ph := phoff + i * 56
		if le32(file, ph) != PT_LOAD {
			continue
		}
		flags := le32(file, ph + 4)
		offset := le64(file, ph + 8)
		vaddr := le64(file, ph + 16)
		filesz := le64(file, ph + 32)
		memsz := le64(file, ph + 40)

		if filesz > memsz || !in_file(file, offset, filesz) {
			return {}, .Bad_Segment
		}
		if memsz == 0 {
			continue
		}
		end := vaddr + memsz
		if vaddr < NULL_GUARD || end < vaddr || end > img.heap_limit {
			return {}, .Segment_Out_Of_Range
		}
		if flags & PF_W != 0 && flags & PF_X != 0 {
			return {}, .Write_And_Exec
		}

		perms := vm.PERMS_R
		if flags & PF_X != 0 { perms = vm.PERMS_RX }
		if flags & PF_W != 0 { perms = vm.PERMS_RW }

		for p := vaddr >> vm.PAGE_SHIFT; p <= (end - 1) >> vm.PAGE_SHIFT; p += 1 {
			merged := m.perms[p] | perms
			if .Write in merged && .Exec in merged {
				return {}, .Write_And_Exec
			}
			m.perms[p] = merged
		}
		copy(m.data[vaddr:][:filesz], file[offset:][:filesz])
		max_end = max(max_end, end)
	}

	if !vm.memory_check(m, entry, 2, vm.PERMS_RX) {
		return {}, .Bad_Entry
	}

	img.entry = entry
	img.brk = align_up(max_end, vm.PAGE_SIZE)
	vm.memory_protect(m, img.stack_lo, cfg.stack_size, vm.PERMS_RW)

	img.manifest, err = read_manifest(file, allocator)
	if err != nil {
		return {}, err
	}
	if img.manifest.abi > abi.ABI_VERSION {
		manifest_destroy(&img.manifest)
		return {}, .Unsupported_ABI
	}

	cpu.pc = entry
	cpu.x[vm.REG_SP] = img.stack_top - 16
	return img, nil
}

// Finds the .nb_manifest section, if any, and parses it.
@(private)
read_manifest :: proc(file: []u8, allocator := context.allocator) -> (Manifest, Error) {
	shoff := le64(file, 40)
	shentsize := le16(file, 58)
	shnum := le16(file, 60)
	shstrndx := le16(file, 62)
	if shoff == 0 || shnum == 0 {
		return default_manifest(allocator), nil
	}
	if shentsize != 64 || shstrndx >= shnum || !in_file(file, shoff, shnum * 64) {
		return {}, .Bad_Header
	}
	strtab := shoff + shstrndx * 64
	str_off := le64(file, strtab + 24)
	str_size := le64(file, strtab + 32)
	if !in_file(file, str_off, str_size) {
		return {}, .Bad_Header
	}
	names := file[str_off:][:str_size]

	for i in 0 ..< shnum {
		sh := shoff + i * 64
		name_off := le32(file, sh)
		if name_off >= str_size {
			continue
		}
		name_bytes := names[name_off:]
		n := 0
		for n < len(name_bytes) && name_bytes[n] != 0 {
			n += 1
		}
		if string(name_bytes[:n]) != MANIFEST_SECTION {
			continue
		}
		off := le64(file, sh + 24)
		size := le64(file, sh + 32)
		if !in_file(file, off, size) {
			return {}, .Bad_Manifest
		}
		mf, ok := parse_manifest(string(file[off:][:size]), allocator)
		if !ok {
			return {}, .Bad_Manifest
		}
		return mf, nil
	}
	return default_manifest(allocator), nil
}

// Parses sizes such as "4096", "64K", "64M", "1G".
parse_size :: proc(s: string) -> (u64, bool) {
	if len(s) == 0 {
		return 0, false
	}
	mult: u64 = 1
	num := s
	switch s[len(s) - 1] {
	case 'K', 'k': mult = KiB
	case 'M', 'm': mult = MiB
	case 'G', 'g': mult = GiB
	}
	if mult != 1 {
		num = s[:len(s) - 1]
	}
	v, ok := strconv.parse_u64_of_base(num, 10)
	if !ok || (v != 0 && v * mult / v != mult) {
		return 0, false
	}
	return v * mult, true
}

// Splits a manifest line into key and value.
@(private)
split_kv :: proc(line: string) -> (key, value: string) {
	l := strings.trim_space(line)
	i := strings.index_any(l, " \t")
	if i < 0 {
		return l, ""
	}
	return l[:i], strings.trim_space(l[i:])
}
