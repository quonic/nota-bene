package proto_test

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "../../src/proto"
import "../../src/server"

// A resolver that never leaves the process: TXT answers come from `records`
// and every host dials loopback.
Fake_DNS :: struct {
	records: map[string][]string, // written before the pool is used
	fail:    bool,                // every TXT lookup fails, like a timeout
	delay:   time.Duration,
	lookups: int,                 // atomic
}

fake_resolver :: proc(f: ^Fake_DNS) -> proto.Resolver {
	return {
		data = f,
		txt = proc(data: rawptr, name: string, allocator: runtime.Allocator) -> ([]string, bool) {
			f := (^Fake_DNS)(data)
			sync.atomic_add(&f.lookups, 1)
			if f.delay > 0 {
				time.sleep(f.delay)
			}
			if f.fail {
				return nil, false
			}
			return f.records[name], true
		},
		address = proc(data: rawptr, host: string) -> (net.Address, bool) {
			return net.IP4_Loopback, true
		},
	}
}

@(private)
test_key :: proc(seed: u8) -> (k: proto.Key) {
	for i in 0 ..< len(k) {
		k[i] = seed + u8(i) * 3
	}
	return
}

@(private)
txt_for :: proc(k: proto.Key) -> string {
	return proto.dns_txt_value(k, context.temp_allocator)
}

@(test)
test_dns_txt_key :: proc(t: ^testing.T) {
	k, other := test_key(1), test_key(2)
	ks := proto.key_string(k, context.temp_allocator)
	ots := proto.key_string(other, context.temp_allocator)

	testing.expect_value(t, txt_for(k), fmt.tprintf("v=nb1; key=%s", ks))
	valid := []string{
		txt_for(k),
		fmt.tprintf("  v = nb1 ;key= %s ;  ", ks),
		fmt.tprintf("V=NB1;KEY=%s", strings.to_upper(ks, context.temp_allocator)),
		fmt.tprintf("v=nb1; note=hello world; key=%s; future=1", ks),
	}
	for v in valid {
		got, ok := proto.dns_txt_key(v)
		testing.expectf(t, ok && got == k, "%q should give the key", v)
	}
	invalid := []string{
		"",
		fmt.tprintf("key=%s", ks),             // no version
		fmt.tprintf("v=nb2; key=%s", ks),      // another version
		fmt.tprintf("key=%s; v=nb1", ks),      // the version must come first
		"v=nb1",                               // no key
		"v=nb1; key=",
		"v=nb1; key=tooshort",
		fmt.tprintf("v=nb1; key=%s1", ks[:51]), // '1' is not base32
		fmt.tprintf("v=nb1; key=%s; key=%s", ks, ots), // ambiguous
		fmt.tprintf("v=nb1; junk; key=%s", ks), // a field without '='
		"v=spf1 include:example.org ~all",
	}
	for v in invalid {
		_, ok := proto.dns_txt_key(v)
		testing.expectf(t, !ok, "%q should be ignored", v)
	}
}

// Several records: duplicates collapse, other records are skipped, and the
// set is capped.
@(test)
test_dns_txt_keys :: proc(t: ^testing.T) {
	k1, k2 := test_key(1), test_key(2)
	keys := proto.dns_txt_keys({txt_for(k1), "v=spf1 -all", txt_for(k1), fmt.tprintf("v=nb2; key=%s", proto.key_string(test_key(3), context.temp_allocator)), txt_for(k2)})
	testing.expect_value(t, keys.count, 2)
	testing.expect(t, keys.keys[0] == k1 && keys.keys[1] == k2)

	many: [dynamic]string
	many.allocator = context.temp_allocator
	for i in 0 ..< proto.MAX_DNS_KEYS + 2 {
		append(&many, txt_for(test_key(u8(10 + i))))
	}
	testing.expect_value(t, proto.dns_txt_keys(many[:]).count, proto.MAX_DNS_KEYS)
}

// TXT wire data is a run of length-prefixed strings.
@(test)
test_txt_rdata :: proc(t: ^testing.T) {
	Case :: struct {
		rdata, want: string,
		ok:          bool,
	}
	for c in ([]Case{{"\x05hello", "hello", true}, {"\x03v=n\x02b1", "v=nb1", true}, {"", "", true}, {"\x05abc", "", false}}) {
		got, ok := proto.txt_rdata_text(c.rdata, context.temp_allocator)
		testing.expectf(t, ok == c.ok && got == c.want, "%q: got %q %v", c.rdata, got, ok)
	}
}

@(test)
test_dns_names :: proc(t: ^testing.T) {
	testing.expect_value(t, proto.dns_record_name("Example.ORG.", proto.DEFAULT_PORT, context.temp_allocator), "_nb.example.org")
	testing.expect_value(t, proto.dns_record_name("example.org", 9000, context.temp_allocator), "_9000._nb.example.org")
	for host in ([]string{"example.org", "a-b.example.", "x_y.test", "local.example"}) {
		testing.expectf(t, proto.dns_lookup_allowed(host), "%q should be looked up", host)
	}
	for host in ([]string{"127.0.0.1", "::1", "localhost", "LocalHost.", "app.localhost", "printer.local", "Box.Local.", "intranet", "intranet.", "a..b", "ex!ample.org", ""}) {
		testing.expectf(t, !proto.dns_lookup_allowed(host), "%q should not be looked up", host)
	}
}

// A key in the address beats a pinned one; DNS is only for neither.
@(test)
test_pinned_key :: proc(t: ^testing.T) {
	k1, k2 := test_key(1), test_key(2)
	kh: proto.Known_Hosts
	kh.entries = make(map[string]proto.Key)
	defer proto.known_hosts_destroy(&kh)
	proto.known_hosts_set(&kh, "site.test:4040", k2)

	u, _ := proto.parse_url(fmt.tprintf("nb://%s@site.test/", proto.key_string(k1, context.temp_allocator)))
	key, src := proto.pinned_key(u, &kh)
	testing.expect(t, src == .URL && key.? == k1, "the address's key wins")
	u, _ = proto.parse_url("nb://site.test/")
	key, src = proto.pinned_key(u, &kh)
	testing.expect(t, src == .Known_Hosts && key.? == k2)
	u, _ = proto.parse_url("nb://other.test/")
	key, src = proto.pinned_key(u, &kh)
	testing.expect(t, src == .None && key == nil)
}

// Lookups are cached per pool, misses and failures included, and never made
// for IP literals or localhost.
@(test)
test_dns_cache :: proc(t: ^testing.T) {
	k := test_key(1)
	f: Fake_DNS
	f.records = make(map[string][]string, context.temp_allocator)
	f.records["_nb.site.test"] = {txt_for(k)}
	pool := proto.pool_create(fake_resolver(&f))
	defer proto.pool_close(pool)
	url :: proc(s: string) -> proto.URL {
		u, _ := proto.parse_url(s)
		return u
	}

	for _ in 0 ..< 2 {
		keys, answer := proto.dns_keys(pool, url("nb://site.test/"))
		testing.expect(t, answer == .Keys && keys.count == 1 && keys.keys[0] == k)
	}
	testing.expect_value(t, sync.atomic_load(&f.lookups), 1)
	testing.expect_value(t, proto.pool_dns_lookups(pool), 1)

	// Another port is another record, absent here; the miss is remembered.
	for _ in 0 ..< 2 {
		_, answer := proto.dns_keys(pool, url("nb://site.test:9000/"))
		testing.expect_value(t, answer, proto.DNS_Answer.No_Record)
	}
	testing.expect_value(t, sync.atomic_load(&f.lookups), 2)

	for s in ([]string{"nb://127.0.0.1/", "nb://[::1]/", "nb://localhost:4041/", "nb://app.localhost/", "nb://printer.local/", "nb://intranet/"}) {
		_, answer := proto.dns_keys(pool, url(s))
		testing.expectf(t, answer == .Not_Asked, "%s: %v", s, answer)
	}
	testing.expect_value(t, sync.atomic_load(&f.lookups), 2)

	// No resolver, no pool: no DNS.
	plain := proto.pool_create()
	defer proto.pool_close(plain)
	_, plain_answer := proto.dns_keys(plain, url("nb://site.test/"))
	testing.expect_value(t, plain_answer, proto.DNS_Answer.Not_Asked)
	_, nil_answer := proto.dns_keys(nil, url("nb://site.test/"))
	testing.expect_value(t, nil_answer, proto.DNS_Answer.Not_Asked)

	// A failed lookup is told apart from "no record", and not retried at once.
	down: Fake_DNS
	down.fail = true
	dpool := proto.pool_create(fake_resolver(&down))
	defer proto.pool_close(dpool)
	for _ in 0 ..< 2 {
		_, answer := proto.dns_keys(dpool, url("nb://site.test/"))
		testing.expect_value(t, answer, proto.DNS_Answer.Failed)
	}
	testing.expect_value(t, sync.atomic_load(&down.lookups), 1)
}

// Fetches that start together share one lookup.
@(test)
test_dns_concurrent :: proc(t: ^testing.T) {
	f: Fake_DNS
	f.records = make(map[string][]string, context.temp_allocator)
	f.records["_nb.site.test"] = {txt_for(test_key(1))}
	f.delay = 50 * time.Millisecond
	pool := proto.pool_create(fake_resolver(&f))
	defer proto.pool_close(pool)
	Worker :: struct {
		pool:  ^proto.Pool,
		count: int,
	}
	workers: [4]Worker
	threads: [4]^thread.Thread
	for &w, i in workers {
		w.pool = pool
		threads[i] = thread.create_and_start_with_poly_data(&w, proc(w: ^Worker) {
			u, _ := proto.parse_url("nb://site.test/")
			keys, _ := proto.dns_keys(w.pool, u)
			w.count = keys.count
		})
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	for w in workers {
		testing.expect_value(t, w.count, 1)
	}
	testing.expect_value(t, sync.atomic_load(&f.lookups), 1)
}

// End to end against a real server, with names the fake resolver answers.
@(test)
test_dns_fetch :: proc(t: ^testing.T) {
	srv: server.Server
	th, started := start_server(t, &srv, BUILD_DIR)
	if !started {
		return
	}
	defer stop_server(&srv, th)
	pub := proto.public_key_of(&srv.cfg.static_key)
	wrong, wrong2 := pub, pub
	wrong[0] ~= 0x40
	wrong2[1] ~= 0x40
	port := u16(srv.endpoint.port)

	f: Fake_DNS
	f.records = make(map[string][]string, context.temp_allocator)
	record :: proc(f: ^Fake_DNS, host: string, port: u16, values: ..string) {
		// The variadic slice lives on the caller's stack: keep a copy.
		f.records[proto.dns_record_name(host, port, context.temp_allocator)] = slice.clone(values, context.temp_allocator)
	}
	record(&f, "good.test", port, txt_for(pub))
	record(&f, "wrong.test", port, txt_for(wrong))
	record(&f, "rotating.test", port, txt_for(wrong), txt_for(pub))
	record(&f, "stale.test", port, txt_for(wrong), txt_for(wrong2))
	record(&f, "pinned.test", port, txt_for(wrong))
	pool := proto.pool_create(fake_resolver(&f))
	defer proto.pool_close(pool)
	url :: proc(host: string, port: u16, path := "/hello") -> proto.URL {
		u, _ := proto.parse_url(fmt.tprintf("nb://%s:%d%s", host, port, path))
		return u
	}

	// The key from DNS: NK succeeds.
	r := proto.fetch(url("good.test", port), nil, nil, pool)
	testing.expectf(t, r.err == nil, "good: %s %s", proto.error_text(r.err), r.detail)
	testing.expect(t, r.dns == .Keys && r.server_key == pub)
	proto.fetch_result_destroy(&r)
	rd := proto.read(url("good.test", port, "/hello.elf"), nil, 1 << 20, pool)
	testing.expect(t, rd.err == nil && rd.status == proto.STATUS_OK && rd.dns == .Keys)
	proto.read_result_destroy(&rd)

	// A key the server does not hold: refused, with no request sent and no
	// second, unauthenticated attempt.
	requests, dials := sync.atomic_load(&srv.requests), proto.pool_dials(pool)
	r = proto.fetch(url("wrong.test", port), nil, nil, pool)
	testing.expect_value(t, r.err, proto.Error.Handshake)
	testing.expect_value(t, r.dns, proto.DNS_Answer.Keys)
	proto.fetch_result_destroy(&r)
	rd = proto.read(url("wrong.test", port, "/hello.elf"), nil, 1 << 20, pool)
	testing.expect(t, rd.err == .Handshake && rd.dns == .Keys)
	proto.read_result_destroy(&rd)
	testing.expect_value(t, sync.atomic_load(&srv.requests), requests)
	testing.expect_value(t, proto.pool_dials(pool), dials + 2)

	// Several keys (a rotation): the server must prove one of them.
	r = proto.fetch(url("rotating.test", port), nil, nil, pool)
	testing.expectf(t, r.err == nil && r.dns == .Keys && r.server_key == pub, "rotating: %v", r.err)
	proto.fetch_result_destroy(&r)
	requests = sync.atomic_load(&srv.requests)
	r = proto.fetch(url("stale.test", port), nil, nil, pool)
	testing.expect_value(t, r.err, proto.Error.Key_Mismatch)
	testing.expect_value(t, r.dns, proto.DNS_Answer.Keys)
	proto.fetch_result_destroy(&r)
	testing.expect_value(t, sync.atomic_load(&srv.requests), requests)

	// A pinned key wins, and DNS is not asked.
	lookups := sync.atomic_load(&f.lookups)
	r = proto.fetch(url("pinned.test", port), pub, nil, pool)
	testing.expectf(t, r.err == nil && r.dns == .Not_Asked, "pinned: %v", r.err)
	proto.fetch_result_destroy(&r)
	testing.expect_value(t, sync.atomic_load(&f.lookups), lookups)

	// No record: trust on first use, as before.
	r = proto.fetch(url("none.test", port), nil, nil, pool)
	testing.expectf(t, r.err == nil && r.dns == .No_Record && r.server_key == pub, "none: %v", r.err)
	proto.fetch_result_destroy(&r)

	// A failed lookup: the page loads, and the caller learns not to pin.
	down: Fake_DNS
	down.fail = true
	dpool := proto.pool_create(fake_resolver(&down))
	defer proto.pool_close(dpool)
	r = proto.fetch(url("good.test", port), nil, nil, dpool)
	testing.expectf(t, r.err == nil && r.dns == .Failed && r.server_key == pub, "down: %v", r.err)
	proto.fetch_result_destroy(&r)
	testing.expect_value(t, sync.atomic_load(&down.lookups), 1)
}

// The cache stays bounded however many names a page fetches from.
@(test)
test_dns_cache_cap :: proc(t: ^testing.T) {
	f: Fake_DNS
	pool := proto.pool_create(fake_resolver(&f))
	defer proto.pool_close(pool)
	for i in 0 ..< proto.DNS_CACHE_MAX + 10 {
		u, _ := proto.parse_url(fmt.tprintf("nb://host%d.test/", i))
		proto.dns_keys(pool, u)
	}
	testing.expect_value(t, proto.pool_dns_cached(pool), proto.DNS_CACHE_MAX)
	// A name that did not fit is looked up again; one that did is not.
	lookups := sync.atomic_load(&f.lookups)
	late, _ := proto.parse_url(fmt.tprintf("nb://host%d.test/", proto.DNS_CACHE_MAX + 5))
	early, _ := proto.parse_url("nb://host0.test/")
	proto.dns_keys(pool, late)
	proto.dns_keys(pool, early)
	testing.expect_value(t, sync.atomic_load(&f.lookups), lookups + 1)
}

@(test)
test_resolv_conf_options :: proc(t: ^testing.T) {
	timeout, attempts := proto.resolv_conf_options("nameserver 10.0.0.1\n")
	testing.expect(t, timeout == proto.DNS_TIMEOUT && attempts == proto.DNS_ATTEMPTS)
	timeout, attempts = proto.resolv_conf_options("nameserver 10.0.0.1\noptions edns0 timeout:2 attempts:3\n")
	testing.expect(t, timeout == 2 * time.Second && attempts == 3)
	timeout, attempts = proto.resolv_conf_options("options timeout:30 attempts:9\n")
	testing.expect(t, timeout == proto.DNS_MAX_TIMEOUT && attempts == proto.DNS_MAX_ATTEMPTS, "capped")
	timeout, attempts = proto.resolv_conf_options("options timeout:0 attempts:x\n")
	testing.expect(t, timeout == proto.DNS_TIMEOUT && attempts == proto.DNS_ATTEMPTS, "nonsense is ignored")
}

// Builds a reply to `query` with the given flags and TXT answers.
@(private)
dns_reply :: proc(query: []u8, rcode: u8, truncated := false, answers: ..string) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, query[0], query[1], 0x81 | (0x02 if truncated else 0), 0x80 | rcode)
	append(&out, 0, 1, 0, u8(len(answers)), 0, 0, 0, 0)
	append(&out, ..query[12:]) // the question
	for a in answers {
		append(&out, 0xC0, 0x0C, 0, 16, 0, 1, 0, 0, 0, 60, 0, u8(len(a) + 1), u8(len(a)))
		append(&out, ..transmute([]u8)a)
	}
	return out[:]
}

@(test)
test_dns_txt_reply :: proc(t: ^testing.T) {
	query_buf: [net.DNS_PACKET_MIN_LEN]u8
	query, qerr := net.make_dns_packet(query_buf[:], 0x1234, "_nb.site.test", .TXT)
	testing.expect(t, qerr == nil)

	values, ok := proto.dns_txt_reply(dns_reply(query, 0, false, "v=nb1; key=x", "other"), context.temp_allocator)
	testing.expect(t, ok && len(values) == 2 && values[0] == "v=nb1; key=x" && values[1] == "other")
	values, ok = proto.dns_txt_reply(dns_reply(query, 0), context.temp_allocator)
	testing.expect(t, ok && len(values) == 0, "NOERROR without records is an answer")
	values, ok = proto.dns_txt_reply(dns_reply(query, 3), context.temp_allocator)
	testing.expect(t, ok && len(values) == 0, "NXDOMAIN is an answer")

	_, ok = proto.dns_txt_reply(dns_reply(query, 2), context.temp_allocator)
	testing.expect(t, !ok, "SERVFAIL is a failure")
	_, ok = proto.dns_txt_reply(dns_reply(query, 5), context.temp_allocator)
	testing.expect(t, !ok, "REFUSED is a failure")
	_, ok = proto.dns_txt_reply(dns_reply(query, 0, true, "v=nb1"), context.temp_allocator)
	testing.expect(t, !ok, "a truncated reply is a failure")
	cut := dns_reply(query, 0, false, "v=nb1; key=x")
	_, ok = proto.dns_txt_reply(cut[:len(cut) - 4], context.temp_allocator)
	testing.expect(t, !ok, "a malformed reply is a failure")
	_, ok = proto.dns_txt_reply(query, context.temp_allocator)
	testing.expect(t, !ok, "a query is not a reply")
	_, ok = proto.dns_txt_reply(nil, context.temp_allocator)
	testing.expect(t, !ok, "no reply (a timeout) is a failure")
}

// A name server on loopback that ignores the first `drop` queries and then
// answers each with `rcode` (and a record for NOERROR).
Fake_Server :: struct {
	sock:     net.UDP_Socket,
	endpoint: net.Endpoint,
	drop:     int,
	rcode:    u8,
	truncate: bool,
	queries:  int,  // atomic
	stop:     bool, // atomic
	thread:   ^thread.Thread,
}

@(private)
fake_server_start :: proc(t: ^testing.T, s: ^Fake_Server) -> bool {
	sock, err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	if !testing.expectf(t, err == nil, "udp: %v", err) {
		return false
	}
	s.sock = sock
	s.endpoint, _ = net.bound_endpoint(sock)
	net.set_option(sock, .Receive_Timeout, 20 * time.Millisecond)
	s.thread = thread.create_and_start_with_poly_data(s, proc(s: ^Fake_Server) {
		buf: [512]u8
		for !sync.atomic_load(&s.stop) {
			n, from, rerr := net.recv_udp(s.sock, buf[:])
			if rerr != nil || n < 12 {
				continue
			}
			if sync.atomic_add(&s.queries, 1) < s.drop {
				continue
			}
			reply := dns_reply(buf[:n], s.rcode, s.truncate, "v=nb1; key=k") if s.rcode == 0 else dns_reply(buf[:n], s.rcode)
			net.send_udp(s.sock, reply, from)
		}
	})
	return true
}

@(private)
fake_server_stop :: proc(s: ^Fake_Server) {
	sync.atomic_store(&s.stop, true)
	thread.join(s.thread)
	thread.destroy(s.thread)
	net.close(s.sock)
}

// One lost packet does not make the lookup fail; a server that fails moves
// on to the next; with no answer at all the lookup fails.
@(test)
test_dns_query_retry :: proc(t: ^testing.T) {
	timeout :: 150 * time.Millisecond

	lossy := Fake_Server{drop = 1}
	if !fake_server_start(t, &lossy) {
		return
	}
	defer fake_server_stop(&lossy)
	values, ok := proto.dns_query_txt("_nb.site.test", {lossy.endpoint}, timeout, 2, context.temp_allocator)
	testing.expect(t, ok && len(values) == 1 && values[0] == "v=nb1; key=k", "answered on the second attempt")
	testing.expect_value(t, sync.atomic_load(&lossy.queries), 2)

	failing := Fake_Server{rcode = 2} // SERVFAIL
	truncating := Fake_Server{truncate = true}
	good := Fake_Server{}
	for s in ([]^Fake_Server{&failing, &truncating, &good}) {
		if !fake_server_start(t, s) {
			return
		}
	}
	defer fake_server_stop(&failing)
	defer fake_server_stop(&truncating)
	defer fake_server_stop(&good)
	values, ok = proto.dns_query_txt("_nb.site.test", {failing.endpoint, truncating.endpoint, good.endpoint}, timeout, 1, context.temp_allocator)
	testing.expect(t, ok && len(values) == 1, "the third server answers")

	nxdomain := Fake_Server{rcode = 3}
	if !fake_server_start(t, &nxdomain) {
		return
	}
	defer fake_server_stop(&nxdomain)
	values, ok = proto.dns_query_txt("_nb.site.test", {nxdomain.endpoint, good.endpoint}, timeout, 1, context.temp_allocator)
	testing.expect(t, ok && len(values) == 0, "NXDOMAIN is final")

	silent := Fake_Server{drop = 1 << 30}
	if !fake_server_start(t, &silent) {
		return
	}
	defer fake_server_stop(&silent)
	_, ok = proto.dns_query_txt("_nb.site.test", {silent.endpoint, failing.endpoint}, timeout, 2, context.temp_allocator)
	testing.expect(t, !ok, "no usable answer is a failure")
	testing.expect_value(t, sync.atomic_load(&silent.queries), 2)
}
