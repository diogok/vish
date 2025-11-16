pub const VTable = struct {
    handle: *const fn (h: *Handler, req: Request, res: *Response) Error!void,
};

pub const Error = error{
    WriteFailed,
    NoSpaceLeft,
};

pub const Handler = struct {
    vtable: *const VTable,

    pub fn handle(
        self: *@This(),
        req: Request,
        res: *Response,
    ) Error!void {
        return self.vtable.handle(self, req, res);
    }

    pub fn wrap(HandlerType: type) type {
        return struct {
            const Self = @This();

            handler: *HandlerType,
            interface_state: Handler,

            pub fn init(handler: *HandlerType) Self {
                return .{
                    .handler = handler,
                    .interface_state = .{
                        .vtable = &.{
                            .handle = Self.handle,
                        },
                    },
                };
            }

            pub fn interface(r: *@This()) *Handler {
                return &r.interface_state;
            }

            pub fn handle(h: *Handler, req: Request, res: *Response) Error!void {
                const self: *Self = @alignCast(@fieldParentPtr("interface_state", h));
                try self.handler.handle(req, res);
            }
        };
    }
};

const log = std.log.scoped(.http);

const std = @import("std");
const testing = std.testing;

const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
