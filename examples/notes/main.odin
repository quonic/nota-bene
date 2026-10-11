// Notes: a list kept in the site's storage, so it survives reloads and
// restarts. Also counts visits.
package main

import "core:strconv"
import "core:strings"

import nb "../../sdk/nb"

notes: [dynamic]string
list, usage: nb.Handle
removes: [dynamic]nb.Handle // the Remove button for each note, in order

main :: proc() {
	root := nb.el(.Box)
	nb.set_attr(root, .Gap, "12")
	title := nb.el(.Heading, root, "Notes")
	nb.set_attr(title, .Level, "2")

	visits := count_visit()
	buf: [32]u8
	nb.el(.Paragraph, root, strings.concatenate({"You have opened this page ", strconv.write_int(buf[:], i64(visits), 10), " time" if visits == 1 else " times", "."}, context.temp_allocator))

	row := nb.el(.Box, root)
	nb.set_attr(row, .Direction, "row")
	nb.set_attr(row, .Gap, "8")
	input := nb.el(.Input, row)
	nb.set_attr(input, .Label, "New note")
	add := nb.el(.Button, row, "Add")

	list = nb.el(.List, root)
	usage = nb.el(.Text, root)
	nb.set_attr(usage, .Color, "#6b7280")

	back := nb.el(.Link, root, "Back to hello")
	nb.set_attr(back, .Href, "hello.elf")
	nb.set_root(root)

	load_notes()
	render_notes()

	for {
		ev, ok := nb.wait_event()
		if !ok {
			continue
		}
		#partial switch ev.kind {
		case .Click:
			if ev.handle == add {
				add_note(input)
			}
			for h, i in removes {
				if ev.handle == h {
					delete(notes[i])
					ordered_remove(&notes, i)
					save_notes()
					render_notes()
					break
				}
			}
		case .Key:
			if ev.handle == input && ev.a == i64(nb.Key.Enter) && ev.c == 1 {
				add_note(input)
			}
		case .Quit:
			return
		}
		free_all(context.temp_allocator)
	}
}

count_visit :: proc() -> int {
	n := 0
	if v, err := nb.storage_get("visits", context.temp_allocator); err == .OK {
		n = strconv.parse_int(string(v)) or_else 0
	}
	n += 1
	buf: [32]u8
	nb.storage_set_string("visits", strconv.write_int(buf[:], i64(n), 10))
	return n
}

load_notes :: proc() {
	v, err := nb.storage_get("notes", context.temp_allocator)
	if err != .OK {
		return
	}
	rest := string(v)
	for line in strings.split_lines_iterator(&rest) {
		if line != "" {
			append(&notes, strings.clone(line))
		}
	}
}

save_notes :: proc() {
	joined := strings.join(notes[:], "\n", context.temp_allocator)
	if err := nb.storage_set_string("notes", joined); err == .NOSPC {
		nb.log("storage quota reached", .Warn)
	}
}

add_note :: proc(input: nb.Handle) {
	text, _ := nb.get_text(input, context.temp_allocator)
	text = strings.trim_space(text)
	if text == "" {
		return
	}
	append(&notes, strings.clone(text))
	save_notes()
	nb.set_text(input, "")
	render_notes()
}

// Every node render_notes created, so the next render can close them all
// (closing a node does not close its children).
rendered: [dynamic]nb.Handle

// Rebuilds the list items from `notes`.
render_notes :: proc() {
	for h in rendered {
		nb.close(h)
	}
	clear(&rendered)
	clear(&removes)
	make_el :: proc(kind: nb.Node_Kind, parent: nb.Handle, text := "") -> nb.Handle {
		h := nb.el(kind, parent, text)
		append(&rendered, h)
		return h
	}

	for note in notes {
		item := make_el(.List_Item, list)
		row := make_el(.Box, item)
		nb.set_attr(row, .Direction, "row")
		nb.set_attr(row, .Gap, "12")
		make_el(.Text, row, note)
		append(&removes, make_el(.Button, row, "Remove"))
	}
	if len(notes) == 0 {
		make_el(.List_Item, list, "No notes yet.")
	}

	used, _ := nb.storage_usage()
	buf: [32]u8
	nb.set_text(usage, strings.concatenate({strconv.write_int(buf[:], i64(used), 10), " bytes of 64 KiB storage used"}, context.temp_allocator))
}

@(export, link_name="_start")
_start :: proc "c" () -> ! {
	nb.start(main)
}
