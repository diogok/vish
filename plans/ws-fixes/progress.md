# Progress — WebSocket review fixes

## Session 3 — T2 (S2) + T3 (S3) + T4 (S4)

Landed F2/F3/F4/F10 (T2, commit `c05d22f`), F7/F8/F9 (T3), and
F5 (T4, this commit).

T2: `upgrade()` now checks `upgrade.len == 0 → NotWebSocket` first (a
non-GET without an Upgrade header routes through instead of 400ing),
rejects body-bearing handshakes, and `reject()` forces
`Connection: close` so the body-less 400 frames itself and the
connection drops immediately. Five new `upgrade()` unit tests via an
`UpgradeOutcome` helper; the rejected-400 integration test now uses a
realistic request and asserts the close header (F10).

T3: new `close_surfaced` latch — a second Close frame from the peer is
now a protocol violation (1002), while a Close answering our own
`close()` still surfaces once. The close-code check rejects 0–999
including an explicit `0x0000` while the legal 0-byte "no status"
payload stays admissible (the `len >= 2` guard in the plan.md formula
is load-bearing). Failed automatic pong/close-echo writes return
`ReadFailed` instead of leaking the raw writer error (`writeFrame`
already latches `failed`). `next()` doc updated. Four new unit tests.

T4: private `max_payload` field (default `max_payload_default =
16 MiB`) enforced in `readFrame` before `readAlloc` sizes the buffer
and cumulatively in `appendFrag` across fragment sequences; both fail
with close 1009. `CloseCode.message_too_big` is no longer dead code.
architecture.md size-limit line rewritten. Three new unit tests
(over-cap frame, fragments summing over cap, exactly-at-cap accepted).

Live probe after T2 (demo2 + /tmp/ws_t2_probe.py): rejected upgrade →
400 + `Connection: close`, EOF 1.1 ms (was the 1.00 s idle window);
body-bearing GET → 400; `POST /ws` without Upgrade → 404; valid
handshake + echo unchanged. `zig build test` 118/118, `zig build`
green.

Mistakes to remember: the Zig 0.16 error-value pitfalls hit in T2
(cross-error-set equality, `try anyerror`, `switch |payload|`) are in
notes.md; the 1009 close-code bytes are `0x03 0xf1` — the plan card
said `0x03 0xe9` (that is 1001), corrected in plan.md.

Next: T5 (subprotocol negotiation, S5).

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
