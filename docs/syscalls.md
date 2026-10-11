# Syscall ABI

ABI version **1**. The constants live in [`src/abi/abi.odin`](../src/abi/abi.odin),
which both the browser and the SDK import.

## Calling convention

This follows the Linux RISC-V convention:

| Register | Use |
|---|---|
| `a7` | syscall number |
| `a0` … `a5` | arguments |
| `a0` | result: `>= 0` on success, `-errno` on failure |

All other registers are preserved. Strings and buffers are always passed as
`(pointer, length)` pairs. Strings must be valid UTF-8. The browser checks
that the whole range lies inside guest memory with the right permission, and
fails with `-FAULT` otherwise. It never trusts a guest pointer.

Numbers are grouped in blocks of `0x100` per subsystem. Unknown numbers
return `-NOSYS`, so a page can probe for newer features.

## Errors

| Value | Name | Meaning |
|---|---|---|
| 1 | `PERM` | not allowed by the manifest or browser policy |
| 2 | `INVAL` | bad argument |
| 3 | `FAULT` | buffer outside guest memory or lacking permission |
| 4 | `BADH` | handle is invalid, closed, or the wrong kind |
| 5 | `NOSYS` | unknown syscall |
| 6 | `NOMEM` | out of guest memory or quota |
| 7 | `AGAIN` | try again later |
| 8 | `RANGE` | length or count over a limit |
| 9 | `TIMEDOUT` | |
| 10 | `NOENT` | no such storage key |
| 11 | `NOSPC` | the write would exceed the storage quota |
| 12 | `NET` | the server could not be reached, or did not prove its identity |

## Core (`0x000`)

| Nr | Name | Arguments | Returns |
|---|---|---|---|
| `0x000` | `Exit` | `code` (i32) | does not return |
| `0x001` | `Debug_Log` | `ptr, len, level` (0 info, 1 warn, 2 error) | 0. `len` ≤ 16 KiB |
| `0x002` | `Abi_Version` | | `1` |
| `0x003` | `Mem_Grow` | `delta` bytes (rounded up to 4 KiB) | previous break. `-NOMEM` if the heap would reach the stack guard. `-INVAL` if `delta < 0` |
| `0x004` | `Time_Now` | | monotonic ns since page start, **1 ms granularity** |
| `0x005` | `Random` | `ptr, len` (≤ 64 KiB) | `len`. Cryptographically secure |
| `0x006` | `Wait_Event` | `event_ptr, timeout_ms` (-1 forever, 0 poll) | 1 if an event was written, 0 on timeout |
| `0x007` | `Handle_Close` | `handle` | 0 |

`Wait_Event` writes a 32-byte `Event`:

```odin
Event :: struct {      // offset
	kind:   Event_Kind, // 0   u32
	handle: Handle,     // 4   u32: the node or stream the event concerns
	a, b, c: i64,       // 8, 16, 24: kind-specific
}
```

| Kind | Value | Fields |
|---|---|---|
| `Quit` | 1 | The page is closing. Clean up and return from `main` or `Exit`. |
| `Timer` | 2 | |
| `Click` | 3 | `handle` = the nearest Button, Link, Input or Canvas under the pointer (else the deepest node). `a`, `b` = position relative to the node (to the pixel grid, for a Canvas). `c` = `Modifiers` |
| `Key` | 4 | `handle` = focused Input or 0. `a` = `Key` value or the key's lowercase code point. `b` = `Modifiers`. `c` = 1 down / 0 up |
| `Text` | 5 | `handle` = focused Input or 0. `a` = a typed Unicode code point |
| `Resize` | 6 | `a` width, `b` height of the viewport in px. Sent once when the page starts and on every resize |
| `Fetch` | 7 | `handle` = fetch stream. `a` = the server's status (200, 404, …) or a negated error code. `b` = body length. See [Fetch](#fetch-0x300) |
| `Change` | 8 | `handle` = an Input whose text the user edited. Read it with `Node_Get_Text` |
| `Select` | 9 | `handle` = an Input whose caret or selection the user moved. `a` = anchor, `b` = caret. See [Input selection](#input-selection) |

**`Key` values** for non-character keys: `Backspace` 0x08, `Tab` 0x09,
`Enter` 0x0D, `Escape` 0x1B, `Delete` 0x7F, then `Left` 0x10000, `Right`,
`Up`, `Down`, `Home`, `End`, `Page_Up`, `Page_Down` in sequence.
**`Modifiers`** is a bit set: Shift 1, Ctrl 2, Alt 4, Super 8.

The browser keeps a few keys for itself and does not pass them to the page:
Ctrl+L / F6 (address bar), F5 / Ctrl+R (reload), Alt+Left (back), F12
(dump the tree), the tab keys (Ctrl+T, Ctrl+W, Ctrl+Tab, Ctrl+1…9), find
(Ctrl+F, F3), and Ctrl+A / Ctrl+C / Ctrl+X / Ctrl+V. Ctrl+A and Ctrl+C on
page text select and copy it, and the browser does that itself; so do Shift
with the arrows, Home and End while there is a selection on the page, though
the page still gets those `Key` events. In a focused Input, the browser also
keeps the keys it edits with: Left, Right, Home, End, Backspace and Delete
(with or without Shift and Ctrl), Ctrl+A, and Ctrl+Z / Ctrl+Y for undo and
redo. While the address bar has focus, no keys reach the page.

**Clipboard.** Pages have no clipboard syscalls. The user copies and pastes
in Inputs through the browser, and a paste arrives like typing: as `Text`
events plus one `Change`. That way a page can never read the clipboard
behind the user's back. Links with an
`Href` are followed by the browser; clicking one does not send a `Click`.

The headless runner has no input. It answers a timed wait by skipping the
clock ahead, and the first unbounded wait with `Quit`.

## View tree (`0x100`)

| Nr | Name | Arguments | Returns |
|---|---|---|---|
| `0x100` | `Node_Create` | `kind` | handle. `-RANGE` past 100 000 handles |
| `0x101` | `Node_Set_Text` | `handle, ptr, len` (≤ 1 MiB) | 0 |
| `0x102` | `Node_Set_Attr` | `handle, attr, ptr, len` (≤ 64 KiB). An empty value removes the attribute | 0 |
| `0x103` | `Node_Append` | `parent, child` | 0. Moves `child` if it already has a parent. `-INVAL` for cycles or appending the root |
| `0x104` | `Node_Remove` | `handle` | 0. Detaches from its parent; the node stays valid |
| `0x105` | `Root_Set` | `handle`, or 0 to clear | 0. `-INVAL` if the node has a parent |
| `0x106` | `Node_Get_Text` | `handle, ptr, cap` | the full text length in bytes. Copies `min(length, cap)` bytes. Use it to read what the user typed into an `Input` |
| `0x107` | `Input_Get_Selection` | `handle, ptr` | 0. Writes a 16-byte `Selection` |
| `0x108` | `Input_Set_Selection` | `handle, anchor, caret` | 0. `-RANGE` past the end of the text, `-INVAL` inside a character |
| `0x109` | `Input_Focus` | `handle`, or 0 | 0. Gives the Input keyboard focus; 0 takes focus off the page's Inputs. `-INVAL` for a node not in the tree under the root |

`Handle_Close` on a node detaches it. Its children become detached roots and
keep their handles.

**Node kinds:** 0 `Box`, 1 `Text`, 2 `Heading`, 3 `Paragraph`, 4 `Link`,
5 `Button`, 6 `Input`, 7 `Image`, 8 `Canvas`, 9 `List`, 10 `List_Item`,
11 `Emphasis`, 12 `Strong`, 13 `Code`.

**Inline text.** A `Paragraph`, `Heading` or `List_Item` whose children are
all *inline* (`Text`, `Link`, `Emphasis`, `Strong`, `Code`, nested to any
depth) flows its own text and its children's as one wrapped paragraph:

```odin
p := nb.el(.Paragraph, root, "Read the ")
l := nb.el(.Link, p, "manual")
nb.set_attr(l, .Href, "manual.elf")
nb.el(.Text, p, " or ")
nb.el(.Code, p, "nb.start")
nb.el(.Text, p, ".")
```

- **Styles nest.** Inline nodes inherit the surrounding font: a `Link`
  inside a `Heading` is heading-sized, and `Code` inside `Emphasis` is italic
  monospace. They may set `Color`, `Background` and `Font_Size`.
- **Clicks** report the inline node that was clicked: the link, not the
  paragraph.
- **Spaces are part of the text.** Put them inside the runs (`"Read the "`),
  as in the example.
- **Mixed content stays block layout.** A paragraph that also contains block
  children (a `Button`, say) lays every child out as a block.

**Attributes:** 0 `Href`, 1 `Alt`, 2 `Label`, 3 `Direction` (`row`|`column`),
4 `Gap`, 5 `Padding`, 6 `Color` (`#rrggbb`), 7 `Background`, 8 `Font_Size`,
9 `Width`, 10 `Height`, 11 `Level` (heading 1–6), 12 `Id`.

Attributes are hints. The browser, and the user's settings, have the final
say on presentation.

**Input nodes are edited by the browser.** When the user types into a
focused `Input`, the browser updates the node's text itself and sends
`Change`. The browser keeps the caret, the selection and the undo history,
so the page does not have to implement text editing, and it sees no `Key`
events for editing keys, only `Text` for what was typed and `Change` after
every edit. A page can still set the text with `Node_Set_Text`. The caret
stays where it was if it still fits, and the user's undo history for that
Input starts over.

### Input selection

A page can ask where the caret and selection are in an Input, and move
them. Offsets are bytes into the Input's text, on character boundaries, as
with `Node_Get_Text`.

```odin
Selection :: struct { // offset
	anchor: i64,      // 0: where the selection started
	caret:  i64,      // 8: the end that moves; equal to anchor when nothing is selected
}
```

- **`Select` events** report each move the user makes: arrows, clicks,
  drags, Ctrl+A, and typing, which moves the caret. A drag sends at most one
  per frame. Typing sends `Text`, then `Change`, then `Select`.
- **`Input_Get_Selection`** works on any Input. One that does not have focus
  keeps the selection it had when it lost focus. A new Input has its caret at 0.
- **`Input_Set_Selection`** moves the caret to `caret`, selecting from
  `anchor`. Pass the same offset twice for a caret with no selection. It
  sends no `Select` event. On an Input without focus, the selection takes
  effect when the Input is focused, by the user or with `Input_Focus`;
  otherwise focusing puts the caret at the end of the text.
- **`Input_Focus`** moves the keyboard focus, as a click or Tab would. It
  does not scroll the Input into view. While the user is typing in the
  browser's address bar or find bar, the request is ignored.
- **`Node_Set_Text`** keeps the selection where it still fits, and pulls it
  back to the end of the new text otherwise.

These syscalls fail with `-INVAL` for a node that is not an Input.

## Canvas (`0x200`)

A `Canvas` node owns an RGBA8 pixel buffer sized by its `Width` and `Height`
attributes (default 300×150, at most 4096×4096). Changing either attribute
resizes the buffer and clears it to transparent. Colours are `0xRRGGBBAA`.

| Nr | Name | Arguments | Returns |
|---|---|---|---|
| `0x200` | `Canvas_Clear` | `handle, rgba` | 0 |
| `0x201` | `Canvas_Fill_Rect` | `handle, x, y, w, h, rgba` (signed; clipped to the canvas) | 0 |
| `0x202` | `Canvas_Put_Pixels` | `handle, ptr, len` | 0. `len` must be exactly `width × height × 4`. Rows are top to bottom, bytes R, G, B, A |

All three return `-INVAL` for a node that is not a `Canvas`. Pages that want
paths, text or anything else draw into their own buffer and upload it with
`Canvas_Put_Pixels` (see `examples/canvas`).

## Fetch (`0x300`)

A page can fetch data from the servers its manifest names, and from nowhere
else. Requests run in the background. A request returns a stream handle at
once, and a `Fetch` event follows when the answer is in.

| Nr | Name | Arguments | Returns |
|---|---|---|---|
| `0x300` | `Fetch_Open` | `url_ptr, url_len` (≤ 2048) | stream handle. `-PERM` if no manifest `fetch` line admits the URL. `-INVAL` for a malformed URL or another scheme. `-AGAIN` with 16 requests in flight. `-NOSYS` if the browser has no network (`nbrun`) |
| `0x301` | `Fetch_Read` | `handle, ptr, cap` | bytes copied, `0` at the end of the body. `-AGAIN` until the `Fetch` event |

```odin
h, err := nb.fetch("feed.txt")          // relative to the page's own address
// ... in the event loop:
case .Fetch:
	if ev.handle == h && ev.a == 200 {
		data, _ := nb.fetch_read_all(h, int(ev.b))
	}
	nb.close(h)
```

- **Addresses.** A request is an `nb://` URL, or a reference relative to the
  page's own address that resolves the way links do. `.` and `..` are folded
  before the manifest check. A page opened from a local file has no address,
  so it can only fetch absolute URLs.
- **What comes back.** The server returns the file at that path byte for byte
  (the `read` op in [protocol.md](protocol.md#messages)). The path must name
  the file exactly. A page path like `/hello` does not resolve to
  `hello.elf` here.
- **The `Fetch` event.** `a` is the server's status: 200 with the file as the
  body, or 404 or 500 with the server's message as the body. When no answer
  came back, `a` is a negated error code: `-NET` if the server could not be
  reached or failed the key check, `-RANGE` if the body is over 16 MiB.
  `b` is the body's length.
- **Keys.** A fetch authenticates the server like a page load does. It uses
  the key named in the manifest line or the URL, else the pinned key from
  `known_hosts`, else the key is pinned on first use. Relative requests
  carry the key the page itself was loaded from. A server holding a
  different key cannot answer them, even at the same address.
- **Closing a stream** with `Handle_Close` discards the body, or cancels a
  request that is still pending. A cancelled request still counts towards
  the 16 in flight until the network gives up on it. That way, opening and
  closing streams in a loop cannot pile up connections.
- **No ambient credentials.** Requests carry no cookies and no client
  identity, and each one uses its own connection.

## Storage (`0x400`)

Each site gets a private key-value store that persists across visits. The
size of the store is the manifest's `storage` quota, at most 16 MiB. A site
is the server's address together with its key, so a server with a new key
cannot read what pages stored under the old one. Local pages get one store
per file. Without a quota, every call fails with `-PERM`.

| Nr | Name | Arguments | Returns |
|---|---|---|---|
| `0x400` | `Storage_Get` | `key_ptr, key_len, buf_ptr, cap` | the value's full length. Copies `min(length, cap)` bytes. `-NOENT` if absent |
| `0x401` | `Storage_Set` | `key_ptr, key_len, val_ptr, val_len` | 0. `-NOSPC` over the quota |
| `0x402` | `Storage_Delete` | `key_ptr, key_len` | 0. `-NOENT` if absent |
| `0x403` | `Storage_Usage` | | bytes used: keys plus values |

Keys are 1 to 256 bytes of UTF-8. Values are at most 1 MiB.

## Reserved

| Block | Subsystem | Milestone |
|---|---|---|
| `0x500` | reserved (a page-initiated "copy this text", if ever needed, would go here, never a read) | chrome |

## Manifest

A page declares its needs in an ELF section named `.nb_manifest`. The section
holds plain UTF-8 text with one `key value` pair per line:

```
# comments start with '#'
abi 1
title Hello
fetch nb://example.org      # repeatable: servers the page may fetch from
fetch /                     # the page's own server
storage 1M                  # persistent storage quota
```

- **`fetch`** admits a server, optionally only part of it:

  | Line | Admits |
  |---|---|
  | `fetch nb://example.org` | every path on example.org, port 4040 |
  | `fetch nb://example.org:5000/api` | `/api` and everything below it, by whole segments (`/api/x`, not `/apix`) |
  | `fetch nb://<key>@example.org` | example.org, and only if it proves it holds `<key>` |
  | `fetch /` | the page's own server, with the key the page was loaded from |
  | `fetch /data` | `/data` and below on the page's own server |

  Relative lines keep a page portable between servers. Lines in any other
  form are ignored, with a warning.

- **`abi`** is the ABI version the page was built for. The browser refuses to
  load a page with a higher version than it supports.
- **Unknown keys** are reported as warnings, not errors, so older browsers can
  still run newer pages.
- **A page without a manifest** gets ABI 1, no network access and no storage.

The SDK build embeds `manifest.txt` from the page directory with
`llvm-objcopy`. That works for pages written in any language.

## Limits

| Limit | Value |
|---|---|
| Guest memory | 64 MiB by default, 1 GiB max (`nbrun --mem`) |
| Stack | 1 MiB by default (`nbrun --stack`) |
| Handles | 100 000 |
| Log line | 16 KiB |
| Node text | 1 MiB |
| Attribute value | 64 KiB |
| Random per call | 64 KiB |
| Canvas | 4096 × 4096 |
| Storage | the manifest's quota, at most 16 MiB; keys 256 bytes, values 1 MiB |
| Fetch | 16 requests in flight per page; URLs 2048 bytes; bodies 16 MiB |
| Running without waiting (`nb`) | 5 s, then the page is stopped |
