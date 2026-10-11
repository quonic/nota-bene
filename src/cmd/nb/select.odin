package main

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

import "../../abi"
import "../../layout"

// A position in page text: a byte offset into a node's text. Positions name
// nodes by handle, so they survive re-layout.
Text_Pos :: struct {
	handle: abi.Handle,
	offset: int,
}

// Text ranges are painted in this order: selection, then find matches.
SELECTION_COLOR     :: layout.Color{0xC7, 0xDB, 0xFA, 0xFF}
MATCH_COLOR         :: layout.Color{0xFF, 0xE5, 0x8F, 0xFF}
CURRENT_MATCH_COLOR :: layout.Color{0xFF, 0xA9, 0x4D, 0xFF}

// Items whose text can be selected and searched: everything but Input
// (edited by the browser) and image alt text.
@(private="file")
is_text_item :: proc(item: ^layout.Item) -> bool {
	return len(item.text) > 0 && item.kind != .Input && item.kind != .Image && item.kind != .Canvas
}

item_index_of :: proc(b: ^Browser, h: abi.Handle) -> int {
	for item, i in b.lay.items {
		if item.handle == h {
			return i
		}
	}
	return -1
}

// The cached text object for an item, created if it has not been drawn yet.
item_text :: proc(b: ^Browser, item: ^layout.Item) -> ^Cached_Text {
	return cached_text(b, u64(item.handle), item.text, item.style.font, item.wrap)
}

// The cached text object for one inline fragment.
fragment_text :: proc(b: ^Browser, item: ^layout.Item, k: int) -> ^Cached_Text {
	f := b.lay.fragments[item.frag_first + k]
	return cached_text(b, KEY_FRAG_BASE + u64(item.frag_first + k), item.text[f.start:f.end], f.font, 0)
}

// Document-space rectangles covering bytes [start, end) of an item's text,
// one per line (per fragment, for inline text).
range_rects :: proc(b: ^Browser, item: ^layout.Item, start, end: int, allocator := context.temp_allocator) -> []layout.Rect {
	out := make([dynamic]layout.Rect, allocator)
	if start >= end {
		return out[:]
	}
	if item.frag_count > 0 {
		for f, k in b.lay.fragments[item.frag_first:][:item.frag_count] {
			s, e := max(start, f.start), min(end, f.end)
			if s >= e {
				continue
			}
			c := fragment_text(b, item, k)
			if c == nil {
				continue
			}
			for r in text_range_rects(b, c, s - f.start, e - f.start, {f.rect.x, f.rect.y}) {
				append(&out, r)
			}
		}
		return out[:]
	}
	c := item_text(b, item)
	if c == nil {
		return out[:]
	}
	for r in text_range_rects(b, c, start, end, {item.text_rect.x, item.text_rect.y}) {
		append(&out, r)
	}
	return out[:]
}

// Rectangles for bytes [start, end) of one text object drawn at `origin`.
@(private="file")
text_range_rects :: proc(b: ^Browser, c: ^Cached_Text, start, end: int, origin: [2]f32) -> []layout.Rect {
	out := make([dynamic]layout.Rect, context.temp_allocator)
	count: i32
	subs := ttf.GetTextSubStringsForRange(c.text, i32(start), i32(end - start), &count)
	if subs == nil {
		return out[:]
	}
	defer sdl.free(subs)
	line := i32(-1)
	for i in 0 ..< count {
		r := subs[i].rect
		x0 := origin.x + f32(r.x) / b.scale
		x1 := origin.x + f32(r.x + r.w) / b.scale
		y := origin.y + f32(r.y) / b.scale
		h := f32(r.h) / b.scale
		if subs[i].line_index == line && len(out) > 0 {
			last := &out[len(out) - 1]
			lx1 := max(last.x + last.w, x1)
			last.x = min(last.x, x0)
			last.w = lx1 - last.x
		} else {
			append(&out, layout.Rect{x0, y, x1 - x0, h})
			line = subs[i].line_index
		}
	}
	return out[:]
}

// The text position nearest a document point, if there is page text near it.
pos_at_point :: proc(b: ^Browser, x, y: f32) -> (Text_Pos, bool) {
	if pos, ok := fragment_pos_at_point(b, x, y); ok {
		return pos, true
	}
	// The last text item that starts at or above the point.
	best := -1
	for &item, i in b.lay.items {
		if !is_text_item(&item) {
			continue
		}
		if item.text_rect.y > y {
			break
		}
		best = i
		tr := item.text_rect
		if y < tr.y + tr.h && x < tr.x + tr.w {
			break // the point is on this item's lines
		}
	}
	if best < 0 {
		return {}, false
	}
	item := &b.lay.items[best]
	tr := item.text_rect
	if y >= tr.y + tr.h {
		return {item.handle, len(item.text)}, true // below the text: its end
	}
	c := item_text(b, item)
	if c == nil {
		return {item.handle, 0}, true
	}
	px := i32((x - tr.x) * b.scale)
	py := i32((max(y, tr.y) - tr.y) * b.scale)
	sub: ttf.SubString
	if !ttf.GetTextSubStringForPoint(c.text, px, py, &sub) {
		return {item.handle, 0}, true
	}
	offset := int(sub.offset)
	if px > sub.rect.x + sub.rect.w / 2 {
		offset += int(sub.length) // the right half of a character means after it
	}
	return {item.handle, clamp(offset, 0, len(item.text))}, true
}

// Inline text: the fragment on the line under the point, or the nearest one
// on that line when the point is beside the text.
@(private="file")
fragment_pos_at_point :: proc(b: ^Browser, x, y: f32) -> (Text_Pos, bool) {
	best := -1
	best_dx: f32 = max(f32)
	for f, i in b.lay.fragments {
		if y < f.rect.y || y >= f.rect.y + f.rect.h {
			continue
		}
		dx: f32 = 0
		if x < f.rect.x {
			dx = f.rect.x - x
		} else if x >= f.rect.x + f.rect.w {
			dx = x - (f.rect.x + f.rect.w)
		}
		if dx < best_dx {
			best, best_dx = i, dx
		}
	}
	if best < 0 {
		return {}, false
	}
	f := b.lay.fragments[best]
	item := &b.lay.items[f.item]
	if x <= f.rect.x {
		return {item.handle, f.start}, true
	}
	if x >= f.rect.x + f.rect.w {
		return {item.handle, f.end}, true
	}
	c := fragment_text(b, item, best - item.frag_first)
	if c == nil {
		return {item.handle, f.start}, true
	}
	px := i32((x - f.rect.x) * b.scale)
	sub: ttf.SubString
	if !ttf.GetTextSubStringForPoint(c.text, px, 0, &sub) {
		return {item.handle, f.start}, true
	}
	offset := int(sub.offset)
	if px > sub.rect.x + sub.rect.w / 2 {
		offset += int(sub.length)
	}
	return {item.handle, clamp(f.start + offset, f.start, f.end)}, true
}

// Selection endpoints in document order, as item indices and offsets.
selection_span :: proc(b: ^Browser) -> (a_item, a_off, z_item, z_off: int, ok: bool) {
	if !b.has_selection {
		return
	}
	ai := item_index_of(b, b.sel_anchor.handle)
	fi := item_index_of(b, b.sel_focus.handle)
	if ai < 0 || fi < 0 {
		return
	}
	a_off = min(b.sel_anchor.offset, len(b.lay.items[ai].text))
	f_off := min(b.sel_focus.offset, len(b.lay.items[fi].text))
	if ai < fi || (ai == fi && a_off <= f_off) {
		return ai, a_off, fi, f_off, true
	}
	return fi, f_off, ai, a_off, true
}

// The selected part of item `i`, as a byte range.
selected_range :: proc(b: ^Browser, i: int) -> (start, end: int, ok: bool) {
	ai, ao, zi, zo := selection_span(b) or_return
	if i < ai || i > zi || !is_text_item(&b.lay.items[i]) {
		return
	}
	start = ao if i == ai else 0
	end = zo if i == zi else len(b.lay.items[i].text)
	return start, end, start < end
}

draw_highlights :: proc(b: ^Browser, index: int, dy: f32) {
	item := &b.lay.items[index]
	if !is_text_item(item) {
		return
	}
	paint :: proc(b: ^Browser, item: ^layout.Item, start, end: int, dy: f32, color: layout.Color) {
		for r in range_rects(b, item, start, end) {
			fill_rect(b, {r.x, r.y + dy, r.w, r.h}, color)
		}
	}
	if start, end, ok := selected_range(b, index); ok {
		paint(b, item, start, end, dy, SELECTION_COLOR)
	}
	if b.find_open {
		for m, i in b.matches {
			if m.handle == item.handle {
				paint(b, item, m.offset, m.offset + m.length, dy, CURRENT_MATCH_COLOR if i == b.current_match else MATCH_COLOR)
			}
		}
	}
}

clear_selection :: proc(b: ^Browser) {
	if b.has_selection {
		b.has_selection = false
		b.dirty = true
	}
	b.selecting = false
}

// Starts a selection at a document point (mouse down on page text).
begin_selection :: proc(b: ^Browser, x, y: f32, clicks: int) {
	pos, ok := pos_at_point(b, x, y)
	if !ok {
		clear_selection(b)
		return
	}
	b.sel_anchor, b.sel_focus = pos, pos
	b.has_selection = true
	b.selecting = true
	if clicks == 2 {
		select_word(b, pos)
	}
	b.dirty = true
}

extend_selection :: proc(b: ^Browser, x, y: f32) {
	if !b.selecting {
		return
	}
	if pos, ok := pos_at_point(b, x, y); ok && pos != b.sel_focus {
		b.sel_focus = pos
		b.dirty = true
	}
}

end_selection :: proc(b: ^Browser) {
	if b.selecting && b.sel_anchor == b.sel_focus {
		b.has_selection = false // a click, not a drag
		b.dirty = true
	}
	b.selecting = false
}

// Double click: the word (letters, digits, marks) around `pos`.
select_word :: proc(b: ^Browser, pos: Text_Pos) {
	i := item_index_of(b, pos.handle)
	if i < 0 {
		return
	}
	text := b.lay.items[i].text
	is_word :: proc(r: rune) -> bool {
		return unicode.is_letter(r) || unicode.is_digit(r) || unicode.is_combining(r) || r == '_' || r == '\''
	}
	start, end := pos.offset, pos.offset
	for start > 0 {
		r, size := utf8.decode_last_rune_in_string(text[:start])
		if !is_word(r) {
			break
		}
		start -= size
	}
	for end < len(text) {
		r, size := utf8.decode_rune_in_string(text[end:])
		if !is_word(r) {
			break
		}
		end += size
	}
	b.sel_anchor = {pos.handle, start}
	b.sel_focus = {pos.handle, end}
}

select_all :: proc(b: ^Browser) {
	first, last := -1, -1
	for &item, i in b.lay.items {
		if is_text_item(&item) {
			if first < 0 {
				first = i
			}
			last = i
		}
	}
	if first < 0 {
		return
	}
	b.sel_anchor = {b.lay.items[first].handle, 0}
	b.sel_focus = {b.lay.items[last].handle, len(b.lay.items[last].text)}
	b.has_selection = true
	b.selecting = false
	b.dirty = true
}

// The selected text. Pieces on the same line are joined with a space,
// pieces on different lines with a newline.
selected_text :: proc(b: ^Browser, allocator := context.temp_allocator) -> string {
	ai, _, zi, _, ok := selection_span(b)
	if !ok {
		return ""
	}
	sb := strings.builder_make(allocator)
	prev := -1
	for i in ai ..= zi {
		start, end, sok := selected_range(b, i)
		if !sok {
			continue
		}
		if prev >= 0 {
			a, z := &b.lay.items[prev], &b.lay.items[i]
			root_a := a.inline_root if a.inline_root >= 0 else prev
			root_z := z.inline_root if z.inline_root >= 0 else i
			switch {
			case root_a == root_z:
				// The same paragraph: its pieces carry their own spaces.
			case a.text_rect.y == z.text_rect.y:
				strings.write_byte(&sb, ' ')
			case:
				strings.write_byte(&sb, '\n')
			}
		}
		strings.write_string(&sb, b.lay.items[i].text[start:end])
		prev = i
	}
	return strings.to_string(sb)
}
