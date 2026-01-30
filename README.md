# http

A simple HTTP server library for Zig.

## Features

### Handler interface

A vtable-based interface that allows any struct with a `handle(Request, *Response)` function to process HTTP requests.

- Use `Handler.wrap(T)` to convert any struct with a compatible `handle` method into a `Handler`
- All handlers expose an `.interface()` method that returns the common `Handler` type
- Handlers can be composed and chained together, enabling middleware-like patterns
- Return `error.Skipped` from a handler to indicate it didn't match, allowing fallback to the next handler

### Accept/read/write Loop

A multi-threaded loop that manages HTTP connections:

- Runs an accept loop in a dedicated thread, waiting for incoming connections
- Dispatches each connection to a thread pool
- Supports graceful shutdown: stops accepting new connections and waits for workers to finish
- Memory is managed per-connection using an arena allocator that resets between requests

I am waiting for the Zig IO rework to try alternative evented async loop.

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
zig fetch --save git+https://github.com/your-username/http
```

Then in your `build.zig`:

```zig
const http = b.dependency("http", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("http", http.module("http"));
```

## Usage

```zig
const std = @import("std");
const http = @import("http");

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    const address = try std.net.Address.resolveIp("127.0.0.1", 8080);

    var server = http.Server.init(allocator, address, .{});
    defer server.deinit();
    try server.listen();

    var my_handler = MyHandler{};
    const handler = http.Handler.wrap(MyHandler).init(&my_handler);

    var loop = try http.Loop.init(allocator, &server, handler.interface());
    defer loop.deinit();
    try loop.start();

    http.waitInterrupt();
}

const MyHandler = struct {
    pub fn handle(
        _: @This(),
        req: http.Request,
        res: *http.Response,
    ) http.HandleError!void {
        _ = req;
        res.body = "Hello, World!";
        try res.send();
    }
};
```

See [src/demo.zig] and [src/demo2.zig].

## License

MIT License.
