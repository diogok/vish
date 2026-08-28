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

    var ws_state = WsEchoHandler{};
    var ws_handler = vish.Handler.wrap(WsEchoHandler).init(&ws_state);
    var struct_handler = vish.utils.router.StructRouter(MyHandler).init(.{});
    var static_handler = vish.utils.router.StaticRouter(assets).init(io);
    var combined_handlers = vish.utils.router.CombinedRouter.init(&.{
        ws_handler.interface(),
        struct_handler.interface(),
        static_handler.interface(),
    });

    var handler = vish.utils.logging.Common.init(io, combined_handlers.interface());

    var loop = try vish.Loop.init(io, &server, handler.interface());
    defer loop.deinit();
    try loop.start();

    vish.waitInterrupt(io);
}

/// WebSocket echo on `/ws`: answers text and binary messages
/// verbatim. Non-WebSocket requests skip to the next handler.
pub const WsEchoHandler = struct {
    pub fn handle(_: @This(), req: vish.Request, res: *vish.Response) !void {
        if (!std.mem.eql(u8, req.uri.path, "/ws")) return error.Skipped;
        var ws = vish.WebSocket.upgrade(req, res) catch |err| switch (err) {
            error.NotWebSocket => return error.Skipped,
            else => return,
        };
        while (true) {
            const msg = ws.next() catch break;
            switch (msg) {
                .text => |t| ws.sendText(t),
                .binary => |b| ws.sendBinary(b),
                .close => break,
            }
        }
    }
};

pub const MyHandler = struct {
    pub fn @"GET /"(
        _: @This(),
        _: vish.Request,
        res: *vish.Response,
    ) void {
        res.body = "hello";

        res.send();
    }

    pub fn @"GET /err"(
        _: @This(),
        _: vish.Request,
        _: *vish.Response,
    ) !void {
        // Escapes to the router boundary, which turns it into a 500.
        return error.Internal;
    }

    pub fn @"GET /hello"(
        _: @This(),
        req: vish.Request,
        res: *vish.Response,
    ) !void {
        const Params = struct {
            name: ?[]const u8 = null,
        };
        var params = Params{};
        var query_reader = std.Io.Reader.fixed(req.uri.query);

        // Everything below allocates from the per-request arena: no
        // frees needed, memory is reclaimed when the request ends.
        vish.utils.formdata.readFormdata(
            req.allocator,
            &query_reader,
            &params,
        ) catch |err| {
            log.warn("error reading query string: {t}", .{err});
        };

        var greeting = std.Io.Writer.Allocating.init(req.allocator);

        _ = try greeting.writer.write("Hello, ");
        if (params.name) |name| {
            _ = try greeting.writer.write(name);
        } else {
            _ = try greeting.writer.write("nameless");
        }
        _ = try greeting.writer.write("!");

        res.body = greeting.written();
        res.send();
    }

    pub fn @"POST /hello"(
        _: @This(),
        req: vish.Request,
        res: *vish.Response,
    ) !void {
        const Params = struct {
            name: ?[]const u8 = null,
        };
        var params = Params{};
        var buf: [1024]u8 = undefined;
        var body_reader = try req.bodyReader(&buf);

        vish.utils.formdata.readFormdata(
            req.allocator,
            body_reader.interface(),
            &params,
        ) catch |err| {
            log.warn("error reading body: {t}", .{err});
        };

        var greeting = std.Io.Writer.Allocating.init(req.allocator);

        _ = try greeting.writer.write("Hello, ");
        if (params.name) |name| {
            _ = try greeting.writer.write(name);
        } else {
            _ = try greeting.writer.write("nameless");
        }
        _ = try greeting.writer.write("!");

        res.body = greeting.written();
        res.send();
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
