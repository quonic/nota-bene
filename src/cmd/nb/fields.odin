package main

import "core:strings"
import "core:time"

import sdl "vendor:sdl3"

import "../../abi"
import "../../field"
import "../../host"
import "../../layout"
import "../../text"

// A text field drawn by the browser: the address bar, the find bar or the
// focused page Input or Text_Area. Editing is in package field; this adds
// what drawing needs.
Text_Field :: struct {
	using edit: field.Field,
	scroll_x:   f32, // how far the text is scrolled left to keep the caret in view
	// Text_Area only: the text wraps, Enter inserts a newline and the lines
	// scroll up by `scroll_y`. Up and Down keep to column `goal_x`.
	multiline:  bool,
	scroll_y:   f32,
	seen_caret: int, // the caret offset last scrolled into view
	goal_x:     Maybe(f32),
}

Field_Target :: enum {
	None,
	Address,
	Find,
	Input,
}

// The field that has keyboard focus, if any.
focused_field :: proc(b: ^Browser) -> Field_Target {
	switch {
	case b.address_focus:
		return .Address
	case b.find_focus:
		return .Find
	case b.focus != abi.INVALID_HANDLE && sync_input(b):
		return .Input
	}
	return .None
}

// Where a field is drawn: its text cache key, its font and the left edge of
// its text area.
field_geometry :: proc(b: ^Browser, t: Field_Target) -> (f: ^Text_Field, key: u64, font: layout.Font, left: f32, ok: bool) {
	switch t {
	case .None:
		return
	case .Address:
		return &b.address, KEY_ADDRESS, ADDRESS_FONT, address_inner(b).x, true
	case .Find:
		_, vh := viewport_size(b)
		return &b.find, KEY_FIND_TEXT, FIND_FONT, find_field_inner(b, CHROME_HEIGHT + vh).x, true
	case .Input:
		i := item_index_of(b, b.focus)
		if i < 0 {
			return
		}
		item := &b.lay.items[i]
		return &b.input, u64(item.handle), item.style.font, item.rect.x + item.style.padding, true
	}
	return
}

// Keys that edit or move inside a field. `changed` means the text changed.
field_key :: proc(b: ^Browser, f: ^Text_Field, key: sdl.Keycode, mods: abi.Modifiers) -> (handled, changed: bool) {
	e := &f.edit
	ctrl, shift := .Ctrl in mods, .Shift in mods
	if f.multiline && area_key(b, f, key, mods) {
		b.dirty = true
		return true, false
	}
	f.goal_x = nil
	handled = true
	switch {
	case key == sdl.K_LEFT:
		field.move(e, .Word_Left if ctrl else .Left, shift)
	case key == sdl.K_RIGHT:
		field.move(e, .Word_Right if ctrl else .Right, shift)
	case key == sdl.K_HOME:
		field.move(e, .Start, shift)
	case key == sdl.K_END:
		field.move(e, .End, shift)
	case key == sdl.K_BACKSPACE:
		changed = field.delete_to(e, .Word_Left if ctrl else .Left)
	case key == sdl.K_DELETE:
		changed = field.delete_to(e, .Word_Right if ctrl else .Right)
	case ctrl && key == 'a':
		field.select_all(e)
	case ctrl && (key == 'y' || (key == 'z' && shift)):
		changed = field.redo(e)
	case ctrl && key == 'z':
		changed = field.undo(e)
	case ctrl && (key == 'c' || key == 'x'):
		if field.has_selection(e) {
			_ = sdl.SetClipboardText(strings.clone_to_cstring(field.selected_text(e), context.temp_allocator))
			if key == 'x' {
				changed = field.delete_to(e, .Left)
			}
		}
	case:
		handled = false
	}
	if handled {
		b.dirty = true
	}
	return
}

// The clipboard's text. For a one-line field (all but a Text_Area),
// newlines become spaces.
clipboard_text :: proc(multiline: bool) -> (string, bool) {
	raw := sdl.GetClipboardText()
	if raw == nil {
		return "", false
	}
	defer sdl.free(raw)
	pasted, _ := strings.replace_all(string(cstring(raw)), "\r", "", context.temp_allocator)
	if !multiline {
		pasted, _ = strings.replace_all(pasted, "\n", " ", context.temp_allocator)
	}
	return pasted, true
}

// Brings the focused Input's field up to date with its node, in case the
// page changed the text. False if the focus is not on an Input.
sync_input :: proc(b: ^Browser) -> bool {
	n := host.node_get(&b.page, b.focus)
	if n == nil || n.kind not_in abi.EDITABLE {
		return false
	}
	if n.text != field.text(&b.input) {
		field.set_text(&b.input, n.text)
	}
	return true
}

// Hands the focused Input's edited text to the page, which gets a Change event.
commit_input :: proc(b: ^Browser) {
	host.page_input_edit(&b.page, b.focus, field.text(&b.input))
}

// Applies the page's focus request, then keeps the focused Input's
// selection and its node's in step: a selection the page placed is applied,
// and one the user moved is reported to the page with a Select event.
sync_selection :: proc(b: ^Browser) {
	if b.cur == nil || !b.loaded {
		return
	}
	if b.page.focus_requested {
		b.page.focus_requested = false
		h := b.page.focus_request
		// The address and find bars keep their focus: the request is dropped,
		// so the caret never jumps away from what the user is typing there.
		n := host.node_get(&b.page, h)
		if !b.address_focus && !b.find_focus && (h == abi.INVALID_HANDLE || (n != nil && n.kind in abi.EDITABLE)) {
			set_focus(b, h)
			reset_caret_blink(b)
		}
	}
	if focused_field(b) != .Input {
		return
	}
	n := host.node_get(&b.page, b.focus)
	if n.selection_set {
		n.selection_set = false
		field.select_range(&b.input, n.anchor, n.caret)
		reset_caret_blink(b)
		b.dirty = true
	} else if b.input.anchor != n.anchor || b.input.caret != n.caret {
		host.page_input_select(&b.page, b.focus, b.input.anchor, b.input.caret)
	}
}

// The byte offset in field `t` nearest window point (x, y). Only a
// Text_Area looks at y.
field_offset_at :: proc(b: ^Browser, t: Field_Target, x, y: f32) -> (offset: int, ok: bool) {
	if t == .Input && b.input.multiline {
		a := focused_area(b) or_return
		top := a.inner.y + CHROME_HEIGHT - b.scroll_y - b.input.scroll_y
		return area_offset_at(b, a, x - a.inner.x, y - top), true
	}
	f, key, _, left := field_geometry(b, t) or_return
	fl := field_layout_of(b, t) or_return
	return field_text_offset(b, key, fl, x - left + f.scroll_x, 0), true
}

// The laid-out text of one-line field `t`, as draw_field lays it out.
field_layout_of :: proc(b: ^Browser, t: Field_Target) -> (fl: ^Field_Layout, ok: bool) {
	f, key, font, _ := field_geometry(b, t) or_return
	width: f32
	dir := text.Dir.Auto
	switch t {
	case .None:
		return nil, false
	case .Address:
		width = address_inner(b).w
	case .Find:
		_, vh := viewport_size(b)
		width = find_field_inner(b, CHROME_HEIGHT + vh).w
	case .Input:
		item := &b.lay.items[item_index_of(b, b.focus)]
		width = item.rect.w - 2 * item.style.padding
		dir = item.style.text_dir
	}
	return field_layout(b, key, field.text(&f.edit), font, 0, dir, width), true
}

// Mouse down in field `t`: places the caret, extends the selection with
// Shift, selects a word on a double click. Dragging then extends it.
field_press :: proc(b: ^Browser, t: Field_Target, x, y: f32, mods: abi.Modifiers, clicks: int) {
	offset, ok := field_offset_at(b, t, x, y)
	if !ok {
		return
	}
	f, _, _, _, _ := field_geometry(b, t)
	if clicks == 2 {
		field.select_word_at(&f.edit, offset)
	} else if clicks >= 3 {
		field.select_all(&f.edit)
	} else {
		field.set_caret(&f.edit, offset, extend = .Shift in mods)
	}
	f.goal_x = nil
	b.field_drag = t
	b.dirty = true
}

field_drag_to :: proc(b: ^Browser, x, y: f32) {
	offset, ok := field_offset_at(b, b.field_drag, x, y)
	if !ok {
		return
	}
	f, _, _, _, _ := field_geometry(b, b.field_drag)
	if offset != f.caret {
		field.set_caret(&f.edit, offset, extend = true)
		b.dirty = true
	}
}

// Draws one line of text in `inner`, starting at `y`. With a field `f`
// (one that has focus), also its selection and caret, scrolled sideways to
// keep the caret in view. Leaves the clip rectangle set to `inner`; the
// caller restores it.
draw_field :: proc(b: ^Browser, key: u64, s: string, font: layout.Font, color: layout.Color, inner: layout.Rect, y: f32, f: ^Text_Field = nil, dir := text.Dir.Auto) {
	fl := field_layout(b, key, s, font, 0, dir, inner.w)
	x := inner.x
	caret: layout.Rect
	if f != nil {
		caret = field_text_caret(b, key, fl, f.caret)
		if caret.x - f.scroll_x > inner.w - 2 {
			f.scroll_x = caret.x - inner.w + 2
		} else if caret.x < f.scroll_x {
			f.scroll_x = caret.x
		}
		f.scroll_x = clamp(f.scroll_x, 0, max(field_extent(fl) - inner.w + 2, 0))
		x -= f.scroll_x
	}

	clip := sdl.Rect{i32(inner.x * b.scale), i32(inner.y * b.scale), i32(inner.w * b.scale), i32(inner.h * b.scale)}
	sdl.SetRenderClipRect(b.renderer, &clip)
	if f != nil && field.has_selection(&f.edit) {
		lo, hi := field.selection(&f.edit)
		for r in field_range_rects(b, key, fl, lo, hi) {
			fill_rect(b, {x + r.x, y + r.y, r.w, r.h}, SELECTION_COLOR)
		}
	}
	draw_field_text(b, key, fl, color, x, y)
	if f != nil && b.caret_shown {
		fill_rect(b, {x + caret.x, y + caret.y + 2, 1.5, caret.h - 4}, color)
	}
}

// How long the caret stays on, then off.
CARET_BLINK :: 530 * time.Millisecond

// Restarts the blink cycle, so the caret is solid right after the user types,
// clicks or moves it.
reset_caret_blink :: proc(b: ^Browser) {
	b.caret_since = time.tick_now()
	if !b.caret_shown {
		b.dirty = true
	}
}

// Whether the caret is in the on half of its blink cycle. An unfocused window
// shows no caret.
caret_visible :: proc(b: ^Browser) -> bool {
	if b.no_blink {
		return true
	}
	if !b.window_focused {
		return false
	}
	return (time.tick_since(b.caret_since) / CARET_BLINK) % 2 == 0
}

// Whether any caret is showing: a focused field's, or the page caret while
// caret browsing.
caret_wanted :: proc(b: ^Browser) -> bool {
	return focused_field(b) != .None || page_caret_wanted(b)
}

// Milliseconds until the caret next turns on or off, or -1 if it does not
// blink right now.
caret_next_toggle_ms :: proc(b: ^Browser) -> i32 {
	if b.no_blink || !b.window_focused || !caret_wanted(b) {
		return -1
	}
	elapsed := time.tick_since(b.caret_since)
	left := CARET_BLINK - elapsed % CARET_BLINK
	return i32((left + time.Millisecond - 1) / time.Millisecond)
}
