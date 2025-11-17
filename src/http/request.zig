pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,

    pub fn read(reader: *std.Io.Reader) !Method {
        const bytes0 = try reader.takeDelimiter(' ');
        if (bytes0) |bytes| {
            return @This().parse(bytes);
        } else {
            return error.NoData;
        }
    }

    pub fn parse(bytes: []const u8) !Method {
        if (std.mem.eql(u8, bytes, "GET")) {
            return .GET;
        } else if (std.mem.eql(u8, bytes, "POST")) {
            return .POST;
        } else if (std.mem.eql(u8, bytes, "PUT")) {
            return .PUT;
        } else if (std.mem.eql(u8, bytes, "DELETE")) {
            return .DELETE;
        } else if (std.mem.eql(u8, bytes, "PATCH")) {
            return .PATCH;
        } else {
            log.err("Invalid method: {s}", .{bytes});
            return error.InvalidHTTPMethod;
        }
    }

    pub fn string(self: @This()) []const u8 {
        return @tagName(self);
    }
};

pub const URI = struct {
    path: []const u8 = "",
    query: []const u8 = "",

    pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader) !URI {
        const bytes0 = try reader.takeDelimiter(' ');
        if (bytes0) |bytes| {
            return @This().parse(allocator, bytes);
        } else {
            return error.InvalidURI;
        }
    }
    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !URI {
        if (std.mem.indexOfScalar(u8, bytes, '?')) |query_start| {
            const path = try allocator.dupe(u8, bytes[0..query_start]);
            const query = try allocator.dupe(u8, bytes[query_start + 1 .. bytes.len]);
            return .{ .path = path, .query = query };
        } else {
            const path = try allocator.dupe(u8, bytes);
            return .{ .path = path };
        }
    }
};

pub const Version = enum {
    HTTP_0_9,
    HTTP_1_0,
    HTTP_1_1,

    pub fn read(reader: *std.Io.Reader) !Version {
        const bytes0 = try reader.takeDelimiter('\n');
        if (bytes0) |bytes| {
            return @This().parse(bytes[0 .. bytes.len - 1]);
        } else {
            return error.InvalidHTTPVersion;
        }
    }

    pub fn parse(bytes: []const u8) !Version {
        if (std.ascii.eqlIgnoreCase(bytes, "HTTP/1.1")) {
            return .HTTP_1_1;
        } else if (std.ascii.eqlIgnoreCase(bytes, "HTTP/1.0")) {
            return .HTTP_1_0;
        } else if (std.ascii.eqlIgnoreCase(bytes, "HTTP/0.9")) {
            return .HTTP_0_9;
        } else {
            log.err("Invalid HTTP version: {s}", .{bytes});
            return error.InvalidHTTPVersion;
        }
    }

    pub fn string(self: @This()) []const u8 {
        switch (self) {
            .HTTP_1_1 => {
                return "HTTP/1.1";
            },
            .HTTP_0_9 => {
                return "HTTP/1.0";
            },
            .HTTP_1_0 => {
                return "HTTP/0.9";
            },
        }
    }
};

pub const Headers = struct { // how to make customizable?
    transfer_encoding: []const u8 = "", // make it enum
    content_length: []const u8 = "", // make it usize
    content_type: []const u8 = "",
    connection: []const u8 = "", // make it enum
    location: []const u8 = "",
    accept: []const u8 = "",

    // maybe add a map for non stantard headers?

    pub fn free(self: @This(), allocator: std.mem.Allocator) void {
        inline for (std.meta.fields(@This())) |field| {
            allocator.free(@field(self, field.name));
        }
    }

    pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Headers {
        var target = Headers{};
        // TODO: config max line?
        var line_buffer: [256]u8 = undefined;

        while (true) {
            const maybe_line = try reader.takeDelimiter('\n');
            if (maybe_line == null) {
                @branchHint(.unlikely);
                continue;
            }

            // somehow I can't just use maybe_line
            std.mem.copyForwards(u8, &line_buffer, maybe_line.?);
            var line = line_buffer[0..maybe_line.?.len];

            if (line.len == 1) {
                // last header line
                break;
            }

            const maybe_separator = std.mem.indexOfScalar(u8, line, ':');
            if (maybe_separator == null) {
                @branchHint(.unlikely);
                continue;
            }
            const separator_pos = maybe_separator.?;

            const key: []u8 = line[0..separator_pos];
            const value: []u8 = line[separator_pos + 1 .. line.len - 1];
            for (key, 0..) |b, i| {
                if (b == '-') {
                    key[i] = '_';
                } else {
                    key[i] = std.ascii.toLower(b);
                }
            }

            inline for (std.meta.fields(Headers)) |field| {
                if (std.mem.eql(u8, field.name, key)) {
                    const clean_value = std.mem.trim(u8, value, " ");
                    @field(target, field.name) = try allocator.dupe(u8, clean_value);
                }
            }
        }

        return target;
    }
};

pub const Request = struct {
    method: Method,
    uri: URI,
    version: Version,
    headers: Headers,
    body: []const u8,

    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,

    pub fn read(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
    ) !@This() {
        const method = try Method.read(reader);

        const uri = try URI.read(allocator, reader);
        errdefer allocator.free(uri.path);
        errdefer allocator.free(uri.query);

        const version = try Version.read(reader);

        const headers = try Headers.read(allocator, reader);
        errdefer headers.free(allocator);

        //const body = try readBody(allocator, reader, headers, 9999);
        //errdefer allocator.free(body);

        return .{
            .version = version,
            .method = method,
            .uri = uri,
            .headers = headers,
            .body = "",

            .reader = reader,
            .writer = writer,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: @This()) void {
        self.allocator.free(self.body);
        self.allocator.free(self.uri.path);
        self.allocator.free(self.uri.query);

        self.headers.free(self.allocator);
    }

    pub const example: Request = .{
        .version = .HTTP_1_1,
        .method = .GET,
        .uri = .{
            .path = "/",
        },
        .headers = .{},
        .body = "",
        .reader = .ending,
        .writer = &discarding.writer,
        .allocator = testing.allocator,
    };
};

var discarding = std.Io.Writer.Discarding.init(&[_]u8{});

test "Parse basic http request with body" {
    const request = "POST /foo/bar?fuz=baz HTTP/1.1\r\nContent-Type: application/form-data\r\nContent-Length: 9 \r\n\r\nkey=value";

    var reader = std.Io.Reader.fixed(request);
    var writer = std.Io.Writer.Discarding.init(&[_]u8{});

    const req = try Request.read(testing.allocator, &reader, &writer.writer);
    defer req.deinit();

    try testing.expectEqual(req.method, .POST);
    try testing.expectEqualStrings("/foo/bar", req.uri.path);
    try testing.expectEqualStrings("fuz=baz", req.uri.query);
    try testing.expectEqualStrings("application/form-data", req.headers.content_type);
    try testing.expectEqualStrings("9", req.headers.content_length);
    //try testing.expectEqualStrings("key=value", req.body);
}

test "Parse http request without body" {
    const request = "POST /foo/bar?fuz=baz HTTP/1.1\r\nContent-Type: application/form-data\r\nContent-Length: 0 \r\n\r\n";

    var reader = std.Io.Reader.fixed(request);
    var writer = std.Io.Writer.Discarding.init(&[_]u8{});

    const req = try Request.read(testing.allocator, &reader, &writer.writer);
    defer req.deinit();

    try testing.expectEqual(req.method, .POST);
    try testing.expectEqualStrings("/foo/bar", req.uri.path);
    try testing.expectEqualStrings("fuz=baz", req.uri.query);
    try testing.expectEqualStrings("application/form-data", req.headers.content_type);
    try testing.expectEqualStrings("0", req.headers.content_length);
    try testing.expectEqualStrings("", req.body);
}

test "Parse http request without headers, body" {
    const request = "POST /foo/bar?fuz=baz HTTP/1.1\r\n\r\n";

    var reader = std.Io.Reader.fixed(request);
    var writer = std.Io.Writer.Discarding.init(&[_]u8{});

    const req = try Request.read(testing.allocator, &reader, &writer.writer);
    defer req.deinit();

    try testing.expectEqual(req.method, .POST);
    try testing.expectEqualStrings("/foo/bar", req.uri.path);
    try testing.expectEqualStrings("fuz=baz", req.uri.query);
    try testing.expectEqualStrings("", req.headers.content_type);
    try testing.expectEqualStrings("", req.headers.content_length);
    try testing.expectEqualStrings("", req.body);
}

test "Parse http request without headers, body and qs" {
    const request = "POST /foo/bar HTTP/1.1\r\n\r\n";

    var reader = std.Io.Reader.fixed(request);
    var writer = std.Io.Writer.Discarding.init(&[_]u8{});

    const req = try Request.read(testing.allocator, &reader, &writer.writer);
    defer req.deinit();

    try testing.expectEqual(req.method, .POST);
    try testing.expectEqualStrings("/foo/bar", req.uri.path);
    try testing.expectEqualStrings("", req.uri.query);
    try testing.expectEqualStrings("", req.headers.content_type);
    try testing.expectEqualStrings("", req.headers.content_length);
    try testing.expectEqualStrings("", req.body);
}

const std = @import("std");
const testing = std.testing;

const log = std.log.scoped(.http);
