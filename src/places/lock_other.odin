#+build !linux
package places

import "core:os"

// Not enforced on other systems yet: every browser may save. Saves still
// go through a temporary file unique to the process, so a file is never
// left half written, but two browsers on one profile keep whichever saved
// last.
@(private)
try_lock :: proc(f: ^os.File) -> bool {
	_ = f
	return true
}
