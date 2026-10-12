// Package abi is the contract between pages and the browser.
//
// It holds only constants and plain data layouts so that both the host (native)
// and the page SDK (freestanding_riscv64) can import it. See docs/syscalls.md.
package abi

ABI_VERSION :: 1

// Syscall numbers, passed in a7. Arguments go in a0..a5; the result comes back
// in a0 as a value >= 0, or a negated Errno on failure.
//
// Numbers are grouped by subsystem in blocks of 0x100.
Syscall :: enum u32 {
	// 0x000 core
	Exit         = 0x000, // (code)                      -> does not return
	Debug_Log    = 0x001, // (ptr, len, level)           -> 0
	Abi_Version  = 0x002, // ()                          -> ABI_VERSION
	Mem_Grow     = 0x003, // (delta_bytes)               -> previous break
	Time_Now     = 0x004, // ()                          -> monotonic ns, 1 ms granularity
	Random       = 0x005, // (ptr, len)                  -> len
	Wait_Event   = 0x006, // (event_ptr, timeout_ms)     -> 1 event written, 0 timed out
	Handle_Close = 0x007, // (handle)                    -> 0

	// 0x100 view tree
	Node_Create   = 0x100, // (kind)                     -> handle
	Node_Set_Text = 0x101, // (handle, ptr, len)         -> 0
	Node_Set_Attr = 0x102, // (handle, attr, ptr, len)   -> 0
	Node_Append   = 0x103, // (parent, child)            -> 0
	Node_Remove   = 0x104, // (handle)                   -> 0   detach from parent
	Root_Set      = 0x105, // (handle)                   -> 0
	Node_Get_Text = 0x106, // (handle, ptr, cap)         -> full length; copies min(length, cap) bytes
	// An Input's selection, as byte offsets into its text. See Selection.
	Input_Get_Selection = 0x107, // (handle, ptr)          -> 0   writes a Selection
	Input_Set_Selection = 0x108, // (handle, anchor, caret) -> 0
	Input_Focus         = 0x109, // (handle)               -> 0   0 takes focus off the page's Inputs
	// An Image's picture: an encoded PNG or baseline JPEG, decoded by the
	// browser. len 0 clears it.
	Image_Set_Data      = 0x10A, // (handle, ptr, len)     -> 0

	// 0x200 canvas. Colours are 0xRRGGBBAA; pixels are RGBA8, row-major.
	Canvas_Clear      = 0x200, // (handle, rgba)             -> 0
	Canvas_Fill_Rect  = 0x201, // (handle, x, y, w, h, rgba) -> 0   clipped to the canvas
	Canvas_Put_Pixels = 0x202, // (handle, ptr, len)         -> 0   len must be width*height*4

	// 0x300 fetch: data from the servers named in the manifest's `fetch`
	// lines. A request completes in the background and is announced by a
	// Fetch event; the body is then read from the stream handle.
	Fetch_Open = 0x300, // (url_ptr, url_len)   -> stream handle
	Fetch_Read = 0x301, // (handle, ptr, cap)   -> bytes copied, 0 at the end of the body

	// 0x400 storage: a private key-value store per site, limited by the
	// manifest's `storage` quota. Keys are 1..MAX_STORAGE_KEY bytes of UTF-8.
	Storage_Get    = 0x400, // (key_ptr, key_len, buf_ptr, cap)   -> full value length; copies min(length, cap)
	Storage_Set    = 0x401, // (key_ptr, key_len, val_ptr, val_len) -> 0
	Storage_Delete = 0x402, // (key_ptr, key_len)                 -> 0
	Storage_Usage  = 0x403, // ()                                 -> bytes used (keys + values)

	// 0x500 clipboard: reserved.
}

Errno :: enum i32 {
	OK       = 0,
	PERM     = 1, // not allowed by the manifest or browser policy
	INVAL    = 2, // bad argument
	FAULT    = 3, // pointer range outside guest memory or lacking permission
	BADH     = 4, // stale, closed or wrong-kind handle
	NOSYS    = 5, // unknown syscall number
	NOMEM    = 6, // out of guest memory or host quota
	AGAIN    = 7, // try again later
	RANGE    = 8, // value too large (text length, handle count, ...)
	TIMEDOUT = 9,
	NOENT    = 10, // no such key
	NOSPC    = 11, // the storage quota would be exceeded
	NET      = 12, // the server could not be reached, or did not prove its identity
}

Log_Level :: enum u32 {
	Info  = 0,
	Warn  = 1,
	Error = 2,
}

// Handles are opaque. 0 is never a valid handle.
Handle :: distinct u32

INVALID_HANDLE :: Handle(0)

Node_Kind :: enum u32 {
	Box       = 0, // generic container
	Text      = 1, // inline run of text
	Heading   = 2,
	Paragraph = 3,
	Link      = 4,
	Button    = 5,
	Input     = 6,
	Image     = 7, // a picture set with Image_Set_Data; inline inside a paragraph
	Canvas    = 8,
	List      = 9,
	List_Item = 10,
	// Inline kinds: inside a Paragraph, Heading or List_Item (together with
	// Text and Link) they flow as one wrapped paragraph.
	Emphasis  = 11, // italic
	Strong    = 12, // bold
	Code      = 13, // monospace
	Text_Area = 14, // multi-line Input: wraps, Enter inserts a newline
}

// Kinds the browser edits: they take the Input syscalls and send Change and
// Select events.
EDITABLE :: bit_set[Node_Kind]{.Input, .Text_Area}

// Attributes are semantic or layout hints. Values are UTF-8 strings; the
// browser decides how to honour them, and user settings may override them.
Attr :: enum u32 {
	Href      = 0, // Link target
	Alt       = 1, // text alternative for Image / Canvas
	Label     = 2, // accessible label
	Direction = 3, // "row" | "column"
	Gap       = 4, // spacing between children, in px
	Padding   = 5, // px
	Color     = 6, // "#rrggbb"
	Background = 7,
	Font_Size = 8, // px
	Width     = 9,
	Height    = 10,
	Level     = 11, // Heading level "1".."6"
	Id        = 12, // page-chosen identifier echoed back in events
}

Event_Kind :: enum u32 {
	None   = 0,
	Quit   = 1, // the page is being closed; clean up and exit
	Timer  = 2,
	Click  = 3, // handle = clicked node, a/b = x/y relative to the node, c = Modifiers
	Key    = 4, // handle = focused node or 0, a = Key or code point, b = Modifiers, c = 1 down / 0 up
	Text   = 5, // a = Unicode code point
	Resize = 6, // a = viewport width, b = viewport height, in px
	Fetch  = 7, // handle = fetch stream, a = server status (200, 404, ...) or a negated Errno, b = body length
	Change = 8, // handle = Input node whose text the user edited; read it with Node_Get_Text
	Select = 9, // handle = Input node whose caret or selection the user moved, a = anchor, b = caret
}

// Event.a for Key events. Printable keys use their (unshifted, lowercase)
// Unicode code point; the rest use these values.
Key :: enum i64 {
	Backspace = 0x08,
	Tab       = 0x09,
	Enter     = 0x0D,
	Escape    = 0x1B,
	Delete    = 0x7F,
	Left      = 0x1_0000,
	Right,
	Up,
	Down,
	Home,
	End,
	Page_Up,
	Page_Down,
}

// Modifier keys held during an event: Event.b for Key, Event.c for Click.
Modifier :: enum u8 {
	Shift,
	Ctrl,
	Alt,
	Super,
}
Modifiers :: bit_set[Modifier; i64]

// Event is written to guest memory by Wait_Event. The layout is identical on the
// host and the guest: both are 64-bit little-endian.
Event :: struct {
	kind:   Event_Kind,
	handle: Handle,
	a:      i64,
	b:      i64,
	c:      i64,
}

#assert(size_of(Event) == 32)

// An Input's selection, written to guest memory by Input_Get_Selection.
// Offsets are bytes into the text, on rune boundaries. The selection runs
// from `anchor` (where it started) to `caret` (the end that moves); they are
// equal when nothing is selected.
Selection :: struct {
	anchor: i64,
	caret:  i64,
}

#assert(size_of(Selection) == 16)

// Limits a page can rely on.
MAX_LOG_LEN    :: 16 * 1024
MAX_TEXT_LEN   :: 1024 * 1024
MAX_ATTR_LEN   :: 64 * 1024
MAX_RANDOM_LEN :: 64 * 1024
MAX_NODES      :: 100_000
MAX_CANVAS_DIM :: 4096
MAX_IMAGE_BYTES :: 16 * 1024 * 1024  // encoded
MAX_IMAGE_DIM   :: 4096
MAX_IMAGE_TOTAL :: 256 * 1024 * 1024 // decoded RGBA, all of a page's images together
MAX_STORAGE_KEY   :: 256
MAX_STORAGE_VALUE :: 1024 * 1024
MAX_STORAGE_QUOTA :: 16 * 1024 * 1024 // larger manifest requests are capped
MAX_FETCH_URL  :: 2048
MAX_FETCH_BODY :: 16 * 1024 * 1024
MAX_FETCHES    :: 16 // requests in flight per page, counting closed streams until they finish

DEFAULT_CANVAS_WIDTH  :: 300
DEFAULT_CANVAS_HEIGHT :: 150
