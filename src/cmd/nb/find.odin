package main

import "core:fmt"

import sdl "vendor:sdl3"

import "../../abi"
import "../../field"
import "../../layout"
import "../../search"

Match :: struct {
	handle: abi.Handle,
	offset: int,
	length: int,
}

FIND_FONT :: layout.Font{size = 13}

KEY_FIND_LABEL :: KEY_STATUS_LEFT + 20
KEY_FIND_TEXT  :: KEY_STATUS_LEFT + 21
KEY_FIND_COUNT :: KEY_STATUS_LEFT + 22

open_find :: proc(b: ^Browser) {
	set_address_focus(b, false)
	b.find_open = true
	b.find_focus = true
	field.select_all(&b.find) // typing replaces the last query
	update_text_input(b)
	refresh_matches(b)
	b.dirty = true
}

close_find :: proc(b: ^Browser) {
	b.find_open = false
	b.find_focus = false
	clear(&b.matches)
	update_text_input(b)
	b.dirty = true
}

// Recomputes the matches for the current query over the laid-out page.
refresh_matches :: proc(b: ^Browser, scroll := true) {
	clear(&b.matches)
	b.current_match = -1
	b.matches_version = b.lay_version
	query := field.text(&b.find)
	if !b.find_open || query == "" || !b.lay_valid {
		return
	}
	for &item in b.lay.items {
		if len(item.text) == 0 || item.kind in abi.EDITABLE || item.kind == .Image || item.kind == .Canvas {
			continue
		}
		for m in search.find_all(item.text, query) {
			append(&b.matches, Match{item.handle, m[0], m[1] - m[0]})
		}
	}
	// Start from the first match at or below the top of the view.
	for m, i in b.matches {
		if idx := item_index_of(b, m.handle); idx >= 0 && b.lay.items[idx].text_rect.y >= b.scroll_y {
			b.current_match = i
			break
		}
	}
	if b.current_match < 0 && len(b.matches) > 0 {
		b.current_match = 0
	}
	if scroll {
		scroll_to_match(b)
	}
	b.dirty = true
}

step_match :: proc(b: ^Browser, backwards: bool) {
	if len(b.matches) == 0 {
		return
	}
	n := len(b.matches)
	b.current_match = (b.current_match + (n - 1 if backwards else 1)) % n
	scroll_to_match(b)
	b.dirty = true
}

// Scrolls so the current match is comfortably inside the view.
scroll_to_match :: proc(b: ^Browser) {
	if b.current_match < 0 || b.current_match >= len(b.matches) {
		return
	}
	m := b.matches[b.current_match]
	i := item_index_of(b, m.handle)
	if i < 0 {
		return
	}
	rects := range_rects(b, &b.lay.items[i], m.offset, m.offset + m.length)
	r := rects[0] if len(rects) > 0 else b.lay.items[i].text_rect
	_, vh := viewport_size(b)
	if r.y < b.scroll_y || r.y + r.h > b.scroll_y + vh {
		b.scroll_y = r.y - vh / 3
		clamp_scroll(b, vh)
	}
}

// Keys for the find bar that are not editing keys.
find_key :: proc(b: ^Browser, key: sdl.Keycode, mods: abi.Modifiers) {
	switch key {
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		step_match(b, .Shift in mods)
	case sdl.K_ESCAPE:
		close_find(b)
	}
}

// The find bar's text box, inside its border. `y` is the bar's top edge.
find_field_inner :: proc(b: ^Browser, y: f32) -> layout.Rect {
	box := find_field_rect(b, y)
	return {box.x + 6, box.y, box.w - 12, box.h}
}

@(private="file")
find_field_rect :: proc(b: ^Browser, y: f32) -> layout.Rect {
	vw, _ := viewport_size(b)
	lw, _ := measure_text(&b.fonts, "Find", FIND_FONT, 0)
	return {16 + lw, y + 3, min(280, vw / 2), STATUS_BAR_HEIGHT - 6}
}

// The find bar replaces the status bar while it is open. `y` is its top edge.
draw_find_bar :: proc(b: ^Browser, vw, y: f32) {
	fill_rect(b, {0, y, vw, STATUS_BAR_HEIGHT}, {0xF2, 0xF3, 0xF5, 0xFF})
	fill_rect(b, {0, y, vw, 1}, {0xD5, 0xD8, 0xDD, 0xFF})
	muted := layout.Color{0x55, 0x5B, 0x65, 0xFF}
	_, th := measure_text(&b.fonts, "", FIND_FONT, 0)
	ty := y + (STATUS_BAR_HEIGHT - th) / 2

	draw_text(b, KEY_FIND_LABEL, "Find", FIND_FONT, 0, muted, 8, ty)

	box := find_field_rect(b, y)
	fill_rect(b, box, b.theme.input)
	stroke_rect(b, box, b.theme.focus if b.find_focus else b.theme.input_edge, 2 if b.find_focus else 1)
	query := field.text(&b.find)
	draw_field(b, KEY_FIND_TEXT, query, FIND_FONT, b.theme.text, find_field_inner(b, y), ty, &b.find if b.find_focus else nil)
	sdl.SetRenderClipRect(b.renderer, nil)

	count: string
	switch {
	case query == "":
		count = "Enter: next · Shift+Enter: previous · Esc: close"
	case len(b.matches) == 0:
		count = "No matches"
	case:
		count = fmt.tprintf("%d of %d", b.current_match + 1, len(b.matches))
	}
	draw_text(b, KEY_FIND_COUNT, count, FIND_FONT, 0, muted, box.x + box.w + 12, ty)
}

find_bar_contains :: proc(b: ^Browser, x, y: f32) -> bool {
	_, vh := viewport_size(b)
	return b.find_open && y >= CHROME_HEIGHT + vh
}
