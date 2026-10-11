package main

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

import sdl "vendor:sdl3"

import "../../abi"
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
	b.find_select_all = true
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
	query := strings.to_string(b.find_query)
	if !b.find_open || query == "" || !b.lay_valid {
		return
	}
	for &item in b.lay.items {
		if len(item.text) == 0 || item.kind == .Input || item.kind == .Image || item.kind == .Canvas {
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

find_type :: proc(b: ^Browser, text: string) {
	if b.find_select_all {
		strings.builder_reset(&b.find_query)
		b.find_select_all = false
	}
	strings.write_string(&b.find_query, text)
	refresh_matches(b)
}

find_key :: proc(b: ^Browser, key: sdl.Keycode, mods: abi.Modifiers) {
	switch key {
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		step_match(b, .Shift in mods)
	case sdl.K_ESCAPE:
		close_find(b)
	case sdl.K_BACKSPACE:
		if b.find_select_all {
			strings.builder_reset(&b.find_query)
			b.find_select_all = false
		} else if q := strings.to_string(b.find_query); len(q) > 0 {
			_, size := utf8.decode_last_rune_in_string(q)
			resize(&b.find_query.buf, len(q) - size)
		}
		refresh_matches(b)
	case sdl.K_LEFT, sdl.K_RIGHT, sdl.K_HOME, sdl.K_END:
		b.find_select_all = false
		b.dirty = true
	}
}

// The find bar replaces the status bar while it is open. `y` is its top edge.
draw_find_bar :: proc(b: ^Browser, vw, y: f32) {
	fill_rect(b, {0, y, vw, STATUS_BAR_HEIGHT}, {0xF2, 0xF3, 0xF5, 0xFF})
	fill_rect(b, {0, y, vw, 1}, {0xD5, 0xD8, 0xDD, 0xFF})
	muted := layout.Color{0x55, 0x5B, 0x65, 0xFF}
	_, th := measure_text(&b.fonts, "", FIND_FONT, 0)
	ty := y + (STATUS_BAR_HEIGHT - th) / 2

	lw, _ := measure_text(&b.fonts, "Find", FIND_FONT, 0)
	draw_text(b, KEY_FIND_LABEL, "Find", FIND_FONT, 0, muted, 8, ty)

	field := layout.Rect{16 + lw, y + 3, min(280, vw / 2), STATUS_BAR_HEIGHT - 6}
	fill_rect(b, field, b.theme.input)
	stroke_rect(b, field, b.theme.focus if b.find_focus else b.theme.input_edge, 2 if b.find_focus else 1)
	query := strings.to_string(b.find_query)
	qw, _ := measure_text(&b.fonts, query, FIND_FONT, 0)
	inner := layout.Rect{field.x + 6, field.y, field.w - 12, field.h}
	offset := max(qw - inner.w + 2, 0)
	clip := sdl.Rect{i32(inner.x * b.scale), i32(inner.y * b.scale), i32(inner.w * b.scale), i32(inner.h * b.scale)}
	sdl.SetRenderClipRect(b.renderer, &clip)
	if b.find_focus && b.find_select_all && query != "" {
		fill_rect(b, {inner.x - offset, ty, qw, th}, SELECTION_COLOR)
	}
	draw_text(b, KEY_FIND_TEXT, query, FIND_FONT, 0, b.theme.text, inner.x - offset, ty)
	if b.find_focus && !b.find_select_all {
		fill_rect(b, {inner.x - offset + qw, ty + 2, 1.5, th - 4}, b.theme.text)
	}
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
	draw_text(b, KEY_FIND_COUNT, count, FIND_FONT, 0, muted, field.x + field.w + 12, ty)
}

find_bar_contains :: proc(b: ^Browser, x, y: f32) -> bool {
	_, vh := viewport_size(b)
	return b.find_open && y >= CHROME_HEIGHT + vh
}
