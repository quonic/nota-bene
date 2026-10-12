// Images: pictures embedded in the page with #load and handed to the
// browser, which decodes and draws them. Shows block and inline images,
// scaling, an image link and the placeholder for an image with no picture.
// The pictures are made by tests/images/make_images.py (./build.sh images).
package main

import nb "../../sdk/nb"

PHOTO :: #load("photo.jpg")
ICON  :: #load("icon.png")

image :: proc(parent: nb.Handle, data: []u8, alt: string) -> nb.Handle {
	img := nb.el(.Image, parent)
	nb.set_attr(img, .Alt, alt)
	if err := nb.image_set_data(img, data); err != .OK {
		nb.log("could not decode an image", .Warn)
	}
	return img
}

main :: proc() {
	root := nb.el(.Box)
	nb.set_attr(root, .Gap, "14")
	title := nb.el(.Heading, root, "Images")
	nb.set_attr(title, .Level, "1")

	nb.el(.Paragraph, root, "A JPEG at its own size, 320 by 200 pixels:")
	image(root, PHOTO, "Circles over a blue to orange gradient")

	p := nb.el(.Paragraph, root, "Images flow inside text: here is an icon ")
	image(p, ICON, "red dot")
	nb.el(.Text, p, " in the middle of a sentence, and it wraps with the words around it like any other word. ")
	nb.el(.Text, p, "Inside a link, the icon is part of what you click: ")
	link := nb.el(.Link, p, "back to hello ")
	nb.set_attr(link, .Href, "hello.elf")
	image(link, ICON, "")
	nb.el(.Text, p, ".")

	row := nb.el(.Box, root)
	nb.set_attr(row, .Direction, "row")
	nb.set_attr(row, .Gap, "12")
	small := image(row, PHOTO, "The same picture, 160 wide")
	nb.set_attr(small, .Width, "160")
	tall := image(row, PHOTO, "The same picture, 60 tall")
	nb.set_attr(tall, .Height, "60")
	big := image(row, ICON, "The icon, 48 by 48")
	nb.set_attr(big, .Width, "48")

	nb.el(.Paragraph, root, "An Image the page has not given a picture shows its alt text:")
	missing := nb.el(.Image, root)
	nb.set_attr(missing, .Alt, "A picture still on its way")

	nb.set_root(root)
	for {
		ev, ok := nb.wait_event()
		if ok && ev.kind == .Quit {
			return
		}
	}
}

@(export, link_name="_start")
_start :: proc "c" () -> ! { nb.start(main) }
