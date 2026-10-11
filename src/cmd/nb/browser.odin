package main

import "core:crypto/blake2b"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

import "../../abi"
import "../../host"
import "../../layout"
import "../../loader"
import "../../proto"

TABBAR_HEIGHT     :: 30
TOOLBAR_HEIGHT    :: 40
CHROME_HEIGHT     :: TABBAR_HEIGHT + TOOLBAR_HEIGHT // everything above the content
STATUS_BAR_HEIGHT :: 24
SCROLL_STEP       :: 48
UNRESPONSIVE      :: 5 * time.Second
RUN_SLICE         :: 200_000

Cached_Text :: struct {
	text:  ^ttf.Text,
	str:   string,
	key:   Font_Key,
	wrap:  i32,
}

Cached_Canvas :: struct {
	tex:     ^sdl.Texture,
	w, h:    int,
	version: u64,
}

// Everything that belongs to one page view. The browser's `cur` tab is
// reachable directly through `using`, so most code just says b.page.
Tab :: struct {
	page:        host.Page,
	loaded:      bool,
	page_path:   string,
	error:       string, // load error or why the page stopped
	message:     string, // transient status-bar message
	history:     [dynamic]string,

	lay:         layout.Result,
	lay_version: u64,
	lay_width:   f32,
	lay_valid:   bool,
	scroll_y:    f32,
	focus:       abi.Handle,
	input:       Text_Field, // the focused Input's text, caret and undo (fields.odin)
	hover_href:  string,
	busy_since:  time.Tick,
	painted:     u64, // page.paint_version at the last frame

	texts:    map[u64]Cached_Text,
	canvases: map[abi.Handle]Cached_Canvas,

	job:       ^Fetch_Job, // network load in progress (net.odin)
	publisher: string,     // fingerprint of the current page's publisher, if signed
	serial:    u64,        // identifies the loaded page, so late fetch answers for an earlier one are dropped

	// Text selection (select.odin)
	has_selection: bool, // a selection, possibly empty: where the user last clicked in page text
	selecting:     bool, // the mouse button is down, extending the selection
	sel_anchor:    Text_Pos,
	sel_focus:     Text_Pos,
	sel_goal_x:    f32,      // where Shift+Up/Down aim, so a column is kept across short lines
	sel_goal_at:   Text_Pos, // the focus sel_goal_x was set for; any other move invalidates it

	// Find in page (find.odin)
	find_open:       bool,
	matches:         [dynamic]Match,
	current_match:   int,
	matches_version: u64, // lay_version the matches were computed for
}

Browser :: struct {
	window:   ^sdl.Window,
	renderer: ^sdl.Renderer,
	engine:   ^ttf.TextEngine,
	scale:    f32,
	fonts:    Fonts,
	theme:    layout.Theme,
	cursors:  [sdl.SystemCursor]^sdl.Cursor,
	mem_cfg:  loader.Config,
	dirty:    bool,
	quit:     bool,

	// Tabs (tabs.odin). `cur` is the tab being worked on: normally the active
	// one, briefly a background tab while it runs or finishes loading.
	tabs:      [dynamic]^Tab,
	active:    ^Tab,
	using cur: ^Tab,

	// Network (net.odin)
	known_hosts: proto.Known_Hosts,
	cache:       map[string]Cached_Page,
	profile:     string, // directory for known_hosts and site storage
	fetches:     [dynamic]^Data_Fetch, // pages' own requests, from every tab
	last_serial: u64,

	// Address bar (chrome.odin)
	address:       Text_Field,
	address_focus: bool,

	// Find bar (find.odin); the query is shared by all tabs
	find:       Text_Field,
	find_focus: bool,

	field_drag: Field_Target, // the field a mouse drag is selecting in

	// Caret blinking (fields.odin)
	caret_since:    time.Tick, // when the blink cycle last restarted
	caret_shown:    bool,      // whether the last frame drew the caret
	window_focused: bool,
	no_blink:       bool, // scripted runs keep the caret solid, so screenshots are repeatable
}

// Logical (layout) size of the content area, which sits between the
// toolbar and the status bar.
viewport_size :: proc(b: ^Browser) -> (w, h: f32) {
	iw, ih: i32
	sdl.GetWindowSize(b.window, &iw, &ih)
	return f32(iw), max(f32(ih) - CHROME_HEIGHT - STATUS_BAR_HEIGHT, 1)
}

// Converts window coordinates to document coordinates; ok is false outside the content area.
to_document :: proc(b: ^Browser, x, y: f32) -> (dx, dy: f32, ok: bool) {
	_, vh := viewport_size(b)
	if y < CHROME_HEIGHT || y >= CHROME_HEIGHT + vh {
		return
	}
	return x, y - CHROME_HEIGHT + b.scroll_y, true
}

set_message :: proc(b: ^Browser, format: string, args: ..any) {
	delete(b.message)
	b.message = fmt.aprintf(format, ..args)
	b.dirty = true
}

set_error :: proc(b: ^Browser, format: string, args: ..any) {
	delete(b.error)
	b.error = fmt.aprintf(format, ..args)
	b.dirty = true
}

page_log :: proc(p: ^host.Page, level: abi.Log_Level, msg: string) {
	switch level {
	case .Info:  fmt.printfln("[page] %s", msg)
	case .Warn:  fmt.printfln("[page] warning: %s", msg)
	case .Error: fmt.printfln("[page] error: %s", msg)
	}
}

unload_page :: proc(b: ^Browser) {
	for _, c in b.texts {
		ttf.DestroyText(c.text)
		delete(c.str)
	}
	clear(&b.texts)
	for _, c in b.canvases {
		sdl.DestroyTexture(c.tex)
	}
	clear(&b.canvases)
	if b.loaded {
		host.page_destroy(&b.page)
		b.loaded = false
	}
	clear(&b.lay.items)
	b.lay_valid = false
	b.focus = abi.INVALID_HANDLE
	b.scroll_y = 0
	b.has_selection = false
	b.selecting = false
	clear(&b.matches)
	delete(b.hover_href)
	b.hover_href = ""
	delete(b.error)
	b.error = ""
	update_text_input(b)
}

// Opens a location: a local file path or an nb:// URL. Network loads finish
// asynchronously (see net.odin).
open_location :: proc(b: ^Browser, location: string, push_history := true) {
	if proto.is_nb_url(location) {
		start_fetch(b, location, push_history)
		return
	}
	data, err := os.read_entire_file(location, context.allocator)
	if err != nil {
		begin_page(b, location, push_history)
		set_error(b, "cannot read %s: %v", location, err)
		return
	}
	defer delete(data)
	abs, _ := os.get_absolute_path(location, context.temp_allocator)
	load_page(b, location, data, push_history, origin = strings.concatenate({"file:", abs}, context.temp_allocator))
}

// Where a site's storage lives: one file per origin under the profile. The
// file name is a hash, so origins never have to be valid file names.
storage_path :: proc(b: ^Browser, origin: string) -> string {
	ctx: blake2b.Context
	digest: [16]u8
	blake2b.init(&ctx, len(digest))
	blake2b.update(&ctx, transmute([]u8)origin)
	blake2b.final(&ctx, digest[:])
	name := strings.concatenate({string(hex.encode(digest[:], context.temp_allocator)), ".cbor"}, context.temp_allocator)
	path, _ := filepath.join({b.profile, "storage", name}, context.temp_allocator)
	return path
}

// Replaces the current page with a blank one at `location`.
@(private)
begin_page :: proc(b: ^Browser, location: string, push_history: bool) {
	unload_page(b)
	if push_history {
		append(&b.history, strings.clone(location))
	}
	delete(b.page_path)
	b.page_path = strings.clone(location)
	update_title(b)
}

// Starts the page executable `elf`, shown at `location`. `origin` names the
// site for storage: pages from the same origin share a store.
load_page :: proc(b: ^Browser, location: string, elf: []u8, push_history := true, origin := "") -> bool {
	begin_page(b, location, push_history)
	if lerr := host.page_init(&b.page, elf, b.mem_cfg); lerr != nil {
		set_error(b, "cannot load %s: %v", location, lerr)
		return false
	}
	b.loaded = true
	b.last_serial += 1
	b.serial = b.last_serial
	b.page.log_proc = page_log
	b.page.fetch_proc = page_fetch
	b.page.user_data = b
	if origin != "" {
		host.page_attach_storage(&b.page, storage_path(b, origin))
	}
	for key in b.page.image.manifest.unknown {
		fmt.eprintfln("nb: warning: unknown manifest key %q in %s", key, location)
	}
	for entry in b.page.image.manifest.fetch {
		if !host.fetch_entry_valid(entry) {
			fmt.eprintfln("nb: warning: ignoring manifest line \"fetch %s\" in %s: not an nb:// address or a /path", entry, location)
		}
	}

	update_title(b)

	w, h := viewport_size(b)
	host.page_push_event(&b.page, abi.Event{kind = .Resize, a = i64(w), b = i64(h)})
	b.busy_since = {}
	b.dirty = true
	return true
}

go_back :: proc(b: ^Browser) {
	if len(b.history) < 2 {
		return
	}
	delete(pop(&b.history))
	open_location(b, b.history[len(b.history) - 1], push_history = false)
}

reload :: proc(b: ^Browser) {
	if b.page_path != "" {
		open_location(b, strings.clone(b.page_path, context.temp_allocator), push_history = false)
	}
}

// Follows a link. Relative links resolve against the current location: for
// nb:// pages that is a URL on the same server, for local pages a file
// beside the current one.
navigate :: proc(b: ^Browser, href: string, new_tab_ := false) {
	target, ok := resolve_href(b, href)
	if !ok {
		set_message(b, "unsupported link: %s", href)
		return
	}
	if new_tab_ {
		new_tab(b, target, activate = false)
		set_message(b, "opened %s in a new tab", target)
		return
	}
	open_location(b, target)
}

// The location a link on the current page points to (temp-allocated).
resolve_href :: proc(b: ^Browser, href: string) -> (string, bool) {
	if proto.is_nb_url(href) {
		return href, true
	}
	if strings.contains(href, "://") {
		return "", false
	}
	if base, ok := proto.parse_url(b.page_path); ok {
		return proto.resolve_ref(base, href, context.temp_allocator)
	}
	target := strings.trim_prefix(href, "file:")
	if !filepath.is_abs(target) {
		target, _ = filepath.join({filepath.dir(b.page_path), target}, context.temp_allocator)
	}
	return target, true
}

// Runs the page for at most `max_time`, tracking whether it has stopped yielding.
run_page :: proc(b: ^Browser, max_time: time.Duration) {
	if !b.loaded || b.page.state != .Running {
		b.busy_since = {}
		return
	}
	start := time.tick_now()
	if b.busy_since == {} {
		b.busy_since = start
	}
	for b.page.state == .Running && time.tick_since(start) < max_time {
		host.page_run(&b.page, RUN_SLICE)
	}
	#partial switch b.page.state {
	case .Running:
		if time.tick_since(b.busy_since) > UNRESPONSIVE {
			host.page_kill(&b.page, "unresponsive: ran for 5 s without waiting for events")
		}
	case:
		b.busy_since = {}
	}
	report_stop(b)
}

report_stop :: proc(b: ^Browser) {
	if b.error != "" || !b.loaded {
		return
	}
	#partial switch b.page.state {
	case .Exited:
		if b.page.exit_code != 0 {
			set_error(b, "The page exited with code %d.", b.page.exit_code)
		}
	case .Faulted:
		set_error(b, "The page crashed: %s", describe_fault(&b.page))
	case .Killed:
		set_error(b, "The page was stopped: %s", b.page.kill_reason)
	}
}

// Lays the page out again if the tree or the viewport width changed.
update_layout :: proc(b: ^Browser) {
	if !b.loaded {
		return
	}
	w, h := viewport_size(b)
	if b.lay_valid && b.lay_version == b.page.tree_version && b.lay_width == w {
		return
	}
	layout.layout(&b.page, w, layout.Measurer{data = &b.fonts, measure = measure_text}, b.theme, &b.lay)
	first_layout := b.lay_version == 0 || len(b.matches) == 0
	b.lay_version = b.page.tree_version
	b.lay_width = w
	b.lay_valid = true
	clamp_scroll(b, h)
	b.dirty = true
	if b.find_open {
		keep := b.current_match
		refresh_matches(b, scroll = first_layout)
		if !first_layout && keep >= 0 && len(b.matches) > 0 {
			b.current_match = min(keep, len(b.matches) - 1)
		}
	}

	// Forget cached text and canvases for nodes that are gone.
	live := make(map[abi.Handle]bool, len(b.lay.items), context.temp_allocator)
	for item in b.lay.items {
		live[item.handle] = true
	}
	for key, c in b.texts {
		stale_node := key < 1 << 32 && !live[abi.Handle(key)]
		stale_frag := key >= KEY_FRAG_BASE && int(key - KEY_FRAG_BASE) >= len(b.lay.fragments)
		if stale_node || stale_frag {
			ttf.DestroyText(c.text)
			delete(c.str)
			delete_key(&b.texts, key)
		}
	}
	for h, c in b.canvases {
		if !live[h] {
			sdl.DestroyTexture(c.tex)
			delete_key(&b.canvases, h)
		}
	}
	if b.focus != abi.INVALID_HANDLE && !live[b.focus] {
		b.focus = abi.INVALID_HANDLE
		update_text_input(b)
	}
}

clamp_scroll :: proc(b: ^Browser, viewport_h: f32) {
	b.scroll_y = clamp(b.scroll_y, 0, max(b.lay.height - viewport_h, 0))
}
