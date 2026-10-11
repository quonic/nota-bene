package proto_test

import "core:crypto/ecdh"
import "core:crypto/ed25519"
import "core:fmt"
import "core:net"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"

import "../../src/proto"
import "../../src/server"

BUILD_DIR :: #config(BUILD_DIR, "build")

@(test)
test_base32 :: proc(t: ^testing.T) {
	data := [5]u8{0xDE, 0xAD, 0xBE, 0xEF, 0x01}
	s := proto.b32_encode(data[:], context.temp_allocator)
	testing.expect_value(t, s, "32w353yb")
	out: [5]u8
	testing.expect(t, proto.b32_decode(s, out[:]))
	testing.expect_value(t, out, data)
	testing.expect(t, proto.b32_decode("32W353YB", out[:]), "decoding is case-insensitive")
	testing.expect(t, !proto.b32_decode("32w353y1", out[:]), "'1' is not in the alphabet")
	testing.expect(t, !proto.b32_decode("32w353y", out[:]), "wrong length")
	four: [4]u8
	testing.expect(t, proto.b32_decode("32w353y", four[:]))
	testing.expect(t, !proto.b32_decode("32w353z", four[:]), "stray trailing bits")

	k: proto.Key
	for i in 0 ..< len(k) {
		k[i] = u8(i * 7)
	}
	ks := proto.key_string(k, context.temp_allocator)
	testing.expect_value(t, len(ks), 52)
	back, ok := proto.key_parse(ks)
	testing.expect(t, ok && back == k)
}

@(test)
test_parse_url :: proc(t: ^testing.T) {
	u, ok := proto.parse_url("nb://example.org/hello")
	testing.expect(t, ok)
	testing.expect_value(t, u.host, "example.org")
	testing.expect_value(t, u.port, proto.DEFAULT_PORT)
	testing.expect_value(t, u.path, "/hello")
	testing.expect(t, !u.has_key)

	u, ok = proto.parse_url("nb://localhost:9000")
	testing.expect(t, ok && u.port == 9000 && u.path == "/")
	u, ok = proto.parse_url("nb://[::1]:4041/x")
	testing.expect(t, ok && u.host == "::1" && u.port == 4041)
	testing.expect_value(t, proto.host_port(u, context.temp_allocator), "[::1]:4041")

	k: proto.Key
	k[0] = 1
	with_key := fmt.tprintf("nb://%s@host/p", proto.key_string(k, context.temp_allocator))
	u, ok = proto.parse_url(with_key)
	testing.expect(t, ok && u.has_key && u.key == k && u.host == "host")
	testing.expect_value(t, proto.url_string(u, context.temp_allocator), with_key)

	for bad in ([]string{"http://x/", "nb://", "nb://:4040/", "nb://host:0/", "nb://host:70000/", "nb://ho st/", "nb://bad@host/", "nb://[::1/"}) {
		_, bok := proto.parse_url(bad)
		testing.expectf(t, !bok, "%q should not parse", bad)
	}
}

@(test)
test_resolve_ref :: proc(t: ^testing.T) {
	base, _ := proto.parse_url("nb://site:5000/docs/guide/intro")
	Case :: struct {
		ref, want: string,
	}
	cases := []Case{
		{"next", "nb://site:5000/docs/guide/next"},
		{"../index", "nb://site:5000/docs/index"},
		{"/top", "nb://site:5000/top"},
		{"../../../../etc", "nb://site:5000/etc"},
		{"./a/./b//c", "nb://site:5000/docs/guide/a/b/c"},
		{"nb://other/x", "nb://other/x"},
	}
	for c in cases {
		got, ok := proto.resolve_ref(base, c.ref, context.temp_allocator)
		testing.expectf(t, ok && got == c.want, "resolve %q: got %q, want %q", c.ref, got, c.want)
	}
	_, ok := proto.resolve_ref(base, "https://example.org/", context.temp_allocator)
	testing.expect(t, !ok, "only nb:// links resolve")
}

@(test)
test_bundle_verification :: proc(t: ^testing.T) {
	code := []u8{1, 2, 3, 4}
	data, hash, ok := proto.bundle_encode(code, nil, nil, context.temp_allocator)
	testing.expect(t, ok)
	b, err := proto.bundle_decode(data)
	testing.expect_value(t, err, proto.Error.None)
	testing.expect_value(t, string(b.code), string(code))
	testing.expect_value(t, string(b.hash), string(hash[:]))
	proto.bundle_destroy(&b)

	// Flip one byte of the code inside the encoding: the hash no longer matches.
	tampered := make([]u8, len(data), context.temp_allocator)
	copy(tampered, data)
	for i in 0 ..< len(tampered) - 3 {
		if tampered[i] == 1 && tampered[i + 1] == 2 && tampered[i + 2] == 3 {
			tampered[i + 1] = 9
			break
		}
	}
	_, err = proto.bundle_decode(tampered)
	testing.expect_value(t, err, proto.Error.Bad_Bundle)

	// Signed bundles verify; a signature from another key does not.
	signer: ed25519.Private_Key
	testing.expect(t, ed25519.private_key_generate(&signer))
	sdata, _, sok := proto.bundle_encode(code, nil, &signer, context.temp_allocator)
	testing.expect(t, sok)
	sb, serr := proto.bundle_decode(sdata)
	testing.expect_value(t, serr, proto.Error.None)
	testing.expect_value(t, len(sb.publisher), ed25519.PUBLIC_KEY_SIZE)
	proto.bundle_destroy(&sb)

	forged := make([]u8, len(sdata), context.temp_allocator)
	copy(forged, sdata)
	forged[len(forged) - 1] ~= 0xFF // last byte belongs to the signature
	_, ferr := proto.bundle_decode(forged)
	testing.expect_value(t, ferr, proto.Error.Bad_Bundle)

	_, gerr := proto.bundle_decode([]u8{0xFF, 0x00, 0x13})
	testing.expect_value(t, gerr, proto.Error.Bad_Bundle)
}

// An in-memory byte pipe, so sessions can be tested (and tampered with)
// without sockets.
Pipe :: struct {
	mu:     sync.Mutex,
	cond:   sync.Cond,
	buf:    [dynamic]u8,
	closed: bool,
}

pipe_conn :: proc(r, w: ^Pipe) -> proto.Conn {
	Ends :: struct {
		r, w: ^Pipe,
	}
	ends := new(Ends, context.temp_allocator)
	ends^ = {r, w}
	return proto.Conn {
		data = ends,
		read = proc(data: rawptr, buf: []u8) -> int {
			p := (^Ends)(data).r
			sync.mutex_lock(&p.mu)
			defer sync.mutex_unlock(&p.mu)
			for len(p.buf) == 0 && !p.closed {
				sync.cond_wait(&p.cond, &p.mu)
			}
			n := copy(buf, p.buf[:])
			remove_range(&p.buf, 0, n)
			return n
		},
		write = proc(data: rawptr, buf: []u8) -> bool {
			p := (^Ends)(data).w
			sync.mutex_lock(&p.mu)
			append(&p.buf, ..buf)
			sync.cond_broadcast(&p.cond)
			sync.mutex_unlock(&p.mu)
			return true
		},
	}
}

Server_Side :: struct {
	session: ^proto.Session,
	conn:    proto.Conn,
	key:     ^ecdh.Private_Key,
	err:     proto.Error,
	out:     ^Pipe,
}

pipe_close :: proc(p: ^Pipe) {
	sync.mutex_lock(&p.mu)
	p.closed = true
	sync.cond_broadcast(&p.cond)
	sync.mutex_unlock(&p.mu)
}

handshake_pair :: proc(t: ^testing.T, c2s, s2c: ^Pipe, key: ^ecdh.Private_Key, pinned: Maybe(proto.Key)) -> (client, srv: ^proto.Session, server_key: proto.Key, cerr, serr: proto.Error) {
	client = new(proto.Session)
	srv = new(proto.Session)
	side := Server_Side{session = srv, conn = pipe_conn(c2s, s2c), key = key, out = s2c}
	th := thread.create_and_start_with_poly_data(&side, proc(s: ^Server_Side) {
		s.err = proto.server_handshake(s.session, s.conn, s.key)
		if s.err != nil {
			pipe_close(s.out) // like a server closing the socket
		}
	})
	server_key, cerr = proto.client_handshake(client, pipe_conn(s2c, c2s), pinned)
	if cerr != nil {
		pipe_close(c2s) // unblock a server still waiting for a frame
	}
	thread.join(th)
	thread.destroy(th)
	return client, srv, server_key, cerr, side.err
}

@(test)
test_session :: proc(t: ^testing.T) {
	key: ecdh.Private_Key
	testing.expect(t, ecdh.private_key_generate(&key, .X25519))
	pub := proto.public_key_of(&key)

	c2s, s2c: Pipe
	defer delete(c2s.buf)
	defer delete(s2c.buf)
	client, srv, learned, cerr, serr := handshake_pair(t, &c2s, &s2c, &key, nil)
	defer free(client)
	defer free(srv)
	testing.expect_value(t, cerr, proto.Error.None)
	testing.expect_value(t, serr, proto.Error.None)
	testing.expect(t, learned == pub, "NX must reveal the server's key")

	// Messages flow both ways.
	testing.expect_value(t, proto.session_send(client, transmute([]u8)string("ping")), proto.Error.None)
	msg, err := proto.session_recv(srv)
	testing.expect(t, err == nil && string(msg) == "ping")
	testing.expect_value(t, proto.session_send(srv, transmute([]u8)string("pong")), proto.Error.None)
	msg, err = proto.session_recv(client)
	testing.expect(t, err == nil && string(msg) == "pong")

	// Rekeying at the interval keeps both directions in sync.
	client.sent = proto.REKEY_INTERVAL - 1
	srv.received = proto.REKEY_INTERVAL - 1
	for word in ([]string{"before", "after"}) {
		testing.expect_value(t, proto.session_send(client, transmute([]u8)word), proto.Error.None)
		msg, err = proto.session_recv(srv)
		testing.expectf(t, err == nil && string(msg) == word, "across rekey: %v %q", err, msg)
	}

	// A flipped bit in transit is detected.
	proto.session_send(client, transmute([]u8)string("secret"))
	c2s.buf[len(c2s.buf) - 1] ~= 1
	_, err = proto.session_recv(srv)
	testing.expect_value(t, err, proto.Error.Decrypt)
}

@(test)
test_pinned_key_mismatch :: proc(t: ^testing.T) {
	key, other: ecdh.Private_Key
	testing.expect(t, ecdh.private_key_generate(&key, .X25519))
	testing.expect(t, ecdh.private_key_generate(&other, .X25519))

	c2s, s2c: Pipe
	defer delete(c2s.buf)
	defer delete(s2c.buf)
	client, srv, _, cerr, _ := handshake_pair(t, &c2s, &s2c, &key, proto.public_key_of(&other))
	free(client)
	free(srv)
	testing.expect_value(t, cerr, proto.Error.Handshake)

	// The right pinned key uses NK and succeeds.
	c2s2, s2c2: Pipe
	defer delete(c2s2.buf)
	defer delete(s2c2.buf)
	client2, srv2, learned, cerr2, serr2 := handshake_pair(t, &c2s2, &s2c2, &key, proto.public_key_of(&key))
	free(client2)
	free(srv2)
	testing.expect_value(t, cerr2, proto.Error.None)
	testing.expect_value(t, serr2, proto.Error.None)
	testing.expect(t, learned == proto.public_key_of(&key))
}

@(test)
test_server_paths :: proc(t: ^testing.T) {
	testing.expect(t, server.valid_path("/"))
	testing.expect(t, server.valid_path("/hello"))
	testing.expect(t, server.valid_path("/docs/a-b_c.elf"))
	for bad in ([]string{"", "hello", "/../etc/passwd", "/a/../b", "/./a", "//a", "/a b", "/a\\b", "/a%2e"}) {
		testing.expectf(t, !server.valid_path(bad), "%q should be rejected", bad)
	}
}

// End to end over loopback TCP: nbd's server code and the browser's fetch.
@(test)
test_fetch :: proc(t: ^testing.T) {
	hello, rerr := os.read_entire_file(fmt.tprintf("%s/hello.elf", BUILD_DIR), context.temp_allocator)
	if !testing.expectf(t, rerr == nil, "build/hello.elf missing (run ./build.sh test): %v", rerr) {
		return
	}

	srv: server.Server
	srv.cfg.root = BUILD_DIR
	testing.expect(t, ecdh.private_key_generate(&srv.cfg.static_key, .X25519))
	testing.expect(t, ed25519.private_key_generate(&srv.cfg.signer))
	srv.cfg.sign = true
	if err := server.listen(&srv, {address = net.IP4_Loopback, port = 0}); !testing.expectf(t, err == nil, "listen: %v", err) {
		return
	}
	th := thread.create_and_start_with_poly_data(&srv, server.serve)
	defer {
		server.stop(&srv)
		thread.join(th)
		thread.destroy(th)
		server.destroy(&srv)
	}
	server_pub := proto.public_key_of(&srv.cfg.static_key)
	url := fmt.tprintf("nb://127.0.0.1:%d/hello", srv.endpoint.port)
	u, ok := proto.parse_url(url)
	testing.expect(t, ok)

	// First contact: NX, key learned.
	r := proto.fetch(u, nil, nil)
	testing.expectf(t, r.err == nil, "fetch: %s %s", proto.error_text(r.err), r.detail)
	testing.expect(t, r.server_key == server_pub)
	testing.expect_value(t, len(r.bundle.code), len(hello))
	testing.expect(t, string(r.bundle.code) == string(hello), "bundle code differs from the file")
	testing.expect_value(t, len(r.bundle.publisher), ed25519.PUBLIC_KEY_SIZE)
	hash := make([]u8, len(r.bundle.hash), context.temp_allocator)
	copy(hash, r.bundle.hash)
	proto.fetch_result_destroy(&r)

	// Pinned key: NK. With the cached hash: 304.
	r = proto.fetch(u, server_pub, hash)
	testing.expectf(t, r.err == nil && r.not_modified, "revalidate: %v %v", r.err, r.not_modified)
	proto.fetch_result_destroy(&r)

	// Wrong pinned key.
	wrong := server_pub
	wrong[0] ~= 0x40
	r = proto.fetch(u, wrong, nil)
	testing.expect_value(t, r.err, proto.Error.Handshake)
	proto.fetch_result_destroy(&r)

	// Missing pages and paths escaping the root.
	for path in ([]string{"/missing", "/../hello"}) {
		mu := u
		mu.path = path
		r = proto.fetch(mu, server_pub, nil)
		testing.expectf(t, r.err == .Not_Found, "%s: %v", path, r.err)
		proto.fetch_result_destroy(&r)
	}

	// Nobody listening.
	closed := u
	closed.port = 1
	r = proto.fetch(closed, nil, nil)
	testing.expect_value(t, r.err, proto.Error.Connect)
	proto.fetch_result_destroy(&r)

	// Data: files as they are, named exactly.
	rd := proto.read(u, server_pub, 1 << 20) // "/hello" is a page path, not a file name
	testing.expect_value(t, rd.err, proto.Error.None)
	testing.expect_value(t, rd.status, proto.STATUS_NOT_FOUND)
	proto.read_result_destroy(&rd)
	du := u
	du.path = "/hello.elf"
	rd = proto.read(du, server_pub, 1 << 20)
	testing.expectf(t, rd.err == nil && rd.status == proto.STATUS_OK, "read: %v %d", rd.err, rd.status)
	testing.expect(t, string(rd.body) == string(hello), "read body differs from the file")
	proto.read_result_destroy(&rd)
	rd = proto.read(du, server_pub, len(hello) - 1)
	testing.expect_value(t, rd.err, proto.Error.Too_Large)
	proto.read_result_destroy(&rd)

	testing.expect(t, sync.atomic_load(&srv.requests) >= 4)
}

// Files on the exclusion list (nbd's own keys) are never served, by either op.
@(test)
test_server_exclude :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/test_exclude", BUILD_DIR)
	os.make_directory_all(dir)
	secret := fmt.tprintf("%s/server.key", dir)
	testing.expect(t, os.write_entire_file(secret, transmute([]u8)string("private")) == nil)
	public := fmt.tprintf("%s/data.txt", dir)
	testing.expect(t, os.write_entire_file(public, transmute([]u8)string("public")) == nil)
	defer os.remove_all(dir)

	abs, aerr := os.get_absolute_path(secret, context.temp_allocator)
	testing.expect(t, aerr == nil)
	srv: server.Server
	srv.cfg.root = dir
	srv.cfg.exclude = []string{abs}
	testing.expect(t, ecdh.private_key_generate(&srv.cfg.static_key, .X25519))
	if err := server.listen(&srv, {address = net.IP4_Loopback, port = 0}); !testing.expectf(t, err == nil, "listen: %v", err) {
		return
	}
	th := thread.create_and_start_with_poly_data(&srv, server.serve)
	defer {
		server.stop(&srv)
		thread.join(th)
		thread.destroy(th)
		server.destroy(&srv)
	}
	pub := proto.public_key_of(&srv.cfg.static_key)
	u, _ := proto.parse_url(fmt.tprintf("nb://127.0.0.1:%d/server.key", srv.endpoint.port))

	r := proto.fetch(u, pub, nil)
	testing.expect_value(t, r.err, proto.Error.Not_Found)
	proto.fetch_result_destroy(&r)
	rd := proto.read(u, pub, 1 << 20)
	testing.expect_value(t, rd.status, proto.STATUS_NOT_FOUND)
	testing.expect(t, string(rd.body) != "private")
	proto.read_result_destroy(&rd)

	u.path = "/data.txt"
	rd = proto.read(u, pub, 1 << 20)
	testing.expect_value(t, rd.status, proto.STATUS_OK)
	testing.expect_value(t, string(rd.body), "public")
	proto.read_result_destroy(&rd)
}

@(test)
test_fetch_allows :: proc(t: ^testing.T) {
	k1, k2: proto.Key
	k1[0], k2[0] = 1, 2
	keyed := fmt.tprintf("nb://%s@site", proto.key_string(k1, context.temp_allocator))
	other := fmt.tprintf("nb://%s@site/x", proto.key_string(k2, context.temp_allocator))
	Case :: struct {
		entry, target: string,
		ok:            bool,
		pinned:        bool,
	}
	cases := []Case{
		{"nb://site", "nb://site/anything", true, false},
		{"nb://site", "nb://SITE:4040/", true, false},
		{"nb://site", "nb://site:4041/", false, false},
		{"nb://site", "nb://elsewhere/", false, false},
		{"nb://site/api", "nb://site/api", true, false},
		{"nb://site/api/", "nb://site/api/v1/x", true, false},
		{"nb://site/api", "nb://site/apix", false, false},
		{"nb://site/api", "nb://site/", false, false},
		{keyed, "nb://site/x", true, true},
		{keyed, other, false, false},
		{"nb://site", other, true, true},
	}
	for c in cases {
		e, eok := proto.parse_url(c.entry)
		g, gok := proto.parse_url(c.target)
		testing.expect(t, eok && gok)
		pinned, ok := proto.fetch_allows(e, g)
		testing.expectf(t, ok == c.ok, "%s admits %s: got %v", c.entry, c.target, ok)
		testing.expectf(t, (pinned != nil) == c.pinned, "%s, %s: pinned %v", c.entry, c.target, pinned)
	}
}

@(test)
test_known_hosts :: proc(t: ^testing.T) {
	path := fmt.tprintf("%s/test_known_hosts", BUILD_DIR)
	os.remove(path)
	defer os.remove(path)

	kh: proto.Known_Hosts
	proto.known_hosts_load(&kh, path)
	k: proto.Key
	k[3] = 7
	proto.known_hosts_set(&kh, "example.org:4040", k)
	testing.expect(t, proto.known_hosts_save(&kh))
	proto.known_hosts_destroy(&kh)

	again: proto.Known_Hosts
	proto.known_hosts_load(&again, path)
	defer proto.known_hosts_destroy(&again)
	got, ok := proto.known_hosts_get(&again, "example.org:4040")
	testing.expect(t, ok && got == k)
	_, missing := proto.known_hosts_get(&again, "other:4040")
	testing.expect(t, !missing)
}
