pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();

    const ip = "127.0.0.1";
    const port: u16 = 8080;
    const address = try std.net.Address.resolveIp(ip, port);

    var server = http.Server.init(allocator, address, .{});
    defer server.deinit();
    try server.listen();

    var my_handler = MyHandler{
        .allocator = allocator,
    };
    var struct_handler = http.utils.router.StructRouter(MyHandler).init(&my_handler);
    var combined_handlers = http.utils.router.CombinedRouter.init(&.{
        struct_handler.interface(),
    });

    var handler = http.utils.logging.Common.init(combined_handlers.interface());

    var loop = try http.Loop.init(allocator);
    defer loop.deinit();
    try loop.start(&server, handler.interface());

    http.waitSignal();
    loop.stop();
    loop.wait();
    server.stop();
}

pub const MyHandler = struct {
    allocator: std.mem.Allocator,

    pub fn @"GET /"(
        _: *@This(),
        _: http.Request,
        res: *http.Response,
    ) http.HandleError!void {
        res.body = "hello";

        try res.send();
    }

    pub fn @"GET /err"(
        _: *@This(),
        _: http.Request,
        _: *http.Response,
    ) http.HandleError!void {
        return error.Internal;
    }

    pub fn @"GET /hello"(
        self: *@This(),
        req: http.Request,
        res: *http.Response,
    ) http.HandleError!void {
        const Params = struct {
            name: ?[]const u8 = null,
        };
        var params = Params{};
        var query_reader = std.Io.Reader.fixed(req.uri.query);

        http.utils.formdata.read_formdata(
            self.allocator,
            &query_reader,
            &params,
        ) catch |err| {
            log.err("error reading query string: {any}", .{err});
        };

        var greeting = std.Io.Writer.Allocating.init(self.allocator);
        defer greeting.deinit();

        _ = try greeting.writer.write("Hello, ");
        if (params.name) |name| {
            defer self.allocator.free(name);
            _ = try greeting.writer.write(name);
        } else {
            _ = try greeting.writer.write("nameless");
        }
        _ = try greeting.writer.write("!");

        res.body = greeting.written();
        try res.send();
    }

    pub fn @"POST /hello"(
        self: *@This(),
        req: http.Request,
        res: *http.Response,
    ) http.HandleError!void {
        const Params = struct {
            name: ?[]const u8 = null,
        };
        var params = Params{};
        var buf: [1024]u8 = undefined;
        var body_reader = std.Io.Reader.Limited.init(
            req.reader,
            .limited(req.getContentLength()),
            &buf,
        );

        http.utils.formdata.read_formdata(
            self.allocator,
            &body_reader.interface,
            &params,
        ) catch |err| {
            log.err("error reading body: {any}", .{err});
        };

        var greeting = std.Io.Writer.Allocating.init(self.allocator);
        defer greeting.deinit();

        _ = try greeting.writer.write("Hello, ");
        if (params.name) |name| {
            defer self.allocator.free(name);
            _ = try greeting.writer.write(name);
        } else {
            _ = try greeting.writer.write("nameless");
        }
        _ = try greeting.writer.write("!");

        res.body = greeting.written();
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
