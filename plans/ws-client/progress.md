# Progress — WebSocket client

## Session 1 (continued) — V2 (2026-09-02)

V2 landed. `src/http/websocket/frame.zig` holds the codec (`OpCode`,
`CloseCode`, `readHeader` / `readMaskKey` / `encodeHeader`, `mask`,
`acceptKey`; five tests including the RFC §1.3 accept sample and
the §5.7 masked "Hello"). The session gained `role` (`.server`
default): `readFrame` requires masked frames from a client and
unmasked from a server, `writeFrameParts` masks with a fresh
`io.random` key per frame through a 4 KiB stack chunk.
`src/http/websocket/client.zig` is `vish.WebSocketClient`:
`connect(io, allocator, Options)` (IP literal via `IpAddress.parse`,
otherwise `HostName.connect`), heap-allocated `Stream.Reader` /
`Stream.Writer` so the returned value stays valid, the §4.1
handshake with the accept check, `Connection` token lists,
subprotocol selection that must come from the offered list, extra
headers; `next` / `sendText` / `sendBinary` / `ping` / `pong` /
`close` / `deinit`; ten handshake unit tests against canned
responses. In `websocket.zig`: three client-role unit tests and
nine live-loop tests through the real client (text + 100 KB binary,
fragments both ways with pings between, close handshake both ways,
1009 over-cap, idle deadline 1001, refill-spanning payload,
subprotocol, and a client-side sender task racing the client's
pongs). Four raw tests whose client versions now exist were removed
(subprotocol echo, 1009, close-and-return drain, idle deadline);
the raw handshake/pong test, the 400 test, the `Connection` list
test, the refill regression (a two-frame single write the client
cannot produce) and the V1 storm stay on `WsClient`.
`src/ws_echo.zig` + `zig build ws-echo`: against demo2 it printed
`hello` and, with `ws://127.0.0.1:8080/ws "hello vish"`, the
message back. `zig build test` 166/166 (170 before the four
removals), `zig build` green, `zig fmt` clean. README,
architecture.md, usage.md and AGENTS.md updated.

Next: V3 (`tls` option).

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
