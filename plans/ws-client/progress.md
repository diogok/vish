# Progress — WebSocket client

## Session 1 — plan, V1 (2026-09-02)

V1 landed: `io` is a required session field (the loop always sets
`Request.io`; a hand-built request without one gets
`error.UpgradeFailed`), `write_mutex: std.Io.Mutex` is held across
every frame write including the pongs, Close echoes and failure
Closes that `next()` issues, and the `closed` / `failed` checks that
gate a write moved under the same hold (`sendCloseOnce` replaces
`sendClosePayload`; `close()`, `failProtocol` and the idle deadline
all go through it, so racing closers produce one frame). New test:
the raw client sends 200 pings while a `Group.concurrent` task on
the server sends 1 000 binary frames; every frame and every pong
arrive intact and in order. `zig build test` 143/143 (142 before),
`zig build` green, `zig fmt --check src` clean. architecture.md and
usage.md carry the concurrency contract.

Next: V2 (codec split, client, tests migrated, `ws-echo` probe).
