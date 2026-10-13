package layout

import "../abi"
import "../host"

// Inline formatting: a Paragraph, Heading or List_Item whose children are
// all inline (Text, Link, Emphasis, Strong, Code, Image) flows its own text
// and theirs as one paragraph (para.odin), breaking lines where Unicode
// allows across style changes. An Image is one unbreakable box on the line,
// like a word. A node with block children lays out its own text the same
// way, alone.
//
// The result is a list of fragments: a fragment is a contiguous slice of
// one node's text on one line, in one style and one direction. Fragments
// are stored in logical order; their rectangles are in visual order. Every
// inline node still gets an Item (for hit testing, links, selection and
// find); its fragments are items[i].frag_first ..< frag_first + frag_count
// in Result.fragments. An Image's single fragment is its picture's box,
// with an empty byte range.

Fragment :: struct {
	item:       int, // the Item whose node owns the text
	start, end: int, // byte range in that node's text
	rect:       Rect,
	font:       Font,
	color:      Color,
	background: Color, // alpha 0 = none
	rtl:        bool,  // runs right to left
}

// Does `n` start an inline formatting context?
is_inline_context :: proc(p: ^host.Page, n: ^host.Node) -> bool {
	#partial switch n.kind {
	case .Paragraph, .Heading, .List_Item, .Text, .Link, .Emphasis, .Strong, .Code:
	case:
		return false
	}
	return all_inline(p, n)
}

@(private)
all_inline :: proc(p: ^host.Page, n: ^host.Node) -> bool {
	for c := n.first_child; c != abi.INVALID_HANDLE; {
		child := host.node_get(p, c)
		if child == nil || !is_inline_kind(child.kind) || !all_inline(p, child) {
			return false
		}
		c = child.next
	}
	return true
}

@(private)
Run :: struct {
	item:  int,
	text:  string,
	style: Style,
	image: ^host.Node, // set for an Image, which has no text
}

// Lays out the node at item `idx`'s own text, and with `children` its
// inline children's too, as one paragraph in a box `avail` wide at (x, y).
// Right-to-left paragraphs are aligned to the right of `avail` when `fill`,
// else of the widest line. Returns the size used.
@(private)
layout_inline :: proc(ctx: ^Context, n: ^host.Node, idx: int, x, y, avail: f32, children, fill: bool) -> (w, h: f32) {
	runs := make([dynamic]Run, context.temp_allocator)
	container_style := ctx.out.items[idx].style
	if len(n.text) > 0 {
		append(&runs, Run{idx, n.text, container_style, nil})
	}
	if children {
		collect_runs(ctx, n, idx, container_style, &runs)
	}

	// One string for the whole paragraph, so breaks and directions are
	// found across style changes. An Image stands in as U+FFFC.
	sb := make([dynamic]u8, context.temp_allocator)
	pruns := make([]Para_Run, len(runs), context.temp_allocator)
	for run, ri in runs {
		pr := Para_Run{start = len(sb), font = run.style.font}
		if run.image != nil {
			append(&sb, OBJECT_TEXT)
			pr.object = image_size(run.image, avail)
			pr.is_object = true
		} else {
			append(&sb, run.text)
		}
		pr.end = len(sb)
		pruns[ri] = pr
	}

	_, base_h := ctx.m.measure(ctx.m.data, "", container_style.font, 0)
	para: Para
	para.segs.allocator = context.temp_allocator
	para.lines.allocator = context.temp_allocator
	para_layout(ctx.m, string(sb[:]), pruns, {wrap = avail, dir = container_style.text_dir, line_h = base_h}, &para)
	para_align(&para, avail if fill else para.width)
	ctx.out.items[idx].rtl = para.rtl

	// Segments are in logical order, so each item's fragments stay together.
	for sg in para.segs {
		run := runs[sg.run]
		item := &ctx.out.items[run.item]
		if item.frag_count == 0 {
			item.frag_first = len(ctx.out.fragments)
		}
		item.frag_count += 1
		font := run.style.font
		font.rtl = sg.rtl
		start, end := 0, 0
		if run.image == nil {
			start, end = sg.start - pruns[sg.run].start, sg.end - pruns[sg.run].start
		}
		r := sg.rect
		r.x += x
		r.y += y
		append(&ctx.out.fragments, Fragment {
			item       = run.item,
			start      = start,
			end        = end,
			rect       = r,
			font       = font,
			color      = run.style.color,
			background = run.style.background,
			rtl        = sg.rtl,
		})
	}

	// Each inline item's box is the bounding box of its fragments.
	for run in runs {
		item := &ctx.out.items[run.item]
		if item.frag_count == 0 {
			continue
		}
		bounds := ctx.out.fragments[item.frag_first].rect
		for f in ctx.out.fragments[item.frag_first:][:item.frag_count] {
			x1 := max(bounds.x + bounds.w, f.rect.x + f.rect.w)
			y1 := max(bounds.y + bounds.h, f.rect.y + f.rect.h)
			bounds.x = min(bounds.x, f.rect.x)
			bounds.y = min(bounds.y, f.rect.y)
			bounds.w, bounds.h = x1 - bounds.x, y1 - bounds.y
		}
		item.text_rect = bounds
		if run.item != idx {
			item.rect = bounds
		}
	}
	return para.width, para.height
}

@(private)
collect_runs :: proc(ctx: ^Context, n: ^host.Node, parent_idx: int, parent_style: Style, runs: ^[dynamic]Run) {
	for c := n.first_child; c != abi.INVALID_HANDLE; {
		child := host.node_get(ctx.page, c)
		st := inline_style(child, parent_style, ctx.theme)
		ci := len(ctx.out.items)
		append(&ctx.out.items, Item {
			handle      = c,
			kind        = child.kind,
			style       = st,
			text        = child.text,
			href        = child.attrs[.Href] or_else "",
			alt         = child.attrs[.Alt] or_else "",
			parent      = parent_idx,
			inline_root = ctx.out.items[parent_idx].inline_root if ctx.out.items[parent_idx].inline_root >= 0 else parent_idx,
		})
		if child.kind == .Image {
			append(runs, Run{ci, "", st, child}) // its children, if any, are not shown
		} else {
			if len(child.text) > 0 {
				append(runs, Run{ci, child.text, st, nil})
			}
			collect_runs(ctx, child, ci, st, runs)
		}
		c = child.next
	}
}
