package layout

import "../abi"
import "../host"

// Inline formatting: a Paragraph, Heading or List_Item whose children are
// all inline (Text, Link, Emphasis, Strong, Code, Image) flows its own text
// and theirs as one paragraph, wrapping at spaces across style changes. An
// Image is one unbreakable box on the line, like a word.
//
//
// The result is a list of fragments: a fragment is a contiguous slice of
// one node's text on one line, in one style. Every inline node still gets an
// Item (for hit testing, links, selection and find); its fragments are
// items[i].frag_first ..< frag_first + frag_count in Result.fragments. An
// Image's single fragment is its picture's box, with an empty byte range.

Fragment :: struct {
	item:       int, // the Item whose node owns the text
	start, end: int, // byte range in that node's text
	rect:       Rect,
	font:       Font,
	color:      Color,
	background: Color, // alpha 0 = none
}

// Does `n` start an inline formatting context?
is_inline_context :: proc(p: ^host.Page, n: ^host.Node) -> bool {
	#partial switch n.kind {
	case .Paragraph, .Heading, .List_Item, .Text, .Link, .Emphasis, .Strong, .Code:
	case:
		return false
	}
	if n.first_child == abi.INVALID_HANDLE {
		return false // plain text: the simple path wraps it in one piece
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

@(private)
Token :: struct {
	run:        int,
	start, end: int, // byte range in the run's text
	w, h:       f32,
	kind:       enum u8 {
		Word,
		Space,
		Newline,
	},
}

// Lays out the inline content of the node at item `idx` in a box `avail`
// wide at (x, y). Returns the size used.
@(private)
layout_inline :: proc(ctx: ^Context, n: ^host.Node, idx: int, x, y, avail: f32) -> (w, h: f32) {
	runs := make([dynamic]Run, context.temp_allocator)
	container_style := ctx.out.items[idx].style
	if len(n.text) > 0 {
		append(&runs, Run{idx, n.text, container_style, nil})
	}
	collect_runs(ctx, n, idx, container_style, &runs)

	tokens := make([dynamic]Token, context.temp_allocator)
	for run, ri in runs {
		tokenize(ctx, ri, run, avail, &tokens)
	}

	_, base_h := ctx.m.measure(ctx.m.data, "", container_style.font, 0)
	line_y := y
	line_x: f32
	line_h: f32
	line_start := len(ctx.out.fragments)
	pending_space := -1 // index of a space token waiting for the next word
	max_w: f32

	finish_line :: proc(ctx: ^Context, line_start: int, line_y: ^f32, line_h: ^f32, line_x: ^f32, base_h: f32) {
		hgt := line_h^ if line_h^ > 0 else base_h
		// Bottom-align fragments of different heights on the line (smaller
		// text sits on the same base as larger text).
		for &f in ctx.out.fragments[line_start:] {
			f.rect.y = line_y^ + hgt - f.rect.h
		}
		line_y^ += hgt
		line_h^ = 0
		line_x^ = 0
	}

	for t, ti in tokens {
		switch t.kind {
		case .Newline:
			finish_line(ctx, line_start, &line_y, &line_h, &line_x, base_h)
			line_start = len(ctx.out.fragments)
			pending_space = -1
		case .Space:
			if line_x > 0 {
				pending_space = ti
			}
		case .Word:
			space_w: f32 = 0
			if pending_space >= 0 {
				space_w = tokens[pending_space].w
			}
			if line_x > 0 && line_x + space_w + t.w > avail {
				finish_line(ctx, line_start, &line_y, &line_h, &line_x, base_h)
				line_start = len(ctx.out.fragments)
				pending_space = -1
				space_w = 0
			}
			if pending_space >= 0 {
				place(ctx, runs[:], tokens[pending_space], x + line_x, line_start)
				line_x += space_w
			}
			place(ctx, runs[:], t, x + line_x, line_start)
			line_x += t.w
			line_h = max(line_h, t.h)
			max_w = max(max_w, line_x)
			pending_space = -1
		}
	}
	if len(ctx.out.fragments) > line_start || line_x > 0 {
		finish_line(ctx, line_start, &line_y, &line_h, &line_x, base_h)
	}

	// Each inline item's box is the bounding box of its fragments.
	for run in runs {
		item := &ctx.out.items[run.item]
		if item.frag_count == 0 {
			continue
		}
		first := ctx.out.fragments[item.frag_first]
		bounds := first.rect
		for f in ctx.out.fragments[item.frag_first:][:item.frag_count] {
			x1 := max(bounds.x + bounds.w, f.rect.x + f.rect.w)
			y1 := max(bounds.y + bounds.h, f.rect.y + f.rect.h)
			bounds.x = min(bounds.x, f.rect.x)
			bounds.y = min(bounds.y, f.rect.y)
			bounds.w, bounds.h = x1 - bounds.x, y1 - bounds.y
		}
		item.text_rect = first.rect
		if run.item != idx {
			item.rect = bounds
		}
	}
	return max_w, line_y - y
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

@(private)
tokenize :: proc(ctx: ^Context, ri: int, run: Run, avail: f32, out: ^[dynamic]Token) {
	if run.image != nil {
		size := image_size(run.image, avail)
		append(out, Token{run = ri, w = size.x, h = size.y, kind = .Word})
		return
	}
	text := run.text
	for i := 0; i < len(text); {
		c := text[i]
		switch {
		case c == '\n':
			append(out, Token{run = ri, start = i, end = i + 1, kind = .Newline})
			i += 1
		case c == ' ' || c == '\t':
			j := i
			for j < len(text) && (text[j] == ' ' || text[j] == '\t') {
				j += 1
			}
			// A run of spaces collapses to one space's width.
			w, h := ctx.m.measure(ctx.m.data, " ", run.style.font, 0)
			append(out, Token{run = ri, start = i, end = j, w = w, h = h, kind = .Space})
			i = j
		case:
			j := i
			for j < len(text) && text[j] != ' ' && text[j] != '\t' && text[j] != '\n' {
				j += 1
			}
			w, h := ctx.m.measure(ctx.m.data, text[i:j], run.style.font, 0)
			append(out, Token{run = ri, start = i, end = j, w = w, h = h, kind = .Word})
			i = j
		}
	}
}

// Adds a token to the current line, extending the previous fragment when it
// continues the same run.
@(private)
place :: proc(ctx: ^Context, runs: []Run, t: Token, x: f32, line_start: int) {
	run := runs[t.run]
	frags := &ctx.out.fragments
	if n := len(frags); n > line_start {
		last := &frags[n - 1]
		if last.item == run.item && last.end == t.start {
			last.end = t.end
			last.rect.w = x + t.w - last.rect.x
			last.rect.h = max(last.rect.h, t.h)
			return
		}
	}
	item := &ctx.out.items[run.item]
	if item.frag_count == 0 {
		item.frag_first = len(frags)
	}
	item.frag_count += 1
	append(frags, Fragment {
		item       = run.item,
		start      = t.start,
		end        = t.end,
		rect       = {x, 0, t.w, t.h},
		font       = run.style.font,
		color      = run.style.color,
		background = run.style.background,
	})
}
