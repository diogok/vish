# Progress — WebSocket client

## Session 2 — review fixes (2026-09-02)

The review of V1-V3 applied in one commit. Comments: the `//!`
headers of `websocket.zig`, `websocket/client.zig`,
`websocket/frame.zig` and `root.zig` cut to orientation only; one
`///` per client field; the session's `io` doc names the mask key.
Code: `defaultPort` below the public methods; the client's duplicate
`allocator` / `io` fields removed (read through `session`);
`offered` → `findOffered`; `n` → `chunk_len`, `op` / `ext` →
`opcode_bits` / `extended`; the TLS start's `catch` in switch form;
`build.zig` grew `addExecutableWithRun` for demo, demo2 and ws-echo
(steps unchanged). Correctness: `next()` reads `failed` and `closed`
under `write_mutex` (`hasFailed` / `isClosed`, never a nested hold);
the client fails a 101 carrying `Sec-WebSocket-Extensions` with
`HandshakeInvalid` (§4.1 step 5); `readHeader` refuses a 64-bit
length with bit 63 set as a protocol violation (§5.2), so it gets
1002 rather than the payload cap's 1009. Tests: `ping` / `pong` are
exercised in the client storm test (the pong read raw off
`client.session.reader` while the socket is quiet); new: the canned
extension test, a live raw-server extension test through
`Client.connect` (`answerUpgradeOnce` on an `io.concurrent` future),
the bit-63 live test on `WsClient`, and a bit-63 case in
`frame.zig`. usage.md names both `SubprotocolMismatch` causes and
the extension rule.

Verified: `zig build test` 170/170 (167 before), `zig build` green
(demo, demo2, ws-echo), `zig fmt --check` clean, and the live probe:
demo2 in the background, `zig-out/bin/ws-echo` printed `hello`.

## Session 1 (continued) — V3 (2026-09-02)

V3 landed. `Options.tls` (default false) and `Options.port: ?u16`
(null = 80, or 443 with `tls`). `connect` sizes the socket ends at
`min_buffer_len` under TLS, allocates the plaintext buffers
(`read_buffer_size` + a record; `write_buffer_size` capped at one
record), runs `startTls` — system CA bundle via
`Certificate.Bundle.rescan`, `host = .{ .explicit }`, entropy from
`io.randomSecure`, a TLS alert logged at debug — and hands the TLS
client's reader/writer to the session with the socket writer as
`WebSocket.transport_writer`, flushed after every frame (the
stdlib's TLS writer leaves records in the socket buffer). The idle
deadline is off under TLS. `deinit` sends `close_notify` best
effort. `ws_echo.zig` takes `wss://` and logs vish at debug.

Verified: `zig build test` 167/167 (one new port test; the plain
path's tests unchanged), `zig build` green, `zig fmt` clean. Live,
through `zig-out/bin/ws-echo`: `wss://ws.postman-echo.com/raw`
echoed `hello from vish`; `wss://echo.websocket.org/` printed its
greeting then the echo; both ran the close handshake and exited 0.
Negative: `wss://wrong.host.badssl.com/` → `CertificateHostMismatch`,
`wss://self-signed.badssl.com/` → `TlsCertificateNotVerified`,
`wss://expired.badssl.com/` → `CertificateExpired`. Not verified:
TLS under the unit suite (no stdlib TLS server), large (> one
record) payloads over TLS, and a server that drops TLS without
`close_notify` (expected: `ReadFailed` from `next()`, since
`allow_truncation_attacks` stays false).

Plan complete; merging is the user's call.

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
