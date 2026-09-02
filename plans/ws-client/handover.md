# Handover — WebSocket client

**Status: V1 and V2 committed; V3 next.** Branch `ws-client` from
`main` at `84a0db0`.

## Next: V3 — the `tls` option

- Plan: `src/http/websocket/client.zig` (`connect`, the buffers,
  `deinit`), `/home/diogo/workspace/zig/lib/std/crypto/tls/Client.zig`
  (`Options`, `init`, `min_buffer_len`, `end`), plan.md "Verified
  facts" (buffers, CA bundle, entropy, clock).
- Do: `tls: bool = false` on `Options` (default port 443 when set);
  a heap-allocated `std.crypto.tls.Client` initialised over the
  socket reader/writer before the handshake, with the system CA
  bundle (`Certificate.Bundle.rescan`) and `host = .{ .explicit }`;
  the session's reader/writer become the TLS client's; the idle
  deadline is disabled under TLS (the peek would miss a buffered
  record); `deinit` sends `close_notify` best effort and frees the
  TLS state; `ws_echo.zig` accepts `wss://`.
- Verify: `zig build test --summary all` (the plain path unchanged),
  `zig build`, `zig fmt --check src`; a live probe against a public
  `wss://` echo if the network allows — record what was and was not
  verified in progress.md.

Baseline command: `zig build test --summary all`.
