//! Common Log Format request logging middleware.

/// Wraps another `Handler` and writes one CLF line to stdout per request.
///
/// Use as the outermost handler: a `.skipped` outcome is logged as the
/// 404 the loop sends when no handler claims a request. Nested inside
/// another router, that 404 line could be wrong (an outer handler may
/// still handle the request).
pub const Common = struct {
    io: std.Io,
    handler: Handler,
    /// Connections run on concurrent workers; serialize log writes so
    /// lines never interleave.
    mutex: std.Io.Mutex = .init,

    pub fn init(io: std.Io, handler: Handler) @This() {
        return .{ .io = io, .handler = handler };
    }

    pub fn log(
        self: *@This(),
        req: Request,
        res: *Response,
    ) Outcome {
        const outcome = self.handler.handle(req, res);

        const status: u16 = switch (outcome) {
            .handled => res.status.int(),
            .skipped => Status.Not_Found.int(),
        };

        const date = getCurrentDate(self.io);

        var host_buffer: [48]u8 = undefined;
        const host = formatHost(&host_buffer, req.client_address);

        // CLF wants `-` for an unknown size, which `{?d}` can't produce.
        var length_buffer: [20]u8 = undefined;
        const length: []const u8 = if (outcome == .handled)
            if (res.headers.content_length) |len|
                std.fmt.bufPrint(&length_buffer, "{d}", .{len}) catch "-"
            else
                "-"
        else
            "-";

        const fmt = "{s} - - [{s}] \"{s} {s} {s}\" {d} {s}\n";
        const args = .{
            host,
            date,
            req.method.string(),
            req.uri.path,
            req.version.string(),
            status,
            length,
        };

        // Hold the lock across print and flush: a line longer than the
        // buffer flushes mid-line, so unlocking between the two would
        // let another worker's line land in the middle of this one.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Streaming, not positional: a positional writer starts at
        // offset 0 every request, so with stdout redirected to a file
        // each line would overwrite the previous one.
        var stdout_buffer: [1024]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writerStreaming(self.io, &stdout_buffer);
        const stdout = &stdout_writer.interface;

        stdout.print(fmt, args) catch {};

        if (!@import("builtin").is_test) {
            stdout.flush() catch {};
        }

        return outcome;
    }

    pub fn interface(self: *@This()) Handler {
        return .{
            .ptr = self,
            .vtable = &.{ .handle = handle },
        };
    }

    fn handle(h: Handler, req: Request, res: *Response) Outcome {
        const self: *@This() = @ptrCast(@alignCast(h.ptr));
        return self.log(req, res);
    }
};

/// CLF host field: the client IP without the port, `-` when unknown.
fn formatHost(buffer: []u8, address: ?std.Io.net.IpAddress) []const u8 {
    const addr = address orelse return "-";
    return switch (addr) {
        .ip4 => |ip4| blk: {
            const bytes = &ip4.bytes;
            break :blk std.fmt.bufPrint(
                buffer,
                "{d}.{d}.{d}.{d}",
                .{ bytes[0], bytes[1], bytes[2], bytes[3] },
            ) catch "-";
        },
        .ip6 => |ip6| blk: {
            const unresolved: std.Io.net.Ip6Address.Unresolved = .{
                .bytes = ip6.bytes,
                .interface_name = null,
            };
            break :blk std.fmt.bufPrint(buffer, "{f}", .{unresolved}) catch "-";
        },
    };
}

test "common logs" {
    const MyHandler = struct {
        called: bool = false,

        pub fn handle(
            self: *@This(),
            req: Request,
            res: *Response,
        ) void {
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
    try testing.expectEqual(.handled, logger.interface().handle(req, &res));

    try testing.expect(my_handler.called);
}

test "common passes skipped through" {
    const SkipHandler = struct {
        pub fn handle(
            self: *@This(),
            req: Request,
            res: *Response,
        ) Outcome {
            _ = self;
            _ = req;
            _ = res;
            return .skipped;
        }
    };
    var skip_handler = SkipHandler{};

    const wrapper_handler = Handler.wrap(SkipHandler).init(&skip_handler);
    var logger = Common.init(testing.io, wrapper_handler.interface());

    const req: Request = .example;
    var res = Response.fromRequest(req);
    try testing.expectEqual(.skipped, logger.interface().handle(req, &res));
}

test "formatHost" {
    var buffer: [48]u8 = undefined;

    try testing.expectEqualStrings("-", formatHost(&buffer, null));

    const ip4 = try std.Io.net.IpAddress.parse("192.168.0.1", 12345);
    try testing.expectEqualStrings("192.168.0.1", formatHost(&buffer, ip4));

    const ip6 = try std.Io.net.IpAddress.parse("2001:db8::1", 12345);
    try testing.expectEqualStrings("2001:db8::1", formatHost(&buffer, ip6));
}

const std = @import("std");
const testing = std.testing;

const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const Status = @import("../http/response.zig").Status;
const Handler = @import("../loop/handler.zig").Handler;
const Outcome = @import("../loop/handler.zig").Outcome;

const getCurrentDate = @import("timestamp.zig").getCurrentDate;
