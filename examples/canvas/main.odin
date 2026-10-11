// Canvas demo: pixels computed in the page, an animation driven by
// Wait_Event timeouts, and clicks that stamp squares.
package main

import nb "../../sdk/nb"

W :: 320
H :: 180

pixels: [W * H * 4]u8

Stamp :: struct {
	x, y: int,
}

main :: proc() {
	root := nb.el(.Box)
	nb.set_attr(root, .Gap, "12")
	title := nb.el(.Heading, root, "Canvas")
	nb.set_attr(title, .Level, "2")
	nb.el(.Paragraph, root, "Every pixel below is computed by the page. Click to stamp squares.")

	canvas := nb.el(.Canvas, root)
	nb.set_attr(canvas, .Width, "320")
	nb.set_attr(canvas, .Height, "180")
	nb.set_attr(canvas, .Alt, "An animated gradient with a moving bar")

	back := nb.el(.Link, root, "Back to hello")
	nb.set_attr(back, .Href, "hello.elf")
	nb.set_root(root)

	stamps := make([dynamic]Stamp)
	defer delete(stamps)
	frame := 0

	for {
		draw(canvas, frame, stamps[:])
		ev, ok := nb.wait_event(33) // ~30 frames per second
		if !ok {
			frame += 1
			continue
		}
		#partial switch ev.kind {
		case .Click:
			if ev.handle == canvas {
				append(&stamps, Stamp{int(ev.a), int(ev.b)})
			}
		case .Quit:
			return
		}
	}
}

draw :: proc(canvas: nb.Handle, frame: int, stamps: []Stamp) {
	for y in 0 ..< H {
		for x in 0 ..< W {
			i := (y * W + x) * 4
			pixels[i + 0] = u8(x * 255 / W)
			pixels[i + 1] = u8(y * 255 / H)
			pixels[i + 2] = u8(160 + (x + y + frame * 2) % 96)
			pixels[i + 3] = 255
		}
	}
	nb.canvas_put_pixels(canvas, pixels[:])
	bar_x := (frame * 4) % (W + 40) - 40
	nb.canvas_fill_rect(canvas, bar_x, 0, 40, H, 0xFFFFFF60)
	for s in stamps {
		nb.canvas_fill_rect(canvas, s.x - 6, s.y - 6, 12, 12, 0x1F2328FF)
	}
}

@(export, link_name="_start")
_start :: proc "c" () -> ! {
	nb.start(main)
}
