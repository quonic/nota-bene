package proto

import "core:encoding/cbor"

// Request and response heads are CBOR maps; a response body follows its head
// as raw chunks of up to MAX_PLAINTEXT bytes, `size` bytes in total.

Request :: struct {
	id:   u64,
	op:   string, // OP_GET or OP_READ
	path: string,
	have: []u8 `cbor:"have"`, // hash of a cached bundle; empty if none
}

Response_Head :: struct {
	id:      u64,
	status:  u16,
	size:    u64,
	message: string, // human-readable, for errors
}

OP_GET  :: "get"  // a page: the body is a bundle
OP_READ :: "read" // a file as it is: the body is its bytes

STATUS_OK           :: 200
STATUS_NOT_MODIFIED :: 304 // `have` matched: use the cached bundle
STATUS_BAD_REQUEST  :: 400
STATUS_NOT_FOUND    :: 404
STATUS_SERVER_ERROR :: 500

MAX_BODY :: 64 * 1024 * 1024

send_cbor :: proc(s: ^Session, v: any) -> Error {
	data, err := cbor.marshal(v, cbor.ENCODE_SMALL, context.temp_allocator, context.temp_allocator)
	if err != nil {
		return .Bad_Message
	}
	return session_send(s, data)
}

// Receives one CBOR message into `v`. Strings and slices in `v` are allocated
// with `allocator`.
recv_cbor :: proc(s: ^Session, v: ^$T, allocator := context.allocator) -> Error {
	data := session_recv(s) or_return
	if cbor.unmarshal(data, v, {.Disallow_Streaming}, allocator, context.temp_allocator) != nil {
		return .Bad_Message
	}
	return nil
}

send_body :: proc(s: ^Session, body: []u8) -> Error {
	for off := 0; off < len(body); off += MAX_PLAINTEXT {
		session_send(s, body[off:][:min(MAX_PLAINTEXT, len(body) - off)]) or_return
	}
	return nil
}

recv_body :: proc(s: ^Session, size: u64, allocator := context.allocator) -> ([]u8, Error) {
	if size > MAX_BODY {
		return nil, .Too_Large
	}
	body := make([]u8, int(size), allocator)
	for off := 0; off < len(body); {
		chunk, err := session_recv(s)
		if err != nil || len(chunk) > len(body) - off {
			delete(body, allocator)
			return nil, err if err != nil else .Bad_Message
		}
		off += copy(body[off:], chunk)
	}
	return body, nil
}
