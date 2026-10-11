// Package search finds text the way find-in-page does: case-insensitively,
// rune by rune, reporting byte ranges in the original text.
package search

import "core:unicode"
import "core:unicode/utf8"

// Case-insensitive search: byte offsets of every non-overlapping occurrence
// of `needle` in `hay`, comparing lowercased runes.
find_all :: proc(hay, needle: string, allocator := context.temp_allocator) -> [dynamic][2]int {
	out := make([dynamic][2]int, allocator)
	if len(needle) == 0 {
		return out
	}
	for start := 0; start < len(hay); {
		h, n := start, 0
		for n < len(needle) && h < len(hay) {
			hr, hs := utf8.decode_rune_in_string(hay[h:])
			nr, ns := utf8.decode_rune_in_string(needle[n:])
			if unicode.to_lower(hr) != unicode.to_lower(nr) {
				break
			}
			h += hs
			n += ns
		}
		if n == len(needle) {
			append(&out, [2]int{start, h})
			start = h
			continue
		}
		_, size := utf8.decode_rune_in_string(hay[start:])
		start += size
	}
	return out
}
