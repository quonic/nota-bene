// Package gdbstub lets GDB debug a page over the GDB Remote Serial Protocol.
//
// It does no I/O: a front end passes the bytes GDB sent to session_feed,
// sends whatever collects in Session.out, and calls session_run while the
// page runs. nbrun --gdb does this over a TCP socket.
//
// Breakpoints never touch guest code (executable pages are never writable).
// While any are set, the page runs one instruction at a time and the stub
// checks pc before each one; without breakpoints it runs in whole slices.
package gdbstub

import "base:runtime"
import "core:fmt"
import "core:strings"

import "../host"
import "../vm"

// GDB's own signal numbers, which the stop replies use.
SIGINT  :: 2
SIGILL  :: 4
SIGTRAP :: 5
SIGKILL :: 9
SIGBUS  :: 10
SIGSEGV :: 11

Mode :: enum u8 {
	Stopped,  // waiting for a command
	Running,  // after `c`: until a breakpoint, an ebreak, an interrupt or the end
	Stepping, // after `s`: one instruction
	Ended,    // the page exited or was stopped, and GDB was told (W or X)
}

Done :: enum u8 {
	No,
	Detached, // `D`: the front end runs the page on without the debugger
	Killed,   // `k` or vKill: the page was stopped
}

Bp_Kind  :: enum u8 {Software, Hardware}
Bp_Kinds :: bit_set[Bp_Kind; u8]

// Wakes a page blocked in Wait_Event. Returns false if it would wait forever.
Wait_Proc :: #type proc(p: ^host.Page) -> bool

Session :: struct {
	page:        ^host.Page,
	budget:      u64,       // the page is stopped once instret reaches this
	wait_proc:   Wait_Proc, // nil: a waiting page is stopped

	mode:        Mode,
	done:        Done,
	no_ack:      bool,
	swbreak:     bool, // GDB takes the swbreak and hwbreak stop reasons
	hwbreak:     bool,
	breakpoints: map[u64]Bp_Kinds,
	resumed:     bool, // nothing has run since the resume; a breakpoint at pc does not fire
	ebreak_pc:   u64,  // where the page last stopped on an ebreak
	ebreak_len:  u64,

	dec:         Decoder,
	out:         [dynamic]u8, // bytes for GDB; the front end sends and clears them
	last:        [dynamic]u8, // the last packet, resent when GDB answers '-'
	stop_reply:  strings.Builder,
	scratch:     strings.Builder,
	xml:         string,
	allocator:   runtime.Allocator,
}

session_init :: proc(s: ^Session, p: ^host.Page, budget := max(u64), wait_proc: Wait_Proc = nil, allocator := context.allocator) {
	s^ = {
		page      = p,
		budget    = budget,
		wait_proc = wait_proc,
		allocator = allocator,
	}
	p.debugger = true
	s.breakpoints = make(map[u64]Bp_Kinds, allocator)
	s.dec.body = make([dynamic]u8, allocator)
	s.out = make([dynamic]u8, allocator)
	s.last = make([dynamic]u8, allocator)
	s.stop_reply = strings.builder_make(allocator)
	s.scratch = strings.builder_make(allocator)
	s.xml = target_xml(allocator)
	// GDB asks `?` first; the page has not run yet.
	strings.write_string(&s.stop_reply, "T05")
}

session_destroy :: proc(s: ^Session) {
	delete(s.breakpoints)
	decoder_destroy(&s.dec)
	delete(s.out)
	delete(s.last)
	strings.builder_destroy(&s.stop_reply)
	strings.builder_destroy(&s.scratch)
	delete(s.xml, s.allocator)
	s^ = {}
}

session_running :: proc(s: ^Session) -> bool {
	return s.mode == .Running || s.mode == .Stepping
}

// Handles bytes from GDB. Replies are appended to s.out.
session_feed :: proc(s: ^Session, data: []u8) {
	for b in data {
		switch decode_byte(&s.dec, b) {
		case .Packet:
			if !s.no_ack {
				append(&s.out, '+')
			}
			handle_packet(s, string(s.dec.body[:]))
		case .Bad:
			if !s.no_ack {
				append(&s.out, '-')
			}
		case .Nak:
			append(&s.out, ..s.last[:])
		case .Interrupt:
			if session_running(s) {
				stop(s, SIGINT)
			}
		case .Ack, .None:
		}
	}
}

// Runs the page for up to `slice` instructions while GDB has it running.
// Stopping (a breakpoint, an ebreak, the end of a step, the page ending)
// appends the stop reply to s.out.
//
// With breakpoints set, each instruction is a separate page_run call so pc
// can be checked before it executes. That costs a call and a map lookup per
// instruction, several times slower than running a slice, and only while
// breakpoints exist.
session_run :: proc(s: ^Session, slice: u64) {
	if !session_running(s) {
		return
	}
	p := s.page
	bulk := s.mode == .Running && len(s.breakpoints) == 0
	done: u64
	for done < slice {
		if kinds, ok := s.breakpoints[p.cpu.pc]; ok && !s.resumed {
			stop_at_breakpoint(s, kinds)
			return
		}
		s.resumed = false
		if p.cpu.instret >= s.budget {
			host.page_kill(p, "instruction budget exhausted")
			end(s, 'X', SIGKILL)
			return
		}
		n := u64(1)
		if bulk {
			n = min(slice - done, s.budget - p.cpu.instret)
		}
		before := p.cpu.instret
		state := host.page_run(p, n)
		done += max(p.cpu.instret - before, 1)

		switch state {
		case .Running:
			if s.mode == .Stepping {
				stop(s, SIGTRAP)
				return
			}
		case .Waiting:
			if s.wait_proc == nil || !s.wait_proc(p) {
				host.page_kill(p, "waiting for events forever")
				end(s, 'X', SIGKILL)
				return
			}
			if s.mode == .Stepping {
				stop(s, SIGTRAP)
				return
			}
		case .Break:
			s.ebreak_pc = p.cpu.pc
			s.ebreak_len = 4
			if half, ok := vm.memory_slice(&p.cpu.mem, p.cpu.pc, 2, {.Read}); ok && half[0] & 3 != 3 {
				s.ebreak_len = 2 // c.ebreak
			}
			stop(s, SIGTRAP)
			return
		case .Exited:
			end(s, 'W', u8(p.exit_code))
			return
		case .Faulted:
			stop(s, fault_signal(p.cpu.fault.kind))
			return
		case .Killed:
			end(s, 'X', SIGKILL)
			return
		}
	}
}

// Disconnects the debugger and lets the page run on as if it had never been
// attached. A page stopped on an ebreak continues after it.
session_detach :: proc(s: ^Session) {
	p := s.page
	p.debugger = false
	leave_ebreak(s)
	s.done = .Detached
}

fault_signal :: proc(kind: vm.Fault_Kind) -> u8 {
	#partial switch kind {
	case .Illegal_Instruction: return SIGILL
	case .Misaligned_Atomic:   return SIGBUS
	}
	return SIGSEGV
}

@(private)
reply :: proc(s: ^Session, payload: string) {
	clear(&s.last)
	encode_packet(&s.last, payload)
	append(&s.out, ..s.last[:])
}

@(private)
stop :: proc(s: ^Session, sig: u8, reason := "") {
	s.mode = .Stopped
	strings.builder_reset(&s.stop_reply)
	fmt.sbprintf(&s.stop_reply, "T%02x%s", sig, reason)
	reply(s, strings.to_string(s.stop_reply))
}

// Tells GDB the page is gone: W<exit code> or X<signal>.
@(private)
end :: proc(s: ^Session, kind: u8, code: u8) {
	s.mode = .Ended
	strings.builder_reset(&s.stop_reply)
	strings.write_byte(&s.stop_reply, kind)
	fmt.sbprintf(&s.stop_reply, "%02x", code)
	reply(s, strings.to_string(s.stop_reply))
}

@(private)
stop_at_breakpoint :: proc(s: ^Session, kinds: Bp_Kinds) {
	reason := ""
	if .Software in kinds && s.swbreak {
		reason = "swbreak:;"
	} else if .Hardware in kinds && s.hwbreak {
		reason = "hwbreak:;"
	}
	stop(s, SIGTRAP, reason)
}

// A page stopped on an ebreak resumes after it, unless GDB moved pc.
@(private)
leave_ebreak :: proc(s: ^Session) -> (skipped: bool) {
	p := s.page
	if p.state != .Break {
		return false
	}
	p.state = .Running
	if p.cpu.pc == s.ebreak_pc {
		p.cpu.pc += s.ebreak_len
		return true
	}
	return false
}

@(private)
resume :: proc(s: ^Session, step: bool, addr: string) {
	if s.mode == .Ended {
		reply(s, strings.to_string(s.stop_reply))
		return
	}
	p := s.page
	if addr != "" {
		pc, ok := parse_hex(addr)
		if !ok {
			reply(s, "E01")
			return
		}
		p.cpu.pc = pc
	}
	if p.state == .Faulted {
		// A fault cannot be resumed; like an unhandled signal it ends the process.
		end(s, 'X', fault_signal(p.cpu.fault.kind))
		return
	}
	// Skipping an ebreak counts as the first instruction: a breakpoint right
	// after it fires, and a step ends there.
	skipped := leave_ebreak(s)
	if skipped && step {
		stop(s, SIGTRAP)
		return
	}
	s.mode = Mode.Stepping if step else Mode.Running
	s.resumed = !skipped
}

@(private)
kill :: proc(s: ^Session) {
	if s.mode != .Ended {
		host.page_kill(s.page, "killed by the debugger")
		s.mode = .Ended
	}
	s.done = .Killed
}

@(private)
handle_packet :: proc(s: ^Session, pkt: string) {
	if pkt == "" {
		reply(s, "")
		return
	}
	cpu := &s.page.cpu
	sb := &s.scratch
	strings.builder_reset(sb)
	args := pkt[1:]

	switch pkt[0] {
	case '?':
		reply(s, strings.to_string(s.stop_reply))

	case 'g':
		for n in G_REGS {
			write_le(sb, reg_get(cpu, n), reg_size(n))
		}
		reply(s, strings.to_string(sb^))

	case 'G':
		want := 0
		for n in G_REGS {
			want += 2 * reg_size(n)
		}
		if len(args) != want {
			reply(s, "E01")
			return
		}
		vals: [len(G_REGS)]u64
		at := 0
		for n, i in G_REGS {
			size := reg_size(n)
			v, ok := read_le(args[at:][:2 * size])
			if !ok {
				reply(s, "E01")
				return
			}
			vals[i] = v
			at += 2 * size
		}
		for n, i in G_REGS {
			reg_set(cpu, n, vals[i])
		}
		reply(s, "OK")

	case 'p':
		n, ok := parse_hex(args)
		size := reg_size(int(n)) if ok && n <= 128 else 0
		if size == 0 {
			reply(s, "E01")
			return
		}
		write_le(sb, reg_get(cpu, int(n)), size)
		reply(s, strings.to_string(sb^))

	case 'P':
		num, eq, val := strings.partition(args, "=")
		n, ok := parse_hex(num)
		size := reg_size(int(n)) if ok && n <= 128 else 0
		v, vok := read_le(val)
		if eq == "" || size == 0 || !vok || len(val) != 2 * size {
			reply(s, "E01")
			return
		}
		reg_set(cpu, int(n), v)
		reply(s, "OK")

	case 'm':
		read_memory(s, args)

	case 'M':
		write_memory(s, args)

	case 'c':
		resume(s, false, args)
	case 's':
		resume(s, true, args)
	case 'C', 'S':
		// Continue with a signal. Pages have no signal handlers, so the signal
		// only matters after a fault, which resume handles.
		_, _, addr := strings.partition(args, ";")
		resume(s, pkt[0] == 'S', addr)

	case 'Z', 'z':
		set_breakpoint(s, pkt[0] == 'Z', args)

	case 'k':
		kill(s) // no reply: GDB closes the connection

	case 'D':
		reply(s, "OK")
		session_detach(s)

	case 'H', 'T':
		reply(s, "OK") // one thread, always alive

	case 'q':
		handle_query(s, pkt)

	case 'Q':
		if pkt == "QStartNoAckMode" {
			reply(s, "OK") // this reply is still acknowledged
			s.no_ack = true
		} else {
			reply(s, "")
		}

	case 'v':
		if strings.has_prefix(pkt, "vKill") {
			reply(s, "OK")
			kill(s)
		} else {
			reply(s, "") // vMustReplyEmpty, vCont? and anything else
		}

	case:
		reply(s, "")
	}
}

@(private)
handle_query :: proc(s: ^Session, pkt: string) {
	switch {
	case strings.has_prefix(pkt, "qSupported"):
		_, _, features := strings.partition(pkt, ":")
		for f in strings.split_iterator(&features, ";") {
			switch f {
			case "swbreak+": s.swbreak = true
			case "hwbreak+": s.hwbreak = true
			}
		}
		reply(s, fmt.tprintf("PacketSize=%x;qXfer:features:read+;QStartNoAckMode+;swbreak+;hwbreak+", PACKET_SIZE))

	case strings.has_prefix(pkt, "qXfer:features:read:"):
		rest := pkt[len("qXfer:features:read:"):]
		annex, _, range := strings.partition(rest, ":")
		off_s, _, len_s := strings.partition(range, ",")
		off, ok1 := parse_hex(off_s)
		n, ok2 := parse_hex(len_s)
		if annex != "target.xml" || !ok1 || !ok2 {
			reply(s, "E00")
			return
		}
		if off >= u64(len(s.xml)) {
			reply(s, "l")
			return
		}
		n = min(n, (PACKET_SIZE - 8) / 2) // room for the marker, the framing and escapes
		chunk := s.xml[off:]
		marker := "l"
		if u64(len(chunk)) > n {
			chunk = chunk[:n]
			marker = "m"
		}
		reply(s, fmt.tprintf("%s%s", marker, chunk))

	case pkt == "qAttached":
		reply(s, "0") // nbrun started the page for us: quitting GDB kills it
	case pkt == "qC":
		reply(s, "QC1")
	case pkt == "qfThreadInfo":
		reply(s, "m1")
	case pkt == "qsThreadInfo":
		reply(s, "l")
	case:
		reply(s, "")
	}
}

// m addr,length. Reads stop at the first byte the page cannot read; GDB
// accepts a short reply, and an error if nothing was readable.
@(private)
read_memory :: proc(s: ^Session, args: string) {
	addr_s, _, len_s := strings.partition(args, ",")
	addr, ok1 := parse_hex(addr_s)
	length, ok2 := parse_hex(len_s)
	if !ok1 || !ok2 {
		reply(s, "E01")
		return
	}
	length = min(length, (PACKET_SIZE - 8) / 2)
	mem := &s.page.cpu.mem
	n: u64
	for n < length && vm.memory_check(mem, addr + n, 1, {.Read}) {
		n += 1
	}
	if n == 0 && length > 0 {
		reply(s, "E01")
		return
	}
	data, _ := vm.memory_slice(mem, addr, n, {.Read})
	sb := &s.scratch
	for b in data {
		strings.write_byte(sb, HEX[b >> 4])
		strings.write_byte(sb, HEX[b & 15])
	}
	reply(s, strings.to_string(sb^))
}

// M addr,length:bytes. The write goes through the page's own permissions, so
// code (never writable) and unmapped memory give an error.
@(private)
write_memory :: proc(s: ^Session, args: string) {
	head, _, hex := strings.partition(args, ":")
	addr_s, _, len_s := strings.partition(head, ",")
	addr, ok1 := parse_hex(addr_s)
	length, ok2 := parse_hex(len_s)
	if !ok1 || !ok2 || u64(len(hex)) != 2 * length {
		reply(s, "E01")
		return
	}
	for i in 0 ..< len(hex) {
		if _, ok := hex_digit(hex[i]); !ok {
			reply(s, "E01")
			return
		}
	}
	dst, ok := vm.memory_slice(&s.page.cpu.mem, addr, length, {.Write})
	if !ok {
		reply(s, "E01")
		return
	}
	for &b, i in dst {
		hi, _ := hex_digit(hex[2 * i])
		lo, _ := hex_digit(hex[2 * i + 1])
		b = hi << 4 | lo
	}
	reply(s, "OK")
}

// Z/z type,addr,kind. Types 0 (software) and 1 (hardware) are both kept in
// the stub's own table; anything else (watchpoints) is unsupported.
@(private)
set_breakpoint :: proc(s: ^Session, insert: bool, args: string) {
	type_s, _, rest := strings.partition(args, ",")
	addr_s, _, _ := strings.partition(rest, ",")
	kind: Bp_Kind
	switch type_s {
	case "0": kind = .Software
	case "1": kind = .Hardware
	case:
		reply(s, "")
		return
	}
	addr, ok := parse_hex(addr_s)
	if !ok {
		reply(s, "E01")
		return
	}
	kinds := s.breakpoints[addr]
	if insert {
		kinds += {kind}
	} else {
		kinds -= {kind}
	}
	if kinds == {} {
		delete_key(&s.breakpoints, addr)
	} else {
		s.breakpoints[addr] = kinds
	}
	reply(s, "OK")
}

// Parses 1 to 16 hex digits.
parse_hex :: proc(str: string) -> (v: u64, ok: bool) {
	if len(str) == 0 || len(str) > 16 {
		return 0, false
	}
	for i in 0 ..< len(str) {
		d := hex_digit(str[i]) or_return
		v = v << 4 | u64(d)
	}
	return v, true
}

// Register values travel as little-endian bytes in hex.
write_le :: proc(sb: ^strings.Builder, v: u64, size: int) {
	for i in 0 ..< size {
		b := u8(v >> (8 * uint(i)))
		strings.write_byte(sb, HEX[b >> 4])
		strings.write_byte(sb, HEX[b & 15])
	}
}

read_le :: proc(str: string) -> (v: u64, ok: bool) {
	if len(str) == 0 || len(str) > 16 || len(str) % 2 != 0 {
		return 0, false
	}
	for i := 0; i < len(str); i += 2 {
		hi := hex_digit(str[i]) or_return
		lo := hex_digit(str[i + 1]) or_return
		v |= u64(hi << 4 | lo) << (4 * uint(i))
	}
	return v, true
}
