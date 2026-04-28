# Usage

Walk-through from "hello world" up to routing, static assets, middleware,
form data, streaming, and SSE. Every snippet here matches the current
`std.Io`-based API; runnable versions live in `src/demo.zig` (minimal)
and `src/demo2.zig` (routing + assets + logging).

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

Static-asset bundling is opt-in. If you want it, also pull
`addStaticAssets` from this package's `build.zig` (or copy the function —
it's pure `std.Build` code).

## Minimal server

```zig
pub fn main(init: std.process.Init) !void {
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
    pub fn handle(_: @This(), _: vish.Request, res: *vish.Response) vish.HandleError!void {
        res.body = "Hello, World!";
        try res.send();
    }
};

const std = @import("std");
const vish = @import("vish");
```

Run with `zig build run`.

## Routing — StructRouter

Define routes as struct methods named `"<METHOD> <PATH>"`. The router
matches on method + path; non-matches return `error.Skipped`.

```zig
const Routes = struct {
    pub fn @"GET /"(_: @This(), _: vish.Request, res: *vish.Response) vish.HandleError!void {
        res.body = "home";
        try res.send();
    }

    pub fn @"POST /users"(_: @This(), _: vish.Request, res: *vish.Response) vish.HandleError!void {
        res.status = .Created;
        try res.send();
    }
};

var routes = vish.utils.router.StructRouter(Routes).init(.{});
var loop = try vish.Loop.init(io, &server, routes.interface());
```

### Path params

Use `?` as a single-segment wildcard. Matched segments are passed as a
4th parameter `params: []const []const u8`:

```zig
pub fn @"GET /users/?"(_: @This(), _: Request, res: *Response, params: []const []const u8) !void {
    const user_id = params[0];           // "123" for /users/123
    res.body = user_id;
    try res.send();
}

pub fn @"GET /users/?/posts/?"(_: @This(), _: Request, res: *Response, params: []const []const u8) !void {
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

`CombinedRouter` tries each handler in order; `error.Skipped` falls
through to the next. The first non-Skipped result wins.

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

Debug builds read from disk on each request (live edits, no rebuild).
Release builds `@embedFile` everything into the binary. `StaticRouter`
only handles `GET`, rejects path-traversal, and returns `Skipped` on
miss so a `CombinedRouter` can fall through.

## Middleware — request logging

`Common` wraps another handler and logs each request in CLF after the
inner handler returns:

```zig
var combined = CombinedRouter.init(&.{ ... });
var logger = vish.utils.logging.Common.init(io, combined.interface());

var loop = try vish.Loop.init(io, &server, logger.interface());
```

Custom middleware is just a handler that holds a wrapped `Handler`,
calls it, and adds behavior — see `src/utils/logging.zig` for the
template.

## Reading a body

`Request.bodyReader(buffer)` returns a `BodyReader` that handles both
`Content-Length` and `Transfer-Encoding: chunked`, and (transparently)
`Content-Encoding: gzip|deflate`. Always read through `.interface()`:

```zig
pub fn @"POST /upload"(_: @This(), req: Request, res: *Response) !void {
    var buf: [4096]u8 = undefined;
    var body_reader = try req.bodyReader(&buf);
    defer body_reader.deinit();             // no-op unless content-encoded

    const body = try body_reader.interface().allocRemaining(req.allocator, .unlimited);
    // body is arena-owned; do not free.
    res.body = body;
    try res.send();
}
```

## Form data and query strings

`read_formdata` parses `application/x-www-form-urlencoded` data into a
struct of `?[]const u8` (or `[]const u8`) fields. Field names match
form keys; URL-decoded values are arena-allocated.

### Query string

```zig
pub fn @"GET /hello"(self: @This(), req: Request, res: *Response) !void {
    const Params = struct { name: ?[]const u8 = null };
    var params = Params{};

    var query = std.Io.Reader.fixed(req.uri.query);
    vish.utils.formdata.read_formdata(self.allocator, &query, &params) catch {};

    var out = std.Io.Writer.Allocating.init(self.allocator);
    defer out.deinit();
    try out.writer.print("Hello, {s}!", .{ params.name orelse "world" });

    res.body = out.written();
    try res.send();
}
```

### Form body

```zig
pub fn @"POST /hello"(self: @This(), req: Request, res: *Response) !void {
    const Params = struct { name: ?[]const u8 = null };
    var params = Params{};

    var buf: [1024]u8 = undefined;
    var body_reader = try req.bodyReader(&buf);
    vish.utils.formdata.read_formdata(self.allocator, body_reader.interface(), &params) catch {};

    // ...
}
```

`StructRouter` instances need an allocator if their handlers use one;
construct with `.init(.{ .allocator = allocator })` and access via
`self.allocator`.

## Responses

### One-shot

```zig
res.status = .Created;
res.headers.content_type = "application/json";
res.body = "{\"ok\":true}";
try res.send();
```

`Content-Length` is filled in automatically from `body.len` if not set.

### Chunked streaming

```zig
try res.writeChunk("first");
try res.writeChunk("second");
try res.end();
```

`writeChunk` sends `Transfer-Encoding: chunked` headers on the first
call; chunk sizes are emitted in hex per RFC 7230.

### Server-Sent Events

```zig
try res.writeSSE(.{ .id = "1", .event = "token", .data = "hello" });
try res.writeSSEComment("heartbeat");           // ": heartbeat\n\n"
try res.writeSSE(.{ .data = "multi\nline" });   // splits on \n into multiple data: lines
try res.flush();
```

The first SSE call sets `Content-Type: text/event-stream` and
`Cache-Control: no-cache` if not already set. SSE is incompatible with
`Content-Encoding` (asserts in debug).

### Compression

```zig
res.headers.content_encoding = .gzip;   // or .deflate
res.body = big_payload;
try res.send();
```

`send()` compresses into the per-request arena, sets `Content-Length`
to the compressed size, and writes status/headers/body. Streaming
compression is **not** supported — don't combine `content_encoding`
with `writeChunk`/`writeSSE`.

### Extra headers

```zig
res.headers.extra = &.{
    .{ .name = "X-Request-ID", .value = req_id },
    .{ .name = "X-Trace-ID",   .value = trace_id },
};
try res.send();
```

For frequently-used headers, prefer adding a typed field to
`response.Headers` instead — the comptime serializer picks it up
automatically.

## Reading arbitrary request headers

By default unrecognized request headers are discarded for performance.
Opt in:

```zig
var server = vish.Server.init(io, allocator, address, .{ .parse_extra_headers = true });
```

then in handlers:

```zig
if (req.headers.get("x-request-id")) |rid| { ... }   // case-insensitive
```

Pre-parsed fields (`Host`, `Content-Type`, `Content-Length`, ...) are
**not** mirrored into `extras` — read them via the typed field.

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

`idle_timeout_in_millis` only times the wait-for-next-request gap on a
keep-alive connection; once data starts arriving the deadline is
cancelled and a slow request is allowed to complete.

## Shutdown

`vish.waitInterrupt(io)` blocks on SIGINT/SIGHUP. The deferred
`loop.deinit()` and `server.deinit()` then run in reverse declaration
order to:

1. Set `loop.active = false` and shut down the listener — accept
   returns null.
2. Cancel the accept group and worker group — any task blocked in I/O
   is unblocked.
3. Close the listening socket and free buffers.

For a soft stop, call `loop.stop()` and `loop.wait()` instead — workers
are allowed to finish in-flight requests on their own.

## Running tests

```sh
zig build test
```

Tests cover request parsing, response writing, all routers, the loop
itself (real sockets on `127.0.0.1:0`), form data, MIME detection,
URI encoding, and timestamps.
