# VISH

**V**table **I**O **S**erver for **H**TTP: an HTTP server library for Zig.

## Features

### Handler interface

A vtable-based interface that allows any struct with a `handle(Request, *Response)` function to process HTTP requests.

- Use `Handler.wrap(T)` to convert any struct with a compatible `handle` method into a `Handler`
- All handlers expose an `.interface()` method that returns the common `Handler` type
- Handlers can be composed and chained together, enabling middleware-like patterns
- Return `error.Skipped` from a handler to indicate it didn't match, allowing fallback to the next handler

### Accept/read/write Loop

A concurrent loop built on Zig's `std.Io` rework:

- An accept task runs in its own unit of concurrency, waiting for incoming connections
- Each connection is dispatched to a worker task (one OS thread per connection under the default `Io`)
- Backpressure: when concurrency is saturated, the connection runs inline on the accept task
- Idle keep-alive connections are reaped after a configurable timeout
- Supports graceful shutdown: stops accepting new connections and cancels in-flight workers
- Memory is managed per-connection using an arena allocator that resets between requests

### Routing

StructRouter: Define routes declaratively using Zig's identifier syntax.

```zig
pub fn @"GET /"(self: @This(), req: Request, res: *Response) !void { }
pub fn @"POST /users"(self: @This(), req: Request, res: *Response) !void { }
```

Supports wildcard path parameters. Matched parts are passed as an additional parameter:

```zig
// Matches /users/123, /users/abc, etc.
pub fn @"GET /users/?"(self: @This(), req: Request, res: *Response, params: []const []const u8) !void {
    const user_id = params[0];
}
```

PrefixRouter: Routes requests to a handler if the URI prefix matches. The prefix is stripped from the path before passing to the inner handler, enabling modular sub-applications.

CombinedRouter: Chains multiple handlers together, attempting each in order until one matches.

### Streaming responses

- Chunked transfer encoding via `writeChunk` / `end`
- Server-Sent Events via `writeSSE` / `writeEvent` / `writeSSEComment`

### Compression

Transparent `gzip` and `deflate` for both directions:

- Request bodies with `Content-Encoding: gzip|deflate` are decompressed on read; handlers always see plaintext
- Set `res.headers.content_encoding = .gzip` (or `.deflate`) on a response and `send()` will compress the body and update `Content-Length`

### Static assets

`addStaticAssets` in `build.zig` generates an asset module that pairs with `StaticRouter`:

- Debug builds read from disk on each request (live edits, no rebuild)
- Release builds `@embedFile` everything into the binary

### Middleware

Handlers that wrap other handlers to add cross-cutting functionality:

- Common Log Format: Logs requests in standard CLF format.

Custom middleware can be implemented by creating a handler that wraps another handler and calls it within its own logic.

### Utilities

- Form data parsing: Parse URL-encoded form data from query strings or request bodies into Zig structs
- MIME types: MIME type detection and handling
- URI encoding: URL encoding/decoding utilities
- Timestamps: Date/time formatting for HTTP headers

## Installation

```sh
zig fetch --save git+https://github.com/diogok/vish
```

Then in your `build.zig`:

```zig
const vish = b.dependency("vish", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("vish", vish.module("vish"));
```

## Usage

```zig
const std = @import("std");
const vish = @import("vish");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 8080);

    var server = vish.Server.init(io, allocator, address, .{});
    defer server.deinit();
    try server.listen();

    var my_handler = MyHandler{};
    const handler = vish.Handler.wrap(MyHandler).init(&my_handler);

    var loop = try vish.Loop.init(io, &server, handler.interface());
    defer loop.deinit();
    try loop.start();

    vish.waitInterrupt(io);
}

const MyHandler = struct {
    pub fn handle(
        _: @This(),
        req: vish.Request,
        res: *vish.Response,
    ) vish.HandleError!void {
        _ = req;
        res.body = "Hello, World!";
        try res.send();
    }
};
```

See [src/demo.zig](src/demo.zig) and [src/demo2.zig](src/demo2.zig) for runnable examples, and [docs/](docs/) for architecture, conventions, and a full usage walkthrough.

## AI Usage

- This library was mostly hand written. 
- Some functions, fixes and zig version migratation were AI assisted.
- Comments and docs were AI written and human edited.
- All was human reviewed.
- The design, interfaces and archtecture is my own.

## License

MIT License.
