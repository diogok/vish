# Notes — WebSocket client

## Session internals worth not rediscovering

- `readFrame` copies the mask key out of the reader before the
  payload read: `take` slices are invalidated by the next refill.
- `buf` is one receive buffer grown geometrically up to
  `max_payload`; `frag_len` is the open fragment sequence's length.
  `next()` returns slices into it, valid until the next `next()`.
- `closed` is set by our own Close (sent) or the peer's (echoed);
  `close_seen` marks the peer's Close consumed; `violated` is the
  sticky protocol failure; `failed` is the sticky transport failure.
- Test sessions are built with `std.Io.Reader.fixed` /
  `std.Io.Writer.fixed`, `testing.io`, and no `stream` (the idle
  deadline needs one).

## Zig 0.16 pitfalls hit

- `defer` inside a loop body block runs on `continue` and `return`
  alike: a `{ lock; defer unlock; ... continue; }` block is safe.
- `std.Io.Group.concurrent` returns `error.ConcurrencyUnavailable`
  on an Io without threads; `testing.io` has them.
