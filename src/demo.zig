pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();
    //const allocator = std.heap.page_allocator;

    const ip = "127.0.0.1";
    const port: u16 = 8080;
    const address = try std.net.Address.resolveIp(ip, port);

    var handler = http.Handler.wrap(MyHandler{}).init();

    try http.runAndWait(allocator, address, (&handler).interface(), .{});
}

pub const MyHandler = struct {
    pub fn handle(
        _: @This(),
        conn: http.Connection,
        req: http.Request,
        res: *http.Response,
    ) http.HandleError!void {
        log.info("Request: {any}", .{req});

        res.body = "hello";

        try res.send(conn.writer());
    }
};

const std = @import("std");
const http = @import("http");
const log = std.log.scoped(.demo);

pub const std_options: std.Options = .{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        //.{ .scope = .demo, .level = .err },
        //.{ .scope = .http, .level = .err },
    },
};
