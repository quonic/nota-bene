// A small interactive page: a document, a button that counts clicks, and
// links to the other examples.
package main

import "core:strconv"

import nb "../../sdk/nb"

clicks := 0
counter: nb.Handle

main :: proc() {
	nb.log("hello from a page")

	root := nb.el(.Box)
	nb.set_attr(root, .Direction, "column")
	nb.set_attr(root, .Gap, "12")

	title := nb.el(.Heading, root, "Hello, new web")
	nb.set_attr(title, .Level, "1")

	intro := nb.el(.Paragraph, root, "This page is a ")
	nb.el(.Strong, intro, "RISC-V program")
	nb.el(.Text, intro, " running in a sandboxed VM. ")
	nb.el(.Emphasis, intro, "No HTML, no JavaScript.")

	// Exercise the heap: a dynamic array of squares, one list item each.
	squares := make([dynamic]int)
	defer delete(squares)
	for i in 1 ..= 3 {
		append(&squares, i * i)
	}
	list := nb.el(.List, root)
	for sq in squares {
		buf: [24]u8
		nb.el(.List_Item, list, strconv.write_int(buf[:], i64(sq), 10)) // the browser copies the text
	}

	row := nb.el(.Box, root)
	nb.set_attr(row, .Direction, "row")
	nb.set_attr(row, .Gap, "12")
	button := nb.el(.Button, row, "Click me")
	counter = nb.el(.Text, row, "Not clicked yet.")

	links := nb.el(.Box, root)
	nb.set_attr(links, .Direction, "row")
	nb.set_attr(links, .Gap, "16")
	canvas_link := nb.el(.Link, links, "Canvas demo")
	nb.set_attr(canvas_link, .Href, "canvas.elf")
	form_link := nb.el(.Link, links, "Form demo")
	nb.set_attr(form_link, .Href, "form.elf")
	notes_link := nb.el(.Link, links, "Notes")
	nb.set_attr(notes_link, .Href, "notes.elf")
	feed_link := nb.el(.Link, links, "Feed")
	nb.set_attr(feed_link, .Href, "feed.elf")
	about_link := nb.el(.Link, links, "About")
	nb.set_attr(about_link, .Href, "about.elf")
	source := nb.el(.Link, links, "Source")
	nb.set_attr(source, .Href, "nb://example.org/hello")

	nb.set_root(root)

	for {
		ev, ok := nb.wait_event()
		if !ok {
			continue
		}
		#partial switch ev.kind {
		case .Click:
			if ev.handle == button {
				clicks += 1
				buf: [64]u8
				n := copy(buf[:], "Clicked ")
				n += len(strconv.write_int(buf[n:], i64(clicks), 10))
				n += copy(buf[n:], " time" if clicks == 1 else " times")
				nb.set_text(counter, string(buf[:n]))
			}
		case .Quit:
			nb.log("goodbye")
			return
		}
	}
}

@(export, link_name="_start")
_start :: proc "c" () -> ! {
	nb.start(main)
}
