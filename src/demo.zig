pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const ip = "127.0.0.1";
    const port: u16 = 8080;
    const address = try std.Io.net.IpAddress.parse(ip, port);

    var server = http.Server.init(io, allocator, address, .{});
    defer server.deinit();
    try server.listen();

    var my_handler = MyHandler{};
    const handler = http.Handler.wrap(MyHandler).init(&my_handler);

    var loop = try http.Loop.init(io, &server, handler.interface());
    defer loop.deinit();
    try loop.start();

    http.waitInterrupt(io);
}

pub const MyHandler = struct {
    pub fn handle(
        _: @This(),
        req: http.Request,
        res: *http.Response,
    ) http.HandleError!void {
        log.debug("Request: {any}", .{req});

        res.body = "hello";

        try res.send();
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
