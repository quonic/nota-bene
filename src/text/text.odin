// Package text finds where text may break and which way it runs: Unicode
// line breaks (UAX #14), grapheme clusters (UAX #29) and bidirectional runs
// (UAX #9), using kb_text_shape. It needs no font, so layout and field use
// it and it is tested without graphics.
//
// kb_text_shape resolves each character to left-to-right or right-to-left
// only, not to full embedding levels, and ignores the explicit direction
// controls (LRE, RLE, LRO, RLO, PDF and the isolates). Runs therefore get
// one of three levels: 0 (LTR in an LTR paragraph), 1 (RTL) and 2 (LTR in
// an RTL paragraph). Reordering a line by those levels (rule L2) is
// visual_order's job; the caller applies it per line.
package text

import "core:c"
import "core:slice"
import "core:unicode"

import kbts "vendor:kb_text_shape"

// A paragraph's base direction. Auto takes it from the first letter (rule
// P2), falling back to left-to-right.
Dir :: enum u8 {
	Auto,
	Ltr,
	Rtl,
}

// Bytes [start, end) of the text, all at one embedding level. Odd levels
// run right to left.
Run :: struct {
	start, end: int,
	level:      u8,
}

Analysis :: struct {
	flags: []kbts.break_flags, // len(s)+1 entries, by byte offset: what boundary is before that byte
	runs:  []Run,              // in logical order, covering the whole text
	rtl:   bool,               // the resolved paragraph direction
}

parse_dir :: proc(s: string) -> (Dir, bool) {
	switch s {
	case "auto": return .Auto, true
	case "ltr":  return .Ltr, true
	case "rtl":  return .Rtl, true
	}
	return .Auto, false
}

// Breaks and direction runs of `s` in a paragraph running `dir`.
analyze :: proc(s: string, dir: Dir, allocator := context.allocator) -> Analysis {
	a: Analysis
	a.flags = make([]kbts.break_flags, len(s) + 1, allocator)
	if len(s) == 0 {
		a.rtl = dir == .Rtl
		a.runs = make([]Run, 0, allocator)
		return a
	}
	// Breaks and grapheme clusters do not depend on the direction.
	breaks := break_string(s, .DONT_KNOW, a.flags, context.temp_allocator)
	if dir == .Auto {
		// kb_text_shape takes the first character with a direction, digits
		// included; rule P2 wants the first letter. Letters are strongly
		// typed, so the run holding it says which way the paragraph runs.
		a.rtl = first_letter_rtl(s, breaks)
	} else {
		a.rtl = dir == .Rtl
	}
	// kb_text_shape streams, so it does not know where the text ends, and
	// neutrals at the end keep the direction before them. A mark in the
	// paragraph's direction (LRM or RLM, plain strong characters) stands in
	// for the end of the paragraph, so "שלום." in a left-to-right paragraph
	// ends with a left-to-right full stop, as rule N1 says.
	marked := make([]u8, len(s) + 3, context.temp_allocator)
	copy(marked, s)
	copy(marked[len(s):], "\u200f" if a.rtl else "\u200e")
	scratch := make([]kbts.break_flags, len(marked) + 1, context.temp_allocator)
	breaks = break_string(string(marked), kbts_dir(a.rtl), scratch, context.temp_allocator)

	runs := make([dynamic]Run, allocator)
	cur_rtl := a.rtl
	start := 0
	for b in breaks {
		if .DIRECTION not_in b.Flags || b.Direction == .DONT_KNOW {
			continue
		}
		pos := int(b.Position)
		if pos >= len(s) {
			break // the end mark
		}
		rtl := b.Direction == .KBTS_DIRECTION_RTL
		if pos > start && rtl != cur_rtl {
			append(&runs, Run{start, pos, level_of(cur_rtl, a.rtl)})
			start = pos
		}
		cur_rtl = rtl
	}
	append(&runs, Run{start, len(s), level_of(cur_rtl, a.rtl)})
	a.runs = runs[:]
	return a
}

analysis_destroy :: proc(a: ^Analysis, allocator := context.allocator) {
	delete(a.flags, allocator)
	delete(a.runs, allocator)
	a^ = {}
}

// A line may end before byte `i`.
can_break :: proc(a: ^Analysis, i: int) -> bool {
	return .LINE_SOFT in a.flags[i]
}

// A line must end before byte `i` (after a newline).
must_break :: proc(a: ^Analysis, i: int) -> bool {
	return .LINE_HARD in a.flags[i]
}

// A grapheme cluster (a user-perceived character) starts at byte `i`.
is_grapheme :: proc(a: ^Analysis, i: int) -> bool {
	return i <= 0 || i >= len(a.flags) - 1 || .GRAPHEME in a.flags[i]
}

// The embedding level of the byte at `i`.
level_at :: proc(a: ^Analysis, i: int) -> u8 {
	for r in a.runs {
		if i < r.end {
			return r.level
		}
	}
	return 1 if a.rtl else 0
}

// The start of the grapheme cluster before `pos`.
prev_grapheme :: proc(s: string, pos: int) -> int {
	if pos <= 0 {
		return 0
	}
	flags := grapheme_flags(s)
	for i := min(pos, len(s)) - 1; i > 0; i -= 1 {
		if .GRAPHEME in flags[i] {
			return i
		}
	}
	return 0
}

// The end of the grapheme cluster at `pos`.
next_grapheme :: proc(s: string, pos: int) -> int {
	if pos >= len(s) {
		return len(s)
	}
	flags := grapheme_flags(s)
	for i := pos + 1; i < len(s); i += 1 {
		if .GRAPHEME in flags[i] {
			return i
		}
	}
	return len(s)
}

// Rule L2: given the levels of a line's pieces in logical order, writes
// into `order` the logical index of each piece from left to right. From the
// highest level down to the lowest odd one, every stretch of pieces at that
// level or above is reversed.
visual_order :: proc(levels: []u8, order: []int) {
	assert(len(order) == len(levels))
	for i in 0 ..< len(order) {
		order[i] = i
	}
	if len(levels) == 0 {
		return
	}
	hi, lo_odd := u8(0), u8(255)
	for l in levels {
		hi = max(hi, l)
		if l % 2 == 1 {
			lo_odd = min(lo_odd, l)
		}
	}
	if lo_odd == 255 {
		return // all left to right
	}
	for lvl := hi; lvl >= lo_odd; lvl -= 1 {
		i := 0
		for i < len(order) {
			if levels[order[i]] < lvl {
				i += 1
				continue
			}
			j := i
			for j < len(order) && levels[order[j]] >= lvl {
				j += 1
			}
			slice.reverse(order[i:j])
			i = j
		}
	}
}

@(private)
level_of :: proc(rtl, para_rtl: bool) -> u8 {
	if rtl {
		return 1
	}
	return 2 if para_rtl else 0
}

@(private)
kbts_dir :: proc(rtl: bool) -> kbts.direction {
	return .KBTS_DIRECTION_RTL if rtl else .KBTS_DIRECTION_LTR
}

// Runs kb_text_shape over `s`, filling `flags` (len(s)+1) and returning the
// break records sorted by position (it does not promise that order).
@(private)
break_string :: proc(s: string, d: kbts.direction, flags: []kbts.break_flags, allocator := context.temp_allocator) -> []kbts.break_type {
	count, flag_count: c.int
	kbts.BreakEntireStringUtf8(d, .NORMAL, {}, s, nil, &count, nil, &flag_count)
	breaks := make([]kbts.break_type, count, allocator)
	slice.zero(flags)
	kbts.BreakEntireStringUtf8(d, .NORMAL, {}, s, breaks, &count, flags, &flag_count)
	breaks = breaks[:count]
	slice.stable_sort_by(breaks, proc(a, b: kbts.break_type) -> bool {
		return a.Position < b.Position
	})
	return breaks
}

@(private)
first_letter_rtl :: proc(s: string, breaks: []kbts.break_type) -> bool {
	for r, i in s {
		if !unicode.is_letter(r) {
			continue
		}
		rtl := false
		for b in breaks {
			if int(b.Position) > i {
				break
			}
			if .DIRECTION in b.Flags && b.Direction != .DONT_KNOW {
				rtl = b.Direction == .KBTS_DIRECTION_RTL
			}
		}
		return rtl
	}
	return false
}

@(private)
grapheme_flags :: proc(s: string) -> []kbts.break_flags {
	flags := make([]kbts.break_flags, len(s) + 1, context.temp_allocator)
	break_string(s, .DONT_KNOW, flags)
	return flags
}
