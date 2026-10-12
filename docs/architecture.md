# Architecture

A page is a compiled program, not a document. The browser downloads a RISC-V
executable, loads it into a sandboxed virtual machine, and the program builds
what the user sees by making syscalls. There is no HTML parser, no CSS engine
and no JavaScript runtime.

```
 ┌───────────────────── browser process ─────────────────────┐
 │                                                           │
 │  front end: nb (SDL3 window) or nbrun (headless)          │
 │        │ page_run / page_push_event / log_proc            │
 │        ▼                                                  │
 │  host ── handle table ── view tree ── (canvas, fetch, …)  │
 │        │ ecall: a7 = number, a0..a5 = args                │
 │        ▼                                                  │
 │  vm: RV64GC interpreter, flat guest memory, W^X pages     │
 │        ▲                                                  │
 │  loader: ELF64 → guest memory, manifest                   │
 └────────┼──────────────────────────────────────────────────┘
          │ page.elf: a local file, or a bundle fetched from nbd over
          │ Noise (see protocol.md)
```

## Components

| Path            | Package  | Role                                                                                                                                                                                                  |
| --------------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/abi`       | `abi`    | Syscall numbers, error codes, node kinds and attributes, the event layout. Constants only, so it compiles both for the host and for pages.                                                            |
| `src/vm`        | `vm`     | User-mode RV64GC interpreter. `run(cpu, budget)` stops on budget, `ecall`, `ebreak` or fault. It knows nothing about syscalls.                                                                        |
| `src/loader`    | `loader` | Validates and maps an ELF64 executable, sets up the stack, parses the `.nb_manifest` section.                                                                                                         |
| `src/host`      | `host`   | The page object: drives the VM, dispatches syscalls, owns the handle table and the view tree, and checks fetches against the manifest. No I/O; front ends plug in through callbacks (logging, fetch). |
| `src/field`     | `field`  | Text editing: caret, selection, word moves, undo. It works on bytes, and leaves wrapped lines to `nb`. Used by `nb` for the address bar, the find bar, page Inputs and Text_Areas.                    |
| `src/layout`    | `layout` | Turns the view tree into positioned boxes. Text measurement is pluggable, so it is tested without graphics.                                                                                           |
| `src/cmd/nb`    | `main`   | The browser window: SDL3 for windowing, input and drawing, SDL3_ttf (FreeType and HarfBuzz) for text.                                                                                                 |
| `src/cmd/nbrun` | `main`   | Headless runner for development and tests.                                                                                                                                                            |
| `src/proto`     | `proto`  | NB/1: framing, Noise sessions, messages, bundles, `nb://` URLs, key pinning.                                                                                                                          |
| `src/server`    | `server` | Serves bundles from a directory, one thread per connection. Used by `nbd` and the tests.                                                                                                              |
| `src/cmd/nbd`   | `main`   | The page server.                                                                                                                                                                                      |
| `sdk/nb`        | `nb`     | What page authors import: syscall wrappers, a heap over `Mem_Grow`, the entry point, the linker script.                                                                                               |
| `examples/`     |          | Example pages.                                                                                                                                                                                        |
| `tests/`        |          | Assembly fixtures (`tests/asm`) and Odin test packages.                                                                                                                                               |

## Execution model

- **One page, one VM, one thread.** The host calls `page_run(page, budget)`
  to run up to `budget` instructions. Syscalls are handled inline. The call
  returns early when the page exits, faults, or blocks in `Wait_Event`.
- **Event driven.** After building its first view, a page loops on
  `Wait_Event`. While blocked it costs no CPU. The front end delivers input,
  timer and fetch events with `page_push_event`.
- **Budgets, not trust.** A page that never yields is stopped by the front
  end once it exceeds its instruction budget, so a runaway page cannot freeze
  the browser.
- **Deterministic.** Given the same events, a page executes identically on
  every host: NaN results are canonical, `rdcycle` counts instructions rather
  than time, and the only clock is the coarse `Time_Now`. This leaves room
  for record/replay debugging later.

## Guest memory

```
0x0000_0000 ┬─────────────────────────┐
            │ null guard (64 KiB)     │ unmapped: null dereferences fault
0x0001_0000 ├─────────────────────────┤
            │ .text                   │ R X
            ├─────────────────────────┤
            │ .rodata                 │ R
            ├─────────────────────────┤
            │ .data / .bss            │ R W
       brk  ├─────────────────────────┤
            │ heap (Mem_Grow)         │ R W, grows up
heap_limit  ├─────────────────────────┤
            │ guard page              │ unmapped: stack overflow faults
  stack_lo  ├─────────────────────────┤
            │ stack                   │ R W, sp starts at the top
  mem_size  └─────────────────────────┘ default 64 MiB, max 1 GiB
```

Permissions are tracked per 4 KiB page and checked on every access, including
host access to syscall buffers. No page is ever both writable and executable.

## Capabilities

Pages never see host pointers. Everything the browser gives a page is an
opaque `u32` handle: a table index plus a generation counter. A closed handle
stays invalid even after its slot is reused, so use-after-close shows up as
`-BADH` instead of touching another object.

What a page may do beyond its own sandbox (network origins, storage quota) is
declared in its manifest and enforced by the host. See
[syscalls.md](syscalls.md#manifest).

## The view tree

Pages describe _what_ to show, not _how_: a tree of semantic nodes (box,
heading, paragraph, link, button, input, image, canvas, list…) with
attributes. The browser does layout and rendering. Because the tree is
semantic, accessibility, find-in-page, text selection and copy, zoom, reader
mode and user font and colour overrides work on every page without the page's
cooperation. A `Canvas` node will give pages raw drawing where they need it.

## Layout and rendering

`src/layout` is deliberately small:

- Every node is a block. A block stacks its children in a column (the
  default) or flows them in a row (`Direction=row`) that wraps when the next
  child does not fit. Items on a row line are centred vertically.
- In a column, children fill the available width. In a row, they shrink to
  their content.
- A node's own text is wrapped to its inner width and placed before its
  children.
- Browser defaults per kind set the look: heading sizes, link colour and
  underline, button and input boxes, list indentation and bullets. An Input
  is one line tall; a Text_Area is four lines (or `Height`) and its text
  wraps and scrolls inside the box rather than making it taller. The `Gap`,
  `Padding`, `Width`, `Height`, `Font_Size`, `Color` and `Background`
  attributes adjust them.
- **Inline formatting.** A Paragraph, Heading or List_Item whose children are
  all inline (Text, Link, Emphasis, Strong, Code) is laid out by
  `src/layout/inline.odin`:
  1. Its runs are split into words and spaces, each measured in its own font.
  2. Lines are broken greedily at spaces, across style changes.
  3. The result is a list of _fragments_: one node's text, on one line, in
     one style.

  Rendering, hit-testing, selection and find all work per fragment. A link
  that wraps is therefore still one clickable link, and copying a paragraph
  gives back its exact text. SDL_ttf can only use one font per text object,
  so the line breaking is done here rather than by SDL_ttf.

`nb` keeps the layout until `Page.tree_version` changes or the window width
changes. It only repaints when something changed, including canvas pixels
(`Page.paint_version`), or when the caret of the focused field blinks; typing
or clicking restarts the blink with the caret on. It renders in physical pixels, so text stays sharp on
high-DPI screens. It runs the page for at most 8 ms between frames and stops
a page that runs 5 s without waiting for an event.

Local links (`Href="canvas.elf"`) load the page beside the current one.
`nb://` links are fetched over the network.

`nb --screenshot out.png` with `SDL_VIDEO_DRIVER=offscreen` renders a page
without a display, after optional `--click X,Y` and `--type TEXT` steps. This
is how the window is checked from scripts.

## Building a page

Pages are ordinary Odin programs:

```odin
package main

import nb "../../sdk/nb"   // or a -collection

main :: proc() {
    root := nb.el(.Box)
    nb.el(.Heading, root, "Hello")
    nb.set_root(root)
    for {
        ev, ok := nb.wait_event()
        if ok && ev.kind == .Quit { return }
    }
}

@(export, link_name="_start")
_start :: proc "c" () -> ! { nb.start(main) }
```

`./build.sh page examples/hello` runs four steps:

1. `odin build <dir> -target:freestanding_riscv64 -build-mode:obj -use-single-module -no-thread-local -reloc-mode:static`
2. assemble `sdk/nb/rt.S` (the `ecall` stub plus `memset`, `memcpy`, `memmove` and `memcmp`)
3. `ld.lld -static -T sdk/nb/page.ld page.o rt.o -o page.elf`
4. `llvm-objcopy --add-section .nb_manifest=manifest.txt page.elf`, if the page directory has a `manifest.txt`

Why each piece exists (all found while setting this up):

- Odin cannot link freestanding riscv64 executables itself, so we link with `ld.lld`.
- Odin refuses `intrinsics.syscall` on freestanding targets and has no riscv64 inline assembly, hence the assembly stub.
- `intrinsics.__entry_point` only works in exe build mode, hence the explicit `_start` that calls `nb.start(main)`.
- `-no-thread-local` avoids `__tls_get_addr`.
- `-reloc-mode:static` yields a plain `ET_EXEC` with no relocations to process.

Any language that compiles to RV64GC can target the same ABI. `tests/asm`
contains pages written directly in assembly.

## Roadmap

1. **VM and headless runner** (done). The interpreter, loader, syscalls, SDK,
   `nbrun`, tests and these docs.
2. **Window** (done). The `nb` browser: layout, SDL3_ttf text, links between
   local pages, buttons, inputs edited by the browser, canvas, scrolling,
   reload and back.
3. **Network** (done). `nbd` serves signed, content-addressed bundles over
   Noise on port 4040. `nb` fetches `nb://` addresses on a background thread,
   pins server keys on first use, and revalidates its cache by hash. See
   [protocol.md](protocol.md).
4. **Browser chrome** (done):
   - **Tabs.** Each tab has its own page, history, layout and caches.
     Background tabs keep running on a smaller time slice, so their timers
     and animations continue.
   - **An address bar** with Back and Reload. Bare `host/path` addresses mean
     nb://.
   - **A clipboard** for the address bar and page inputs.
   - **Text fields.** The address bar, the find bar and page Inputs share
     `src/field`: a caret, a selection, moves by character (keeping
     combining marks with their letter) and by word, and undo that groups a
     run of typing into one step. It has no graphics, so it is unit tested;
     `nb` adds drawing, mouse selection and sideways scrolling. Pages read
     and place an Input's selection with `Input_Get_Selection` and
     `Input_Set_Selection`, get a `Select` event when the user moves it, and
     focus an Input with `Input_Focus`. A Text_Area is the multi-line kind:
     `nb` wraps its text, moves the caret by line with Up and Down, scrolls
     it inside the box, and inserts a newline on Enter (Ctrl+Enter goes to
     the page).
   - **Text selection and find in page.** These work on every page with no
     page code, because the browser knows the text of every node:
     - Drag to select across nodes, double-click selects a word,
       triple-click a paragraph, Ctrl+A selects everything, and Ctrl+C
       copies.
     - Shift+click and Shift with the arrows, Home or End extend a selection,
       including from an empty one left by a plain click. Up and Down keep
       their column across short lines and skip the gaps between blocks.
     - Ctrl+F matches case-insensitively and scrolls each match into view.
     - Positions are kept as (node handle, byte offset), so they survive
       re-layout.
     - Character positions and range rectangles come from SDL_ttf, so they
       follow the real shaped text.
   - **Per-site storage** with quotas from the manifest, keyed by the
     server's verified key.
5. **Pages fetch data** (done). `Fetch_Open` and `Fetch_Read` reach only the
   servers named in the manifest's `fetch` lines. `fetch /` means the page's
   own server, held to the key the page was loaded from.
   - **Who does what.** `host` resolves each request and checks it against the
     manifest, then hands it to the front end through `Page.fetch_proc`. `nb`
     runs the request on a thread and delivers the answer with
     `page_fetch_complete`, which raises a `Fetch` event.
   - **Late answers.** Each loaded page has a serial number, so an answer
     that arrives after the user navigated away or closed the tab is dropped.
   - **On the server,** the new NB/1 `read` op serves files as they are. See
     [syscalls.md](syscalls.md#fetch-0x300).

Later ideas:

- inline images; bidirectional text and line breaking per the Unicode algorithm (kb_text_shape provides both)
- a history and bookmarks view
- a visible, keyboard-driven caret on pages (caret browsing, F7)
- an accessibility bridge: the semantic tree maps directly onto platform accessibility APIs
- a pre-decoded instruction cache (W^X makes it safe)
- a GDB remote stub hooked to `ebreak`
- record and replay
- hybrid post-quantum handshakes with ML-KEM
- bundle assets, and connection reuse for fetches
- sending data, not just reading it: a request body, for servers that do more than serve files
