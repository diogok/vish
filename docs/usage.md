# Usage

Walk-through from "hello world" up to routing, static assets, middleware, form data, streaming, SSE, and WebSocket.

Every snippet here matches the current `std.Io`-based API; runnable versions live in `src/demo.zig` (minimal) and `src/demo2.zig` (routing + assets + logging).

## Install

```sh
zig fetch --save git+https://github.com/diogok/vish
```

`build.zig`:

```zig
const vish = b.dependency("vish", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("vish", vish.module("vish"));
```

Static-asset bundling is opt-in. If you want it, also pull `addStaticAssets` from this package's `build.zig` (or copy the function — it's pure `std.Build` code).

## Minimal server

```zig
pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| {
        std.log.err("startup failed: {t}", .{err});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 8080);

    var server = vish.Server.init(io, allocator, address, .{});
    defer server.deinit();
    try server.listen();

    var hello = Hello{};
    const handler = vish.Handler.wrap(Hello).init(&hello);

    var loop = try vish.Loop.init(io, &server, handler.interface());
    defer loop.deinit();
    try loop.start();

    vish.waitInterrupt(io);
}

const Hello = struct {
    pub fn handle(_: @This(), _: vish.Request, res: *vish.Response) void {
        res.body = "Hello, World!";
        res.send();
    }
};

const std = @import("std");
const vish = @import("vish");
```

Startup errors (bad address, port permissions, no concurrency) are the only fatal ones: `main` logs them and exits 1. Once the loop is running, nothing a handler or client does can bring the server down.

Run with `zig build run`.

## Routing — StructRouter

Define routes as struct methods named `"<METHOD> <PATH>"`. The router matches on method + path; non-matches produce `.skipped`, which the loop turns into `404 Not Found` if nothing else in the chain handles the request.

```zig
const Routes = struct {
    pub fn @"GET /"(_: @This(), _: vish.Request, res: *vish.Response) void {
        res.body = "home";
        res.send();
    }

    pub fn @"POST /users"(_: @This(), _: vish.Request, res: *vish.Response) !void {
        res.status = .Created;
        res.send();
    }
};

var routes = vish.utils.router.StructRouter(Routes).init(.{});
var loop = try vish.Loop.init(io, &server, routes.interface());
```

Route methods may return `void` or an error union. Errors never escape the router — see [Error handling](#error-handling).

### Path params

Use `?` as a single-segment wildcard. Matched segments are passed as a 4th parameter `params: []const []const u8`:

```zig
pub fn @"GET /users/?"(_: @This(), _: Request, res: *Response, params: []const []const u8) void {
    const user_id = params[0];           // "123" for /users/123
    res.body = user_id;
    res.send();
}

pub fn @"GET /users/?/posts/?"(_: @This(), _: Request, res: *Response, params: []const []const u8) void {
    const user_id = params[0];
    const post_id = params[1];
    _ = .{ user_id, post_id };
}
```

`?` matches exactly one segment. `?` does not match across `/`.

### PrefixRouter — mounting sub-apps

`PrefixRouter` strips a path prefix and forwards to an inner handler:

```zig
var api_routes = StructRouter(ApiRoutes).init(.{});
var api = vish.utils.router.PrefixRouter.init("/api", api_routes.interface());
```

Now `GET /api/users` is dispatched to `ApiRoutes.@"GET /users"`.

### CombinedRouter — chaining

```zig
var struct_routes = StructRouter(MyHandler).init(.{ .allocator = allocator });
var static_routes = StaticRouter(assets).init(io);

var combined = vish.utils.router.CombinedRouter.init(&.{
    struct_routes.interface(),
    static_routes.interface(),
});
```

`CombinedRouter` tries each handler in order; `.skipped` falls through to the next. The first handler that answers `.handled` wins.

## Static assets

`build.zig`:

```zig
const assets = addStaticAssets(b, target, optimize, "src/assets");
exe.root_module.addImport("assets", assets);
```

Code:

```zig
const assets = @import("assets");

var static = vish.utils.router.StaticRouter(assets).init(io);
// add static.interface() to a CombinedRouter
```

Debug builds read from disk on each request (live edits, no rebuild). Release builds `@embedFile` everything into the binary. `StaticRouter` only handles `GET`, rejects path-traversal, and returns `.skipped` on miss so a `CombinedRouter` can fall through.

## Middleware — request logging

`Common` wraps another handler and logs each request in CLF after the inner handler returns:

```zig
var combined = CombinedRouter.init(&.{ ... });
var logger = vish.utils.logging.Common.init(io, combined.interface());

var loop = try vish.Loop.init(io, &server, logger.interface());
```

Custom middleware is just a handler that holds a wrapped `Handler`, calls it, and adds behavior — see `src/utils/logging.zig` for the template.

## Error handling

The type-erased `Handler` interface cannot return errors — it returns `vish.Outcome` (`.handled` or `.skipped`). Concrete handlers and route methods may still be fallible; `Handler.wrap` and the routers convert any error into a response at the boundary:

| Error               | Response                    |
|---------------------|-----------------------------|
| `error.Skipped`     | `.skipped` (chain continues; 404 if nothing handles it) |
| `error.BadRequest`  | `400 Bad Request`           |
| `error.Unauthorized`| `401 Unauthorized`          |
| `error.StreamTooLong` | `413 Payload Too Large`   |
| `error.Internal`    | `500 Internal Server Error` |
| anything else       | `500 Internal Server Error` |

```zig
pub fn @"POST /users"(_: @This(), req: vish.Request, res: *vish.Response) !void {
    const body = try parse(req);        // any error here becomes a 500...
    if (body.name == null) return error.BadRequest; // ...this one a 400
    res.send();
}
```

To customize the conversion, declare `onError` next to `handle` (or the route methods) — it replaces the default mapping:

```zig
pub fn onError(_: @This(), err: anyerror, _: vish.Request, res: *vish.Response) void {
    res.status = vish.statusForError(err);
    res.body = "{\"error\":true}";
    res.send();
}
```

Response writes are infallible: a transport failure (client gone) latches `res.failed` and turns every later write into a no-op — the loop closes the connection afterwards. A handler that returns `.handled` without ever calling `send()` is fine too: the loop sends whatever was built. Every request gets exactly one complete response, or a closed connection; nothing a handler does can take the server down.

## Reading a body

`Request.bodyReader(buffer)` returns a `BodyReader` that handles both `Content-Length` and `Transfer-Encoding: chunked`, and (transparently) `Content-Encoding: gzip|deflate`. Always read through `.interface()`:

```zig
pub fn @"POST /upload"(_: @This(), req: Request, res: *Response) !void {
    var buf: [4096]u8 = undefined;
    var body_reader = try req.bodyReader(&buf);
    defer body_reader.deinit();             // no-op unless content-encoded

    const body = try body_reader.interface().allocRemaining(req.allocator, .unlimited);
    // body is arena-owned; do not free.
    res.body = body;
    res.send();
}
```

## Form data and query strings

`readFormdata` parses `application/x-www-form-urlencoded` data into a struct of `?[]const u8` (or `[]const u8`) fields. Field names match form keys; URL-decoded values are allocated from the allocator you pass. Pass `req.allocator` (the per-request arena): values then live until the handler returns and need no `free`.

### Query string

```zig
pub fn @"GET /hello"(_: @This(), req: Request, res: *Response) !void {
    const Params = struct { name: ?[]const u8 = null };
    var params = Params{};

    var query = std.Io.Reader.fixed(req.uri.query);
    vish.utils.formdata.readFormdata(req.allocator, &query, &params) catch {};

    var out = std.Io.Writer.Allocating.init(req.allocator);
    try out.writer.print("Hello, {s}!", .{ params.name orelse "world" });

    res.body = out.written();
    res.send();
}
```

### Form body

```zig
pub fn @"POST /hello"(_: @This(), req: Request, res: *Response) !void {
    const Params = struct { name: ?[]const u8 = null };
    var params = Params{};

    var buf: [1024]u8 = undefined;
    var body_reader = try req.bodyReader(&buf);
    vish.utils.formdata.readFormdata(req.allocator, body_reader.interface(), &params) catch {};

    // ...
}
```

## Responses

### One-shot

```zig
res.status = .Created;
res.headers.content_type = "application/json";
res.body = "{\"ok\":true}";
res.send();
```

`Content-Length` is filled in automatically from `body.len` if not set.

### Chunked streaming

```zig
res.writeChunk("first");
res.writeChunk("second");
res.end();
```

`writeChunk` sends `Transfer-Encoding: chunked` headers on the first call; chunk sizes are emitted in hex per RFC 7230.

Writes never fail — a broken connection latches `res.failed`. Long-running streaming loops should check it to stop producing early:

```zig
while (nextChunk()) |chunk| {
    if (res.failed) break;   // client is gone
    res.writeChunk(chunk);
    res.flush();
}
res.end();
```

### Server-Sent Events

```zig
res.writeSSE(.{ .id = "1", .event = "token", .data = "hello" });
res.writeSSEComment("heartbeat");           // ": heartbeat\n\n"
res.writeSSE(.{ .data = "multi\nline" });   // splits on \n into multiple data: lines
res.flush();
```

The first SSE call sets `Content-Type: text/event-stream` and `Cache-Control: no-cache` if not already set. SSE is incompatible with `Content-Encoding` (asserts in debug).

### WebSocket

A WebSocket route is a regular handler that calls `WebSocket.upgrade` and then serves the session with a `next()` loop. The worker blocks for the session's lifetime; the connection closes when the handler returns.

```zig
pub const WsEchoHandler = struct {
    pub fn handle(_: @This(), req: Request, res: *Response) !void {
        if (!std.mem.eql(u8, req.uri.path, "/ws")) return error.Skipped;
        var ws = WebSocket.upgrade(req, res) catch |err| switch (err) {
            error.NotWebSocket => return error.Skipped, // not an upgrade request
            else => return, // 400 already sent (or the client went away)
        };
        while (true) {
            const msg = ws.next() catch break; // peer closed or protocol error
            switch (msg) {
                .text => |t| ws.sendText(t),
                .binary => |b| ws.sendBinary(b),
                .close => break, // Close echoed back; session is over
            }
        }
    }
};
```

`upgrade` errors: `NotWebSocket` (the request is not an upgrade — return `error.Skipped` so routing continues), `HandshakeRejected` (an invalid upgrade request; the 400 is already on the wire — return and let it stand), and `UpgradeFailed` (the 101 could not be delivered).

Pings are answered automatically; you rarely need `ping`/`pong`/`flush` yourself. `close(code, reason)` initiates the close handshake. Payloads returned by `next()` are arena-owned and valid until the next `next()` call. When the client sends `Sec-WebSocket-Protocol`, the 101 echoes the first offered subprotocol. See `src/demo2.zig` for a live `/ws` echo route.

### Compression

```zig
res.headers.content_encoding = .gzip;   // or .deflate
res.body = big_payload;
res.send();
```

`send()` compresses into the per-request arena, sets `Content-Length` to the compressed size, and writes status/headers/body. Streaming compression is **not** supported — don't combine `content_encoding` with `writeChunk`/`writeSSE`.

### Extra headers

```zig
res.headers.extra = &.{
    .{ .name = "X-Request-ID", .value = req_id },
    .{ .name = "X-Trace-ID",   .value = trace_id },
};
res.send();
```

For frequently-used headers, prefer adding a typed field to `response.Headers` instead — the comptime serializer picks it up automatically.

## Reading arbitrary request headers

By default unrecognized request headers are discarded for performance. Opt in:

```zig
var server = vish.Server.init(io, allocator, address, .{ .parse_extra_headers = true });
```

then in handlers:

```zig
if (req.headers.get("x-request-id")) |rid| { ... }   // case-insensitive
```

Pre-parsed fields (`Host`, `Content-Type`, `Content-Length`, ...) are **not** mirrored into `extras` — read them via the typed field.

## Listening options

```zig
vish.Server.init(io, allocator, address, .{
    .kernel_backlog = 1024,
    .reuse_address = true,
    .tcp_keep_alive = true,
    .tcp_no_delay = false,
    .idle_timeout_in_millis = 1000,   // 0 disables
    .read_buffer_size = 8 * 1024,
    .write_buffer_size = 8 * 1024,
    .parse_extra_headers = false,
});
```

`idle_timeout_in_millis` only times the wait-for-next-request gap on a keep-alive connection; once data starts arriving the deadline no longer applies and a slow request is allowed to complete.

## Shutdown

`vish.waitInterrupt(io)` blocks on SIGINT, SIGTERM, or SIGHUP. The deferred `loop.deinit()` and `server.deinit()` then run in reverse declaration order to:

1. Set `loop.active = false` and shut down the listener — accept returns null.
2. Cancel the accept group and worker group — any task blocked in I/O is unblocked.
3. Close the listening socket and free buffers.

For a soft stop, call `loop.stop()` and `loop.wait()` instead — workers are allowed to finish in-flight requests on their own.

## Running tests

```sh
zig build test
```

Tests cover request parsing, response writing, all routers, the loop itself (real sockets on `127.0.0.1:0`), form data, MIME detection, URI encoding, and timestamps.
