package vm

import "core:mem"

PAGE_SIZE  :: 4096
PAGE_SHIFT :: 12

Perm :: enum u8 {
	Read,
	Write,
	Exec,
}
Perms :: bit_set[Perm; u8]

PERMS_NONE :: Perms{}
PERMS_RX   :: Perms{.Read, .Exec}
PERMS_R    :: Perms{.Read}
PERMS_RW   :: Perms{.Read, .Write}

// Memory is a page's flat guest address space. Guest address N is data[N].
// Every access is bounds-checked and checked against per-4KiB-page permissions,
// which is how the null guard, W^X and stack guard are enforced.
Memory :: struct {
	data:  []u8,
	perms: []Perms,
}

memory_init :: proc(m: ^Memory, size: u64, allocator := context.allocator) -> mem.Allocator_Error {
	assert(size % PAGE_SIZE == 0 && size > 0)
	m.data = make([]u8, int(size), allocator) or_return
	m.perms = make([]Perms, int(size / PAGE_SIZE), allocator) or_return
	return nil
}

memory_destroy :: proc(m: ^Memory, allocator := context.allocator) {
	delete(m.data, allocator)
	delete(m.perms, allocator)
	m^ = {}
}

memory_size :: #force_inline proc "contextless" (m: ^Memory) -> u64 {
	return u64(len(m.data))
}

// Sets permissions for every page overlapping [addr, addr+size).
memory_protect :: proc(m: ^Memory, addr, size: u64, perms: Perms) -> bool {
	if size == 0 {
		return true
	}
	end := addr + size
	if end < addr || end > memory_size(m) {
		return false
	}
	for p := addr >> PAGE_SHIFT; p <= (end - 1) >> PAGE_SHIFT; p += 1 {
		m.perms[p] = perms
	}
	return true
}

// Reports whether [addr, addr+size) is inside memory and every page has `need`.
memory_check :: #force_inline proc "contextless" (m: ^Memory, addr, size: u64, need: Perms) -> bool {
	end := addr + size
	if end < addr || end > u64(len(m.data)) {
		return false
	}
	if size == 0 {
		return true
	}
	first := addr >> PAGE_SHIFT
	last := (end - 1) >> PAGE_SHIFT
	if !(need <= m.perms[first]) {
		return false
	}
	// An access spans at most two pages unless it is a host-side bulk range.
	for p := first + 1; p <= last; p += 1 {
		if !(need <= m.perms[p]) {
			return false
		}
	}
	return true
}

// Returns a view of guest memory if the range is valid for `need`.
// Used by the host to read and write syscall buffers.
memory_slice :: proc "contextless" (m: ^Memory, addr, size: u64, need: Perms) -> ([]u8, bool) {
	if !memory_check(m, addr, size, need) {
		return nil, false
	}
	return m.data[addr:][:size], true
}

// Little-endian load of 1, 2, 4 or 8 bytes, zero-extended. Misaligned addresses are allowed.
load :: #force_inline proc "contextless" (m: ^Memory, addr: u64, $N: u64) -> (u64, bool) {
	if !memory_check(m, addr, N, PERMS_R) {
		return 0, false
	}
	v: u64
	p := m.data[addr:]
	#unroll for i in 0 ..< N {
		v |= u64(p[i]) << (8 * i)
	}
	return v, true
}

store :: #force_inline proc "contextless" (m: ^Memory, addr: u64, v: u64, $N: u64) -> bool {
	if !memory_check(m, addr, N, {.Write}) {
		return false
	}
	p := m.data[addr:]
	#unroll for i in 0 ..< N {
		p[i] = u8(v >> (8 * i))
	}
	return true
}

// Instruction fetch: 16 bits at a time so compressed instructions work.
fetch16 :: #force_inline proc "contextless" (m: ^Memory, addr: u64) -> (u16, bool) {
	if !memory_check(m, addr, 2, PERMS_RX) {
		return 0, false
	}
	return u16(m.data[addr]) | u16(m.data[addr + 1]) << 8, true
}
