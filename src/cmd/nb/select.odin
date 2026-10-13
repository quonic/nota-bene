package main

import "core:strings"

import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

import "../../abi"
import "../../field"
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
	return len(item.text) > 0 && item.kind not_in abi.EDITABLE && item.kind != .Image && item.kind != .Canvas
}

item_index_of :: proc(b: ^Browser, h: abi.Handle) -> int {
	for item, i in b.lay.items {
		if item.handle == h {
			return i
		}
	}
	return -1
}

// The cached text object for one inline fragment.
fragment_text :: proc(b: ^Browser, item: ^layout.Item, k: int) -> ^Cached_Text {
	f := b.lay.fragments[item.frag_first + k]
	return cached_text(b, KEY_FRAG_BASE + u64(item.frag_first + k), item.text[f.start:f.end], f.font, 0)
}

// Document-space rectangles covering bytes [start, end) of an item's text,
// one per fragment it touches. In mixed-direction text a range can be
// several pieces on one line.
range_rects :: proc(b: ^Browser, item: ^layout.Item, start, end: int, allocator := context.temp_allocator) -> []layout.Rect {
	out := make([dynamic]layout.Rect, allocator)
	if start >= end {
		return out[:]
	}
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

// Rectangles for bytes [start, end) of one text object drawn at `origin`.
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
// Page text is all fragments: see fragment_pos_at_point.
pos_at_point :: proc(b: ^Browser, x, y: f32) -> (Text_Pos, bool) {
	if pos, ok := fragment_pos_at_point(b, x, y); ok {
		return pos, true
	}
	// Not on any line: the end of the last text item that starts above the
	// point (a point in the gap after a paragraph belongs to its end).
	best := -1
	for &item, i in b.lay.items {
		if !is_text_item(&item) {
			continue
		}
		if item.text_rect.y > y {
			break
		}
		best = i
	}
	if best < 0 {
		return {}, false
	}
	item := &b.lay.items[best]
	return {item.handle, len(item.text)}, true
}

// The byte offset in a text object nearest physical point (px, py),
// relative to its top left. The half of a character further along the
// reading direction (the right half, or the left in right-to-left text)
// means after it.
text_offset_at :: proc(c: ^Cached_Text, px, py: i32, rtl := false) -> (int, bool) {
	sub: ttf.SubString
	if !ttf.GetTextSubStringForPoint(c.text, px, py, &sub) {
		return 0, false
	}
	offset := int(sub.offset)
	if (px > sub.rect.x + sub.rect.w / 2) != rtl {
		offset += int(sub.length)
	}
	return offset, true
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
		return {item.handle, f.end if f.rtl else f.start}, true
	}
	if x >= f.rect.x + f.rect.w {
		return {item.handle, f.start if f.rtl else f.end}, true
	}
	c := fragment_text(b, item, best - item.frag_first)
	if c == nil {
		return {item.handle, f.start}, true
	}
	offset, _ := text_offset_at(c, i32((x - f.rect.x) * b.scale), 0, f.rtl)
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

// Starts a selection at a document point (mouse down on page text). Shift
// extends the current one instead; a double click selects a word and a
// triple click the paragraph.
begin_selection :: proc(b: ^Browser, x, y: f32, clicks: int, mods: abi.Modifiers) {
	pos, ok := pos_at_point(b, x, y)
	if !ok {
		clear_selection(b)
		return
	}
	if .Shift in mods && b.has_selection {
		b.sel_focus = pos
	} else {
		b.sel_anchor, b.sel_focus = pos, pos
	}
	b.has_selection = true
	b.selecting = true
	switch {
	case clicks == 2:
		select_word(b, pos)
	case clicks >= 3:
		select_paragraph(b, pos)
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

// The mouse button was released: ends a drag in page text or in a field.
// A click without a drag leaves an empty selection: nothing is highlighted,
// but Shift+click and Shift+arrows extend from there.
end_selection :: proc(b: ^Browser) {
	b.field_drag = .None
	b.selecting = false
}

// Whether there is selected text, not just an empty selection where the user clicked.
selection_nonempty :: proc(b: ^Browser) -> bool {
	ai, ao, zi, zo, ok := selection_span(b)
	return ok && (ai != zi || ao != zo)
}

// Double click: the word around `pos`, by the same rule as word moves in fields.
select_word :: proc(b: ^Browser, pos: Text_Pos) {
	i := item_index_of(b, pos.handle)
	if i < 0 {
		return
	}
	start, end := field.word_at(b.lay.items[i].text, pos.offset)
	b.sel_anchor = {pos.handle, start}
	b.sel_focus = {pos.handle, end}
}

// Triple click: the paragraph around `pos`, all the inline items that flow
// together with it.
select_paragraph :: proc(b: ^Browser, pos: Text_Pos) {
	i := item_index_of(b, pos.handle)
	if i < 0 {
		return
	}
	root := b.lay.items[i].inline_root if b.lay.items[i].inline_root >= 0 else i
	first, last := -1, -1
	for &item, j in b.lay.items {
		if (j == root || item.inline_root == root) && is_text_item(&item) {
			if first < 0 {
				first = j
			}
			last = j
		}
	}
	if first < 0 {
		return
	}
	b.sel_anchor = {b.lay.items[first].handle, 0}
	b.sel_focus = {b.lay.items[last].handle, len(b.lay.items[last].text)}
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

// Shift with the arrows, Home or End moves the focus end of the page
// selection: by character (by word with Ctrl), by line, or to the start or
// end of the line. Returns false if there is no selection to extend.
extend_selection_key :: proc(b: ^Browser, key: sdl.Keycode, mods: abi.Modifiers) -> bool {
	if .Shift not_in mods || !b.has_selection || !b.lay_valid {
		return false
	}
	i := item_index_of(b, b.sel_focus.handle)
	if i < 0 {
		return false
	}
	offset := min(b.sel_focus.offset, len(b.lay.items[i].text))
	pos := Text_Pos{b.sel_focus.handle, offset}
	here := caret_rect(b, i, offset)
	switch key {
	case sdl.K_LEFT, sdl.K_RIGHT:
		pos = step_pos(b, i, offset, key == sdl.K_LEFT, .Ctrl in mods)
	case sdl.K_UP, sdl.K_DOWN:
		if b.sel_goal_at != b.sel_focus {
			b.sel_goal_x = here.x
		}
		pos = vertical_pos(b, here, key == sdl.K_UP, b.sel_goal_x, pos)
	case sdl.K_HOME, sdl.K_END:
		vw, _ := viewport_size(b)
		if p, ok := pos_at_point(b, 0 if key == sdl.K_HOME else vw, here.y + here.h / 2); ok {
			pos = p
		}
	case:
		return false
	}
	b.sel_focus = pos
	if key == sdl.K_UP || key == sdl.K_DOWN {
		b.sel_goal_at = pos
	}
	if j := item_index_of(b, pos.handle); j >= 0 {
		scroll_into_view(b, caret_rect(b, j, pos.offset))
	}
	b.dirty = true
	return true
}

// The position on the line above or below the caret at `here`, at column
// `goal_x`. Probes in half-line steps, so the gap between two paragraphs is
// skipped; `pos` if there is no line there.
@(private="file")
vertical_pos :: proc(b: ^Browser, here: layout.Rect, up: bool, goal_x: f32, pos: Text_Pos) -> Text_Pos {
	step := max(here.h, 1) / 2 * (-1 if up else 1)
	for y := here.y + here.h / 2 + step; y >= 0 && y <= b.lay.height; y += step {
		p, ok := pos_at_point(b, goal_x, y)
		if !ok {
			continue
		}
		j := item_index_of(b, p.handle)
		if j < 0 {
			continue
		}
		r := caret_rect(b, j, p.offset)
		if (r.y + r.h <= here.y + 1) if up else (r.y >= here.y + here.h - 1) {
			// Another line. A probe in a gap lands at a paragraph's end, so
			// aim at the goal column in the middle of that line.
			if q, qok := pos_at_point(b, goal_x, r.y + r.h / 2); qok {
				return q
			}
			return p
		}
	}
	return pos
}

// One character (or word) left or right of `offset` in item `i`. At the
// edge of an item it carries on into the previous or next text item: within
// a paragraph by one more character, since the two edges are the same place
// on screen; across blocks to the near edge.
@(private="file")
step_pos :: proc(b: ^Browser, i, offset: int, back, word: bool) -> Text_Pos {
	item := &b.lay.items[i]
	if back && offset > 0 {
		return {item.handle, field.prev_word(item.text, offset) if word else field.prev_char(item.text, offset)}
	}
	if !back && offset < len(item.text) {
		return {item.handle, field.next_word(item.text, offset) if word else field.next_char(item.text, offset)}
	}
	for j := i - 1 if back else i + 1; j >= 0 && j < len(b.lay.items); j += -1 if back else 1 {
		next := &b.lay.items[j]
		if !is_text_item(next) {
			continue
		}
		same_paragraph := item.inline_root >= 0 && next.inline_root == item.inline_root
		switch {
		case back && same_paragraph:
			return {next.handle, field.prev_word(next.text, len(next.text)) if word else field.prev_char(next.text, len(next.text))}
		case back:
			return {next.handle, len(next.text)}
		case same_paragraph:
			return {next.handle, field.next_word(next.text, 0) if word else field.next_char(next.text, 0)}
		case:
			return {next.handle, 0}
		}
	}
	return {item.handle, offset}
}

// A zero-width rectangle at `offset` in item `i`, one line tall.
caret_rect :: proc(b: ^Browser, i, offset: int) -> layout.Rect {
	item := &b.lay.items[i]
	// The leading edge of the character after the caret (its left, or its
	// right in right-to-left text), else the trailing edge of the one before.
	if offset < len(item.text) {
		if r, rtl, ok := char_rect(b, item, offset, field.next_char(item.text, offset)); ok {
			return {r.x + r.w if rtl else r.x, r.y, 0, r.h}
		}
	}
	if offset > 0 {
		if r, rtl, ok := char_rect(b, item, field.prev_char(item.text, offset), offset); ok {
			return {r.x if rtl else r.x + r.w, r.y, 0, r.h}
		}
	}
	_, line_h := measure_text(&b.fonts, "", item.style.font, 0)
	return {item.text_rect.x, item.text_rect.y, 0, line_h}
}

// The box of the character at bytes [start, end) of an item's text, and
// whether it runs right to left.
@(private="file")
char_rect :: proc(b: ^Browser, item: ^layout.Item, start, end: int) -> (r: layout.Rect, rtl, ok: bool) {
	for f, k in b.lay.fragments[item.frag_first:][:item.frag_count] {
		if start < f.start || end > f.end {
			continue
		}
		c := fragment_text(b, item, k)
		if c == nil {
			return
		}
		rs := text_range_rects(b, c, start - f.start, end - f.start, {f.rect.x, f.rect.y})
		if len(rs) == 0 {
			return
		}
		return rs[0], f.rtl, true
	}
	return
}

// Scrolls as little as possible to bring `r` (document coordinates) into view.
scroll_into_view :: proc(b: ^Browser, r: layout.Rect) {
	_, vh := viewport_size(b)
	margin: f32 = 8
	old := b.scroll_y
	if r.y < b.scroll_y {
		b.scroll_y = r.y - margin
	} else if r.y + r.h > b.scroll_y + vh {
		b.scroll_y = r.y + r.h - vh + margin
	}
	clamp_scroll(b, vh)
	if b.scroll_y != old {
		b.dirty = true
	}
}
