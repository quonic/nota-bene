package places_test

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../../src/places"

@(private = "file")
locations :: proc(l: ^places.List) -> []string {
	out := make([]string, len(l.entries), context.temp_allocator)
	for e, i in l.entries {
		out[i] = e.location
	}
	return out
}

@(private = "file")
expect_locations :: proc(t: ^testing.T, l: ^places.List, want: []string, loc := #caller_location) {
	got := locations(l)
	testing.expect_value(t, len(got), len(want), loc = loc)
	for w, i in want {
		if i < len(got) {
			testing.expect_value(t, got[i], w, loc = loc)
		}
	}
}

// A revisit must move the entry, not duplicate it, and take the new title.
@(test)
test_visit_dedupes_and_bumps :: proc(t: ^testing.T) {
	l: places.List
	defer places.destroy(&l)
	places.visit(&l, "nb://a/", "A", 10)
	places.visit(&l, "nb://b/", "B", 20)
	places.visit(&l, "nb://a/", "A again", 30)
	expect_locations(t, &l, {"nb://b/", "nb://a/"})
	testing.expect_value(t, l.entries[1].title, "A again")
	testing.expect_value(t, l.entries[1].time, 30)
}

// The limit drops the oldest visits, never the newest.
@(test)
test_visit_limit_drops_oldest :: proc(t: ^testing.T) {
	l := places.List{limit = 2}
	defer places.destroy(&l)
	places.visit(&l, "x", "", 1)
	places.visit(&l, "y", "", 2)
	places.visit(&l, "z", "", 3)
	expect_locations(t, &l, {"y", "z"})
}

// Locations with tabs or newlines would break the line format; they are refused.
@(test)
test_visit_refuses_unstorable_locations :: proc(t: ^testing.T) {
	l: places.List
	defer places.destroy(&l)
	testing.expect(t, !places.visit(&l, "a\tb", "", 1))
	testing.expect(t, !places.visit(&l, "a\nb", "", 1))
	testing.expect(t, !places.visit(&l, "", "", 1))
	testing.expect(t, !places.visit(&l, "bad\xffutf8", "", 1))
	testing.expect_value(t, len(l.entries), 0)
}

@(test)
test_clean_title :: proc(t: ^testing.T) {
	Case :: struct {
		in_, want: string,
	}
	cases := []Case {
		{"  Hello,\t\n  world  ", "Hello, world"}, // control characters and runs of spaces collapse
		{"bad\xffbyte", "bad�byte"},          // invalid UTF-8 is replaced, not stored
		{"", ""},
	}
	for c in cases {
		got := places.clean_title(c.in_, context.temp_allocator)
		testing.expect_value(t, got, c.want)
	}
	// Cut at a character boundary, never in the middle of one.
	long := strings.repeat("é", 150, context.temp_allocator) // 300 bytes
	got := places.clean_title(long, context.temp_allocator)
	testing.expect(t, len(got) <= places.MAX_TITLE_BYTES)
	testing.expect_value(t, len(got), places.MAX_TITLE_BYTES)
	testing.expect(t, strings.has_suffix(got, "é"))
}

// toggle must tell a refused location from a removal, so the browser does
// not report removing a bookmark it never had.
@(test)
test_toggle :: proc(t: ^testing.T) {
	l: places.List
	defer places.destroy(&l)
	testing.expect_value(t, places.toggle(&l, "nb://a/", "A", 1), places.Toggled.Added)
	testing.expect(t, places.contains(&l, "nb://a/"))
	testing.expect_value(t, places.toggle(&l, "nb://a/", "A", 2), places.Toggled.Removed)
	testing.expect(t, !places.contains(&l, "nb://a/"))
	testing.expect_value(t, places.toggle(&l, "a\nb", "", 3), places.Toggled.Refused)
	testing.expect_value(t, len(l.entries), 0)
}

// A revisit without a title (a reload of a page named by its heading) must
// not wipe the title the entry already has.
@(test)
test_visit_keeps_title_when_new_one_is_empty :: proc(t: ^testing.T) {
	l: places.List
	defer places.destroy(&l)
	places.visit(&l, "a", "From the heading", 1)
	places.visit(&l, "a", "", 2)
	testing.expect_value(t, l.entries[0].title, "From the heading")
	testing.expect_value(t, l.entries[0].time, 2)
	places.visit(&l, "a", "New title", 3)
	testing.expect_value(t, l.entries[0].title, "New title")
}

// Two browsers saving at once must not share a temporary file.
@(test)
test_temp_paths_are_unique :: proc(t: ^testing.T) {
	a := places.temp_path("/p/history", context.temp_allocator)
	b := places.temp_path("/p/history", context.temp_allocator)
	testing.expect(t, a != b)
	testing.expect(t, strings.has_prefix(a, "/p/history."))
	testing.expect(t, strings.contains(a, fmt.tprintf(".%d.", os.get_pid())))
}

// A file that exists but cannot be read is never replaced by a save.
@(test)
test_unreadable_file_makes_list_read_only :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "places-test-*", context.temp_allocator)
	testing.expect_value(t, err, nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "history"}, context.temp_allocator)
	testing.expect_value(t, os.make_directory(path), nil) // reading a directory fails

	l: places.List
	defer places.destroy(&l)
	testing.expect(t, !places.load(&l, path, 5))
	testing.expect(t, l.read_only)
	places.visit(&l, "a", "", 1)
	testing.expect(t, !places.save(&l, "test"))
	testing.expect(t, os.is_dir(path))

	// A missing file is only an empty list.
	missing: places.List
	defer places.destroy(&missing)
	other, _ := filepath.join({dir, "bookmarks"}, context.temp_allocator)
	testing.expect(t, places.load(&missing, other, 5))
	testing.expect(t, !missing.read_only)
}

// Only one browser at a time may write a profile; unlocking frees it.
@(test)
test_profile_lock :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		dir, err := os.make_directory_temp("", "places-test-*", context.temp_allocator)
		testing.expect_value(t, err, nil)
		defer os.remove_all(dir)
		first, ok := places.lock_profile(dir)
		testing.expect(t, ok)
		second, ok2 := places.lock_profile(dir)
		testing.expect(t, !ok2)
		places.unlock_profile(&second)
		places.unlock_profile(&first)
		again, ok3 := places.lock_profile(dir)
		testing.expect(t, ok3)
		places.unlock_profile(&again)
	}
}

@(test)
test_set_title_and_remove :: proc(t: ^testing.T) {
	l: places.List
	defer places.destroy(&l)
	places.visit(&l, "a", "a", 1)
	places.visit(&l, "b", "b", 2)
	testing.expect(t, places.set_title(&l, "a", "Heading"))
	testing.expect_value(t, l.entries[0].title, "Heading")
	testing.expect(t, !places.set_title(&l, "missing", "x"))
	testing.expect(t, places.remove_location(&l, "a"))
	testing.expect(t, !places.remove_location(&l, "a"))
	places.remove(&l, 5) // out of range: ignored
	expect_locations(t, &l, {"b"})
}

// Newest first, matching title or location without regard to case.
@(test)
test_filter :: proc(t: ^testing.T) {
	l: places.List
	defer places.destroy(&l)
	places.visit(&l, "nb://example.org/", "Welcome", 1)
	places.visit(&l, "/home/u/notes.elf", "Notes", 2)
	places.visit(&l, "nb://other.net/", "Example list", 3)
	all := places.filter(&l, "", context.temp_allocator)
	testing.expect_value(t, len(all), 3)
	testing.expect_value(t, all[0], 2)
	got := places.filter(&l, "EXAMPLE", context.temp_allocator)
	testing.expect_value(t, len(got), 2)
	testing.expect_value(t, l.entries[got[0]].location, "nb://other.net/") // by title, and newest
	testing.expect_value(t, l.entries[got[1]].location, "nb://example.org/") // by location
	testing.expect_value(t, len(places.filter(&l, "zzz", context.temp_allocator)), 0)
}

// What is saved parses back to the same entries.
@(test)
test_round_trip :: proc(t: ^testing.T) {
	l: places.List
	defer places.destroy(&l)
	places.visit(&l, "nb://a/", "Title with # and spaces", 100)
	places.visit(&l, "/tmp/x.elf", "", 200)
	text := places.serialize(&l, "test", context.temp_allocator)
	back: places.List
	defer places.destroy(&back)
	testing.expect_value(t, places.parse(&back, text), 0)
	testing.expect_value(t, len(back.entries), 2)
	for e, i in l.entries {
		testing.expect_value(t, back.entries[i].location, e.location)
		testing.expect_value(t, back.entries[i].title, e.title)
		testing.expect_value(t, back.entries[i].time, e.time)
	}
}

// A damaged file loses only its damaged lines; order and duplicates are repaired.
@(test)
test_parse_tolerates_damage :: proc(t: ^testing.T) {
	text := "# comment\n" +
		"300\tnb://c/\tC\n" +
		"garbage line\n" +
		"notanumber\tnb://x/\tX\n" +
		"100\tnb://a/\tA\r\n" +
		"200\tnb://c/\tOld C\n" +
		"150\t\tempty location\n" +
		"250\tnb://b/\n" + // no title field
		"\n"
	l := places.List{limit = 10}
	defer places.destroy(&l)
	testing.expect_value(t, places.parse(&l, text), 3)
	expect_locations(t, &l, {"nb://a/", "nb://b/", "nb://c/"})
	testing.expect_value(t, l.entries[0].title, "A")
	testing.expect_value(t, l.entries[1].title, "")
	testing.expect_value(t, l.entries[2].title, "C") // the newer duplicate wins
}

// A file longer than the limit (an older build, a hand edit) keeps the newest.
@(test)
test_parse_applies_limit :: proc(t: ^testing.T) {
	l := places.List{limit = 1}
	defer places.destroy(&l)
	places.parse(&l, "2\tnew\t\n1\told\t\n")
	expect_locations(t, &l, {"new"})
}

// save writes through a temporary file and load reads it back; no .tmp is left.
@(test)
test_save_and_load :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "places-test-*", context.temp_allocator)
	testing.expect_value(t, err, nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "profile", "history"}, context.temp_allocator)

	l: places.List
	defer places.destroy(&l)
	places.load(&l, path, 5) // missing file: empty
	testing.expect_value(t, len(l.entries), 0)
	places.visit(&l, "nb://a/", "A", 1)
	testing.expect(t, places.save(&l, "Nota Bene history"))
	testing.expect(t, !os.exists(strings.concatenate({path, ".tmp"}, context.temp_allocator)))

	back: places.List
	defer places.destroy(&back)
	places.load(&back, path, 5)
	expect_locations(t, &back, {"nb://a/"})
	testing.expect_value(t, back.entries[0].title, "A")
}

@(test)
test_age_text :: proc(t: ^testing.T) {
	now := i64(1_800_000_000)
	testing.expect_value(t, places.age_text(now - 5, now), "just now")
	testing.expect_value(t, places.age_text(now - 5 * 60, now), "5 min ago")
	testing.expect_value(t, places.age_text(now - 3 * 3600, now), "3 h ago")
	testing.expect_value(t, places.age_text(now - 30 * 3600, now), "yesterday")
	testing.expect_value(t, places.age_text(now - 4 * 86_400, now), "4 days ago")
	testing.expect_value(t, places.age_text(0, now), "1970-01-01")
	testing.expect_value(t, places.age_text(now + 100, now), "just now") // a clock that went back
}
