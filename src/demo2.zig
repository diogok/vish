pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const ip = "127.0.0.1";
    const port: u16 = 8080;
    const address = try std.Io.net.IpAddress.parse(ip, port);

    var server = vish.Server.init(io, allocator, address, .{});
    defer server.deinit();
    try server.listen();

    var struct_handler = vish.utils.router.StructRouter(MyHandler).init(.{
        .allocator = allocator,
    });
    var static_handler = vish.utils.router.StaticRouter(assets).init(io);
    var combined_handlers = vish.utils.router.CombinedRouter.init(&.{
        struct_handler.interface(),
        static_handler.interface(),
    });

    var handler = vish.utils.logging.Common.init(io, combined_handlers.interface());

    var loop = try vish.Loop.init(io, &server, handler.interface());
    defer loop.deinit();
    try loop.start();

    vish.waitInterrupt(io);
}

pub const MyHandler = struct {
    allocator: std.mem.Allocator,

    pub fn @"GET /"(
        _: @This(),
        _: vish.Request,
        res: *vish.Response,
    ) vish.HandleError!void {
        res.body = "hello";

        try res.send();
    }

    pub fn @"GET /err"(
        _: @This(),
        _: vish.Request,
        _: *vish.Response,
    ) vish.HandleError!void {
        return error.Internal;
    }

    pub fn @"GET /hello"(
        self: @This(),
        req: vish.Request,
        res: *vish.Response,
    ) vish.HandleError!void {
        const Params = struct {
            name: ?[]const u8 = null,
        };
        var params = Params{};
        var query_reader = std.Io.Reader.fixed(req.uri.query);

        vish.utils.formdata.read_formdata(
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
        self: @This(),
        req: vish.Request,
        res: *vish.Response,
    ) vish.HandleError!void {
        const Params = struct {
            name: ?[]const u8 = null,
        };
        var params = Params{};
        var buf: [1024]u8 = undefined;
        var body_reader = try req.bodyReader(&buf);

        vish.utils.formdata.read_formdata(
            self.allocator,
            body_reader.interface(),
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
const vish = @import("vish");
const assets = @import("assets");
const log = std.log.scoped(.demo);

pub const std_options: std.Options = .{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .vish, .level = .warn },
    },
};
