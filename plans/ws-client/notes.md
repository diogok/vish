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

## TLS client (`std.crypto.tls.Client`)

- `init(input, output, options)` flushes `output` (the socket
  writer) itself during the handshake, but the plaintext `writer`'s
  `flush` only encrypts into `output`'s buffer: whoever writes
  through the TLS writer must flush the socket writer afterwards.
  Without that, the WebSocket request sat in the buffer and the
  server timed out (`EndOfStream` after 60 s on postman-echo).
  Hence `WebSocket.transport_writer`.
- `input` (the socket reader) needs a buffer of `min_buffer_len`
  (16 645) bytes; `Options.read_buffer` (plaintext) must hold a whole
  decrypted record, `max_ciphertext_len` (16 640) — the client uses
  `min_buffer_len + read_buffer_size`; `Options.write_buffer` must
  stay within one record (16 384), because `flush` assumes all it
  buffered fits the greedy slice of `output`.
- `options.ca` and the bundle are read during `init` only, so the
  bundle and its `RwLock` can be locals of the connect call.
- `end()` writes `close_notify` into `output`; flush the socket
  writer after it.
- Verified live (2026-09-02): `wss://ws.postman-echo.com/raw` and
  `wss://echo.websocket.org/` echo; `wrong.host.badssl.com` →
  `CertificateHostMismatch`, `self-signed.badssl.com` →
  `TlsCertificateNotVerified`, `expired.badssl.com` →
  `CertificateExpired`.

## Zig 0.16 pitfalls hit

- `defer` inside a loop body block runs on `continue` and `return`
  alike: a `{ lock; defer unlock; ... continue; }` block is safe.
- `std.Io.Group.concurrent` returns `error.ConcurrencyUnavailable`
  on an Io without threads; `testing.io` has them.
