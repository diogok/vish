pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| {
        log.err("startup failed: {t}", .{err});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const ip = "127.0.0.1";
    const port: u16 = 8080;
    const address = try std.Io.net.IpAddress.parse(ip, port);

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

pub const MyHandler = struct {
    pub fn handle(
        _: @This(),
        req: vish.Request,
        res: *vish.Response,
    ) void {
        // The path is client-controlled: cap and escape it so a hostile
        // request can't forge or flood log lines.
        const max_logged_path_bytes = 32;
        const path = req.uri.path[0..@min(req.uri.path.len, max_logged_path_bytes)];
        log.debug("Request: {s} {f}", .{ req.method.string(), std.ascii.hexEscape(path, .lower) });

        res.body = "hello";

        res.send();
    }
};

const std = @import("std");
const vish = @import("vish");
const log = std.log.scoped(.demo);

pub const std_options: std.Options = .{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .vish, .level = .warn },
    },
};
