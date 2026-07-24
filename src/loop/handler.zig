//! Type-erased HTTP request handler. `Handler` is a `ptr + vtable` value
//! type; concrete handlers plug in via `Handler.wrap(T)` or by exposing
//! their own `interface()` method.
//!
//! The vtable returns an `Outcome`, never an error: by the time control
//! reaches the loop, every failure has been converted into a response.
//! Concrete handlers may still be fallible — `Handler.wrap` and the
//! routers call `errorOutcome` at the boundary to turn errors into
//! responses (or into `.skipped` for `error.Skipped`).

/// What a handler did with a request. `.skipped` means "I don't match,
/// try the next handler" — the loop converts a top-level `.skipped`
/// into `404 Not Found`.
pub const Outcome = enum { handled, skipped };

pub const VTable = struct {
    handle: *const fn (h: Handler, req: Request, res: *Response) Outcome,
};

/// Errors with a defined status mapping in `statusForError`. Handlers
/// may return any error set — these names are the vocabulary the
/// default boundary understands; anything else maps to 500.
pub const Error = error{
    Skipped,

    BadRequest,
    Unauthorized,
    StreamTooLong,
    Internal,
};

pub const Handler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub fn handle(
        self: Handler,
        req: Request,
        res: *Response,
    ) Outcome {
        return self.vtable.handle(self, req, res);
    }

    /// Utility to wrap any struct with a compatible `handle` function.
    /// The wrapped `handle` may return `void`, `Outcome`, or an error
    /// union of either — errors cross the boundary via `errorOutcome`.
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

            fn handleFn(h: Handler, req: Request, res: *Response) Outcome {
                const concrete: *HandlerType = @ptrCast(@alignCast(h.ptr));
                const ReturnType = @typeInfo(@TypeOf(HandlerType.handle)).@"fn".return_type.?;
                if (comptime ReturnType == Outcome) {
                    return concrete.handle(req, res);
                } else if (comptime @typeInfo(ReturnType) == .error_union) {
                    if (comptime @typeInfo(ReturnType).error_union.payload == Outcome) {
                        return concrete.handle(req, res) catch |err| errorOutcome(concrete, err, req, res);
                    } else {
                        concrete.handle(req, res) catch |err| return errorOutcome(concrete, err, req, res);
                        return .handled;
                    }
                } else {
                    concrete.handle(req, res);
                    return .handled;
                }
            }
        };
    }
};

/// The error → response boundary. `error.Skipped` becomes `.skipped`;
/// every other error becomes a sent response — via `handler.onError(err,
/// req, res)` when the handler type declares it, otherwise a bare status
/// from `statusForError`. `handler` may be a value or a pointer.
pub fn errorOutcome(handler: anytype, err: anyerror, req: Request, res: *Response) Outcome {
    if (err == error.Skipped) return .skipped;

    const HandlerType = switch (@typeInfo(@TypeOf(handler))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(handler),
    };
    if (comptime @hasDecl(HandlerType, "onError")) {
        handler.onError(err, req, res);
        return .handled;
    }

    const status = statusForError(err);
    if (status == .Internal_Server_Error) {
        logInternal("Handler error: {any}", .{err});
    } else {
        log.debug("Handler error: {any} -> {any}", .{ err, status });
    }
    res.sendError(status);
    return .handled;
}

/// 500-mapped handler failures log at error level in production, but at
/// debug level in tests — exercising the 500 path is expected there and
/// the test runner treats error-level logs as failures.
const logInternal = if (@import("builtin").is_test) log.debug else log.err;

/// Default error → status mapping used by `errorOutcome`.
pub fn statusForError(err: anyerror) Status {
    return switch (err) {
        error.BadRequest => .Bad_Request,
        error.Unauthorized => .Unauthorized,
        error.StreamTooLong => .Payload_Too_Large,
        else => .Internal_Server_Error,
    };
}

/// Invoke a handler/route function with `args` and normalize the result
/// to an `Outcome`, exactly like `Handler.wrap` does for `handle`
/// methods. `owner` is the handler instance consulted for `onError`.
pub fn callOutcome(owner: anytype, comptime func: anytype, args: anytype, req: Request, res: *Response) Outcome {
    const ReturnType = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    if (comptime ReturnType == Outcome) {
        return @call(.auto, func, args);
    } else if (comptime @typeInfo(ReturnType) == .error_union) {
        if (comptime @typeInfo(ReturnType).error_union.payload == Outcome) {
            return @call(.auto, func, args) catch |err| errorOutcome(owner, err, req, res);
        } else {
            @call(.auto, func, args) catch |err| return errorOutcome(owner, err, req, res);
            return .handled;
        }
    } else {
        @call(.auto, func, args);
        return .handled;
    }
}

test "wrap converts error.Skipped into .skipped" {
    const SkipAll = struct {
        pub fn handle(_: @This(), _: Request, _: *Response) Error!void {
            return error.Skipped;
        }
    };

    var state = SkipAll{};
    const wrapped = Handler.wrap(SkipAll).init(&state);

    const req: Request = .example;
    var res = Response.fromRequest(req);
    try testing.expectEqual(.skipped, wrapped.interface().handle(req, &res));
    try testing.expect(!res.sent_status);
}

test "wrap converts mapped errors into status responses" {
    const Failing = struct {
        pub fn handle(_: @This(), _: Request, _: *Response) Error!void {
            return error.Unauthorized;
        }
    };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var state = Failing{};
    const wrapped = Handler.wrap(Failing).init(&state);

    var req: Request = .example;
    req.writer = &writer;
    var res = Response.fromRequest(req);
    try testing.expectEqual(.handled, wrapped.interface().handle(req, &res));

    const content = buffer[0..writer.end];
    try testing.expectEqualStrings("HTTP/1.1 401 Unauthorized\r\n\r\n", content);
}

test "wrap converts unknown errors into 500" {
    const Failing = struct {
        pub fn handle(_: @This(), _: Request, _: *Response) !void {
            return error.SomethingDomainSpecific;
        }
    };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var state = Failing{};
    const wrapped = Handler.wrap(Failing).init(&state);

    var req: Request = .example;
    req.writer = &writer;
    var res = Response.fromRequest(req);
    try testing.expectEqual(.handled, wrapped.interface().handle(req, &res));

    const content = buffer[0..writer.end];
    try testing.expectEqualStrings("HTTP/1.1 500 Internal Server Error\r\n\r\n", content);
}

test "wrap supports infallible void handlers" {
    const Infallible = struct {
        pub fn handle(_: @This(), _: Request, res: *Response) void {
            res.body = "ok";
            res.send();
        }
    };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var state = Infallible{};
    const wrapped = Handler.wrap(Infallible).init(&state);

    var req: Request = .example;
    req.writer = &writer;
    var res = Response.fromRequest(req);
    try testing.expectEqual(.handled, wrapped.interface().handle(req, &res));
    try testing.expect(res.sent_status);
}

test "wrap prefers a declared onError over the default mapping" {
    const CustomError = struct {
        pub fn handle(_: @This(), _: Request, _: *Response) Error!void {
            return error.Internal;
        }
        pub fn onError(_: @This(), _: anyerror, _: Request, res: *Response) void {
            res.status = .Service_Unavailable;
            res.body = "try later";
            res.send();
        }
    };

    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var state = CustomError{};
    const wrapped = Handler.wrap(CustomError).init(&state);

    var req: Request = .example;
    req.writer = &writer;
    var res = Response.fromRequest(req);
    try testing.expectEqual(.handled, wrapped.interface().handle(req, &res));

    const content = buffer[0..writer.end];
    try testing.expect(std.mem.indexOf(u8, content, "503 Service Unavailable") != null);
    try testing.expect(std.mem.indexOf(u8, content, "try later") != null);
}

const log = std.log.scoped(.vish);

const std = @import("std");
const testing = std.testing;

const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const Status = @import("../http/response.zig").Status;
