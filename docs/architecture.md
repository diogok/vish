# Architecture

A short tour of what lives where, how a request flows through the server, and the invariants the modules rely on.

## Module layout

```
src/
├── root.zig         — public surface: re-exports Request, Response, Server,
│                      Loop, Handler, utils, etc.
├── http/
│   ├── server.zig   — Server (accept) + Connection (per-socket state, arena,
│   │                  buffers, request parsing)
│   ├── request.zig  — Method, URI, Version, Headers, Request, BodyReader
│   ├── response.zig — Status, Headers, Response (status/headers/body, chunked,
│   │                  SSE, gzip/deflate)
│   ├── websocket.zig — WebSocket (RFC 6455): upgrade handshake, frame
│   │                   codec, protocol validation
│   └── socket.zig   — TCP keep-alive / no-delay socket option setters
├── loop/
│   ├── loop.zig     — multi-task accept + worker loop, idle timeout
│   ├── handler.zig  — Handler vtable interface and `wrap(T)` helper
│   └── signal.zig   — SIGINT/SIGTERM/SIGHUP -> std.Io.Event for graceful
│                      shutdown
├── utils/
│   ├── root.zig     — utils namespace; registers submodule tests
│   ├── router.zig   — StructRouter, PrefixRouter, CombinedRouter, StaticRouter
│   ├── logging.zig  — Common Log Format middleware
│   ├── formdata.zig — URL-encoded form/query parsing into structs
│   ├── mime.zig     — extension -> MIME type table
│   ├── timestamp.zig — HTTP date formatting
│   └── uriencode.zig — URL encode/decode
├── assets/          — static assets bundled by `addStaticAssets` in build.zig
└── demo.zig, demo2.zig — runnable examples
```

`build.zig` also exposes `addStaticAssets(b, target, optimize, dir)`, which generates a module exporting `get(io, allocator, path) ?Asset`. In Debug it reads from disk on each call (live edits); in release it `@embedFile`s.

## Concurrency model

Built on the Zig `std.Io` rework. There is no thread pool managed by this library — concurrency is whatever the `Io` implementation provides. With the default `std.Io` each `Group.concurrent` task runs on its own OS thread.

```
                ┌───────────────────────┐
                │   Loop.start()        │
                │                       │
                │  accept_group         │
                │  ┌─────────────────┐  │
                │  │  acceptLoop     │  │  (one task)
                │  │  while active:  │  │
                │  │    accept()     │  │
                │  │    spawn worker │  │
                │  └─────────────────┘  │
                │                       │
                │  worker_group         │
                │  ┌─────┐ ┌─────┐ ...  │  (one task per connection)
                │  │ w0  │ │ w1  │      │
                │  └─────┘ └─────┘      │
                └───────────────────────┘
```

- **Accept task**: spawned via `accept_group.concurrent`. Loops on `server.accept()` and hands each connection to `worker_group.concurrent`.
- **Workers**: one task per TCP connection. Process keep-alive requests in a loop until the client closes, the idle deadline fires, or `Loop.stop()` is called.
- **Backpressure**: if `worker_group.concurrent` returns `error.ConcurrencyUnavailable`, the connection is handled inline on the accept task. This blocks the accept loop until the connection finishes, applying natural backpressure rather than dropping connections.
- **Idle timeout**: implemented as a peek-with-timeout on the socket (`Socket.receiveManyTimeout` with `MSG_PEEK`, a non-blocking receive plus a `poll` under the default `Io`) while waiting for the first byte of the next request. Only the wait-for-first-byte phase is timed; once a request starts arriving it parses without a deadline.

## Request lifecycle

1. `acceptLoop` receives a `Connection` from `server.accept()`.
2. Worker takes ownership; arena is initialized once per connection.
3. For each request:
   - `waitForNextRequest` blocks for the first byte (with optional idle deadline).
   - `Connection.next()` resets the arena and parses the request line + headers via `Request.read`.
   - `Response.fromRequest(req)` constructs a fresh response sharing the request's writer and arena allocator.
   - `handler.handle(req, &res)` runs. A top-level `.skipped` outcome (what `error.Skipped` from a concrete handler becomes at the boundary) causes the loop to send `404 Not Found`.
   - `req.writer.flush()` writes buffered bytes to the socket.
   - The connection continues unless either side sent `Connection: close`, the request was HTTP/1.0 without `Connection: keep-alive` (RFC 7230 §6.3: only HTTP/1.1 is persistent by default), or the response has neither `Content-Length` nor chunked framing (an SSE stream) and so is delimited by closing.

`Response.send()` is for one-shot bodies. For streaming, use `writeChunk` + `end` (chunked transfer-encoding) or `writeSSE` / `writeEvent` / `writeSSEComment` (Server-Sent Events).

## WebSocket

RFC 6455, in `http/websocket.zig`. The session lives inside the handler's `handle()` — the same pattern as SSE streaming — and the worker task blocks for the session's lifetime:

1. `WebSocket.upgrade(req, res)` validates the request. A valid upgrade sends `101 Switching Protocols` (with the computed `Sec-WebSocket-Accept`, and the selected `Sec-WebSocket-Protocol` when the client offered one), flushes it, and sets `res.upgraded`. An upgrade request that is invalid sends `400` and returns `error.HandshakeRejected`. A request that is not an upgrade attempt sends nothing and returns `error.NotWebSocket` — the handler returns `error.Skipped` so routing continues.
2. With `res.upgraded`, the loop closes the TCP connection when the handler returns — no keep-alive, no arena reset — the way RFC 6455 §7.1.1 has the server do it: it shuts down the send side first, then drains the peer's remaining input (its Close reply, or frames in flight) for up to `ListenOptions.upgrade_linger_in_millis` (default 1 s) before closing the socket, so the final frames are delivered rather than lost to a reset. A handler may therefore `close()` and return at once.
3. The handler then loops on `ws.next()`: text/binary messages are returned as `Message`, pings are answered with pongs internally, and a received Close is echoed back and surfaced once as `.close`. `next()` returns `error.EndOfStream` when the peer closes the connection and `error.ProtocolError` after a violation (Close already sent with the appropriate code; the error is sticky). After the handler's own `close()`, frames the peer sent before seeing it are discarded until its Close arrives. The HTTP idle reaper does not cover a session; `ws.idle_timeout_in_millis` (default 0, wait forever) closes a silent peer with 1001 and returns `error.Timeout`.
4. Outbound frames go through `sendText` / `sendBinary` / `ping` / `pong` / `close`; each flushes. Inbound frames are validated per the RFC: client frames must be masked, RSV bits and reserved opcodes are rejected with 1002, text must be valid UTF-8 (1007), and close payloads carry a valid status code.

The server never masks its frames and does not negotiate extensions. The handshake's `Connection` header is a token list (Firefox sends `keep-alive, Upgrade`); the 101 always answers with exactly `Connection: Upgrade`. When the client offers `Sec-WebSocket-Protocol`, the 101 echoes the first non-empty offered subprotocol.

Inbound data payloads are read into one session-owned receive buffer, grown geometrically and reused across messages, so a long session does not grow the per-request arena (which is never reset while the handler runs); the slices `next()` returns point into it and are valid until the next `next()` call. Control-frame payloads land in a separate 125-byte buffer so a ping mid-sequence cannot disturb a fragmented message. Payloads are capped: a data frame, or a fragment sequence summed, over `max_payload` (default 16 MiB; a handler may lower the field before its first `next()`) fails the connection with close 1009 — checked before any buffer is sized.

## Memory model

- The `Server` allocator (passed to `Server.init`) owns the read/write buffers and the arena's backing allocator. It is a normal allocator — typically a GPA or `smp_allocator`.
- Each `Connection` owns a `std.heap.ArenaAllocator`. The arena is reset to `.retain_capacity` at the start of every request, so allocations made during request parsing or handling have the lifetime of one request.
- `Request.allocator`, `Response.allocator`, and the allocator passed to `BodyReader.init` all point to this per-request arena. Handler code can allocate freely without explicit `free` — but must not retain pointers past the handler return.
- `BodyReader.deinit` is only meaningful when the request body has a `Content-Encoding`; it frees the dedicated inner buffer + decompress window. With an arena allocator both calls are no-ops; with a GPA (in tests) they prevent leaks.
- `Headers.free` is a no-op under the arena and only matters in tests that use `testing.allocator`.

## Handler interface

`Handler` is a two-pointer (`ptr` + `vtable`) value type, modeled on `std.io.Reader`. Concrete handlers implement `handle(self, req, *res)` and plug into `Handler` two ways:

1. `Handler.wrap(T).init(&state).interface()` — generic, no boilerplate.
2. Define `pub fn interface(self: *@This()) Handler` directly, declaring a private `handle(h: Handler, req, *res)` thunk that downcasts `h.ptr`. This is what every `utils/router.zig` type does.

`error.Skipped` is the convention for "this handler doesn't match — try the next one". `CombinedRouter` walks its handlers in order and treats `Skipped` as a continuation. The top-level `Loop` translates an unhandled `Skipped` into `404 Not Found`.

## Compression

Both directions are buffered (not streaming):

- **Request**: when `Content-Encoding: gzip|deflate` is present, `BodyReader.interface()` lazily wraps the inner stream in a `std.compress.flate.Decompress`. Handlers always read plaintext.
- **Response**: when `Headers.content_encoding` is set on the response, `Response.send()` compresses `body` into an arena buffer, updates `Content-Length`, then writes status + headers + compressed bytes. Streaming compression (`writeChunk` + content-encoding, or SSE + content-encoding) is unsupported and asserts in debug.

## Static assets

`build.zig` provides `addStaticAssets`, which generates a module backing `StaticRouter`. The generated module branches on `builtin.mode`:

- **Debug**: `Asset.get` opens the source asset directory each call. Edits are picked up without a rebuild — useful during development.
- **Release**: bytes are `@embedFile`d into the binary as a `StaticStringMap`, so the binary is self-contained.

`StaticRouter` only handles `GET`, rejects path-traversal (`..` segments), sets `Content-Type` from the file extension, and falls through with `error.Skipped` on miss so a `CombinedRouter` can try the next handler.

## Shutdown

```
Ctrl-C  ──►  signal.wait returns
              │
              ▼
         loop.deinit()
              │
              ├── stop()                       (sets active=false)
              ├── server.stop()                (shutdown listening socket
              │                                 -> accept() returns null)
              ├── accept_group.cancel()        (tear down accept task)
              └── worker_group.cancel()        (unblock idle workers)
                       │
                       ▼
                 server.deinit()               (close listener, free buffers)
```

`Loop.wait()` is the soft alternative — block until accept and workers finish on their own, without forcing cancellation.
