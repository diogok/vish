//! Event loop for handling concurrent HTTP connections.
//!
//! Provides a multi-threaded event loop that accepts connections
//! and dispatches them to handler functions.
//!
//! It uses a thread pool to process multiple connections concurrently,
//! and handle shutdown and cleanup as needed.
//!
//! ## Main flow
//! - Main accept loop runs in its own thread, waiting for new connections
//! - Each connection is dispatched to a thread pool worker
//! - Workers process requests in a keep-alive loop until the connection closes
//! - Graceful shutdown stops accepting new connections and waits for workers to finish
//!
//! ## Lifecycle
//! - Accept thread receives connection and spawns worker task
//! - Worker reads requests in a loop (supporting HTTP keep-alive)
//! - Each request is passed to the handler, which populates the response
//! - Response is flushed; connection continues or closes based on Connection header
//! - Connection arena is reset between requests for memory efficiency

pub const Loop = struct {
    allocator: std.mem.Allocator,

    thread_pool: *std.Thread.Pool,
    wait_group: *std.Thread.WaitGroup,

    active: bool,

    server: *http.Server,
    handler: Handler,

    pub fn init(
        allocator: std.mem.Allocator,
        server: *http.Server,
        handler: Handler,
    ) !@This() {
        var pool = try allocator.create(std.Thread.Pool);
        const cpu_count = std.Thread.getCpuCount() catch 4;
        try pool.init(.{ .allocator = allocator, .n_jobs = @intCast(cpu_count * 4) });

        const wg = try allocator.create(std.Thread.WaitGroup);
        wg.* = std.Thread.WaitGroup{};

        return @This(){
            .allocator = allocator,
            .thread_pool = pool,
            .wait_group = wg,
            .active = false,
            .server = server,
            .handler = handler,
        };
    }

    pub fn deinit(self: *@This()) void {
        log.info("Deinit loop", .{});
        self.stop();
        self.wait();
        self.thread_pool.deinit();
        self.allocator.destroy(self.thread_pool);
        self.allocator.destroy(self.wait_group);
    }

    pub fn stop(self: *@This()) void {
        log.info("Stop loop", .{});
        self.active = false;
    }

    pub fn start(
        self: *@This(),
    ) !void {
        self.active = true;
        self.thread_pool.spawnWg(self.wait_group, @This().accept, .{ self, self.server, self.handler });
        log.info("Started", .{});
    }

    pub fn wait(self: *@This()) void {
        self.thread_pool.waitAndWork(self.wait_group);
    }

    /// While loop is active, accept a connection (when available), and start a thread to handle it
    fn accept(
        self: *@This(),
        server: *http.Server,
        handler: Handler,
    ) void {
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
                self.thread_pool.spawnWg(
                    self.wait_group,
                    @This().onConnection,
                    .{
                        self,
                        conn,
                        handler,
                    },
                );
            }
        }
    }

    /// Handle a single TCP connection, processing multiple HTTP requests (keep-alive).
    ///
    /// This function runs in a thread pool worker and processes requests in a loop
    /// until either:
    /// - The connection is closed (Connection: close header)
    /// - A read error occurs (timeout, client disconnect)
    /// - The server is shutting down (self.active == false)
    ///
    /// Memory for each request is managed by the Connection's allocator,
    /// which is reset between requests.
    fn onConnection(
        self: *@This(),
        connection: http.Connection,
        handler: Handler,
    ) void {
        var conn = connection;
        defer conn.deinit();
        defer log.info("Done with connection", .{});

        log.info("Connection started", .{});
        // Keep-alive loop: process multiple requests on the same connection
        while (self.active) {
            const request = conn.next() catch |err| {
                log.err("Error reading request: {any}", .{err});
                return;
            };
            if (request) |req| {
                const conn_header = self.onRequest(handler, req);
                switch (conn_header) {
                    .close => {
                        return; // Client or server requested connection close
                    },
                    .keep => {}, // Continue to next request
                }
            } else {
                return; // No more data (client closed connection or timeout)
            }
        }
    }

    /// Process a single HTTP request and determine if the connection should continue.
    ///
    /// Returns .close if either the request or response has Connection: close,
    /// indicating the connection should be terminated after this response.
    /// Returns .keep to continue processing requests on this connection.
    fn onRequest(
        _: *@This(),
        handler: Handler,
        req: http.Request,
    ) enum { close, keep } {
        // Note: Request cleanup is handled by arena reset in Connection.next()

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
