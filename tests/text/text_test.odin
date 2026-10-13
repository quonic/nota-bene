package text_test

import "core:testing"

import "../../src/text"

breaks_of :: proc(s: string) -> [dynamic]int {
	a := text.analyze(s, .Auto, context.temp_allocator)
	out := make([dynamic]int, context.temp_allocator)
	for i in 1 ..= len(s) {
		if text.can_break(&a, i) {
			append(&out, i)
		}
	}
	return out
}

expect_ints :: proc(t: ^testing.T, got: []int, want: []int, what: string, loc := #caller_location) {
	ok := len(got) == len(want)
	for i in 0 ..< min(len(got), len(want)) {
		ok = ok && got[i] == want[i]
	}
	testing.expectf(t, ok, "%s: got %v, want %v", what, got, want, loc = loc)
}

@(test)
test_line_breaks :: proc(t: ^testing.T) {
	// After spaces, not inside words; the end of the text is always a break.
	expect_ints(t, breaks_of("the big dog")[:], {4, 8, 11}, "spaces")
	// After a hyphen and a zero width space; never at a no-break space.
	expect_ints(t, breaks_of("well-known​x y")[:], {5, 13, 17}, "hyphen, ZWSP, NBSP")
	// Between ideographs, but not before the full stop (kinsoku).
	expect_ints(t, breaks_of("日本語。テキスト")[:], {3, 6, 12, 15, 18, 21, 24}, "CJK")
	a := text.analyze("a\nb", .Auto, context.temp_allocator)
	testing.expect(t, text.must_break(&a, 2), "a newline forces a break after it")
}

@(test)
test_graphemes :: proc(t: ^testing.T) {
	family :: "👩‍💻" // woman technologist: one cluster joined with ZWJ
	s :: "a" + family + "b"
	testing.expect_value(t, text.next_grapheme(s, 1), 1 + len(family))
	testing.expect_value(t, text.prev_grapheme(s, 1 + len(family)), 1)
	flags := "🇫🇷🇩🇪" // two flags, four regional indicators
	testing.expect_value(t, text.next_grapheme(flags, 0), 8)
	testing.expect_value(t, text.prev_grapheme(flags, len(flags)), 8)
	accent := "éx"
	testing.expect_value(t, text.next_grapheme(accent, 0), 3)
	testing.expect_value(t, text.prev_grapheme(accent, 3), 0)
	testing.expect_value(t, text.next_grapheme(accent, len(accent)), len(accent))
	testing.expect_value(t, text.prev_grapheme(accent, 0), 0)
}

@(test)
test_runs :: proc(t: ^testing.T) {
	s := "abc אבג def" // Hebrew is bytes 4..<10
	ltr := text.analyze(s, .Auto, context.temp_allocator)
	testing.expect(t, !ltr.rtl, "a Latin first letter makes an LTR paragraph")
	testing.expect_value(t, len(ltr.runs), 3)
	testing.expect_value(t, ltr.runs[0], text.Run{0, 4, 0})
	testing.expect_value(t, ltr.runs[1], text.Run{4, 10, 1})
	testing.expect_value(t, ltr.runs[2], text.Run{10, len(s), 0}) // the space between R and L takes the paragraph's direction

	rtl := text.analyze(s, .Rtl, context.temp_allocator)
	testing.expect(t, rtl.rtl)
	testing.expect_value(t, rtl.runs[0], text.Run{0, 3, 2})
	testing.expect_value(t, rtl.runs[1], text.Run{3, 11, 1})
	testing.expect_value(t, rtl.runs[2], text.Run{11, len(s), 2})

	// Digits are not letters: the Hebrew decides the direction.
	h := text.analyze("12 שלום", .Auto, context.temp_allocator)
	testing.expect(t, h.rtl, "the first letter is Hebrew")
	none := text.analyze("123 !", .Auto, context.temp_allocator)
	testing.expect(t, !none.rtl, "no letters: left to right")
	testing.expect_value(t, len(none.runs), 1)
	testing.expect_value(t, none.runs[0].level, 0)
	empty := text.analyze("", .Rtl, context.temp_allocator)
	testing.expect(t, empty.rtl)
}

@(test)
test_visual_order :: proc(t: ^testing.T) {
	order: [5]int
	text.visual_order({0, 0, 0}, order[:3])
	expect_ints(t, order[:3], {0, 1, 2}, "all LTR")
	text.visual_order({0, 1, 1, 0}, order[:4])
	expect_ints(t, order[:4], {0, 2, 1, 3}, "RTL inside LTR")
	text.visual_order({1, 1, 1}, order[:3])
	expect_ints(t, order[:3], {2, 1, 0}, "all RTL")
	// LTR words inside an RTL paragraph keep their own order.
	text.visual_order({1, 2, 2, 1, 2}, order[:5])
	expect_ints(t, order[:5], {4, 3, 1, 2, 0}, "LTR inside RTL")

	dir, ok := text.parse_dir("rtl")
	testing.expect(t, ok && dir == .Rtl)
	_, ok = text.parse_dir("sideways")
	testing.expect(t, !ok)
}

// Neutrals at the end of a paragraph take the paragraph's direction.
@(test)
test_end_of_paragraph :: proc(t: ^testing.T) {
	s := "then קישור." // the Hebrew is bytes 5..<15
	a := text.analyze(s, .Ltr, context.temp_allocator)
	testing.expect_value(t, len(a.runs), 3)
	testing.expect_value(t, a.runs[1], text.Run{5, 15, 1})
	testing.expect_value(t, a.runs[2], text.Run{15, 16, 0})
	r := text.analyze("שלום abc.", .Rtl, context.temp_allocator)
	testing.expect_value(t, r.runs[len(r.runs) - 1], text.Run{12, 13, 1})
}
