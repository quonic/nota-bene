package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"

import "../../abi"
import "../../host"
import "../../proto"

// A fetch running on its own thread so the window stays responsive.
Fetch_Job :: struct {
	location:     string, // owned; `url` points into it
	url:          proto.URL,
	pinned:       Maybe(proto.Key),
	pinned_from:  enum {
		None,
		URL,
		Known_Hosts,
	},
	have:         []u8,
	push_history: bool,
	result:       proto.Fetch_Result,
	done:         bool, // atomic
	thread:       ^thread.Thread,
}

// The last bundle fetched for a location, revalidated with its hash.
Cached_Page :: struct {
	hash:      []u8,
	code:      []u8,
	publisher: string,
}

@(private)
cache_key :: proc(u: proto.URL) -> string {
	return fmt.tprintf("%s%s", proto.host_port(u, context.temp_allocator), u.path)
}

start_fetch :: proc(b: ^Browser, location: string, push_history: bool) {
	if b.job != nil {
		set_message(b, "still loading %s", b.job.location)
		return
	}
	job := new(Fetch_Job)
	job.location = strings.clone(location)
	u, ok := proto.parse_url(job.location)
	if !ok {
		begin_page(b, location, push_history)
		set_error(b, "%s is not a valid nb:// address", location)
		delete(job.location)
		free(job)
		return
	}
	job.url = u
	job.push_history = push_history
	host := proto.host_port(u, context.temp_allocator)
	if u.has_key {
		job.pinned, job.pinned_from = u.key, .URL
	} else if k, found := proto.known_hosts_get(&b.known_hosts, host); found {
		job.pinned, job.pinned_from = k, .Known_Hosts
	}
	if c, found := b.cache[cache_key(u)]; found {
		job.have = c.hash
	}
	b.job = job
	set_message(b, "connecting to %s…", host)
	job.thread = thread.create_and_start_with_poly_data(job, proc(job: ^Fetch_Job) {
		job.result = proto.fetch(job.url, job.pinned, job.have)
		sync.atomic_store(&job.done, true)
	})
}

// Finishes a completed fetch: checks and pins the server key, updates the
// cache, and starts the page.
poll_fetch :: proc(b: ^Browser) {
	job := b.job
	if job == nil || !sync.atomic_load(&job.done) {
		return
	}
	thread.join(job.thread)
	thread.destroy(job.thread)
	b.job = nil
	defer {
		proto.fetch_result_destroy(&job.result)
		delete(job.location)
		free(job)
	}
	delete(b.message)
	b.message = ""

	r := &job.result
	u := job.url
	server := proto.host_port(u, context.temp_allocator)
	if r.err != nil {
		begin_page(b, job.location, job.push_history)
		switch {
		case r.err == .Handshake && job.pinned_from == .Known_Hosts:
			set_error(b, "%s did not prove it holds the key pinned for it on your first visit. The server's key may have changed, or someone may be intercepting the connection. If the change is expected, remove the %s line from %s.", server, server, b.known_hosts.path)
		case r.err == .Handshake && job.pinned_from == .URL:
			set_error(b, "%s did not prove it holds the key given in the address. Someone may be intercepting the connection, or the address is out of date.", server)
		case r.detail != "":
			set_error(b, "Cannot load %s: %s (%s)", job.location, proto.error_text(r.err), r.detail)
		case:
			set_error(b, "Cannot load %s: %s", job.location, proto.error_text(r.err))
		}
		return
	}

	// Trust on first use: remember the key the server proved it holds.
	if job.pinned_from != .Known_Hosts {
		proto.known_hosts_set(&b.known_hosts, server, r.server_key)
		if !proto.known_hosts_save(&b.known_hosts) {
			fmt.eprintfln("nb: cannot save %s", b.known_hosts.path)
		}
		if job.pinned_from == .None {
			set_message(b, "first visit to %s: pinned its key %s", server, proto.key_fingerprint(r.server_key, context.temp_allocator))
		}
	}

	key := cache_key(u)
	if !r.not_modified {
		publisher := ""
		if len(r.bundle.publisher) == proto.KEY_SIZE {
			pk: proto.Key
			copy(pk[:], r.bundle.publisher)
			publisher = proto.key_fingerprint(pk)
		}
		if old, found := b.cache[key]; found {
			delete(old.hash)
			delete(old.code)
			delete(old.publisher)
			b.cache[key] = {}
		} else {
			key = strings.clone(key)
		}
		// Take ownership of the bundle's buffers.
		b.cache[key] = {hash = r.bundle.hash, code = r.bundle.code, publisher = publisher}
		r.bundle.hash, r.bundle.code = nil, nil
	}
	c, found := b.cache[key]
	if !found {
		begin_page(b, job.location, job.push_history)
		set_error(b, "the server said the cached copy of %s is current, but there is none", job.location)
		return
	}
	// The origin includes the server's key: if the key changes, the new key
	// holder cannot read what pages stored under the old one.
	origin := strings.concatenate({"nb:", server, "#", proto.key_string(r.server_key, context.temp_allocator)}, context.temp_allocator)
	if load_page(b, job.location, c.code, job.push_history, origin) {
		// The page's own address, naming the key this server proved it
		// holds: relative fetches go back to exactly this server.
		self := u
		self.key, self.has_key = r.server_key, true
		host.page_set_location(&b.page, proto.url_string(self, context.temp_allocator))
	}
	delete(b.publisher)
	b.publisher = strings.clone(c.publisher)
}

// A request a page made with Fetch_Open, running on its own thread. The
// thread only touches the job, so it can outlive the page and the tab.
Data_Fetch :: struct {
	location:    string, // owned; `url` points into it
	url:         proto.URL,
	pinned:      Maybe(proto.Key),
	from_known:  bool, // `pinned` came from known_hosts
	tab:         ^Tab,
	serial:      u64,  // the page that asked; see Tab.serial
	id:          u64,  // the host's request id
	result:      proto.Read_Result,
	done:        bool, // atomic
	thread:      ^thread.Thread,
}

// host.Fetch_Proc for every page. It runs inside page_run, while b.cur is
// the tab that owns the page.
page_fetch :: proc(p: ^host.Page, id: u64, url: string) {
	b := (^Browser)(p.user_data)
	t := b.cur
	assert(t != nil && &t.page == p)
	job := new(Data_Fetch)
	job.location = strings.clone(url)
	job.url, _ = proto.parse_url(job.location) // the host only hands out valid URLs
	job.tab, job.serial, job.id = t, t.serial, id
	if job.url.has_key {
		job.pinned = job.url.key
	} else if k, found := proto.known_hosts_get(&b.known_hosts, proto.host_port(job.url, context.temp_allocator)); found {
		job.pinned, job.from_known = k, true
	}
	append(&b.fetches, job)
	job.thread = thread.create_and_start_with_poly_data(job, proc(job: ^Data_Fetch) {
		job.result = proto.read(job.url, job.pinned, abi.MAX_FETCH_BODY)
		sync.atomic_store(&job.done, true)
	})
}

// Hands finished requests to the pages that made them. Answers for a page
// that has since been replaced or closed are dropped.
poll_data_fetches :: proc(b: ^Browser) {
	for i := 0; i < len(b.fetches); {
		job := b.fetches[i]
		if !sync.atomic_load(&job.done) {
			i += 1
			continue
		}
		ordered_remove(&b.fetches, i)
		thread.join(job.thread)
		thread.destroy(job.thread)
		finish_data_fetch(b, job)
		proto.read_result_destroy(&job.result)
		delete(job.location)
		free(job)
	}
}

@(private)
finish_data_fetch :: proc(b: ^Browser, job: ^Data_Fetch) {
	r := &job.result
	server := proto.host_port(job.url, context.temp_allocator)
	if r.err == nil && job.pinned == nil {
		// Trust on first use, as for pages.
		proto.known_hosts_set(&b.known_hosts, server, r.server_key)
		if !proto.known_hosts_save(&b.known_hosts) {
			fmt.eprintfln("nb: cannot save %s", b.known_hosts.path)
		}
	}
	for t in b.tabs {
		if t != job.tab || !t.loaded || t.serial != job.serial {
			continue
		}
		prev := b.cur
		b.cur = t
		defer b.cur = prev
		switch {
		case r.err == nil:
			host.page_fetch_complete(&t.page, job.id, i64(r.status), r.body)
		case r.err == .Too_Large:
			host.page_fetch_complete(&t.page, job.id, -i64(abi.Errno.RANGE), nil)
		case:
			host.page_fetch_complete(&t.page, job.id, -i64(abi.Errno.NET), nil)
			if r.err == .Handshake && job.pinned != nil {
				set_message(b, "%s did not prove it holds the key %s; the page's request failed", server, "pinned for it" if job.from_known else "the page expects")
			}
		}
		return
	}
}

// Runs after every tab is closed (close_tab finishes each tab's fetch).
net_shutdown :: proc(b: ^Browser) {
	// Requests still running are left to finish on their own: joining could
	// stall the exit for as long as a connect takes to time out.
	poll_data_fetches(b)
	delete(b.fetches)
	for key, c in b.cache {
		delete(key)
		delete(c.hash)
		delete(c.code)
		delete(c.publisher)
	}
	delete(b.cache)
	proto.known_hosts_destroy(&b.known_hosts)
}
