package proto

import "core:crypto/ecdh"
import "core:crypto/noise"
import "core:net"
import "core:time"

// Every frame on the wire is a 2-byte big-endian length followed by that many
// bytes. After the handshake each frame is one Noise ciphertext.
MAX_FRAME     :: noise.MAX_PACKET_SIZE // 65535
MAX_PLAINTEXT :: MAX_FRAME - noise.TAG_SIZE

PROLOGUE    :: "NB/1"
PROTOCOL_NX :: "Noise_NX_25519_ChaChaPoly_BLAKE2b" // first contact: the server sends its key
PROTOCOL_NK :: "Noise_NK_25519_ChaChaPoly_BLAKE2b" // key known: authenticated from message one

// The first handshake frame starts with this byte so the server knows which
// pattern the client chose. It is also bound into the prologue, so changing
// it in transit makes the handshake fail.
MODE_NX :: u8('X')
MODE_NK :: u8('K')

// Both sides rekey after this many messages in a direction.
REKEY_INTERVAL :: 1 << 20

IO_TIMEOUT :: 15 * time.Second

Error :: enum {
	None,
	Bad_URL,
	Connect,        // could not reach the server
	Closed,         // the peer went away (or timed out)
	Bad_Frame,
	Handshake,      // handshake failed: wrong pinned key, tampering, or not an NB/1 server
	Decrypt,        // a transport message failed authentication
	Key_Mismatch,   // the server's key is not the one pinned for it
	Too_Large,
	Bad_Message,
	Not_Found,
	Server_Error,
	Bad_Bundle,     // hash or signature does not verify
}

error_text :: proc(e: Error) -> string {
	switch e {
	case .None:         return "ok"
	case .Bad_URL:      return "not a valid nb:// address"
	case .Connect:      return "could not connect to the server"
	case .Closed:       return "the connection closed unexpectedly"
	case .Bad_Frame:    return "the server sent a malformed frame"
	case .Handshake:    return "the secure handshake failed (the server's key may have changed, or the connection was tampered with)"
	case .Decrypt:      return "a message failed authentication (the connection was tampered with)"
	case .Key_Mismatch: return "the server's key does not match the key pinned for it"
	case .Too_Large:    return "the response is too large"
	case .Bad_Message:  return "the server sent an invalid message"
	case .Not_Found:    return "no page at this address"
	case .Server_Error: return "the server reported an error"
	case .Bad_Bundle:   return "the page bundle failed verification"
	}
	return "unknown error"
}

// A byte stream. TCP in practice; tests plug in pipes.
Conn :: struct {
	data:  rawptr,
	read:  proc(data: rawptr, buf: []u8) -> int, // bytes read; <= 0 when closed or failed
	write: proc(data: rawptr, buf: []u8) -> bool, // writes everything or fails
}

tcp_conn :: proc(sock: net.TCP_Socket) -> Conn {
	return Conn {
		data = rawptr(uintptr(sock)),
		read = proc(data: rawptr, buf: []u8) -> int {
			n, err := net.recv_tcp(net.TCP_Socket(uintptr(data)), buf)
			return n if err == nil else -1
		},
		write = proc(data: rawptr, buf: []u8) -> bool {
			_, err := net.send_tcp(net.TCP_Socket(uintptr(data)), buf)
			return err == nil
		},
	}
}

// Applies the I/O timeouts both ends use, so a stalled peer cannot hold a thread forever.
tcp_set_timeouts :: proc(sock: net.TCP_Socket) {
	net.set_option(sock, .Receive_Timeout, IO_TIMEOUT)
	net.set_option(sock, .Send_Timeout, IO_TIMEOUT)
	net.set_option(sock, .TCP_Nodelay, true)
}

@(private)
read_full :: proc(c: Conn, buf: []u8) -> bool {
	for off := 0; off < len(buf); {
		n := c.read(c.data, buf[off:])
		if n <= 0 {
			return false
		}
		off += n
	}
	return true
}

read_frame :: proc(c: Conn, buf: []u8) -> ([]u8, Error) {
	hdr: [2]u8
	if !read_full(c, hdr[:]) {
		return nil, .Closed
	}
	n := int(hdr[0]) << 8 | int(hdr[1])
	if n == 0 || n > len(buf) {
		return nil, .Bad_Frame
	}
	if !read_full(c, buf[:n]) {
		return nil, .Closed
	}
	return buf[:n], nil
}

write_frame :: proc(c: Conn, payload: []u8) -> Error {
	if len(payload) == 0 || len(payload) > MAX_FRAME {
		return .Bad_Frame
	}
	hdr := [2]u8{u8(len(payload) >> 8), u8(len(payload))}
	if !c.write(c.data, hdr[:]) || !c.write(c.data, payload) {
		return .Closed
	}
	return nil
}

// An established, encrypted connection.
Session :: struct {
	conn:     Conn,
	cs:       noise.Cipher_States,
	sent:     u64,
	received: u64,
	frame:    [MAX_FRAME]u8,
	plain:    [MAX_FRAME]u8,
}

@(private)
hs_ok :: proc(st: noise.Status) -> bool {
	#partial switch st {
	case .Ok, .Handshake_Pending, .Handshake_Complete:
		return true
	}
	return false
}

// Runs the client side. With a pinned key the NK pattern authenticates the
// server from the first message; without one, NX learns the key, which is
// returned for the caller to pin.
client_handshake :: proc(s: ^Session, conn: Conn, pinned: Maybe(Key)) -> (server_key: Key, err: Error) {
	s.conn = conn
	hs: noise.Handshake_State
	defer noise.handshake_reset(&hs)

	mode := MODE_NX
	protocol := PROTOCOL_NX
	rs: ecdh.Public_Key
	rs_ptr: ^ecdh.Public_Key
	if k, ok := pinned.?; ok {
		mode, protocol = MODE_NK, PROTOCOL_NK
		k := k
		if !ecdh.public_key_set_bytes(&rs, .X25519, k[:]) {
			return {}, .Handshake
		}
		rs_ptr = &rs
	}
	prologue := [5]u8{'N', 'B', '/', '1', mode}
	if noise.handshake_init(&hs, true, prologue[:], nil, rs_ptr, protocol) != .Ok {
		return {}, .Handshake
	}

	msg1, st := noise.handshake_write_message(&hs, nil, allocator = context.temp_allocator)
	if !hs_ok(st) {
		return {}, .Handshake
	}
	first := make([]u8, len(msg1) + 1, context.temp_allocator)
	first[0] = mode
	copy(first[1:], msg1)
	write_frame(conn, first) or_return

	msg2, ferr := read_frame(conn, s.frame[:])
	if ferr != nil {
		// A server that cannot complete the handshake (wrong pinned key, or
		// not an NB/1 server) simply hangs up.
		return {}, .Handshake if ferr == .Closed else ferr
	}
	_, st = noise.handshake_read_message(&hs, msg2, allocator = context.temp_allocator)
	if !hs_ok(st) || hs.status != .Handshake_Complete {
		return {}, .Handshake
	}
	peer, pst := noise.handshake_peer_identity(&hs)
	if pst != .Ok {
		return {}, .Handshake
	}
	ecdh.public_key_bytes(peer, server_key[:])
	if k, ok := pinned.?; ok && k != server_key {
		return server_key, .Key_Mismatch // NK already guarantees this; checked for clarity
	}
	if noise.handshake_split(&hs, &s.cs) != .Ok {
		return {}, .Handshake
	}
	return server_key, nil
}

// Runs the server side with the server's static key, for either pattern.
server_handshake :: proc(s: ^Session, conn: Conn, static_key: ^ecdh.Private_Key) -> Error {
	s.conn = conn
	hs: noise.Handshake_State
	defer noise.handshake_reset(&hs)

	first := read_frame(conn, s.frame[:]) or_return
	protocol: string
	switch first[0] {
	case MODE_NX: protocol = PROTOCOL_NX
	case MODE_NK: protocol = PROTOCOL_NK
	case:         return .Handshake
	}
	prologue := [5]u8{'N', 'B', '/', '1', first[0]}
	if noise.handshake_init(&hs, false, prologue[:], static_key, nil, protocol) != .Ok {
		return .Handshake
	}
	_, st := noise.handshake_read_message(&hs, first[1:], allocator = context.temp_allocator)
	if !hs_ok(st) {
		return .Handshake
	}
	msg2, wst := noise.handshake_write_message(&hs, nil, allocator = context.temp_allocator)
	if !hs_ok(wst) || hs.status != .Handshake_Complete {
		return .Handshake
	}
	write_frame(conn, msg2) or_return
	if noise.handshake_split(&hs, &s.cs) != .Ok {
		return .Handshake
	}
	return nil
}

session_send :: proc(s: ^Session, plaintext: []u8) -> Error {
	if len(plaintext) > MAX_PLAINTEXT {
		return .Too_Large
	}
	ct, st := noise.seal_message(&s.cs, nil, plaintext, s.frame[:len(plaintext) + noise.TAG_SIZE])
	if st != .Ok {
		return .Decrypt
	}
	write_frame(s.conn, ct) or_return
	s.sent += 1
	if s.sent % REKEY_INTERVAL == 0 && noise.cipherstates_rekey(&s.cs, true) != .Ok {
		return .Decrypt
	}
	return nil
}

// Returns the next message. The slice is valid until the next session_recv.
session_recv :: proc(s: ^Session) -> (msg: []u8, err: Error) {
	ct := read_frame(s.conn, s.frame[:]) or_return
	if len(ct) < noise.TAG_SIZE {
		return nil, .Bad_Frame
	}
	pt, st := noise.open_message(&s.cs, nil, ct, s.plain[:len(ct) - noise.TAG_SIZE])
	if st != .Ok {
		return nil, .Decrypt
	}
	s.received += 1
	if s.received % REKEY_INTERVAL == 0 && noise.cipherstates_rekey(&s.cs, false) != .Ok {
		return nil, .Decrypt
	}
	return pt, nil
}

session_close :: proc(s: ^Session) {
	noise.cipherstates_reset(&s.cs)
}
