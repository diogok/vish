//! HTTP request: method, URI, version, headers, and a streaming
//! `BodyReader` that handles `Content-Length`, chunked
//! `Transfer-Encoding`, and transparent `Content-Encoding: gzip|deflate`.

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
        // HTTP versions are always uppercase per spec - use exact comparison
        if (std.mem.eql(u8, bytes, "HTTP/1.1")) {
            return .HTTP_1_1;
        } else if (std.mem.eql(u8, bytes, "HTTP/1.0")) {
            return .HTTP_1_0;
        } else if (std.mem.eql(u8, bytes, "HTTP/0.9")) {
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
        inline for (std.meta.fields(@This())) |field| {
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

pub const TransferEncoding = enum {
    chunked,

    pub fn parse(bytes: []const u8) ?TransferEncoding {
        inline for (std.meta.fields(@This())) |field| {
            if (std.ascii.eqlIgnoreCase(bytes, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return null;
    }
};

/// HTTP `Content-Encoding` body wrapping. `gzip` maps to RFC 1952 (gzip
/// container); `deflate` maps to RFC 1950 (zlib-wrapped raw deflate).
pub const ContentEncoding = enum(u1) {
    gzip = 0,
    deflate = 1,

    pub fn parse(bytes: []const u8) ?ContentEncoding {
        inline for (std.meta.fields(@This())) |field| {
            if (std.ascii.eqlIgnoreCase(bytes, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return null;
    }

    pub fn container(self: @This()) std.compress.flate.Container {
        return switch (self) {
            .gzip => .gzip,
            .deflate => .zlib,
        };
    }
};

pub const Headers = struct {
    content_length: usize = 0,
    content_type: []const u8 = "",
    authorization: []const u8 = "",
    cookie: []const u8 = "",
    connection: ?Connection = null,
    transfer_encoding: ?TransferEncoding = null,
    content_encoding: ?ContentEncoding = null,
    last_event_id: []const u8 = "",
    if_match: []const u8 = "",
    if_none_match: []const u8 = "",
    accept: []const u8 = "",
    host: []const u8 = "",
    user_agent: []const u8 = "",
    idempotency_key: []const u8 = "",

    /// Arbitrary headers not matched by the typed fields above. Only
    /// populated when `ListenOptions.parse_extra_headers = true`. Keys
    /// are stored lowercased; values are trimmed of leading/trailing
    /// space. Backed by the per-connection arena.
    extras: std.StringHashMapUnmanaged([]const u8) = .{},

    /// True when `Headers.read` was called with `parse_extras = true`.
    /// Used by `get` to assert in debug builds that the caller didn't
    /// forget to enable the flag.
    parsed_extras: bool = false,

    pub fn free(self: @This(), allocator: std.mem.Allocator) void {
        inline for (std.meta.fields(@This())) |field| {
            if (field.type == []const u8) {
                allocator.free(@field(self, field.name));
            }
        }
        // In production `allocator` is an arena (per-connection) and these
        // frees are no-ops; in tests it's the GPA, so they prevent leaks.
        var mut = self.extras;
        var it = mut.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        mut.deinit(allocator);
    }

    /// Look up an arbitrary request header by name (case-insensitive).
    /// Returns `null` if the header is absent or if extras parsing was
    /// not enabled. Pre-parsed fields (Host, Content-Type, etc.) are
    /// NOT mirrored here — read them via the typed field instead.
    pub fn get(self: @This(), name: []const u8) ?[]const u8 {
        std.debug.assert(self.parsed_extras); // enable ListenOptions.parse_extra_headers
        var buf: [128]u8 = undefined;
        if (name.len > buf.len) return null;
        const lower = std.ascii.lowerString(buf[0..name.len], name);
        return self.extras.get(lower);
    }

    pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader, parse_extras: bool) !Headers {
        var target = Headers{ .parsed_extras = parse_extras };

        while (true) {
            const maybe_line = try reader.takeDelimiter('\n');
            if (maybe_line == null) {
                @branchHint(.unlikely);
                continue;
            }
            const line = maybe_line.?;

            if (line.len == 1) {
                // last header line (just \r)
                break;
            }

            const maybe_separator = std.mem.indexOfScalar(u8, line, ':');
            if (maybe_separator == null) {
                @branchHint(.unlikely);
                continue;
            }
            const separator_pos = maybe_separator.?;

            const key = line[0..separator_pos];
            const value = line[separator_pos + 1 .. line.len - 1];

            // comptime check each field of header using case-insensitive compare
            // with length check to short-circuit early
            var matched = false;
            inline for (std.meta.fields(Headers)) |field| {
                // Skip the extras map and the parsed_extras flag — they aren't HTTP headers.
                if (comptime (!std.mem.eql(u8, field.name, "extras") and
                    !std.mem.eql(u8, field.name, "parsed_extras")))
                {
                    // Convert field name from snake_case to kebab-case at comptime
                    const header_name = comptime blk: {
                        var buf: [field.name.len]u8 = undefined;
                        _ = std.mem.replace(u8, field.name, "_", "-", &buf);
                        break :blk buf;
                    };
                    // Length check first for fast rejection
                    if (key.len == header_name.len and std.ascii.eqlIgnoreCase(key, &header_name)) {
                        const clean_value = std.mem.trim(u8, value, " ");
                        if (field.type == []const u8) {
                            @field(target, field.name) = try allocator.dupe(u8, clean_value);
                        } else if (field.type == ?Connection) {
                            @field(target, field.name) = Connection.parse(clean_value);
                        } else if (field.type == ?TransferEncoding) {
                            @field(target, field.name) = TransferEncoding.parse(clean_value);
                        } else if (field.type == ?ContentEncoding) {
                            @field(target, field.name) = ContentEncoding.parse(clean_value);
                        } else if (field.type == usize) {
                            @field(target, field.name) = std.fmt.parseInt(usize, clean_value, 10) catch 0;
                        }
                        matched = true;
                    }
                }
            }

            if (!matched and parse_extras and key.len > 0) {
                const lower_key = try allocator.alloc(u8, key.len);
                _ = std.ascii.lowerString(lower_key, key);
                const dup_value = try allocator.dupe(u8, std.mem.trim(u8, value, " "));
                try target.extras.put(allocator, lower_key, dup_value);
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

    /// Per-request parsing options. New knobs (header limits, body
    /// limits, etc.) get added here without changing the call site.
    pub const Options = struct {
        /// When true, request headers not matched by the pre-parsed
        /// `Headers` fields are stored in `Headers.extras` and queryable
        /// via `Headers.get(name)`. Default false: arbitrary headers
        /// are discarded, saving a per-non-pre-parsed-header lowercase
        /// alloc and hashmap put.
        parse_extra_headers: bool = false,
    };

    pub fn read(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        options: Options,
    ) !@This() {
        const method = try Method.read(reader);

        const uri = try URI.read(allocator, reader);
        errdefer allocator.free(uri.path);
        errdefer allocator.free(uri.query);

        const version = try Version.read(reader);

        const headers = try Headers.read(allocator, reader, options.parse_extra_headers);
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

    pub fn bodyReader(self: @This(), buffer: []u8) !BodyReader {
        return BodyReader.init(self.allocator, self.headers, self.reader, buffer);
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

    const req = try Request.read(testing.allocator, &reader, &writer.writer, .{});
    defer req.deinit();

    try testing.expectEqual(req.method, .POST);
    try testing.expectEqualStrings("/foo/bar", req.uri.path);
    try testing.expectEqualStrings("fuz=baz", req.uri.query);
    try testing.expectEqualStrings("application/form-data", req.headers.content_type);
    try testing.expectEqual(9, req.headers.content_length);

    var body_reader = try req.bodyReader(&[0]u8{});
    var b_reader = body_reader.interface();
    const body = try b_reader.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("key=value", body);
}

test "Parse http request without body" {
    const request = "POST /foo/bar?fuz=baz HTTP/1.1\r\nContent-Type: application/form-data\r\nContent-Length: 0 \r\n\r\n";

    var reader = std.Io.Reader.fixed(request);
    var writer = std.Io.Writer.Discarding.init(&[_]u8{});

    const req = try Request.read(testing.allocator, &reader, &writer.writer, .{});
    defer req.deinit();

    try testing.expectEqual(req.method, .POST);
    try testing.expectEqualStrings("/foo/bar", req.uri.path);
    try testing.expectEqualStrings("fuz=baz", req.uri.query);
    try testing.expectEqualStrings("application/form-data", req.headers.content_type);
    try testing.expectEqual(0, req.headers.content_length);

    var body_reader = try req.bodyReader(&[0]u8{});
    var b_reader = body_reader.interface();
    const body = try b_reader.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("", body);
}

test "Parse http request without headers, body" {
    const request = "POST /foo/bar?fuz=baz HTTP/1.1\r\n\r\n";

    var reader = std.Io.Reader.fixed(request);
    var writer = std.Io.Writer.Discarding.init(&[_]u8{});

    const req = try Request.read(testing.allocator, &reader, &writer.writer, .{});
    defer req.deinit();

    try testing.expectEqual(req.method, .POST);
    try testing.expectEqualStrings("/foo/bar", req.uri.path);
    try testing.expectEqualStrings("fuz=baz", req.uri.query);
    try testing.expectEqualStrings("", req.headers.content_type);
    try testing.expectEqual(0, req.headers.content_length);

    var body_reader = try req.bodyReader(&[0]u8{});
    var b_reader = body_reader.interface();
    const body = try b_reader.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("", body);
}

test "Parse http request without headers, body and qs" {
    const request = "POST /foo/bar HTTP/1.1\r\n\r\n";

    var reader = std.Io.Reader.fixed(request);
    var writer = std.Io.Writer.Discarding.init(&[_]u8{});

    const req = try Request.read(testing.allocator, &reader, &writer.writer, .{});
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

    const req = try Request.read(testing.allocator, &reader, &writer.writer, .{});
    defer req.deinit();

    try testing.expectEqual(req.method, .POST);
    try testing.expectEqualStrings("/", req.uri.path);
    try testing.expectEqual(.chunked, req.headers.transfer_encoding.?);

    var body_reader = try req.bodyReader(&[0]u8{});
    var b_reader = body_reader.interface();
    const body = try b_reader.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("key=value", body);
}

test "Parse http request with extended headers" {
    const request =
        "GET /stream HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "User-Agent: test-agent/1.0\r\n" ++
        "Accept: text/event-stream\r\n" ++
        "Last-Event-ID: 42\r\n" ++
        "If-Match: \"etag-one\"\r\n" ++
        "If-None-Match: \"etag-two\"\r\n" ++
        "Idempotency-Key: abc-123\r\n" ++
        "\r\n";

    var reader = std.Io.Reader.fixed(request);
    var writer = std.Io.Writer.Discarding.init(&[_]u8{});

    const req = try Request.read(testing.allocator, &reader, &writer.writer, .{});
    defer req.deinit();

    try testing.expectEqualStrings("example.com", req.headers.host);
    try testing.expectEqualStrings("test-agent/1.0", req.headers.user_agent);
    try testing.expectEqualStrings("text/event-stream", req.headers.accept);
    try testing.expectEqualStrings("42", req.headers.last_event_id);
    try testing.expectEqualStrings("\"etag-one\"", req.headers.if_match);
    try testing.expectEqualStrings("\"etag-two\"", req.headers.if_none_match);
    try testing.expectEqualStrings("abc-123", req.headers.idempotency_key);
}

test "extras: arbitrary headers populated when parse_extras=true" {
    const request =
        "GET /x HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "X-Request-ID: abc-123\r\n" ++
        "X-Forwarded-For: 1.2.3.4\r\n" ++
        "\r\n";

    var reader = std.Io.Reader.fixed(request);
    var writer = std.Io.Writer.Discarding.init(&[_]u8{});

    const req = try Request.read(testing.allocator, &reader, &writer.writer, .{ .parse_extra_headers = true });
    defer req.deinit();

    // Case-insensitive lookup
    try testing.expectEqualStrings("abc-123", req.headers.get("x-request-id").?);
    try testing.expectEqualStrings("abc-123", req.headers.get("X-Request-ID").?);
    try testing.expectEqualStrings("1.2.3.4", req.headers.get("X-Forwarded-For").?);

    // Pre-parsed fields are NOT mirrored into extras
    try testing.expectEqual(@as(?[]const u8, null), req.headers.get("host"));

    // Missing header returns null
    try testing.expectEqual(@as(?[]const u8, null), req.headers.get("X-Missing"));
}

test "extras: empty when parse_extras=false even with custom headers" {
    const request =
        "GET /x HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "X-Request-ID: abc-123\r\n" ++
        "X-Forwarded-For: 1.2.3.4\r\n" ++
        "\r\n";

    var reader = std.Io.Reader.fixed(request);
    var writer = std.Io.Writer.Discarding.init(&[_]u8{});

    const req = try Request.read(testing.allocator, &reader, &writer.writer, .{});
    defer req.deinit();

    try testing.expectEqual(@as(usize, 0), req.headers.extras.count());
    try testing.expectEqualStrings("example.com", req.headers.host);
}

test "extras: empty when parse_extras=true and only pre-parsed headers present" {
    const request =
        "GET /x HTTP/1.1\r\n" ++
        "Host: example.com\r\n" ++
        "Accept: text/html\r\n" ++
        "\r\n";

    var reader = std.Io.Reader.fixed(request);
    var writer = std.Io.Writer.Discarding.init(&[_]u8{});

    const req = try Request.read(testing.allocator, &reader, &writer.writer, .{ .parse_extra_headers = true });
    defer req.deinit();

    try testing.expectEqual(@as(usize, 0), req.headers.extras.count());
}

test "Parse chunked body with hex chunk sizes" {
    // Chunk sizes in HTTP are hexadecimal per RFC 7230 §4.1
    // 'a' = 10 bytes, '5' = 5 bytes
    const request = "POST / HTTP/1.1\r\nTransfer-Encoding: chunked \r\n\r\na\r\n0123456789\r\n5\r\nabcde\r\n0\r\n\r\n";

    var reader = std.Io.Reader.fixed(request);
    var writer = std.Io.Writer.Discarding.init(&[_]u8{});

    const req = try Request.read(testing.allocator, &reader, &writer.writer, .{});
    defer req.deinit();

    var body_reader = try req.bodyReader(&[0]u8{});
    var b_reader = body_reader.interface();
    const body = try b_reader.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("0123456789abcde", body);
}

fn buildEncodedRequest(
    allocator: std.mem.Allocator,
    plaintext: []const u8,
    container: std.compress.flate.Container,
    encoding_header: []const u8,
) ![]u8 {
    const cbuf = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(cbuf);

    // Compress.init asserts output.buffer.len > 8.
    var sink = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer sink.deinit();
    var compressor = try std.compress.flate.Compress.init(&sink.writer, cbuf, container, .default);
    try compressor.writer.writeAll(plaintext);
    try compressor.finish();
    const compressed = sink.written();

    var out = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    errdefer out.deinit();
    try out.writer.print(
        "POST /upload HTTP/1.1\r\nContent-Length: {d}\r\nContent-Encoding: {s}\r\n\r\n",
        .{ compressed.len, encoding_header },
    );
    try out.writer.writeAll(compressed);
    return out.toOwnedSlice();
}

test "Request body decompresses Content-Encoding: gzip" {
    const plaintext = "Hello, world! This is a test of gzip decompression over HTTP.";
    const request_bytes = try buildEncodedRequest(testing.allocator, plaintext, .gzip, "gzip");
    defer testing.allocator.free(request_bytes);

    var reader = std.Io.Reader.fixed(request_bytes);
    var writer = std.Io.Writer.Discarding.init(&[_]u8{});
    const req = try Request.read(testing.allocator, &reader, &writer.writer, .{});
    defer req.deinit();

    try testing.expectEqual(ContentEncoding.gzip, req.headers.content_encoding.?);

    var body_reader = try req.bodyReader(&[0]u8{});
    defer body_reader.deinit();
    var b_reader = body_reader.interface();
    const body = try b_reader.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(plaintext, body);
}

test "Request body decompresses Content-Encoding: deflate" {
    const plaintext = "deflate (zlib-wrapped) request bodies should round-trip back to plaintext.";
    // HTTP "deflate" is RFC 1950 zlib-wrapped raw deflate.
    const request_bytes = try buildEncodedRequest(testing.allocator, plaintext, .zlib, "deflate");
    defer testing.allocator.free(request_bytes);

    var reader = std.Io.Reader.fixed(request_bytes);
    var writer = std.Io.Writer.Discarding.init(&[_]u8{});
    const req = try Request.read(testing.allocator, &reader, &writer.writer, .{});
    defer req.deinit();

    try testing.expectEqual(ContentEncoding.deflate, req.headers.content_encoding.?);

    var body_reader = try req.bodyReader(&[0]u8{});
    defer body_reader.deinit();
    var b_reader = body_reader.interface();
    const body = try b_reader.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(plaintext, body);
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
/// When the request carries `Content-Encoding: gzip|deflate`, `interface()` lazily
/// wraps the inner stream in a `flate.Decompress` so handlers always see plaintext.
pub const BodyReader = struct {
    reader: *std.Io.Reader,

    limited_reader: std.Io.Reader.Limited,

    chunked: bool = false,
    chunked_interface: std.Io.Reader,
    chunk: []u8 = "",
    pos: usize = 0,

    encoding: ?ContentEncoding = null,
    decompress_buffer: []u8 = &.{},
    decompress: std.compress.flate.Decompress = undefined,
    decompress_initialized: bool = false,

    /// Set when `init` allocated a dedicated inner buffer (because an
    /// encoding is present). Empty when the user-supplied buffer is used.
    owned_inner_buffer: []u8 = &.{},
    allocator: ?std.mem.Allocator = null,

    pub fn init(
        allocator: std.mem.Allocator,
        headers: Headers,
        reader: *std.Io.Reader,
        buffer: []u8,
    ) !@This() {
        const has_encoding = headers.content_encoding != null;

        // Decompress peeks bits from its source reader, requiring
        // `source.buffer.len >= peek_size`. The user-supplied `buffer`
        // may be empty (some callers pass `&[0]u8{}`), so when an
        // encoding is present we allocate a dedicated inner buffer.
        const inner_buffer: []u8 = if (has_encoding)
            try allocator.alloc(u8, 4 * 1024)
        else
            buffer;

        const limited_reader = std.Io.Reader.Limited.init(
            reader,
            .limited(headers.content_length),
            inner_buffer,
        );

        const chunked = headers.transfer_encoding == .chunked;

        // 64 KB is the minimum required by std.compress.flate.Decompress
        // (max_window_len). Allocated only when the request body is encoded.
        const decompress_buffer: []u8 = if (has_encoding)
            try allocator.alloc(u8, std.compress.flate.max_window_len)
        else
            &.{};

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
                .buffer = inner_buffer,
            },

            .encoding = headers.content_encoding,
            .decompress_buffer = decompress_buffer,
            .owned_inner_buffer = if (has_encoding) inner_buffer else &.{},
            .allocator = if (has_encoding) allocator else null,
        };
    }

    /// Free buffers allocated by `init`. No-op when no encoding was
    /// present, or when the allocator is an arena (arena `free` is a
    /// no-op). Always safe to call.
    pub fn deinit(self: *@This()) void {
        if (self.allocator) |a| {
            if (self.owned_inner_buffer.len > 0) a.free(self.owned_inner_buffer);
            if (self.decompress_buffer.len > 0) a.free(self.decompress_buffer);
        }
    }

    pub fn interface(self: *@This()) *std.Io.Reader {
        const inner: *std.Io.Reader = if (!self.chunked)
            &self.limited_reader.interface
        else
            &self.chunked_interface;

        const enc = self.encoding orelse return inner;

        if (!self.decompress_initialized) {
            self.decompress = std.compress.flate.Decompress.init(
                inner,
                enc.container(),
                self.decompress_buffer,
            );
            self.decompress_initialized = true;
        }
        return &self.decompress.reader;
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

const log = std.log.scoped(.vish);
