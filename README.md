# Nota Bene

Nota Bene is an experimental implementation of a web browser with a completely new approach to web pages.

We don't do HTML, CSS, nor JS. Just small, fast and compiled pages.

- **Pages are RISC-V programs.** The VM runs standard RV64GC code, so pages can be written in Odin (with the SDK in `sdk/nb`) or in any language with an RV64 compiler.
- **Syscalls follow the Linux convention.** A page calls the browser with `ecall`, putting the number in `a7` and the arguments in `a0`–`a5`. Everything the browser hands out is an opaque capability handle; the page never sees a host pointer.
- **Pages describe meaning, the browser draws.** A page builds a semantic tree of headings, paragraphs (with links, emphasis and code inline), inputs and so on, plus a canvas node for custom drawing. The browser handles layout. Because the browser knows what everything on the page is, text selection, copying and find-in-page already work on every page with no page code. Accessibility and user font settings can follow the same way.
- **Every connection is encrypted** with the Noise protocol from Odin's standard library. Server keys are pinned on first use, like ssh, so there are no certificate authorities and no OpenSSL.

Done so far:

1. the VM and its syscall layer
2. the windowed browser `nb`
3. the network layer: `nbd` serves pages over Noise, and `nb` opens `nb://` addresses
4. browser chrome: tabs, an address bar, text selection, find in page, a clipboard, and private per-site storage with quotas (see the Notes and About examples)
5. pages fetch data, but only from the servers their manifest names (see the Feed example)
6. images: PNG and JPEG, as blocks or inline in text (see the Images example)

## Documentation

- [Architecture](docs/architecture.md): components, execution model, memory layout, how pages are built, roadmap
- [Instruction set](docs/isa.md): why RISC-V, what is implemented, how faults work
- [Syscall ABI](docs/syscalls.md): every syscall, error code, event and limit, plus the page manifest
- [Network protocol](docs/protocol.md): Noise handshakes, framing, page bundles, key pinning

## Building

Requirements:

- [Odin](https://odin-lang.org) (tested with `dev-2026-10`)
- `clang` with the riscv64 target
- `ld.lld`
- `llvm-objcopy`
- SDL3 and SDL3_ttf, for the `nb` browser. Without the `SDL3_ttf-devel` package, `build.sh` links against the runtime library directly.

```sh
./build.sh          # build/nb, build/nbrun and the example pages
./build.sh test     # build everything and run the test suites
./build.sh page DIR # build an Odin page from DIR
```

Open a page in the browser:

```sh
./build/nb build/hello.elf
```

Serve pages over the network and browse them:

```sh
./build/nbd build/site            # prints the server key; creates nbd.key on first run
./build/nb nb://localhost/        # in another terminal
./build/nb nb://localhost/feed    # a page that fetches build/site/feed.txt
```

On the first visit, `nb` pins the server's key in `~/.config/new-browser/known_hosts`. Site storage also lives in that directory; use `--profile DIR` to point `nb` somewhere else. Later visits fail loudly if the server cannot prove it holds that key. `nbd --sign publisher.key` also signs every page, and `nb` shows who signed it in the status bar.

Keys:

- Ctrl+L or F6: address bar (type `nb://…`, a file path, or just `host/path`)
- Ctrl+T: new tab. Ctrl+W: close the tab. Ctrl+Tab and Ctrl+Shift+Tab: next and previous tab. Ctrl+1…9: go to a tab
- Ctrl+click or middle-click a link: open it in a background tab
- Drag to select page text, double-click to select a word, triple-click for a paragraph, Ctrl+A to select everything, then Ctrl+C to copy. Shift+click, and Shift with the arrows, Home or End, extend the selection
- F7: caret browsing. A caret in the page text moves with the arrows (by word with Ctrl), Home and End (the whole page with Ctrl), Page Up and Page Down; Shift selects as it goes, and Enter follows the link the caret is in
- Ctrl+F: find in page. Enter or F3: next match. Shift+Enter or Shift+F3: previous match. Esc: close
- In the address bar, the find bar and page inputs: the arrows, Home and End move the caret (by word with Ctrl, selecting with Shift), the mouse places it and selects, Ctrl+C, Ctrl+X, Ctrl+V copy, cut and paste, and Ctrl+Z, Ctrl+Y (or Ctrl+Shift+Z) undo and redo
- F5 or Ctrl+R: reload
- Alt+Left: back
- Tab: next input
- F12: print the view tree

Run a page headlessly:

```sh
$ ./build/nbrun build/hello.elf --dump-tree
[page] hello from a page
[page] goodbye
box direction="column" gap="12"
  heading level="1" "Hello, new web"
  ...
```

`nbrun --help` lists the options: an instruction budget, memory size, syscall and instruction tracing, and a tree dump.

## Technology Stack

- Odin Programming Language
- Custom virtual machine: a user-mode RV64GC interpreter
- SDL3 and SDL3_ttf (FreeType and HarfBuzz) for windowing and text
- `core:crypto/noise` (Noise NX/NK, X25519, ChaCha20-Poly1305, BLAKE2b) for transport encryption, and ed25519 for page signatures

## Supported Platforms

- Linux
- Windows (no OS available to test with)
- macOS (no hardware available to test with)

## Default Configuration

Port: 4040
