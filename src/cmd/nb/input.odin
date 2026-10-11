package main

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

import sdl "vendor:sdl3"

import "../../abi"
import "../../host"
import "../../layout"

INTERACTIVE :: bit_set[abi.Node_Kind]{.Button, .Link, .Input, .Canvas}

modifiers :: proc(mod: sdl.Keymod) -> abi.Modifiers {
	m: abi.Modifiers
	if mod & {.LSHIFT, .RSHIFT} != {} { m += {.Shift} }
	if mod & {.LCTRL, .RCTRL} != {}   { m += {.Ctrl} }
	if mod & {.LALT, .RALT} != {}     { m += {.Alt} }
	if mod & {.LGUI, .RGUI} != {}     { m += {.Super} }
	return m
}

// SDL keycode -> abi key value. Printable keys are already Unicode code points.
map_key :: proc(k: sdl.Keycode) -> (i64, bool) {
	switch k {
	case sdl.K_LEFT:      return i64(abi.Key.Left), true
	case sdl.K_RIGHT:     return i64(abi.Key.Right), true
	case sdl.K_UP:        return i64(abi.Key.Up), true
	case sdl.K_DOWN:      return i64(abi.Key.Down), true
	case sdl.K_HOME:      return i64(abi.Key.Home), true
	case sdl.K_END:       return i64(abi.Key.End), true
	case sdl.K_PAGEUP:    return i64(abi.Key.Page_Up), true
	case sdl.K_PAGEDOWN:  return i64(abi.Key.Page_Down), true
	case sdl.K_RETURN2, sdl.K_KP_ENTER: return i64(abi.Key.Enter), true
	}
	if u32(k) & sdl.K_SCANCODE_MASK != 0 {
		return 0, false // function keys and other non-character keys
	}
	return i64(k), true
}

set_focus :: proc(b: ^Browser, h: abi.Handle) {
	if b.focus == h {
		return
	}
	b.focus = h
	update_text_input(b)
	b.dirty = true
}

// Text input (and the on-screen keyboard, where there is one) is on while
// the address bar or a page Input has focus.
update_text_input :: proc(b: ^Browser) {
	if b.address_focus || b.find_focus || b.focus != abi.INVALID_HANDLE {
		_ = sdl.StartTextInput(b.window)
	} else {
		_ = sdl.StopTextInput(b.window)
	}
}

// Moves focus to the next (or previous) Input in document order.
cycle_focus :: proc(b: ^Browser, backwards: bool) {
	inputs := make([dynamic]abi.Handle, context.temp_allocator)
	current := -1
	for item in b.lay.items {
		if item.kind == .Input {
			if item.handle == b.focus {
				current = len(inputs)
			}
			append(&inputs, item.handle)
		}
	}
	if len(inputs) == 0 {
		return
	}
	next := 0
	if current >= 0 {
		next = (current + (len(inputs) - 1 if backwards else 1)) % len(inputs)
	}
	set_focus(b, inputs[next])
}

push_event :: proc(b: ^Browser, ev: abi.Event) {
	if b.loaded && (b.page.state == .Running || b.page.state == .Waiting) {
		host.page_push_event(&b.page, ev)
	}
}

// A click at logical window coordinates.
// A click at logical window coordinates. Ctrl+click and middle click open
// links in a new background tab.
click :: proc(b: ^Browser, x, y: f32, mods: abi.Modifiers, middle := false, clicks := 1) {
	if y < TABBAR_HEIGHT {
		tabbar_click(b, x, y, middle)
		return
	}
	if y < CHROME_HEIGHT {
		toolbar_click(b, x, y)
		return
	}
	set_address_focus(b, false)
	if find_bar_contains(b, x, y) {
		b.find_focus = true
		update_text_input(b)
		b.dirty = true
		return
	}
	if b.find_focus {
		b.find_focus = false
		update_text_input(b)
		b.dirty = true
	}
	_, dy, inside := to_document(b, x, y)
	if !b.lay_valid || !inside {
		return
	}
	hit := layout.hit_test(&b.lay, x, dy)
	if hit < 0 {
		set_focus(b, abi.INVALID_HANDLE)
		begin_selection(b, x, dy, clicks) // the margin beside text still selects it
		return
	}
	if link := layout.find_ancestor(&b.lay, hit, {.Link}); link >= 0 && b.lay.items[link].href != "" {
		navigate(b, b.lay.items[link].href, new_tab_ = middle || .Ctrl in mods)
		return
	}
	if middle {
		return
	}
	target := layout.find_ancestor(&b.lay, hit, INTERACTIVE)
	if target < 0 {
		// Plain content: pressing here starts a text selection.
		begin_selection(b, x, dy, clicks)
		target = hit
	} else {
		clear_selection(b)
	}
	item := b.lay.items[target]
	set_focus(b, item.handle if item.kind == .Input else abi.INVALID_HANDLE)
	origin := item.text_rect if item.kind == .Canvas else item.rect
	push_event(b, abi.Event {
		kind   = .Click,
		handle = item.handle,
		a      = i64(x - origin.x),
		b      = i64(dy - origin.y),
		c      = transmute(i64)mods,
	})
}

hover :: proc(b: ^Browser, x, y: f32) {
	href := ""
	cursor := sdl.SystemCursor.DEFAULT
	if y >= TABBAR_HEIGHT && y < CHROME_HEIGHT {
		cursor = toolbar_cursor(b, x, y)
	} else if y < TABBAR_HEIGHT {
		cursor = tabbar_cursor(b, x, y)
	}
	if _, dy, inside := to_document(b, x, y); b.lay_valid && inside {
		if hit := layout.hit_test(&b.lay, x, dy); hit >= 0 {
			if link := layout.find_ancestor(&b.lay, hit, {.Link}); link >= 0 {
				href = b.lay.items[link].href
				cursor = .POINTER
			} else if t := layout.find_ancestor(&b.lay, hit, INTERACTIVE); t >= 0 {
				cursor = .TEXT if b.lay.items[t].kind == .Input else .POINTER
			}
		}
	}
	_ = sdl.SetCursor(b.cursors[cursor])
	if href != b.hover_href {
		delete(b.hover_href)
		b.hover_href = strings.clone(href)
		b.dirty = true
	}
}

// Mouse moved with the left button held: extend the selection, scrolling
// when the pointer leaves the content area.
drag :: proc(b: ^Browser, x, y: f32) {
	if !b.selecting {
		return
	}
	_, vh := viewport_size(b)
	if y < CHROME_HEIGHT {
		scroll_by(b, -SCROLL_STEP / 2)
	} else if y >= CHROME_HEIGHT + vh {
		scroll_by(b, SCROLL_STEP / 2)
	}
	cy := clamp(y, CHROME_HEIGHT, CHROME_HEIGHT + vh - 1)
	extend_selection(b, x, cy - CHROME_HEIGHT + b.scroll_y)
}

scroll_by :: proc(b: ^Browser, dy: f32) {
	_, vh := viewport_size(b)
	old := b.scroll_y
	b.scroll_y += dy
	clamp_scroll(b, vh)
	if b.scroll_y != old {
		b.dirty = true
	}
}

// Edits the focused Input. Returns true if the key was consumed.
edit_input :: proc(b: ^Browser, key: sdl.Keycode) -> bool {
	n := host.node_get(&b.page, b.focus)
	if n == nil {
		return false
	}
	switch key {
	case sdl.K_BACKSPACE:
		if len(n.text) > 0 {
			_, size := utf8.decode_last_rune_in_string(n.text)
			host.page_input_edit(&b.page, b.focus, n.text[:len(n.text) - size])
		}
		return true
	case sdl.K_ESCAPE:
		set_focus(b, abi.INVALID_HANDLE)
		return true
	}
	return false
}

// Window-level keys, handled before the page or the address bar sees them.
browser_shortcut :: proc(b: ^Browser, key: sdl.Keycode, mods: abi.Modifiers) -> bool {
	ctrl := .Ctrl in mods
	switch {
	case key == sdl.K_F6 || (ctrl && key == 'l'):
		set_address_focus(b, true)
	case ctrl && key == 't':
		new_tab(b)
	case ctrl && key == 'w':
		if !close_tab(b, b.active) {
			b.quit = true
		}
	case ctrl && key == sdl.K_TAB:
		cycle_tab(b, .Shift in mods)
	case ctrl && key >= '1' && key <= '9':
		if i := int(key - '1'); i < len(b.tabs) {
			switch_tab(b, b.tabs[i] if key != '9' else b.tabs[len(b.tabs) - 1])
		}
	case ctrl && key == 'f':
		open_find(b)
	case key == sdl.K_F3:
		if !b.find_open {
			open_find(b)
		} else {
			step_match(b, .Shift in mods)
		}
	case ctrl && key == 'a':
		switch {
		case b.address_focus:
			b.address_select_all = true
			b.dirty = true
		case b.find_focus:
			b.find_select_all = true
			b.dirty = true
		case b.focus != abi.INVALID_HANDLE:
			return false // a page Input: let the page see it
		case:
			select_all(b)
		}
	case ctrl && (key == 'c' || key == 'x' || key == 'v'):
		return clipboard_key(b, key)
	case:
		return false
	}
	return true
}

// Copy, cut and paste for whatever text field has focus: the address bar or
// a page Input. Without one, the keys go to the page as usual.
clipboard_key :: proc(b: ^Browser, key: sdl.Keycode) -> bool {
	current: string
	input: ^host.Node
	switch {
	case b.address_focus:
		current = strings.to_string(b.address)
	case b.find_focus:
		current = strings.to_string(b.find_query)
	case b.focus != abi.INVALID_HANDLE:
		input = host.node_get(&b.page, b.focus)
		if input == nil {
			return false
		}
		current = input.text
	case b.has_selection && key == 'c':
		_ = sdl.SetClipboardText(strings.clone_to_cstring(selected_text(b), context.temp_allocator))
		set_message(b, "copied the selection")
		return true
	case:
		return false
	}
	switch key {
	case 'c', 'x':
		_ = sdl.SetClipboardText(strings.clone_to_cstring(current, context.temp_allocator))
		if key == 'x' {
			if b.address_focus {
				strings.builder_reset(&b.address)
				b.dirty = true
			} else if b.find_focus {
				strings.builder_reset(&b.find_query)
				refresh_matches(b)
			} else {
				host.page_input_edit(&b.page, b.focus, "")
			}
		}
	case 'v':
		raw := sdl.GetClipboardText()
		if raw == nil {
			return true
		}
		defer sdl.free(raw)
		// Inputs are single-line: newlines become spaces.
		pasted, _ := strings.replace_all(string(cstring(raw)), "\n", " ", context.temp_allocator)
		pasted, _ = strings.replace_all(pasted, "\r", "", context.temp_allocator)
		handle_text(b, pasted)
	}
	return true
}

handle_key :: proc(b: ^Browser, e: sdl.KeyboardEvent) {
	mods := modifiers(e.mod)
	if e.down && browser_shortcut(b, e.key, mods) {
		return
	}
	if b.address_focus {
		if e.down {
			address_key(b, e.key)
		}
		return // the page does not see keys typed into the address bar
	}
	if b.find_focus {
		if e.down {
			find_key(b, e.key, mods)
		}
		return
	}
	if e.down {
		switch {
		case e.key == sdl.K_F5 || (e.key == 'r' && .Ctrl in mods):
			reload(b)
			return
		case e.key == sdl.K_LEFT && .Alt in mods:
			go_back(b)
			return
		case e.key == sdl.K_F12:
			dump_tree(b)
			return
		case e.key == sdl.K_TAB:
			cycle_focus(b, .Shift in mods)
		case b.focus != abi.INVALID_HANDLE:
			if edit_input(b, e.key) {
				return
			}
		case:
			_, vh := viewport_size(b)
			switch e.key {
			case sdl.K_DOWN:     scroll_by(b, SCROLL_STEP)
			case sdl.K_UP:       scroll_by(b, -SCROLL_STEP)
			case sdl.K_PAGEDOWN, sdl.K_SPACE: scroll_by(b, vh - SCROLL_STEP)
			case sdl.K_PAGEUP:   scroll_by(b, -(vh - SCROLL_STEP))
			case sdl.K_HOME:     scroll_by(b, -b.scroll_y)
			case sdl.K_END:      scroll_by(b, b.lay.height)
			}
		}
	}
	if code, ok := map_key(e.key); ok {
		push_event(b, abi.Event {
			kind   = .Key,
			handle = b.focus,
			a      = code,
			b      = transmute(i64)mods,
			c      = 1 if e.down else 0,
		})
	}
}

handle_text :: proc(b: ^Browser, text: string) {
	if b.address_focus {
		address_type(b, text)
		return
	}
	if b.find_focus {
		find_type(b, text)
		return
	}
	if n := host.node_get(&b.page, b.focus); n != nil && n.kind == .Input {
		joined := strings.concatenate({n.text, text}, context.temp_allocator)
		if len(joined) <= abi.MAX_TEXT_LEN {
			host.page_input_edit(&b.page, b.focus, joined)
		}
	}
	for r in text {
		push_event(b, abi.Event{kind = .Text, handle = b.focus, a = i64(r)})
	}
}

dump_tree :: proc(b: ^Browser) {
	if !b.loaded {
		return
	}
	sb := strings.builder_make(context.temp_allocator)
	host.dump_tree(&b.page, &sb)
	fmt.print(strings.to_string(sb))
}
