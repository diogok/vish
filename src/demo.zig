pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();
    //const allocator = std.heap.smp_allocator; // for a faster allocator

    const ip = "127.0.0.1";
    const port: u16 = 8080;
    const address = try std.net.Address.resolveIp(ip, port);

    var server = http.Server.init(allocator, address, .{});
    defer server.deinit();
    try server.listen();

    var handler = http.Handler.wrap(MyHandler{}).init();

    var loop = try http.Loop.init(allocator);
    defer loop.deinit();
    try loop.start(&server, (&handler).interface());

    http.waitSignal();
    loop.stop();
    loop.wait();
    server.stop();
}

pub const MyHandler = struct {
    pub fn handle(
        _: @This(),
        conn: http.Connection,
        req: http.Request,
        res: *http.Response,
    ) http.HandleError!void {
        log.debug("Request: {any}", .{req});

        res.body = "hello";

        try res.send(conn.writer());
    }
};

const std = @import("std");
const http = @import("http");
const log = std.log.scoped(.demo);

pub const std_options: std.Options = .{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .http, .level = .warn },
    },
};
