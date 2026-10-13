// Package layout turns a page's view tree into positioned boxes.
//
// The model is deliberately small: every node is a block; a block stacks its
// children in a column, or flows them in a wrapping row. Nodes in a column
// fill the available width; nodes in a row shrink to their content. Text is
// wrapped to the block's inner width. Text measurement is supplied by the
// caller, so layout runs (and is tested) without any graphics library.
package layout

import "../abi"
import "../host"

Rect :: struct {
	x, y, w, h: f32,
}

rect_contains :: proc "contextless" (r: Rect, x, y: f32) -> bool {
	return x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h
}

// Returns the size of `text` set in `font`, wrapped at `wrap_width`
// (0 = wrap only at newlines). An empty string returns the line height.
Measure_Proc :: #type proc(data: rawptr, text: string, font: Font, wrap_width: f32) -> (w, h: f32)

Measurer :: struct {
	data:    rawptr,
	measure: Measure_Proc,
}

// One laid-out node. Items are stored in pre-order, so a node's descendants
// follow it, and later items paint over earlier ones.
Item :: struct {
	handle:    abi.Handle,
	kind:      abi.Node_Kind,
	rect:      Rect,   // border box, document coordinates
	text_rect: Rect,   // text (or canvas/image content) box
	text:      string, // borrowed from the node: valid until the tree changes
	wrap:      f32,    // Text_Area: the width its text wraps at
	style:     Style,
	href:      string,
	alt:       string,
	parent:    int,    // index of the parent item, -1 for the root

	// Inline layout (inline.odin). Items with fragments draw their text as
	// those fragments instead of as one wrapped block.
	frag_first:  int,
	frag_count:  int,
	inline_root: int,  // the item whose inline context this item flows in, or -1
	rtl:         bool, // its text forms a right-to-left paragraph
}

Result :: struct {
	items:     [dynamic]Item,
	fragments: [dynamic]Fragment,
	width:  f32, // document size
	height: f32,
}

VIEWPORT_MARGIN :: 16

// The size of an Image with no picture yet.
IMAGE_PLACEHOLDER :: [2]f32{120, 80}

// How many lines tall a Text_Area is without a Height attribute.
TEXT_AREA_LINES :: 4

@(private)
Context :: struct {
	page:  ^host.Page,
	m:     Measurer,
	theme: Theme,
	out:   ^Result,
}

result_destroy :: proc(r: ^Result) {
	delete(r.items)
	delete(r.fragments)
	r^ = {}
}

// Lays out the page's tree for a viewport `viewport_w` px wide.
layout :: proc(p: ^host.Page, viewport_w: f32, m: Measurer, theme: Theme, out: ^Result) {
	clear(&out.items)
	clear(&out.fragments)
	out.width, out.height = viewport_w, 0
	if p.root == abi.INVALID_HANDLE {
		return
	}
	ctx := Context{page = p, m = m, theme = theme, out = out}
	avail := max(viewport_w - 2 * VIEWPORT_MARGIN, 1)
	w, h := layout_node(&ctx, p.root, -1, VIEWPORT_MARGIN, VIEWPORT_MARGIN, avail, true)
	out.width = max(viewport_w, w + 2 * VIEWPORT_MARGIN)
	out.height = h + 2 * VIEWPORT_MARGIN
}

// Index of the deepest item under (x, y) in document coordinates, or -1.
// Inline items are hit only on their fragments, not their whole bounding box.
hit_test :: proc(r: ^Result, x, y: f32) -> int {
	#reverse for item, i in r.items {
		if item.frag_count > 0 && item.inline_root >= 0 {
			for f in r.fragments[item.frag_first:][:item.frag_count] {
				if rect_contains(f.rect, x, y) {
					return i
				}
			}
			continue
		}
		if rect_contains(item.rect, x, y) {
			return i
		}
	}
	return -1
}

// Index of the nearest item at or above `index` whose kind is in `kinds`, or -1.
find_ancestor :: proc(r: ^Result, index: int, kinds: bit_set[abi.Node_Kind]) -> int {
	for i := index; i >= 0; i = r.items[i].parent {
		if r.items[i].kind in kinds {
			return i
		}
	}
	return -1
}

@(private)
layout_node :: proc(ctx: ^Context, h: abi.Handle, parent: int, x, y, avail: f32, fill: bool) -> (f32, f32) {
	n := host.node_get(ctx.page, h)
	if n == nil {
		return 0, 0
	}
	st := style_for(n, ctx.theme)
	if .Dir not_in n.attrs && parent >= 0 {
		st.text_dir = ctx.out.items[parent].style.text_dir
	}
	idx := len(ctx.out.items)
	append(&ctx.out.items, Item {
		handle = h,
		kind   = n.kind,
		style  = st,
		href   = n.attrs[.Href] or_else "",
		alt    = n.attrs[.Alt] or_else "",
		parent = parent,
		inline_root = -1,
	})

	pad := st.padding
	outer_w: f32 = -1
	if fw, ok := st.width.?; ok {
		outer_w = min(fw, avail)
	} else if fill {
		outer_w = avail
	}
	inner := max((outer_w if outer_w >= 0 else avail) - 2 * pad - st.indent, 1)
	cx := x + pad + st.indent
	if st.text_dir == .Rtl {
		cx = x + pad // a right-to-left list is indented on the right
	}
	cy := y + pad
	content_w: f32
	text_rect: Rect
	wrap: f32

	#partial switch n.kind {
	case .Input:
		// Single line; the text scrolls inside the box rather than wrapping.
		_, line_h := ctx.m.measure(ctx.m.data, "", st.font, 0)
		tw, _ := ctx.m.measure(ctx.m.data, n.text, st.font, 0)
		text_rect = {cx, cy, tw, line_h}
		content_w = inner
		cy += line_h

	case .Text_Area:
		// Wraps at the box width. The box is a fixed number of lines tall
		// (or Height); longer text scrolls inside it.
		_, line_h := ctx.m.measure(ctx.m.data, "", st.font, 0)
		_, th := ctx.m.measure(ctx.m.data, n.text, st.font, inner)
		text_rect = {cx, cy, inner, max(th, line_h)}
		wrap = inner
		content_w = inner
		cy += TEXT_AREA_LINES * line_h

	case .Canvas:
		cw, ch := host.canvas_wanted_size(n)
		outer_w = f32(cw) + 2 * pad // a canvas is always its pixel size
		text_rect = {cx, cy, f32(cw), f32(ch)}
		content_w = f32(cw)
		cy += f32(ch)

	case .Image:
		size := image_size(n, avail - 2 * pad)
		outer_w = size.x + 2 * pad
		text_rect = {cx, cy, size.x, size.y}
		content_w = size.x
		cy += size.y

	case:
		if is_inline_context(ctx.page, n) {
			iw, ih := layout_inline(ctx, n, idx, cx, cy, inner, true, outer_w >= 0)
			content_w = iw
			cy += ih
			text_rect = ctx.out.items[idx].text_rect
			break
		}
		has_text := len(n.text) > 0
		if has_text {
			tw, th := layout_inline(ctx, n, idx, cx, cy, inner, false, outer_w >= 0)
			text_rect = ctx.out.items[idx].text_rect
			content_w = tw
			cy += th
		}
		if n.first_child != abi.INVALID_HANDLE && has_text {
			cy += st.gap
		}
		switch st.direction {
		case .Column:
			first := true
			for c := n.first_child; c != abi.INVALID_HANDLE; c = host.node_get(ctx.page, c).next {
				if !first {
					cy += st.gap
				}
				cw, ch := layout_node(ctx, c, idx, cx, cy, inner, true)
				cy += ch
				content_w = max(content_w, cw)
				first = false
			}
		case .Row:
			// Children on a line are centred vertically once the line is complete.
			Placed :: struct {
				first, end: int,
				h:          f32,
			}
			line := make([dynamic]Placed, context.temp_allocator)
			finish_line :: proc(ctx: ^Context, line: ^[dynamic]Placed, line_h: f32) {
				for pl in line {
					if dy := (line_h - pl.h) / 2; dy > 0 {
						shift_items(ctx.out, pl.first, pl.end, dy)
					}
				}
				clear(line)
			}
			line_x, line_y, line_h := cx, cy, f32(0)
			for c := n.first_child; c != abi.INVALID_HANDLE; c = host.node_get(ctx.page, c).next {
				gap_x := st.gap if line_x > cx else 0
				remaining := cx + inner - (line_x + gap_x)
				start := len(ctx.out.items)
				// Measure at full line width to learn the child's natural size.
				cw, ch := layout_node(ctx, c, idx, line_x + gap_x, line_y, inner, false)
				if line_x > cx && cw > remaining {
					// Does not fit: start a new line.
					resize(&ctx.out.items, start)
					finish_line(ctx, &line, line_h)
					line_y += line_h + st.gap
					line_h = 0
					cw, ch = layout_node(ctx, c, idx, cx, line_y, inner, false)
					line_x = cx + cw
				} else {
					line_x += gap_x + cw
				}
				append(&line, Placed{start, len(ctx.out.items), ch})
				line_h = max(line_h, ch)
				content_w = max(content_w, line_x - cx)
			}
			finish_line(ctx, &line, line_h)
			cy = line_y + line_h
		}
	}

	w := outer_w if outer_w >= 0 else content_w + 2 * pad + st.indent
	hgt := st.height.? or_else (cy - y + pad)
	if n.kind == .Canvas || n.kind == .Image {
		hgt = cy - y + pad // Width/Height already sized the content
	}
	item := &ctx.out.items[idx]
	item.rect = {x, y, w, hgt}
	item.text_rect = text_rect
	item.text = n.text
	item.wrap = wrap
	return w, hgt
}

// The size an Image is drawn at: its picture's size in pixels (or the
// placeholder's), unless Width or Height says otherwise. With only one of
// them set, the other follows the aspect ratio. An image wider than `avail`
// is scaled down to fit.
image_size :: proc(n: ^host.Node, avail: f32) -> [2]f32 {
	size := IMAGE_PLACEHOLDER
	if n.bitmap.pixels != nil {
		size = {f32(n.bitmap.width), f32(n.bitmap.height)}
	}
	px :: proc(n: ^host.Node, attr: abi.Attr) -> (f32, bool) {
		s, ok := n.attrs[attr]
		if !ok {
			return 0, false
		}
		return parse_px(s)
	}
	w, has_w := px(n, .Width)
	h, has_h := px(n, .Height)
	switch {
	case has_w && has_h:
		size = {w, h}
	case has_w:
		size = {w, size.y * w / size.x}
	case has_h:
		size = {size.x * h / size.y, h}
	}
	if size.x > avail {
		size = {max(avail, 0), size.y * max(avail, 0) / size.x}
	}
	return size
}

@(private)
shift_items :: proc(r: ^Result, first, end: int, dy: f32) {
	for &item in r.items[first:end] {
		item.rect.y += dy
		item.text_rect.y += dy
		for &f in r.fragments[item.frag_first:][:item.frag_count] {
			f.rect.y += dy
		}
	}
}
