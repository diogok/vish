//! HTTP request handling.

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
                return "HTTP/0.9";
            },
            .HTTP_1_0 => {
                return "HTTP/1.0";
            },
        }
    }
};

pub const Connection = enum(u1) {
    keep_alive = 0,
    close = 1,

    pub fn parse(bytes: []const u8) ?Connection {
        // comptime loop for each possible value in the enum
        inline for (std.meta.fields(@This())) |field| {
            // convert from _ to -
            const name = comptime blk: {
                var buf: [field.name.len]u8 = undefined;
                _ = std.mem.replace(u8, field.name, "_", "-", &buf);
                break :blk buf;
            };
            if (std.ascii.eqlIgnoreCase(bytes, &name)) {
                return @enumFromInt(field.value);
            }
        }
        return null;
    }
};

pub const TransferEncoding = enum(u1) {
    chunked = 0,
    deflate = 1,

    pub fn parse(bytes: []const u8) ?TransferEncoding {
        // comptime loop for each possible value in the enum
        inline for (std.meta.fields(@This())) |field| {
            if (std.ascii.eqlIgnoreCase(bytes, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return null;
    }
};

pub const Headers = struct {
    content_length: usize = 0,
    content_type: []const u8 = "",
    connection: ?Connection = null,
    transfer_encoding: ?TransferEncoding = null,

    // TODO: maybe add an optional hashmap for rest of headers

    pub fn free(self: @This(), allocator: std.mem.Allocator) void {
        inline for (std.meta.fields(@This())) |field| {
            if (field.type == []const u8) {
                allocator.free(@field(self, field.name));
            }
        }
    }

    pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Headers {
        var target = Headers{};
        // TODO: config max header line length
        var line_buffer: [4096]u8 = undefined;

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

            // comptime check each field of header
            inline for (std.meta.fields(Headers)) |field| {
                if (std.mem.eql(u8, field.name, key)) {
                    const clean_value = std.mem.trim(u8, value, " ");
                    if (field.type == []const u8) {
                        @field(target, field.name) = try allocator.dupe(u8, clean_value);
                    } else if (field.type == ?Connection) {
                        @field(target, field.name) = Connection.parse(clean_value);
                    } else if (field.type == ?TransferEncoding) {
                        @field(target, field.name) = TransferEncoding.parse(clean_value);
                    } else if (field.type == usize) {
                        @field(target, field.name) = std.fmt.parseInt(usize, clean_value, 10) catch 0;
                    }
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

        return .{
            .version = version,
            .method = method,
            .uri = uri,
            .headers = headers,

            .reader = reader,
            .writer = writer,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: @This()) void {
        self.allocator.free(self.uri.path);
        self.allocator.free(self.uri.query);
        self.headers.free(self.allocator);
    }

    pub fn bodyReader(self: @This(), buffer: []u8) BodyReader {
        return BodyReader.init(self.headers, self.reader, buffer);
    }

    pub const example: Request = .{
        .version = .HTTP_1_1,
        .method = .GET,
        .uri = .{
            .path = "/",
        },
        .headers = .{},
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
    try testing.expectEqual(9, req.headers.content_length);

    var body_reader = req.bodyReader(&[0]u8{});
    var b_reader = body_reader.interface();
    const body = try b_reader.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("key=value", body);
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
    try testing.expectEqual(0, req.headers.content_length);

    var body_reader = req.bodyReader(&[0]u8{});
    var b_reader = body_reader.interface();
    const body = try b_reader.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("", body);
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
    try testing.expectEqual(0, req.headers.content_length);

    var body_reader = req.bodyReader(&[0]u8{});
    var b_reader = body_reader.interface();
    const body = try b_reader.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("", body);
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
    try testing.expectEqual(0, req.headers.content_length);
}

test "Parse http request with chunked body" {
    const request = "POST / HTTP/1.1\r\nContent-Type: application/form-data\r\nTransfer-Encoding: chunked \r\n\r\n4\r\nkey=\r\n5\r\nvalue\r\n0\r\n\r\n";

    var reader = std.Io.Reader.fixed(request);
    var writer = std.Io.Writer.Discarding.init(&[_]u8{});

    const req = try Request.read(testing.allocator, &reader, &writer.writer);
    defer req.deinit();

    try testing.expectEqual(req.method, .POST);
    try testing.expectEqualStrings("/", req.uri.path);
    try testing.expectEqual(.chunked, req.headers.transfer_encoding.?);

    var body_reader = req.bodyReader(&[0]u8{});
    var b_reader = body_reader.interface();
    const body = try b_reader.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("key=value", body);
}

test "Parse chunked body with hex chunk sizes" {
    // Chunk sizes in HTTP are hexadecimal per RFC 7230 §4.1
    // 'a' = 10 bytes, '5' = 5 bytes
    const request = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked \r\n\r\na\r\n0123456789\r\n5\r\nabcde\r\n0\r\n\r\n";

    var reader = std.Io.Reader.fixed(request);
    var writer = std.Io.Writer.Discarding.init(&[_]u8{});

    const req = try Request.read(testing.allocator, &reader, &writer.writer);
    defer req.deinit();

    var body_reader = req.bodyReader(&[0]u8{});
    var b_reader = body_reader.interface();
    const body = try b_reader.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("0123456789abcde", body);
}



test "URI.parse() handles various path formats" {
    // Path with query
    const uri1 = try URI.parse(testing.allocator, "/path?query=value");
    defer testing.allocator.free(uri1.path);
    defer testing.allocator.free(uri1.query);
    try testing.expectEqualStrings("/path", uri1.path);
    try testing.expectEqualStrings("query=value", uri1.query);

    // Path without query
    const uri2 = try URI.parse(testing.allocator, "/path/to/resource");
    defer testing.allocator.free(uri2.path);
    try testing.expectEqualStrings("/path/to/resource", uri2.path);
    try testing.expectEqualStrings("", uri2.query);

    // Root path
    const uri3 = try URI.parse(testing.allocator, "/");
    defer testing.allocator.free(uri3.path);
    try testing.expectEqualStrings("/", uri3.path);

    // Path with empty query
    const uri4 = try URI.parse(testing.allocator, "/path?");
    defer testing.allocator.free(uri4.path);
    defer testing.allocator.free(uri4.query);
    try testing.expectEqualStrings("/path", uri4.path);
    try testing.expectEqualStrings("", uri4.query);
}


/// A streaming body reader that handles both Content-Length and chunked Transfer-Encoding.
pub const BodyReader = struct {
    reader: *std.Io.Reader,

    limited_reader: std.Io.Reader.Limited,

    chunked: bool = false,
    chunked_interface: std.Io.Reader,
    chunk: []u8 = "",
    pos: usize = 0,

    pub fn init(headers: Headers, reader: *std.Io.Reader, buffer: []u8) @This() {
        const limited_reader = std.Io.Reader.Limited.init(
            reader,
            .limited(headers.content_length),
            buffer,
        );

        const chunked = headers.transfer_encoding == .chunked;

        return @This(){
            .reader = reader,

            .limited_reader = limited_reader,

            .chunked = chunked,
            .chunked_interface = .{
                .vtable = &.{
                    .stream = @This().streamChunked,
                },
                .end = 0,
                .seek = 0,
                .buffer = buffer,
            },
        };
    }

    pub fn interface(self: *@This()) *std.Io.Reader {
        if (!self.chunked) {
            return &self.limited_reader.interface;
        } else {
            return &self.chunked_interface;
        }
    }

    fn readChunk(self: *@This()) std.Io.Reader.Error!void {
        const line0 = self.reader.takeDelimiter('\n') catch return error.ReadFailed;
        if (line0 == null or line0.?.len == 1) {
            return error.EndOfStream;
        }
        const len = std.fmt.parseInt(usize, line0.?[0 .. line0.?.len - 1], 16) catch 0;
        if (len == 0) {
            self.reader.toss(2); // \r\n
            return error.EndOfStream;
        }
        self.chunk = try self.reader.take(len);
        self.reader.toss(2); // \r\n
        self.pos = 0;
    }

    fn streamChunked(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *@This() = @alignCast(@fieldParentPtr("chunked_interface", reader));

        if (self.pos == self.chunk.len) {
            try self.readChunk();
        }

        const wrote = try writer.write(limit.slice(self.chunk[self.pos..]));
        self.pos += wrote;

        return wrote;
    }
};

const std = @import("std");
const testing = std.testing;

const log = std.log.scoped(.http);
