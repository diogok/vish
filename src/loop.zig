pub const Loop = struct {
    allocator: std.mem.Allocator,

    thread_pool: *std.Thread.Pool,
    wait_group: *std.Thread.WaitGroup,

    active: bool,

    pub fn init(allocator: std.mem.Allocator) !@This() {
        var pool = try allocator.create(std.Thread.Pool);
        try pool.init(.{ .allocator = allocator, .n_jobs = 102 });

        const wg = try allocator.create(std.Thread.WaitGroup);
        wg.* = std.Thread.WaitGroup{};

        return @This(){
            .allocator = allocator,
            .thread_pool = pool,
            .wait_group = wg,
            .active = false,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.stop();
        self.thread_pool.deinit();
        self.allocator.destroy(self.thread_pool);
        self.allocator.destroy(self.wait_group);
    }

    pub fn stop(self: *@This()) void {
        self.active = false;
    }

    pub fn run(
        self: *@This(),
        server: *Server,
        handler: *Handler,
    ) !void {
        self.active = true;
        self.thread_pool.spawnWg(self.wait_group, @This().waitDefaultSignal, .{ self, server });
        self.thread_pool.spawnWg(self.wait_group, @This().accept, .{ self, server, handler });
        //_ = try std.Thread.spawn(.{}, @This().waitDefaultSignal, .{ self, server });
        //_ = try std.Thread.spawn(.{}, @This().accept, .{ self, server, handler });
    }

    pub fn wait(self: *@This()) void {
        self.thread_pool.waitAndWork(self.wait_group);
        //self.wait_group.wait();
        self.active = false;
    }

    fn waitDefaultSignal(self: *@This(), server: *Server) void {
        //self.wait_group.start();
        //defer self.wait_group.finish();

        // TODO: what about when not using default signals?
        log.info("Waiting on default signal", .{});
        signal.wait();
        log.info("Stopping on default signal", .{});

        server.stop();
        self.active = false;
    }

    fn accept(
        self: *@This(),
        server: *Server,
        handler: *Handler,
    ) void {
        //self.wait_group.start();
        //defer self.wait_group.finish();
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
                //_ = std.Thread.spawn(
                //    .{},
                //    @This().onConnection,
                //    .{
                //        self,
                //        conn,
                //        handler,
                //    },
                //) catch |err| {
                //    log.err("Failed to spawn thread for connection: {any}", .{err});
                //};
            }
        }
        log.info("Done accepting connections", .{});
    }

    fn onConnection(
        self: *@This(),
        connection: Connection,
        handler: *Handler,
    ) void {
        //self.wait_group.start();
        //defer self.wait_group.finish();

        log.info("Connection started", .{});
        defer connection.deinit();

        while (self.active) {
            const request = connection.next() catch |err| {
                log.err("Error reading request: {any}", .{err});
                return;
            };
            if (request) |req| {
                defer req.deinit(connection.server.allocator);

                log.debug("Request: {any}", .{req});

                var res = Response.fromRequest(req);

                handler.handle(connection, req, &res) catch |err| {
                    log.err("Handle error: {any}", .{err});
                };

                log.debug("Response: {any}", .{res});

                connection.writer().flush() catch |err| {
                    log.err("Writer flush error: {any}", .{err});
                };

                if (!std.ascii.eqlIgnoreCase(req.headers.connection, "keep-alive") or
                    !std.ascii.eqlIgnoreCase(res.headers.connection, "keep-alive"))
                {
                    return;
                }
            } else {
                return;
            }
        }

        log.info("Done with connection", .{});
    }
};

pub fn runAndWait(
    allocator: std.mem.Allocator,
    address: std.net.Address,
    handler: *Handler,
    options: ListenOptions,
) !void {
    var server = Server.init(allocator, address, options);
    defer server.deinit();

    try server.listen();

    log.debug("Listening on {any}:{d}", .{ address, address.getPort() });

    signal.registerDefaultHandlers();

    var loop = try Loop.init(allocator);
    defer loop.deinit();

    try loop.run(&server, handler);

    log.info("waiting", .{});
    loop.wait();

    log.info("the end.", .{});
}

const log = std.log.scoped(.http);

const std = @import("std");
const testing = std.testing;

const signal = @import("signal.zig");
const Server = @import("server.zig").Server;
const Connection = @import("server.zig").Connection;
const ListenOptions = @import("server.zig").ListenOptions;

const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

const Handler = @import("handler.zig").Handler;
