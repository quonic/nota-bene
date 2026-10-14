package host

import "base:runtime"
import "core:strings"

import "../abi"
import "../proto"

// Page-initiated fetches. The host decides what a page may fetch; the front
// end does the network I/O. Fetch_Open checks the request against the
// manifest, hands it to Page.fetch_proc, and returns a stream handle at once.
// When the front end has an answer it calls page_fetch_complete, which
// stores the body in the stream and sends the page a Fetch event.
//
// Manifest `fetch` lines name what a page may contact:
//
//   fetch nb://example.org           everything on that server
//   fetch nb://example.org/api       /api and everything below it
//   fetch nb://<key>@example.org     only if the server holds that key
//   fetch /                          the page's own server, with the key it was loaded from
//   fetch /data                      /data on the page's own server
//
// Relative entries keep a page portable between servers, and only work for
// pages loaded over nb:// (see page_set_location).

// The response to one Fetch_Open. Pending until `done`.
Stream :: struct {
	id:     u64,
	done:   bool,
	status: i64, // the server's status, or a negated abi.Errno
	body:   []u8,
	pos:    int,  // how far Fetch_Read has got
}

// Starts a request for `url`: an nb:// URL that names the server key when the
// manifest or the page's own address does. The string is only valid during
// the call. The front end answers later, on any frame, with
// page_fetch_complete(p, id, ...).
Fetch_Proc :: #type proc(p: ^Page, id: u64, url: string)

// Records where the page was loaded from (an nb:// URL, ideally naming the
// server's key). Relative fetches resolve against it. Pages without a
// location can only fetch absolute nb:// URLs.
page_set_location :: proc(p: ^Page, url: string) {
	delete(p.location, p.allocator)
	p.location = strings.clone(url, p.allocator)
}

// Gives the page the files that came in its bundle, keyed by path relative
// to the page's own address. Relative fetches that name one are answered
// from here, without a round trip. The map is copied; nil clears it.
page_set_assets :: proc(p: ^Page, assets: map[string][]u8) {
	for name, data in p.assets {
		delete(name, p.allocator)
		delete(data, p.allocator)
	}
	delete(p.assets)
	p.assets = nil
	if len(assets) == 0 {
		return
	}
	p.assets = make(map[string][]u8, len(assets), p.allocator)
	for name, data in assets {
		p.assets[strings.clone(name, p.allocator)] = clone_bytes(data, p.allocator)
	}
}

// Delivers the answer to request `id`. A body over abi.MAX_FETCH_BODY turns
// into -RANGE. Answers for streams the page has closed are dropped. The body
// is copied.
page_fetch_complete :: proc(p: ^Page, id: u64, status: i64, body: []u8) {
	h, found := p.fetches[id]
	if !found {
		return
	}
	delete_key(&p.fetches, id)
	e := handle_get(&p.handles, h)
	if e == nil {
		return
	}
	st, ok := &e.obj.(Stream)
	if !ok || st.id != id {
		return
	}
	stream_finish(p, h, st, status, body)
}

@(private)
stream_finish :: proc(p: ^Page, h: abi.Handle, st: ^Stream, status: i64, body: []u8) {
	status, body := status, body
	if len(body) > abi.MAX_FETCH_BODY {
		status, body = -i64(abi.Errno.RANGE), nil
	}
	st.done = true
	st.status = status
	st.body = clone_bytes(body, p.allocator)
	page_push_event(p, abi.Event{kind = .Fetch, handle = h, a = status, b = i64(len(body))})
}

@(private)
clone_bytes :: proc(b: []u8, allocator: runtime.Allocator) -> []u8 {
	out := make([]u8, len(b), allocator)
	copy(out, b)
	return out
}

// The bundled file a relative reference names, if any: the reference must
// resolve to the page's own server and key, under the page's directory.
@(private)
fetch_asset :: proc(p: ^Page, ref: string) -> (data: []u8, ok: bool) {
	if len(p.assets) == 0 || proto.is_nb_url(ref) || strings.contains(ref, "://") {
		return
	}
	base := proto.parse_url(p.location) or_return
	resolved, _ := proto.resolve_ref(base, ref, context.temp_allocator)
	target := proto.parse_url(resolved) or_return
	if target.host != base.host || target.port != base.port || target.has_key != base.has_key || target.key != base.key {
		return
	}
	dir := base.path[:strings.last_index_byte(base.path, '/') + 1]
	path := proto.clean_path(target.path, context.temp_allocator)
	if !strings.has_prefix(path, dir) {
		return
	}
	return p.assets[path[len(dir):]]
}

// The URL a page asked for, resolved against its own address and checked
// against its manifest. The result is temp-allocated and names the key the
// server must prove it holds, if any.
fetch_resolve :: proc(p: ^Page, ref: string) -> (string, abi.Errno) {
	target: proto.URL
	base, has_base := proto.parse_url(p.location)
	switch {
	case proto.is_nb_url(ref):
		ok: bool
		if target, ok = proto.parse_url(ref); !ok {
			return "", .INVAL
		}
	case strings.contains(ref, "://"):
		return "", .INVAL // other schemes
	case !has_base:
		return "", .PERM // a relative address, on a page with no server of its own
	case:
		resolved, _ := proto.resolve_ref(base, ref, context.temp_allocator)
		ok: bool
		if target, ok = proto.parse_url(resolved); !ok {
			return "", .INVAL
		}
	}
	target.path = proto.clean_path(target.path, context.temp_allocator)

	for entry in p.image.manifest.fetch {
		allowed: proto.URL
		switch {
		case strings.has_prefix(entry, "/"):
			if !has_base {
				continue
			}
			allowed = base
			allowed.path = entry
		case:
			ok: bool
			if allowed, ok = proto.parse_url(entry); !ok {
				continue
			}
		}
		allowed.path = proto.clean_path(allowed.path, context.temp_allocator)
		if pinned, ok := proto.fetch_allows(allowed, target); ok {
			if k, has := pinned.?; has {
				target.key, target.has_key = k, true
			}
			return proto.url_string(target, context.temp_allocator), .OK
		}
	}
	return "", .PERM
}

// Whether a manifest `fetch` value has a form fetch_resolve understands, so
// front ends can warn about the others.
fetch_entry_valid :: proc(entry: string) -> bool {
	if strings.has_prefix(entry, "/") {
		return true
	}
	_, ok := proto.parse_url(entry)
	return ok
}

@(private)
fetch_open :: proc(p: ^Page, ref: string) -> (abi.Handle, abi.Errno) {
	if data, ok := fetch_asset(p, ref); ok {
		// Part of the page itself: no manifest line needed, nothing in flight.
		h, hok := handle_alloc(&p.handles, Stream{})
		if !hok {
			return abi.INVALID_HANDLE, .RANGE
		}
		st, _ := &handle_get(&p.handles, h).obj.(Stream)
		stream_finish(p, h, st, 200, data)
		return h, .OK
	}
	if p.fetch_proc == nil {
		return abi.INVALID_HANDLE, .NOSYS // this front end has no network
	}
	url, err := fetch_resolve(p, ref)
	if err != .OK {
		return abi.INVALID_HANDLE, err
	}
	if len(p.fetches) >= abi.MAX_FETCHES {
		return abi.INVALID_HANDLE, .AGAIN
	}
	id := p.next_fetch_id + 1
	h, ok := handle_alloc(&p.handles, Stream{id = id})
	if !ok {
		return abi.INVALID_HANDLE, .RANGE
	}
	p.next_fetch_id = id
	p.fetches[id] = h
	p.fetch_proc(p, id, url)
	return h, .OK
}

@(private)
stream_get :: proc(p: ^Page, h: abi.Handle) -> ^Stream {
	e := handle_get(&p.handles, h)
	if e == nil {
		return nil
	}
	if st, ok := &e.obj.(Stream); ok {
		return st
	}
	return nil
}

// Closing a pending stream cancels it from the page's point of view. The
// request still counts against MAX_FETCHES until the front end answers it,
// so opening and closing in a loop cannot pile up network work.
@(private)
stream_close :: proc(p: ^Page, h: abi.Handle) {
	st := stream_get(p, h)
	if st == nil {
		return
	}
	if !st.done {
		p.fetches[st.id] = abi.INVALID_HANDLE
	}
	delete(st.body, p.allocator)
	handle_release(&p.handles, h)
}
