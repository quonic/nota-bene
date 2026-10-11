// nbrun runs a page headlessly: no window, no network. It prints the page's
// log, can trace syscalls or instructions, and can dump the view tree.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "../../abi"
import "../../host"
import "../../loader"
import "../../vm"

USAGE :: `usage: nbrun [options] page.elf

options:
  --budget N     stop the page after N instructions (default 1000000000)
  --mem SIZE     guest memory size, e.g. 64M (default 64M, max 1G)
  --stack SIZE   stack size (default 1M)
  --trace        print every syscall
  --trace-inst   print every instruction (slow)
  --dump-tree    print the view tree when the page stops
  --storage FILE keep the page's storage in FILE (default: memory only)
  -h, --help     show this help

exit status: the page's exit code if it exits; 2 usage or load error;
3 the page faulted; 4 the page was stopped (budget, ebreak, idle forever).
`

Options :: struct {
	path:       string,
	budget:     u64,
	cfg:        loader.Config,
	trace:      bool,
	trace_inst: bool,
	dump_tree:  bool,
	storage:    string,
}

SLICE :: 1_000_000

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

	idle := run(&page, opts)

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
	case .Running, .Waiting:
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
			// Headless: there are no input sources, so a timed wait completes
			// immediately on a skipped-ahead clock and an unbounded wait is
			// answered with Quit, once.
			if host.page_skip_to_deadline(page) {
				continue
			}
			if !page.quit_sent {
				host.page_push_event(page, abi.Event{kind = .Quit})
				continue
			}
			return true
		case .Exited, .Faulted, .Killed:
			return false
		}
	}
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
	opts.budget = 1_000_000_000
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
		case:
			if strings.has_prefix(arg, "-") || opts.path != "" {
				fmt.eprintfln("nbrun: unexpected argument %q", arg)
				return opts, false
			}
			opts.path = arg
		}
	}
	return opts, opts.path != ""
}
