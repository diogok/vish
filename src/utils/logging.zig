pub const Common = struct {
    handler: *Handler,
    interface_state: Handler,

    pub fn init(handler: *Handler) @This() {
        return .{
            .handler = handler,
            .interface_state = .{
                .vtable = &.{
                    .handle = @This().handle,
                },
            },
        };
    }

    pub fn log(
        self: *@This(),
        req: Request,
        res: *Response,
    ) HandlerError!void {
        try self.handler.handle(req, res);

        const date = get_current_date();

        const fmt = "{s} - - [{s}] \"{s} {s} {s}\" {d} {s}\n";
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
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        const stdout = &stdout_writer.interface;

        stdout.print(fmt, args) catch {};

        if (!@import("builtin").is_test) {
            stdout.flush() catch {};
        }
    }

    pub fn interface(r: *@This()) *Handler {
        return &r.interface_state;
    }

    pub fn handle(h: *Handler, req: Request, res: *Response) HandlerError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("interface_state", h));
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

    var wrapper_handler = Handler.wrap(MyHandler).init(&my_handler);
    const handler = (&wrapper_handler).interface();

    var logger = Common.init(handler);

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

const get_current_date = @import("timestamp.zig").get_current_date;
