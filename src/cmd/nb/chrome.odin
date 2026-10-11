package main

import "core:os"
import "core:strings"
import "core:unicode/utf8"

import sdl "vendor:sdl3"

import "../../layout"
import "../../proto"

// Toolbar geometry, in logical px.
@(private="file") BUTTON_Y :: TABBAR_HEIGHT + 6
@(private="file") BUTTON_H :: TOOLBAR_HEIGHT - 12

@(private="file")
back_rect :: proc() -> layout.Rect { return {8, BUTTON_Y, 56, BUTTON_H} }

@(private="file")
reload_rect :: proc() -> layout.Rect { return {70, BUTTON_Y, 66, BUTTON_H} }

@(private="file")
address_rect :: proc(b: ^Browser) -> layout.Rect {
	vw, _ := viewport_size(b)
	return {144, BUTTON_Y, max(vw - 152, 40), BUTTON_H}
}

ADDRESS_FONT :: layout.Font{size = 14}

KEY_BACK    :: KEY_STATUS_LEFT + 10
KEY_RELOAD  :: KEY_STATUS_LEFT + 11
KEY_ADDRESS :: KEY_STATUS_LEFT + 12

// The location the address bar shows when nobody is editing it.
current_location :: proc(b: ^Browser) -> string {
	if b.job != nil {
		return b.job.location
	}
	return b.page_path
}

set_address_focus :: proc(b: ^Browser, focus: bool) {
	if b.address_focus == focus {
		return
	}
	b.address_focus = focus
	if focus {
		b.find_focus = false
		strings.builder_reset(&b.address)
		strings.write_string(&b.address, current_location(b))
		b.address_select_all = true
	}
	update_text_input(b)
	b.dirty = true
}

address_type :: proc(b: ^Browser, text: string) {
	if b.address_select_all {
		strings.builder_reset(&b.address)
		b.address_select_all = false
	}
	strings.write_string(&b.address, text)
	b.dirty = true
}

address_key :: proc(b: ^Browser, key: sdl.Keycode) {
	switch key {
	case sdl.K_RETURN, sdl.K_KP_ENTER:
		target := strings.trim_space(strings.to_string(b.address))
		set_address_focus(b, false)
		if target != "" {
			open_location(b, address_target(target, context.temp_allocator))
		}
	case sdl.K_ESCAPE:
		set_address_focus(b, false)
	case sdl.K_BACKSPACE:
		if b.address_select_all {
			strings.builder_reset(&b.address)
			b.address_select_all = false
		} else if text := strings.to_string(b.address); len(text) > 0 {
			_, size := utf8.decode_last_rune_in_string(text)
			resize(&b.address.buf, len(text) - size)
		}
		b.dirty = true
	case sdl.K_LEFT, sdl.K_RIGHT, sdl.K_HOME, sdl.K_END:
		b.address_select_all = false // keep the text, start editing at the end
		b.dirty = true
	}
}

// What typing `text` in the address bar means: nb:// URLs and existing
// files as they are; anything else is taken as an nb:// address, so
// "example.org/page" opens nb://example.org/page.
address_target :: proc(text: string, allocator := context.allocator) -> string {
	if proto.is_nb_url(text) || os.exists(text) || strings.contains(text, "://") {
		return strings.clone(text, allocator)
	}
	return strings.concatenate({proto.SCHEME, text}, allocator)
}

toolbar_click :: proc(b: ^Browser, x, y: f32) {
	switch {
	case layout.rect_contains(back_rect(), x, y):
		set_address_focus(b, false)
		go_back(b)
	case layout.rect_contains(reload_rect(), x, y):
		set_address_focus(b, false)
		reload(b)
	case layout.rect_contains(address_rect(b), x, y):
		set_address_focus(b, true)
	case:
		set_address_focus(b, false)
	}
}

toolbar_cursor :: proc(b: ^Browser, x, y: f32) -> sdl.SystemCursor {
	switch {
	case layout.rect_contains(address_rect(b), x, y):
		return .TEXT
	case layout.rect_contains(back_rect(), x, y) && len(b.history) > 1, layout.rect_contains(reload_rect(), x, y):
		return .POINTER
	}
	return .DEFAULT
}

draw_toolbar :: proc(b: ^Browser, vw: f32) {
	fill_rect(b, {0, TABBAR_HEIGHT, vw, TOOLBAR_HEIGHT}, {0xF8, 0xF9, 0xFA, 0xFF})
	fill_rect(b, {0, CHROME_HEIGHT - 1, vw, 1}, {0xD5, 0xD8, 0xDD, 0xFF})

	draw_button :: proc(b: ^Browser, key: u64, r: layout.Rect, label: string, enabled: bool) {
		fill_rect(b, r, b.theme.button if enabled else {0xF2, 0xF3, 0xF5, 0xFF})
		stroke_rect(b, r, b.theme.button_edge)
		color := b.theme.text if enabled else layout.Color{0xA0, 0xA5, 0xAD, 0xFF}
		tw, th := measure_text(&b.fonts, label, ADDRESS_FONT, 0)
		draw_text(b, key, label, ADDRESS_FONT, 0, color, r.x + (r.w - tw) / 2, r.y + (r.h - th) / 2)
	}
	draw_button(b, KEY_BACK, back_rect(), "Back", len(b.history) > 1)
	draw_button(b, KEY_RELOAD, reload_rect(), "Reload", b.page_path != "")

	r := address_rect(b)
	fill_rect(b, r, b.theme.input)
	if b.address_focus {
		stroke_rect(b, r, b.theme.focus, 2)
	} else {
		stroke_rect(b, r, b.theme.input_edge)
	}
	text := strings.to_string(b.address) if b.address_focus else current_location(b)
	tw, th := measure_text(&b.fonts, text, ADDRESS_FONT, 0)
	inner := layout.Rect{r.x + 8, r.y, r.w - 16, r.h}
	offset := max(tw - inner.w + 2, 0) if b.address_focus else 0
	tx, ty := inner.x - offset, r.y + (r.h - th) / 2

	clip := sdl.Rect{i32(inner.x * b.scale), i32(inner.y * b.scale), i32(inner.w * b.scale), i32(inner.h * b.scale)}
	sdl.SetRenderClipRect(b.renderer, &clip)
	if b.address_focus && b.address_select_all && len(text) > 0 {
		fill_rect(b, {tx, ty, tw, th}, {0xC7, 0xDB, 0xFA, 0xFF})
	}
	draw_text(b, KEY_ADDRESS, text, ADDRESS_FONT, 0, b.theme.text, tx, ty)
	if b.address_focus && !b.address_select_all {
		fill_rect(b, {tx + tw, ty + 2, 1.5, th - 4}, b.theme.text)
	}
	sdl.SetRenderClipRect(b.renderer, nil)
}
