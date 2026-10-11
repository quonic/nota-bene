// Package proto implements NB/1, the browser's network protocol: Noise
// sessions over TCP, request/response messages, page bundles, nb:// URLs and
// server-key pinning. See docs/protocol.md.
package proto

import "core:crypto/ecdh"
import "core:encoding/hex"
import "core:os"
import "core:path/filepath"
import "core:strings"

KEY_SIZE :: 32

// A server's static X25519 public key: its identity.
Key :: [KEY_SIZE]u8

@(private)
B32 := "abcdefghijklmnopqrstuvwxyz234567"

// Lowercase RFC 4648 base32 without padding: 52 characters for a key.
b32_encode :: proc(data: []u8, allocator := context.allocator) -> string {
	out := make([]u8, (len(data) * 8 + 4) / 5, allocator)
	acc, bits, n := u32(0), uint(0), 0
	for b in data {
		acc = acc << 8 | u32(b)
		bits += 8
		for bits >= 5 {
			bits -= 5
			out[n] = B32[(acc >> bits) & 31]
			n += 1
		}
	}
	if bits > 0 {
		out[n] = B32[(acc << (5 - bits)) & 31]
		n += 1
	}
	return string(out[:n])
}

// Decodes into `dst`, which must be exactly the decoded length. Case-insensitive.
b32_decode :: proc(s: string, dst: []u8) -> bool {
	if (len(s) * 5) / 8 != len(dst) || len(s) != (len(dst) * 8 + 4) / 5 {
		return false
	}
	acc, bits, n := u32(0), uint(0), 0
	for c in transmute([]u8)s {
		v: u32
		switch c {
		case 'a' ..= 'z':
			v = u32(c - 'a')
		case 'A' ..= 'Z':
			v = u32(c - 'A')
		case '2' ..= '7':
			v = u32(c - '2') + 26
		case:
			return false
		}
		acc = acc << 5 | v
		bits += 5
		if bits >= 8 {
			bits -= 8
			dst[n] = u8(acc >> bits)
			n += 1
		}
	}
	return n == len(dst) && acc & ((1 << bits) - 1) == 0 // no stray trailing bits
}

key_string :: proc(k: Key, allocator := context.allocator) -> string {
	k := k
	return b32_encode(k[:], allocator)
}

key_parse :: proc(s: string) -> (k: Key, ok: bool) {
	ok = b32_decode(s, k[:])
	return
}

// A short form for people to compare, e.g. "x7k2-q9fa-m3bd-p0zz".
key_fingerprint :: proc(k: Key, allocator := context.allocator) -> string {
	full := key_string(k, context.temp_allocator)
	return strings.join({full[0:4], full[4:8], full[8:12], full[12:16]}, "-", allocator)
}

public_key_of :: proc(priv: ^ecdh.Private_Key) -> (k: Key) {
	ecdh.private_key_public_bytes(priv, k[:])
	return
}

// Loads a server's static private key (hex text), creating it if the file
// does not exist. New key files are readable by the owner only.
static_key_load_or_create :: proc(
	path: string,
	key: ^ecdh.Private_Key,
) -> (
	created: bool,
	ok: bool,
) {
	if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		raw: [KEY_SIZE]u8
		decoded, dok := hex.decode(
			transmute([]u8)strings.trim_space(string(data)),
			context.temp_allocator,
		)
		if !dok || len(decoded) != KEY_SIZE {
			return false, false
		}
		copy(raw[:], decoded)
		return false, ecdh.private_key_set_bytes(key, .X25519, raw[:])
	}
	if !ecdh.private_key_generate(key, .X25519) {
		return false, false
	}
	raw: [KEY_SIZE]u8
	ecdh.private_key_bytes(key, raw[:])
	text := hex.encode(raw[:], context.temp_allocator)
	return true, write_private_file(
		path,
		strings.concatenate({string(text), "\n"}, context.temp_allocator),
	)
}

// Writes a file only the owner can read.
write_private_file :: proc(path, contents: string) -> bool {
	f, err := os.open(path, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if err != nil {
		return false
	}
	defer os.close(f)
	_, werr := os.write_string(f, contents)
	return werr == nil
}

// Pinned server keys ("trust on first use"), one `host:port key` per line,
// like ssh's known_hosts.
Known_Hosts :: struct {
	path:    string,
	entries: map[string]Key,
}

// Where per-user browser state lives: $XDG_CONFIG_HOME/new-browser,
// ~/.config/new-browser, or %APPDATA%\new-browser.
config_dir :: proc(allocator := context.allocator) -> string {
	base := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	when ODIN_OS == .Windows {
		if base == "" {
			base = os.get_env("APPDATA", context.temp_allocator)
		}
	}
	if base == "" {
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" {
			home = "."
		}
		base, _ = filepath.join({home, ".config"}, context.temp_allocator)
	}
	dir, _ := filepath.join({base, "new-browser"}, allocator)
	return dir
}

known_hosts_load :: proc(kh: ^Known_Hosts, path: string) {
	kh.path = strings.clone(path)
	kh.entries = make(map[string]Key)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if len(l) == 0 || l[0] == '#' {
			continue
		}
		fields := strings.fields(l, context.temp_allocator)
		if len(fields) != 2 {
			continue
		}
		if k, ok := key_parse(fields[1]); ok {
			kh.entries[strings.clone(fields[0])] = k
		}
	}
}

known_hosts_save :: proc(kh: ^Known_Hosts) -> bool {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "# Server keys pinned by Nota Bene: host:port key\n")
	for host, k in kh.entries {
		strings.write_string(&sb, host)
		strings.write_byte(&sb, ' ')
		strings.write_string(&sb, key_string(k, context.temp_allocator))
		strings.write_byte(&sb, '\n')
	}
	os.make_directory_all(filepath.dir(kh.path))
	return write_private_file(kh.path, strings.to_string(sb))
}

known_hosts_get :: proc(kh: ^Known_Hosts, host_port: string) -> (Key, bool) {
	return kh.entries[host_port]
}

known_hosts_set :: proc(kh: ^Known_Hosts, host_port: string, k: Key) {
	if _, ok := kh.entries[host_port]; ok {
		kh.entries[host_port] = k
		return
	}
	kh.entries[strings.clone(host_port)] = k
}

known_hosts_destroy :: proc(kh: ^Known_Hosts) {
	for host in kh.entries {
		delete(host)
	}
	delete(kh.entries)
	delete(kh.path)
	kh^ = {}
}
