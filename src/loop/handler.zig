//! Handler is an "interface" (using a vtable) for handling HTTP Requests.

pub const VTable = struct {
    handle: *const fn (h: Handler, req: Request, res: *Response) Error!void,
};

pub const Error = error{
    StreamTooLong,
    OutOfMemory,
    ReadFailed,
    WriteFailed,
    NoSpaceLeft,

    Skipped,

    Internal,
    BadRequest,
    Unauthorized,
};

pub const Handler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub fn handle(
        self: Handler,
        req: Request,
        res: *Response,
    ) Error!void {
        return self.vtable.handle(self, req, res);
    }

    /// Utility to wrap any struct with a compatible Handle function
    pub fn wrap(HandlerType: type) type {
        return struct {
            handler: *HandlerType,

            pub fn init(handler: *HandlerType) @This() {
                return .{ .handler = handler };
            }

            pub fn interface(self: @This()) Handler {
                return .{
                    .ptr = self.handler,
                    .vtable = &.{ .handle = @This().handleFn },
                };
            }

            fn handleFn(h: Handler, req: Request, res: *Response) Error!void {
                const concrete: *HandlerType = @ptrCast(@alignCast(h.ptr));
                try concrete.handle(req, res);
            }
        };
    }
};

const log = std.log.scoped(.vish);

const std = @import("std");
const testing = std.testing;

const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
