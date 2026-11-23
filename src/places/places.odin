// Package places keeps the browser's history and bookmarks: lists of
// visited or saved locations with a title and a time, bounded, deduplicated
// and stored as plain text in the profile. It has no graphics and no page
// ever sees it, so it is unit tested on its own.
package places

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import "../search"

HISTORY_LIMIT   :: 1000   // most recent visits kept
BOOKMARK_LIMIT  :: 10_000 // only bounds what a damaged file can make us hold
MAX_TITLE_BYTES :: 200

Entry :: struct {
	location: string,
	title:    string,
	time:     i64, // Unix seconds: the last visit, or when it was bookmarked
}

// Entries are kept oldest first, so a visit is an append and the newest
// entry is the last.
List :: struct {
	entries: [dynamic]Entry,
	limit:   int,    // 0 = unbounded
	path:    string, // where save writes; empty for a list that is not stored
}

destroy :: proc(l: ^List) {
	for &e in l.entries {
		entry_destroy(&e)
	}
	delete(l.entries)
	delete(l.path)
	l^ = {}
}

@(private)
entry_destroy :: proc(e: ^Entry) {
	delete(e.location)
	delete(e.title)
	e^ = {}
}

// Whether a location can be stored: the file has one entry per line and
// tab-separated fields, so it must have no control characters.
valid_location :: proc(location: string) -> bool {
	if location == "" || !utf8.valid_string(location) {
		return false
	}
	for c in transmute([]u8)location {
		if c < 0x20 || c == 0x7F {
			return false
		}
	}
	return true
}

// `title` made fit for the list: valid UTF-8, runs of whitespace and control
// characters collapsed to one space, trimmed and cut to MAX_TITLE_BYTES at a
// character boundary.
clean_title :: proc(title: string, allocator := context.allocator) -> string {
	valid := strings.to_valid_utf8(title, "�", context.temp_allocator)
	sb := strings.builder_make(allocator)
	space := false
	for r in valid {
		if r < 0x20 || r == 0x7F || r == ' ' || r == 0xA0 {
			space = strings.builder_len(sb) > 0
			continue
		}
		size := utf8.rune_size(r) + (1 if space else 0)
		if strings.builder_len(sb) + size > MAX_TITLE_BYTES {
			break
		}
		if space {
			strings.write_byte(&sb, ' ')
			space = false
		}
		strings.write_rune(&sb, r)
	}
	return strings.to_string(sb)
}

// The index of `location`, or -1.
find :: proc(l: ^List, location: string) -> int {
	for e, i in l.entries {
		if e.location == location {
			return i
		}
	}
	return -1
}

contains :: proc(l: ^List, location: string) -> bool {
	return find(l, location) >= 0
}

// Records a visit: a location seen before moves to the newest place with
// the new title and time. The oldest entries go beyond the limit. False
// (and nothing recorded) for a location that cannot be stored.
visit :: proc(l: ^List, location, title: string, now: i64) -> bool {
	if !valid_location(location) {
		return false
	}
	if i := find(l, location); i >= 0 {
		e := l.entries[i]
		ordered_remove(&l.entries, i)
		delete(e.title)
		e.title = clean_title(title)
		e.time = now
		append(&l.entries, e)
	} else {
		append(&l.entries, Entry{strings.clone(location), clean_title(title), now})
	}
	trim(l)
	return true
}

// Changes the title of `location`, if it is in the list.
set_title :: proc(l: ^List, location, title: string) -> bool {
	i := find(l, location)
	if i < 0 {
		return false
	}
	e := &l.entries[i]
	clean := clean_title(title)
	if clean == e.title {
		delete(clean)
		return false
	}
	delete(e.title)
	e.title = clean
	return true
}

// Adds `location` if it is missing, removes it otherwise. Returns whether
// it is in the list afterwards.
toggle :: proc(l: ^List, location, title: string, now: i64) -> bool {
	if remove_location(l, location) {
		return false
	}
	return visit(l, location, title, now)
}

remove :: proc(l: ^List, index: int) {
	if index < 0 || index >= len(l.entries) {
		return
	}
	entry_destroy(&l.entries[index])
	ordered_remove(&l.entries, index)
}

remove_location :: proc(l: ^List, location: string) -> bool {
	i := find(l, location)
	if i < 0 {
		return false
	}
	remove(l, i)
	return true
}

@(private)
trim :: proc(l: ^List) {
	if l.limit <= 0 || len(l.entries) <= l.limit {
		return
	}
	extra := len(l.entries) - l.limit
	for &e in l.entries[:extra] {
		entry_destroy(&e)
	}
	remove_range(&l.entries, 0, extra)
}

// Indices of the entries whose title or location contains `query`
// (case-insensitively, as find in page matches), newest first. An empty
// query matches everything.
filter :: proc(l: ^List, query: string, allocator := context.allocator) -> [dynamic]int {
	out := make([dynamic]int, allocator)
	for i := len(l.entries) - 1; i >= 0; i -= 1 {
		e := l.entries[i]
		if query == "" || matches(e.title, query) || matches(e.location, query) {
			append(&out, i)
		}
	}
	return out
}

@(private)
matches :: proc(s, query: string) -> bool {
	return len(search.find_all(s, query, context.temp_allocator)) > 0
}

// The file form: a comment line, then one `time<TAB>location<TAB>title`
// line per entry, oldest first.
serialize :: proc(l: ^List, header: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	fmt.sbprintf(&sb, "# %s: unix-time<TAB>location<TAB>title, oldest first\n", header)
	for e in l.entries {
		fmt.sbprintf(&sb, "%d\t%s\t%s\n", e.time, e.location, e.title)
	}
	return strings.to_string(sb)
}

// Replaces the entries with those in `text`. Lines that do not parse are
// skipped, so a damaged file loses only its damaged lines. Entries are put
// in time order, a location listed twice keeps its newest entry, and the
// limit applies. Returns how many lines were skipped.
parse :: proc(l: ^List, text: string) -> (skipped: int) {
	for &e in l.entries {
		entry_destroy(&e)
	}
	clear(&l.entries)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if strings.trim_space(line) == "" || line[0] == '#' {
			continue
		}
		fields := strings.split_n(line, "\t", 3, context.temp_allocator)
		if len(fields) < 2 {
			skipped += 1
			continue
		}
		t, tok := strconv.parse_i64_of_base(fields[0], 10)
		location := strings.trim_right(fields[1], "\r")
		if !tok || !valid_location(location) {
			skipped += 1
			continue
		}
		title := fields[2] if len(fields) == 3 else ""
		append(&l.entries, Entry{strings.clone(location), clean_title(title), t})
	}
	slice.stable_sort_by(l.entries[:], proc(a, b: Entry) -> bool { return a.time < b.time })
	// Duplicates: keep the newest, which is the last one in time order.
	seen := make(map[string]bool, len(l.entries), context.temp_allocator)
	for i := len(l.entries) - 1; i >= 0; i -= 1 {
		if seen[l.entries[i].location] {
			remove(l, i)
		} else {
			seen[l.entries[i].location] = true
		}
	}
	trim(l)
	return
}

// Loads the list stored at `path`; a missing or unreadable file gives an
// empty list. Later saves go to `path`.
load :: proc(l: ^List, path: string, limit: int) {
	delete(l.path)
	l.path = strings.clone(path)
	l.limit = limit
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	parse(l, string(data))
}

// Writes the list to its path through a temporary file and a rename, so a
// crash mid-write never leaves a half-written file. The file is private to
// the user: it is their browsing history.
save :: proc(l: ^List, header: string) -> bool {
	if l.path == "" {
		return false
	}
	_ = os.make_directory_all(filepath.dir(l.path))
	tmp := strings.concatenate({l.path, ".tmp"}, context.temp_allocator)
	f, err := os.open(tmp, {.Write, .Create, .Trunc}, {.Read_User, .Write_User})
	if err != nil {
		return false
	}
	_, werr := os.write_string(f, serialize(l, header, context.temp_allocator))
	serr := os.sync(f)
	os.close(f)
	if werr != nil || serr != nil || os.rename(tmp, l.path) != nil {
		_ = os.remove(tmp)
		return false
	}
	return true
}

// How long ago `then` was, for the list: "just now", "5 min ago", "3 h ago",
// "yesterday", "4 days ago", then the date (UTC). Temp-allocated.
age_text :: proc(then, now: i64) -> string {
	d := now - then
	switch {
	case d < 60:
		return "just now"
	case d < 3600:
		return fmt.tprintf("%d min ago", d / 60)
	case d < 86_400:
		return fmt.tprintf("%d h ago", d / 3600)
	case d < 2 * 86_400:
		return "yesterday"
	case d < 14 * 86_400:
		return fmt.tprintf("%d days ago", d / 86_400)
	}
	y, m, day := time.date(time.unix(then, 0))
	return fmt.tprintf("%04d-%02d-%02d", y, int(m), day)
}
