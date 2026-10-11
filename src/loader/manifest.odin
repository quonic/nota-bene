package loader

import "base:runtime"
import "core:strconv"
import "core:strings"

import "../abi"

// Manifest declares what a page needs. It is plain UTF-8 text, one
// `key value` pair per line, embedded in the ELF section `.nb_manifest`:
//
//   # comments start with '#'
//   abi 1
//   title Hello, world
//   fetch nb://example.org      (repeatable: origins the page may contact)
//   storage 1M                  (persistent storage quota)
//
// Unknown keys are kept in `unknown` so the browser can warn about them
// without breaking pages written for a newer ABI.
Manifest :: struct {
	abi:     u32,
	title:   string,
	fetch:   [dynamic]string,
	storage: u64,
	unknown: [dynamic]string,

	allocator: runtime.Allocator,
}

MAX_MANIFEST_SIZE :: 64 * KiB

default_manifest :: proc(allocator := context.allocator) -> Manifest {
	return {
		abi       = abi.ABI_VERSION,
		fetch     = make([dynamic]string, allocator),
		unknown   = make([dynamic]string, allocator),
		allocator = allocator,
	}
}

parse_manifest :: proc(text: string, allocator := context.allocator) -> (mf: Manifest, ok: bool) {
	if len(text) > MAX_MANIFEST_SIZE {
		return {}, false
	}
	mf = default_manifest(allocator)
	defer if !ok {
		manifest_destroy(&mf)
	}

	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if len(l) == 0 || l[0] == '#' || l[0] == 0 {
			continue
		}
		key, value := split_kv(l)
		switch key {
		case "abi":
			v, vok := strconv.parse_u64_of_base(value, 10)
			if !vok || v > u64(max(u32)) {
				return mf, false
			}
			mf.abi = u32(v)
		case "title":
			delete(mf.title, allocator)
			mf.title = strings.clone(value, allocator)
		case "fetch":
			if len(value) == 0 {
				return mf, false
			}
			append(&mf.fetch, strings.clone(value, allocator))
		case "storage":
			mf.storage = parse_size(value) or_return
		case:
			append(&mf.unknown, strings.clone(key, allocator))
		}
	}
	return mf, true
}

manifest_destroy :: proc(mf: ^Manifest) {
	allocator := mf.allocator
	delete(mf.title, allocator)
	for s in mf.fetch {
		delete(s, allocator)
	}
	for s in mf.unknown {
		delete(s, allocator)
	}
	delete(mf.fetch)
	delete(mf.unknown)
	mf^ = {}
}
