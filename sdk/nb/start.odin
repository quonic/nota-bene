package nb

import "base:runtime"

@(private) heap_state: Heap
@(private) temp_arena: runtime.Arena

// Sets up the Odin runtime for a page and runs `entry`. Exits with code 0
// when `entry` returns.
start :: proc "contextless" (entry: proc()) -> ! {
	context = page_context()
	runtime._startup_runtime()
	entry()
	runtime._cleanup_runtime()
	exit(0)
}

// The context pages run with: heap and temp allocators backed by Mem_Grow,
// assertions and panics reported through Debug_Log, and a random generator
// backed by the Random syscall.
page_context :: proc "contextless" () -> runtime.Context {
	c := runtime.default_context()
	c.allocator = heap_allocator(&heap_state)
	c.assertion_failure_proc = assertion_failure
	c.random_generator = {procedure = random_generator_proc}
	if temp_arena.backing_allocator.procedure == nil {
		context = c
		_ = runtime.arena_init(&temp_arena, 0, c.allocator)
	}
	c.temp_allocator = {procedure = runtime.arena_allocator_proc, data = &temp_arena}
	return c
}

@(private)
assertion_failure :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	buf: [512]u8
	n := 0
	put :: proc "contextless" (buf: []u8, n: ^int, s: string) {
		n^ += copy(buf[n^:], s)
	}
	put(buf[:], &n, prefix)
	if len(message) > 0 {
		put(buf[:], &n, ": ")
		put(buf[:], &n, message)
	}
	put(buf[:], &n, " at ")
	put(buf[:], &n, loc.file_path)
	put(buf[:], &n, ":")
	line_buf: [20]u8
	put(buf[:], &n, format_uint(line_buf[:], u64(loc.line)))
	log(string(buf[:n]), .Error)
	exit(PANIC_EXIT_CODE)
}

@(private)
format_uint :: proc "contextless" (buf: []u8, v: u64) -> string {
	i := len(buf)
	v := v
	for {
		i -= 1
		buf[i] = '0' + u8(v % 10)
		v /= 10
		if v == 0 || i == 0 {
			break
		}
	}
	return string(buf[i:])
}

@(private)
random_generator_proc :: proc(data: rawptr, mode: runtime.Random_Generator_Mode, p: []byte) {
	switch mode {
	case .Read:
		for off := 0; off < len(p); off += 64 * 1024 {
			random(p[off:][:min(64 * 1024, len(p) - off)])
		}
	case .Reset:
	case .Query_Info:
		if len(p) != size_of(runtime.Random_Generator_Query_Info) {
			return
		}
		info := (^runtime.Random_Generator_Query_Info)(raw_data(p))
		info^ += {.Cryptographic, .Uniform, .External_Entropy}
	}
}
