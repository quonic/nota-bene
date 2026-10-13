package main

import sdl "vendor:sdl3"

import "../../abi"
import "../../field"
import "../../layout"

// A Text_Area is a page Input whose text wraps at the box width and may hold
// newlines. Editing is the same as for an Input (package field); this file
// adds what needs the wrapped lines: the caret's line, Up and Down, Home and
// End of a line, and scrolling the lines inside the box.

// A Text_Area's wrapped text and where it sits.
Area :: struct {
	fl:     ^Field_Layout,
	key:    u64,
	text:   string,
	rect:   layout.Rect, // the box, in document coordinates
	inner:  layout.Rect, // the box inside its padding
	line_h: f32,
}

area_of :: proc(b: ^Browser, item: ^layout.Item, s: string) -> Area {
	pad := item.style.padding
	r := item.rect
	_, line_h := measure_text(&b.fonts, "", item.style.font, 0)
	key := u64(item.handle)
	return {
		fl     = field_layout(b, key, s, item.style.font, item.wrap, item.style.text_dir, item.wrap),
		key    = key,
		text   = s,
		rect   = r,
		inner  = {r.x + pad, r.y + pad, r.w - 2 * pad, r.h - 2 * pad},
		line_h = line_h,
	}
}

// The focused Text_Area, if the focus is on one.
focused_area :: proc(b: ^Browser) -> (a: Area, ok: bool) {
	if !b.input.multiline || focused_field(b) != .Input {
		return
	}
	i := item_index_of(b, b.focus)
	if i < 0 || b.lay.items[i].kind != .Text_Area {
		return
	}
	return area_of(b, &b.lay.items[i], field.text(&b.input)), true
}

// A zero-width rectangle at `offset`, one line tall, relative to the top
// left of the text. After a newline it is at the start of the next line.
area_caret :: proc(b: ^Browser, a: Area, offset: int) -> layout.Rect {
	return field_text_caret(b, a.key, a.fl, offset)
}

// The bottom of the text, relative to its top.
area_height :: proc(a: Area) -> f32 {
	return max(a.fl.para.height, a.line_h)
}

// The byte offset nearest point (x, y), relative to the top left of the
// text. Above the text is its start, below it its end.
area_offset_at :: proc(b: ^Browser, a: Area, x, y: f32) -> int {
	if y < 0 {
		return 0
	}
	if y >= a.fl.para.height {
		return len(a.text)
	}
	return field_text_offset(b, a.key, a.fl, x, y)
}

// The keys that move by line in a Text_Area: Up, Down, Page Up, Page Down
// and Home and End of the line (Ctrl+Home and Ctrl+End are left to
// field_key: the whole text). Shift extends the selection.
area_key :: proc(b: ^Browser, f: ^Text_Field, key: sdl.Keycode, mods: abi.Modifiers) -> bool {
	a := focused_area(b) or_return
	shift := .Shift in mods
	lines := a.fl.para.lines[:]
	if len(lines) == 0 {
		return false
	}
	li := field_line_of(a.fl, f.caret)
	switch key {
	case sdl.K_UP, sdl.K_DOWN, sdl.K_PAGEUP, sdl.K_PAGEDOWN:
		n := 1
		if key == sdl.K_PAGEUP || key == sdl.K_PAGEDOWN {
			n = max(int(a.inner.h / a.line_h) - 1, 1)
		}
		if key == sdl.K_UP || key == sdl.K_PAGEUP {
			n = -n
		}
		goal := f.goal_x.? or_else area_caret(b, a, f.caret).x
		target := li + n
		offset: int
		switch {
		case target < 0:
			offset = 0
		case target >= len(lines):
			offset = len(a.text)
		case:
			l := lines[target]
			offset = field_text_offset(b, a.key, a.fl, goal, l.y + l.h / 2)
		}
		field.set_caret(&f.edit, offset, extend = shift)
		f.goal_x = goal
	case sdl.K_HOME, sdl.K_END:
		if .Ctrl in mods {
			return false
		}
		// The logical start and end of the line, whichever side they are on.
		l := lines[li]
		offset := l.start
		if key == sdl.K_END {
			offset = l.end
			if li < len(lines) - 1 && offset > l.start {
				offset = field.prev_char(a.text, offset) // stay on this line
			}
		}
		field.set_caret(&f.edit, offset, extend = shift)
		f.goal_x = nil
	case:
		return false
	}
	return true
}

// The mouse wheel over the focused Text_Area scrolls its lines, until they
// reach the top or bottom; then the page scrolls.
area_wheel :: proc(b: ^Browser, x, y, dy: f32) -> bool {
	a := focused_area(b) or_return
	_, docy, inside := to_document(b, x, y)
	if !inside || !layout.rect_contains(a.rect, x, docy) {
		return false
	}
	old := b.input.scroll_y
	b.input.scroll_y = clamp(old + dy, 0, max(area_height(a) - a.inner.h, 0))
	if b.input.scroll_y == old {
		return false
	}
	b.dirty = true
	return true
}

// Draws a Text_Area whose box is at `r` (window coordinates). With a field
// `f` (it has focus), also its selection and caret, scrolled to keep the
// caret in view when it moves. Leaves the clip rectangle set to the box
// inside its padding; the caller restores it.
draw_area :: proc(b: ^Browser, item: ^layout.Item, r: layout.Rect, f: ^Text_Field = nil) {
	st := item.style
	s := field.text(&f.edit) if f != nil else item.text
	a := area_of(b, item, s)
	pad := st.padding
	inner := layout.Rect{r.x + pad, r.y + pad, r.w - 2 * pad, r.h - 2 * pad}
	scroll: f32
	caret: layout.Rect
	if f != nil {
		caret = area_caret(b, a, f.caret)
		if f.caret != f.seen_caret {
			// The caret moved (or the text changed under it): bring it into view.
			if caret.y + caret.h - f.scroll_y > inner.h {
				f.scroll_y = caret.y + caret.h - inner.h
			} else if caret.y < f.scroll_y {
				f.scroll_y = caret.y
			}
			f.seen_caret = f.caret
		}
		f.scroll_y = clamp(f.scroll_y, 0, max(area_height(a) - inner.h, 0))
		scroll = f.scroll_y
	}
	x, y := inner.x, inner.y - scroll

	clip := sdl.Rect{i32(inner.x * b.scale), i32(inner.y * b.scale), i32(inner.w * b.scale), i32(inner.h * b.scale)}
	sdl.SetRenderClipRect(b.renderer, &clip)
	if f != nil && field.has_selection(&f.edit) {
		lo, hi := field.selection(&f.edit)
		for sr in field_range_rects(b, a.key, a.fl, lo, hi) {
			fill_rect(b, {x + sr.x, y + sr.y, sr.w, sr.h}, SELECTION_COLOR)
		}
	}
	draw_field_text(b, a.key, a.fl, st.color, x, y)
	if f != nil && b.caret_shown {
		fill_rect(b, {x + caret.x, y + caret.y + 2, 1.5, caret.h - 4}, st.color)
	}
}
