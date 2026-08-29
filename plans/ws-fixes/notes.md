# Notes — ws-fixes (verified facts)

Recon done in the review session (before any fix). Facts below were
observed or checked against the stdlib source in this toolchain; do not
re-derive them.

## Environment recipes

- Build/test: `zig build test` (library), `zig build` (adds the demos).
  Toolchain: custom Zig 0.16.0 at `/home/diogo/workspace/zig`; stdlib
  source at `/home/diogo/workspace/zig/lib/std` (built-in docs match).
- Live probe: `./zig-out/bin/demo2` binds `127.0.0.1:8080`. Start it as
  a background task (`background: true`), never `&` — a demo started
  with `&` in a bash call dies with the shell. Probe scripts live in
  `/tmp/ws_probe.py` (handshake/echo/ping/close + the new-behavior
  checks) and `/tmp/reject_probe2.py` (timing of a rejected handshake).
  No Python ws libraries are installed; raw sockets only.

## Verified facts — stdlib (this toolchain)

- `std.Io.Reader.take(n)` = `peek(n)` + `toss(n)`; `peek` fills until
  exactly n bytes are buffered or `error.EndOfStream`
  (`lib/std/Io/Reader.zig:510, 558`). Never returns a short slice.
- `std.Io.Reader.readAlloc(r, allocator, len)` allocates `len` bytes
  FIRST, then `readSliceAll` reads exactly len
  (`lib/std/Io/Reader.zig:739-744`). This is why F5's cap must be
  enforced before the call: the allocation is the exposure.
- `Allocator.realloc` is two-argument in this stdlib (no allocator
  error on the old pointer). Arena realloc = fresh allocation + copy;
  the old block is NOT freed (arena), which is why the F1 reproducer
  shows the previous message's *content* ("Hello") as the stale prefix
  rather than garbage.
- `std.Io.Writer.failing` exists and is used by the existing
  failed-latch test (websocket.zig:844-856).
- Gotchas from `plans/websocket/progress.md` that still hold:
  `std.mem.readInt/writeInt` take array pointers not slices;
  `std.base64.standard` codec shape; test `DebugAllocator` validates
  frees against slice length (allocate exact wire sizes in helpers);
  stream reader/writer APIs reached via `.interface`.

## Verified facts — post-review fixes (2026-08-29)

- A slice from `Reader.take` does NOT survive a following payload read:
  `readSliceShort` → `readVec` → `writableVector`
  (`lib/std/Io/Reader.zig:2044-2058`) sets `seek = end = 0` and hands
  the whole buffer to `recv` as spillover once the buffered bytes are
  consumed, so the next frame's bytes land at `buffer[0..]` — right
  where the mask slice pointed. Reproduced over TCP: a 10000-byte frame
  followed by a second frame in the same write echoed garbage from
  byte 0. Fix: copy the mask (`takeArray(4).*`); regression test
  "payload spanning a read-buffer refill".
- Arena `realloc` only grows in place when the block is the arena's
  most recent allocation; a `readAlloc` between two `appendFrag`
  reallocs defeated that, making fragment reassembly quadratic in
  arena memory (1 MiB in 1 KiB fragments ≈ 512 MiB). Data payloads now
  read straight into one session `buf` (doubling growth); control
  payloads into a fixed `control_buf`. Nothing per-frame goes to the
  arena any more — the buffer-reuse unit test runs on
  `testing.allocator` so the leak check enforces it.
- `Connection` is a token list: Firefox's handshake sends
  `keep-alive, Upgrade`. `Connection.parse` now tokenizes; `upgrade()`
  sets `res.headers.connection = .upgrade` itself.
- Threaded Io reports a peer FIN from `receiveManyTimeout` as a
  successful receive with `data.len == 0` (`Threaded.zig:12913-12928`),
  not an error — the linger drain in `Loop.lingerClose` stops on that.
  `Io.Timeout` has a `.deadline` variant (`Timeout.toDeadline(io)`), so
  the drain is bounded as a whole, not per receive.
- Closing a socket with unread input makes Linux send RST and drop
  unsent output. The loop now returns `.linger` for an upgraded
  connection: `shutdown(.send)` (the server initiates the TCP close, per
  RFC 6455 §7.1.1) and a drain until the peer's FIN or
  `ListenOptions.upgrade_linger_in_millis` (default 1 s).
- `Request` now carries `stream` and `io` (null outside a live
  connection); `WebSocket.idle_timeout_in_millis` uses them through the
  shared `socket.waitReadable` (the loop's keep-alive reaper uses the
  same helper). Only the gap between frames is timed.
- RFC 6455 close semantics as now implemented: after *our* Close the
  peer's in-flight data/pings are discarded (§1.4) until its Close
  arrives; after the *peer's* Close any further frame is 1002 (§5.5.1);
  a protocol failure is sticky — `next()` never reads again (§7.1.7).

## Verified facts — current code (before fixes)

- `Response.fromRequest` (response.zig:157-169) copies the request's
  `Connection` header into the response. This is why a rejected
  handshake (request said `Connection: Upgrade`) replies with
  `Connection: Upgrade` on the 400 (F2).
- `onRequest` keep-alive decision (loop.zig:216-222) returns `.close`
  only when either side is `.close`; `.upgrade`/`.upgrade` → `.keep`.
  So a 400 with no `Content-Length` stays open until the idle reaper.
- `Response.sendHeaders` (response.zig:257-293) writes `Content-Length`
  only when the body is non-empty or the field was set; the 400/101
  bodies are empty, so neither carries a Content-Length. The 101 is
  fine (no body is expected); the 400 is not (F2).
- `WebSocket.upgrade()` check order after S2 (websocket.zig:89-179):
  `upgrade.len` (NotWebSocket) → upgrade value + connection → method →
  version → key → body-less. `reject()` forces `Connection: close`.
- `upgrade()` now has direct unit tests (the `UpgradeOutcome` helper +
  5 tests, websocket.zig ~512-615) alongside the live-loop integration
  tests; the rejected-handshake integration test uses a realistic
  request (good `Connection: Upgrade`, bad key) per F10.
- `Headers.free` (request.zig:204-218) frees **every** `[]const u8`
  field, including comptime string literals. A hand-constructed
  `Request` in a unit test must therefore never call `req.deinit()`
  (see Test pitfalls).

## Verified facts — RFC 6455 (as applied here)

- §4.1: handshake is a GET; the request carries `Upgrade`,
  `Connection` (token `Upgrade`), `Sec-WebSocket-Key` (16 random bytes
  base64), `Sec-WebSocket-Version: 13`, optional
  `Sec-WebSocket-Protocol` (comma-separated list). The handshake
  request is body-less — no `Content-Length` / `Transfer-Encoding`
  (basis for F3's reject).
- §4.1 subprotocol: "If the header field is present in the client's
  request, the server MUST include a header field with the name
  'Sec-WebSocket-Protocol' in its response. The value of this field is
  determined by the server from among the subprotocols listed by the
  client ... If the server cannot determine an acceptable subprotocol,
  it MUST fail the connection." Clients that requested subprotocols and
  received none treat the handshake as failed (browsers fire `onerror`;
  Node `ws` errors) — basis for F6.
- §5.1: client frames MUST be masked; the server MUST close on an
  unmasked frame (already enforced).
- §7.4: status codes 1005/1006 are local-only and MUST NOT appear in a
  frame; values 0–999 are not assigned and MUST NOT be used as status
  codes (basis for F8 — today's `code != 0` carve-out lets a 2-byte
  `0x0000` payload through).
- §5.5.1 / close semantics: an endpoint that received Close and
  responded MUST NOT send further frames — a second Close from the
  peer is a protocol violation (basis for F7).
- §1.3 vector (the integration test's): key
  `dGhlIHNhbXBsZSBub25jZQ==` → accept `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`.

## Measured behavior (demo2 + raw-socket probes, pre-fix)

- Basic flow OK: 101 with correct accept; text/binary echo; ping→pong;
  close echo (1000) then clean TCP close.
- F2: rejected handshake (bad key, request `Connection: Upgrade`) →
  400 with `Connection: Upgrade`, no Content-Length; the client's
  follow-up read sat **exactly 1.00 s** (the idle reaper at the
  default 1000 ms) before EOF. With the idle timeout disabled this
  hangs indefinitely.
- F3: `GET /ws` + `Content-Length: 5` + 5 body bytes + valid upgrade
  headers → 101 sent; the client's first real frame then triggered a
  1002 close (leftover body bytes desynced the frame stream).
- F4: `POST /ws` *with* upgrade headers → 400 today (and stays 400
  after the fix); `GET /ws` *without* upgrade headers → 404 (routes
  through in demo2). The trap is a non-GET with no Upgrade header
  reaching an `upgrade()` call without a path pre-check.
- F6: handshake with `Sec-WebSocket-Protocol: chat, superchat` → 101
  carries no `Sec-WebSocket-Protocol` (PROTOCOL_ECHOED = False).
- Demo log during probes: `warning(demo): error reading body:
  EndOfStream` from the **pre-existing** `POST /hello` formdata path
  (demo2.zig:132) — not part of this branch's work, out of scope.

## Measured behavior (post-S2 fix, probe /tmp/ws_t2_probe.py)

- Rejected handshake (bad key, `Connection: Upgrade` request) → 400 with
  `Connection: close`, EOF **1.1 ms** after the response (was the full
  1.00 s idle window). No body is sent on the 400 — the close frames it.
- Body-bearing GET (`Content-Length: 5` + 5 bytes) → 400 + close.
- `POST /ws` without Upgrade header → 404 (routing continues; the demo's
  `WsEchoHandler` maps NotWebSocket → Skipped).
- Valid upgrade unchanged: 101 + correct accept; "hi" echo arrives as a
  4-byte wire frame (0x81 0x02 'h' 'i') — probes must wait for 4 bytes,
  not 6.

## F1 reproducer (the data-corruption test)

Two masked fragmented text messages back to back — "Hel"+"lo" then
"Wor"+"ld" — fed to one `WebSocket` over a fixed reader. Pre-fix
result:

```
msg1 = Hello
msg2 = HelloWorld (len 10)     ← expected "World"
```

Root cause chain: `next()`'s final-fragment branch (websocket.zig:
246-256) leaves `frag_len` > 0 and the buffer filled after returning a
reassembled message; `appendFrag` (385-396) only starts fresh when
`self.frag.len == 0`, so the next sequence reallocs to
`frag_len + chunk.len` and copies the new chunk **after** the stale
payload; `next()` then returns `self.frag[0..frag_len]` including the
stale prefix.

## Zig 0.16 error-value pitfalls (learned in T2)

- **Error values do not compare across error sets.** `error.NotWebSocket`
  written in a test body is a member of the *test's* error set; the value
  returned by `upgrade()` carries a code from *upgrade's* set. Same name,
  different integer: `testing.expectEqual` fails with the baffling
  "expected error.NotWebSocket, found error.NotWebSocket". Never compare
  `anyerror` values across functions — flatten to a local enum in the
  helper (that's what `UpgradeOutcome` in the S2 tests does).
- **`try` on a bare `anyerror` is illegal**: "expected error union type,
  found 'anyerror'". A function returning `anyerror` cannot be `try`'d.
- **`switch` on an error union has no `|payload|` prong** in this build
  ("expected '}', found '|'"). The working shape:
  `const r = f(); return if (r) |_| { return .ok; } else |err| switch (err) {...};`
  (`|_|` wildcard capture is valid; a block arm must end in a statement,
  not a bare expression).
- A `switch` on an error set is exhaustive over its members: `upgrade()`'s
  set is exactly `{NotWebSocket, HandshakeRejected, UpgradeFailed}` (all
  other call-site errors are caught internally), so an `else` prong is an
  "unreachable else prong" compile error.
- A hand-built `Request` literal needs `.version` (request.zig:305) —
  there is no default.

## Test pitfalls (must not rediscover)

- Hand-constructed `Request` with comptime literal header strings:
  **never** call `req.deinit()` — `Headers.free` frees the literals
  and the debug allocator panics ("Invalid free"). Nothing in
  `upgrade()` allocates through the request's allocator, so dropping
  the struct is safe.
- Same-file unit tests may set WebSocket's private fields (e.g.
  `max_payload` for the S4 tests) — tests live in `websocket.zig`
  itself.
- The `frame()` test helper allocates exact wire sizes (debug
  allocator validates frees against the returned slice length).
- Integration tests over real TCP take ~1 s each while a connection
  waits out the idle window — the S2 updated test must NOT rely on
  that: after the fix the 400 carries `Connection: close`, so
  `allocRemaining` returns immediately; assert the header, not the
  timing.
