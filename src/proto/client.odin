package proto

import "core:fmt"
import "core:net"
import "core:strings"

Fetch_Result :: struct {
	err:          Error,
	detail:       string, // extra context for err, e.g. the server's message
	server_key:   Key,    // the key the server proved it holds
	not_modified: bool,   // the bundle matching `have` is still current
	bundle:       Bundle, // valid when err == nil and !not_modified
}

fetch_result_destroy :: proc(r: ^Fetch_Result, allocator := context.allocator) {
	delete(r.detail, allocator)
	bundle_destroy(&r.bundle, allocator)
	r^ = {}
}

// A connection that has completed its handshake.
@(private)
Client :: struct {
	sock:    net.TCP_Socket,
	session: ^Session,
}

@(private)
client_open :: proc(u: URL, pinned: Maybe(Key), allocator := context.allocator) -> (c: Client, server_key: Key, err: Error, detail: string) {
	sock, derr := net.dial_tcp(host_port(u, context.temp_allocator))
	if derr != nil {
		return {}, {}, .Connect, fmt.aprintf("%v", derr, allocator = allocator)
	}
	tcp_set_timeouts(sock)
	c = {sock, new(Session, context.temp_allocator)} // 128 KiB of buffers: keep it off the stack
	server_key, err = client_handshake(c.session, tcp_conn(sock), pinned)
	if err != nil {
		client_close(&c)
	}
	return
}

@(private)
client_close :: proc(c: ^Client) {
	session_close(c.session)
	net.close(c.sock)
}

// Sends one request and reads the head of its response.
@(private)
client_request :: proc(c: ^Client, req: Request) -> (head: Response_Head, err: Error) {
	send_cbor(c.session, req) or_return
	recv_cbor(c.session, &head, context.temp_allocator) or_return
	if head.id != req.id {
		return head, .Bad_Message
	}
	return head, nil
}

// Fetches the bundle at `u` over a new connection. Blocking: run it off the UI thread.
//
// `pinned` is the key already trusted for this server (from the URL or the
// known_hosts file); without one the handshake learns the key, and the caller
// decides whether to pin it. `have` is the hash of a cached copy, if any.
fetch :: proc(u: URL, pinned: Maybe(Key), have: []u8, allocator := context.allocator) -> (r: Fetch_Result) {
	c: Client
	c, r.server_key, r.err, r.detail = client_open(u, pinned, allocator)
	if r.err != nil {
		return
	}
	defer client_close(&c)

	head: Response_Head
	head, r.err = client_request(&c, Request{id = 1, op = OP_GET, path = u.path, have = have})
	if r.err != nil {
		return
	}
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
	r.bundle, r.err = bundle_decode(body, allocator)
	return
}

Read_Result :: struct {
	err:        Error,  // a transport failure; the server's answer is in `status`
	detail:     string, // extra context for err
	server_key: Key,
	status:     u16,
	body:       []u8,   // the file for 200, the server's message otherwise
}

read_result_destroy :: proc(r: ^Read_Result, allocator := context.allocator) {
	delete(r.detail, allocator)
	delete(r.body, allocator)
	r^ = {}
}

// Reads the file at `u` as it is, over a new connection. Blocking, like
// fetch. A body larger than `max_size` fails with .Too_Large before it is
// received.
read :: proc(u: URL, pinned: Maybe(Key), max_size: int, allocator := context.allocator) -> (r: Read_Result) {
	c: Client
	c, r.server_key, r.err, r.detail = client_open(u, pinned, allocator)
	if r.err != nil {
		return
	}
	defer client_close(&c)

	head: Response_Head
	head, r.err = client_request(&c, Request{id = 1, op = OP_READ, path = u.path})
	if r.err != nil {
		return
	}
	r.status = head.status
	if head.status != STATUS_OK {
		r.body = transmute([]u8)strings.clone(head.message, allocator)
		return
	}
	if head.size > u64(max_size) {
		r.err = .Too_Large
		return
	}
	r.body, r.err = recv_body(c.session, head.size, allocator)
	return
}

