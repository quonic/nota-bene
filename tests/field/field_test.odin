package field_test

import "core:testing"

import "../../src/field"

@(test)
test_char_moves :: proc(t: ^testing.T) {
	f: field.Field
	defer field.destroy(&f)
	// "e" + combining acute is one character; "ü" is two bytes.
	field.set_text(&f, "aéü")
	field.set_caret(&f, len(field.text(&f)))
	field.move(&f, .Left)
	testing.expect_value(t, f.caret, 4)
	field.move(&f, .Left)
	testing.expect_value(t, f.caret, 1) // over the accent and its letter
	field.move(&f, .Right)
	testing.expect_value(t, f.caret, 4)
	field.move(&f, .Start)
	field.move(&f, .Left)
	testing.expect_value(t, f.caret, 0)
}

@(test)
test_word_moves :: proc(t: ^testing.T) {
	s := "nb://example.org/some_page"
	testing.expect_value(t, field.prev_word(s, len(s)), 17)
	testing.expect_value(t, field.prev_word(s, 17), 13)
	testing.expect_value(t, field.next_word(s, 0), 2)
	testing.expect_value(t, field.next_word(s, 2), 12)
	start, end := field.word_at("don't stop", 2)
	testing.expect_value(t, start, 0)
	testing.expect_value(t, end, 5)
}

@(test)
test_selection_and_editing :: proc(t: ^testing.T) {
	f: field.Field
	defer field.destroy(&f)
	field.set_text(&f, "hello brave world")
	field.set_caret(&f, 11)
	field.move(&f, .Word_Left, extend = true)
	testing.expect_value(t, field.selected_text(&f), "brave")
	field.move(&f, .Right) // collapses to the right side
	testing.expect_value(t, f.caret, 11)
	testing.expect(t, !field.has_selection(&f))

	field.select_word_at(&f, 8)
	testing.expect(t, field.insert(&f, "new", typing = true))
	testing.expect_value(t, field.text(&f), "hello new world")
	testing.expect_value(t, f.caret, 9)

	testing.expect(t, field.delete_to(&f, .Word_Left))
	testing.expect_value(t, field.text(&f), "hello  world")
	testing.expect(t, field.delete_to(&f, .Right))
	testing.expect_value(t, field.text(&f), "hello world")
	field.move(&f, .End)
	testing.expect(t, !field.delete_to(&f, .Right))
}

@(test)
test_max_len :: proc(t: ^testing.T) {
	f: field.Field
	defer field.destroy(&f)
	f.max_len = 5
	field.set_text(&f, "abc")
	field.move(&f, .End)
	testing.expect(t, field.insert(&f, "üx")) // ü is 2 bytes: only it fits
	testing.expect_value(t, field.text(&f), "abcü")
	testing.expect(t, !field.insert(&f, "z"))
	field.select_all(&f)
	testing.expect(t, field.insert(&f, "12345678"))
	testing.expect_value(t, field.text(&f), "12345")
}

@(test)
test_undo :: proc(t: ^testing.T) {
	f: field.Field
	defer field.destroy(&f)
	for r in "hi there" {
		buf: [4]u8
		buf[0] = u8(r)
		field.insert(&f, string(buf[:1]), typing = true)
	}
	field.move(&f, .Left) // a move ends the typing run
	field.insert(&f, "X", typing = true)
	testing.expect_value(t, field.text(&f), "hi therXe")

	testing.expect(t, field.undo(&f))
	testing.expect_value(t, field.text(&f), "hi there")
	testing.expect_value(t, f.caret, 7)
	testing.expect(t, field.undo(&f))
	testing.expect_value(t, field.text(&f), "")
	testing.expect(t, !field.undo(&f))

	testing.expect(t, field.redo(&f))
	testing.expect_value(t, field.text(&f), "hi there")
	field.insert(&f, "!") // a new edit drops the redo history
	testing.expect(t, !field.redo(&f))
}

@(test)
test_set_text :: proc(t: ^testing.T) {
	f: field.Field
	defer field.destroy(&f)
	field.set_text(&f, "one two")
	f.anchor, f.caret = 4, 7
	field.insert(&f, "2")
	field.set_text(&f, "ü") // shorter: the caret clamps to the end
	testing.expect_value(t, f.caret, 2)
	testing.expect_value(t, f.anchor, 2)
	testing.expect(t, !field.undo(&f))
	field.set_caret(&f, 1) // inside ü: back to its start
	testing.expect_value(t, f.caret, 0)
}

@(test)
test_select_range :: proc(t: ^testing.T) {
	f: field.Field
	defer field.destroy(&f)
	field.set_text(&f, "aüb")
	field.select_range(&f, 4, 0) // backwards is fine
	testing.expect_value(t, f.anchor, 4)
	testing.expect_value(t, f.caret, 0)
	testing.expect_value(t, field.selected_text(&f), "aüb")
	field.select_range(&f, 2, 9) // inside ü, and past the end
	testing.expect_value(t, f.anchor, 1)
	testing.expect_value(t, f.caret, 4)
}

@(test)
test_newlines :: proc(t: ^testing.T) {
	f: field.Field
	defer field.destroy(&f)
	field.insert(&f, "one", typing = true)
	field.insert(&f, "\n")
	field.insert(&f, "two", typing = true)
	testing.expect_value(t, field.text(&f), "one\ntwo")
	// A newline separates words like a space does.
	s := field.text(&f)
	testing.expect_value(t, field.prev_word(s, len(s)), 4)
	testing.expect_value(t, field.prev_word(s, 4), 0)
	testing.expect_value(t, field.next_word(s, 3), 7)
	start, end := field.word_at(s, 5)
	testing.expect_value(t, start, 4)
	testing.expect_value(t, end, 7)
	// Backspace at the start of a line joins it to the line above.
	field.set_caret(&f, 4)
	field.delete_to(&f, .Left)
	testing.expect_value(t, field.text(&f), "onetwo")
	field.undo(&f)
	testing.expect_value(t, field.text(&f), "one\ntwo")
	testing.expect_value(t, f.caret, 4)
}
