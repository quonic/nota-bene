package main

import "core:strings"

import "../../field"
import "../../layout"
import "../../text"

// The text of a field (a page Input or Text_Area, the address bar, the find
// bar) is laid out by layout.para_layout like page text, so it breaks lines
// and orders mixed directions the same way. Each segment is drawn as its
// own TTF_Text; caret positions and hit testing work per segment.

// Segment texts are cached under KEY_SEG_BASE + (field slot << 20) + index.
KEY_SEG_BASE :: u64(1) << 56

Field_Layout :: struct {
	para:  layout.Para,
	str:   string,
	font:  layout.Font,
	wrap:  f32,
	dir:   text.Dir,
	align: f32, // right-to-left lines end at this x
}

// The cache key of segment `k` of the field cached under `key`.
seg_key :: proc(key: u64, k: int) -> u64 {
	slot := key if key < 1 << 32 else 1 << 32 + (key & 0xFFFF)
	return KEY_SEG_BASE + slot << 20 + u64(k)
}

// The field slot a segment key belongs to, for pruning; false for other keys.
seg_slot :: proc(key: u64) -> (u64, bool) {
	if key < KEY_SEG_BASE {
		return 0, false
	}
	return (key - KEY_SEG_BASE) >> 20, true
}

field_layout_destroy :: proc(fl: ^Field_Layout) {
	layout.para_destroy(&fl.para)
	delete(fl.str)
	fl^ = {}
}

clear_field_layouts :: proc(t: ^Tab) {
	for _, &fl in t.field_lays {
		field_layout_destroy(&fl)
	}
	clear(&t.field_lays)
}

// `s` laid out in `font`, wrapped at `wrap` (0 = one line per newline),
// with right-to-left lines ending at `align`. Cached under `key` until any
// of them changes.
field_layout :: proc(b: ^Browser, key: u64, s: string, font: layout.Font, wrap: f32, dir: text.Dir, align: f32) -> ^Field_Layout {
	fl, ok := &b.field_lays[key]
	if ok && fl.str == s && fl.font == font && fl.wrap == wrap && fl.dir == dir && fl.align == align {
		return fl
	}
	if !ok {
		b.field_lays[key] = {}
		fl = &b.field_lays[key]
	}
	delete(fl.str)
	fl.str = strings.clone(s)
	fl.font, fl.wrap, fl.dir, fl.align = font, wrap, dir, align
	_, line_h := measure_text(&b.fonts, "", font, 0)
	runs := []layout.Para_Run{{start = 0, end = len(s), font = font}}
	m := layout.Measurer{data = &b.fonts, measure = measure_text}
	layout.para_layout(m, s, runs, {wrap = wrap, dir = dir, line_h = line_h, editing = true}, &fl.para)
	layout.para_align(&fl.para, max(align, fl.para.width))
	return fl
}

// How far right the text reaches, whitespace at line ends included.
field_extent :: proc(fl: ^Field_Layout) -> f32 {
	w := fl.para.width
	for sg in fl.para.segs {
		w = max(w, sg.rect.x + sg.rect.w)
	}
	return w
}

// The cached text object for segment `k`.
seg_text :: proc(b: ^Browser, key: u64, fl: ^Field_Layout, k: int) -> ^Cached_Text {
	sg := fl.para.segs[k]
	font := fl.font
	font.rtl = sg.rtl
	return cached_text(b, seg_key(key, k), fl.str[sg.start:sg.end], font, 0)
}

// Draws the field's text with its top left at (x, y).
draw_field_text :: proc(b: ^Browser, key: u64, fl: ^Field_Layout, color: layout.Color, x, y: f32) {
	for sg, k in fl.para.segs {
		font := fl.font
		font.rtl = sg.rtl
		draw_text(b, seg_key(key, k), fl.str[sg.start:sg.end], font, 0, color, x + sg.rect.x, y + sg.rect.y)
	}
}

// Rectangles covering bytes [start, end), relative to the text's top left.
field_range_rects :: proc(b: ^Browser, key: u64, fl: ^Field_Layout, start, end: int) -> []layout.Rect {
	out := make([dynamic]layout.Rect, context.temp_allocator)
	for sg, k in fl.para.segs {
		s, e := max(start, sg.start), min(end, sg.end)
		if s >= e {
			continue
		}
		c := seg_text(b, key, fl, k)
		if c == nil {
			continue
		}
		for r in text_range_rects(b, c, s - sg.start, e - sg.start, {sg.rect.x, sg.rect.y}) {
			line := fl.para.lines[sg.line]
			append(&out, layout.Rect{r.x, line.y, r.w, line.h})
		}
	}
	return out[:]
}

// The line holding the caret at `offset`: the last one starting at or
// before it, so a caret after a newline or a wrap is on the next line.
field_line_of :: proc(fl: ^Field_Layout, offset: int) -> int {
	line := 0
	for l, i in fl.para.lines {
		if l.start <= offset {
			line = i
		}
	}
	return line
}

// A zero-width rectangle at `offset`, one line tall, relative to the
// text's top left.
field_text_caret :: proc(b: ^Browser, key: u64, fl: ^Field_Layout, offset: int) -> layout.Rect {
	if len(fl.para.lines) == 0 {
		return {}
	}
	li := field_line_of(fl, offset)
	line := fl.para.lines[li]
	segs := fl.para.segs[line.seg_first:][:line.seg_count]
	edge :: proc(b: ^Browser, key: u64, fl: ^Field_Layout, k, start, end: int, leading: bool) -> (f32, bool) {
		sg := fl.para.segs[k]
		c := seg_text(b, key, fl, k)
		if c == nil {
			return 0, false
		}
		rs := text_range_rects(b, c, start - sg.start, end - sg.start, {sg.rect.x, sg.rect.y})
		if len(rs) == 0 {
			return 0, false
		}
		// The leading edge is the left one, or the right in right-to-left text.
		r := rs[0]
		return r.x + r.w if leading == sg.rtl else r.x, true
	}
	// The character after the caret, on this line; else the one before it.
	for sg, j in segs {
		if sg.start <= offset && offset < sg.end {
			if x, ok := edge(b, key, fl, line.seg_first + j, offset, field.next_char(fl.str, offset), true); ok {
				return {x, line.y, 0, line.h}
			}
		}
	}
	for sg, j in segs {
		if sg.start < offset && offset <= sg.end {
			if x, ok := edge(b, key, fl, line.seg_first + j, field.prev_char(fl.str, offset), offset, false); ok {
				return {x, line.y, 0, line.h}
			}
		}
	}
	// An empty line: where its text would start.
	x: f32 = max(fl.align, fl.para.width) if fl.para.rtl else 0
	return {x, line.y, 0, line.h}
}

// The byte offset nearest point (x, y), relative to the text's top left.
// Above the text is the first line, below it the last.
field_text_offset :: proc(b: ^Browser, key: u64, fl: ^Field_Layout, x, y: f32) -> int {
	lines := fl.para.lines[:]
	if len(lines) == 0 {
		return 0
	}
	li := len(lines) - 1
	for l, i in lines {
		if y < l.y + l.h {
			li = i
			break
		}
	}
	line := lines[li]
	best, best_dx := -1, max(f32)
	for sg, j in fl.para.segs[line.seg_first:][:line.seg_count] {
		dx: f32 = 0
		if x < sg.rect.x {
			dx = sg.rect.x - x
		} else if x >= sg.rect.x + sg.rect.w {
			dx = x - (sg.rect.x + sg.rect.w)
		}
		if dx < best_dx {
			best, best_dx = line.seg_first + j, dx
		}
	}
	offset := line.start
	if best >= 0 {
		sg := fl.para.segs[best]
		switch {
		case x <= sg.rect.x:
			offset = sg.end if sg.rtl else sg.start
		case x >= sg.rect.x + sg.rect.w:
			offset = sg.start if sg.rtl else sg.end
		case:
			offset = sg.start
			if c := seg_text(b, key, fl, best); c != nil {
				o, _ := text_offset_at(c, i32((x - sg.rect.x) * b.scale), 0, sg.rtl)
				offset = clamp(sg.start + o, sg.start, sg.end)
			}
		}
	}
	// The end of a line that is not the last (after its newline, or the
	// space a wrap broke at) is already the next line: stay on this one.
	if li < len(lines) - 1 && offset >= line.end && offset > line.start {
		offset = field.prev_char(fl.str, line.end)
	}
	return offset
}
