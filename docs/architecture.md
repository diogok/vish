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
│   └── socket.zig   — TCP keep-alive / no-delay socket option setters
├── loop/
│   ├── loop.zig     — multi-task accept + worker loop, idle timeout babysitter
│   ├── handler.zig  — Handler vtable interface and `wrap(T)` helper
│   └── signal.zig   — SIGINT/SIGHUP -> std.Io.Event for graceful shutdown
├── utils/
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
- **Idle timeout**: implemented as a "babysitter" task that sleeps for `idle_timeout_in_millis` and shuts the stream down if not cancelled first. Only the wait-for-first-byte phase is timed; once a request starts arriving the babysitter is cancelled.

## Request lifecycle

1. `acceptLoop` receives a `Connection` from `server.accept()`.
2. Worker takes ownership; arena is initialized once per connection.
3. For each request:
   - `waitForNextRequest` blocks for the first byte (with optional idle deadline).
   - `Connection.next()` resets the arena and parses the request line + headers via `Request.read`.
   - `Response.fromRequest(req)` constructs a fresh response sharing the request's writer and arena allocator.
   - `handler.handle(req, &res)` runs. Returning `error.Skipped` causes the loop to send `404 Not Found`.
   - `req.writer.flush()` writes buffered bytes to the socket.
   - The connection continues unless either side sent `Connection: close`.

`Response.send()` is for one-shot bodies. For streaming, use `writeChunk` + `end` (chunked transfer-encoding) or `writeSSE` / `writeEvent` / `writeSSEComment` (Server-Sent Events).

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
