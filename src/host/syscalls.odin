package host

import "core:crypto"
import "core:time"
import "core:unicode/utf8"

import "../abi"
import "../vm"

@(private)
errno :: #force_inline proc "contextless" (e: abi.Errno) -> i64 {
	return -i64(e)
}

// Reads a guest (ptr, len) buffer. The returned slice aliases guest memory.
@(private)
guest_read :: proc(p: ^Page, ptr, n: u64) -> ([]u8, bool) {
	return vm.memory_slice(&p.cpu.mem, ptr, n, vm.PERMS_R)
}

@(private)
guest_write :: proc(p: ^Page, ptr, n: u64) -> ([]u8, bool) {
	return vm.memory_slice(&p.cpu.mem, ptr, n, {.Write})
}

// Reads a UTF-8 string argument, enforcing a maximum length.
@(private)
guest_string :: proc(p: ^Page, ptr, n: u64, limit: u64) -> (string, abi.Errno) {
	if n > limit {
		return "", .RANGE
	}
	b, ok := guest_read(p, ptr, n)
	if !ok {
		return "", .FAULT
	}
	s := string(b)
	if !utf8.valid_string(s) {
		return "", .INVAL
	}
	return s, .OK
}

@(private)
dispatch :: proc(p: ^Page) {
	x := &p.cpu.x
	nr := x[vm.REG_A7]
	args := [6]u64{x[vm.REG_A0], x[vm.REG_A1], x[vm.REG_A2], x[vm.REG_A3], x[vm.REG_A4], x[vm.REG_A5]}
	ret := syscall(p, nr, args)
	// Exit and a blocking Wait_Event leave a0 alone: there is no return yet.
	if p.state == .Running {
		x[vm.REG_A0] = u64(ret)
	}
	if p.trace_proc != nil {
		p.trace_proc(p, nr, args, ret)
	}
}

@(private)
syscall :: proc(p: ^Page, nr: u64, args: [6]u64) -> i64 {
	if nr > u64(max(u32)) {
		return errno(.NOSYS)
	}
	a0, a1, a2, a3 := args[0], args[1], args[2], args[3]

	#partial switch abi.Syscall(u32(nr)) {
	case .Exit:
		p.exit_code = i64(i32(u32(a0)))
		p.state = .Exited
		return 0

	case .Debug_Log:
		if a2 > u64(max(abi.Log_Level)) {
			return errno(.INVAL)
		}
		if a1 > abi.MAX_LOG_LEN {
			return errno(.RANGE)
		}
		b, ok := guest_read(p, a0, a1)
		if !ok {
			return errno(.FAULT)
		}
		if p.log_proc != nil {
			p.log_proc(p, abi.Log_Level(a2), string(b))
		}
		return 0

	case .Abi_Version:
		return abi.ABI_VERSION

	case .Mem_Grow:
		delta := i64(a0)
		img := &p.image
		if delta < 0 {
			return errno(.INVAL)
		}
		old := img.brk
		grow := (u64(delta) + vm.PAGE_SIZE - 1) &~ u64(vm.PAGE_SIZE - 1)
		if grow > img.heap_limit - old {
			return errno(.NOMEM)
		}
		vm.memory_protect(&p.cpu.mem, old, grow, vm.PERMS_RW)
		img.brk = old + grow
		return i64(old)

	case .Time_Now:
		return page_now(p)

	case .Random:
		if a1 > abi.MAX_RANDOM_LEN {
			return errno(.RANGE)
		}
		b, ok := guest_write(p, a0, a1)
		if !ok {
			return errno(.FAULT)
		}
		when crypto.HAS_RAND_BYTES {
			crypto.rand_bytes(b)
		} else {
			return errno(.NOSYS)
		}
		return i64(a1)

	case .Wait_Event:
		if _, ok := guest_write(p, a0, size_of(abi.Event)); !ok {
			return errno(.FAULT)
		}
		timeout_ms := i64(a1)
		p.wait_ptr = a0
		if len(p.events) > 0 {
			ev := p.events[0]
			ordered_remove(&p.events, 0)
			write_event(p, a0, ev)
			return 1
		}
		if timeout_ms == 0 {
			return 0
		}
		p.wait_until = max(i64)
		if timeout_ms > 0 {
			p.wait_until = page_now(p) + timeout_ms * i64(time.Millisecond)
		}
		p.state = .Waiting
		return 0

	case .Handle_Close:
		h := abi.Handle(u32(a0))
		if u64(h) != a0 {
			return errno(.BADH)
		}
		e := handle_get(&p.handles, h)
		if e == nil {
			return errno(.BADH)
		}
		switch _ in e.obj {
		case Node:
			node_close(p, h)
		case Stream:
			stream_close(p, h)
		}
		return 0

	case .Node_Create:
		if a0 > u64(max(abi.Node_Kind)) {
			return errno(.INVAL)
		}
		h, ok := node_create(p, abi.Node_Kind(a0))
		if !ok {
			return errno(.RANGE)
		}
		return i64(h)

	case .Node_Set_Text:
		s, err := guest_string(p, a1, a2, abi.MAX_TEXT_LEN)
		if err != .OK {
			return errno(err)
		}
		return errno(node_set_text(p, handle_arg(a0), s))

	case .Node_Set_Attr:
		if a1 > u64(max(abi.Attr)) {
			return errno(.INVAL)
		}
		s, err := guest_string(p, a2, a3, abi.MAX_ATTR_LEN)
		if err != .OK {
			return errno(err)
		}
		return errno(node_set_attr(p, handle_arg(a0), abi.Attr(a1), s))

	case .Node_Append:
		return errno(node_append(p, handle_arg(a0), handle_arg(a1)))

	case .Node_Remove:
		h := handle_arg(a0)
		if node_get(p, h) == nil {
			return errno(.BADH)
		}
		node_detach(p, h)
		return 0

	case .Root_Set:
		h := handle_arg(a0)
		if h == abi.INVALID_HANDLE {
			p.root = h
			p.tree_version += 1
			return 0
		}
		n := node_get(p, h)
		if n == nil {
			return errno(.BADH)
		}
		if n.parent != abi.INVALID_HANDLE {
			return errno(.INVAL)
		}
		p.root = h
		p.tree_version += 1
		return 0

	case .Node_Get_Text:
		n := node_get(p, handle_arg(a0))
		if n == nil {
			return errno(.BADH)
		}
		count := min(a2, u64(len(n.text)))
		dst, ok := guest_write(p, a1, count)
		if !ok {
			return errno(.FAULT)
		}
		copy(dst, n.text)
		return i64(len(n.text))

	case .Input_Get_Selection:
		n, err := input_node(p, handle_arg(a0))
		if err != .OK {
			return errno(err)
		}
		dst, ok := guest_write(p, a1, size_of(abi.Selection))
		if !ok {
			return errno(.FAULT)
		}
		sel := abi.Selection{i64(n.anchor), i64(n.caret)}
		copy(dst, ([^]u8)(&sel)[:size_of(abi.Selection)])
		return 0

	case .Input_Set_Selection:
		n, err := input_node(p, handle_arg(a0))
		if err != .OK {
			return errno(err)
		}
		anchor, aerr := text_offset(n.text, a1)
		if aerr != .OK {
			return errno(aerr)
		}
		caret, cerr := text_offset(n.text, a2)
		if cerr != .OK {
			return errno(cerr)
		}
		n.anchor, n.caret = anchor, caret
		n.selection_set = true
		p.paint_version += 1
		return 0

	case .Input_Focus:
		h := handle_arg(a0)
		if a0 != 0 {
			if _, err := input_node(p, h); err != .OK {
				return errno(err)
			}
			if p.root == abi.INVALID_HANDLE || !node_is_ancestor(p, p.root, h) {
				return errno(.INVAL) // not shown, so it could not be typed into
			}
		}
		p.focus_request = h
		p.focus_requested = true
		p.paint_version += 1
		return 0

	case .Image_Set_Data:
		if a2 > abi.MAX_IMAGE_BYTES {
			return errno(.RANGE)
		}
		data, ok := guest_read(p, a1, a2)
		if !ok {
			return errno(.FAULT)
		}
		return errno(node_set_image(p, handle_arg(a0), data))

	case .Canvas_Clear:
		c, err := canvas_node(p, handle_arg(a0))
		if err != .OK {
			return errno(err)
		}
		canvas_fill_rect(p, c, 0, 0, i64(c.width), i64(c.height), a1)
		return 0

	case .Canvas_Fill_Rect:
		c, err := canvas_node(p, handle_arg(a0))
		if err != .OK {
			return errno(err)
		}
		canvas_fill_rect(p, c, i64(a1), i64(a2), i64(a3), i64(args[4]), args[5])
		return 0

	case .Canvas_Put_Pixels:
		c, err := canvas_node(p, handle_arg(a0))
		if err != .OK {
			return errno(err)
		}
		if a2 != u64(len(c.pixels)) {
			return errno(.INVAL)
		}
		src, ok := guest_read(p, a1, a2)
		if !ok {
			return errno(.FAULT)
		}
		copy(c.pixels, src)
		p.paint_version += 1
		return 0

	case .Fetch_Open:
		ref, err := guest_string(p, a0, a1, abi.MAX_FETCH_URL)
		if err != .OK {
			return errno(err)
		}
		h, ferr := fetch_open(p, ref)
		if ferr != .OK {
			return errno(ferr)
		}
		return i64(h)

	case .Fetch_Read:
		st := stream_get(p, handle_arg(a0))
		if st == nil {
			return errno(.BADH)
		}
		if !st.done {
			return errno(.AGAIN)
		}
		count := min(a2, u64(len(st.body) - st.pos))
		dst, ok := guest_write(p, a1, count)
		if !ok {
			return errno(.FAULT)
		}
		copy(dst, st.body[st.pos:])
		st.pos += int(count)
		return i64(count)

	case .Storage_Get:
		st := p.storage
		if st == nil {
			return errno(.PERM)
		}
		key, err := storage_key(p, a0, a1)
		if err != .OK {
			return errno(err)
		}
		value, ok := storage_get(st, key)
		if !ok {
			return errno(.NOENT)
		}
		count := min(a3, u64(len(value)))
		dst, wok := guest_write(p, a2, count)
		if !wok {
			return errno(.FAULT)
		}
		copy(dst, value)
		return i64(len(value))

	case .Storage_Set:
		st := p.storage
		if st == nil {
			return errno(.PERM)
		}
		key, err := storage_key(p, a0, a1)
		if err != .OK {
			return errno(err)
		}
		if a3 > abi.MAX_STORAGE_VALUE {
			return errno(.RANGE)
		}
		value, ok := guest_read(p, a2, a3)
		if !ok {
			return errno(.FAULT)
		}
		return errno(storage_set(st, key, value))

	case .Storage_Delete:
		st := p.storage
		if st == nil {
			return errno(.PERM)
		}
		key, err := storage_key(p, a0, a1)
		if err != .OK {
			return errno(err)
		}
		return errno(storage_delete(st, key))

	case .Storage_Usage:
		if p.storage == nil {
			return errno(.PERM)
		}
		return i64(p.storage.used)
	}
	return errno(.NOSYS)
}

// Handles are u32; anything wider can never be valid.
@(private)
handle_arg :: #force_inline proc "contextless" (v: u64) -> abi.Handle {
	if v > u64(max(u32)) {
		return abi.INVALID_HANDLE
	}
	return abi.Handle(u32(v))
}

@(private)
input_node :: proc(p: ^Page, h: abi.Handle) -> (^Node, abi.Errno) {
	n := node_get(p, h)
	if n == nil {
		return nil, .BADH
	}
	if n.kind not_in abi.EDITABLE {
		return nil, .INVAL
	}
	return n, .OK
}

// A byte offset into `text` from a syscall argument: at most the text's
// length, and on a rune boundary.
@(private)
text_offset :: proc(text: string, v: u64) -> (int, abi.Errno) {
	if v > u64(len(text)) {
		return 0, .RANGE // also catches negative offsets
	}
	pos := int(v)
	if pos < len(text) && text[pos] & 0xC0 == 0x80 {
		return 0, .INVAL
	}
	return pos, .OK
}

@(private)
storage_key :: proc(p: ^Page, ptr, n: u64) -> (string, abi.Errno) {
	if n == 0 {
		return "", .INVAL
	}
	return guest_string(p, ptr, n, abi.MAX_STORAGE_KEY)
}
