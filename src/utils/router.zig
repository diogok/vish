//! HTTP request routing module.
//!
//! Provides flexible routing mechanisms for dispatching HTTP requests to appropriate handlers based on method and path patterns.


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
                    const maybe_matches = check_match(fn_path, path);
                    if (maybe_matches) |matches| {
                        if (std.mem.eql(u8, fn_method, @tagName(req.method))) {
                            const func = @field(HandlerType, decl.name);
                            // TODO: can I make the args a struct?
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
            var body_reader = req.bodyReader(&buffer);
            var reader = body_reader.interface();
            res.body = try reader.allocRemaining(testing.allocator, .unlimited);
            //defer testing.allocator.free(res.body);
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

/// Count the number of wildcard parameters ("?") in a route pattern.
/// Used to determine the size of the params array at compile time.
fn params_len(src_route: []const u8) usize {
    const route = std.mem.trimRight(u8, src_route, "/");
    var size: usize = 0;
    for (route) |c| {
        if (c == '?') {
            size += 1;
        }
    }
    return size;
}

/// Match a request path against a route pattern with wildcard support.
///
/// Route patterns can contain "?" as wildcards that match any single path segment.
/// The matched segments are captured and returned in the params array.
///
/// Examples
/// - Route "/users/?/posts" matches path "/users/123/posts" -> params = ["123"]
/// - Route "/?" matches path "/anything" -> params = ["anything"]
/// - Route "/foo/bar" matches path "/foo/bar" exactly (no params)
///
/// Returns null if the path doesn't match the route pattern.
fn check_match(comptime src_route: []const u8, src_path: []const u8) ?[params_len(src_route)][]const u8 {
    // Normalize paths by trimming trailing slashes
    const route = comptime std.mem.trimRight(u8, src_route, "/");
    const path = std.mem.trimRight(u8, src_path, "/");

    var params: [params_len(route)][]const u8 = undefined;

    // Empty route matches empty path
    if (route.len == 0 and path.len == 0) {
        return params;
    }

    // Count segments in route pattern (compile-time)
    const route_len: usize = comptime blk: {
        var size: usize = 0;
        for (route) |c| {
            if (c == '/') {
                size += 1;
            }
        }
        break :blk size;
    };

    // Count segments in request path (runtime)
    const path_len: usize = blk: {
        var size: usize = 0;
        for (path) |c| {
            if (c == '/') {
                size += 1;
            }
        }
        break :blk size;
    };

    // Paths with different number of segments cannot match
    if (path_len != route_len) {
        return null;
    }

    // Routes with no segments match (both are empty or "/")
    if (route_len == 0) {
        return params;
    }

    // Routes with no wildcards: early return if segment counts match
    if (params.len == 0) {
        return params;
    }

    // Split route into segments (compile-time)
    const route_parts: [route_len][]const u8 = blk: {
        var parts: [route_len][]const u8 = undefined;
        var index: usize = 0;
        var split = std.mem.splitScalar(u8, route, '/');
        _ = split.first(); // skip empty string before first "/"
        while (split.next()) |part| {
            parts[index] = part;
            index += 1;
        }
        break :blk parts;
    };

    // Split request path into segments (runtime)
    const req_parts: [route_len][]const u8 = blk: {
        var parts: [route_len][]const u8 = undefined;
        var index: usize = 0;
        var split = std.mem.splitScalar(u8, path, '/');
        _ = split.first(); // skip empty string before first "/"
        while (split.next()) |part| {
            parts[index] = part;
            index += 1;
        }
        break :blk parts;
    };

    var count: usize = 0;
    var i: usize = 0;
    while (i < route_len) {
        const req_part = req_parts[i];
        const route_part = route_parts[i];
        if (std.mem.eql(u8, route_part, "?")) {
            // match any
            params[count] = req_part;
            count += 1;
        } else if (std.mem.eql(u8, route_part, req_part)) {
            // match exact
        } else {
            // does not match
            return null;
        }
        i += 1;
    }

    return params;
}

test "matching paths" {
    const m1 = check_match("/", "/");
    try testing.expect(m1 != null);

    const m2 = check_match("/", "/foo");
    try testing.expect(m2 == null);

    const m3 = check_match("/foo", "/");
    try testing.expect(m3 == null);

    const m4 = check_match("/foo/bar", "/foo");
    try testing.expect(m4 == null);

    const m5 = check_match("/foo/bar", "/foo/bar");
    try testing.expect(m5 != null);

    const m6 = check_match("/foo/bar", "/foo/bar/baz");
    try testing.expect(m6 == null);

    const m7 = check_match("/foo/?", "/foo/bar/baz");
    try testing.expect(m7 == null);

    const m8 = check_match("/foo/?/baz", "/foo/bar");
    try testing.expect(m8 == null);

    const m9 = check_match("/foo/?/baz", "/foo/bar/baz");
    try testing.expect(m9 != null);
    try testing.expectEqualStrings(m9.?[0], "bar");
}

const std = @import("std");
const testing = std.testing;

const Request = @import("../http/request.zig").Request;
const Response = @import("../http/response.zig").Response;
const Handler = @import("../loop/handler.zig").Handler;
const HandlerError = @import("../loop/handler.zig").Error;
