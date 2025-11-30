pub const Loop = struct {
    allocator: std.mem.Allocator,

    thread_pool: *std.Thread.Pool,
    wait_group: *std.Thread.WaitGroup,

    active: bool,

    server: *http.Server,
    handler: *Handler,

    pub fn init(
        allocator: std.mem.Allocator,
        server: *http.Server,
        handler: *Handler,
    ) !@This() {
        var pool = try allocator.create(std.Thread.Pool);
        try pool.init(.{ .allocator = allocator });

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

    fn accept(
        self: *@This(),
        server: *http.Server,
        handler: *Handler,
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

    fn onConnection(
        self: *@This(),
        connection: http.Connection,
        handler: *Handler,
    ) void {
        defer connection.deinit();
        defer log.info("Done with connection", .{});

        log.info("Connection started", .{});
        while (self.active) {
            const request = connection.next() catch |err| {
                log.err("Error reading request: {any}", .{err});
                return;
            };
            if (request) |req| {
                const conn_header = self.onRequest(handler, req);
                switch (conn_header) {
                    .close => {
                        return;
                    },
                    .keep => {},
                }
            } else {
                return;
            }
        }
    }

    fn onRequest(
        _: *@This(),
        handler: *Handler,
        req: http.Request,
    ) enum { close, keep } {
        defer req.deinit();

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

        if (std.ascii.eqlIgnoreCase(req.headers.connection, "close") or
            std.ascii.eqlIgnoreCase(res.headers.connection, "close"))
        {
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
