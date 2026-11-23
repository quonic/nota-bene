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
  padding). `nbd` prints its key, a ready-made address and the DNS record
  that publishes the key (see [Keys in DNS](#keys-in-dns)) at startup.
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
| Key known (from the address, `known_hosts` or DNS) | `Noise_NK_25519_ChaChaPoly_BLAKE2b` | The server is authenticated from the first message. If it does not hold the key, it cannot complete the handshake. |

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

### Keys in DNS

A server can publish its key in a DNS TXT record, so that even the first
visit is authenticated:

```text
_nb.example.org.        TXT "v=nb1; key=<server-key>"   ; port 4040
_9000._nb.example.org.  TXT "v=nb1; key=<server-key>"   ; any other port
```

- **Format:** `;`-separated `name=value` fields. The first must be `v=nb1`.
  Exactly one `key` field names the key. Names are case-insensitive,
  whitespace around fields is ignored, and so are unknown fields. Records
  that do not follow this are skipped. Keep the value in one TXT string (it
  fits easily): Windows returns each string separately.
- **Ports:** each port has its own name, because two servers on one host have
  two keys. A record for the wrong server would make every visit fail.
- **Several records:** all their keys are accepted (the first 4). With one
  key the browser uses NK. With several it uses NX and checks the key the
  server proves before it sends anything.
- **Not looked up:** IP literals, `localhost`, names under `.localhost` and
  `.local` (mDNS), and single-label names such as `intranet`.

Which key the browser expects, in order:

1. a key in the address;
2. a key pinned in `known_hosts`;
3. keys published in DNS;
4. none: NX and trust on first use.

DNS is only asked when there is no key from 1 or 2, so a DNS record can never
override a pin. A key found in DNS is pinned after the first successful
visit, like a key learned on first use, and the status bar says that it
matched the DNS record. An existing pin is never replaced, not even by a
load that started before it was made.

- **Wrong key:** if the server cannot prove a key from DNS, the browser
  refuses the page. It does not fall back to NX, because that would let
  anyone who can block the real server downgrade the connection.
- **No record:** if DNS answers that there is no record (no TXT records, no
  valid `v=nb1` record, or no such name), the browser uses NX and trust on
  first use, and pins the key.
- **Failed lookup:** each name server gets the query in turn, twice over,
  with a 1 s wait for each reply (resolv.conf's `options timeout:` and
  `attempts:` change this, up to 5 s and 3 attempts). A timeout, SERVFAIL,
  REFUSED, a truncated reply or a malformed one moves on to the next. If no
  server answers usably, the browser loads the page with NX but does not pin
  the key, so the next visit asks DNS again. The status bar says so.
- **Caching:** a pool of connections keeps up to 256 answers for the
  session. Keys are kept for 10 minutes, "no record" for 60 s and a failure
  for 10 s. A record fixed after a refusal takes effect when its answer
  expires.

**Rotating a key:** a pin outranks DNS, so a new key in DNS only helps
visitors who have not pinned the old one. Publishing the new key beside the
old lets first-time visitors in while both are possible, but a returning
visitor whose browser pinned the old key gets the "key changed" error as
soon as the server switches. To recover, they remove the server's line from
`known_hosts`, and the next visit checks the new key against DNS. Operators
should announce the change, publish the new key before switching, and remove
the old record afterwards.

**Security:** the lookup is not authenticated, and the browser does not
validate DNSSEC, so a DNS key is only as trustworthy as the DNS answers you
get. It helps against an attacker who can intercept the connection to the
server but cannot forge or block your DNS traffic. An attacker who can do
both on your first visit still wins: forging "no such name" (or a record with
their key) gets their key pinned, as with plain trust on first use. Blocking
DNS alone does not get a key pinned, because a failed lookup pins nothing. A
key in the address is still the strong option.

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
- **Several requests** may be sent one after another on one connection, each
  with a new `id`. The browser keeps idle connections for 10 seconds (the
  server gives up on a silent connection after 15), at most 4 per server,
  and shares them between page loads and fetches. A connection is reused
  only for the same address and, when a key is pinned or published in DNS,
  only if it was authenticated with that key. If a reused connection turns out to be
  closed, the request is sent once more on a new one: both ops only read.
  A connection whose body was left unread (`.Too_Large`) is closed.

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
  "assets":    { * tstr => bstr },  ; files shipped with the page, by relative path
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

**Assets:** `nbd` puts every file under `name.assets/` into the bundle of
`name.elf` (`index.assets/` for `index.elf`), keyed by its path relative to
that directory, such as `img/logo.png`. Hidden files, names a request could
not use (see the path rules above) and excluded files are left out. One asset
may be at most 16 MiB, the whole bundle at most 64 MiB, and a page may have at
most 1024 assets. The hash covers them, so editing an asset changes the
bundle, and a client's `have` stops matching. Pages read them with a relative
fetch (see [syscalls.md](syscalls.md#fetch-0x300)).

**Caching:** the browser keeps each fetched bundle for the session. Reload
and back send its hash as `have`, so an unchanged page costs only a 304.

## Files

| File | Holds |
| --- | --- |
| `nbd.key` (`nbd --key`) | the server's X25519 private key, hex. Created on first run, mode 0600. |
| `--sign FILE` | the publisher's ed25519 private key, hex. Created on first use. |
| `~/.config/new-browser/known_hosts` | pinned server keys, one `host:port key` per line. `nb --profile DIR` moves the whole profile, and `$XDG_CONFIG_HOME` and `%APPDATA%` are honoured. |
| `~/.config/new-browser/storage/` | per-site storage (see [syscalls.md](syscalls.md#storage-0x400)) |
| `~/.config/new-browser/history` | pages the user loaded, one `time<TAB>address<TAB>title` line each (Unix seconds), oldest first. At most 1000. |
| `~/.config/new-browser/bookmarks` | bookmarks, in the same form as `history` |

## Not yet implemented

- **Per-site client keys (`Noise_XK`):** passwordless logins that cannot be
  linked across sites.
- **Hybrid post-quantum handshakes:** `core:crypto/mlkem` provides ML-KEM-768,
  and one option is an `NKpsk2` variant keyed from an ML-KEM exchange. This
  needs a design review first.
- **Compression:** the standard library only decompresses;
  `vendor:compress/lz4` could fill the gap.
