package places

import "core:os"
import "core:path/filepath"

// The profile lock: one browser at a time writes the history and bookmarks
// of a profile. Another browser started on the same profile can still read
// them, but treats them as read-only; otherwise the last one to save would
// silently drop what the other recorded.
Lock :: struct {
	file: ^os.File,
}

// Takes the file `lock` in profile directory `dir`, creating both if needed.
// ok is false if another browser holds it, or it cannot be made; the caller
// then makes its lists read-only.
lock_profile :: proc(dir: string) -> (lk: Lock, ok: bool) {
	_ = os.make_directory_all(dir)
	path, _ := filepath.join({dir, "lock"}, context.temp_allocator)
	f, err := os.open(path, {.Read, .Write, .Create}, {.Read_User, .Write_User})
	if err != nil {
		return
	}
	lk.file = f
	return lk, try_lock(f)
}

// Releases the lock: closing the file is what frees it.
unlock_profile :: proc(lk: ^Lock) {
	if lk.file != nil {
		os.close(lk.file)
	}
	lk^ = {}
}
