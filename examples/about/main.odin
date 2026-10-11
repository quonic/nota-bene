// About: a long text page describing the browser. Handy for trying text
// selection, find in page (Ctrl+F) and scrolling.
package main

import nb "../../sdk/nb"

Section :: struct {
	heading:    string,
	paragraphs: []string,
}

SECTIONS := []Section {
	{
		"Pages are programs",
		{
			"A page is a compiled RISC-V program, not a document. The browser downloads it, loads it into a sandboxed virtual machine, and the program builds what you see by making system calls. There is no HTML parser, no style sheet engine and no script interpreter.",
			"Because pages are ordinary programs, they can be written in any language that compiles to 64-bit RISC-V. The examples you are looking at are written in Odin, using a small software development kit that wraps the system calls.",
		},
	},
	{
		"Meaning, not pixels",
		{
			"Pages describe what they show as a tree of headings, paragraphs, lists, links, buttons and inputs. The browser decides how to lay that tree out and draw it, which is why selecting this text, copying it and searching it work without the page doing anything.",
			"When a page needs full control it can use a canvas, a block of pixels it computes itself. Everything around the canvas stays semantic.",
		},
	},
	{
		"A sandbox with a budget",
		{
			"Every page runs in its own memory, with no way to reach the browser's memory or anyone else's. Memory pages are either writable or executable, never both. A page that runs for five seconds without waiting for an event is stopped, so it cannot freeze the browser.",
			"Everything the browser gives a page is an opaque handle. Closing a handle and reusing its slot never lets an old handle reach the new object.",
		},
	},
	{
		"Encrypted by default",
		{
			"Pages travel over the Noise protocol. Every connection is encrypted and authenticated; there is no unencrypted mode. Instead of certificate authorities, the browser remembers each server's key the first time it connects and refuses to continue if the key changes, much like a secure shell client.",
			"Publishers can also sign their pages, so a copy served by a mirror can still be checked against the publisher's key.",
		},
	},
	{
		"Your data stays on your side",
		{
			"There are no cookies. A page that wants to remember something asks for a storage quota in its manifest and gets a private store that only pages from the same server, with the same key, can read.",
			"Pages cannot read the clipboard. When you paste into an input, the page sees the text arrive as if you had typed it.",
		},
	},
}

main :: proc() {
	root := nb.el(.Box)
	nb.set_attr(root, .Gap, "14")
	title := nb.el(.Heading, root, "About Nota Bene")
	nb.set_attr(title, .Level, "1")
	for section in SECTIONS {
		h := nb.el(.Heading, root, section.heading)
		nb.set_attr(h, .Level, "2")
		for p in section.paragraphs {
			nb.el(.Paragraph, root, p)
		}
	}
	// Inline content: links, code and emphasis flowing inside one paragraph.
	try_it := nb.el(.Heading, root, "Try it")
	nb.set_attr(try_it, .Level, "2")
	p := nb.el(.Paragraph, root, "Open ")
	link(p, "the notes page", "notes.elf")
	nb.el(.Text, p, ", which keeps its data with ")
	nb.el(.Code, p, "nb.storage_set")
	nb.el(.Text, p, ", or ")
	link(p, "the form demo", "form.elf")
	nb.el(.Text, p, " to see inputs the browser edits for the page. Everything on this page is ")
	nb.el(.Emphasis, p, "selectable")
	nb.el(.Text, p, " and ")
	nb.el(.Strong, p, "searchable")
	nb.el(.Text, p, ": press Ctrl+F.")

	back := nb.el(.Link, root, "Back to hello")
	nb.set_attr(back, .Href, "hello.elf")
	nb.set_root(root)

	for {
		ev, ok := nb.wait_event()
		if ok && ev.kind == .Quit {
			return
		}
	}
}

link :: proc(parent: nb.Handle, text, href: string) {
	l := nb.el(.Link, parent, text)
	nb.set_attr(l, .Href, href)
}

@(export, link_name = "_start")
_start :: proc "c" () -> ! {
	nb.start(main)
}
