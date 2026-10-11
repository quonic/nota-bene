// Form demo: an Input the browser edits for the page, Change events, and
// reading the value back with Node_Get_Text.
package main

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

import nb "../../sdk/nb"

main :: proc() {
	root := nb.el(.Box)
	nb.set_attr(root, .Gap, "12")
	title := nb.el(.Heading, root, "Form")
	nb.set_attr(title, .Level, "2")
	nb.el(.Paragraph, root, "Type your name and press Enter or the button.")

	row := nb.el(.Box, root)
	nb.set_attr(row, .Direction, "row")
	nb.set_attr(row, .Gap, "8")
	input := nb.el(.Input, row)
	nb.set_attr(input, .Label, "Your name")
	greet := nb.el(.Button, row, "Greet")

	count := nb.el(.Text, root, "0 characters")
	nb.set_attr(count, .Color, "#6b7280")
	result := nb.el(.Paragraph, root)
	nb.set_attr(result, .Font_Size, "20")

	back := nb.el(.Link, root, "Back to hello")
	nb.set_attr(back, .Href, "hello.elf")
	nb.set_root(root)

	for {
		ev, ok := nb.wait_event()
		if !ok {
			continue
		}
		#partial switch ev.kind {
		case .Change:
			name, _ := nb.get_text(input, context.temp_allocator)
			buf: [32]u8
			n := strconv.write_int(buf[:], i64(utf8.rune_count_in_string(name)), 10)
			nb.set_text(count, strings.concatenate({n, " characters"}, context.temp_allocator))
		case .Click:
			if ev.handle == greet {
				say_hello(input, result)
			}
		case .Key:
			if ev.handle == input && ev.a == i64(nb.Key.Enter) && ev.c == 1 {
				say_hello(input, result)
			}
		case .Quit:
			return
		}
		free_all(context.temp_allocator)
	}
}

say_hello :: proc(input, result: nb.Handle) {
	name, _ := nb.get_text(input, context.temp_allocator)
	name = strings.trim_space(name)
	if name == "" {
		nb.set_text(result, "Hello, whoever you are!")
	} else {
		nb.set_text(result, strings.concatenate({"Hello, ", name, "!"}, context.temp_allocator))
	}
}

@(export, link_name="_start")
_start :: proc "c" () -> ! {
	nb.start(main)
}
