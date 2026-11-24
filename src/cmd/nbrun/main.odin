// nbrun runs a page headlessly: no window, no network. It prints the page's
// log, can trace syscalls or instructions, can dump the view tree, and can
// let GDB debug the page (--gdb).
package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"

import "../../abi"
import "../../gdbstub"
import "../../host"
import "../../loader"
import "../../vm"

USAGE :: `usage: nbrun [options] page.elf

options:
  --budget N     stop the page after N instructions (default 1000000000;
                 under --gdb, no limit until GDB detaches unless
                 --budget is given)
  --mem SIZE     guest memory size, e.g. 64M (default 64M, max 1G)
  --stack SIZE   stack size (default 1M)
  --trace        print every syscall
  --trace-inst   print every instruction (slow)
  --dump-tree    print the view tree when the page stops
  --storage FILE keep the page's storage in FILE (default: memory only)
  --gdb PORT     wait for GDB on 127.0.0.1:PORT before the first instruction;
                 then run gdb page.elf and type target remote :PORT
  -h, --help     show this help

exit status: the page's exit code if it exits; 2 usage or load error;
3 the page faulted; 4 the page was stopped (budget, ebreak, idle forever,
killed from GDB).
`

Options :: struct {
	path:       string,
	budget:     u64, // max(u64): no limit
	budget_set: bool, // --budget was given
	cfg:        loader.Config,
	trace:      bool,
	trace_inst: bool,
	dump_tree:  bool,
	storage:    string,
	gdb_port:   int, // 0: no debugger
}

DEFAULT_BUDGET :: 1_000_000_000

SLICE :: 1_000_000
// Under GDB the socket is polled for Ctrl-C between slices, so they are shorter.
GDB_SLICE :: 100_000

main :: proc() {
	opts, ok := parse_args(os.args[1:])
	if !ok {
		fmt.eprint(USAGE)
		os.exit(2)
	}

	elf, read_err := os.read_entire_file(opts.path, context.allocator)
	if read_err != nil {
		fmt.eprintfln("nbrun: cannot read %s: %v", opts.path, read_err)
		os.exit(2)
	}
	defer delete(elf)

	page: host.Page
	if err := host.page_init(&page, elf, opts.cfg); err != nil {
		fmt.eprintfln("nbrun: cannot load %s: %v", opts.path, err)
		os.exit(2)
	}
	defer host.page_destroy(&page)

	page.log_proc = log_line
	host.page_attach_storage(&page, opts.storage)
	if opts.trace {
		page.trace_proc = trace_syscall
	}
	for key in page.image.manifest.unknown {
		fmt.eprintfln("nbrun: warning: unknown manifest key %q", key)
	}

	idle := debug(&page, opts) if opts.gdb_port != 0 else run(&page, opts)

	if opts.dump_tree {
		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		host.dump_tree(&page, &sb)
		fmt.print(strings.to_string(sb))
	}

	instret := page.cpu.instret
	switch page.state {
	case .Exited:
		if page.exit_code != 0 {
			fmt.eprintfln("nbrun: page exited with code %d after %d instructions", page.exit_code, instret)
		}
		os.exit(int(u8(page.exit_code)))
	case .Faulted:
		fmt.eprintfln("nbrun: page faulted: %s", vm.describe_fault(page.cpu.fault, context.temp_allocator))
		os.exit(3)
	case .Killed:
		fmt.eprintfln("nbrun: page stopped: %s (after %d instructions)", page.kill_reason, instret)
		os.exit(4)
	case .Running, .Waiting, .Break:
		if idle {
			fmt.eprintln("nbrun: page is waiting for events forever after Quit; stopping it")
		}
		os.exit(4)
	}
}

// Drives the page until it stops. Returns true if it ended up idle forever.
run :: proc(page: ^host.Page, opts: Options) -> (idle: bool) {
	for {
		if page.cpu.instret >= opts.budget {
			host.page_kill(page, "instruction budget exhausted")
			return false
		}
		left := opts.budget - page.cpu.instret
		state: host.Page_State
		if opts.trace_inst {
			trace_instruction(page)
			state = host.page_run(page, 1)
		} else {
			state = host.page_run(page, min(SLICE, left))
		}

		switch state {
		case .Running:
		case .Waiting:
			if headless_wake(page) {
				continue
			}
			return true
		case .Exited, .Faulted, .Killed, .Break:
			return false
		}
	}
}

// Headless: there are no input sources, so a timed wait completes
// immediately on a skipped-ahead clock and an unbounded wait is answered
// with Quit, once. Returns false if the page would wait forever.
headless_wake :: proc(page: ^host.Page) -> bool {
	if host.page_skip_to_deadline(page) {
		return true
	}
	if !page.quit_sent {
		host.page_push_event(page, abi.Event{kind = .Quit})
		return true
	}
	return false
}

// Serves one GDB client on 127.0.0.1 and runs the page under it. The page
// does not start until GDB says so. If GDB detaches, the page runs on as
// without --gdb.
debug :: proc(page: ^host.Page, opts: Options) -> (idle: bool) {
	listener, err := net.listen_tcp({net.IP4_Loopback, opts.gdb_port}, 1)
	if err != nil {
		fmt.eprintfln("nbrun: cannot listen on 127.0.0.1:%d: %v", opts.gdb_port, err)
		os.exit(2)
	}
	fmt.eprintfln("nbrun: waiting for GDB on 127.0.0.1:%d", opts.gdb_port)
	client, _, aerr := net.accept_tcp(listener)
	net.close(listener) // one client
	if aerr != nil {
		fmt.eprintfln("nbrun: accepting GDB failed: %v", aerr)
		os.exit(2)
	}
	defer net.close(client)
	net.set_option(client, .TCP_Nodelay, true)

	s: gdbstub.Session
	gdbstub.session_init(&s, page, opts.budget, headless_wake)
	defer gdbstub.session_destroy(&s)

	buf: [4096]u8
	blocking := true
	connected := true
	for connected && s.done == .No {
		connected = send_all(client, s.out[:])
		clear(&s.out)
		// Block while GDB has the page stopped; poll while it runs, so
		// Ctrl-C (0x03) can interrupt it between slices.
		if running := gdbstub.session_running(&s); running == blocking {
			blocking = !running
			net.set_blocking(client, blocking)
		}
		n, rerr := net.recv_tcp(client, buf[:])
		#partial switch rerr {
		case .None:
			if n == 0 {
				connected = false // GDB went away
			}
		case .Would_Block, .Interrupted:
		case:
			connected = false
		}
		gdbstub.session_feed(&s, buf[:n])
		gdbstub.session_run(&s, GDB_SLICE)
	}
	if connected {
		send_all(client, s.out[:]) // the reply to D or vKill
	}

	switch s.done {
	case .Detached:
		fmt.eprintln("nbrun: GDB detached; running on")
		opts := opts
		if !opts.budget_set {
			// Nobody is driving any more, so the usual limit applies again,
			// counted from here.
			instret := page.cpu.instret
			opts.budget = instret + min(DEFAULT_BUDGET, max(u64) - instret)
		}
		return run(page, opts)
	case .Killed:
	case .No:
		if s.mode != .Ended {
			host.page_kill(page, "GDB disconnected")
		}
	}
	return false
}

send_all :: proc(sock: net.TCP_Socket, data: []u8) -> bool {
	for sent := 0; sent < len(data); {
		n, err := net.send_tcp(sock, data[sent:])
		if err == .Would_Block || err == .Interrupted {
			continue
		}
		if err != nil {
			return false
		}
		sent += n
	}
	return true
}

log_line :: proc(p: ^host.Page, level: abi.Log_Level, msg: string) {
	switch level {
	case .Info:  fmt.printfln("[page] %s", msg)
	case .Warn:  fmt.printfln("[page] warning: %s", msg)
	case .Error: fmt.printfln("[page] error: %s", msg)
	}
}

trace_syscall :: proc(p: ^host.Page, nr: u64, args: [6]u64, ret: i64) {
	name := fmt.tprintf("0x%03x", nr)
	if nr <= u64(max(u32)) {
		if s, ok := fmt.enum_value_to_string(abi.Syscall(u32(nr))); ok {
			name = s
		}
	}
	if p.state == .Waiting {
		fmt.eprintfln("syscall %s(0x%x, 0x%x, 0x%x, 0x%x) = (waiting)", name, args[0], args[1], args[2], args[3])
	} else if ret < 0 && ret >= -64 {
		e, _ := fmt.enum_value_to_string(abi.Errno(-ret))
		fmt.eprintfln("syscall %s(0x%x, 0x%x, 0x%x, 0x%x) = -%s", name, args[0], args[1], args[2], args[3], e)
	} else {
		fmt.eprintfln("syscall %s(0x%x, 0x%x, 0x%x, 0x%x) = %d", name, args[0], args[1], args[2], args[3], ret)
	}
}

trace_instruction :: proc(p: ^host.Page) {
	pc := p.cpu.pc
	lo, ok := vm.fetch16(&p.cpu.mem, pc)
	if !ok {
		return
	}
	if lo & 3 != 3 {
		fmt.eprintfln("%08x:     %04x", pc, lo)
		return
	}
	hi, _ := vm.fetch16(&p.cpu.mem, pc + 2)
	fmt.eprintfln("%08x: %08x", pc, u32(lo) | u32(hi) << 16)
}

parse_args :: proc(args: []string) -> (opts: Options, ok: bool) {
	opts.cfg = loader.DEFAULT_CONFIG
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		value :: proc(args: []string, i: ^int) -> (string, bool) {
			if i^ + 1 >= len(args) {
				fmt.eprintfln("nbrun: %s needs a value", args[i^])
				return "", false
			}
			i^ += 1
			return args[i^], true
		}
		switch arg {
		case "-h", "--help":
			fmt.print(USAGE)
			os.exit(0)
		case "--budget":
			v := value(args, &i) or_return
			opts.budget = strconv.parse_u64_of_base(v, 10) or_return
			opts.budget_set = true
		case "--mem":
			v := value(args, &i) or_return
			opts.cfg.mem_size = loader.parse_size(v) or_return
		case "--stack":
			v := value(args, &i) or_return
			opts.cfg.stack_size = loader.parse_size(v) or_return
		case "--trace":
			opts.trace = true
		case "--trace-inst":
			opts.trace_inst = true
		case "--dump-tree":
			opts.dump_tree = true
		case "--storage":
			opts.storage = value(args, &i) or_return
		case "--gdb":
			v := value(args, &i) or_return
			port := strconv.parse_int(v, 10) or_return
			if port < 1 || port > 65535 {
				fmt.eprintfln("nbrun: bad port %q", v)
				return opts, false
			}
			opts.gdb_port = port
		case:
			if strings.has_prefix(arg, "-") || opts.path != "" {
				fmt.eprintfln("nbrun: unexpected argument %q", arg)
				return opts, false
			}
			opts.path = arg
		}
	}
	if opts.gdb_port != 0 && opts.trace_inst {
		fmt.eprintln("nbrun: --trace-inst cannot be used with --gdb")
		return opts, false
	}
	if !opts.budget_set {
		// A human driving GDB decides when the page stops, so a debugging
		// session has no budget unless one is asked for.
		opts.budget = max(u64) if opts.gdb_port != 0 else DEFAULT_BUDGET
	}
	return opts, opts.path != ""
}
