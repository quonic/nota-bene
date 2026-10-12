package main

import "core:fmt"
import "core:math"
import "core:strings"

import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

import "../../abi"
import "../../field"
import "../../host"
import "../../layout"
import "../../vm"

// Cache keys for browser-chrome text, kept clear of page handles (< 2^32).
KEY_STATUS_LEFT  :: u64(1) << 40
KEY_STATUS_RIGHT :: KEY_STATUS_LEFT + 1
KEY_BANNER       :: KEY_STATUS_LEFT + 2
KEY_ALT_BASE     :: u64(1) << 41 // + handle: image alt text
KEY_FRAG_BASE    :: u64(1) << 48 // + fragment index: inline text

STATUS_FONT :: layout.Font{size = 13}

describe_fault :: proc(p: ^host.Page) -> string {
	return vm.describe_fault(p.cpu.fault, context.temp_allocator)
}

set_color :: proc(b: ^Browser, c: layout.Color) {
	sdl.SetRenderDrawColor(b.renderer, c.r, c.g, c.b, c.a)
}

// Converts a layout rect (logical px) to a physical-pixel rect.
phys :: proc(b: ^Browser, r: layout.Rect) -> sdl.FRect {
	s := b.scale
	return {math.round(r.x * s), math.round(r.y * s), math.round(r.w * s), math.round(r.h * s)}
}

fill_rect :: proc(b: ^Browser, r: layout.Rect, c: layout.Color) {
	set_color(b, c)
	pr := phys(b, r)
	sdl.RenderFillRect(b.renderer, &pr)
}

stroke_rect :: proc(b: ^Browser, r: layout.Rect, c: layout.Color, thickness: f32 = 1) {
	t := thickness
	fill_rect(b, {r.x, r.y, r.w, t}, c)
	fill_rect(b, {r.x, r.y + r.h - t, r.w, t}, c)
	fill_rect(b, {r.x, r.y, t, r.h}, c)
	fill_rect(b, {r.x + r.w - t, r.y, t, r.h}, c)
}

// Returns the TTF_Text cached under `key`, creating or updating it so it
// holds `str` set in `font` and wrapped at `wrap`. Nil for empty strings.
cached_text :: proc(b: ^Browser, key: u64, str: string, font: layout.Font, wrap: f32) -> ^Cached_Text {
	if len(str) == 0 {
		return nil
	}
	fkey := font_key(&b.fonts, font)
	wpx := wrap_px(&b.fonts, wrap)
	c, ok := &b.texts[key]
	if ok && c.key != fkey {
		ttf.DestroyText(c.text)
		delete(c.str)
		delete_key(&b.texts, key)
		ok = false
	}
	if !ok {
		handle := font_get(&b.fonts, font)
		if handle == nil {
			return nil
		}
		t := ttf.CreateText(b.engine, handle, raw_data(str), uint(len(str)))
		if t == nil {
			return nil
		}
		ttf.SetTextWrapWidth(t, wpx)
		b.texts[key] = {text = t, str = strings.clone(str), key = fkey, wrap = wpx}
		c = &b.texts[key]
	} else {
		if c.str != str {
			ttf.SetTextString(c.text, raw_data(str), uint(len(str)))
			delete(c.str)
			c.str = strings.clone(str)
		}
		if c.wrap != wpx {
			ttf.SetTextWrapWidth(c.text, wpx)
			c.wrap = wpx
		}
	}
	return c
}

// Draws `str` at logical (x, y), reusing the TTF_Text cached under `key`.
draw_text :: proc(b: ^Browser, key: u64, str: string, font: layout.Font, wrap: f32, color: layout.Color, x, y: f32) {
	c := cached_text(b, key, str, font, wrap)
	if c == nil {
		return
	}
	ttf.SetTextColor(c.text, color.r, color.g, color.b, color.a)
	px, py := math.round(x * b.scale), math.round(y * b.scale)
	ttf.DrawRendererText(c.text, px, py)
	if font.underline {
		ascent := f32(ttf.GetFontAscent(ttf.GetTextFont(c.text)))
		thickness := max(math.round(b.scale), 1)
		set_color(b, color)
		for line in 0 ..< c.text.num_lines {
			sub: ttf.SubString
			if !ttf.GetTextSubStringForLine(c.text, line, &sub) {
				continue
			}
			bar := sdl.FRect{px + f32(sub.rect.x), py + f32(sub.rect.y) + ascent + thickness, f32(sub.rect.w), thickness}
			sdl.RenderFillRect(b.renderer, &bar)
		}
	}
}


render :: proc(b: ^Browser) {
	vw, vh := viewport_size(b)
	page_color := b.theme.page
	set_color(b, page_color)
	sdl.RenderClear(b.renderer)

	b.caret_shown = caret_visible(b)
	content := content_clip(b)
	sdl.SetRenderClipRect(b.renderer, &content)
	if b.loaded && b.lay_valid {
		for &item, i in b.lay.items {
			r := item.rect
			r.y -= b.scroll_y
			if r.y > vh || r.y + r.h < 0 {
				continue
			}
			draw_item(b, &item, i, CHROME_HEIGHT - b.scroll_y)
		}
	}
	if b.error != "" {
		draw_banner(b, vw)
	} else if !b.loaded && b.job == nil {
		draw_blank_tab(b, vw)
	}
	sdl.SetRenderClipRect(b.renderer, nil)
	draw_tabbar(b, vw)
	draw_toolbar(b, vw)
	if b.find_open {
		draw_find_bar(b, vw, CHROME_HEIGHT + vh)
	} else {
		draw_status_bar(b, vw, CHROME_HEIGHT + vh)
	}
	sdl.RenderPresent(b.renderer)
	b.dirty = false
	if b.loaded {
		b.painted = b.page.paint_version
	}
}

draw_item :: proc(b: ^Browser, item: ^layout.Item, index: int, dy: f32) {
	st := item.style
	r := item.rect
	r.y += dy
	tr := item.text_rect
	tr.y += dy

	if st.background.a > 0 {
		fill_rect(b, r, st.background)
	}
	focused := item.kind in abi.EDITABLE && item.handle == b.focus && !b.address_focus
	if focused {
		stroke_rect(b, r, b.theme.focus, 2)
	} else if st.border.a > 0 {
		stroke_rect(b, r, st.border)
	}

	#partial switch item.kind {
	case .Canvas:
		draw_canvas(b, item, tr)
		return
	case .Image:
		fill_rect(b, tr, b.theme.placeholder)
		alt := item.alt if item.alt != "" else "image"
		draw_text(b, KEY_ALT_BASE + u64(item.handle), alt, {size = 13}, tr.w - 8, b.theme.text, tr.x + 4, tr.y + 4)
		return
	case .Input:
		// One line; while focused, with the caret and selection kept in view.
		inner := layout.Rect{r.x + st.padding, r.y, r.w - 2 * st.padding, r.h}
		if focused && sync_input(b) {
			draw_field(b, u64(item.handle), field.text(&b.input), st.font, st.color, inner, tr.y, &b.input)
		} else {
			draw_field(b, u64(item.handle), item.text, st.font, st.color, inner, tr.y)
		}
		content := content_clip(b)
		sdl.SetRenderClipRect(b.renderer, &content)
		return
	case .Text_Area:
		// Wrapped lines, scrolled inside the box while focused.
		draw_area(b, item, r, &b.input if focused && sync_input(b) else nil)
		content := content_clip(b)
		sdl.SetRenderClipRect(b.renderer, &content)
		return
	}

	if st.bullet {
		_, line_h := measure_text(&b.fonts, "", st.font, 0)
		size: f32 = 5
		top := first_text_top(b, item) + dy
		fill_rect(b, {r.x - 13, top + line_h / 2 - size / 2, size, size}, st.color)
	}
	if item.frag_count > 0 {
		// Inline text: backgrounds (code) first, then highlights, then the text.
		frags := b.lay.fragments[item.frag_first:][:item.frag_count]
		for f in frags {
			if f.background.a > 0 {
				fill_rect(b, {f.rect.x - 2, f.rect.y + dy, f.rect.w + 4, f.rect.h}, f.background)
			}
		}
		draw_highlights(b, index, dy)
		for f, k in frags {
			draw_text(b, KEY_FRAG_BASE + u64(item.frag_first + k), item.text[f.start:f.end], f.font, 0, f.color, f.rect.x, f.rect.y + dy)
		}
	} else if len(item.text) > 0 {
		draw_highlights(b, index, dy)
		draw_text(b, u64(item.handle), item.text, st.font, item.wrap, st.color, tr.x, tr.y)
	}
}

// The top of the first line of text in `item` or its descendants, so a list
// bullet lines up with it even when the text sits in a centred row.
first_text_top :: proc(b: ^Browser, item: ^layout.Item) -> f32 {
	if len(item.text) > 0 {
		return item.text_rect.y
	}
	start := int(uintptr(item) - uintptr(raw_data(b.lay.items))) / size_of(layout.Item)
	for i in start + 1 ..< len(b.lay.items) {
		// Items are in pre-order: descendants follow until one is outside the subtree.
		inside := false
		for p := b.lay.items[i].parent; p >= 0; p = b.lay.items[p].parent {
			if p == start {
				inside = true
				break
			}
		}
		if !inside {
			break
		}
		if len(b.lay.items[i].text) > 0 {
			return b.lay.items[i].text_rect.y
		}
	}
	return item.rect.y
}

draw_canvas :: proc(b: ^Browser, item: ^layout.Item, dst: layout.Rect) {
	n := host.node_get(&b.page, item.handle)
	if n == nil {
		return
	}
	canvas := host.canvas_sync(&b.page, n)
	c, ok := &b.canvases[item.handle]
	if ok && (c.w != canvas.width || c.h != canvas.height) {
		sdl.DestroyTexture(c.tex)
		delete_key(&b.canvases, item.handle)
		ok = false
	}
	if !ok {
		tex := sdl.CreateTexture(b.renderer, .RGBA32, .STREAMING, i32(canvas.width), i32(canvas.height))
		if tex == nil {
			return
		}
		sdl.SetTextureScaleMode(tex, .NEAREST)
		b.canvases[item.handle] = {tex = tex, w = canvas.width, h = canvas.height, version = max(u64)}
		c = &b.canvases[item.handle]
	}
	if c.version != b.page.paint_version {
		sdl.UpdateTexture(c.tex, nil, raw_data(canvas.pixels), i32(canvas.width * 4))
		c.version = b.page.paint_version
	}
	pr := phys(b, dst)
	sdl.RenderTexture(b.renderer, c.tex, nil, &pr)
}

draw_banner :: proc(b: ^Browser, vw: f32) {
	font := layout.Font{size = 14}
	pad: f32 = 10
	_, th := measure_text(&b.fonts, b.error, font, vw - 4 * pad)
	box := layout.Rect{pad, CHROME_HEIGHT + pad, vw - 2 * pad, th + 2 * pad}
	fill_rect(b, box, {0xFD, 0xE8, 0xE8, 0xFF})
	stroke_rect(b, box, {0xE0, 0x9A, 0x9A, 0xFF})
	draw_text(b, KEY_BANNER, b.error, font, vw - 4 * pad, {0x8A, 0x1C, 0x1C, 0xFF}, 2 * pad, CHROME_HEIGHT + 2 * pad)
}

// The content area in physical pixels, for clipping.
content_clip :: proc(b: ^Browser) -> sdl.Rect {
	vw, vh := viewport_size(b)
	return {0, i32(CHROME_HEIGHT * b.scale), i32(vw * b.scale), i32(vh * b.scale)}
}

// `vh` is the y coordinate of the bar's top edge.
draw_status_bar :: proc(b: ^Browser, vw, vh: f32) {
	bar := layout.Rect{0, vh, vw, STATUS_BAR_HEIGHT}
	fill_rect(b, bar, {0xF2, 0xF3, 0xF5, 0xFF})
	fill_rect(b, {0, vh, vw, 1}, {0xD5, 0xD8, 0xDD, 0xFF})
	muted := layout.Color{0x55, 0x5B, 0x65, 0xFF}

	left := b.page_path
	if b.message != "" {
		left = b.message
	}
	right := ""
	if b.hover_href != "" {
		right = b.hover_href
	} else if b.job != nil {
		right = "loading"
	} else if b.loaded && b.page.state == .Waiting && b.publisher != "" {
		right = fmt.tprintf("signed by %s", b.publisher)
	} else if b.loaded {
		#partial switch b.page.state {
		case .Running: right = "running"
		case .Waiting: right = "idle"
		case .Exited:  right = "exited"
		case:          right = "stopped"
		}
	}
	_, th := measure_text(&b.fonts, "", STATUS_FONT, 0)
	y := vh + (STATUS_BAR_HEIGHT - th) / 2
	rw, _ := measure_text(&b.fonts, right, STATUS_FONT, 0)
	draw_text(b, KEY_STATUS_RIGHT, right, STATUS_FONT, 0, muted, vw - rw - 8, y)
	clip := sdl.Rect{0, i32(vh * b.scale), i32(max(vw - rw - 24, 0) * b.scale), i32(STATUS_BAR_HEIGHT * b.scale)}
	sdl.SetRenderClipRect(b.renderer, &clip)
	draw_text(b, KEY_STATUS_LEFT, left, STATUS_FONT, 0, muted, 8, y)
	sdl.SetRenderClipRect(b.renderer, nil)
}
