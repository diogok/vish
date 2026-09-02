# Handover — WebSocket client

**Status: complete.** V1, V2, V3 and the review fixes are committed
on branch `ws-client` (from `main` at `84a0db0`); the tree is clean.
No next task. Merging into `main` is the user's call.

## Final state

- `src/http/websocket.zig`: the session for either role; `io`
  required; `write_mutex` around every frame write, the `closed` /
  `failed` gates read and written under it; `role`;
  `transport_writer` for a TLS layer underneath.
- `src/http/websocket/frame.zig`: the shared codec; a 64-bit length
  with bit 63 set is a protocol violation (1002).
- `src/http/websocket/client.zig` (`vish.WebSocketClient`):
  `connect(io, allocator, Options)`, `next`, `sendText`,
  `sendBinary`, `ping`, `pong`, `close`, `deinit`; `Options.tls`; a
  101 naming a `Sec-WebSocket-Extensions` is `HandshakeInvalid`.
- `src/ws_echo.zig`, `zig build ws-echo`: the live probe.
- Verification of the last commit: `zig build test` 170/170,
  `zig build` green, `zig fmt --check` clean, and the `ws://` probe
  against demo2 printed `hello`; the `wss://` probes are recorded in
  progress.md (session 1, V3).

## Out of scope / sanctioned

- No TLS on the server side (terminate at a proxy).
- The idle deadline is off over TLS (plan.md "Open risks").
- No unit coverage of the TLS path (plan.md "Open risks").

Baseline command: `zig build test --summary all`.
