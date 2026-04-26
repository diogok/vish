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

    pub fn start(self: *@This()) !void {
        self.active = true;
        self.accept_group.async(self.io, acceptLoop, .{ self, self.server, self.handler });
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

const log = std.log.scoped(.http);

const std = @import("std");
const testing = std.testing;

const http = @import("../http/server.zig");

const Handler = @import("handler.zig").Handler;
