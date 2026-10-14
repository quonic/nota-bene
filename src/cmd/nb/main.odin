// nb is the Nota Bene window: it runs a page and shows its view tree.
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

import "../../abi"
import "../../field"
import "../../host"
import "../../layout"
import "../../loader"
import "../../proto"

USAGE :: `usage: nb [options] LOCATION

LOCATION is a page file (page.elf) or an nb:// address (nb://host/path).

options:
  --size WxH          initial window size in px (default 900x700)
  --font FILE         TrueType font to use (also: NB_FONT)
  --mem SIZE          guest memory per page (default 64M)
  --profile DIR       pinned server keys and site storage (default ~/.config/new-browser)
  --click X,Y         after the page settles, click at X,Y (repeatable)
  --middle-click X,Y  after the page settles, middle-click at X,Y (repeatable)
  --double-click X,Y  after the page settles, double-click at X,Y (repeatable)
  --triple-click X,Y  after the page settles, triple-click at X,Y (repeatable)
  --shift-click X,Y   after the page settles, Shift+click at X,Y (repeatable)
  --drag X1,Y1,X2,Y2  after the page settles, drag with the left button (repeatable)
  --print-clipboard   print the clipboard's text to stdout (for scripted checks)
  --type TEXT         after the page settles, type TEXT (repeatable)
  --key NAME          after the page settles, press a key: enter, escape, tab, backspace,
                      delete, left, right, up, down, home, end or a letter, optionally
                      with ctrl+ and/or shift+ in front (repeatable)
  --screenshot FILE   save a PNG of the window after the page settles, then exit
  -h, --help          show this help

keys: Ctrl+L / F6 address bar, F5 / Ctrl+R reload, Alt+Left back,
      Tab next input, F12 dump the view tree; in text fields, Shift and Ctrl
      with the arrows select and move by word, Ctrl+Z / Ctrl+Y undo and redo;
      in a text area, Enter adds a line and Ctrl+Enter goes to the page;
      on page text, Shift+arrows, Home and End extend the selection
`

Action :: struct {
	kind:   enum {
		Click,
		Middle_Click,
		Double_Click,
		Triple_Click,
		Drag,
		Type,
		Key,
		Print_Clipboard,
	},
	x2, y2: f32,
	key:    sdl.Keycode,
	mod:    sdl.Keymod,
	x, y:   f32,
	text:   string,
}

Options :: struct {
	path:       string,
	width:      i32,
	height:     i32,
	font:       string,
	mem:        loader.Config,
	actions:    [dynamic]Action,
	screenshot: string,
	profile:    string,
}

main :: proc() {
	opts, ok := parse_args(os.args[1:])
	if !ok {
		fmt.eprint(USAGE)
		os.exit(2)
	}
	os.exit(run(opts))
}

run :: proc(opts: Options) -> int {
	if !sdl.Init({.VIDEO}) {
		fmt.eprintfln("nb: cannot initialise SDL: %s", sdl.GetError())
		return 1
	}
	defer sdl.Quit()
	if !ttf.Init() {
		fmt.eprintfln("nb: cannot initialise SDL_ttf: %s", sdl.GetError())
		return 1
	}
	defer ttf.Quit()

	b: Browser
	b.theme = layout.DEFAULT_THEME
	b.window_focused = true
	b.caret_since = time.tick_now()
	b.mem_cfg = opts.mem
	if !sdl.CreateWindowAndRenderer(
		"Nota Bene",
		opts.width,
		opts.height,
		{.RESIZABLE, .HIGH_PIXEL_DENSITY},
		&b.window,
		&b.renderer,
	) {
		fmt.eprintfln("nb: cannot create a window: %s", sdl.GetError())
		return 1
	}
	defer sdl.DestroyWindow(b.window)
	defer sdl.DestroyRenderer(b.renderer)
	sdl.SetRenderVSync(b.renderer, 1)
	sdl.SetRenderDrawBlendMode(b.renderer, {.BLEND})
	b.scale = display_scale(&b)

	font := opts.font
	if font == "" {
		font = os.get_env("NB_FONT", context.temp_allocator)
	}
	if !fonts_init(&b.fonts, font, b.scale) {
		fmt.eprintln("nb: no usable font found; pass one with --font FILE")
		return 1
	}
	defer fonts_destroy(&b.fonts)
	b.engine = ttf.CreateRendererTextEngine(b.renderer)
	if b.engine == nil {
		fmt.eprintfln("nb: cannot create a text engine: %s", sdl.GetError())
		return 1
	}
	defer ttf.DestroyRendererTextEngine(b.engine)
	for c in sdl.SystemCursor {
		b.cursors[c] = sdl.CreateSystemCursor(c)
	}

	b.profile = opts.profile if opts.profile != "" else proto.config_dir(context.temp_allocator)
	kh_path, _ := filepath.join({b.profile, "known_hosts"}, context.temp_allocator)
	proto.known_hosts_load(&b.known_hosts, kh_path)
	b.pool = proto.pool_create()
	defer net_shutdown(&b)
	defer field.destroy(&b.address)
	defer field.destroy(&b.find)

	new_tab(&b, opts.path)
	defer {
		for len(b.tabs) > 0 {
			close_tab(&b, b.tabs[len(b.tabs) - 1])
		}
		delete(b.tabs)
	}

	// Scripted actions and screenshots run once the page has settled: it is
	// waiting for events (or has stopped) and has been laid out.
	next_action := 0
	automating := len(opts.actions) > 0 || opts.screenshot != ""
	b.no_blink = automating

	for !b.quit {
		run_tabs(&b)
		sync_selection(&b) // a selection the page placed shows in this frame
		update_layout(&b)
		if focused_field(&b) != .None && caret_visible(&b) != b.caret_shown {
			b.dirty = true
		}
		if b.dirty || (b.loaded && b.painted != b.page.paint_version) {
			render(&b)
		}

		if automating && settled(&b) {
			if next_action < len(opts.actions) {
				a := opts.actions[next_action]
				next_action += 1
				switch a.kind {
				case .Click:
					click(&b, a.x, a.y, modifiers(a.mod))
					end_selection(&b)
				case .Middle_Click:
					click(&b, a.x, a.y, {}, middle = true)
				case .Double_Click:
					click(&b, a.x, a.y, {}, clicks = 2)
					end_selection(&b)
				case .Triple_Click:
					click(&b, a.x, a.y, {}, clicks = 3)
					end_selection(&b)
				case .Drag:
					click(&b, a.x, a.y, {})
					for step in 1 ..= 8 { 	// move in steps, like a real pointer
						t := f32(step) / 8
						drag(&b, a.x + (a.x2 - a.x) * t, a.y + (a.y2 - a.y) * t)
					}
					end_selection(&b)
				case .Print_Clipboard:
					if raw := sdl.GetClipboardText(); raw != nil {
						fmt.printfln("clipboard: %q", string(cstring(raw)))
						sdl.free(raw)
					}
				case .Type:
					handle_text(&b, a.text)
				case .Key:
					handle_key(&b, {key = a.key, mod = a.mod, down = true})
					handle_key(&b, {key = a.key, mod = a.mod, down = false})
				}
				continue
			}
			if opts.screenshot != "" {
				render(&b)
				return save_screenshot(&b, opts.screenshot)
			}
			automating = false
		}

		ev: sdl.Event
		if sdl.WaitEventTimeout(&ev, wait_timeout(&b, automating)) {
			handle_event(&b, ev)
			for !b.quit && sdl.PollEvent(&ev) {
				handle_event(&b, ev)
			}
		}
		sync_selection(&b) // one Select per frame, however far the user dragged
	}
	return 0
}

settled :: proc(b: ^Browser) -> bool {
	if len(b.fetches) > 0 {
		return false
	}
	for t in b.tabs {
		if t.job != nil {
			return false
		}
	}
	if !b.loaded {
		return true
	}
	return b.page.state != .Running && b.lay_valid && b.lay_version == b.page.tree_version
}

// How long to block waiting for window events: not at all while any page is
// running, briefly while a fetch is in flight, until the nearest page timer
// or caret blink otherwise.
wait_timeout :: proc(b: ^Browser, automating: bool) -> i32 {
	if automating {
		return 0
	}
	timeout: i32 = -1
	if len(b.fetches) > 0 {
		timeout = 15 // pages' own requests: their answers arrive without a window event
	}
	if ms := caret_next_toggle_ms(b); ms >= 0 {
		timeout = ms if timeout < 0 else min(timeout, ms)
	}
	for t in b.tabs {
		switch {
		case t.loaded && t.page.state == .Running:
			return 0
		case t.job != nil:
			timeout = 15 if timeout < 0 else min(timeout, 15)
		case t.loaded && t.page.state == .Waiting && t.page.wait_until != max(i64):
			ms := i32(
				clamp(
					(t.page.wait_until - host.page_now(&t.page)) / i64(time.Millisecond),
					0,
					1000,
				),
			)
			timeout = ms if timeout < 0 else min(timeout, ms)
		}
	}
	return timeout
}

handle_event :: proc(b: ^Browser, ev: sdl.Event) {
	#partial switch ev.type {
	case .QUIT, .WINDOW_CLOSE_REQUESTED:
		b.quit = true
	case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_DISPLAY_SCALE_CHANGED:
		if s := display_scale(b); s != b.scale {
			b.scale = s
			b.fonts.scale = s
			fonts_clear(&b.fonts)
			clear_all_text_caches(b)
		}
		w, h := viewport_size(b)
		for t in b.tabs {
			b.cur = t
			push_event(b, abi.Event{kind = .Resize, a = i64(w), b = i64(h)})
		}
		b.cur = b.active
		b.dirty = true
	case .WINDOW_EXPOSED:
		b.dirty = true
	case .WINDOW_FOCUS_GAINED:
		b.window_focused = true
		reset_caret_blink(b)
	case .WINDOW_FOCUS_LOST:
		b.window_focused = false
		b.dirty = true
	case .MOUSE_MOTION:
		hover(b, ev.motion.x, ev.motion.y)
		if .LEFT in ev.motion.state {
			drag(b, ev.motion.x, ev.motion.y)
		}
	case .MOUSE_BUTTON_UP:
		if ev.button.button == 1 {
			end_selection(b)
		}
	case .MOUSE_BUTTON_DOWN:
		reset_caret_blink(b)
		switch ev.button.button {
		case 1:
			click(
				b,
				ev.button.x,
				ev.button.y,
				modifiers(sdl.GetModState()),
				clicks = int(ev.button.clicks),
			)
		case 2:
			click(b, ev.button.x, ev.button.y, modifiers(sdl.GetModState()), middle = true)
		}
	case .MOUSE_WHEEL:
		if !area_wheel(b, ev.wheel.mouse_x, ev.wheel.mouse_y, -ev.wheel.y * SCROLL_STEP) {
			scroll_by(b, -ev.wheel.y * SCROLL_STEP)
		}
	case .KEY_DOWN, .KEY_UP:
		if ev.type == .KEY_DOWN {
			reset_caret_blink(b)
		}
		handle_key(b, ev.key)
	case .TEXT_INPUT:
		reset_caret_blink(b)
		handle_text(b, string(ev.text.text))
	}
}

// Gives the page a chance to handle Quit before its tab or the window closes.
close_page_gracefully :: proc(b: ^Browser) {
	if !b.loaded || (b.page.state != .Running && b.page.state != .Waiting) {
		return
	}
	host.page_push_event(&b.page, abi.Event{kind = .Quit})
	host.page_run(&b.page, 50_000_000)
}

display_scale :: proc(b: ^Browser) -> f32 {
	pw, lw, h: i32
	sdl.GetWindowSizeInPixels(b.window, &pw, &h)
	sdl.GetWindowSize(b.window, &lw, &h)
	if lw <= 0 {
		return 1
	}
	return max(f32(pw) / f32(lw), 1)
}

save_screenshot :: proc(b: ^Browser, path: string) -> int {
	surface := sdl.RenderReadPixels(b.renderer, nil)
	if surface == nil {
		fmt.eprintfln("nb: cannot read pixels: %s", sdl.GetError())
		return 1
	}
	defer sdl.DestroySurface(surface)
	if !sdl.SavePNG(surface, strings.clone_to_cstring(path, context.temp_allocator)) {
		fmt.eprintfln("nb: cannot save %s: %s", path, sdl.GetError())
		return 1
	}
	fmt.printfln("nb: saved %s", path)
	return 0
}

parse_args :: proc(args: []string) -> (opts: Options, ok: bool) {
	opts.width, opts.height = 900, 700
	opts.mem = loader.DEFAULT_CONFIG
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		value :: proc(args: []string, i: ^int) -> (string, bool) {
			if i^ + 1 >= len(args) {
				fmt.eprintfln("nb: %s needs a value", args[i^])
				return "", false
			}
			i^ += 1
			return args[i^], true
		}
		pair :: proc(s: string, sep: string) -> (a, b: f32, ok: bool) {
			parts := strings.split(s, sep, context.temp_allocator)
			if len(parts) != 2 {
				return
			}
			a = strconv.parse_f32(parts[0]) or_return
			b = strconv.parse_f32(parts[1]) or_return
			return a, b, true
		}
		switch arg {
		case "-h", "--help":
			fmt.print(USAGE)
			os.exit(0)
		case "--size":
			v := value(args, &i) or_return
			w, h := pair(v, "x") or_return
			opts.width, opts.height = i32(max(w, 200)), i32(max(h, 150))
		case "--font":
			opts.font = value(args, &i) or_return
		case "--mem":
			v := value(args, &i) or_return
			opts.mem.mem_size = loader.parse_size(v) or_return
		case "--click":
			v := value(args, &i) or_return
			x, y := pair(v, ",") or_return
			append(&opts.actions, Action{kind = .Click, x = x, y = y})
		case "--double-click":
			v := value(args, &i) or_return
			x, y := pair(v, ",") or_return
			append(&opts.actions, Action{kind = .Double_Click, x = x, y = y})
		case "--triple-click":
			v := value(args, &i) or_return
			x, y := pair(v, ",") or_return
			append(&opts.actions, Action{kind = .Triple_Click, x = x, y = y})
		case "--shift-click":
			v := value(args, &i) or_return
			x, y := pair(v, ",") or_return
			append(&opts.actions, Action{kind = .Click, x = x, y = y, mod = {.LSHIFT}})
		case "--drag":
			v := value(args, &i) or_return
			parts := strings.split(v, ",", context.temp_allocator)
			if len(parts) != 4 {
				return opts, false
			}
			a := Action {
				kind = .Drag,
			}
			a.x = strconv.parse_f32(parts[0]) or_return
			a.y = strconv.parse_f32(parts[1]) or_return
			a.x2 = strconv.parse_f32(parts[2]) or_return
			a.y2 = strconv.parse_f32(parts[3]) or_return
			append(&opts.actions, a)
		case "--print-clipboard":
			append(&opts.actions, Action{kind = .Print_Clipboard})
		case "--middle-click":
			v := value(args, &i) or_return
			x, y := pair(v, ",") or_return
			append(&opts.actions, Action{kind = .Middle_Click, x = x, y = y})
		case "--type":
			v := value(args, &i) or_return
			append(&opts.actions, Action{kind = .Type, text = v})
		case "--profile":
			opts.profile = value(args, &i) or_return
		case "--key":
			v := value(args, &i) or_return
			key: sdl.Keycode
			mod: sdl.Keymod
			name := v
			for {
				if strings.has_prefix(name, "ctrl+") {
					mod += {.LCTRL}
					name = name[len("ctrl+"):]
				} else if strings.has_prefix(name, "shift+") {
					mod += {.LSHIFT}
					name = name[len("shift+"):]
				} else {
					break
				}
			}
			switch name {
			case "enter":
				key = sdl.K_RETURN
			case "escape":
				key = sdl.K_ESCAPE
			case "tab":
				key = sdl.K_TAB
			case "backspace":
				key = sdl.K_BACKSPACE
			case "delete":
				key = sdl.K_DELETE
			case "left":
				key = sdl.K_LEFT
			case "right":
				key = sdl.K_RIGHT
			case "up":
				key = sdl.K_UP
			case "down":
				key = sdl.K_DOWN
			case "home":
				key = sdl.K_HOME
			case "end":
				key = sdl.K_END
			case:
				if len(name) == 1 && name[0] >= 'a' && name[0] <= 'z' {
					key = sdl.Keycode(name[0])
				} else {
					fmt.eprintfln(
						"nb: --key takes [ctrl+][shift+] and enter, escape, tab, backspace, delete, an arrow, home, end or a letter",
					)
					return opts, false
				}
			}
			append(&opts.actions, Action{kind = .Key, key = key, mod = mod})
		case "--screenshot":
			opts.screenshot = value(args, &i) or_return
		case:
			if strings.has_prefix(arg, "-") || opts.path != "" {
				fmt.eprintfln("nb: unexpected argument %q", arg)
				return opts, false
			}
			opts.path = arg
		}
	}
	return opts, opts.path != ""
}
