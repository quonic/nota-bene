package proto

import "base:runtime"
import "core:fmt"
import "core:net"
@(require) import "core:os" // only used off Windows
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

// How long "no record" (or a failed lookup) is remembered. Keys found are
// kept for the session.
DNS_NEGATIVE_TTL :: 60 * time.Second

// How a pool looks names up. Without `txt` no DNS lookups are made.
Resolver :: struct {
	data:    rawptr,
	// The TXT strings at `name`; ok is false when the lookup failed.
	txt:     proc(data: rawptr, name: string, allocator: runtime.Allocator) -> (values: []string, ok: bool),
	// Optional: the address to dial for `host` instead of the system's
	// answer. Tests use it so that no lookup leaves the process.
	address: proc(data: rawptr, host: string) -> (addr: net.Address, ok: bool),
}

// The keys published for a server, deduplicated.
DNS_Keys :: struct {
	keys:  [MAX_DNS_KEYS]Key,
	count: int,
}

@(private)
DNS_Entry :: struct {
	keys:    DNS_Keys,
	pending: bool,      // a lookup is running; wait on Pool.dns_done
	expires: time.Tick, // zero: kept for the session
}

// The system's resolver: the servers in /etc/resolv.conf on Unix, DnsQuery
// on Windows.
os_resolver :: proc() -> Resolver {
	return {txt = os_txt_lookup}
}

@(private)
os_txt_lookup :: proc(_: rawptr, name: string, allocator: runtime.Allocator) -> (values: []string, ok: bool) {
	context.allocator = context.temp_allocator
	out := make([dynamic]string, allocator)
	when ODIN_OS == .Windows {
		recs, err := net.get_dns_records_from_os(name, .TXT)
		if err != nil {
			return nil, false
		}
		for r in recs {
			if txt, is := r.(net.DNS_Record_TXT); is {
				append(&out, strings.clone(txt.value, allocator))
			}
		}
	} else when ODIN_OS == .Linux || ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
		// get_dns_records_from_os rejects names with '_' for TXT queries, so
		// ask the resolv.conf servers directly. Their answers are the raw
		// record data.
		conf, rerr := os.read_entire_file(net.dns_configuration.resolv_conf, context.temp_allocator)
		if rerr != nil {
			return nil, false
		}
		servers := net.parse_resolv_conf(string(conf))
		if len(servers) == 0 {
			return nil, false
		}
		recs, err := net.get_dns_records_from_nameservers(name, .TXT, servers, nil)
		if err != nil {
			return nil, false
		}
		for r in recs {
			if txt, is := r.(net.DNS_Record_TXT); is {
				if s, sok := txt_rdata_text(txt.value, allocator); sok {
					append(&out, s)
				}
			}
		}
	} else {
		return nil, false
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

// Whether DNS is asked about `host`: never for IP literals or localhost, nor
// for names DNS cannot hold.
dns_lookup_allowed :: proc(host: string) -> bool {
	h := strings.to_lower(strings.trim_suffix(host, "."), context.temp_allocator)
	if net.parse_address(h) != nil || h == "localhost" || strings.has_suffix(h, ".localhost") {
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

// The keys published in DNS for the server at `u`, looked up through the
// pool's resolver once per session (a miss once a minute). Blocking: run it
// off the UI thread. Lookups of one name at the same time share one query.
dns_keys :: proc(p: ^Pool, u: URL) -> (keys: DNS_Keys) {
	if p == nil || p.resolver.txt == nil || !dns_lookup_allowed(u.host) {
		return
	}
	name := dns_record_name(u.host, u.port, context.temp_allocator)

	sync.mutex_lock(&p.lock)
	for {
		e, found := &p.dns[name]
		if !found {
			p.dns[strings.clone(name, p.allocator)] = {pending = true}
			break
		}
		if e.pending {
			sync.cond_wait(&p.dns_done, &p.lock)
			continue
		}
		if e.expires == {} || time.tick_diff(time.tick_now(), e.expires) > 0 {
			keys = e.keys
			sync.mutex_unlock(&p.lock)
			return
		}
		e^ = {pending = true}
		break
	}
	sync.mutex_unlock(&p.lock)

	sync.atomic_add(&p.dns_lookups, 1)
	if values, ok := p.resolver.txt(p.resolver.data, name, context.temp_allocator); ok {
		keys = dns_txt_keys(values)
	}
	entry := DNS_Entry{keys = keys}
	if keys.count == 0 {
		entry.expires = time.tick_add(time.tick_now(), DNS_NEGATIVE_TTL)
	}

	sync.mutex_lock(&p.lock)
	if e, found := &p.dns[name]; found {
		e^ = entry
	}
	sync.cond_broadcast(&p.dns_done)
	sync.mutex_unlock(&p.lock)
	return
}

// How many DNS lookups the pool has made.
pool_dns_lookups :: proc(p: ^Pool) -> int {
	return sync.atomic_load(&p.dns_lookups)
}
