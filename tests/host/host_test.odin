package host_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "../../src/abi"
import "../../src/host"
import "../../src/proto"
import "../../src/vm"

FIXTURES  :: #config(FIXTURES, "build/tests")
BUILD_DIR :: #config(BUILD_DIR, "build")

load_page :: proc(t: ^testing.T, p: ^host.Page, path: string) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if !testing.expectf(t, err == nil, "cannot read %s (run ./build.sh test): %v", path, err) {
		return false
	}
	defer delete(data)
	lerr := host.page_init(p, data)
	return testing.expectf(t, lerr == nil, "cannot load %s: %v", path, lerr)
}

// Runs until the page is no longer runnable.
run_page :: proc(p: ^host.Page, budget: u64 = 10_000_000) -> host.Page_State {
	for {
		st := host.page_run(p, budget)
		if st != .Running || p.cpu.instret >= budget {
			return st
		}
	}
}

expect_exit :: proc(t: ^testing.T, p: ^host.Page, code: i64, loc := #caller_location) {
	if p.state == .Faulted {
		testing.expectf(t, false, "page faulted: %s", vm.describe_fault(p.cpu.fault, context.temp_allocator), loc = loc)
		return
	}
	testing.expectf(t, p.state == .Exited, "page state %v, want Exited", p.state, loc = loc)
	testing.expectf(t, p.exit_code == code, "exit code %d, want %d", p.exit_code, code, loc = loc)
}

Log_Capture :: struct {
	lines: [dynamic]string,
}

capture_log :: proc(p: ^host.Page, level: abi.Log_Level, msg: string) {
	c := (^Log_Capture)(p.user_data)
	append(&c.lines, strings.clone(msg))
}

destroy_capture :: proc(c: ^Log_Capture) {
	for l in c.lines {
		delete(l)
	}
	delete(c.lines)
}

@(test)
test_syscalls :: proc(t: ^testing.T) {
	for variant in ([]string{"c", "nc"}) {
		p: host.Page
		if !load_page(t, &p, fmt.tprintf("%s/syscalls.%s.elf", FIXTURES, variant)) {
			return
		}
		defer host.page_destroy(&p)
		logs: Log_Capture
		defer destroy_capture(&logs)
		p.user_data = &logs
		p.log_proc = capture_log

		run_page(&p)
		expect_exit(t, &p, 0) // otherwise the exit code is the failing CHECK
		testing.expect_value(t, len(logs.lines), 1)
	}
}

@(test)
test_wait_and_events :: proc(t: ^testing.T) {
	p: host.Page
	if !load_page(t, &p, fmt.tprintf("%s/waiter.c.elf", FIXTURES)) {
		return
	}
	defer host.page_destroy(&p)

	// First wait has a 50 ms timeout.
	testing.expect_value(t, run_page(&p), host.Page_State.Waiting)
	testing.expect(t, !host.page_check_timeout(&p), "woke before the deadline")
	testing.expect(t, host.page_skip_to_deadline(&p), "did not wake at the deadline")
	testing.expect(t, p.clock_skew >= 49_000_000)

	// Second wait is unbounded and must stay blocked until an event arrives.
	testing.expect_value(t, run_page(&p), host.Page_State.Waiting)
	testing.expect(t, !host.page_skip_to_deadline(&p))
	host.page_push_event(&p, abi.Event{kind = .Click, a = 42})
	testing.expect_value(t, p.state, host.Page_State.Running)
	run_page(&p)
	expect_exit(t, &p, i64(abi.Event_Kind.Click))
}

@(test)
test_event_queued_before_wait :: proc(t: ^testing.T) {
	p: host.Page
	if !load_page(t, &p, fmt.tprintf("%s/waiter.nc.elf", FIXTURES)) {
		return
	}
	defer host.page_destroy(&p)
	testing.expect_value(t, run_page(&p), host.Page_State.Waiting)
	host.page_skip_to_deadline(&p)
	// Pushed while the page is running: queued, then returned by the next wait without blocking.
	host.page_push_event(&p, abi.Event{kind = .Key, a = 42})
	run_page(&p)
	expect_exit(t, &p, i64(abi.Event_Kind.Key))
}

@(test)
test_budget_and_ebreak :: proc(t: ^testing.T) {
	{
		p: host.Page
		if !load_page(t, &p, fmt.tprintf("%s/loop.c.elf", FIXTURES)) {
			return
		}
		defer host.page_destroy(&p)
		testing.expect_value(t, host.page_run(&p, 1000), host.Page_State.Running)
		testing.expect_value(t, p.cpu.instret, 1000)
	}
	{
		p: host.Page
		if !load_page(t, &p, fmt.tprintf("%s/ebreak.c.elf", FIXTURES)) {
			return
		}
		defer host.page_destroy(&p)
		testing.expect_value(t, host.page_run(&p, 1000), host.Page_State.Killed)
	}
}

// End to end: the Odin example page, built with the SDK.
@(test)
test_hello_page :: proc(t: ^testing.T) {
	p: host.Page
	if !load_page(t, &p, fmt.tprintf("%s/hello.elf", BUILD_DIR)) {
		return
	}
	defer host.page_destroy(&p)
	logs: Log_Capture
	defer destroy_capture(&logs)
	p.user_data = &logs
	p.log_proc = capture_log

	testing.expect_value(t, run_page(&p), host.Page_State.Waiting)
	testing.expect_value(t, p.image.manifest.title, "Hello")

	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	host.dump_tree(&p, &sb)
	want := `box direction="column" gap="12"
  heading level="1" "Hello, new web"
  paragraph "This page is a "
    strong "RISC-V program"
    text " running in a sandboxed VM. "
    emphasis "No HTML, no JavaScript."
  list
    list_item "1"
    list_item "4"
    list_item "9"
  box direction="row" gap="12"
    button "Click me"
    text "Not clicked yet."
  box direction="row" gap="16"
    link href="canvas.elf" "Canvas demo"
    link href="form.elf" "Form demo"
    link href="notes.elf" "Notes"
    link href="feed.elf" "Feed"
    link href="about.elf" "About"
    link href="nb://example.org/hello" "Source"
`
	testing.expect_value(t, strings.to_string(sb), want)

	// Clicking the button updates the counter text.
	button := find_node(&p, .Button)
	host.page_push_event(&p, abi.Event{kind = .Click, handle = button})
	testing.expect_value(t, run_page(&p), host.Page_State.Waiting)
	testing.expect(t, find_node_with_text(&p, .Text, "Clicked 1 time") != abi.INVALID_HANDLE, "counter not updated")

	host.page_push_event(&p, abi.Event{kind = .Quit})
	run_page(&p)
	expect_exit(t, &p, 0)
	testing.expect_value(t, len(logs.lines), 2)
	if len(logs.lines) == 2 {
		testing.expect_value(t, logs.lines[0], "hello from a page")
		testing.expect_value(t, logs.lines[1], "goodbye")
	}
}

@(test)
test_handle_table :: proc(t: ^testing.T) {
	ht: host.Handle_Table
	host.handle_table_init(&ht, 2)
	defer host.handle_table_destroy(&ht)

	a, ok_a := host.handle_alloc(&ht, host.Node{})
	b, ok_b := host.handle_alloc(&ht, host.Node{})
	_, ok_c := host.handle_alloc(&ht, host.Node{})
	testing.expect(t, ok_a && ok_b)
	testing.expect(t, !ok_c, "limit not enforced")
	testing.expect(t, a != b && a != abi.INVALID_HANDLE)
	testing.expect(t, i32(a) > 0, "handles must be positive as i32")

	host.handle_release(&ht, a)
	testing.expect(t, host.handle_get(&ht, a) == nil, "released handle still resolves")
	c, ok := host.handle_alloc(&ht, host.Node{})
	testing.expect(t, ok)
	testing.expect(t, c != a, "reused slot must get a new generation")
	testing.expect(t, host.handle_get(&ht, a) == nil, "stale handle resolves to the new object")
	testing.expect(t, host.handle_get(&ht, c) != nil)
	testing.expect(t, host.handle_get(&ht, abi.Handle(0)) == nil)
	testing.expect(t, host.handle_get(&ht, abi.Handle(0x7FFFFFFF)) == nil)
}

// First live node of the given kind, in handle order.
find_node :: proc(p: ^host.Page, kind: abi.Node_Kind) -> abi.Handle {
	for e, i in p.handles.entries {
		if !e.alive {
			continue
		}
		if n, ok := e.obj.(host.Node); ok && n.kind == kind {
			return abi.Handle(e.gen << 20 | u32(i))
		}
	}
	return abi.INVALID_HANDLE
}

find_node_with_text :: proc(p: ^host.Page, kind: abi.Node_Kind, text: string) -> abi.Handle {
	for e, i in p.handles.entries {
		if n, ok := e.obj.(host.Node); ok && e.alive && n.kind == kind && n.text == text {
			return abi.Handle(e.gen << 20 | u32(i))
		}
	}
	return abi.INVALID_HANDLE
}

@(test)
test_canvas_syscalls :: proc(t: ^testing.T) {
	p: host.Page
	if !load_page(t, &p, fmt.tprintf("%s/canvas.c.elf", FIXTURES)) {
		return
	}
	defer host.page_destroy(&p)
	run_page(&p)
	expect_exit(t, &p, 0)

	n := host.node_get(&p, find_node(&p, .Canvas))
	if !testing.expect(t, n != nil) {
		return
	}
	testing.expect_value(t, n.canvas.width, 4)
	testing.expect_value(t, n.canvas.height, 2)
	px := n.canvas.pixels
	testing.expect_value(t, [4]u8{px[0], px[1], px[2], px[3]}, [4]u8{0x11, 0x22, 0x33, 0x44})
	testing.expect_value(t, [4]u8{px[4], px[5], px[6], px[7]}, [4]u8{0xAA, 0xBB, 0xCC, 0xDD})
	testing.expect_value(t, [4]u8{px[8], px[9], px[10], px[11]}, [4]u8{0xAA, 0xBB, 0xCC, 0xDD})
	testing.expect_value(t, [4]u8{px[12], px[13], px[14], px[15]}, [4]u8{0x11, 0x22, 0x33, 0x44})
	testing.expect_value(t, [4]u8{px[16], px[17], px[18], px[19]}, [4]u8{0x11, 0x22, 0x33, 0x44})
	testing.expect(t, p.paint_version > 0)
}

@(test)
test_input_edit :: proc(t: ^testing.T) {
	p: host.Page
	p.allocator = context.allocator
	host.handle_table_init(&p.handles, 100)
	defer host.page_destroy(&p)

	input, _ := host.node_create(&p, .Input)
	box, _ := host.node_create(&p, .Box)
	before := p.tree_version
	host.page_input_edit(&p, input, "typed")
	testing.expect_value(t, host.node_get(&p, input).text, "typed")
	testing.expect(t, p.tree_version > before)
	testing.expect_value(t, len(p.events), 1)
	if len(p.events) == 1 {
		testing.expect_value(t, p.events[0].kind, abi.Event_Kind.Change)
		testing.expect_value(t, p.events[0].handle, input)
	}
	host.page_input_edit(&p, box, "ignored") // only Input nodes are user-editable
	testing.expect_value(t, host.node_get(&p, box).text, "")
	testing.expect_value(t, len(p.events), 1)
}

@(test)
test_input_select :: proc(t: ^testing.T) {
	p: host.Page
	p.allocator = context.allocator
	host.handle_table_init(&p.handles, 100)
	defer host.page_destroy(&p)

	input, _ := host.node_create(&p, .Input)
	box, _ := host.node_create(&p, .Box)
	host.node_set_text(&p, input, "héllo")
	host.page_input_select(&p, input, 1, 6)
	host.page_input_select(&p, input, 1, 6) // unchanged: no second event
	testing.expect_value(t, len(p.events), 1)
	if len(p.events) == 1 {
		testing.expect_value(t, p.events[0].kind, abi.Event_Kind.Select)
		testing.expect_value(t, p.events[0].handle, input)
		testing.expect_value(t, p.events[0].a, 1)
		testing.expect_value(t, p.events[0].b, 6)
	}
	host.page_input_select(&p, box, 0, 0) // only Inputs have a selection
	testing.expect_value(t, len(p.events), 1)

	// New text keeps the selection where it fits, on a rune boundary.
	host.node_set_text(&p, input, "hé")
	n := host.node_get(&p, input)
	testing.expect_value(t, n.anchor, 1)
	testing.expect_value(t, n.caret, 3)
	host.page_input_select(&p, input, 1, 2)
	host.node_set_text(&p, input, "hé") // inside é: back to its start
	testing.expect_value(t, n.caret, 1)
}

@(test)
test_selection_syscalls :: proc(t: ^testing.T) {
	p: host.Page
	if !load_page(t, &p, fmt.tprintf("%s/selection.c.elf", FIXTURES)) {
		return
	}
	defer host.page_destroy(&p)
	run_page(&p)
	expect_exit(t, &p, 0)

	n := host.node_get(&p, find_node(&p, .Input))
	if !testing.expect(t, n != nil) {
		return
	}
	testing.expect(t, n.selection_set) // waiting for the browser to apply it
	testing.expect_value(t, len(p.events), 0) // the page's own moves send no Select
	testing.expect(t, p.focus_requested)
	testing.expect_value(t, p.focus_request, find_node(&p, .Input)) // the last request wins
}

@(test)
test_storage :: proc(t: ^testing.T) {
	path := fmt.tprintf("%s/test_storage.cbor", BUILD_DIR)
	os.remove(path)
	defer os.remove(path)

	for variant in ([]string{"c", "nc"}) {
		os.remove(path) // each variant starts from an empty store
		p: host.Page
		if !load_page(t, &p, fmt.tprintf("%s/storage.%s.elf", FIXTURES, variant)) {
			return
		}
		testing.expect_value(t, p.image.manifest.storage, 64)
		host.page_attach_storage(&p, path)
		run_page(&p)
		expect_exit(t, &p, 0)
		host.page_destroy(&p)
	}

	// What the page stored survives in the file.
	st: host.Storage
	host.storage_open(&st, path, 64)
	defer host.storage_close(&st)
	v, ok := host.storage_get(&st, "persist")
	testing.expect(t, ok && string(v) == "yes")
	testing.expect_value(t, st.used, len("persist") + len("yes"))
	_, gone := host.storage_get(&st, "k")
	testing.expect(t, !gone)
}

@(test)
test_storage_quota_cap :: proc(t: ^testing.T) {
	st: host.Storage
	host.storage_open(&st, "", 1 << 40) // a huge manifest request is capped
	defer host.storage_close(&st)
	testing.expect_value(t, st.quota, abi.MAX_STORAGE_QUOTA)
	testing.expect_value(t, host.storage_set(&st, "a", make([]u8, 10, context.temp_allocator)), abi.Errno.OK)
	testing.expect_value(t, st.used, 11)
}

Fetch_Log :: struct {
	ids:  [dynamic]u64,
	urls: [dynamic]string,
}

@(test)
test_fetch :: proc(t: ^testing.T) {
	for variant in ([]string{"c", "nc"}) {
		p: host.Page
		if !load_page(t, &p, fmt.tprintf("%s/fetch.%s.elf", FIXTURES, variant)) {
			return
		}
		defer host.page_destroy(&p)
		log: Fetch_Log
		defer {
			for u in log.urls {
				delete(u)
			}
			delete(log.urls)
			delete(log.ids)
		}
		p.user_data = &log
		p.fetch_proc = proc(p: ^host.Page, id: u64, url: string) {
			log := (^Fetch_Log)(p.user_data)
			append(&log.ids, id)
			append(&log.urls, strings.clone(url))
		}
		host.page_set_location(&p, "nb://site.example/app/page")

		// Answer every request each time the page waits.
		answers := []string{"hello", "nope", "never seen"}
		statuses := []i64{200, 404, 200}
		answered := 0
		for run_page(&p) == .Waiting && answered < len(log.ids) {
			for ; answered < len(log.ids); answered += 1 {
				i := min(answered, len(answers) - 1)
				host.page_fetch_complete(&p, log.ids[answered], statuses[i], transmute([]u8)answers[i])
			}
		}
		expect_exit(t, &p, 0) // otherwise the exit code is the failing CHECK

		want := []string{
			"nb://allowed.example/data/x",
			"nb://site.example/app/rel/y",
			"nb://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@KEYED.example/k",
		}
		testing.expect_value(t, len(log.urls), len(want) + abi.MAX_FETCHES)
		for w, i in want {
			if i < len(log.urls) {
				testing.expect_value(t, log.urls[i], w)
			}
		}
		testing.expect_value(t, len(p.fetches), abi.MAX_FETCHES) // the last batch is never answered
	}
}

@(test)
test_fetch_policy :: proc(t: ^testing.T) {
	p: host.Page
	if !load_page(t, &p, fmt.tprintf("%s/fetch.c.elf", FIXTURES)) {
		return
	}
	defer host.page_destroy(&p)

	// Without a location (a local file), relative requests and "fetch /"
	// entries have no server to refer to.
	_, err := host.fetch_resolve(&p, "rel/y")
	testing.expect_value(t, err, abi.Errno.PERM)
	url, err2 := host.fetch_resolve(&p, "nb://allowed.example:4040/data/")
	testing.expect_value(t, err2, abi.Errno.OK)
	testing.expect_value(t, url, "nb://allowed.example/data/")
	_, err3 := host.fetch_resolve(&p, "nb://allowed.example:4041/data/x")
	testing.expect_value(t, err3, abi.Errno.PERM) // another port is another server

	// With a location that names a key, relative requests must reach that key.
	k1, k2: proto.Key
	k1[0], k2[0] = 1, 2
	key := proto.key_string(k1, context.temp_allocator)
	host.page_set_location(&p, fmt.tprintf("nb://%s@site.example/app/page", key))
	url, err = host.fetch_resolve(&p, "/app/data.txt")
	testing.expect_value(t, err, abi.Errno.OK)
	testing.expect_value(t, url, fmt.tprintf("nb://%s@site.example/app/data.txt", key))
	_, err = host.fetch_resolve(&p, "nb://site.example/app/data.txt")
	testing.expect_value(t, err, abi.Errno.OK) // same server, key from the entry
	_, err = host.fetch_resolve(&p, fmt.tprintf("nb://%s@site.example/app/x", proto.key_string(k2, context.temp_allocator)))
	testing.expect_value(t, err, abi.Errno.PERM) // a different key is a different server

	testing.expect(t, host.fetch_entry_valid("/"))
	testing.expect(t, host.fetch_entry_valid("nb://example.org"))
	testing.expect(t, !host.fetch_entry_valid("https://example.org"))
}
