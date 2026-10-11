package search_test

import "core:testing"

import "../../src/search"

@(test)
test_find_all :: proc(t: ^testing.T) {
	Case :: struct {
		hay, needle: string,
		want:        [][2]int,
	}
	cases := []Case{
		{"No HTML, no JavaScript", "no", {{0, 2}, {9, 11}}},
		{"aaaa", "aa", {{0, 2}, {2, 4}}},               // non-overlapping
		{"Grüße GRÜSSE grüße", "GRÜ", {{0, 4}, {8, 12}, {16, 20}}}, // non-ASCII case folding, byte offsets
		{"abc", "", {}},
		{"abc", "abcd", {}},
		{"", "a", {}},
	}
	for c in cases {
		got := search.find_all(c.hay, c.needle)
		ok := len(got) == len(c.want)
		for i in 0 ..< min(len(got), len(c.want)) {
			ok = ok && got[i] == c.want[i]
		}
		testing.expectf(t, ok, "find_all(%q, %q) = %v, want %v", c.hay, c.needle, got[:], c.want)
	}
}
