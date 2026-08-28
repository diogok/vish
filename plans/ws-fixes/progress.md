# Progress — WebSocket review fixes

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
