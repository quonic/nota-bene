package layout_test

import "core:strings"
import "core:testing"

import "../../src/abi"
import "../../src/host"
import "../../src/layout"

// Fixed-pitch measurer: every character is size/2 wide, lines are size*1.25
// tall, greedy word wrap. Makes expected positions easy to compute by hand.
fake_measure :: proc(data: rawptr, text: string, font: layout.Font, wrap_width: f32) -> (w, h: f32) {
	cw := font.size / 2
	lh := font.size * 1.25
	if len(text) == 0 {
		return 0, lh
	}
	if wrap_width <= 0 {
		return f32(len(text)) * cw, lh // one line, spaces count like any character
	}
	lines := 1
	line_w, max_w: f32
	words := strings.split(text, " ", context.temp_allocator)
	for word, i in words {
		ww := f32(len(word)) * cw
		add := ww if line_w == 0 else line_w + cw + ww
		if wrap_width > 0 && line_w > 0 && add > wrap_width {
			max_w = max(max_w, line_w)
			lines += 1
			line_w = ww
		} else {
			line_w = add
		}
		_ = i
	}
	max_w = max(max_w, line_w)
	return max_w, f32(lines) * lh
}

M :: layout.Measurer{measure = fake_measure}

new_page :: proc(p: ^host.Page) {
	p.allocator = context.allocator
	host.handle_table_init(&p.handles, 1000)
}

node :: proc(p: ^host.Page, kind: abi.Node_Kind, parent := abi.INVALID_HANDLE, text := "") -> abi.Handle {
	h, _ := host.node_create(p, kind)
	if len(text) > 0 {
		host.node_set_text(p, h, text)
	}
	if parent != abi.INVALID_HANDLE {
		host.node_append(p, parent, h)
	}
	return h
}

expect_rect :: proc(t: ^testing.T, got: layout.Rect, want: layout.Rect, what: string, loc := #caller_location) {
	testing.expectf(t, got == want, "%s: got %v, want %v", what, got, want, loc = loc)
}

@(test)
test_column :: proc(t: ^testing.T) {
	p: host.Page
	new_page(&p)
	defer host.page_destroy(&p)
	root := node(&p, .Box)
	host.node_set_attr(&p, root, .Gap, "10")
	node(&p, .Paragraph, root, "hello")
	node(&p, .Paragraph, root, "world")
	p.root = root

	r: layout.Result
	defer layout.result_destroy(&r)
	layout.layout(&p, 400, M, layout.DEFAULT_THEME, &r)

	testing.expect_value(t, len(r.items), 3)
	expect_rect(t, r.items[0].rect, {16, 16, 368, 50}, "root")
	expect_rect(t, r.items[1].rect, {16, 16, 368, 20}, "first paragraph")
	expect_rect(t, r.items[1].text_rect, {16, 16, 40, 20}, "first text")
	expect_rect(t, r.items[2].rect, {16, 46, 368, 20}, "second paragraph")
	testing.expect_value(t, r.height, 50 + 32)
}

@(test)
test_text_wraps :: proc(t: ^testing.T) {
	p: host.Page
	new_page(&p)
	defer host.page_destroy(&p)
	p.root = node(&p, .Paragraph, text = "aaaa bbbb cccc")

	r: layout.Result
	defer layout.result_destroy(&r)
	layout.layout(&p, 72 + 32, M, layout.DEFAULT_THEME, &r)
	expect_rect(t, r.items[0].text_rect, {16, 16, 72, 40}, "wrapped text")
	testing.expect_value(t, r.items[0].wrap, 72)
}

@(test)
test_row_wraps :: proc(t: ^testing.T) {
	p: host.Page
	new_page(&p)
	defer host.page_destroy(&p)
	row := node(&p, .Box)
	host.node_set_attr(&p, row, .Direction, "row")
	host.node_set_attr(&p, row, .Gap, "4")
	for _ in 0 ..< 3 {
		node(&p, .Button, row, "abc") // 24 + 2*8 padding = 40 wide, 20 + 16 = 36 tall
	}
	p.root = row

	r: layout.Result
	defer layout.result_destroy(&r)
	layout.layout(&p, 100 + 32, M, layout.DEFAULT_THEME, &r)
	expect_rect(t, r.items[1].rect, {16, 16, 40, 36}, "button 1")
	expect_rect(t, r.items[2].rect, {60, 16, 40, 36}, "button 2")
	expect_rect(t, r.items[3].rect, {16, 56, 40, 36}, "button 3 (wrapped)")
	expect_rect(t, r.items[3].text_rect, {24, 64, 24, 20}, "button 3 text")
	expect_rect(t, r.items[0].rect, {16, 16, 100, 76}, "row")
}

@(test)
test_hit_test :: proc(t: ^testing.T) {
	p: host.Page
	new_page(&p)
	defer host.page_destroy(&p)
	root := node(&p, .Box)
	para := node(&p, .Paragraph, root)
	link := node(&p, .Link, para, "go")
	host.node_set_attr(&p, link, .Href, "next.elf")
	p.root = root

	r: layout.Result
	defer layout.result_destroy(&r)
	layout.layout(&p, 400, M, layout.DEFAULT_THEME, &r)

	i := layout.hit_test(&r, 20, 20)
	testing.expect_value(t, r.items[i].handle, link)
	testing.expect_value(t, r.items[i].href, "next.elf")
	testing.expect_value(t, layout.hit_test(&r, 2, 2), -1)
	testing.expect_value(t, layout.find_ancestor(&r, i, {.Paragraph}), 1)
	testing.expect_value(t, layout.find_ancestor(&r, i, {.Button}), -1)
}

@(test)
test_canvas_and_input :: proc(t: ^testing.T) {
	p: host.Page
	new_page(&p)
	defer host.page_destroy(&p)
	root := node(&p, .Box)
	c := node(&p, .Canvas, root)
	host.node_set_attr(&p, c, .Width, "64")
	host.node_set_attr(&p, c, .Height, "99999") // clamped
	node(&p, .Input, root, "hi")
	p.root = root

	r: layout.Result
	defer layout.result_destroy(&r)
	layout.layout(&p, 400, M, layout.DEFAULT_THEME, &r)
	expect_rect(t, r.items[1].rect, {16, 16, 64, abi.MAX_CANVAS_DIM}, "canvas")
	input := r.items[2]
	expect_rect(t, input.rect, {16, 16 + abi.MAX_CANVAS_DIM, 260, 36}, "input")
	expect_rect(t, input.text_rect, {24, 24 + abi.MAX_CANVAS_DIM, 16, 20}, "input text")
}

@(test)
test_text_area :: proc(t: ^testing.T) {
	p: host.Page
	new_page(&p)
	defer host.page_destroy(&p)
	root := node(&p, .Box)
	node(&p, .Text_Area, root, strings.repeat("word ", 60, context.temp_allocator))
	sized := node(&p, .Text_Area, root, "hi")
	host.node_set_attr(&p, sized, .Height, "50")
	p.root = root

	r: layout.Result
	defer layout.result_destroy(&r)
	layout.layout(&p, 400, M, layout.DEFAULT_THEME, &r)
	area := r.items[1]
	// Four 20px lines plus padding, however long the text is.
	expect_rect(t, area.rect, {16, 16, 260, 4 * 20 + 16}, "text area")
	testing.expect_value(t, area.wrap, 244)
	testing.expect_value(t, area.text_rect.w, 244)
	testing.expect(t, area.text_rect.h > 4 * 20, "the text is taller than the box")
	expect_rect(t, r.items[2].rect, {16, 16 + 96, 260, 50}, "text area with Height")
}

@(test)
test_styles :: proc(t: ^testing.T) {
	p: host.Page
	new_page(&p)
	defer host.page_destroy(&p)
	h := node(&p, .Heading)
	host.node_set_attr(&p, h, .Level, "2")
	host.node_set_attr(&p, h, .Color, "#336699")
	host.node_set_attr(&p, h, .Padding, "not a number")
	host.node_set_attr(&p, h, .Background, "#abc")
	st := layout.style_for(host.node_get(&p, h), layout.DEFAULT_THEME)
	testing.expect_value(t, st.font.size, 26)
	testing.expect(t, st.font.bold)
	testing.expect_value(t, st.color, layout.Color{0x33, 0x66, 0x99, 0xFF})
	testing.expect_value(t, st.background, layout.Color{0xAA, 0xBB, 0xCC, 0xFF})
	testing.expect_value(t, st.padding, 0)

	_, ok := layout.parse_color("#12345")
	testing.expect(t, !ok)
	c, ok2 := layout.parse_color("#11223380")
	testing.expect(t, ok2)
	testing.expect_value(t, c, layout.Color{0x11, 0x22, 0x33, 0x80})
}

@(test)
test_row_centres_vertically :: proc(t: ^testing.T) {
	p: host.Page
	new_page(&p)
	defer host.page_destroy(&p)
	row := node(&p, .Box)
	host.node_set_attr(&p, row, .Direction, "row")
	node(&p, .Button, row, "ok")   // 36 tall
	node(&p, .Text, row, "label")  // 20 tall: centred, 8 px down
	p.root = row

	r: layout.Result
	defer layout.result_destroy(&r)
	layout.layout(&p, 400, M, layout.DEFAULT_THEME, &r)
	expect_rect(t, r.items[2].rect, {48, 24, 40, 20}, "label")
	expect_rect(t, r.items[2].text_rect, {48, 24, 40, 20}, "label text")
	testing.expect_value(t, r.items[0].rect.h, 36)
}

// "Read the " + Link("big manual") + " now." in a box 13 characters wide
// (8 px each at size 16) wraps across the link:
//   "Read the big"
//   "manual now."
@(test)
test_inline_flow :: proc(t: ^testing.T) {
	p: host.Page
	new_page(&p)
	defer host.page_destroy(&p)
	para := node(&p, .Paragraph, text = "Read the ")
	link := node(&p, .Link, para, "big manual")
	host.node_set_attr(&p, link, .Href, "manual.elf")
	node(&p, .Text, para, " now.")
	p.root = para

	r: layout.Result
	defer layout.result_destroy(&r)
	layout.layout(&p, 13 * 8 + 32, M, layout.DEFAULT_THEME, &r)

	testing.expect_value(t, len(r.items), 3)
	testing.expect_value(t, len(r.fragments), 4)
	frag_text :: proc(r: ^layout.Result, f: layout.Fragment) -> string {
		return r.items[f.item].text[f.start:f.end]
	}
	want := []struct {
		text: string,
		rect: layout.Rect,
	}{
		{"Read the ", {16, 16, 72, 20}},
		{"big", {88, 16, 24, 20}},
		{"manual", {16, 36, 48, 20}},
		{" now.", {64, 36, 40, 20}},
	}
	for w, i in want {
		f := r.fragments[i]
		testing.expectf(t, frag_text(&r, f) == w.text, "fragment %d text %q, want %q", i, frag_text(&r, f), w.text)
		expect_rect(t, f.rect, w.rect, w.text)
	}
	// The link keeps its style and spans both lines; hit testing finds it on
	// its fragments but not in the gap beside "big".
	li := 1
	testing.expect_value(t, r.items[li].handle, link)
	testing.expect(t, r.fragments[1].font.underline)
	testing.expect_value(t, r.items[li].inline_root, 0)
	expect_rect(t, r.items[li].rect, {16, 16, 96, 40}, "link bounds")
	testing.expect_value(t, layout.hit_test(&r, 20, 40), li)
	testing.expect_value(t, layout.hit_test(&r, 20, 20), 0) // "Read" belongs to the paragraph
	expect_rect(t, r.items[0].rect, {16, 16, 104, 40}, "paragraph")
}

@(test)
test_inline_styles :: proc(t: ^testing.T) {
	p: host.Page
	new_page(&p)
	defer host.page_destroy(&p)
	h := node(&p, .Heading, text = "Big ")
	host.node_set_attr(&p, h, .Level, "1")
	em := node(&p, .Emphasis, h, "and ")
	node(&p, .Code, em, "code")
	p.root = h

	r: layout.Result
	defer layout.result_destroy(&r)
	layout.layout(&p, 800, M, layout.DEFAULT_THEME, &r)
	testing.expect_value(t, len(r.fragments), 3)
	f := r.fragments
	testing.expect(t, f[0].font.bold && f[0].font.size == 32, "heading text keeps the heading font")
	testing.expect(t, f[1].font.italic && f[1].font.bold && f[1].font.size == 32, "emphasis inherits size and weight")
	testing.expect(t, f[2].font.mono && f[2].font.italic && f[2].background.a > 0, "code nests inside emphasis")
	testing.expect_value(t, r.items[2].parent, 1)
}

@(test)
test_mixed_children_stay_blocks :: proc(t: ^testing.T) {
	p: host.Page
	new_page(&p)
	defer host.page_destroy(&p)
	para := node(&p, .Paragraph, text = "intro")
	node(&p, .Button, para, "ok") // not inline: the paragraph lays out blocks as before
	p.root = para

	r: layout.Result
	defer layout.result_destroy(&r)
	layout.layout(&p, 400, M, layout.DEFAULT_THEME, &r)
	testing.expect_value(t, len(r.fragments), 0)
	testing.expect_value(t, r.items[1].inline_root, -1)
}

@(test)
test_image_sizes :: proc(t: ^testing.T) {
	p: host.Page
	new_page(&p)
	defer host.page_destroy(&p)
	root := node(&p, .Box)
	PNG :: #load("../images/rgba.png") // 4x3
	sized :: proc(p: ^host.Page, root: abi.Handle, attr: abi.Attr = .Label, value := "") -> abi.Handle {
		img := node(p, .Image, root)
		host.node_set_image(p, img, PNG)
		if value != "" {
			host.node_set_attr(p, img, attr, value)
		}
		return img
	}
	node(&p, .Image, root)                // no picture: the placeholder
	sized(&p, root)                       // its own size
	sized(&p, root, .Width, "40")         // height follows
	sized(&p, root, .Height, "6")         // width follows
	both := sized(&p, root, .Width, "10") // both given: stretched
	host.node_set_attr(&p, both, .Height, "50")
	sized(&p, root, .Width, "1000")       // too wide: scaled down to fit
	p.root = root

	r: layout.Result
	defer layout.result_destroy(&r)
	layout.layout(&p, 400, M, layout.DEFAULT_THEME, &r)
	want := [][2]f32{layout.IMAGE_PLACEHOLDER, {4, 3}, {40, 30}, {8, 6}, {10, 50}, {368, 276}}
	for size, i in want {
		tr := r.items[i + 1].text_rect
		testing.expectf(t, tr.w == size.x && tr.h == size.y, "image %d: %vx%v, want %v", i, tr.w, tr.h, size)
		testing.expectf(t, r.items[i + 1].rect.h == size.y, "image %d box height %v", i, r.items[i + 1].rect.h)
	}
}

@(test)
test_inline_image :: proc(t: ^testing.T) {
	p: host.Page
	new_page(&p)
	defer host.page_destroy(&p)
	para := node(&p, .Paragraph, text = "ab ")
	img := node(&p, .Image, para)
	host.node_set_image(&p, img, #load("../images/rgba.png"))
	host.node_set_attr(&p, img, .Width, "40") // 40x30
	node(&p, .Text, para, " cd")
	p.root = para

	// 70 px wide: "ab", a space and the image fit on the first line; " cd" does not.
	r: layout.Result
	defer layout.result_destroy(&r)
	layout.layout(&p, 70 + 32, M, layout.DEFAULT_THEME, &r)

	testing.expect_value(t, len(r.items), 3)
	testing.expect_value(t, r.items[1].inline_root, 0)
	testing.expect_value(t, r.items[1].frag_count, 1)
	f := r.fragments[r.items[1].frag_first]
	expect_rect(t, f.rect, {16 + 24, 16, 40, 30}, "image fragment")
	testing.expect_value(t, f.start, f.end)
	expect_rect(t, r.items[1].text_rect, f.rect, "image box")
	// The image makes the first line 30 tall; text sits on its bottom.
	expect_rect(t, r.fragments[0].rect, {16, 16 + 10, 24, 20}, "ab")
	cd := r.fragments[r.items[2].frag_first]
	expect_rect(t, cd.rect, {16, 16 + 30, 16, 20}, "cd, wrapped")
	expect_rect(t, r.items[0].rect, {16, 16, 70, 50}, "paragraph")
}

@(test)
test_image_link :: proc(t: ^testing.T) {
	p: host.Page
	new_page(&p)
	defer host.page_destroy(&p)
	para := node(&p, .Paragraph, text = "see ")
	link := node(&p, .Link, para)
	host.node_set_attr(&p, link, .Href, "next.elf")
	img := node(&p, .Image, link) // the 120x80 placeholder, inline
	p.root = para

	r: layout.Result
	defer layout.result_destroy(&r)
	layout.layout(&p, 400, M, layout.DEFAULT_THEME, &r)
	i := layout.hit_test(&r, 16 + 32 + 60, 16 + 40)
	if !testing.expect(t, i >= 0) {
		return
	}
	testing.expect_value(t, r.items[i].handle, img)
	l := layout.find_ancestor(&r, i, {.Link})
	testing.expect(t, l >= 0 && r.items[l].href == "next.elf")
	testing.expect_value(t, layout.hit_test(&r, 16 + 32 + 130, 16 + 40), 0) // past the image: the paragraph
}
