//! Common Log Format request logging middleware.

/// Wraps another `Handler` and writes one CLF line to stdout per request.
pub const Common = struct {
    io: std.Io,
    handler: Handler,

    pub fn init(io: std.Io, handler: Handler) @This() {
        return .{ .io = io, .handler = handler };
    }

    pub fn log(
        self: @This(),
        req: Request,
        res: *Response,
    ) HandlerError!void {
        try self.handler.handle(req, res);

        const date = getCurrentDate(self.io);

        const fmt = "{s} - - [{s}] \"{s} {s} {s}\" {d} {?d}\n";
        const args = .{
            "", // should be client address
            date,
            req.method.string(),
            req.uri.path,
            req.version.string(),
            res.status.int(),
            res.headers.content_length,
        };

        var stdout_buffer: [1024]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(self.io, &stdout_buffer);
        const stdout = &stdout_writer.interface;

        stdout.print(fmt, args) catch {};

        if (!@import("builtin").is_test) {
            stdout.flush() catch {};
        }
    }

    pub fn interface(self: *@This()) Handler {
        return .{
            .ptr = self,
            .vtable = &.{ .handle = handle },
        };
    }

    fn handle(h: Handler, req: Request, res: *Response) HandlerError!void {
        const self: *@This() = @ptrCast(@alignCast(h.ptr));
        try self.log(req, res);
    }
};

test "common logs" {
    const MyHandler = struct {
        called: bool = false,

        pub fn handle(
            self: *@This(),
            req: Request,
            res: *Response,
        ) HandlerError!void {
            _ = req;
            _ = res;
            self.called = true;
        }
    };
    var my_handler = MyHandler{};

    const wrapper_handler = Handler.wrap(MyHandler).init(&my_handler);
    const handler = wrapper_handler.interface();

    var logger = Common.init(testing.io, handler);

    const req: Request = .example;
    var res = Response.fromRequest(req);
    try logger.interface().handle(req, &res);

    try testing.expect(my_handler.called);
}

const std = @import("std");
const testing = std.testing;

const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const Handler = @import("../loop/handler.zig").Handler;
const HandlerError = @import("../loop/handler.zig").Error;

const getCurrentDate = @import("timestamp.zig").getCurrentDate;
