package main

import "core:fmt"
import "core:path/filepath"
import "core:thread"
import "core:time"

import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

import "../../field"
import "../../host"
import "../../layout"
import "../../proto"

MAX_TAB_WIDTH :: 220
MIN_TAB_WIDTH :: 60
NEW_TAB_WIDTH :: 30
BACKGROUND_SLICE :: time.Millisecond // run time per frame for tabs not on screen

KEY_TAB_BASE :: u64(1) << 42 // + 2*index (title) and + 2*index + 1 (close)

// Opens a tab, optionally loading `location`. A new active tab without a
// location gets the address bar's focus.
new_tab :: proc(b: ^Browser, location := "", activate := true) -> ^Tab {
	t := new(Tab)
	append(&b.tabs, t)
	if activate || b.active == nil {
		switch_tab(b, t)
	}
	if location != "" {
		prev := b.cur
		b.cur = t
		open_location(b, location)
		b.cur = prev if !activate else t
	} else if activate {
		set_address_focus(b, true)
	}
	b.dirty = true
	return t
}

switch_tab :: proc(b: ^Browser, t: ^Tab) {
	if b.active == t {
		return
	}
	set_address_focus(b, false)
	b.active = t
	b.cur = t
	b.lay_valid = false // the window may have been resized meanwhile
	b.find_focus = false
	update_text_input(b)
	update_title(b)
	b.dirty = true
}

tab_index :: proc(b: ^Browser, t: ^Tab) -> int {
	for x, i in b.tabs {
		if x == t {
			return i
		}
	}
	return -1
}

// Closes a tab. Returns false when it was the last one (the window should close).
close_tab :: proc(b: ^Browser, t: ^Tab) -> bool {
	i := tab_index(b, t)
	if i < 0 {
		return true
	}
	prev := b.cur
	b.cur = t
	close_page_gracefully(b)
	unload_page(b)
	if t.job != nil {
		// The fetch thread holds no reference to the tab, only to its job;
		// joining is bounded by the protocol's I/O timeouts.
		thread.join(t.job.thread)
		thread.destroy(t.job.thread)
		proto.fetch_result_destroy(&t.job.result)
		delete(t.job.location)
		free(t.job)
	}
	for h in t.history {
		delete(h)
	}
	delete(t.history)
	delete(t.page_path)
	delete(t.error)
	delete(t.message)
	delete(t.publisher)
	delete(t.texts)
	delete(t.textures)
	delete(t.matches)
	field.destroy(&t.input)
	layout.result_destroy(&t.lay)
	free(t)
	ordered_remove(&b.tabs, i)
	b.cur = prev

	if len(b.tabs) == 0 {
		b.active, b.cur = nil, nil
		return false
	}
	if b.active == t {
		b.active = nil
		switch_tab(b, b.tabs[min(i, len(b.tabs) - 1)])
	} else if prev == t {
		b.cur = b.active
	}
	b.dirty = true
	return true
}

cycle_tab :: proc(b: ^Browser, backwards: bool) {
	n := len(b.tabs)
	i := tab_index(b, b.active)
	switch_tab(b, b.tabs[(i + (n - 1 if backwards else 1)) % n])
}

tab_title :: proc(t: ^Tab) -> string {
	switch {
	case t.job != nil:
		return "Loading…"
	case t.loaded && t.page.image.manifest.title != "":
		return t.page.image.manifest.title
	case t.page_path != "":
		if u, ok := proto.parse_url(t.page_path); ok {
			return u.host if u.path == "/" else filepath.base(u.path)
		}
		return filepath.base(t.page_path)
	}
	return "New tab"
}

update_title :: proc(b: ^Browser) {
	if b.cur != b.active || b.cur == nil {
		return
	}
	_ = sdl.SetWindowTitle(b.window, fmt.ctprintf("%s — Nota Bene", tab_title(b.cur)))
}

// Lets every tab make progress: finished loads are applied and pages run,
// background ones on a smaller time slice so the visible tab stays smooth.
run_tabs :: proc(b: ^Browser) {
	poll_data_fetches(b)
	for t in b.tabs {
		b.cur = t
		poll_fetch(b)
		run_page(b, 8 * time.Millisecond if t == b.active else BACKGROUND_SLICE)
		if t.loaded && host.page_check_timeout(&t.page) {
			t.busy_since = {}
		}
	}
	b.cur = b.active
}

@(private = "file")
tab_width :: proc(b: ^Browser, vw: f32) -> f32 {
	return clamp((vw - NEW_TAB_WIDTH) / f32(max(len(b.tabs), 1)), MIN_TAB_WIDTH, MAX_TAB_WIDTH)
}

@(private = "file")
close_rect :: proc(tab: layout.Rect) -> layout.Rect {
	return {tab.x + tab.w - 24, 6, 18, 18}
}

draw_tabbar :: proc(b: ^Browser, vw: f32) {
	fill_rect(b, {0, 0, vw, TABBAR_HEIGHT}, {0xE4, 0xE7, 0xEB, 0xFF})
	w := tab_width(b, vw)
	font := layout.Font {
		size = 13,
	}
	muted := layout.Color{0x55, 0x5B, 0x65, 0xFF}
	for t, i in b.tabs {
		r := layout.Rect{f32(i) * w, 0, w, TABBAR_HEIGHT}
		if r.x >= vw {
			break
		}
		if t == b.active {
			fill_rect(b, r, {0xF8, 0xF9, 0xFA, 0xFF})
		} else if i > 0 && b.tabs[i - 1] != b.active {
			fill_rect(b, {r.x, 7, 1, TABBAR_HEIGHT - 14}, {0xC4, 0xC9, 0xD0, 0xFF})
		}
		title := tab_title(t)
		_, th := measure_text(&b.fonts, title, font, 0)
		clip := sdl.Rect {
			i32((r.x + 10) * b.scale),
			0,
			i32(max(r.w - 38, 0) * b.scale),
			i32(TABBAR_HEIGHT * b.scale),
		}
		sdl.SetRenderClipRect(b.renderer, &clip)
		draw_text(
			b,
			KEY_TAB_BASE + 2 * u64(i),
			title,
			font,
			0,
			b.theme.text if t == b.active else muted,
			r.x + 10,
			(TABBAR_HEIGHT - th) / 2,
		)
		sdl.SetRenderClipRect(b.renderer, nil)
		c := close_rect(r)
		cw, ch := measure_text(&b.fonts, "×", font, 0)
		draw_text(
			b,
			KEY_TAB_BASE + 2 * u64(i) + 1,
			"×",
			font,
			0,
			muted,
			c.x + (c.w - cw) / 2,
			c.y + (c.h - ch) / 2,
		)
	}
	plus := layout.Rect{f32(len(b.tabs)) * w, 0, NEW_TAB_WIDTH, TABBAR_HEIGHT}
	if plus.x < vw {
		pw, ph := measure_text(&b.fonts, "+", {size = 18}, 0)
		draw_text(
			b,
			KEY_TAB_BASE - 1,
			"+",
			{size = 18},
			0,
			muted,
			plus.x + (plus.w - pw) / 2,
			(TABBAR_HEIGHT - ph) / 2,
		)
	}
}

// Left click: switch, close (×) or open (+). Middle click on a tab closes it.
tabbar_click :: proc(b: ^Browser, x, y: f32, middle: bool) {
	vw, _ := viewport_size(b)
	w := tab_width(b, vw)
	i := int(x / w)
	if i >= len(b.tabs) {
		if !middle && x < f32(len(b.tabs)) * w + NEW_TAB_WIDTH {
			new_tab(b)
		}
		return
	}
	t := b.tabs[i]
	r := layout.Rect{f32(i) * w, 0, w, TABBAR_HEIGHT}
	if middle || layout.rect_contains(close_rect(r), x, y) {
		if !close_tab(b, t) {
			b.quit = true
		}
		return
	}
	switch_tab(b, t)
}

tabbar_cursor :: proc(b: ^Browser, x, y: f32) -> sdl.SystemCursor {
	vw, _ := viewport_size(b)
	if x < f32(len(b.tabs)) * tab_width(b, vw) + NEW_TAB_WIDTH {
		return .POINTER
	}
	return .DEFAULT
}

draw_blank_tab :: proc(b: ^Browser, vw: f32) {
	_, vh := viewport_size(b)
	hint := "Type an nb:// address, a file, or host/path above (Ctrl+L)."
	font := layout.Font {
		size = 15,
	}
	tw, th := measure_text(&b.fonts, hint, font, 0)
	draw_text(
		b,
		KEY_BANNER,
		hint,
		font,
		0,
		{0x8A, 0x90, 0x99, 0xFF},
		max((vw - tw) / 2, 16),
		CHROME_HEIGHT + vh / 3 - th / 2,
	)
}

// Frees the cached text objects of every tab (used when the display scale changes).
clear_all_text_caches :: proc(b: ^Browser) {
	for t in b.tabs {
		for key, c in t.texts {
			ttf.DestroyText(c.text)
			delete(c.str)
			delete_key(&t.texts, key)
		}
		t.lay_valid = false
	}
}
