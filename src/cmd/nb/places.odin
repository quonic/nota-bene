package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import sdl "vendor:sdl3"

import "../../abi"
import "../../field"
import "../../layout"
import "../../places"
import "../../proto"

// History and bookmarks. Both lists belong to the browser, not to pages:
// no syscall reads them. The panel that shows them is drawn by the browser
// over the content area, like the find bar.

Panel_Kind :: enum {
	None,
	History,
	Bookmarks,
}

HISTORY_HEADER  :: "Nota Bene history"
BOOKMARK_HEADER :: "Nota Bene bookmarks"

// Panel geometry, in logical px.
@(private = "file") PANEL_MAX_W  :: 680
@(private = "file") PANEL_MARGIN :: 8
@(private = "file") PANEL_HEADER :: 44
@(private = "file") PANEL_ROW    :: 46
@(private = "file") PANEL_FOOTER :: 26

PANEL_TITLE_FONT :: layout.Font{size = 15, bold = true}
PANEL_FONT       :: layout.Font{size = 14}
PANEL_SMALL_FONT :: layout.Font{size = 12}

KEY_PANEL_FILTER :: KEY_STATUS_LEFT + 30 // its low bits name its field slot (fieldtext.odin)
KEY_PANEL_BASE   :: u64(1) << 43 // + 8*row slot + part; the panel's own labels sit below it

@(private = "file") MUTED      :: layout.Color{0x55, 0x5B, 0x65, 0xFF}
@(private = "file") FAINT      :: layout.Color{0x8A, 0x90, 0x99, 0xFF}
@(private = "file") SELECTED   :: layout.Color{0xE8, 0xF0, 0xFE, 0xFF}
@(private = "file") EDGE       :: layout.Color{0xC4, 0xC9, 0xD0, 0xFF}
@(private = "file") SEPARATOR  :: layout.Color{0xEE, 0xEF, 0xF2, 0xFF}
@(private = "file") HEADER_BG  :: layout.Color{0xF8, 0xF9, 0xFA, 0xFF}

// Loads both lists. A second browser on the same profile does not get the
// lock and keeps its lists read-only, so neither drops the other's visits.
places_init :: proc(b: ^Browser) {
	path := proc(b: ^Browser, name: string) -> string {
		p, _ := filepath.join({b.profile, name}, context.temp_allocator)
		return p
	}
	locked: bool
	b.places_lock, locked = places.lock_profile(b.profile)
	if !places.load(&b.visited, path(b, "history"), places.HISTORY_LIMIT) {
		fmt.eprintfln("nb: cannot read %s; it will not be changed", b.visited.path)
	}
	if !places.load(&b.bookmarks, path(b, "bookmarks"), places.BOOKMARK_LIMIT) {
		fmt.eprintfln("nb: cannot read %s; it will not be changed", b.bookmarks.path)
	}
	if !locked {
		b.places_shared = true
		b.visited.read_only = true
		b.bookmarks.read_only = true
		fmt.eprintfln("nb: another browser is using %s; history and bookmarks will not be saved", b.profile)
	}
}

places_destroy :: proc(b: ^Browser) {
	places.destroy(&b.visited)
	places.destroy(&b.bookmarks)
	places.unlock_profile(&b.places_lock)
	field.destroy(&b.panel_filter)
	clear_rows(b)
	delete(b.panel_rows)
}

@(private = "file")
unix_now :: proc() -> i64 {
	return time.time_to_unix(time.now())
}

// The key a location is stored under: nb:// addresses as they are, files
// by absolute path, so an entry opens from any working directory.
place_key :: proc(location: string) -> string {
	if location == "" || proto.is_nb_url(location) {
		return location
	}
	abs, err := os.get_absolute_path(location, context.temp_allocator)
	return abs if err == nil else location
}

// Saves a list after a change, and drops rows the change removed from the
// panel. A read-only list is not saved; the status bar says so once.
@(private = "file")
list_changed :: proc(b: ^Browser, l: ^places.List) {
	header := HISTORY_HEADER if l == &b.visited else BOOKMARK_HEADER
	if l.read_only {
		if !b.places_warned {
			b.places_warned = true
			set_message(b, "%s", not_saved_reason(b, l))
		}
	} else if !places.save(l, header) {
		fmt.eprintfln("nb: cannot save %s", l.path)
	}
	if panel_list(b) == l {
		prune_rows(b)
	}
}

// Records a page that just loaded. Without a manifest title the page's
// first heading names it once the page has built one (update_visit_title).
record_visit :: proc(b: ^Browser, location: string) {
	title := b.page.image.manifest.title
	b.title_pending = title == ""
	if places.visit(&b.visited, place_key(location), title, unix_now()) {
		list_changed(b, &b.visited)
	}
}

// Called after each layout of the current tab: names a pending history
// entry after the page's first heading.
update_visit_title :: proc(b: ^Browser) {
	if !b.title_pending {
		return
	}
	h := heading_text(b)
	if h == "" {
		return
	}
	b.title_pending = false
	if places.set_title(&b.visited, place_key(b.page_path), h) {
		list_changed(b, &b.visited)
	}
}

// Why changes to a read-only list are not saved (temp-allocated).
@(private = "file")
not_saved_reason :: proc(b: ^Browser, l: ^places.List) -> string {
	if b.places_shared {
		return "another Nota Bene window uses this profile, so history and bookmarks are not saved"
	}
	return fmt.tprintf("cannot read %s, so it is not saved", l.path)
}

// A note for a status message about a change to `l`: empty, or why the
// change will not last.
@(private = "file")
unsaved_note :: proc(b: ^Browser, l: ^places.List) -> string {
	return fmt.tprintf(" (%s)", not_saved_reason(b, l)) if l.read_only else ""
}

// The text of the page's first Heading, inline children included (temp-allocated).
@(private = "file")
heading_text :: proc(b: ^Browser) -> string {
	if !b.lay_valid {
		return ""
	}
	for item, i in b.lay.items {
		if item.kind != .Heading {
			continue
		}
		sb := strings.builder_make(context.temp_allocator)
		strings.write_string(&sb, item.text)
		// Items are in pre-order: the heading's descendants follow it.
		for j in i + 1 ..< len(b.lay.items) {
			if layout.find_ancestor(&b.lay, b.lay.items[j].parent, {.Heading}) != i {
				break
			}
			strings.write_string(&sb, b.lay.items[j].text)
		}
		return places.clean_title(strings.to_string(sb), context.temp_allocator)
	}
	return ""
}

// What to call the current page: its manifest title, else its first heading.
page_title :: proc(b: ^Browser) -> string {
	if b.loaded && b.page.image.manifest.title != "" {
		return b.page.image.manifest.title
	}
	return heading_text(b)
}

is_bookmarked :: proc(b: ^Browser) -> bool {
	return b.page_path != "" && places.contains(&b.bookmarks, place_key(b.page_path))
}

// Ctrl+D and the star: bookmarks the current page, or removes its bookmark.
toggle_bookmark :: proc(b: ^Browser) {
	if b.page_path == "" {
		return
	}
	title := page_title(b)
	name := title if title != "" else b.page_path
	switch places.toggle(&b.bookmarks, place_key(b.page_path), title, unix_now()) {
	case .Added:
		list_changed(b, &b.bookmarks)
		set_message(b, "bookmarked %s%s", name, unsaved_note(b, &b.bookmarks) if b.bookmarks.read_only else " (Ctrl+Shift+O shows bookmarks)")
	case .Removed:
		list_changed(b, &b.bookmarks)
		set_message(b, "removed the bookmark for %s%s", name, unsaved_note(b, &b.bookmarks))
	case .Refused:
		set_message(b, "cannot bookmark %s: its address has control characters", name)
	}
}

@(private = "file")
panel_list :: proc(b: ^Browser) -> ^places.List {
	switch b.panel {
	case .History:   return &b.visited
	case .Bookmarks: return &b.bookmarks
	case .None:
	}
	return nil
}

// Ctrl+H and Ctrl+Shift+O: opens the panel on `kind`, or closes it if it
// already shows that list.
toggle_panel :: proc(b: ^Browser, kind: Panel_Kind) {
	if b.panel == kind {
		close_panel(b)
		return
	}
	set_address_focus(b, false)
	b.find_focus = false
	if b.panel == .None {
		field.select_all(&b.panel_filter) // typing replaces the last filter
	}
	b.panel = kind
	refresh_panel(b)
	update_text_input(b)
	b.dirty = true
}

close_panel :: proc(b: ^Browser) {
	if b.panel == .None {
		return
	}
	b.panel = .None
	if b.field_drag == .Panel {
		b.field_drag = .None
	}
	update_text_input(b)
	b.dirty = true
}

@(private = "file")
clear_rows :: proc(b: ^Browser) {
	for r in b.panel_rows {
		delete(r)
	}
	clear(&b.panel_rows)
}

// Lists the entries that match the filter, newest first, and selects the
// first. Only opening the panel and editing the filter do this: visits made
// while the panel is open (opening a row in a new tab, a page loading in the
// background) must not move rows under the keyboard or the mouse.
refresh_panel :: proc(b: ^Browser) {
	l := panel_list(b)
	if l == nil {
		return
	}
	clear_rows(b)
	for i in places.filter(l, field.text(&b.panel_filter), context.temp_allocator) {
		append(&b.panel_rows, strings.clone(l.entries[i].location))
	}
	b.panel_sel, b.panel_top = 0, 0
	b.dirty = true
}

// Drops the rows whose entries are gone (removed, or past the history
// limit), keeping the order. The selection stays on its entry, or, if that
// went, on the row that moves up into its place.
@(private = "file")
prune_rows :: proc(b: ^Browser) {
	l := panel_list(b)
	sel := b.panel_sel
	for i := len(b.panel_rows) - 1; i >= 0; i -= 1 {
		if !places.contains(l, b.panel_rows[i]) {
			delete(b.panel_rows[i])
			ordered_remove(&b.panel_rows, i)
			if i < sel {
				sel -= 1
			}
		}
	}
	b.panel_sel = clamp(sel, 0, max(len(b.panel_rows) - 1, 0))
	keep_selection_visible(b)
	b.dirty = true
}

// The entry row `i` shows, looked up by its location.
@(private = "file")
row_entry :: proc(l: ^places.List, b: ^Browser, i: int) -> (places.Entry, bool) {
	if i < 0 || i >= len(b.panel_rows) {
		return {}, false
	}
	k := places.find(l, b.panel_rows[i])
	if k < 0 {
		return {}, false
	}
	return l.entries[k], true
}

// How many rows fit in the window.
@(private = "file")
panel_capacity :: proc(b: ^Browser) -> int {
	_, vh := viewport_size(b)
	return max(int((vh - 2 * PANEL_MARGIN - PANEL_HEADER - PANEL_FOOTER) / PANEL_ROW), 1)
}

@(private = "file")
keep_selection_visible :: proc(b: ^Browser) {
	n := panel_capacity(b)
	if b.panel_sel < b.panel_top {
		b.panel_top = b.panel_sel
	} else if b.panel_sel >= b.panel_top + n {
		b.panel_top = b.panel_sel - n + 1
	}
	b.panel_top = clamp(b.panel_top, 0, max(len(b.panel_rows) - n, 0))
}

@(private = "file")
panel_rect :: proc(b: ^Browser) -> layout.Rect {
	vw, _ := viewport_size(b)
	w := min(PANEL_MAX_W, vw - 2 * PANEL_MARGIN)
	rows := clamp(len(b.panel_rows), 1, panel_capacity(b))
	return {(vw - w) / 2, CHROME_HEIGHT + PANEL_MARGIN, w, PANEL_HEADER + f32(rows) * PANEL_ROW + PANEL_FOOTER}
}

@(private = "file")
panel_filter_rect :: proc(b: ^Browser) -> layout.Rect {
	p := panel_rect(b)
	lw, _ := measure_text(&b.fonts, "Bookmarks", PANEL_TITLE_FONT, 0) // the wider label, so the field does not move
	x := p.x + 12 + lw + 16
	return {x, p.y + 9, p.x + p.w - 12 - x, PANEL_HEADER - 18}
}

// The filter's text box, inside its border.
panel_filter_inner :: proc(b: ^Browser) -> layout.Rect {
	r := panel_filter_rect(b)
	return {r.x + 6, r.y, r.w - 12, r.h}
}

@(private = "file")
row_rect :: proc(b: ^Browser, slot: int) -> layout.Rect {
	p := panel_rect(b)
	return {p.x + 1, p.y + PANEL_HEADER + f32(slot) * PANEL_ROW, p.w - 2, PANEL_ROW}
}

@(private = "file")
delete_rect :: proc(row: layout.Rect) -> layout.Rect {
	return {row.x + row.w - 32, row.y + (row.h - 22) / 2, 22, 22}
}

panel_contains :: proc(b: ^Browser, x, y: f32) -> bool {
	return b.panel != .None && layout.rect_contains(panel_rect(b), x, y)
}

// The row (index into panel_rows) under (x, y), or -1.
@(private = "file")
row_at :: proc(b: ^Browser, x, y: f32) -> int {
	if !panel_contains(b, x, y) {
		return -1
	}
	for slot in 0 ..< panel_capacity(b) {
		i := b.panel_top + slot
		if i >= len(b.panel_rows) {
			break
		}
		if layout.rect_contains(row_rect(b, slot), x, y) {
			return i
		}
	}
	return -1
}

// Opens row `i`: in this tab (closing the panel), or in a new background
// tab (the panel stays, so several can be opened).
@(private = "file")
open_row :: proc(b: ^Browser, i: int, in_new_tab: bool) {
	if i < 0 || i >= len(b.panel_rows) {
		return
	}
	location := strings.clone(b.panel_rows[i], context.temp_allocator)
	if in_new_tab {
		new_tab(b, location, activate = false)
		set_message(b, "opened %s in a new tab", location)
		return
	}
	close_panel(b)
	open_location(b, location)
}

@(private = "file")
delete_row :: proc(b: ^Browser, i: int) {
	l := panel_list(b)
	if l == nil || i < 0 || i >= len(b.panel_rows) {
		return
	}
	places.remove_location(l, b.panel_rows[i])
	b.panel_sel = i
	list_changed(b, l) // the next row moves up into the selected one
	set_message(b, "removed from %s%s", "history" if l == &b.visited else "bookmarks", unsaved_note(b, l))
}

// Keys for the panel that are not editing keys of its filter.
panel_key :: proc(b: ^Browser, key: sdl.Keycode, mods: abi.Modifiers) -> bool {
	n := len(b.panel_rows)
	move :: proc(b: ^Browser, to: int) {
		b.panel_sel = clamp(to, 0, max(len(b.panel_rows) - 1, 0))
		keep_selection_visible(b)
		b.dirty = true
	}
	switch {
	case key == sdl.K_ESCAPE:
		close_panel(b)
	case key == sdl.K_DOWN:
		move(b, b.panel_sel + 1)
	case key == sdl.K_UP:
		move(b, b.panel_sel - 1)
	case key == sdl.K_PAGEDOWN:
		move(b, b.panel_sel + panel_capacity(b))
	case key == sdl.K_PAGEUP:
		move(b, b.panel_sel - panel_capacity(b))
	case is_enter(key):
		if n > 0 {
			open_row(b, b.panel_sel, in_new_tab = .Ctrl in mods)
		}
	case key == sdl.K_DELETE && .Shift in mods:
		delete_row(b, b.panel_sel)
	case:
		return false
	}
	return true
}

// A click at window coordinates in the content area while the panel is
// open. Outside the panel it closes it; the page never sees the click. A
// click that opens a row or closes the panel also swallows the rest of a
// double or triple click, which would otherwise land on the page (or open
// the row again).
panel_click :: proc(b: ^Browser, x, y: f32, mods: abi.Modifiers, middle: bool, clicks: int) {
	if !panel_contains(b, x, y) {
		close_panel(b)
		b.swallow_clicks = true
		return
	}
	if layout.rect_contains(panel_filter_rect(b), x, y) && !middle {
		field_press(b, .Panel, x, y, mods, clicks)
		return
	}
	i := row_at(b, x, y)
	if i < 0 {
		return
	}
	if !middle && layout.rect_contains(delete_rect(row_rect(b, i - b.panel_top)), x, y) {
		delete_row(b, i)
		return
	}
	b.panel_sel = i
	b.swallow_clicks = true
	open_row(b, i, in_new_tab = middle || .Ctrl in mods)
}

panel_wheel :: proc(b: ^Browser, x, y, dy: f32) -> bool {
	if !panel_contains(b, x, y) {
		return false
	}
	if dy == 0 {
		return true // sideways: nothing to scroll, but not the page's either
	}
	step := 3 if dy > 0 else -3
	b.panel_top = clamp(b.panel_top + step, 0, max(len(b.panel_rows) - panel_capacity(b), 0))
	b.dirty = true
	return true
}

panel_cursor :: proc(b: ^Browser, x, y: f32) -> sdl.SystemCursor {
	switch {
	case layout.rect_contains(panel_filter_rect(b), x, y):
		return .TEXT
	case row_at(b, x, y) >= 0:
		return .POINTER
	}
	return .DEFAULT
}

draw_panel :: proc(b: ^Browser) {
	l := panel_list(b)
	if l == nil {
		return
	}
	p := panel_rect(b)
	// A soft shadow, then the panel.
	fill_rect(b, {p.x - 1, p.y, p.w + 2, p.h + 3}, {0, 0, 0, 0x10})
	fill_rect(b, {p.x, p.y + 1, p.w, p.h + 5}, {0, 0, 0, 0x0C})
	fill_rect(b, p, b.theme.page)
	fill_rect(b, {p.x, p.y, p.w, PANEL_HEADER}, HEADER_BG)
	fill_rect(b, {p.x, p.y + PANEL_HEADER - 1, p.w, 1}, EDGE)

	label := "History" if b.panel == .History else "Bookmarks"
	_, lh := measure_text(&b.fonts, label, PANEL_TITLE_FONT, 0)
	draw_text(b, KEY_PANEL_BASE - 1, label, PANEL_TITLE_FONT, 0, b.theme.text, p.x + 12, p.y + (PANEL_HEADER - lh) / 2)

	box := panel_filter_rect(b)
	inner := panel_filter_inner(b)
	_, th := measure_text(&b.fonts, "", PANEL_FONT, 0)
	ty := box.y + (box.h - th) / 2
	fill_rect(b, box, b.theme.input)
	stroke_rect(b, box, b.theme.focus, 2)
	filter := field.text(&b.panel_filter)
	if filter == "" {
		draw_text(b, KEY_PANEL_BASE - 2, "Filter by title or address", PANEL_FONT, 0, FAINT, inner.x, ty)
	}
	draw_field(b, KEY_PANEL_FILTER, filter, PANEL_FONT, b.theme.text, inner, ty, &b.panel_filter)
	sdl.SetRenderClipRect(b.renderer, nil)

	now := unix_now()
	if len(b.panel_rows) == 0 {
		msg: string
		switch {
		case filter != "":
			msg = "Nothing matches."
		case b.panel == .History:
			msg = "No history yet."
		case:
			msg = "No bookmarks yet. Ctrl+D bookmarks the page you are on."
		}
		r := row_rect(b, 0)
		_, mh := measure_text(&b.fonts, msg, PANEL_FONT, 0)
		draw_text(b, KEY_PANEL_BASE - 3, msg, PANEL_FONT, 0, MUTED, r.x + 12, r.y + (r.h - mh) / 2)
	}
	for slot in 0 ..< panel_capacity(b) {
		i := b.panel_top + slot
		if i >= len(b.panel_rows) {
			break
		}
		e, ok := row_entry(l, b, i)
		if !ok {
			continue
		}
		r := row_rect(b, slot)
		key := KEY_PANEL_BASE + 8 * u64(slot)
		if i == b.panel_sel {
			fill_rect(b, r, SELECTED)
			fill_rect(b, {r.x, r.y, 3, r.h}, b.theme.focus)
		} else if slot > 0 {
			fill_rect(b, {r.x + 12, r.y, r.w - 24, 1}, SEPARATOR)
		}

		age := places.age_text(e.time, now)
		aw, _ := measure_text(&b.fonts, age, PANEL_SMALL_FONT, 0)
		del := delete_rect(r)
		draw_text(b, key + 2, age, PANEL_SMALL_FONT, 0, FAINT, del.x - 10 - aw, r.y + 7)
		xw, xh := measure_text(&b.fonts, "×", PANEL_FONT, 0)
		draw_text(b, key + 3, "×", PANEL_FONT, 0, MUTED, del.x + (del.w - xw) / 2, del.y + (del.h - xh) / 2)

		text_w := max(del.x - 10 - aw - 12 - (r.x + 12), 0)
		clip := sdl.Rect{i32((r.x + 12) * b.scale), i32(r.y * b.scale), i32(text_w * b.scale), i32(r.h * b.scale)}
		sdl.SetRenderClipRect(b.renderer, &clip)
		title := e.title if e.title != "" else e.location
		draw_text(b, key, title, PANEL_FONT, 0, b.theme.text, r.x + 12, r.y + 6)
		loc_clip := sdl.Rect{clip.x, clip.y, i32((del.x - 10 - (r.x + 12)) * b.scale), clip.h}
		sdl.SetRenderClipRect(b.renderer, &loc_clip)
		draw_text(b, key + 1, e.location, PANEL_SMALL_FONT, 0, MUTED, r.x + 12, r.y + 26)
		sdl.SetRenderClipRect(b.renderer, nil)
	}

	foot := p.y + p.h - PANEL_FOOTER
	fill_rect(b, {p.x, foot, p.w, 1}, SEPARATOR)
	hint := "Enter: open · Ctrl+Enter: new tab · Shift+Delete: remove · Esc: close"
	_, hh := measure_text(&b.fonts, hint, PANEL_SMALL_FONT, 0)
	clip := sdl.Rect{i32(p.x * b.scale), i32(foot * b.scale), i32((p.w - 90) * b.scale), i32(PANEL_FOOTER * b.scale)}
	sdl.SetRenderClipRect(b.renderer, &clip)
	draw_text(b, KEY_PANEL_BASE - 4, hint, PANEL_SMALL_FONT, 0, FAINT, p.x + 12, foot + (PANEL_FOOTER - hh) / 2)
	sdl.SetRenderClipRect(b.renderer, nil)
	count := fmt.tprintf("%d of %d", len(b.panel_rows), len(l.entries)) if filter != "" else fmt.tprintf("%d", len(b.panel_rows))
	cw, _ := measure_text(&b.fonts, count, PANEL_SMALL_FONT, 0)
	draw_text(b, KEY_PANEL_BASE - 5, count, PANEL_SMALL_FONT, 0, FAINT, p.x + p.w - 12 - cw, foot + (PANEL_FOOTER - hh) / 2)

	stroke_rect(b, p, EDGE)
}
