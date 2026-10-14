package proto

import "base:runtime"
import "core:sync"
import "core:time"

// Connections kept open between requests, so a page load and the fetches
// that follow it share one handshake per server. A connection is reused only
// for the same address and, when the caller pins a key, only if that is the
// key the connection was authenticated with.
//
// Every user holds a reference: the owner from pool_create, plus one per
// request still running on another thread, so those threads may outlive
// pool_close.
Pool :: struct {
	allocator: runtime.Allocator, // for the pool and every connection it holds
	lock:      sync.Mutex,
	idle:      [dynamic]Idle_Conn, // oldest first; guarded by lock
	closed:    bool,               // guarded by lock
	refs:      int,                // atomic
	dials:     int,                // atomic: connections opened through the pool
}

@(private)
Idle_Conn :: struct {
	client: Client,
	since:  time.Tick,
}

// Idle connections are dropped well before the server's IO_TIMEOUT ends them.
POOL_IDLE_TIMEOUT :: 10 * time.Second
POOL_MAX_PER_HOST :: 4

pool_create :: proc(allocator := context.allocator) -> ^Pool {
	p := new(Pool, allocator)
	p.allocator = allocator
	p.idle.allocator = allocator
	p.refs = 1
	return p
}

pool_retain :: proc(p: ^Pool) {
	if p != nil {
		sync.atomic_add(&p.refs, 1)
	}
}

pool_release :: proc(p: ^Pool) {
	if p == nil || sync.atomic_sub(&p.refs, 1) != 1 {
		return
	}
	for &e in p.idle {
		client_close(&e.client)
	}
	delete(p.idle)
	free(p, p.allocator)
}

// Closes the idle connections, stops keeping new ones, and drops the
// owner's reference. Requests still running finish on their own connections.
pool_close :: proc(p: ^Pool) {
	if p == nil {
		return
	}
	sync.mutex_lock(&p.lock)
	p.closed = true
	for &e in p.idle {
		client_close(&e.client)
	}
	clear(&p.idle)
	sync.mutex_unlock(&p.lock)
	pool_release(p)
}

// How many connections the pool has opened.
pool_dials :: proc(p: ^Pool) -> int {
	return sync.atomic_load(&p.dials)
}

// How many connections are waiting to be reused.
pool_idle :: proc(p: ^Pool) -> int {
	sync.mutex_lock(&p.lock)
	defer sync.mutex_unlock(&p.lock)
	return len(p.idle)
}

// Takes the most recently used idle connection to `host` that `pinned`
// allows, after dropping the expired ones.
@(private)
pool_take :: proc(p: ^Pool, host: string, pinned: Maybe(Key)) -> (c: Client, ok: bool) {
	sync.mutex_lock(&p.lock)
	defer sync.mutex_unlock(&p.lock)
	for i := 0; i < len(p.idle); {
		if time.tick_since(p.idle[i].since) > POOL_IDLE_TIMEOUT {
			client_close(&p.idle[i].client)
			ordered_remove(&p.idle, i)
			continue
		}
		i += 1
	}
	for i := len(p.idle) - 1; i >= 0; i -= 1 {
		e := p.idle[i]
		if e.client.host != host {
			continue
		}
		if k, has := pinned.?; has && k != e.client.server_key {
			continue
		}
		ordered_remove(&p.idle, i)
		return e.client, true
	}
	return
}

// Keeps a connection whose last exchange completed, or closes it if the pool
// is closed or already holds enough for that server.
@(private)
pool_put :: proc(p: ^Pool, c: Client) {
	c := c
	sync.mutex_lock(&p.lock)
	defer sync.mutex_unlock(&p.lock)
	n := 0
	for e in p.idle {
		if e.client.host == c.host {
			n += 1
		}
	}
	if p.closed || n >= POOL_MAX_PER_HOST {
		client_close(&c)
		return
	}
	append(&p.idle, Idle_Conn{c, time.tick_now()})
}
