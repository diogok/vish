# Handover — WebSocket client

**Status: V1 committed; V2 next.** Branch `ws-client` from `main` at
`84a0db0`.

## Next: V2 — the client

- Plan: `src/http/websocket.zig` (`readFrame`, `writeFrameParts`,
  the test helpers `frame`, `WsClient`, `WsTestServer`,
  `readUnmaskedFrame`), plan.md "Design" and "Verified facts".
- Do: `src/http/websocket/frame.zig` (header decode/encode, mask,
  `OpCode`, `CloseCode`, `acceptKey`); `role` on the session (the
  masking direction on both paths); `src/http/websocket/client.zig`
  with `connect(io, allocator, options)`, the handshake, masked
  sends, `next()` / `sendText` / `sendBinary` / `ping` / `close` /
  `deinit`; `vish.WebSocketClient` in `root.zig`; the integration
  tests that do not need raw frames moved to the real client; the
  round-trip tests from the card; `src/ws_echo.zig` + a `ws-echo`
  build step; docs.
- Verify: `zig build test --summary all`, `zig build`,
  `zig fmt --check src`; `zig build run2 &` then `zig build ws-echo`
  prints the echoed `hello`.

Baseline command: `zig build test --summary all`.
