//! Routers: `StructRouter` (method+path methods on a struct),
//! `PrefixRouter` (mount sub-handlers under a path prefix),
//! `CombinedRouter` (try a chain of handlers), `StaticRouter` (serve a
//! comptime asset map).

/// Provider a Handler for a Router where each route pattern is a struct method.
/// Example:
/// ```
/// const MyRouter = struct {
///   pub fn "GET /"(self: @This(), request: Request, response: *Response) !void {}
///   pub fn "POST /hello/?"(self: @This(), request: Request, response: *Response) !void {}
/// };
/// ```
pub fn StructRouter(comptime HandlerType: type) type {
    return struct {
        handler: HandlerType,

        pub fn init(handler: HandlerType) @This() {
            return .{ .handler = handler };
        }

        pub fn route(self: @This(), req: Request, res: *Response) HandlerError!void {
            var path = req.uri.path;
            if (path.len == 0) {
                path = "/";
            }

            const typeInfo = @typeInfo(HandlerType);
            inline for (typeInfo.@"struct".decls) |decl| {
                const sep = comptime std.mem.indexOf(u8, decl.name, " ");
                if (sep == null) {
                    continue;
                }
                const root = comptime std.mem.indexOf(u8, decl.name[sep.?..], "/");
                if (root == null) {
                    continue;
                }

                const fn_method = comptime decl.name[0..sep.?];
                const fn_path = comptime decl.name[sep.? + 1 ..];

                const hasMatching = comptime std.mem.indexOf(u8, fn_path, "?") != null;

                if (hasMatching) {
                    const maybe_matches = checkMatch(fn_path, path);
                    if (maybe_matches) |matches| {
                        if (std.mem.eql(u8, fn_method, @tagName(req.method))) {
                            const func = @field(HandlerType, decl.name);
                            const args = .{ self.handler, req, res, matches[0..] };
                            try @call(.auto, func, args);
                            return;
                        }
                    }
                } else {
                    if (std.mem.eql(u8, fn_path, path)) {
                        if (std.mem.eql(u8, fn_method, @tagName(req.method))) {
                            const func = @field(HandlerType, decl.name);
                            const args = .{ self.handler, req, res };
                            try @call(.auto, func, args);
                            return;
                        }
                    }
                }
            }

            return error.Skipped;
        }

        pub fn interface(self: *@This()) Handler {
            return .{
                .ptr = self,
                .vtable = &.{ .handle = handle },
            };
        }

        fn handle(h: Handler, req: Request, res: *Response) HandlerError!void {
            const self: *@This() = @ptrCast(@alignCast(h.ptr));
            try self.route(req, res);
        }
    };
}

test "struct router" {
    const MyRouter = struct {
        pub fn @"GET /"(_: @This(), _: Request, res: *Response) !void {
            res.body = "hi";
        }
        pub fn @"GET /foo"(_: @This(), _: Request, res: *Response) !void {
            res.body = "bar";
        }
        pub fn @"GET /foo/bar"(_: @This(), _: Request, res: *Response) !void {
            res.body = "baz";
        }
        pub fn @"POST /echo"(_: @This(), req: Request, res: *Response) !void {
            var buffer: [1024]u8 = undefined;
            var body_reader = try req.bodyReader(&buffer);
            var reader = body_reader.interface();
            res.body = try reader.allocRemaining(testing.allocator, .unlimited);
        }
        pub fn @"GET /echo/?"(_: @This(), _: Request, res: *Response, params: []const []const u8) !void {
            res.body = params[0];
        }
    };

    var router = StructRouter(MyRouter).init(.{});

    var req: Request = .example;
    var res: Response = .fromRequest(req);
    try router.interface().handle(req, &res);
    try testing.expectEqualStrings("hi", res.body);

    req.uri.path = "/";
    res = .fromRequest(req);
    try router.interface().handle(req, &res);
    try testing.expectEqualStrings("hi", res.body);

    req.uri.path = "/foo";
    res = .fromRequest(req);
    try router.interface().handle(req, &res);
    try testing.expectEqualStrings("bar", res.body);

    req.uri.path = "/foo/bar";
    res = .fromRequest(req);
    try router.interface().handle(req, &res);
    try testing.expectEqualStrings("baz", res.body);

    var echo = std.Io.Reader.fixed("echo");
    req.method = .POST;
    req.uri.path = "/echo";
    req.headers.content_length = 4;
    req.reader = &echo;
    res = .fromRequest(req);
    try router.interface().handle(req, &res);
    try testing.expectEqualStrings("echo", res.body);
    testing.allocator.free(res.body);

    req.method = .GET;
    req.uri.path = "/echo";
    res = .fromRequest(req);
    const err = router.interface().handle(req, &res);
    try testing.expectEqualStrings("", res.body);
    try testing.expectError(error.Skipped, err);

    var world = std.Io.Reader.fixed("world");
    req.method = .GET;
    req.uri.path = "/echo/hello";
    req.reader = &world;
    res = .fromRequest(req);
    try router.interface().handle(req, &res);
    try testing.expectEqualStrings("hello", res.body);

    // Wildcard routes must check HTTP method — POST /echo/hello should not match GET /echo/?
    req.method = .POST;
    req.uri.path = "/echo/hello";
    res = .fromRequest(req);
    const err2 = router.interface().handle(req, &res);
    try testing.expectError(error.Skipped, err2);
}

/// Routes to a handler if the URI perfix matches.
pub const PrefixRouter = struct {
    prefix: []const u8,
    handler: Handler,

    pub fn init(prefix: []const u8, handler: Handler) @This() {
        return .{
            .prefix = prefix,
            .handler = handler,
        };
    }

    pub fn route(self: @This(), src_req: Request, res: *Response) HandlerError!void {
        if (std.mem.startsWith(u8, src_req.uri.path, self.prefix)) {
            const req = Request{
                .method = src_req.method,
                .headers = src_req.headers,
                .version = src_req.version,
                .uri = .{
                    .path = src_req.uri.path[self.prefix.len..],
                    .query = src_req.uri.query,
                },
                .reader = src_req.reader,
                .writer = src_req.writer,
                .allocator = src_req.allocator,
            };
            try self.handler.handle(req, res);
        } else {
            return error.Skipped;
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
        try self.route(req, res);
    }
};

test "prefix router" {
    const MyRouter = struct {
        pub fn @"GET /bar"(_: @This(), _: Request, res: *Response) !void {
            res.body = "work";
        }
        pub fn @"GET /baz"(_: @This(), req: Request, res: *Response) !void {
            res.body = req.uri.path;
        }
        pub fn deinit(_: @This()) void {}
    };

    var router0 = StructRouter(MyRouter).init(.{});
    var router = PrefixRouter.init("/foo", router0.interface());

    var req: Request = .example;
    var res: Response = .fromRequest(req);
    var err = router.interface().handle(req, &res);
    try testing.expectError(error.Skipped, err);

    req.uri.path = "/bar";
    res = .fromRequest(req);
    err = router.interface().handle(req, &res);
    try testing.expectError(error.Skipped, err);

    req.uri.path = "/foo";
    res = .fromRequest(req);
    err = router.interface().handle(req, &res);
    try testing.expectError(error.Skipped, err);

    req.uri.path = "/foo/bar";
    res = .fromRequest(req);
    try router.interface().handle(req, &res);
    try testing.expectEqual(.OK, res.status);

    req.uri.path = "/foo/baz";
    res = .fromRequest(req);
    try router.interface().handle(req, &res);
    try testing.expectEqual(.OK, res.status);
    try testing.expectEqualStrings(res.body, "/baz");

    req.uri.path = "/foo/barz";
    res = .fromRequest(req);
    err = router.interface().handle(req, &res);
    try testing.expectError(error.Skipped, err);
}

/// Handler that attempts a series of routers until one matches.
pub const CombinedRouter = struct {
    routers: []const Handler,

    pub fn init(routers: []const Handler) @This() {
        return .{ .routers = routers };
    }

    pub fn route(self: @This(), req: Request, res: *Response) HandlerError!void {
        for (self.routers) |router| {
            router.handle(req, res) catch |err| {
                switch (err) {
                    error.Skipped => continue,
                    else => return err,
                }
            };
            return;
        }
        return error.Skipped;
    }

    pub fn interface(self: *@This()) Handler {
        return .{
            .ptr = self,
            .vtable = &.{ .handle = handle },
        };
    }

    fn handle(h: Handler, req: Request, res: *Response) HandlerError!void {
        const self: *@This() = @ptrCast(@alignCast(h.ptr));
        try self.route(req, res);
    }
};

test "combined router" {
    const MyRouter0 = struct {
        pub fn @"GET /"(_: @This(), _: Request, res: *Response) !void {
            res.body = "hi";
        }
        pub fn @"GET /foo"(_: @This(), _: Request, res: *Response) !void {
            res.body = "bar";
        }
    };
    const MyRouter1 = struct {
        pub fn @"GET /foo/bar"(_: @This(), _: Request, res: *Response) !void {
            res.body = "baz";
        }
    };

    var router0 = StructRouter(MyRouter0).init(.{});
    var router1 = StructRouter(MyRouter1).init(.{});
    var prefix_router0 = PrefixRouter.init("/sub", router0.interface());
    var prefix_router1 = PrefixRouter.init("/sub", router1.interface());

    var router = CombinedRouter.init(&.{
        router0.interface(),
        router1.interface(),
        prefix_router0.interface(),
        prefix_router1.interface(),
    });

    var req: Request = .example;
    var res: Response = .fromRequest(req);

    try router.interface().handle(req, &res);
    try testing.expectEqual(.OK, res.status);
    try testing.expectEqualStrings("hi", res.body);

    req.uri.path = "/";
    res = .fromRequest(req);
    try router.interface().handle(req, &res);
    try testing.expectEqual(.OK, res.status);
    try testing.expectEqualStrings("hi", res.body);

    req.uri.path = "/foo";
    res = .fromRequest(req);
    try router.interface().handle(req, &res);
    try testing.expectEqual(.OK, res.status);
    try testing.expectEqualStrings("bar", res.body);

    req.uri.path = "/sub/foo";
    res = .fromRequest(req);
    try router.interface().handle(req, &res);
    try testing.expectEqual(.OK, res.status);
    try testing.expectEqualStrings("bar", res.body);

    req.uri.path = "/foo/bar";
    res = .fromRequest(req);
    try router.interface().handle(req, &res);
    try testing.expectEqual(.OK, res.status);
    try testing.expectEqualStrings("baz", res.body);

    req.uri.path = "/sub/foo/bar";
    res = .fromRequest(req);
    try router.interface().handle(req, &res);
    try testing.expectEqual(.OK, res.status);
    try testing.expectEqualStrings("baz", res.body);
}

/// Number of `?` wildcards in a route pattern. Used at comptime to size
/// the params array.
fn paramsLen(src_route: []const u8) usize {
    const route = std.mem.trimEnd(u8, src_route, "/");
    var size: usize = 0;
    for (route) |c| {
        if (c == '?') {
            size += 1;
        }
    }
    return size;
}

/// Match `src_path` against `src_route`. `?` segments match any single
/// path segment; matched segments are returned in the params array, in
/// order. Returns null if the path does not match.
fn checkMatch(comptime src_route: []const u8, src_path: []const u8) ?[paramsLen(src_route)][]const u8 {
    const route = comptime std.mem.trimEnd(u8, src_route, "/");
    const path = std.mem.trimEnd(u8, src_path, "/");

    var params: [paramsLen(route)][]const u8 = undefined;

    if (route.len == 0 and path.len == 0) {
        return params;
    }

    const route_len: usize = comptime countSlashes(route);
    const path_len: usize = countSlashes(path);

    if (path_len != route_len) {
        return null;
    }
    if (route_len == 0) {
        return params;
    }
    if (params.len == 0) {
        return params;
    }

    const route_parts: [route_len][]const u8 = comptime splitSegments(route_len, route);
    const req_parts: [route_len][]const u8 = splitSegments(route_len, path);

    var count: usize = 0;
    var i: usize = 0;
    while (i < route_len) : (i += 1) {
        const route_part = route_parts[i];
        const req_part = req_parts[i];
        if (std.mem.eql(u8, route_part, "?")) {
            params[count] = req_part;
            count += 1;
        } else if (!std.mem.eql(u8, route_part, req_part)) {
            return null;
        }
    }

    return params;
}

fn countSlashes(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| {
        if (c == '/') n += 1;
    }
    return n;
}

fn splitSegments(comptime n: usize, s: []const u8) [n][]const u8 {
    var parts: [n][]const u8 = undefined;
    var index: usize = 0;
    var split = std.mem.splitScalar(u8, s, '/');
    _ = split.first();
    while (split.next()) |part| : (index += 1) {
        parts[index] = part;
    }
    return parts;
}

test "matching paths" {
    const m1 = checkMatch("/", "/");
    try testing.expect(m1 != null);

    const m2 = checkMatch("/", "/foo");
    try testing.expect(m2 == null);

    const m3 = checkMatch("/foo", "/");
    try testing.expect(m3 == null);

    const m4 = checkMatch("/foo/bar", "/foo");
    try testing.expect(m4 == null);

    const m5 = checkMatch("/foo/bar", "/foo/bar");
    try testing.expect(m5 != null);

    const m6 = checkMatch("/foo/bar", "/foo/bar/baz");
    try testing.expect(m6 == null);

    const m7 = checkMatch("/foo/?", "/foo/bar/baz");
    try testing.expect(m7 == null);

    const m8 = checkMatch("/foo/?/baz", "/foo/bar");
    try testing.expect(m8 == null);

    const m9 = checkMatch("/foo/?/baz", "/foo/bar/baz");
    try testing.expect(m9 != null);
    try testing.expectEqualStrings(m9.?[0], "bar");
}

/// Serves static assets using a comptime `Assets` module (e.g. one
/// created by `addStaticAssets`). The Assets type must expose a
/// `get(io, allocator, path) ?Asset` function returning a value with
/// a `content: []const u8` field and a `deinit()` method.
///
/// Only responds to GET requests. Returns `error.Skipped` for non-GET
/// methods, empty paths, path traversal attempts, or missing files.
///
/// Example:
/// ```
/// const assets = @import("assets");
/// var static = StaticRouter(assets).init(io);
/// ```
pub fn StaticRouter(comptime Assets: type) type {
    return struct {
        io: std.Io,

        pub fn init(io: std.Io) @This() {
            return .{ .io = io };
        }

        pub fn route(self: @This(), req: Request, res: *Response) HandlerError!void {
            if (req.method != .GET) return error.Skipped;

            const path = std.mem.trimStart(u8, req.uri.path, "/");
            if (path.len == 0) return error.Skipped;
            if (std.fs.path.isAbsolute(path)) return error.Skipped;

            // Reject path traversal: ".." as a segment (start, middle, or end)
            var it = std.mem.splitScalar(u8, path, '/');
            while (it.next()) |segment| {
                if (std.mem.eql(u8, segment, "..")) return error.Skipped;
            }

            const asset = Assets.get(self.io, req.allocator, path) orelse return error.Skipped;
            defer asset.deinit();
            res.headers.content_type = mime.guess(path);
            res.body = asset.content;
            try res.send();
        }

        pub fn interface(self: *@This()) Handler {
            return .{
                .ptr = self,
                .vtable = &.{ .handle = handle },
            };
        }

        fn handle(h: Handler, req: Request, res: *Response) HandlerError!void {
            const self: *@This() = @ptrCast(@alignCast(h.ptr));
            try self.route(req, res);
        }
    };
}

test "static router" {
    const MockAssets = struct {
        pub const Asset = struct {
            content: []const u8,
            pub fn deinit(_: Asset) void {}
        };
        pub fn get(_: std.Io, _: std.mem.Allocator, path: []const u8) ?Asset {
            if (std.mem.eql(u8, path, "index.html")) return .{ .content = "<html></html>" };
            if (std.mem.eql(u8, path, "style.css")) return .{ .content = "body {}" };
            return null;
        }
    };

    var buffer: [4 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var router = StaticRouter(MockAssets).init(testing.io);

    var req: Request = .example;
    req.uri.path = "/index.html";
    req.writer = &writer;
    var res: Response = .fromRequest(req);
    try router.interface().handle(req, &res);
    try testing.expectEqualStrings("<html></html>", res.body);
    try testing.expectEqualStrings("text/html", res.headers.content_type);

    req.uri.path = "/style.css";
    res = .fromRequest(req);
    try router.interface().handle(req, &res);
    try testing.expectEqualStrings("body {}", res.body);
    try testing.expectEqualStrings("text/css", res.headers.content_type);

    req.uri.path = "/missing.html";
    res = .fromRequest(req);
    try testing.expectError(error.Skipped, router.interface().handle(req, &res));

    req.uri.path = "/../etc/passwd";
    res = .fromRequest(req);
    try testing.expectError(error.Skipped, router.interface().handle(req, &res));

    req.uri.path = "/";
    res = .fromRequest(req);
    try testing.expectError(error.Skipped, router.interface().handle(req, &res));

    req.method = .POST;
    req.uri.path = "/index.html";
    res = .fromRequest(req);
    try testing.expectError(error.Skipped, router.interface().handle(req, &res));
}

const std = @import("std");
const testing = std.testing;

const mime = @import("mime.zig");
const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const Handler = @import("../loop/handler.zig").Handler;
const HandlerError = @import("../loop/handler.zig").Error;
