# Network protocol (NB/1)

NB/1 is how the browser (`nb`) fetches pages from servers (`nbd`). The
implementation is in [`src/proto`](../src/proto) and
[`src/server`](../src/server). It is built entirely on Odin's standard
library (`core:crypto/noise`, `core:net`, `core:encoding/cbor`,
`core:crypto/ed25519`, `core:crypto/blake2b`), with no TLS or OpenSSL.

## Goals

- **Every connection is encrypted and authenticated.** There is no plaintext
  mode.
- **No certificate authorities.** A server's identity is a static Curve25519
  key, pinned on first use or given in advance in the address.
- **No ambient tracking.** There are no cookies, and the client presents no
  identity.

## Addresses

```text
nb://host[:port]/path
nb://<server-key>@host[:port]/path
```

- **Default port:** 4040. Port 404, the project's original choice, works with
  `nbd --port 404`, but it is a privileged port: on Linux run
  `sudo setcap cap_net_bind_service=+ep ./nbd` first.
- **Server key:** 52 characters of lowercase base32 (RFC 4648 alphabet, no
  padding). `nbd` prints its key and a ready-made address at startup.
- **IPv6** literals go in brackets: `nb://[::1]:4040/`.
- **Relative links** on an nb:// page resolve against its URL. `.` and `..`
  are folded and can never climb above `/`.

## Transport

TCP. Each message is framed as a 2-byte big-endian length followed by that
many bytes, from 1 to 65535. Both sides time out stalled reads and writes
after 15 s.

## Handshake

The client picks one of two Noise patterns:

| Situation | Pattern | |
| --- | --- | --- |
| No key known for the server | `Noise_NX_25519_ChaChaPoly_BLAKE2b` | The client is anonymous. The server sends its static key encrypted, and the browser pins it in `known_hosts` (trust on first use, like ssh). |
| Key known (from `known_hosts` or the address) | `Noise_NK_25519_ChaChaPoly_BLAKE2b` | The server is authenticated from the first message. If it does not hold the key, it cannot complete the handshake. |

How the two sides agree on the pattern:

1. **Mode byte.** The first handshake frame starts with a mode byte, `X` for
   NX or `K` for NK, followed by the Noise message.
2. **Prologue.** The prologue is `NB/1` followed by the mode byte. Changing
   either in transit makes the handshake fail.
3. **Server.** The server accepts both patterns, using its static key.
4. **Split.** After the second message both sides split into transport keys.
   Each later frame carries exactly one Noise ciphertext: up to 65519 bytes of
   plaintext plus a 16-byte tag.
5. **Rekeying.** Each direction rekeys after every 2^20 messages.

If a pinned key no longer matches, the browser refuses the page and explains
how to un-pin the key if the change was expected. It cannot tell a
legitimately rotated key from an interception attempt.

## Messages

Requests and response heads are CBOR maps:

```text
request       = { "id": uint, "op": "get" / "read", "path": tstr, "have": bstr }
response_head = { "id": uint, "status": uint, "size": uint, "message": tstr }
```

- **`op`**: `get` asks for a page and the body is its bundle. `read`
  asks for a file as it is, which is how pages fetch data (see
  [syscalls.md](syscalls.md#fetch-0x300)).
- **`have`** is the hash of a bundle the client already has cached, or empty.
  `read` ignores it.
- **The body** follows a `200` head as raw messages, `size` bytes in total
  (at most 64 MiB).
- **Several requests** may be sent one after another on one connection. The
  browser currently opens one connection per page.

| Status | Meaning |
| --- | --- |
| 200 | the body is the page bundle |
| 304 | `have` matches the current bundle: use the cached copy |
| 400 | unknown `op` |
| 404 | no page at this path, or the path is invalid |
| 500 | the server could not read the page |

How `nbd` maps paths to files:

- `/` serves `index.elf`, and so does a path naming a directory.
- `/name` serves `name` or `name.elf`.
- `read` takes the path literally: `/feed.txt` serves `feed.txt`, and
  directories are not found.
- Path segments may only contain `A–Z a–z 0–9 . _ - ~`. Requests with `.` or
  `..` segments, or empty segments, are rejected, so a request can never
  leave the served directory.
- `nbd`'s own key files (`--key`, `--sign`) are never served, by either op,
  even when they sit in the served directory (both default to the current
  directory, which is also the default root).

## Page bundles

```text
bundle = {
  "code":      bstr,               ; the page ELF; its manifest is the .nb_manifest section
  "assets":    { * tstr => bstr },  ; reserved for page resources (empty for now)
  "hash":      bstr,               ; BLAKE2b-256 of the deterministic CBOR of { "code", "assets" }
  "publisher": bstr,               ; ed25519 public key, or empty
  "sig":       bstr,               ; ed25519 over "NB/1 bundle\0" || hash, or empty
}
```

The browser rejects any bundle whose hash does not match its content, and any
signed bundle whose signature does not verify. The **transport key** proves
which server you are talking to. The **publisher key**, used with
`nbd --sign`, proves who produced the page, so mirrors and caches can serve
it. The status bar shows the publisher's fingerprint ("signed by …").

**Caching:** the browser keeps each fetched bundle for the session. Reload
and back send its hash as `have`, so an unchanged page costs only a 304.

## Files

| File | Holds |
| --- | --- |
| `nbd.key` (`nbd --key`) | the server's X25519 private key, hex. Created on first run, mode 0600. |
| `--sign FILE` | the publisher's ed25519 private key, hex. Created on first use. |
| `~/.config/new-browser/known_hosts` | pinned server keys, one `host:port key` per line. `nb --profile DIR` moves the whole profile, and `$XDG_CONFIG_HOME` and `%APPDATA%` are honoured. |
| `~/.config/new-browser/storage/` | per-site storage (see [syscalls.md](syscalls.md#storage-0x400)) |

## Not yet implemented

- **Key publication in DNS:** looking up a server key from a DNS
  `TXT _nb.<host>` record.
- **Per-site client keys (`Noise_XK`):** passwordless logins that cannot be
  linked across sites.
- **Hybrid post-quantum handshakes:** `core:crypto/mlkem` provides ML-KEM-768,
  and one option is an `NKpsk2` variant keyed from an ML-KEM exchange. This
  needs a design review first.
- **Bundle assets:** files shipped inside the page's bundle, readable
  without another round trip.
- **Connection reuse:** every page load and every fetch opens its own
  connection and handshake.
- **Compression:** the standard library only decompresses;
  `vendor:compress/lz4` could fill the gap.
