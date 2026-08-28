# WebSocket server support (RFC 6455)

## Goal

Let a `vish` handler accept a WebSocket upgrade on an existing HTTP
connection and then exchange complete messages (text/binary), control
frames (ping/pong/close), with fragmentation and masking handled by the
library. Server-side only; no client yet. No external dependencies
(`std.crypto.hash.Sha1`, `std.base64`).

## Design (settled in notes.md)

- New file `src/http/websocket.zig`, file-as-struct `WebSocket`.
- `WebSocket.upgrade(req, res) !WebSocket`:
  - not an upgrade request → `error.NotWebSocket`, nothing sent (handler
    returns `Skipped`, routing continues);
  - invalid handshake → 400 already sent (with `Sec-WebSocket-Version: 13`
    on version mismatch) → `error.HandshakeRejected` (handler returns
    `.handled`);
  - success → `101 Switching Protocols` sent + flushed, `res.upgraded` set.
- The session lives inside the handler's `handle()` (same pattern as SSE):
  `next() !Message` blocks for messages; the worker task is occupied for
  the session's lifetime. When `handle` returns, the loop closes the
  connection (via the new `res.upgraded` flag) — no HTTP keep-alive resumes.
- Masking: inbound frames must be masked (else close 1002); outbound
  frames are never masked. Pings are answered with pong automatically.
- Payloads are owned by the connection arena (same lifetime rule as bodies).

## Work items

- [x] S1 — Handshake:
  - [x] request `Headers` fields: `upgrade`, `sec_websocket_key`,
        `sec_websocket_version`, `sec_websocket_protocol`;
        request `Connection` enum: `upgrade` tag
  - [x] response: `Status.Switching_Protocols = 101`, `Headers.upgrade`
        field, response `Connection.upgrade` tag (lockstep with request)
  - [x] `WebSocket.upgrade()` validation + 101/rejection paths
  - [x] `Response.upgraded` flag; loop closes upgraded connections
  - [x] verify: `zig build test`, curl 101 probe with RFC §1.3 vector
- [x] S2 — Frame codec + message API:
  - [x] frame header parse (FIN/RSV/opcode/MASK, 7/16/64-bit lengths)
  - [x] inbound payload read + unmask (arena buffer)
  - [x] protocol enforcement: RSV, reserved opcodes, unmasked client
        frame, control frame FIN/len, close payload shape → close 1002
  - [x] fragmentation reassembly; close handshake; auto pong; UTF-8
        check (1007)
  - [x] `next() !Message` (text/binary/close; EndOfStream at session end)
  - [x] send API: `sendText`, `sendBinary`, `ping`, `pong`,
        `close(code, reason)`, `flush`; `failed` latch like Response
  - [x] verify: unit tests on RFC Appendix A vectors
- [x] S3 — Tests:
  - [x] unit: accept-value vector, masked "Hello" frame, fragmented
        "Hello", close frame, every protocol-error path, unmask round-trip
  - [x] integration (live `Loop`): handshake + echo + ping/pong +
        close handshake with an in-test masked client
  - [x] verify: `zig build test`, default `zig build`
- [x] S4 — Demo + docs:
  - [x] `demo2`: `/ws` echo route (CombinedRouter order: WS before
        StructRouter so non-WS fall through)
  - [x] `root.zig`: export `WebSocket`
  - [x] docs: README usage, `docs/usage.md` WS section,
        `docs/architecture.md` module line
  - [x] verify: run demo2, curl 101 probe, python3 masked-frame echo
        round-trip probe

## Open risks

- No max-message-size knob in v1: a hostile 64-bit length fails the
  allocation, the error closes the connection. Acceptable; document.
- `Connection` header token-list semantics: we require exactly
  `Connection: Upgrade` (whole-value enum parse); `keep-alive, Upgrade`
  gets a 400. Real clients send `Upgrade` alone.
- Subprotocols (`Sec-WebSocket-Protocol`) are parsed but not negotiated:
  we never echo one; clients requiring a subprotocol will close.
- Server-initiated close closes TCP immediately after sending the Close
  frame (spec-permitted); we do not wait for the peer's Close.
- Per-frame flush (echo latency); fine at chat scale, noted for the
  benchmark baseline.
