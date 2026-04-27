//! Event loop for handling concurrent HTTP connections.
//!
//! Provides a multi-threaded event loop that accepts connections and
//! dispatches them to handler functions, one task per connection.
//!
//! ## Main flow
//! - The accept loop runs in its own task, waiting for new connections.
//! - Each accepted connection is handed off to a worker task, which
//!   under the default `Io` becomes its own OS thread.
//! - Workers process requests in a keep-alive loop until the connection
//!   closes.
//! - `stop()` stops accepting new connections. `deinit()` releases the
//!   loop and cancels any workers still blocked in I/O.
//!
//! ## Lifecycle
//! - Accept task receives a connection and spawns a worker.
//! - Worker reads requests in a loop (supporting HTTP keep-alive).
//! - Each request is passed to the handler, which populates the response.
//! - Response is flushed; connection continues or closes based on the
//!   `Connection` header.
//! - Connection arena is reset between requests for memory efficiency.

pub const Loop = struct {
    io: std.Io,

    accept_group: std.Io.Group,
    worker_group: std.Io.Group,

    active: bool,

    server: *http.Server,
    handler: Handler,

    pub fn init(io: std.Io, server: *http.Server, handler: Handler) !@This() {
        return .{
            .io = io,
            .accept_group = .init,
            .worker_group = .init,
            .active = false,
            .server = server,
            .handler = handler,
        };
    }

    pub fn deinit(self: *@This()) void {
        log.info("Deinit loop", .{});
        self.stop();
        self.accept_group.cancel(self.io);
        self.worker_group.cancel(self.io);
    }

    pub fn stop(self: *@This()) void {
        log.info("Stop loop", .{});
        self.active = false;
        self.server.stop();
    }

    /// Spawn the accept task and return. Fails with `ConcurrencyUnavailable`
    /// if the `Io` implementation can't dedicate a unit of concurrency to
    /// the accept loop — without one, `start` would deadlock instead of
    /// returning, since `acceptLoop` doesn't terminate until shutdown.
    pub fn start(self: *@This()) !void {
        self.active = true;
        errdefer self.active = false;
        try self.accept_group.concurrent(self.io, acceptLoop, .{ self, self.server, self.handler });
        log.info("Started", .{});
    }

    /// Block until the accept task and all workers finish on their own.
    /// For a hard stop, use `deinit`, which also cancels in-flight tasks.
    pub fn wait(self: *@This()) void {
        self.accept_group.await(self.io) catch |err| switch (err) {
            error.Canceled => {},
        };
        self.worker_group.await(self.io) catch |err| switch (err) {
            error.Canceled => {},
        };
    }

    fn acceptLoop(
        self: *@This(),
        server: *http.Server,
        handler: Handler,
    ) std.Io.Cancelable!void {
        log.debug("Accepting connections", .{});
        defer log.debug("Done accepting connections", .{});

        while (self.active) {
            log.debug("Waiting connection...", .{});
            const connection = server.accept() catch |err| {
                log.err("Error accepting connection: {any}", .{err});
                return;
            };
            if (connection) |conn| {
                log.debug("Got a connection...", .{});
                self.worker_group.concurrent(self.io, onConnection, .{ self, conn, handler }) catch |err| switch (err) {
                    // Out of concurrency: run the connection on the
                    // accept thread. This applies backpressure to the
                    // accept loop until this connection finishes.
                    error.ConcurrencyUnavailable => onConnection(self, conn, handler) catch {},
                };
            } else if (!self.active) {
                return;
            }
        }
    }

    /// Handle a single TCP connection, processing multiple HTTP requests (keep-alive).
    ///
    /// Runs in its own task and processes requests in a loop until either:
    /// - The connection is closed (`Connection: close` header)
    /// - A read error occurs or the client disconnects
    /// - The server is shutting down (`self.active == false`)
    ///
    /// Memory for each request is managed by the Connection's arena,
    /// which is reset between requests.
    fn onConnection(
        self: *@This(),
        connection: http.Connection,
        handler: Handler,
    ) std.Io.Cancelable!void {
        var conn = connection;
        defer conn.deinit();
        defer log.info("Done with connection", .{});

        log.info("Connection started", .{});
        while (self.active) {
            const request = conn.next() catch |err| {
                log.err("Error reading request: {any}", .{err});
                return;
            };
            const req = request orelse return;
            switch (self.onRequest(handler, req)) {
                .close => return,
                .keep => {},
            }
        }
    }

    /// Process a single HTTP request and determine if the connection should continue.
    ///
    /// Returns `.close` if either the request or response has
    /// `Connection: close`, meaning the connection should be terminated
    /// after this response. Returns `.keep` to continue processing
    /// requests on this connection.
    fn onRequest(
        _: *@This(),
        handler: Handler,
        req: http.Request,
    ) enum { close, keep } {
        log.debug("Request: {any}", .{req});

        var res = http.Response.fromRequest(req);

        handler.handle(req, &res) catch |err| {
            switch (err) {
                error.Skipped => {
                    res.status = .Not_Found;
                    res.send() catch |err2| {
                        log.err("Send Not Found error: {any}", .{err2});
                    };
                },
                else => {
                    log.err("Handle error: {any}", .{err});
                },
            }
        };

        log.debug("Response: {any}", .{res});

        req.writer.flush() catch |err| {
            log.err("Writer flush error: {any}", .{err});
        };

        const req_conn = req.headers.connection orelse .close;
        const res_conn = res.headers.connection orelse .close;
        if (req_conn == .close or res_conn == .close) {
            return .close;
        } else {
            return .keep;
        }
    }
};

const HelloHandler = struct {
    pub fn handle(_: @This(), _: http.Request, res: *http.Response) HandlerError!void {
        res.body = "hello";
        try res.send();
    }
};

const TestServer = struct {
    server: http.Server,
    loop: Loop,
    handler_state: HelloHandler,
    handler_wrap: Handler.wrap(HelloHandler),

    fn start(self: *TestServer, io: std.Io, allocator: std.mem.Allocator) !void {
        self.handler_state = .{};
        self.handler_wrap = Handler.wrap(HelloHandler).init(&self.handler_state);

        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        self.server = http.Server.init(io, allocator, address, .{});
        try self.server.listen();
        errdefer self.server.deinit();

        self.loop = try Loop.init(io, &self.server, self.handler_wrap.interface());
        try self.loop.start();
    }

    fn stop(self: *TestServer) void {
        self.loop.deinit();
        self.server.deinit();
    }

    fn boundAddress(self: *TestServer) std.Io.net.IpAddress {
        return self.server.getAddress().?;
    }
};

fn sendRequest(io: std.Io, allocator: std.mem.Allocator, addr: std.Io.net.IpAddress, request: []const u8) ![]u8 {
    var stream = try std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer stream.close(io);

    var wbuf: [1024]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(request);
    try w.interface.flush();

    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    return r.interface.allocRemaining(allocator, .unlimited);
}

test "loop serves a single request" {
    const io = testing.io;
    const allocator = testing.allocator;

    var ts: TestServer = undefined;
    try ts.start(io, allocator);
    defer ts.stop();

    const response = try sendRequest(
        io,
        allocator,
        ts.boundAddress(),
        "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );
    defer allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, response, "hello") != null);
}

test "loop handles keep-alive (multiple requests on one connection)" {
    const io = testing.io;
    const allocator = testing.allocator;

    var ts: TestServer = undefined;
    try ts.start(io, allocator);
    defer ts.stop();

    var stream = try std.Io.net.IpAddress.connect(&ts.boundAddress(), io, .{ .mode = .stream });
    defer stream.close(io);

    var wbuf: [1024]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    inline for (0..3) |_| {
        try w.interface.writeAll("GET / HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n");
    }
    try w.interface.writeAll("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
    try w.interface.flush();

    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    const response = try r.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(response);

    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, response, idx, "200 OK")) |found| {
        count += 1;
        idx = found + "200 OK".len;
    }
    try testing.expectEqual(@as(usize, 4), count);
}

test "loop handles concurrent connections" {
    const io = testing.io;
    const allocator = testing.allocator;

    var ts: TestServer = undefined;
    try ts.start(io, allocator);
    defer ts.stop();

    const N = 8;
    var oks: [N]bool = @splat(false);
    var clients: std.Io.Group = .init;
    const addr = ts.boundAddress();

    for (0..N) |i| {
        clients.async(io, hitOnce, .{ io, allocator, addr, &oks[i] });
    }
    clients.await(io) catch |err| switch (err) {
        error.Canceled => {},
    };

    for (oks) |ok| try testing.expect(ok);
}

fn hitOnce(io: std.Io, allocator: std.mem.Allocator, addr: std.Io.net.IpAddress, ok: *bool) std.Io.Cancelable!void {
    const response = sendRequest(
        io,
        allocator,
        addr,
        "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    ) catch return;
    defer allocator.free(response);
    if (std.mem.indexOf(u8, response, "200 OK") != null and
        std.mem.indexOf(u8, response, "hello") != null)
    {
        ok.* = true;
    }
}

test "loop returns 404 when handler skips" {
    const io = testing.io;
    const allocator = testing.allocator;

    const SkipAll = struct {
        pub fn handle(_: @This(), _: http.Request, _: *http.Response) HandlerError!void {
            return error.Skipped;
        }
    };

    var state = SkipAll{};
    const wrapped = Handler.wrap(SkipAll).init(&state);

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = http.Server.init(io, allocator, address, .{});
    defer server.deinit();
    try server.listen();

    var loop = try Loop.init(io, &server, wrapped.interface());
    defer loop.deinit();
    try loop.start();

    const response = try sendRequest(
        io,
        allocator,
        server.getAddress().?,
        "GET /missing HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );
    defer allocator.free(response);

    try testing.expect(std.mem.indexOf(u8, response, "404 Not Found") != null);
}

test "loop shuts down cleanly with idle worker" {
    // An idle keep-alive client holds a worker blocked in netRead.
    // `loop.deinit` must cancel the worker_group and unblock the worker
    // so this test returns; if cancellation is broken the test hangs.
    const io = testing.io;
    const allocator = testing.allocator;

    var ts: TestServer = undefined;
    try ts.start(io, allocator);
    defer ts.stop();

    var stream = try std.Io.net.IpAddress.connect(&ts.boundAddress(), io, .{ .mode = .stream });
    defer stream.close(io);
    // Connection opened, no bytes sent. Worker is now blocked in netRead.
    // ts.stop() (deferred) must reap it via Group.cancel.
}

const log = std.log.scoped(.http);

const std = @import("std");
const testing = std.testing;

const http = @import("../http/server.zig");

const Handler = @import("handler.zig").Handler;
const HandlerError = @import("handler.zig").Error;
