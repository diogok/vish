pub const VTable = struct {
    handle: *const fn (h: *Handler, conn: Connection, req: Request, res: *Response) Error!void,
};

pub const Error = error{
    WriteFailed,
    NoSpaceLeft,
};

pub const Handler = struct {
    vtable: *const VTable,

    pub fn handle(
        self: *@This(),
        conn: Connection,
        req: Request,
        res: *Response,
    ) Error!void {
        return self.vtable.handle(self, conn, req, res);
    }

    pub fn wrap(handler: anytype) type {
        const HandlerType = @TypeOf(handler);
        return struct {
            const Self = @This();

            handler: HandlerType,
            interface_state: Handler,

            pub fn init() Self {
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

            pub fn handle(h: *Handler, conn: Connection, req: Request, res: *Response) Error!void {
                const self: *Self = @alignCast(@fieldParentPtr("interface_state", h));
                try self.handler.handle(conn, req, res);
            }
        };
    }
};

const log = std.log.scoped(.http);

const std = @import("std");
const testing = std.testing;

const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const Connection = @import("../http/server.zig").Connection;
