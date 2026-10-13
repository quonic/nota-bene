package layout

import "../text"

// Paragraph layout: one string, in runs of different fonts (and inline
// objects such as images), broken into lines at Unicode line break
// opportunities and reordered for bidirectional text. Page paragraphs,
// plain text blocks, Inputs and Text_Areas all go through here, so they
// break and order text the same way.
//
// Segments are kept in logical (byte) order; their rectangles are where
// they sit on screen. A segment is a contiguous byte range of one run, on
// one line, in one direction, so it can be drawn as one shaped string.

Para_Run :: struct {
	start, end: int,    // bytes of the paragraph string
	font:       Font,
	object:     [2]f32, // an inline object's size; its text is U+FFFC
	is_object:  bool,
}

Seg :: struct {
	run:        int,
	start, end: int,  // bytes of the paragraph string
	rect:       Rect, // relative to the paragraph's top left
	rtl:        bool,
	line:       int,
}

Line :: struct {
	start, end: int, // bytes, including a newline that ends the line
	y, h:       f32,
	w:          f32, // without the whitespace hanging at its end
	seg_first:  int,
	seg_count:  int,
}

Para :: struct {
	segs:   [dynamic]Seg,
	lines:  [dynamic]Line,
	width:  f32, // the widest line
	height: f32,
	rtl:    bool,
}

Para_Options :: struct {
	wrap:    f32,      // wrap width; 0 = break only at newlines
	dir:     text.Dir,
	line_h:  f32,      // height of a line with nothing on it
	// Editing: an empty string, and the end of a string ending in a
	// newline, still get a line, for the caret to sit on.
	editing: bool,
}

OBJECT_TEXT :: "￼"

para_destroy :: proc(p: ^Para) {
	delete(p.segs)
	delete(p.lines)
	p^ = {}
}

@(private)
Piece :: struct {
	run:        int,
	start, end: int,
	level:      u8,
	w, h:       f32,
	space:      bool, // whitespace (or a newline): hangs at the end of a line
	newline:    bool,
	break_after: bool, // a line may end after this piece
	hard_after:  bool, // a line must end after this piece
	cluster:    bool, // a single grapheme cluster: cannot be split further
}

// Lays out `s` in `runs` (which cover it in order). Positions are relative
// to the paragraph's top left, with every line starting at x = 0; call
// para_align to place right-to-left lines.
para_layout :: proc(m: Measurer, s: string, runs: []Para_Run, opt: Para_Options, out: ^Para) {
	clear(&out.segs)
	clear(&out.lines)
	out.width, out.height = 0, 0
	a := text.analyze(s, opt.dir, context.temp_allocator)
	out.rtl = a.rtl
	para_level := u8(1) if a.rtl else 0

	pieces := make([dynamic]Piece, context.temp_allocator)
	for run, ri in runs {
		if run.is_object {
			append(&pieces, Piece {
				run = ri, start = run.start, end = run.end,
				level = text.level_at(&a, run.start),
				w = run.object.x, h = run.object.y,
				break_after = text.can_break(&a, run.end),
				hard_after = text.must_break(&a, run.end),
				cluster = true,
			})
			continue
		}
		cut_pieces(m, s, &a, ri, run, &pieces)
	}

	line_first := 0 // first piece of the current line
	x: f32          // width of the pieces on the line so far
	i := 0
	for i < len(pieces) {
		// A unit is the pieces up to the next break opportunity.
		j := i + 1
		for j < len(pieces) && !pieces[j - 1].break_after {
			j += 1
		}
		content := unit_content_width(pieces[i:j])
		if opt.wrap > 0 && content > opt.wrap && !(j == i + 1 && pieces[i].cluster) {
			if i > line_first && x + content > opt.wrap {
				finish_line(out, s, pieces[line_first:i], para_level, opt)
				line_first, x = i, 0
			}
			// Wider than a whole line: allow breaks between its characters.
			split_unit(m, s, &a, runs, &pieces, i, j)
			continue
		}
		if opt.wrap > 0 && i > line_first && x + content > opt.wrap {
			finish_line(out, s, pieces[line_first:i], para_level, opt)
			line_first, x = i, 0
		}
		for p in pieces[i:j] {
			x += p.w
		}
		i = j
		if pieces[j - 1].hard_after {
			finish_line(out, s, pieces[line_first:j], para_level, opt)
			line_first, x = j, 0
		}
	}
	if line_first < len(pieces) {
		finish_line(out, s, pieces[line_first:], para_level, opt)
	} else if opt.editing && (len(s) == 0 || len(out.lines) > 0) {
		// The empty last line after a newline, or the only line of empty text.
		y := out.height
		append(&out.lines, Line{start = len(s), end = len(s), y = y, h = opt.line_h, seg_first = len(out.segs)})
		out.height += opt.line_h
	}
}

// Places right-to-left lines against the right edge of a box `width` wide.
para_align :: proc(p: ^Para, width: f32) {
	if !p.rtl {
		return
	}
	for line in p.lines {
		dx := width - line.w
		for &sg in p.segs[line.seg_first:][:line.seg_count] {
			sg.rect.x += dx
		}
	}
}

// Splits run `ri` into pieces: at its direction changes, line break
// opportunities, and where trailing whitespace starts.
@(private)
cut_pieces :: proc(m: Measurer, s: string, a: ^text.Analysis, ri: int, run: Para_Run, out: ^[dynamic]Piece) {
	start := run.start
	for start < run.end {
		level := text.level_at(a, start)
		end := start + 1
		for end < run.end && !text.can_break(a, end) && text.level_at(a, end) == level {
			end += 1
		}
		// Whitespace before the break hangs: give it its own piece.
		ws := end
		for ws > start && is_space(s[ws - 1]) {
			ws -= 1
		}
		if ws > start {
			append(out, measure_piece(m, s, a, ri, run, start, ws, level, false))
		}
		if ws < end {
			append(out, measure_piece(m, s, a, ri, run, ws, end, level, true))
		}
		start = end
	}
}

@(private)
measure_piece :: proc(m: Measurer, s: string, a: ^text.Analysis, ri: int, run: Para_Run, start, end: int, level: u8, space: bool) -> Piece {
	font := run.font
	font.rtl = level % 2 == 1
	str := s[start:end]
	newline := str[len(str) - 1] == '\n'
	w, h: f32
	if newline {
		_, h = m.measure(m.data, "", font, 0)
		str = str[:len(str) - 1]
		if len(str) > 0 && str[len(str) - 1] == '\r' {
			str = str[:len(str) - 1]
		}
	}
	if len(str) > 0 {
		w, h = m.measure(m.data, str, font, 0)
	}
	return {
		run = ri, start = start, end = end, level = level, w = w, h = h,
		space = space, newline = newline,
		break_after = text.can_break(a, end),
		hard_after = text.must_break(a, end),
		cluster = text.is_grapheme(a, start) && next_cluster(a, start) >= end,
	}
}

@(private)
is_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

@(private)
next_cluster :: proc(a: ^text.Analysis, i: int) -> int {
	j := i + 1
	for j < len(a.flags) - 1 && !text.is_grapheme(a, j) {
		j += 1
	}
	return j
}

// Width of a unit without the whitespace at its end.
@(private)
unit_content_width :: proc(unit: []Piece) -> f32 {
	end := len(unit)
	for end > 0 && unit[end - 1].space {
		end -= 1
	}
	w: f32
	for p in unit[:end] {
		w += p.w
	}
	return w
}

// Replaces pieces [i, j) with one piece per grapheme cluster, each a break
// opportunity, so a word wider than the line can be broken anywhere.
@(private)
split_unit :: proc(m: Measurer, s: string, a: ^text.Analysis, runs: []Para_Run, pieces: ^[dynamic]Piece, i, j: int) {
	unit := make([]Piece, j - i, context.temp_allocator)
	copy(unit, pieces[i:j])
	remove_range(pieces, i, j)
	at := i
	for p, k in unit {
		if p.space || p.cluster {
			q := p
			q.break_after = true if k < len(unit) - 1 else p.break_after
			inject_at(pieces, at, q)
			at += 1
			continue
		}
		for c := p.start; c < p.end; {
			e := min(next_cluster(a, c), p.end)
			q := measure_piece(m, s, a, p.run, runs[p.run], c, e, p.level, false)
			q.cluster = true
			if e < p.end || k < len(unit) - 1 {
				q.break_after, q.hard_after = true, false
			} else {
				q.break_after, q.hard_after = p.break_after, p.hard_after
			}
			inject_at(pieces, at, q)
			at += 1
			c = e
		}
	}
}

// Ends a line made of `pieces`: rule
// L1 (whitespace at the end of the line takes the paragraph's level), rule
// L2 (reordering), and segments for runs of pieces that draw as one string.
@(private)
finish_line :: proc(out: ^Para, s: string, pieces: []Piece, para_level: u8, opt: Para_Options) {
	levels := make([]u8, len(pieces), context.temp_allocator)
	trailing := len(pieces)
	for trailing > 0 && pieces[trailing - 1].space {
		trailing -= 1
	}
	line_h: f32
	content_w: f32
	for p, k in pieces {
		levels[k] = para_level if k >= trailing else p.level
		line_h = max(line_h, p.h)
		if k < trailing {
			content_w += p.w
		}
	}
	if line_h == 0 {
		line_h = opt.line_h
	}

	order := make([]int, len(pieces), context.temp_allocator)
	text.visual_order(levels, order)
	xs := make([]f32, len(pieces), context.temp_allocator)
	x: f32
	if para_level == 1 {
		// Hanging whitespace sits at the visual start of a right-to-left
		// line: start left of zero so the content ends at the line width.
		for k in trailing ..< len(pieces) {
			x -= pieces[k].w
		}
	}
	for k in order {
		xs[k] = x
		x += pieces[k].w
	}

	y := out.height
	line := Line {
		start     = pieces[0].start if len(pieces) > 0 else len(s),
		end       = pieces[len(pieces) - 1].end if len(pieces) > 0 else len(s),
		y         = y,
		h         = line_h,
		w         = content_w,
		seg_first = len(out.segs),
	}
	line_index := len(out.lines)
	last_all_space := false // the last segment is only whitespace
	for p, k in pieces {
		if p.newline && p.start + 1 >= p.end {
			continue // a bare newline draws nothing
		}
		if k >= trailing && !opt.editing {
			continue // whitespace hanging past the end of the line is not drawn
		}
		end := p.end
		if p.newline {
			end -= 1
			if end > p.start && s[end - 1] == '\r' {
				end -= 1
			}
		}
		rtl := levels[k] % 2 == 1
		rect := Rect{xs[k], y + line_h - p.h, p.w, p.h}
		if n := len(out.segs); n > line.seg_first {
			last := &out.segs[n - 1]
			merge := last.run == p.run && last.end == p.start && last.rtl == rtl
			if merge && rtl {
				// SDL_ttf does not place whitespace at the ends of a
				// right-to-left string where we do, which shifts its
				// glyphs. Keep such whitespace in segments of its own.
				if p.space {
					merge = k + 1 < len(pieces) && (k + 1 < trailing || opt.editing) &&
						!pieces[k + 1].space && pieces[k + 1].run == p.run &&
						pieces[k + 1].start == p.end && levels[k + 1] == levels[k]
				} else if last_all_space {
					merge = false
				}
			}
			if merge {
				x0 := min(last.rect.x, rect.x)
				x1 := max(last.rect.x + last.rect.w, rect.x + rect.w)
				last.end = end
				last.rect.x, last.rect.w = x0, x1 - x0
				last.rect.h = max(last.rect.h, p.h)
				last.rect.y = y + line_h - last.rect.h
				last_all_space = last_all_space && p.space
				continue
			}
		}
		append(&out.segs, Seg{run = p.run, start = p.start, end = end, rect = rect, rtl = rtl, line = line_index})
		last_all_space = p.space
	}
	line.seg_count = len(out.segs) - line.seg_first
	append(&out.lines, line)
	out.height += line_h
	out.width = max(out.width, content_w)
}

