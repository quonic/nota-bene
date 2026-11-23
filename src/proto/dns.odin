package proto

import "base:runtime"
import "core:fmt"
import "core:net"
@(require) import "core:os" // only used off Windows
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

// Server keys published in DNS: a TXT record such as "v=nb1; key=<key>" at
// _nb.<host> for the default port, or _<port>._nb.<host> for any other. A
// client that has no key for a server asks DNS before falling back to trust
// on first use. See docs/protocol.md.

DNS_TXT_VERSION :: "nb1"

// At most this many distinct keys are taken from a server's records (enough
// for a key rotation); further ones are ignored.
MAX_DNS_KEYS :: 4

// How long a pool remembers an answer. A failure is retried soon, so one
// lost packet does not decide a whole visit.
DNS_KEYS_TTL      :: 10 * time.Minute
DNS_NO_RECORD_TTL :: 60 * time.Second
DNS_FAILURE_TTL   :: 10 * time.Second

// At most this many names are cached per pool; expired ones are dropped to
// make room, and beyond that lookups are simply not cached.
DNS_CACHE_MAX :: 256

// The system resolver's defaults when resolv.conf sets none, and the limits
// on what it may set: a lookup holds up a page load.
DNS_TIMEOUT      :: 1 * time.Second
DNS_ATTEMPTS     :: 2
DNS_MAX_TIMEOUT  :: 5 * time.Second
DNS_MAX_ATTEMPTS :: 3

// How a pool looks names up. Without `txt` no DNS lookups are made.
Resolver :: struct {
	data:    rawptr,
	// The TXT strings at `name`. ok is true for an answer, including "no
	// such name" and "no TXT records"; false when no server answered
	// usably (timeouts, SERVFAIL, truncated or malformed replies).
	txt:     proc(data: rawptr, name: string, allocator: runtime.Allocator) -> (values: []string, ok: bool),
	// Optional: the address to dial for `host` instead of the system's
	// answer. Tests use it so that no lookup leaves the process.
	address: proc(data: rawptr, host: string) -> (addr: net.Address, ok: bool),
}

// What DNS said about a server.
DNS_Answer :: enum u8 {
	Not_Asked, // a key was pinned, the name is never looked up, or no resolver
	No_Record, // DNS answered: no usable record
	Failed,    // no usable answer: a key learned now must not be pinned
	Keys,      // the server must prove one of the keys published
}

// The keys published for a server, deduplicated.
DNS_Keys :: struct {
	keys:  [MAX_DNS_KEYS]Key,
	count: int,
}

@(private)
DNS_Entry :: struct {
	keys:    DNS_Keys,
	answer:  DNS_Answer,
	pending: bool,      // a lookup is running; wait on Pool.dns_done
	expires: time.Tick,
}

// The system's resolver: the servers in /etc/resolv.conf on Unix, DnsQuery
// on Windows.
os_resolver :: proc() -> Resolver {
	return {txt = os_txt_lookup}
}

@(private)
os_txt_lookup :: proc(_: rawptr, name: string, allocator: runtime.Allocator) -> (values: []string, ok: bool) {
	when ODIN_OS == .Windows {
		context.allocator = context.temp_allocator
		// No records is (nil, nil); "no such name" is an error here, so it
		// counts as a failure and is asked again next time.
		recs, err := net.get_dns_records_from_os(name, .TXT)
		if err != nil {
			return nil, false
		}
		out := make([dynamic]string, allocator)
		for r in recs {
			if txt, is := r.(net.DNS_Record_TXT); is {
				append(&out, strings.clone(txt.value, allocator))
			}
		}
		return out[:], true
	} else when ODIN_OS == .Linux || ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
		// core:net's lookups reject names with '_' for TXT, and answer
		// nothing alike for a timeout, SERVFAIL and NXDOMAIN, so the query
		// is made here with its packet helpers.
		conf, rerr := os.read_entire_file(net.dns_configuration.resolv_conf, context.temp_allocator)
		if rerr != nil {
			return nil, false
		}
		servers := net.parse_resolv_conf(string(conf), context.temp_allocator)
		timeout, attempts := resolv_conf_options(string(conf))
		return dns_query_txt(name, servers, timeout, attempts, allocator)
	} else {
		return nil, false
	}
}

// The `options timeout:N attempts:N` of a resolv.conf, within this
// package's limits.
resolv_conf_options :: proc(conf: string) -> (timeout: time.Duration, attempts: int) {
	timeout, attempts = DNS_TIMEOUT, DNS_ATTEMPTS
	rest := conf
	for line in strings.split_lines_iterator(&rest) {
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) == 0 || fields[0] != "options" {
			continue
		}
		for f in fields[1:] {
			if strings.has_prefix(f, "timeout:") {
				if n, ok := strconv.parse_int(f[len("timeout:"):], 10); ok && n >= 1 {
					timeout = min(time.Duration(n) * time.Second, DNS_MAX_TIMEOUT)
				}
			} else if strings.has_prefix(f, "attempts:") {
				if n, ok := strconv.parse_int(f[len("attempts:"):], 10); ok && n >= 1 {
					attempts = min(n, DNS_MAX_ATTEMPTS)
				}
			}
		}
	}
	return
}

// Asks each of `servers` in turn for the TXT records at `name`, over UDP,
// for `attempts` rounds, waiting up to `timeout` for each reply. The first
// usable answer wins; a timeout, a truncated or malformed reply, or an
// error code other than "no such name" moves on to the next server.
dns_query_txt :: proc(name: string, servers: []net.Endpoint, timeout: time.Duration, attempts: int, allocator := context.allocator) -> (values: []string, ok: bool) {
	id: u16be
	if !runtime.random_generator_read_ptr(context.random_generator, &id, size_of(id)) {
		return nil, false
	}
	query_buf: [net.DNS_PACKET_MIN_LEN]u8
	query, qerr := net.make_dns_packet(query_buf[:], id, name, .TXT)
	if qerr != nil {
		return nil, false
	}
	reply_buf: [4096]u8
	for _ in 0 ..< attempts {
		for server in servers {
			sock, serr := net.make_unbound_udp_socket(net.family_from_endpoint(server))
			if serr != nil {
				continue
			}
			reply := udp_exchange(sock, query, id, server, timeout, reply_buf[:])
			net.close(sock)
			if values, ok = dns_txt_reply(reply, allocator); ok {
				return
			}
		}
	}
	return nil, false
}

// Sends `query` and returns the first reply from `server` with its id, or
// nothing after `timeout`.
@(private)
udp_exchange :: proc(sock: net.UDP_Socket, query: []u8, id: u16be, server: net.Endpoint, timeout: time.Duration, buf: []u8) -> []u8 {
	if _, err := net.send_udp(sock, query, server); err != nil {
		return nil
	}
	deadline := time.tick_add(time.tick_now(), timeout)
	for {
		left := time.tick_diff(time.tick_now(), deadline)
		if left < time.Millisecond || net.set_option(sock, .Receive_Timeout, left) != nil {
			return nil
		}
		n, from, rerr := net.recv_udp(sock, buf)
		if rerr != nil {
			return nil
		}
		if n >= 2 && from == server && u16be(buf[0]) << 8 | u16be(buf[1]) == id {
			return buf[:n]
		}
	}
}

// Reads a reply to a TXT query. ok is false for anything but a complete
// answer: "no such name" and "no TXT records" are answers, with no values.
dns_txt_reply :: proc(reply: []u8, allocator := context.allocator) -> (values: []string, ok: bool) {
	HEADER :: 12
	if len(reply) < HEADER || reply[2] & 0x80 == 0 || reply[2] & 0x02 != 0 {
		return nil, false // not a response, or truncated
	}
	switch reply[3] & 0x0F {
	case 0: // NOERROR
	case 3: // NXDOMAIN
		return nil, true
	case: // SERVFAIL, REFUSED and the rest
		return nil, false
	}
	recs, _, pok := net.parse_response(reply, .TXT, context.temp_allocator)
	if !pok {
		return nil, false
	}
	out := make([dynamic]string, allocator)
	for r in recs {
		if txt, is := r.(net.DNS_Record_TXT); is {
			if s, sok := txt_rdata_text(txt.value, allocator); sok {
				append(&out, s)
			}
		}
	}
	return out[:], true
}

// Joins the character-strings of a TXT record's wire data (each a length
// byte and that many bytes), as SPF and DKIM do.
txt_rdata_text :: proc(rdata: string, allocator := context.allocator) -> (text: string, ok: bool) {
	sb := strings.builder_make(allocator)
	for i := 0; i < len(rdata); {
		n := int(rdata[i])
		i += 1
		if n > len(rdata) - i {
			strings.builder_destroy(&sb)
			return "", false
		}
		strings.write_string(&sb, rdata[i:][:n])
		i += n
	}
	return strings.to_string(sb), true
}

// Where a server's key is published: _nb.<host> for the default port,
// _<port>._nb.<host> for any other.
dns_record_name :: proc(host: string, port: u16, allocator := context.allocator) -> string {
	h := strings.to_lower(strings.trim_suffix(host, "."), context.temp_allocator)
	if port == DEFAULT_PORT {
		return fmt.aprintf("_nb.%s", h, allocator = allocator)
	}
	return fmt.aprintf("_%d._nb.%s", port, h, allocator = allocator)
}

// The TXT value that publishes `k`.
dns_txt_value :: proc(k: Key, allocator := context.allocator) -> string {
	return fmt.aprintf("v=%s; key=%s", DNS_TXT_VERSION, key_string(k, context.temp_allocator), allocator = allocator)
}

// Whether DNS is asked about `host`: never for IP literals, localhost,
// .local or single-label names, nor for names DNS cannot hold.
dns_lookup_allowed :: proc(host: string) -> bool {
	h := strings.to_lower(strings.trim_suffix(host, "."), context.temp_allocator)
	if net.parse_address(h) != nil || h == "localhost" || strings.has_suffix(h, ".localhost") {
		return false
	}
	// Single labels are local names a search list would complete, and
	// .local names belong to mDNS: neither is the server's published name.
	if !strings.contains_rune(h, '.') || strings.has_suffix(h, ".local") {
		return false
	}
	if len(h) == 0 || len(h) > 240 { // leaves room for "_65535._nb."
		return false
	}
	rest := h
	for label in strings.split_iterator(&rest, ".") {
		if len(label) == 0 || len(label) > 63 {
			return false
		}
		for c in transmute([]u8)label {
			switch c {
			case 'a' ..= 'z', '0' ..= '9', '-', '_':
			case:
				return false
			}
		}
	}
	return true
}

// Parses one TXT value: `;`-separated `name=value` fields, the first of
// which must be v=nb1. Whitespace around fields and '=' is ignored, and so
// are unknown fields. Exactly one `key` field must name a valid key.
dns_txt_key :: proc(value: string) -> (k: Key, ok: bool) {
	rest := value
	first, have := true, false
	for field in strings.split_iterator(&rest, ";") {
		f := strings.trim_space(field)
		if f == "" {
			continue
		}
		eq := strings.index_byte(f, '=')
		if eq < 0 {
			return {}, false
		}
		name, val := strings.trim_space(f[:eq]), strings.trim_space(f[eq + 1:])
		if first {
			if !strings.equal_fold(name, "v") || !strings.equal_fold(val, DNS_TXT_VERSION) {
				return {}, false
			}
			first = false
			continue
		}
		if strings.equal_fold(name, "key") {
			if have {
				return {}, false // two keys in one record: ambiguous
			}
			k = key_parse(val) or_return
			have = true
		}
	}
	return k, have
}

// The distinct keys in a server's TXT values. Values that are not valid
// v=nb1 records are skipped.
dns_txt_keys :: proc(values: []string) -> (keys: DNS_Keys) {
	outer: for v in values {
		k := dns_txt_key(v) or_continue
		for have in keys.keys[:keys.count] {
			if have == k {
				continue outer
			}
		}
		if keys.count == MAX_DNS_KEYS {
			break
		}
		keys.keys[keys.count] = k
		keys.count += 1
	}
	return
}

// The keys published in DNS for the server at `u`, through the pool's
// resolver and its cache (see the TTLs above). Blocking: run it off the UI
// thread. Lookups of one name at the same time share one query.
dns_keys :: proc(p: ^Pool, u: URL) -> (keys: DNS_Keys, answer: DNS_Answer) {
	if p == nil || p.resolver.txt == nil || !dns_lookup_allowed(u.host) {
		return
	}
	name := dns_record_name(u.host, u.port, context.temp_allocator)

	cached := true
	sync.mutex_lock(&p.lock)
	for {
		e, found := &p.dns[name]
		if !found {
			if len(p.dns) >= DNS_CACHE_MAX {
				dns_prune(p)
			}
			cached = len(p.dns) < DNS_CACHE_MAX
			if cached {
				p.dns[strings.clone(name, p.allocator)] = {pending = true}
			}
			break
		}
		if e.pending {
			sync.cond_wait(&p.dns_done, &p.lock)
			continue
		}
		if time.tick_diff(time.tick_now(), e.expires) > 0 {
			keys, answer = e.keys, e.answer
			sync.mutex_unlock(&p.lock)
			return
		}
		e^ = {pending = true}
		break
	}
	sync.mutex_unlock(&p.lock)

	sync.atomic_add(&p.dns_lookups, 1)
	ttl: time.Duration
	if values, ok := p.resolver.txt(p.resolver.data, name, context.temp_allocator); !ok {
		answer, ttl = .Failed, DNS_FAILURE_TTL
	} else if keys = dns_txt_keys(values); keys.count > 0 {
		answer, ttl = .Keys, DNS_KEYS_TTL
	} else {
		answer, ttl = .No_Record, DNS_NO_RECORD_TTL
	}
	if !cached {
		return
	}

	sync.mutex_lock(&p.lock)
	if e, found := &p.dns[name]; found {
		e^ = {keys = keys, answer = answer, expires = time.tick_add(time.tick_now(), ttl)}
	}
	sync.cond_broadcast(&p.dns_done)
	sync.mutex_unlock(&p.lock)
	return
}

// Drops expired entries. Called with p.lock held.
@(private)
dns_prune :: proc(p: ^Pool) {
	now := time.tick_now()
	stale := make([dynamic]string, context.temp_allocator)
	for name, e in p.dns {
		if !e.pending && time.tick_diff(now, e.expires) <= 0 {
			append(&stale, name)
		}
	}
	for name in stale {
		key, _ := delete_key(&p.dns, name)
		delete(key, p.allocator)
	}
}

// How many names the pool's DNS cache holds.
pool_dns_cached :: proc(p: ^Pool) -> int {
	sync.mutex_lock(&p.lock)
	defer sync.mutex_unlock(&p.lock)
	return len(p.dns)
}

// How many DNS lookups the pool has made.
pool_dns_lookups :: proc(p: ^Pool) -> int {
	return sync.atomic_load(&p.dns_lookups)
}
