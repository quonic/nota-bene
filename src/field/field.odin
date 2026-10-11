// Package field edits one line of text: a caret, a selection and undo. It
// knows nothing about fonts or windows, so the address bar, the find bar and
// page Inputs share it, and it is tested without graphics.
package field

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

MAX_UNDO :: 100

Move :: enum {
	Left,
	Right,
	Word_Left,
	Word_Right,
	Start,
	End,
}

Snapshot :: struct {
	text:          string,
	caret, anchor: int,
}

Op :: enum {
	None,
	Type, // plain typing: consecutive keystrokes undo as one step
}

// Positions are byte offsets, always on a rune boundary. The selection runs
// between `anchor` (where it started) and `caret` (the end that moves).
Field :: struct {
	buf:           strings.Builder,
	caret, anchor: int,
	max_len:       int, // in bytes; 0 = unlimited
	undo, redo:    [dynamic]Snapshot,
	last:          Op,
}

destroy :: proc(f: ^Field) {
	strings.builder_destroy(&f.buf)
	clear_snapshots(&f.undo)
	clear_snapshots(&f.redo)
	delete(f.undo)
	delete(f.redo)
	f^ = {}
}

text :: proc(f: ^Field) -> string {
	return strings.to_string(f.buf)
}

// The selection in text order.
selection :: proc(f: ^Field) -> (lo, hi: int) {
	return min(f.caret, f.anchor), max(f.caret, f.anchor)
}

has_selection :: proc(f: ^Field) -> bool {
	return f.caret != f.anchor
}

selected_text :: proc(f: ^Field) -> string {
	lo, hi := selection(f)
	return text(f)[lo:hi]
}

// Replaces the text from outside (focus moved here, or a page set its
// Input's text). The caret and selection are kept where they still fit, and
// the undo history is dropped.
set_text :: proc(f: ^Field, s: string) {
	strings.builder_reset(&f.buf)
	strings.write_string(&f.buf, s)
	f.caret = snap(s, f.caret)
	f.anchor = snap(s, f.anchor)
	clear_snapshots(&f.undo)
	clear_snapshots(&f.redo)
	f.last = .None
}

select_all :: proc(f: ^Field) {
	f.anchor, f.caret = 0, len(f.buf.buf)
	f.last = .None
}

// Selects the word around `offset`.
select_word_at :: proc(f: ^Field, offset: int) {
	f.anchor, f.caret = word_at(text(f), snap(text(f), offset))
	f.last = .None
}

// Puts the caret at `offset`, extending the selection or collapsing it.
set_caret :: proc(f: ^Field, offset: int, extend := false) {
	f.caret = snap(text(f), offset)
	if !extend {
		f.anchor = f.caret
	}
	f.last = .None
}

// Selects from `anchor` to `caret`, each clamped into the text and onto a
// rune boundary.
select_range :: proc(f: ^Field, anchor, caret: int) {
	f.anchor = snap(text(f), anchor)
	f.caret = snap(text(f), caret)
	f.last = .None
}

// Moves the caret. Without `extend`, Left and Right first collapse a
// selection to its near side.
move :: proc(f: ^Field, m: Move, extend := false) {
	if !extend && has_selection(f) && (m == .Left || m == .Right) {
		lo, hi := selection(f)
		f.caret = lo if m == .Left else hi
	} else {
		f.caret = target(text(f), f.caret, m)
	}
	if !extend {
		f.anchor = f.caret
	}
	f.last = .None
}

// Types or pastes `s` over the selection. With `max_len` set, `s` is cut at
// a rune boundary to fit. Returns whether the text changed.
insert :: proc(f: ^Field, s: string, typing := false) -> bool {
	s := s
	lo, hi := selection(f)
	if f.max_len > 0 {
		room := max(f.max_len - (len(f.buf.buf) - (hi - lo)), 0)
		if len(s) > room {
			n := room
			for n > 0 && is_continuation(s[n]) {
				n -= 1
			}
			s = s[:n]
		}
	}
	if s == "" && lo == hi {
		return false
	}
	if !(typing && f.last == .Type && lo == hi) {
		save(f)
	}
	remove_range(&f.buf.buf, lo, hi)
	inject_at(&f.buf.buf, lo, s)
	f.caret = lo + len(s)
	f.anchor = f.caret
	f.last = .Type if typing else .None
	return true
}

// Deletes the selection, or else from the caret to where `m` would move it
// (Backspace is .Left, Delete is .Right). Returns whether the text changed.
delete_to :: proc(f: ^Field, m: Move) -> bool {
	lo, hi := selection(f)
	if lo == hi {
		p := target(text(f), f.caret, m)
		lo, hi = min(p, f.caret), max(p, f.caret)
	}
	if lo == hi {
		return false
	}
	save(f)
	remove_range(&f.buf.buf, lo, hi)
	f.caret, f.anchor = lo, lo
	f.last = .None
	return true
}

undo :: proc(f: ^Field) -> bool {
	return swap_state(f, &f.undo, &f.redo)
}

redo :: proc(f: ^Field) -> bool {
	return swap_state(f, &f.redo, &f.undo)
}

// Letters, digits, combining marks, '_' and the apostrophe in "don't".
is_word_rune :: proc(r: rune) -> bool {
	return unicode.is_letter(r) || unicode.is_digit(r) || unicode.is_combining(r) || r == '_' || r == '\''
}

// Where moving from `pos` in `s` lands.
target :: proc(s: string, pos: int, m: Move) -> int {
	switch m {
	case .Left:       return prev_char(s, pos)
	case .Right:      return next_char(s, pos)
	case .Word_Left:  return prev_word(s, pos)
	case .Word_Right: return next_word(s, pos)
	case .Start:      return 0
	case .End:        return len(s)
	}
	return pos
}

// The start of the character before `pos`: one rune plus the combining marks
// on it, so an accent is never split from its letter.
prev_char :: proc(s: string, pos: int) -> int {
	pos := pos
	for pos > 0 {
		r, n := utf8.decode_last_rune_in_string(s[:pos])
		pos -= n
		if !unicode.is_combining(r) {
			break
		}
	}
	return pos
}

// The end of the character at `pos`, with its combining marks.
next_char :: proc(s: string, pos: int) -> int {
	if pos >= len(s) {
		return len(s)
	}
	_, n := utf8.decode_rune_in_string(s[pos:])
	pos := pos
	pos += n
	for pos < len(s) {
		r, size := utf8.decode_rune_in_string(s[pos:])
		if !unicode.is_combining(r) {
			break
		}
		pos += size
	}
	return pos
}

// The start of the word before `pos`.
prev_word :: proc(s: string, pos: int) -> int {
	pos := pos
	for pos > 0 {
		r, n := utf8.decode_last_rune_in_string(s[:pos])
		if is_word_rune(r) {
			break
		}
		pos -= n
	}
	for pos > 0 {
		r, n := utf8.decode_last_rune_in_string(s[:pos])
		if !is_word_rune(r) {
			break
		}
		pos -= n
	}
	return pos
}

// The end of the word after `pos`.
next_word :: proc(s: string, pos: int) -> int {
	pos := pos
	for pos < len(s) {
		r, n := utf8.decode_rune_in_string(s[pos:])
		if is_word_rune(r) {
			break
		}
		pos += n
	}
	for pos < len(s) {
		r, n := utf8.decode_rune_in_string(s[pos:])
		if !is_word_rune(r) {
			break
		}
		pos += n
	}
	return pos
}

// The word around `pos`, or an empty range at `pos` between two non-word runes.
word_at :: proc(s: string, pos: int) -> (start, end: int) {
	start, end = pos, pos
	for start > 0 {
		r, n := utf8.decode_last_rune_in_string(s[:start])
		if !is_word_rune(r) {
			break
		}
		start -= n
	}
	for end < len(s) {
		r, n := utf8.decode_rune_in_string(s[end:])
		if !is_word_rune(r) {
			break
		}
		end += n
	}
	return
}

@(private)
is_continuation :: proc(b: byte) -> bool {
	return b & 0xC0 == 0x80
}

// Clamps `pos` into `s` and back onto a rune boundary.
@(private)
snap :: proc(s: string, pos: int) -> int {
	pos := pos
	pos = clamp(pos, 0, len(s))
	for pos > 0 && pos < len(s) && is_continuation(s[pos]) {
		pos -= 1
	}
	return pos
}

// Records the current state before a change, and forgets what was undone.
@(private)
save :: proc(f: ^Field) {
	append(&f.undo, Snapshot{strings.clone(text(f)), f.caret, f.anchor})
	if len(f.undo) > MAX_UNDO {
		delete(f.undo[0].text)
		ordered_remove(&f.undo, 0)
	}
	clear_snapshots(&f.redo)
}

// Restores the newest state from `from`, saving the current one in `to`.
@(private)
swap_state :: proc(f: ^Field, from, to: ^[dynamic]Snapshot) -> bool {
	if len(from) == 0 {
		return false
	}
	append(to, Snapshot{strings.clone(text(f)), f.caret, f.anchor})
	s := pop(from)
	strings.builder_reset(&f.buf)
	strings.write_string(&f.buf, s.text)
	delete(s.text)
	f.caret, f.anchor = s.caret, s.anchor
	f.last = .None
	return true
}

@(private)
clear_snapshots :: proc(list: ^[dynamic]Snapshot) {
	for s in list {
		delete(s.text)
	}
	clear(list)
}
