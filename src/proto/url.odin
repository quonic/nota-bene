package proto

import "core:fmt"
import "core:strconv"
import "core:strings"

DEFAULT_PORT :: 4040
SCHEME       :: "nb://"

// nb://[key@]host[:port][/path]
URL :: struct {
	host:    string, // without brackets for IPv6 literals
	port:    u16,
	path:    string, // always starts with '/'
	key:     Key,
	has_key: bool,   // the URL itself names the server's key
}

is_nb_url :: proc(s: string) -> bool {
	return strings.has_prefix(s, SCHEME)
}

// Parses an nb:// URL. The result's strings point into `s`.
parse_url :: proc(s: string) -> (u: URL, ok: bool) {
	if !is_nb_url(s) {
		return
	}
	for c in transmute([]u8)s {
		if c <= ' ' || c == 0x7F {
			return // no spaces or control characters
		}
	}
	rest := s[len(SCHEME):]
	authority := rest
	u.path = "/"
	if i := strings.index_byte(rest, '/'); i >= 0 {
		authority = rest[:i]
		u.path = rest[i:]
	}
	if i := strings.index_byte(authority, '@'); i >= 0 {
		u.key = key_parse(authority[:i]) or_return
		u.has_key = true
		authority = authority[i + 1:]
	}
	u.port = DEFAULT_PORT
	port_str := ""
	if strings.has_prefix(authority, "[") {
		end := strings.index_byte(authority, ']')
		if end < 0 {
			return
		}
		u.host = authority[1:end]
		after := authority[end + 1:]
		if len(after) > 0 {
			if after[0] != ':' {
				return
			}
			port_str = after[1:]
		}
	} else {
		u.host = authority
		if i := strings.last_index_byte(authority, ':'); i >= 0 {
			u.host = authority[:i]
			port_str = authority[i + 1:]
		}
	}
	if len(u.host) == 0 {
		return
	}
	if port_str != "" {
		p := strconv.parse_u64_of_base(port_str, 10) or_return
		if p == 0 || p > 65535 {
			return
		}
		u.port = u16(p)
	}
	return u, true
}

// "host:port", the form used for dialing and in known_hosts.
host_port :: proc(u: URL, allocator := context.allocator) -> string {
	if strings.contains_rune(u.host, ':') {
		return fmt.aprintf("[%s]:%d", u.host, u.port, allocator = allocator)
	}
	return fmt.aprintf("%s:%d", u.host, u.port, allocator = allocator)
}

url_string :: proc(u: URL, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, SCHEME)
	if u.has_key {
		strings.write_string(&sb, key_string(u.key, context.temp_allocator))
		strings.write_byte(&sb, '@')
	}
	switch {
	case u.port != DEFAULT_PORT:
		strings.write_string(&sb, host_port(u, context.temp_allocator))
	case strings.contains_rune(u.host, ':'):
		fmt.sbprintf(&sb, "[%s]", u.host)
	case:
		strings.write_string(&sb, u.host)
	}
	strings.write_string(&sb, u.path)
	return strings.to_string(sb)
}

// Resolves a link found on the page at `base` (an nb:// URL). Absolute nb://
// links are returned as they are; "/x" is relative to the server; anything
// else is relative to the base path's directory. "." and ".." are folded,
// never climbing above the root.
resolve_ref :: proc(base: URL, ref: string, allocator := context.allocator) -> (string, bool) {
	if strings.contains(ref, "://") {
		return strings.clone(ref, allocator), is_nb_url(ref)
	}
	joined: string
	if strings.has_prefix(ref, "/") {
		joined = ref
	} else {
		dir := base.path[:strings.last_index_byte(base.path, '/') + 1]
		joined = strings.concatenate({dir, ref}, context.temp_allocator)
	}
	u := base
	u.path = clean_path(joined, context.temp_allocator)
	return url_string(u, allocator), true
}

// Folds "." and ".." segments and duplicate slashes; the result starts with '/'.
clean_path :: proc(path: string, allocator := context.allocator) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	rest := path
	for seg in strings.split_iterator(&rest, "/") {
		switch seg {
		case "", ".":
		case "..":
			if len(parts) > 0 {
				pop(&parts)
			}
		case:
			append(&parts, seg)
		}
	}
	trailing := strings.has_suffix(path, "/") && len(parts) > 0
	out := strings.concatenate({"/", strings.join(parts[:], "/", context.temp_allocator), "/" if trailing else ""}, allocator)
	return out
}

// Whether a manifest `fetch` entry admits `target`. Both are parsed nb://
// URLs. Hosts compare case-insensitively and ports must be equal. An entry
// with a path other than "/" admits that path and everything below it, by
// whole segments ("/api" admits "/api/x", not "/apix"). An entry that names
// a key only admits requests that name the same key or none; `pinned` is the
// key the server must then prove it holds.
fetch_allows :: proc(entry, target: URL) -> (pinned: Maybe(Key), ok: bool) {
	if !strings.equal_fold(entry.host, target.host) || entry.port != target.port {
		return nil, false
	}
	if entry.has_key && target.has_key && entry.key != target.key {
		return nil, false
	}
	prefix := strings.trim_suffix(entry.path, "/")
	if prefix != "" && target.path != prefix && !strings.has_prefix(target.path, strings.concatenate({prefix, "/"}, context.temp_allocator)) {
		return nil, false
	}
	switch {
	case entry.has_key:
		pinned = entry.key
	case target.has_key:
		pinned = target.key
	}
	return pinned, true
}
