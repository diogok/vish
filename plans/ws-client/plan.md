# WebSocket client (branch `ws-client`)

Three stages, each its own commit: a write mutex inside the session
(V1), a client session sharing the server's frame codec (V2), and a
TLS option on the client (V3). Baseline: `main` at `84a0db0`.

## Goal

Make `WebSocket` safe for one reader task plus any number of sender
tasks, then add a client that connects, handshakes, masks its frames
and speaks the same session contract as the server, optionally over
TLS. Server behaviour stays unchanged; the existing suite stays green.

## Verified facts

- `std.Io.Mutex`: `.init`, `lockUncancelable(io)`, `unlock(io)`. The
  uncontended path never touches `io`; contention goes through
  `io.futexWait`. `lock(io)` is a cancelation point; the socket write
  inside the critical section already is one, so `lockUncancelable`
  keeps the mutex wait out of it.
- `std.testing.io` is a `std.Io.Threaded`: `Group.concurrent` gives
  a real second task in tests. The loop spawns its workers with
  `Group.concurrent` too.
- `next()` writes from the reader task: the automatic pong, the
  Close echo, the protocol-error Close, the idle-deadline Close.
- `std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream })`,
  `stream.reader(io, buf)` / `stream.writer(io, buf)` give
  `Stream.Reader` / `Stream.Writer` whose `.interface` is the
  `std.Io.Reader` / `std.Io.Writer`. Both hold a pointer to
  themselves through the interface: they must not move once in use.
- `io.random(buf)` fills bytes from the Io's RNG (seeded from
  `randomSecure`); the mask key and the handshake key use it.
- `std.crypto.tls.Client.init(input, output, options)`: `input` (the
  socket reader) needs a buffer of at least `min_buffer_len`;
  `options.read_buffer` / `write_buffer` are the plaintext buffers;
  `host = .{ .explicit = name }`, `ca = .{ .bundle = .{ gpa, io,
  lock: *RwLock, bundle: *Certificate.Bundle } }`, `entropy` (240
  random bytes), `realtime_now = std.Io.Clock.real.now(io)`. The
  bundle is filled with `bundle.rescan(gpa, io, now)`. The stdlib has
  no TLS server.
- RFC 6455: client frames masked with a fresh key per frame (§5.3);
  a client MUST fail the connection on a masked server frame (§5.1);
  `Sec-WebSocket-Accept` = base64(SHA-1(key ++ GUID)) (§4.2.2); a
  subprotocol in the 101 that was not offered fails the handshake
  (§4.1 step 6).

## Design

- The session (`src/http/websocket.zig`) serves both roles: a `role`
  field decides the masking direction. `upgrade()` builds a server
  session; the client (`src/http/websocket/client.zig`) owns the
  socket, its buffers and the optional TLS state, runs the client
  handshake and embeds a client-role session. The codec
  (`src/http/websocket/frame.zig`) holds the header encode/decode,
  masking, opcodes, close codes and the accept-key derivation.
- One `std.Io.Mutex` per session around every frame write; the state
  checks that gate a write (`closed`, `failed`) run under the same
  lock, so two tasks racing on `close()` produce one Close frame.
- The client's reader, writer and TLS state are heap objects owned
  by the client, so a `Client` returned by value stays valid.

## Work items

- [x] V1 — write mutex: `io` becomes a required session field;
      `write_mutex` held across every frame write; ping storm +
      concurrent sender test.
- [ ] V2 — codec split, client session, tests migrated to the real
      client, in-process round-trip tests, `ws-echo` live probe.
- [ ] V3 — `tls` connect option over `std.crypto.tls.Client`; live
      probe against a public `wss://` echo if the network allows.

## Open risks

- Under TLS the idle deadline peeks the raw socket, so a record that
  is buffered but not yet decrypted could be missed. V3 disables the
  deadline under TLS rather than misreport a silent peer.
- The client's `next()` slices point into the session's receive
  buffer, like the server's: a sender task must copy before sharing.
