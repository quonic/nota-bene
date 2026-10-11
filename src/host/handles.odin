package host

import "../abi"

// Capability handles. A handle encodes a table index plus a generation, so a
// handle that was closed (and whose slot was reused) is detected as stale
// instead of silently referring to someone else's object.
//
//   bit 31      always 0, so handles are positive as i32
//   bits 30..20 generation (never 0)
//   bits 19..0  index (slot 0 is reserved, so no valid handle is 0)

@(private) INDEX_BITS :: 20
@(private) INDEX_MASK :: (1 << INDEX_BITS) - 1
@(private) GEN_MASK   :: 0x7FF

Object :: union {
	Node,
	Stream,
}

Entry :: struct {
	gen:   u32,
	alive: bool,
	obj:   Object,
}

Handle_Table :: struct {
	entries: [dynamic]Entry,
	free:    [dynamic]u32,
	count:   int,
	limit:   int,
}

handle_table_init :: proc(t: ^Handle_Table, limit: int, allocator := context.allocator) {
	t.entries = make([dynamic]Entry, 1, 64, allocator) // slot 0 reserved
	t.free = make([dynamic]u32, allocator)
	t.limit = min(limit, INDEX_MASK)
}

handle_table_destroy :: proc(t: ^Handle_Table) {
	delete(t.entries)
	delete(t.free)
	t^ = {}
}

handle_alloc :: proc(t: ^Handle_Table, obj: Object) -> (abi.Handle, bool) {
	if t.count >= t.limit {
		return abi.INVALID_HANDLE, false
	}
	index: u32
	if n := len(t.free); n > 0 {
		index = t.free[n - 1]
		pop(&t.free)
	} else {
		index = u32(len(t.entries))
		append(&t.entries, Entry{gen = 1})
	}
	e := &t.entries[index]
	e.alive = true
	e.obj = obj
	t.count += 1
	return abi.Handle(e.gen << INDEX_BITS | index), true
}

handle_get :: proc(t: ^Handle_Table, h: abi.Handle) -> ^Entry {
	index := u32(h) & INDEX_MASK
	gen := u32(h) >> INDEX_BITS
	if index == 0 || int(index) >= len(t.entries) {
		return nil
	}
	e := &t.entries[index]
	if !e.alive || e.gen != gen {
		return nil
	}
	return e
}

// Frees the slot. The caller releases whatever the object owns first.
handle_release :: proc(t: ^Handle_Table, h: abi.Handle) {
	e := handle_get(t, h)
	if e == nil {
		return
	}
	e.alive = false
	e.obj = nil
	e.gen = (e.gen + 1) & GEN_MASK
	if e.gen == 0 {
		e.gen = 1
	}
	t.count -= 1
	append(&t.free, u32(h) & INDEX_MASK)
}
