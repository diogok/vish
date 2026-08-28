# Progress — WebSocket review fixes

## Session 3 — T2: handshake validation and rejection framing (S2)

Landed F2/F3/F4/F10. `upgrade()` now checks `upgrade.len == 0 →
NotWebSocket` first (a non-GET without an Upgrade header routes through
instead of 400ing), rejects body-bearing handshakes (`content_length >
0` or `transfer_encoding` set → 400), and `reject()` forces
`Connection: close` so the body-less 400 frames itself and the loop
closes the connection immediately. Five new `upgrade()` unit tests
(bad key, missing Connection, body-bearing GET, chunked GET, non-GET
without Upgrade) via an `UpgradeOutcome` helper; the rejected-400
integration test now uses a realistic request and asserts the close
header (F10).

Live probe (demo2 + /tmp/ws_t2_probe.py): rejected upgrade → 400 +
`Connection: close`, EOF 1.1 ms (was the 1.00 s idle window);
body-bearing GET → 400; `POST /ws` without Upgrade → 404; valid
handshake + echo unchanged. `zig build test` 111/111, `zig build`
green.

The Zig 0.16 error-value pitfalls hit along the way (cross-error-set
equality, `try anyerror`, `switch |payload|`) are recorded in
notes.md — the enum-flattening pattern in the helper is the fix.

Next: T3 (close-handshake strictness, S3).

## Session 2 — T1: fragment reassembly (S1)

Landed the F1 fix: `next()` now zeroes `frag_len` after a complete
fragmented message (buffer kept — the returned slice points into it),
and `appendFrag` starts fresh on `frag_len == 0` using `realloc`
(reusing retained capacity; plain allocators would leak it on a fresh
`alloc`). Two regression tests: two consecutive fragmented messages
(pre-fix "HelloWorld") and fragment/single/fragment interleaving.
`zig build test` 106/106.

Next: T2 (handshake validation, S2).


## Session 1 — planning (no code)

Reviewed the `websocket` branch (commit `bde8dc4`) against RFC 6455:
read all changed files, verified `std.Io.Reader.take/readAlloc`
semantics against this toolchain's stdlib source, ran `zig build test`
+ `zig build` (green), probed a live demo2 with a raw-socket WS
client, and reproduced the fragment-reassembly corruption with a
targeted test ("HelloWorld").

Findings F1–F10 are in `plan.md`; evidence and recipes in `notes.md`.
Wrote the plan: six work items (S1–S6) as six task cards (T1–T6), all
code changes confined to `src/http/websocket.zig` + tests + two doc
updates. Supersedes two accepted risks from `plans/websocket/plan.md`
(no max size, no subprotocols — both now in scope).

Next: T1 (fragment reassembly). Opening prompt is in `plan.md`.
