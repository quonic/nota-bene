package host

import "core:encoding/cbor"
import "core:os"
import "core:strings"

import "../abi"

// Storage is one site's persistent key-value store. Front ends decide where
// it lives (one file per site, keyed by the site's identity) and attach it
// with page_attach_storage; a page without storage gets -PERM.
//
// The whole store is rewritten on every change, through a temporary file and
// a rename so a crash never leaves a half-written store. That is fine for the
// small quotas pages get (16 MiB at most).
Storage :: struct {
	path:    string, // "" keeps the store in memory only
	quota:   int,
	used:    int,
	entries: map[string][]u8,
}

@(private)
storage_cost :: proc "contextless" (key: string, value: []u8) -> int {
	return len(key) + len(value)
}

// Loads (or creates) the store at `path`. An unreadable or corrupt file
// starts an empty store rather than failing the page.
storage_open :: proc(st: ^Storage, path: string, quota: int) {
	st.path = strings.clone(path)
	st.quota = min(quota, abi.MAX_STORAGE_QUOTA)
	st.entries = make(map[string][]u8)
	if path == "" {
		return
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	loaded: map[string][]u8
	if cbor.unmarshal(data, &loaded, {.Disallow_Streaming}, context.allocator, context.temp_allocator) != nil {
		return
	}
	for k, v in loaded {
		st.entries[k] = v
		st.used += storage_cost(k, v)
	}
	delete(loaded)
}

storage_close :: proc(st: ^Storage) {
	for k, v in st.entries {
		delete(k)
		delete(v)
	}
	delete(st.entries)
	delete(st.path)
	st^ = {}
}

@(private)
storage_flush :: proc(st: ^Storage) -> bool {
	if st.path == "" {
		return true
	}
	data, err := cbor.marshal(st.entries, cbor.ENCODE_SMALL, context.temp_allocator, context.temp_allocator)
	if err != nil {
		return false
	}
	os.make_directory_all(dir_of(st.path))
	tmp := strings.concatenate({st.path, ".tmp"}, context.temp_allocator)
	f, oerr := os.open(tmp, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if oerr != nil {
		return false
	}
	_, werr := os.write(f, data)
	os.close(f)
	if werr != nil {
		os.remove(tmp)
		return false
	}
	return os.rename(tmp, st.path) == nil
}

@(private)
dir_of :: proc(path: string) -> string {
	i := strings.last_index_any(path, "/\\")
	return path[:i] if i > 0 else "."
}

storage_get :: proc(st: ^Storage, key: string) -> ([]u8, bool) {
	return st.entries[key]
}

storage_set :: proc(st: ^Storage, key: string, value: []u8) -> abi.Errno {
	old, exists := st.entries[key]
	new_used := st.used + storage_cost(key, value)
	if exists {
		new_used -= storage_cost(key, old)
	}
	if new_used > st.quota {
		return .NOSPC
	}
	v := make([]u8, len(value))
	copy(v, value)
	if exists {
		delete(old)
		st.entries[key] = v
	} else {
		st.entries[strings.clone(key)] = v
	}
	st.used = new_used
	if !storage_flush(st) {
		return .NOMEM
	}
	return .OK
}

storage_delete :: proc(st: ^Storage, key: string) -> abi.Errno {
	if key not_in st.entries {
		return .NOENT
	}
	k, v := delete_key(&st.entries, key)
	st.used -= storage_cost(k, v)
	delete(k)
	delete(v)
	if !storage_flush(st) {
		return .NOMEM
	}
	return .OK
}

// Gives the page persistent storage at `path` ("" for memory only), with the
// quota its manifest asked for. Pages whose manifest asks for none get no store.
page_attach_storage :: proc(p: ^Page, path: string) {
	if p.storage != nil || p.image.manifest.storage == 0 {
		return
	}
	p.storage = new(Storage, p.allocator)
	storage_open(p.storage, path, int(min(p.image.manifest.storage, abi.MAX_STORAGE_QUOTA)))
}
