# Handover — WebSocket client

**Status: complete.** V1, V2 and V3 are committed on branch
`ws-client` (from `main` at `84a0db0`); the tree is clean. No next
task. Merging into `main` is the user's call.

## Final state

- `src/http/websocket.zig`: the session for either role; `io`
  required; `write_mutex` around every frame write; `role`;
  `transport_writer` for a TLS layer underneath.
- `src/http/websocket/frame.zig`: the shared codec.
- `src/http/websocket/client.zig` (`vish.WebSocketClient`):
  `connect(io, allocator, Options)`, `next`, `sendText`,
  `sendBinary`, `ping`, `pong`, `close`, `deinit`; `Options.tls`.
- `src/ws_echo.zig`, `zig build ws-echo`: the live probe.
- Verification of the last commit: `zig build test` 167/167,
  `zig build` green, `zig fmt --check src` clean, and the live
  `ws://` and `wss://` probes recorded in progress.md.

## Out of scope / sanctioned

- No TLS on the server side (terminate at a proxy).
- The idle deadline is off over TLS (plan.md "Open risks").
- No unit coverage of the TLS path (plan.md "Open risks").

Baseline command: `zig build test --summary all`.
