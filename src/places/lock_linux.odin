#+build linux
package places

import "core:os"
import "core:sys/linux"

// An flock lock belongs to the open file, so it is freed when the process
// exits, however it exits, and a second open in the same process conflicts
// too (the tests rely on that).
@(private)
try_lock :: proc(f: ^os.File) -> bool {
	return linux.flock(linux.Fd(os.fd(f)), {.EX, .NB}) == .NONE
}
