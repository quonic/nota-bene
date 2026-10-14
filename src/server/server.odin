// Package server serves page bundles over NB/1 from a directory. It is the
// core of nbd, and is also started in-process by the tests.
package server

import "core:crypto/ecdh"
import "core:crypto/ed25519"
import "core:fmt"
import "core:hash"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "../abi"
import "../proto"

Config :: struct {
	root:            string,
	static_key:      ecdh.Private_Key,   // the server's identity
	signer:          ed25519.Private_Key, // publisher key, used when `sign` is set
	sign:            bool,
	max_connections: int,
	max_requests:    int, // per connection; 0 for no limit
	log:             bool,
	// Files never served, even when they lie under root: nbd puts its key
	// files here. Compared as absolute paths.
	exclude:         []string,
}

Server :: struct {
	cfg:      Config,
	sock:     net.TCP_Socket,
	endpoint: net.Endpoint, // where it is listening (port filled in when 0 was asked for)
	active:   int,          // open connections (atomic)
	stopping: bool,         // (atomic)
	requests: int,          // requests answered (atomic)

	cache_lock: sync.Mutex,
	cache:      map[string]Cached_Bundle,
}

// Encoded bundles, rebuilt when the file's modification time or size
// changes, or any of its assets do.
Cached_Bundle :: struct {
	mtime:      time.Time,
	size:       i64,
	assets_sig: u64,
	hash:       [proto.HASH_SIZE]u8,
	encoded:    []u8,
}

MAX_PATH :: 1024

listen :: proc(srv: ^Server, ep: net.Endpoint) -> net.Network_Error {
	if srv.cfg.max_connections <= 0 {
		srv.cfg.max_connections = 64
	}
	sock := net.listen_tcp(ep) or_return
	srv.sock = sock
	bound, berr := net.bound_endpoint(sock)
	if berr != nil {
		net.close(sock)
		return berr
	}
	srv.endpoint = bound
	return nil
}

// Accepts connections until stop is called, one thread per connection.
serve :: proc(srv: ^Server) {
	for !sync.atomic_load(&srv.stopping) {
		client, peer, err := net.accept_tcp(srv.sock)
		if err != nil {
			if sync.atomic_load(&srv.stopping) {
				break
			}
			time.sleep(10 * time.Millisecond)
			continue
		}
		if sync.atomic_load(&srv.stopping) {
			net.close(client)
			break
		}
		if sync.atomic_add(&srv.active, 1) >= srv.cfg.max_connections {
			sync.atomic_sub(&srv.active, 1)
			net.close(client)
			continue
		}
		thread.create_and_start_with_poly_data3(srv, client, peer, handle_connection, self_cleanup = true)
	}
	net.close(srv.sock)
}

// Stops serve from another thread and waits for open connections to finish.
stop :: proc(srv: ^Server) {
	sync.atomic_store(&srv.stopping, true)
	// accept() does not return when its socket is closed from another
	// thread on every platform, so wake it with a connection instead.
	wake := srv.endpoint
	switch a in wake.address {
	case net.IP4_Address:
		if a == {} {
			wake.address = net.IP4_Loopback
		}
	case net.IP6_Address:
		if a == {} {
			wake.address = net.IP6_Loopback
		}
	case:
		wake.address = net.IP4_Loopback
	}
	if s, err := net.dial_tcp(wake); err == nil {
		net.close(s)
	}
	for sync.atomic_load(&srv.active) > 0 {
		time.sleep(5 * time.Millisecond)
	}
}

destroy :: proc(srv: ^Server) {
	for path in srv.cache {
		srv.cache[path] = Cached_Bundle{}
	}
	delete(srv.cache)
}

@(private)
handle_connection :: proc(srv: ^Server, sock: net.TCP_Socket, peer: net.Endpoint) {
	defer sync.atomic_sub(&srv.active, 1)
	defer net.close(sock)
	defer free_all(context.temp_allocator)
	proto.tcp_set_timeouts(sock)

	s := new(proto.Session)
	defer free(s)
	defer proto.session_close(s)
	if err := proto.server_handshake(s, proto.tcp_conn(sock), &srv.cfg.static_key); err != nil {
		log(srv, peer, "-", "handshake failed: %s", proto.error_text(err))
		return
	}
	for n := 0; !sync.atomic_load(&srv.stopping); n += 1 {
		if srv.cfg.max_requests > 0 && n >= srv.cfg.max_requests {
			return
		}
		req: proto.Request
		if proto.recv_cbor(s, &req, context.temp_allocator) != nil {
			return // closed, timed out or garbage: end the connection
		}
		if !handle_request(srv, s, req, peer) {
			return
		}
		free_all(context.temp_allocator)
	}
}

@(private)
log :: proc(srv: ^Server, peer: net.Endpoint, path: string, format: string, args: ..any) {
	if srv.cfg.log {
		fmt.printfln("%s %s %s", net.endpoint_to_string(peer, context.temp_allocator), path, fmt.tprintf(format, ..args))
	}
}

@(private)
respond :: proc(s: ^proto.Session, id: u64, status: u16, message := "") -> bool {
	return proto.send_cbor(s, proto.Response_Head{id = id, status = status, message = message}) == nil
}

@(private)
handle_request :: proc(srv: ^Server, s: ^proto.Session, req: proto.Request, peer: net.Endpoint) -> bool {
	sync.atomic_add(&srv.requests, 1)
	switch req.op {
	case proto.OP_GET:
		return handle_get(srv, s, req, peer)
	case proto.OP_READ:
		return handle_read(srv, s, req, peer)
	}
	log(srv, peer, req.path, "400 unknown op %q", req.op)
	return respond(s, req.id, proto.STATUS_BAD_REQUEST, "unknown op")
}

@(private)
handle_get :: proc(srv: ^Server, s: ^proto.Session, req: proto.Request, peer: net.Endpoint) -> bool {
	file, ok := resolve(srv.cfg.root, req.path)
	if !ok || excluded(srv, file) {
		log(srv, peer, req.path, "404")
		return respond(s, req.id, proto.STATUS_NOT_FOUND, "not found")
	}
	hash, encoded, bok := get_bundle(srv, file)
	if !bok {
		log(srv, peer, req.path, "500 cannot build bundle for %s", file)
		return respond(s, req.id, proto.STATUS_SERVER_ERROR, "cannot read page")
	}
	if string(req.have) == string(hash[:]) {
		log(srv, peer, req.path, "304")
		return respond(s, req.id, proto.STATUS_NOT_MODIFIED)
	}
	return send_ok(srv, s, req, peer, encoded)
}

// Serves one file as it is. Unlike get, the path must name the file
// exactly: no index.elf for directories and no implied ".elf".
@(private)
handle_read :: proc(srv: ^Server, s: ^proto.Session, req: proto.Request, peer: net.Endpoint) -> bool {
	file := ""
	if valid_path(req.path) {
		file, _ = filepath.join({srv.cfg.root, strings.trim_prefix(req.path, "/")}, context.temp_allocator)
	}
	if file == "" || !os.is_file(file) || excluded(srv, file) {
		log(srv, peer, req.path, "404 (read)")
		return respond(s, req.id, proto.STATUS_NOT_FOUND, "not found")
	}
	if fi, err := os.stat(file, context.temp_allocator); err != nil || fi.size > proto.MAX_BODY {
		log(srv, peer, req.path, "500 cannot read %s", file)
		return respond(s, req.id, proto.STATUS_SERVER_ERROR, "cannot read file")
	}
	data, rerr := os.read_entire_file(file, context.temp_allocator)
	if rerr != nil {
		log(srv, peer, req.path, "500 cannot read %s: %v", file, rerr)
		return respond(s, req.id, proto.STATUS_SERVER_ERROR, "cannot read file")
	}
	return send_ok(srv, s, req, peer, data)
}

@(private)
send_ok :: proc(srv: ^Server, s: ^proto.Session, req: proto.Request, peer: net.Endpoint, body: []u8) -> bool {
	head := proto.Response_Head{id = req.id, status = proto.STATUS_OK, size = u64(len(body))}
	if proto.send_cbor(s, head) != nil || proto.send_body(s, body) != nil {
		return false
	}
	log(srv, peer, req.path, "200 %d bytes%s", len(body), " (read)" if req.op == proto.OP_READ else "")
	return true
}

@(private)
excluded :: proc(srv: ^Server, file: string) -> bool {
	if len(srv.cfg.exclude) == 0 {
		return false
	}
	abs, err := os.get_absolute_path(file, context.temp_allocator)
	if err != nil {
		return true // cannot tell: refuse
	}
	for x in srv.cfg.exclude {
		if abs == x {
			return true
		}
	}
	return false
}

// Accepts only plain relative paths: letters, digits and . _ - ~ in
// segments, no "." or ".." segments, so a request can never leave the root.
valid_path :: proc(path: string) -> bool {
	if len(path) == 0 || len(path) > MAX_PATH || path[0] != '/' {
		return false
	}
	rest := path[1:]
	for seg in strings.split_iterator(&rest, "/") {
		if seg == "." || seg == ".." {
			return false
		}
		for c in transmute([]u8)seg {
			switch c {
			case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '_', '-', '~':
			case:
				return false
			}
		}
	}
	return !strings.contains(path, "//")
}

// Maps a request path to a file: "/" and directories serve index.elf, and
// ".elf" may be left off ("/hello" serves hello.elf).
resolve :: proc(root, path: string) -> (string, bool) {
	if !valid_path(path) {
		return "", false
	}
	rel := strings.trim_prefix(path, "/")
	base, _ := filepath.join({root, rel}, context.temp_allocator)
	candidates := [3]string {
		base,
		strings.concatenate({base, ".elf"}, context.temp_allocator),
		filepath.join({base, "index.elf"}, context.temp_allocator) or_else "",
	}
	for c in candidates {
		if c != "" && os.is_file(c) {
			return c, true
		}
	}
	return "", false
}

@(private)
get_bundle :: proc(srv: ^Server, file: string) -> (hash: [proto.HASH_SIZE]u8, encoded: []u8, ok: bool) {
	fi, serr := os.stat(file, context.temp_allocator)
	if serr != nil {
		return
	}
	assets := list_assets(srv, file) or_return
	sig := assets_signature(assets)
	sync.mutex_lock(&srv.cache_lock)
	defer sync.mutex_unlock(&srv.cache_lock)
	if c, found := srv.cache[file]; found && c.mtime == fi.modification_time && c.size == fi.size && c.assets_sig == sig {
		// The cache owns `encoded`; it is only replaced under the lock, but a
		// sender may still be using it, so hand out a copy.
		return c.hash, clone_bytes(c.encoded), true
	}
	code, rerr := os.read_entire_file(file, context.temp_allocator)
	if rerr != nil {
		return
	}
	data := make(map[string][]u8, len(assets), context.temp_allocator)
	total := len(code)
	for a in assets {
		bytes, aerr := os.read_entire_file(a.path, context.temp_allocator)
		total += len(bytes)
		if aerr != nil || len(bytes) > abi.MAX_FETCH_BODY || total > proto.MAX_BODY {
			return
		}
		data[a.name] = bytes
	}
	signer := &srv.cfg.signer if srv.cfg.sign else nil
	enc, h, eok := proto.bundle_encode(code, data, signer)
	if !eok {
		return
	}
	entry := Cached_Bundle{fi.modification_time, fi.size, sig, h, enc}
	if old, found := srv.cache[file]; found {
		delete(old.encoded)
		srv.cache[file] = entry
	} else {
		srv.cache[strings.clone(file)] = entry
	}
	return h, clone_bytes(enc), true
}

// A file that goes into a page's bundle.
@(private)
Asset_File :: struct {
	name:  string, // relative to the assets directory, "/"-separated
	path:  string,
	size:  i64,
	mtime: time.Time,
}

MAX_ASSETS :: 1024

// The directory whose files ship in the bundle of page `file`: hello.elf
// carries hello.assets/.
assets_dir :: proc(file: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({strings.trim_suffix(file, ".elf"), ".assets"}, allocator)
}

// Lists a page's asset files, sorted by name. Only regular files count, and
// only names a request could ask for; hidden and excluded files are skipped.
// Fails if there are more than MAX_ASSETS.
@(private)
list_assets :: proc(srv: ^Server, file: string) -> (files: []Asset_File, ok: bool) {
	out := make([dynamic]Asset_File, context.temp_allocator)
	dir := assets_dir(file)
	if os.is_dir(dir) {
		list_assets_in(srv, dir, "", &out) or_return
	}
	slice.sort_by(out[:], proc(a, b: Asset_File) -> bool {
		return a.name < b.name
	})
	return out[:], true
}

@(private)
list_assets_in :: proc(srv: ^Server, dir, prefix: string, out: ^[dynamic]Asset_File) -> bool {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return false
	}
	for fi in entries {
		if strings.has_prefix(fi.name, ".") {
			continue
		}
		name := fi.name if prefix == "" else strings.concatenate({prefix, "/", fi.name}, context.temp_allocator)
		if !valid_path(strings.concatenate({"/", name}, context.temp_allocator)) {
			continue
		}
		#partial switch fi.type {
		case .Directory:
			list_assets_in(srv, fi.fullpath, name, out) or_return
		case .Regular:
			if excluded(srv, fi.fullpath) {
				continue
			}
			if len(out) >= MAX_ASSETS {
				return false
			}
			append(out, Asset_File{name, fi.fullpath, fi.size, fi.modification_time})
		}
	}
	return true
}

// Changes whenever an asset is added, removed, renamed or modified.
@(private)
assets_signature :: proc(files: []Asset_File) -> u64 {
	h := hash.fnv64a(nil)
	for f in files {
		size, mtime := f.size, time.to_unix_nanoseconds(f.mtime)
		h = hash.fnv64a(transmute([]u8)f.name, h)
		h = hash.fnv64a({0}, h) // ends the name, which is the only part of varying length
		h = hash.fnv64a(([^]u8)(&size)[:size_of(size)], h)
		h = hash.fnv64a(([^]u8)(&mtime)[:size_of(mtime)], h)
	}
	return h
}

@(private)
clone_bytes :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b), context.temp_allocator)
	copy(out, b)
	return out
}
