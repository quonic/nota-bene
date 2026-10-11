// Package nb is the SDK for writing pages in Odin.
//
// A page is an ordinary Odin program built for freestanding_riscv64. It
// needs a `main` and a two-line entry point:
//
//	main :: proc() { nb.log("hello") }
//
//	@(export, link_name="_start")
//	_start :: proc "c" () -> ! { nb.start(main) }
//
// Build pages with ./build.sh page <dir>; see docs/architecture.md.
package nb

import abi "../../src/abi"

Handle     :: abi.Handle
Node_Kind  :: abi.Node_Kind
Attr       :: abi.Attr
Event      :: abi.Event
Event_Kind :: abi.Event_Kind
Errno      :: abi.Errno
Log_Level  :: abi.Log_Level
Key        :: abi.Key
Modifier   :: abi.Modifier
Modifiers  :: abi.Modifiers
Selection  :: abi.Selection

INVALID_HANDLE :: abi.INVALID_HANDLE

// Exit code used when a page panics or fails an assertion.
PANIC_EXIT_CODE :: 101

@(default_calling_convention="c")
foreign {
	// Implemented in rt.S.
	nb_syscall :: proc(nr: uintptr, a0: uintptr = 0, a1: uintptr = 0, a2: uintptr = 0, a3: uintptr = 0, a4: uintptr = 0, a5: uintptr = 0) -> int ---
}

@(private)
sys :: #force_inline proc "contextless" (nr: abi.Syscall, a0: uintptr = 0, a1: uintptr = 0, a2: uintptr = 0, a3: uintptr = 0) -> int {
	return nb_syscall(uintptr(nr), a0, a1, a2, a3)
}

@(private)
to_errno :: #force_inline proc "contextless" (r: int) -> Errno {
	return Errno(-r) if r < 0 else .OK
}

@(private)
str_args :: #force_inline proc "contextless" (s: string) -> (uintptr, uintptr) {
	return uintptr(raw_data(s)), uintptr(len(s))
}

exit :: proc "contextless" (code: i32) -> ! {
	sys(.Exit, uintptr(u32(code)))
	for {} // unreachable: the browser never resumes a page after Exit
}

log :: proc "contextless" (msg: string, level := Log_Level.Info) {
	p, n := str_args(msg)
	sys(.Debug_Log, p, n, uintptr(level))
}

abi_version :: proc "contextless" () -> int {
	return sys(.Abi_Version)
}

// Extends the heap by at least `delta` bytes (rounded up to whole pages) and
// returns the start of the new region. Most pages use the context allocator instead.
mem_grow :: proc "contextless" (delta: uint) -> (rawptr, Errno) {
	r := sys(.Mem_Grow, uintptr(delta))
	if r < 0 {
		return nil, to_errno(r)
	}
	return rawptr(uintptr(r)), .OK
}

// Monotonic time in nanoseconds, with 1 ms granularity.
time_now :: proc "contextless" () -> i64 {
	return i64(sys(.Time_Now))
}

// Fills `buf` with cryptographically secure random bytes (at most 64 KiB per call).
random :: proc "contextless" (buf: []u8) -> Errno {
	return to_errno(sys(.Random, uintptr(raw_data(buf)), uintptr(len(buf))))
}

// Blocks until an event arrives or `timeout_ms` passes (-1 waits forever, 0 polls).
// Returns ok = false on timeout.
wait_event :: proc "contextless" (timeout_ms: i64 = -1) -> (ev: Event, ok: bool) {
	r := sys(.Wait_Event, uintptr(&ev), uintptr(timeout_ms))
	return ev, r == 1
}

close :: proc "contextless" (h: Handle) -> Errno {
	return to_errno(sys(.Handle_Close, uintptr(h)))
}

// View tree.

create :: proc "contextless" (kind: Node_Kind) -> (Handle, Errno) {
	r := sys(.Node_Create, uintptr(kind))
	if r < 0 {
		return INVALID_HANDLE, to_errno(r)
	}
	return Handle(r), .OK
}

set_text :: proc "contextless" (h: Handle, text: string) -> Errno {
	p, n := str_args(text)
	return to_errno(sys(.Node_Set_Text, uintptr(h), p, n))
}

// An empty value removes the attribute.
set_attr :: proc "contextless" (h: Handle, attr: Attr, value: string) -> Errno {
	p, n := str_args(value)
	return to_errno(sys(.Node_Set_Attr, uintptr(h), uintptr(attr), p, n))
}

// Appends `child` to `parent`, moving it if it already has a parent.
append_child :: proc "contextless" (parent, child: Handle) -> Errno {
	return to_errno(sys(.Node_Append, uintptr(parent), uintptr(child)))
}

remove :: proc "contextless" (h: Handle) -> Errno {
	return to_errno(sys(.Node_Remove, uintptr(h)))
}

set_root :: proc "contextless" (h: Handle) -> Errno {
	return to_errno(sys(.Root_Set, uintptr(h)))
}

// Copies a node's text into `buf` (e.g. what the user typed into an Input).
// Returns the part that fit and the full length in bytes.
get_text_buf :: proc "contextless" (h: Handle, buf: []u8) -> (text: string, full_len: int, err: Errno) {
	r := sys(.Node_Get_Text, uintptr(h), uintptr(raw_data(buf)), uintptr(len(buf)))
	if r < 0 {
		return "", 0, to_errno(r)
	}
	return string(buf[:min(r, len(buf))]), r, .OK
}

// Returns a copy of a node's text allocated with `allocator`.
get_text :: proc(h: Handle, allocator := context.allocator) -> (string, Errno) {
	_, n, err := get_text_buf(h, nil)
	if err != .OK {
		return "", err
	}
	buf := make([]u8, n, allocator)
	text, _, err2 := get_text_buf(h, buf)
	return text, err2
}

// Where the caret and selection are in an Input, as byte offsets into its
// text. The selection runs from `anchor` to `caret`; they are equal when
// nothing is selected. A Select event reports each move the user makes.
get_selection :: proc "contextless" (h: Handle) -> (anchor, caret: int, err: Errno) {
	sel: Selection
	r := sys(.Input_Get_Selection, uintptr(h), uintptr(&sel))
	if r < 0 {
		return 0, 0, to_errno(r)
	}
	return int(sel.anchor), int(sel.caret), .OK
}

// Moves an Input's caret to `caret`, selecting from `anchor`; pass the same
// offset twice for a plain caret. Offsets must lie on rune boundaries.
set_selection :: proc "contextless" (h: Handle, anchor, caret: int) -> Errno {
	return to_errno(sys(.Input_Set_Selection, uintptr(h), uintptr(anchor), uintptr(caret)))
}

// Gives an Input the keyboard focus, or with INVALID_HANDLE takes it off the
// page's Inputs. The Input must be in the tree under the root. The browser
// ignores the request while the user is typing in its address or find bar.
focus :: proc "contextless" (h: Handle) -> Errno {
	return to_errno(sys(.Input_Focus, uintptr(h)))
}

// Canvas drawing. Colours are 0xRRGGBBAA.

canvas_clear :: proc "contextless" (h: Handle, rgba: u32) -> Errno {
	return to_errno(sys(.Canvas_Clear, uintptr(h), uintptr(rgba)))
}

canvas_fill_rect :: proc "contextless" (h: Handle, x, y, w, height: int, rgba: u32) -> Errno {
	return to_errno(nb_syscall(uintptr(abi.Syscall.Canvas_Fill_Rect), uintptr(h), uintptr(x), uintptr(y), uintptr(w), uintptr(height), uintptr(rgba)))
}

// Replaces every pixel: `pixels` is RGBA8, row-major, exactly width*height*4 bytes.
canvas_put_pixels :: proc "contextless" (h: Handle, pixels: []u8) -> Errno {
	return to_errno(sys(.Canvas_Put_Pixels, uintptr(h), uintptr(raw_data(pixels)), uintptr(len(pixels))))
}

// Convenience: creates a node, sets its text and appends it to `parent` (if
// given). Returns INVALID_HANDLE if the node could not be created; later
// calls on an invalid handle fail with .BADH, so chains of `el` stay safe.
el :: proc "contextless" (kind: Node_Kind, parent := INVALID_HANDLE, text := "") -> Handle {
	h, err := create(kind)
	if err != .OK {
		return INVALID_HANDLE
	}
	if len(text) > 0 {
		set_text(h, text)
	}
	if parent != INVALID_HANDLE {
		append_child(parent, h)
	}
	return h
}

// Fetch: data from the servers named in the manifest's `fetch` lines
// (`fetch /` is the page's own server). Anything else fails with .PERM.
//
//	h, err := nb.fetch("feed.txt")      // relative to the page's address
//	...
//	case .Fetch:                        // in the event loop
//		if ev.handle == h && ev.a == 200 {
//			data, _ := nb.fetch_read_all(h, int(ev.b))
//		}
//		nb.close(h)

// Starts a request and returns its stream. A Fetch event for the stream
// follows: a = the server's status (200, 404, ...) or a negated Errno
// (-.NET when the server cannot be reached), b = the body's length.
fetch :: proc "contextless" (url: string) -> (Handle, Errno) {
	p, n := str_args(url)
	r := sys(.Fetch_Open, p, n)
	if r < 0 {
		return INVALID_HANDLE, to_errno(r)
	}
	return Handle(r), .OK
}

// Copies the next part of the body into `buf`; 0 bytes means the end.
// .AGAIN until the Fetch event has arrived.
fetch_read :: proc "contextless" (h: Handle, buf: []u8) -> (int, Errno) {
	r := sys(.Fetch_Read, uintptr(h), uintptr(raw_data(buf)), uintptr(len(buf)))
	if r < 0 {
		return 0, to_errno(r)
	}
	return r, .OK
}

// Reads the rest of the body into a new buffer; `size` is the Fetch event's b.
fetch_read_all :: proc(h: Handle, size: int, allocator := context.allocator) -> ([]u8, Errno) {
	buf := make([]u8, size, allocator)
	n := 0
	for n < size {
		r, err := fetch_read(h, buf[n:])
		if err != .OK {
			delete(buf, allocator)
			return nil, err
		}
		if r == 0 {
			break
		}
		n += r
	}
	return buf[:n], .OK
}

// Storage: a private key-value store for this site, kept across visits.
// The manifest must ask for a quota (`storage 64K`); otherwise these fail
// with .PERM. Keys are 1..256 bytes of UTF-8; values at most 1 MiB.

// Reads a value into `buf`. Returns the part that fit and the full length.
storage_get_buf :: proc "contextless" (key: string, buf: []u8) -> (value: []u8, full_len: int, err: Errno) {
	kp, kn := str_args(key)
	r := sys(.Storage_Get, kp, kn, uintptr(raw_data(buf)), uintptr(len(buf)))
	if r < 0 {
		return nil, 0, to_errno(r)
	}
	return buf[:min(r, len(buf))], r, .OK
}

// Returns a copy of a value allocated with `allocator`; .NOENT if the key is absent.
storage_get :: proc(key: string, allocator := context.allocator) -> ([]u8, Errno) {
	_, n, err := storage_get_buf(key, nil)
	if err != .OK {
		return nil, err
	}
	buf := make([]u8, n, allocator)
	value, _, err2 := storage_get_buf(key, buf)
	return value, err2
}

storage_set :: proc "contextless" (key: string, value: []u8) -> Errno {
	kp, kn := str_args(key)
	return to_errno(sys(.Storage_Set, kp, kn, uintptr(raw_data(value)), uintptr(len(value))))
}

storage_set_string :: proc "contextless" (key, value: string) -> Errno {
	return storage_set(key, transmute([]u8)value)
}

storage_delete :: proc "contextless" (key: string) -> Errno {
	kp, kn := str_args(key)
	return to_errno(sys(.Storage_Delete, kp, kn))
}

// Bytes used by keys and values, counted against the quota.
storage_usage :: proc "contextless" () -> (int, Errno) {
	r := sys(.Storage_Usage)
	if r < 0 {
		return 0, to_errno(r)
	}
	return r, .OK
}
