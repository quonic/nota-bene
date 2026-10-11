// Feed: a list loaded from feed.txt on the page's own server. Shows how a
// page fetches data and handles each outcome. Open it over nb:// (from nbd);
// opened as a local file it has no server to fetch from.
package main

import "core:strconv"
import "core:strings"

import nb "../../sdk/nb"

FEED :: "feed.txt"

list, status: nb.Handle
items: [dynamic]nb.Handle // every node under `list`, closed on refresh
pending := nb.INVALID_HANDLE

main :: proc() {
	root := nb.el(.Box)
	nb.set_attr(root, .Gap, "12")
	title := nb.el(.Heading, root, "Feed")
	nb.set_attr(title, .Level, "2")

	status = nb.el(.Paragraph, root)
	nb.set_attr(status, .Color, "#6b7280")
	list = nb.el(.List, root)
	refresh := nb.el(.Button, root, "Refresh")

	back := nb.el(.Link, root, "Back to hello")
	nb.set_attr(back, .Href, "hello.elf")
	nb.set_root(root)

	load()
	for {
		ev, ok := nb.wait_event()
		if !ok {
			continue
		}
		#partial switch ev.kind {
		case .Click:
			if ev.handle == refresh {
				load()
			}
		case .Fetch:
			if ev.handle == pending {
				loaded(ev.a, int(ev.b))
			}
		case .Quit:
			return
		}
		free_all(context.temp_allocator)
	}
}

load :: proc() {
	if pending != nb.INVALID_HANDLE {
		return // already loading
	}
	h, err := nb.fetch(FEED)
	#partial switch err {
	case .OK:
		pending = h
		nb.set_text(status, "Loading " + FEED + "…")
	case .PERM:
		nb.set_text(status, "This page has no server to fetch from. Open it over nb://, e.g. from nbd.")
	case .NOSYS:
		nb.set_text(status, "This browser cannot fetch.")
	case:
		nb.set_text(status, "Cannot fetch " + FEED + ".")
	}
}

loaded :: proc(result: i64, size: int) {
	h := pending
	pending = nb.INVALID_HANDLE
	defer nb.close(h)
	buf: [32]u8
	switch {
	case result == 200:
	case result == -i64(nb.Errno.NET):
		nb.set_text(status, "The server could not be reached.")
		return
	case result < 0:
		nb.set_text(status, strings.concatenate({"The request failed (error ", strconv.write_int(buf[:], -result, 10), ")."}, context.temp_allocator))
		return
	case:
		nb.set_text(status, strings.concatenate({"The server answered ", strconv.write_int(buf[:], result, 10), "."}, context.temp_allocator))
		return
	}
	data, err := nb.fetch_read_all(h, size, context.temp_allocator)
	if err != .OK {
		nb.set_text(status, "Cannot read the response.")
		return
	}
	#reverse for n in items {
		nb.close(n)
	}
	clear(&items)
	count := 0
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {
			continue
		}
		item := nb.el(.List_Item, list)
		head, _, text := strings.partition(l, "|")
		append(&items, item, nb.el(.Strong, item, strings.trim_space(head)))
		if t := strings.trim_space(text); t != "" {
			append(&items, nb.el(.Text, item, strings.concatenate({" — ", t}, context.temp_allocator)))
		}
		count += 1
	}
	nbuf: [32]u8
	nb.set_text(status, strings.concatenate({strconv.write_int(buf[:], i64(count), 10), " items from ", FEED, ", ", strconv.write_int(nbuf[:], i64(len(data)), 10), " bytes."}, context.temp_allocator))
}

@(export, link_name="_start")
_start :: proc "c" () -> ! {
	nb.start(main)
}
