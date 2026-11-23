package gdbstub_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "../../src/abi"
import "../../src/gdbstub"
import "../../src/host"
import "../../src/vm"

FIXTURES :: #config(FIXTURES, "build/tests")

// A page under a session, as nbrun --gdb sets it up.
Rig :: struct {
	page: host.Page,
	s:    gdbstub.Session,
}

open :: proc(t: ^testing.T, r: ^Rig, name: string, budget := max(u64), wait_proc: gdbstub.Wait_Proc = nil) -> bool {
	path := fmt.tprintf("%s/%s.elf", FIXTURES, name)
	data, err := os.read_entire_file(path, context.allocator)
	if !testing.expectf(t, err == nil, "cannot read %s (run ./build.sh fixtures): %v", path, err) {
		return false
	}
	defer delete(data)
	if lerr := host.page_init(&r.page, data); !testing.expectf(t, lerr == nil, "cannot load %s: %v", path, lerr) {
		return false
	}
	gdbstub.session_init(&r.s, &r.page, budget, wait_proc)
	return true
}

close :: proc(r: ^Rig) {
	gdbstub.session_destroy(&r.s)
	host.page_destroy(&r.page)
}

// Takes the packets the stub sent, checking each checksum. Acks are dropped.
take :: proc(t: ^testing.T, s: ^gdbstub.Session, loc := #caller_location) -> []string {
	out := string(s.out[:])
	packets := make([dynamic]string, context.temp_allocator)
	for len(out) > 0 {
		if out[0] == '+' || out[0] == '-' {
			out = out[1:]
			continue
		}
		end := strings.index_byte(out, '#')
		if !testing.expectf(t, out[0] == '$' && end > 0 && end + 3 <= len(out), "bad output %q", out, loc = loc) {
			break
		}
		body := out[1:end]
		sum: u8
		for i in 0 ..< len(body) {
			sum += body[i]
		}
		testing.expectf(t, fmt.tprintf("%02x", sum) == out[end + 1:][:2], "bad checksum in %q", out[:end + 3], loc = loc)
		append(&packets, strings.clone(body, context.temp_allocator))
		out = out[end + 3:]
	}
	clear(&s.out)
	return packets[:]
}

// Sends one packet and returns the single reply.
ask :: proc(t: ^testing.T, s: ^gdbstub.Session, payload: string, loc := #caller_location) -> string {
	buf := make([dynamic]u8, context.temp_allocator)
	gdbstub.encode_packet(&buf, payload)
	gdbstub.session_feed(s, buf[:])
	replies := take(t, s, loc)
	if !testing.expectf(t, len(replies) == 1, "%q: got %d replies %v", payload, len(replies), replies, loc = loc) {
		return ""
	}
	return replies[0]
}

// Sends c or s and runs the page until the stub reports a stop.
resume :: proc(t: ^testing.T, s: ^gdbstub.Session, cmd: string, loc := #caller_location) -> string {
	buf := make([dynamic]u8, context.temp_allocator)
	gdbstub.encode_packet(&buf, cmd)
	gdbstub.session_feed(s, buf[:])
	for i := 0; i < 1000 && gdbstub.session_running(s); i += 1 {
		gdbstub.session_run(s, 10_000)
	}
	replies := take(t, s, loc)
	if !testing.expectf(t, len(replies) == 1, "%q: got replies %v", cmd, replies, loc = loc) {
		return ""
	}
	return replies[0]
}

reg :: proc(t: ^testing.T, s: ^gdbstub.Session, n: int, loc := #caller_location) -> u64 {
	v, ok := gdbstub.read_le(ask(t, s, fmt.tprintf("p%x", n), loc))
	testing.expect(t, ok, "bad register reply", loc = loc)
	return v
}

@(test)
test_decoder :: proc(t: ^testing.T) {
	d: gdbstub.Decoder
	defer gdbstub.decoder_destroy(&d)
	feed :: proc(d: ^gdbstub.Decoder, bytes: string) -> (last: gdbstub.Input) {
		for i in 0 ..< len(bytes) {
			if r := gdbstub.decode_byte(d, bytes[i]); r != .None {
				last = r
			}
		}
		return
	}
	// Noise before '$' is ignored; the checksum is the byte sum mod 256.
	testing.expect_value(t, feed(&d, "junk$m10,4#2e"), gdbstub.Input.Packet)
	testing.expect_value(t, string(d.body[:]), "m10,4")
	testing.expect_value(t, feed(&d, "$m10,4#2f"), gdbstub.Input.Bad)
	testing.expect_value(t, feed(&d, "$g#zz"), gdbstub.Input.Bad)
	// A '$' inside a packet starts it over: the cut-off one never completes.
	testing.expect_value(t, feed(&d, "$m1$g#67"), gdbstub.Input.Packet)
	testing.expect_value(t, string(d.body[:]), "g")
	testing.expect_value(t, feed(&d, "\x03"), gdbstub.Input.Interrupt)
	testing.expect_value(t, feed(&d, "-"), gdbstub.Input.Nak)
}

@(test)
test_encode_escapes :: proc(t: ^testing.T) {
	out: [dynamic]u8
	defer delete(out)
	gdbstub.encode_packet(&out, "a}#*$")
	// Each special byte becomes '}' and the byte xor 0x20; the checksum
	// covers the bytes as sent.
	sent := "a}]}\x03}\x0a}\x04"
	sum: u8
	for i in 0 ..< len(sent) {
		sum += sent[i]
	}
	testing.expect_value(t, string(out[:]), fmt.tprintf("$%s#%02x", sent, sum))
}

@(test)
test_acks_and_no_ack :: proc(t: ^testing.T) {
	r: Rig
	if !open(t, &r, "gdb.c") {
		return
	}
	defer close(&r)
	s := &r.s

	gdbstub.session_feed(s, transmute([]u8)string("$?#3f"))
	testing.expect_value(t, string(s.out[:]), "+$T05#b9") // ack, then the initial stop
	clear(&s.out)

	gdbstub.session_feed(s, transmute([]u8)string("$?#00"))
	testing.expect_value(t, string(s.out[:]), "-") // bad checksum: ask again
	clear(&s.out)
	gdbstub.session_feed(s, transmute([]u8)string("-"))
	testing.expect_value(t, string(s.out[:]), "$T05#b9") // resend the last packet
	clear(&s.out)

	features := ask(t, s, "qSupported:multiprocess+;swbreak+;hwbreak+")
	testing.expect(t, strings.contains(features, "PacketSize=4000"), features)
	testing.expect(t, strings.contains(features, "qXfer:features:read+"), features)
	testing.expect(t, strings.contains(features, "QStartNoAckMode+"), features)
	testing.expect(t, s.swbreak && s.hwbreak)

	gdbstub.session_feed(s, transmute([]u8)string("$QStartNoAckMode#b0"))
	testing.expect_value(t, string(s.out[:]), "+$OK#9a") // the switch itself is still acked
	clear(&s.out)
	gdbstub.session_feed(s, transmute([]u8)string("$?#3f"))
	testing.expect_value(t, string(s.out[:]), "$T05#b9")
	clear(&s.out)
}

@(test)
test_queries :: proc(t: ^testing.T) {
	r: Rig
	if !open(t, &r, "gdb.c") {
		return
	}
	defer close(&r)
	s := &r.s
	testing.expect_value(t, ask(t, s, "vMustReplyEmpty"), "")
	testing.expect_value(t, ask(t, s, "vCont?"), "") // GDB falls back to c and s
	testing.expect_value(t, ask(t, s, "qC"), "QC1")
	testing.expect_value(t, ask(t, s, "qAttached"), "0")
	testing.expect_value(t, ask(t, s, "Hg0"), "OK")
	testing.expect_value(t, ask(t, s, "Hc-1"), "OK")
	testing.expect_value(t, ask(t, s, "qfThreadInfo"), "m1")
	testing.expect_value(t, ask(t, s, "qsThreadInfo"), "l")
	testing.expect_value(t, ask(t, s, "Z2,10000,4"), "") // watchpoints are unsupported
	testing.expect_value(t, ask(t, s, "qTStatus"), "")
	testing.expect_value(t, ask(t, s, "X10000,0:"), "") // GDB then writes with M
}

@(test)
test_target_xml :: proc(t: ^testing.T) {
	r: Rig
	if !open(t, &r, "gdb.c") {
		return
	}
	defer close(&r)
	s := &r.s

	// Read it in small pieces, as GDB does when PacketSize is small.
	sb := strings.builder_make(context.temp_allocator)
	for off := 0; ; off += 0x100 {
		chunk := ask(t, s, fmt.tprintf("qXfer:features:read:target.xml:%x,100", off))
		if !testing.expect(t, len(chunk) > 0 && (chunk[0] == 'm' || chunk[0] == 'l'), chunk) {
			return
		}
		strings.write_string(&sb, chunk[1:])
		if chunk[0] == 'l' {
			break
		}
	}
	xml := strings.to_string(sb)
	testing.expect_value(t, xml, s.xml)
	for want in ([]string{
		"<architecture>riscv:rv64</architecture>",
		`name="org.gnu.gdb.riscv.cpu"`,
		`name="org.gnu.gdb.riscv.fpu"`,
		`<reg name="zero" bitsize="64" type="int" regnum="0"/>`,
		`<reg name="t6" bitsize="64" type="int" regnum="31"/>`,
		`<reg name="pc" bitsize="64" type="code_ptr" regnum="32"/>`,
		`<reg name="ft0" bitsize="64" type="riscv_double" regnum="33"/>`,
		`<reg name="ft11" bitsize="64" type="riscv_double" regnum="64"/>`,
		`<reg name="fflags" bitsize="32" type="int" regnum="66"/>`,
		`<reg name="frm" bitsize="32" type="int" regnum="67"/>`,
		`<reg name="fcsr" bitsize="32" type="int" regnum="68"/>`,
	}) {
		testing.expectf(t, strings.contains(xml, want), "target.xml lacks %s", want)
	}
	testing.expect_value(t, ask(t, s, fmt.tprintf("qXfer:features:read:target.xml:%x,100", len(xml))), "l")
	testing.expect_value(t, ask(t, s, "qXfer:features:read:other.xml:0,100"), "E00")
}

@(test)
test_registers :: proc(t: ^testing.T) {
	r: Rig
	if !open(t, &r, "gdb.c") {
		return
	}
	defer close(&r)
	s := &r.s
	cpu := &r.page.cpu

	// x0..x31 and pc are 8 bytes, f0..f31 8, fflags/frm/fcsr 4, in that order.
	g := ask(t, s, "g")
	testing.expect_value(t, len(g), 2 * (33 * 8 + 32 * 8 + 3 * 4))
	pc, _ := gdbstub.read_le(g[32 * 16:][:16])
	testing.expect_value(t, pc, cpu.pc)
	sp, _ := gdbstub.read_le(g[2 * 16:][:16])
	testing.expect_value(t, sp, cpu.x[vm.REG_SP])

	testing.expect_value(t, ask(t, s, "P0=0100000000000000"), "OK")
	testing.expect_value(t, cpu.x[0], 0) // x0 stays zero
	testing.expect_value(t, ask(t, s, "Pa=2a00000000000000"), "OK")
	testing.expect_value(t, cpu.x[vm.REG_A0], 42)
	testing.expect_value(t, ask(t, s, "P21=0000000000000840"), "OK") // f0 = 3.0
	testing.expect_value(t, cpu.f[0], 0x4008_0000_0000_0000)
	testing.expect_value(t, ask(t, s, "P21=000000000000f83f"), "OK") // what GDB sends for $ft0 = 1.5
	testing.expect_value(t, cpu.f[0], 0x3ff8_0000_0000_0000)

	// fflags (66), frm (67) and fcsr (68) are views of one CSR.
	testing.expect_value(t, ask(t, s, "P42=15000000"), "OK")
	testing.expect_value(t, ask(t, s, "P43=03000000"), "OK")
	testing.expect_value(t, cpu.fcsr, 0x75)
	testing.expect_value(t, reg(t, s, 68), 0x75)
	testing.expect_value(t, reg(t, s, 66), 0x15)
	testing.expect_value(t, reg(t, s, 67), 3)
	testing.expect_value(t, ask(t, s, "p41"), "E01") // 65 is not described
	testing.expect_value(t, ask(t, s, "P42=15"), "E01") // wrong size

	// G writes back what g read, so a round trip changes nothing.
	before := cpu^
	g = ask(t, s, "g")
	testing.expect_value(t, ask(t, s, strings.concatenate({"G", g}, context.temp_allocator)), "OK")
	testing.expect(t, cpu.x == before.x && cpu.f == before.f && cpu.pc == before.pc && cpu.fcsr == before.fcsr)
	testing.expect_value(t, ask(t, s, "G00"), "E01")
}

// The ebreak stops with pc on it; continuing skips it, whichever length it is.
@(test)
test_ebreak :: proc(t: ^testing.T) {
	for variant in ([]string{"c", "nc"}) {
		r: Rig
		if !open(t, &r, fmt.tprintf("gdb.%s", variant)) {
			return
		}
		defer close(&r)
		s := &r.s

		testing.expect_value(t, resume(t, s, "c"), "T05")
		testing.expect_value(t, r.page.state, host.Page_State.Break)
		pc := r.page.cpu.pc
		want := "0290" if variant == "c" else "73001000"
		testing.expect_value(t, ask(t, s, fmt.tprintf("m%x,%x", pc, len(want) / 2)), want)

		testing.expect_value(t, resume(t, s, "c"), "W07")
		testing.expect_value(t, s.mode, gdbstub.Mode.Ended)
		testing.expect_value(t, ask(t, s, "?"), "W07")
	}
}

@(test)
test_step :: proc(t: ^testing.T) {
	for variant in ([]string{"c", "nc"}) {
		r: Rig
		if !open(t, &r, fmt.tprintf("gdb.%s", variant)) {
			return
		}
		defer close(&r)
		s := &r.s
		cpu := &r.page.cpu

		entry := cpu.pc
		testing.expect_value(t, resume(t, s, "s"), "T05")
		testing.expect(t, cpu.pc == entry + 4 || cpu.pc == entry + 8, "la is auipc+addi: one of them ran")
		testing.expect_value(t, resume(t, s, "c"), "T05")
		ebreak := cpu.pc
		size: u64 = 2 if variant == "c" else 4
		// Stepping from the ebreak steps over it, not onto it again.
		testing.expect_value(t, resume(t, s, "s"), "T05")
		testing.expect_value(t, cpu.pc, ebreak + size)
		testing.expect_value(t, r.page.state, host.Page_State.Running)
		testing.expect_value(t, resume(t, s, "s"), "T05") // the add
		testing.expect_value(t, cpu.x[vm.REG_A0], 3)
		testing.expect_value(t, cpu.pc, cpu.x[vm.REG_A2])
	}
}

@(test)
test_breakpoints :: proc(t: ^testing.T) {
	for variant in ([]string{"c", "nc"}) {
		r: Rig
		if !open(t, &r, fmt.tprintf("gdb.%s", variant)) {
			return
		}
		defer close(&r)
		s := &r.s
		cpu := &r.page.cpu

		ask(t, s, "qSupported:swbreak+;hwbreak+")
		testing.expect_value(t, resume(t, s, "c"), "T05") // the ebreak: a2 is set now
		target := cpu.x[vm.REG_A2]
		code := strings.clone(ask(t, s, fmt.tprintf("m%x,4", target)), context.temp_allocator)

		testing.expect_value(t, ask(t, s, fmt.tprintf("Z0,%x,2", target)), "OK")
		testing.expect_value(t, resume(t, s, "c"), "T05swbreak:;")
		testing.expect_value(t, cpu.pc, target)
		testing.expect_value(t, cpu.x[vm.REG_A0], 3) // the add before it ran, the addi did not
		// The breakpoint lives in the stub; guest code is untouched.
		testing.expect_value(t, ask(t, s, fmt.tprintf("m%x,4", target)), code)

		// Continuing from a breakpoint runs the instruction under it.
		testing.expect_value(t, resume(t, s, "c"), "W07")
	}

	// Z1 reports hwbreak; z0/z1 remove.
	r: Rig
	if !open(t, &r, "gdb.c") {
		return
	}
	defer close(&r)
	s := &r.s
	ask(t, s, "qSupported:swbreak+;hwbreak+")
	resume(t, s, "c")
	target := r.page.cpu.x[vm.REG_A2]
	testing.expect_value(t, ask(t, s, fmt.tprintf("Z1,%x,2", target)), "OK")
	testing.expect_value(t, resume(t, s, "c"), "T05hwbreak:;")
	testing.expect_value(t, ask(t, s, fmt.tprintf("z1,%x,2", target)), "OK")
	testing.expect_value(t, len(s.breakpoints), 0)
	testing.expect_value(t, resume(t, s, "c"), "W07")
}

// M goes through the page's permissions: code and unmapped memory refuse it.
@(test)
test_memory :: proc(t: ^testing.T) {
	r: Rig
	if !open(t, &r, "gdb.nc") {
		return
	}
	defer close(&r)
	s := &r.s
	cpu := &r.page.cpu

	testing.expect_value(t, resume(t, s, "c"), "T05")
	pc := cpu.pc
	testing.expect_value(t, ask(t, s, fmt.tprintf("M%x,4:13000000", pc)), "E01") // W^X
	testing.expect_value(t, ask(t, s, fmt.tprintf("m%x,4", pc)), "73001000")
	testing.expect_value(t, ask(t, s, "m0,4"), "E01")      // the null guard
	testing.expect_value(t, ask(t, s, "M0,1:00"), "E01")
	testing.expect_value(t, ask(t, s, "m10,zz"), "E01")
	// A read running into unmapped memory comes back short.
	top := vm.memory_size(&cpu.mem)
	testing.expect_value(t, len(ask(t, s, fmt.tprintf("m%x,8", top - 2))), 4)

	value := cpu.x[vm.REG_A3]
	testing.expect_value(t, ask(t, s, fmt.tprintf("M%x,8:0500000000000000", value)), "OK")
	testing.expect_value(t, ask(t, s, fmt.tprintf("m%x,8", value)), "0500000000000000")
	testing.expect_value(t, ask(t, s, fmt.tprintf("M%x,8:05", value)), "E01") // short data
	testing.expect_value(t, ask(t, s, fmt.tprintf("M%x,1:zz", value)), "E01")
	testing.expect_value(t, resume(t, s, "c"), "W0c") // 7 + 5
}

@(test)
test_interrupt :: proc(t: ^testing.T) {
	r: Rig
	if !open(t, &r, "loop.c") {
		return
	}
	defer close(&r)
	s := &r.s

	gdbstub.session_feed(s, transmute([]u8)string("$c#63"))
	for _ in 0 ..< 5 {
		gdbstub.session_run(s, 10_000)
	}
	testing.expect(t, gdbstub.session_running(s))
	testing.expect_value(t, r.page.cpu.instret, 50_000)
	clear(&s.out)
	gdbstub.session_feed(s, {0x03})
	testing.expect_value(t, take(t, s)[0], "T02")
	testing.expect(t, !gdbstub.session_running(s))

	gdbstub.session_feed(s, transmute([]u8)string("$k#6b"))
	testing.expect_value(t, s.done, gdbstub.Done.Killed)
	testing.expect_value(t, r.page.state, host.Page_State.Killed)
}

@(test)
test_faults :: proc(t: ^testing.T) {
	cases := [?]struct {
		name: string,
		stop: string,
	}{{"fault_null.c", "T0b"}, {"fault_text_write.c", "T0b"}, {"fault_illegal.c", "T04"}}
	for c in cases {
		r: Rig
		if !open(t, &r, c.name) {
			return
		}
		defer close(&r)
		s := &r.s
		testing.expect_value(t, resume(t, s, "c"), c.stop)
		testing.expect_value(t, r.page.cpu.pc, r.page.cpu.fault.pc) // GDB sees the faulting instruction
		// A fault cannot be resumed: the page ends with the signal.
		testing.expect_value(t, resume(t, s, "c"), fmt.tprintf("X%s", c.stop[1:]))
	}
}

@(test)
test_budget :: proc(t: ^testing.T) {
	r: Rig
	if !open(t, &r, "loop.c", budget = 5000) {
		return
	}
	defer close(&r)
	testing.expect_value(t, resume(t, &r.s, "c"), "X09")
	testing.expect_value(t, r.page.state, host.Page_State.Killed)
	testing.expect_value(t, r.page.cpu.instret, 5000)
}

// Syscalls keep working under the debugger, and waits go to wait_proc.
@(test)
test_waiting :: proc(t: ^testing.T) {
	// The timed wait is skipped ahead; the unbounded one gets the click the
	// waiter fixture expects, once.
	wake :: proc(p: ^host.Page) -> bool {
		if host.page_skip_to_deadline(p) {
			return true
		}
		if sent := (^bool)(p.user_data); !sent^ {
			host.page_push_event(p, abi.Event{kind = .Click, a = 42})
			sent^ = true
			return true
		}
		return false
	}
	{
		r: Rig
		if !open(t, &r, "waiter.c", wait_proc = wake) {
			return
		}
		defer close(&r)
		sent := false
		r.page.user_data = &sent
		testing.expect_value(t, resume(t, &r.s, "c"), fmt.tprintf("W%02x", int(abi.Event_Kind.Click)))
	}
	{
		r: Rig
		if !open(t, &r, "waiter.c") {
			return
		}
		defer close(&r)
		testing.expect_value(t, resume(t, &r.s, "c"), "X09") // nothing can wake it
	}
}

@(test)
test_detach :: proc(t: ^testing.T) {
	r: Rig
	if !open(t, &r, "gdb.c") {
		return
	}
	defer close(&r)
	s := &r.s
	testing.expect_value(t, resume(t, s, "c"), "T05")
	testing.expect_value(t, ask(t, s, "D"), "OK")
	testing.expect_value(t, s.done, gdbstub.Done.Detached)
	testing.expect(t, !r.page.debugger)
	// The page carries on past the ebreak without the debugger.
	testing.expect_value(t, host.page_run(&r.page, 1000), host.Page_State.Exited)
	testing.expect_value(t, r.page.exit_code, 7)
}

// Skipping the ebreak counts as the first instruction of the resume, so a
// breakpoint right after it still fires.
@(test)
test_breakpoint_after_ebreak :: proc(t: ^testing.T) {
	for variant in ([]string{"c", "nc"}) {
		r: Rig
		if !open(t, &r, fmt.tprintf("gdb.%s", variant)) {
			return
		}
		defer close(&r)
		s := &r.s
		cpu := &r.page.cpu
		ask(t, s, "qSupported:swbreak+")
		testing.expect_value(t, resume(t, s, "c"), "T05")
		next := cpu.pc + (2 if variant == "c" else 4)
		testing.expect_value(t, ask(t, s, fmt.tprintf("Z0,%x,2", next)), "OK")
		testing.expect_value(t, resume(t, s, "c"), "T05swbreak:;")
		testing.expect_value(t, cpu.pc, next)
		testing.expect_value(t, cpu.x[vm.REG_A0], 1) // the add has not run
	}
}
