package main

import "core:fmt"
import "core:strings"

import sdl "vendor:sdl3"

import "../../abi"
import "../../field"
import "../../host"
import "../../layout"

INTERACTIVE :: bit_set[abi.Node_Kind]{.Button, .Link, .Input, .Text_Area, .Canvas}

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
	b.input.scroll_x, b.input.scroll_y, b.input.seen_caret = 0, 0, -1
	b.input.goal_x = nil
	b.input.multiline = false
	if n := host.node_get(&b.page, h); n != nil && n.kind in abi.EDITABLE {
		b.input.multiline = n.kind == .Text_Area
		field.set_text(&b.input, n.text)
		if n.selection_set {
			// The page placed the selection before the user got here.
			n.selection_set = false
			field.select_range(&b.input, n.anchor, n.caret)
		} else {
			field.move(&b.input, .End)
		}
	}
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

// Moves focus to the next (or previous) Input or Text_Area in document order.
cycle_focus :: proc(b: ^Browser, backwards: bool) {
	inputs := make([dynamic]abi.Handle, context.temp_allocator)
	current := -1
	for item in b.lay.items {
		if item.kind in abi.EDITABLE {
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

// A click at logical window coordinates. Ctrl+click and middle click open
// links in a new background tab.
click :: proc(b: ^Browser, x, y: f32, mods: abi.Modifiers, middle := false, clicks := 1) {
	if y < TABBAR_HEIGHT {
		tabbar_click(b, x, y, middle)
		return
	}
	if y < CHROME_HEIGHT {
		toolbar_click(b, x, y, mods, clicks)
		return
	}
	set_address_focus(b, false)
	if find_bar_contains(b, x, y) {
		_, vh := viewport_size(b)
		if layout.rect_contains(find_field_inner(b, CHROME_HEIGHT + vh), x, y) || b.find_focus {
			b.find_focus = true
			update_text_input(b)
			field_press(b, .Find, x, y, mods, clicks)
		}
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
		begin_selection(b, x, dy, clicks, mods) // the margin beside text still selects it
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
		begin_selection(b, x, dy, clicks, mods)
		target = hit
	} else {
		clear_selection(b)
	}
	item := b.lay.items[target]
	editable := item.kind in abi.EDITABLE
	set_focus(b, item.handle if editable else abi.INVALID_HANDLE)
	if editable {
		field_press(b, .Input, x, y, mods, clicks)
	}
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
				cursor = .TEXT if b.lay.items[t].kind in abi.EDITABLE else .POINTER
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
	if b.field_drag != .None {
		field_drag_to(b, x, y)
		return
	}
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
	case key == sdl.K_F7:
		b.caret_browsing = !b.caret_browsing
		ensure_caret(b)
		reset_caret_blink(b)
		set_message(b, "caret browsing on" if b.caret_browsing else "caret browsing off")
	case key == sdl.K_F3:
		if !b.find_open {
			open_find(b)
		} else {
			step_match(b, .Shift in mods)
		}
	case ctrl && key == 'a' && focused_field(b) == .None:
		select_all(b)
	case ctrl && key == 'c' && focused_field(b) == .None && selection_nonempty(b):
		_ = sdl.SetClipboardText(strings.clone_to_cstring(selected_text(b), context.temp_allocator))
		set_message(b, "copied the selection")
	case ctrl && key == 'v' && focused_field(b) != .None:
		// A paste arrives like typing, so a page Input sees Text events.
		if text, ok := clipboard_text(focused_field(b) == .Input && b.input.multiline); ok {
			handle_text(b, text, typing = false)
		}
	case:
		return false
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
			if handled, _ := field_key(b, &b.address, e.key, mods); !handled {
				address_key(b, e.key)
			}
		}
		return // the page does not see keys typed into the address bar
	}
	if b.find_focus {
		if e.down {
			if handled, changed := field_key(b, &b.find, e.key, mods); changed {
				refresh_matches(b)
			} else if !handled {
				find_key(b, e.key, mods)
			}
		}
		return
	}
	if !e.down && focused_field(b) == .Input && is_edit_key(e.key, mods, b.input.multiline) {
		return // the page saw neither the press nor this release
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
		case focused_field(b) == .Input:
			// Editing and caret keys belong to the browser; the page sees the
			// result as a Change event.
			if b.input.multiline && is_enter(e.key) && .Ctrl not_in mods {
				handle_text(b, "\n") // Ctrl+Enter goes on to the page
				return
			}
			if handled, changed := field_key(b, &b.input, e.key, mods); handled {
				if changed {
					commit_input(b)
				}
				return
			}
			if e.key == sdl.K_ESCAPE {
				set_focus(b, abi.INVALID_HANDLE)
				return
			}
		case is_enter(e.key) && caret_link(b) != "":
			// Caret browsing: Enter follows the link the caret is in.
			navigate(b, caret_link(b), new_tab_ = .Ctrl in mods)
			return
		case caret_key(b, e.key, mods):
			// The caret (or Shift+arrows, the selection) moved instead of scrolling.
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

// Typed (or, with typing = false, pasted) text for the focused field.
handle_text :: proc(b: ^Browser, text: string, typing := true) {
	switch focused_field(b) {
	case .Address:
		field.insert(&b.address, text, typing)
		b.dirty = true
		return
	case .Find:
		field.insert(&b.find, text, typing)
		refresh_matches(b)
		return
	case .Input:
		b.input.max_len = abi.MAX_TEXT_LEN
		if field.insert(&b.input, text, typing) {
			commit_input(b)
		}
	case .None:
	}
	for r in text {
		push_event(b, abi.Event{kind = .Text, handle = b.focus, a = i64(r)})
	}
}

is_enter :: proc(key: sdl.Keycode) -> bool {
	return key == sdl.K_RETURN || key == sdl.K_RETURN2 || key == sdl.K_KP_ENTER
}

// Keys that field_key handles, so their release is not passed on either.
// A Text_Area also keeps the line keys and Enter (but not Ctrl+Enter).
is_edit_key :: proc(key: sdl.Keycode, mods: abi.Modifiers, multiline := false) -> bool {
	switch key {
	case sdl.K_LEFT, sdl.K_RIGHT, sdl.K_HOME, sdl.K_END, sdl.K_BACKSPACE, sdl.K_DELETE:
		return true
	case sdl.K_UP, sdl.K_DOWN, sdl.K_PAGEUP, sdl.K_PAGEDOWN:
		return multiline
	case sdl.K_RETURN, sdl.K_RETURN2, sdl.K_KP_ENTER:
		return multiline && .Ctrl not_in mods
	case 'a', 'c', 'x', 'v', 'y', 'z':
		return .Ctrl in mods
	}
	return false
}

dump_tree :: proc(b: ^Browser) {
	if !b.loaded {
		return
	}
	sb := strings.builder_make(context.temp_allocator)
	host.dump_tree(&b.page, &sb)
	fmt.print(strings.to_string(sb))
}
