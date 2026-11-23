package proto

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:slice"
import "core:strings"
import "core:sync"

Fetch_Result :: struct {
	err:          Error,
	detail:       string, // extra context for err, e.g. the server's message
	server_key:   Key,    // the key the server proved it holds
	not_modified: bool,   // the bundle matching `have` is still current
	bundle:       Bundle, // valid when err == nil and !not_modified
	from_dns:     bool,   // the server was held to the keys published for it in DNS
}

fetch_result_destroy :: proc(r: ^Fetch_Result, allocator := context.allocator) {
	delete(r.detail, allocator)
	bundle_destroy(&r.bundle, allocator)
	r^ = {}
}

// A connection that has completed its handshake.
@(private)
Client :: struct {
	sock:       net.TCP_Socket,
	session:    ^Session,
	server_key: Key,    // the key the server proved it holds
	host:       string, // host_port of the address it was opened for
	next_id:    u64,
	allocator:  runtime.Allocator, // owns session and host
}

// Connects and runs the handshake. The server must prove it holds one of
// `keys`, or any key when there are none: NK for exactly one key, otherwise
// NX, with the key it reveals checked before anything is sent.
@(private)
client_open :: proc(u: URL, keys: []Key, pool: ^Pool, allocator := context.allocator) -> (c: Client, err: Error, detail: string) {
	host := host_port(u, context.temp_allocator)
	conn_allocator := pool.allocator if pool != nil else context.allocator
	sock: net.TCP_Socket
	derr: net.Network_Error
	if pool != nil && pool.resolver.address != nil {
		addr, ok := pool.resolver.address(pool.resolver.data, u.host)
		if !ok {
			return {}, .Connect, fmt.aprintf("cannot resolve %s", u.host, allocator = allocator)
		}
		sock, derr = net.dial_tcp_from_endpoint({addr, int(u.port)})
	} else {
		sock, derr = net.dial_tcp(host)
	}
	if derr != nil {
		return {}, .Connect, fmt.aprintf("%v", derr, allocator = allocator)
	}
	tcp_set_timeouts(sock)
	c = {
		sock      = sock,
		session   = new(Session, conn_allocator), // 128 KiB of buffers: keep it off the stack
		host      = strings.clone(host, conn_allocator),
		allocator = conn_allocator,
	}
	pinned: Maybe(Key)
	if len(keys) == 1 {
		pinned = keys[0]
	}
	c.server_key, err = client_handshake(c.session, tcp_conn(sock), pinned)
	if err == nil && len(keys) > 1 && !slice.contains(keys, c.server_key) {
		err = .Key_Mismatch
	}
	if err != nil {
		client_close(&c)
	}
	return
}

@(private)
client_close :: proc(c: ^Client) {
	session_close(c.session)
	net.close(c.sock)
	free(c.session, c.allocator)
	delete(c.host, c.allocator)
	c^ = {}
}

// Sends one request and reads the head of its response.
@(private)
client_request :: proc(c: ^Client, req: Request) -> (head: Response_Head, err: Error) {
	req := req
	c.next_id += 1
	req.id = c.next_id
	send_cbor(c.session, req) or_return
	recv_cbor(c.session, &head, context.temp_allocator) or_return
	if head.id != req.id {
		return head, .Bad_Message
	}
	return head, nil
}

// Sends `req` and reads the response head, on an idle connection from `pool`
// when there is one. A reused connection the server has closed in the
// meantime is replaced by a new one once: both ops only read, so asking
// again is safe.
//
// The server must prove it holds `pinned`. Without a pinned key the pool
// looks in DNS; a key found there must be proven in the same way, and there
// is no falling back to trust on first use if it is not. Only when DNS has
// no key does the handshake accept whatever key the server has.
@(private)
exchange :: proc(pool: ^Pool, u: URL, pinned: Maybe(Key), req: Request, allocator := context.allocator) -> (c: Client, head: Response_Head, err: Error, detail: string, from_dns: bool) {
	expect: DNS_Keys
	if k, ok := pinned.?; ok {
		expect.keys[0], expect.count = k, 1
	} else {
		expect = dns_keys(pool, u)
		from_dns = expect.count > 0
	}
	keys := expect.keys[:expect.count]
	if pool != nil {
		if idle, ok := pool_take(pool, host_port(u, context.temp_allocator), keys); ok {
			c = idle
			if head, err = client_request(&c, req); err == nil {
				return
			}
			client_close(&c)
		}
		sync.atomic_add(&pool.dials, 1)
	}
	c, err, detail = client_open(u, keys, pool, allocator)
	if err != nil {
		return
	}
	if head, err = client_request(&c, req); err != nil {
		client_close(&c)
	}
	return
}

// Hands a connection back to `pool` if its last exchange completed, so the
// stream is at a message boundary; otherwise closes it.
@(private)
client_done :: proc(pool: ^Pool, c: ^Client, complete: bool) {
	if pool != nil && complete {
		pool_put(pool, c^)
		c^ = {}
	} else {
		client_close(c)
	}
}

// Fetches the bundle at `u`, over an idle connection from `pool` or a new
// one. Blocking: run it off the UI thread.
//
// `pinned` is the key already trusted for this server (see pinned_key);
// without one the pool's resolver may find keys in DNS (r.from_dns), and
// otherwise the handshake learns the key. Either way the caller decides
// whether to pin it. `have` is the hash of a cached copy, if any.
fetch :: proc(u: URL, pinned: Maybe(Key), have: []u8, pool: ^Pool = nil, allocator := context.allocator) -> (r: Fetch_Result) {
	c: Client
	head: Response_Head
	c, head, r.err, r.detail, r.from_dns = exchange(pool, u, pinned, Request{op = OP_GET, path = u.path, have = have}, allocator)
	if r.err != nil {
		return
	}
	r.server_key = c.server_key
	complete := head.size == 0 // answers other than 200 have no body
	defer client_done(pool, &c, complete)

	switch head.status {
	case STATUS_OK:
	case STATUS_NOT_MODIFIED:
		r.not_modified = true
		return
	case STATUS_NOT_FOUND:
		r.err = .Not_Found
		return
	case:
		r.err = .Server_Error
		r.detail = fmt.aprintf("%d %s", head.status, head.message, allocator = allocator)
		return
	}

	body, berr := recv_body(c.session, head.size, context.temp_allocator)
	if berr != nil {
		r.err = berr
		return
	}
	complete = true
	r.bundle, r.err = bundle_decode(body, allocator)
	return
}

Read_Result :: struct {
	err:        Error,  // a transport failure; the server's answer is in `status`
	detail:     string, // extra context for err
	server_key: Key,
	status:     u16,
	body:       []u8,   // the file for 200, the server's message otherwise
	from_dns:   bool,   // as for Fetch_Result
}

read_result_destroy :: proc(r: ^Read_Result, allocator := context.allocator) {
	delete(r.detail, allocator)
	delete(r.body, allocator)
	r^ = {}
}

// Reads the file at `u` as it is, over an idle connection from `pool` or a
// new one. Blocking, like fetch. A body larger than `max_size` fails with
// .Too_Large before it is received.
read :: proc(u: URL, pinned: Maybe(Key), max_size: int, pool: ^Pool = nil, allocator := context.allocator) -> (r: Read_Result) {
	c: Client
	head: Response_Head
	c, head, r.err, r.detail, r.from_dns = exchange(pool, u, pinned, Request{op = OP_READ, path = u.path}, allocator)
	if r.err != nil {
		return
	}
	r.server_key = c.server_key
	complete := false
	defer client_done(pool, &c, complete)

	r.status = head.status
	if head.status != STATUS_OK {
		r.body = transmute([]u8)strings.clone(head.message, allocator)
		complete = head.size == 0
		return
	}
	if head.size > u64(max_size) {
		r.err = .Too_Large // the body is left unread, so the connection goes
		return
	}
	r.body, r.err = recv_body(c.session, head.size, allocator)
	complete = r.err == nil
	return
}
