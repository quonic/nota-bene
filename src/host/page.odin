// Package host runs a page: it owns the VM, the handle table and the view
// tree, and implements the syscall ABI from package abi.
//
// It does no I/O of its own. Front ends (the headless runner today, the SDL
// browser later) drive it with page_run, feed it events with page_push_event,
// and receive log lines through Page.log_proc.
package host

import "base:runtime"
import "core:time"

import "../abi"
import "../loader"
import "../vm"

#assert(ODIN_ENDIAN == .Little, "guest structs are copied byte-for-byte; a big-endian host needs byte swapping")

Page_State :: enum {
	Running, // has more to do; call page_run again
	Waiting, // blocked in Wait_Event; push an event or let the deadline pass
	Exited,  // called Exit; see exit_code
	Faulted, // the VM faulted; see cpu.fault
	Killed,  // stopped by the host; see kill_reason
}

Log_Proc :: #type proc(p: ^Page, level: abi.Log_Level, msg: string)
Trace_Proc :: #type proc(p: ^Page, nr: u64, args: [6]u64, ret: i64)

Page :: struct {
	cpu:         vm.Cpu,
	image:       loader.Image,
	state:       Page_State,
	exit_code:   i64,
	kill_reason: string,

	handles:     Handle_Table,
	root:        abi.Handle,

	// Bumped whenever the tree's structure, text or attributes change (re-layout
	// needed) and whenever canvas pixels change (repaint needed).
	tree_version:  u64,
	paint_version: u64,

	events:      [dynamic]abi.Event, // FIFO
	quit_sent:   bool,
	wait_ptr:    u64,
	wait_until:  i64, // ns on the page clock; max(i64) waits forever

	start:       time.Tick,
	clock_skew:  i64, // ns added to the page clock (headless runs skip ahead instead of sleeping)

	storage:     ^Storage, // nil: the page has no persistent storage (see page_attach_storage)

	bitmap_bytes: int, // decoded Image pixels held, against abi.MAX_IMAGE_TOTAL

	// An Input_Focus the browser has not applied yet. The request may be 0
	// (take focus off the page's Inputs), hence the separate flag.
	focus_request:   abi.Handle,
	focus_requested: bool,

	// Fetch (fetch.odin)
	location:      string,                // where the page came from; see page_set_location
	fetch_proc:    Fetch_Proc,            // nil: Fetch_Open fails with -NOSYS
	fetches:       map[u64]abi.Handle,    // requests in flight; INVALID_HANDLE once the page closed the stream
	next_fetch_id: u64,

	log_proc:    Log_Proc,
	trace_proc:  Trace_Proc, // called after each syscall when set
	user_data:   rawptr,
	allocator:   runtime.Allocator,
}

page_init :: proc(p: ^Page, elf: []u8, cfg := loader.DEFAULT_CONFIG, allocator := context.allocator) -> loader.Error {
	p^ = {}
	p.allocator = allocator
	img, err := loader.load(&p.cpu, elf, cfg, allocator)
	if err != nil {
		return err
	}
	p.image = img
	handle_table_init(&p.handles, abi.MAX_NODES, allocator)
	p.events = make([dynamic]abi.Event, allocator)
	p.fetches = make(map[u64]abi.Handle, allocator)
	p.start = time.tick_now()
	return nil
}

page_destroy :: proc(p: ^Page) {
	for &e in p.handles.entries {
		if !e.alive {
			continue
		}
		switch &obj in e.obj {
		case Node:
			node_free_storage(p, &obj)
		case Stream:
			delete(obj.body, p.allocator)
		}
	}
	handle_table_destroy(&p.handles)
	if p.storage != nil {
		storage_close(p.storage)
		free(p.storage, p.allocator)
	}
	delete(p.events)
	delete(p.fetches)
	delete(p.location, p.allocator)
	loader.manifest_destroy(&p.image.manifest)
	vm.memory_destroy(&p.cpu.mem, p.allocator)
	p^ = {}
}

// Monotonic page clock in ns, quantised to 1 ms so pages cannot build
// high-resolution timers for side-channel attacks.
page_now :: proc(p: ^Page) -> i64 {
	ns := i64(time.tick_since(p.start)) + p.clock_skew
	return ns - ns % i64(time.Millisecond)
}

// Executes up to `budget` instructions, handling syscalls along the way.
// Returns early when the page waits, exits or faults.
page_run :: proc(p: ^Page, budget: u64) -> Page_State {
	if p.state != .Running {
		return p.state
	}
	remaining := budget
	for remaining > 0 && p.state == .Running {
		reason, executed := vm.run(&p.cpu, remaining)
		remaining -= executed
		switch reason {
		case .Budget:
		case .Ecall:
			dispatch(p)
		case .Ebreak:
			page_kill(p, "ebreak with no debugger attached")
		case .Fault:
			p.state = .Faulted
		}
	}
	return p.state
}

page_kill :: proc(p: ^Page, reason: string) {
	p.state = .Killed
	p.kill_reason = reason
}

// Queues an event. If the page is blocked in Wait_Event it is delivered now
// and the page becomes runnable.
page_push_event :: proc(p: ^Page, ev: abi.Event) {
	if ev.kind == .Quit {
		p.quit_sent = true
	}
	append(&p.events, ev)
	if p.state == .Waiting {
		deliver_event(p)
	}
}

// Wakes a waiting page whose timeout has passed. Returns true if it woke.
page_check_timeout :: proc(p: ^Page) -> bool {
	if p.state != .Waiting || p.wait_until == max(i64) || page_now(p) < p.wait_until {
		return false
	}
	p.cpu.x[vm.REG_A0] = 0
	p.state = .Running
	return true
}

// Moves the page clock forward to the pending deadline instead of sleeping.
page_skip_to_deadline :: proc(p: ^Page) -> bool {
	if p.state != .Waiting || p.wait_until == max(i64) {
		return false
	}
	if delta := p.wait_until - page_now(p); delta > 0 {
		p.clock_skew += delta
	}
	return page_check_timeout(p)
}

@(private)
deliver_event :: proc(p: ^Page) {
	ev := p.events[0]
	ordered_remove(&p.events, 0)
	write_event(p, p.wait_ptr, ev)
	p.cpu.x[vm.REG_A0] = 1
	p.state = .Running
}

@(private)
write_event :: proc(p: ^Page, ptr: u64, ev: abi.Event) {
	dst, _ := vm.memory_slice(&p.cpu.mem, ptr, size_of(abi.Event), {.Write})
	ev := ev
	copy(dst, ([^]u8)(&ev)[:size_of(abi.Event)])
}

// Replaces an Input node's text on the user's behalf (typing, pasting) and
// sends the page a Change event for it.
page_input_edit :: proc(p: ^Page, h: abi.Handle, text: string) {
	n := node_get(p, h)
	if n == nil || n.kind not_in abi.EDITABLE {
		return
	}
	node_set_text(p, h, text)
	page_push_event(p, abi.Event{kind = .Change, handle = h})
}

// Records where the user put the caret and selection in an Input, and sends
// the page a Select event if they moved.
page_input_select :: proc(p: ^Page, h: abi.Handle, anchor, caret: int) {
	n := node_get(p, h)
	if n == nil || n.kind not_in abi.EDITABLE || (n.anchor == anchor && n.caret == caret) {
		return
	}
	n.anchor, n.caret = anchor, caret
	page_push_event(p, abi.Event{kind = .Select, handle = h, a = i64(anchor), b = i64(caret)})
}
