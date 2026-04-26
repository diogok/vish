//! HTTP response handling.

pub const Status = enum(u16) {
    OK = 200,
    Moved_Permanentely = 301,
    Found = 302,
    See_Other = 303,
    Not_Modified = 304,
    Temporary_Redirect = 307,
    Permanent_Redirect = 308,
    Created = 201,
    Accepted = 202,
    No_Content = 204,
    Bad_Request = 400,
    Unauthorized = 401,
    Forbidden = 403,
    Not_Found = 404,
    Method_Not_Allowed = 405,
    Conflict = 409,
    Gone = 410,
    Precondition_Failed = 412,
    Payload_Too_Large = 413,
    Unprocessable_Entity = 422,
    Precondition_Required = 428,
    Too_Many_Requests = 429,
    Internal_Server_Error = 500,
    Service_Unavailable = 503,
    // TODO: rest of standard codes

    pub fn int(self: @This()) u16 {
        return @intFromEnum(self);
    }
};

pub const Connection = enum(u1) {
    keep_alive = 0,
    close = 1,

    pub fn getValue(self: @This()) []const u8 {
        return switch (self) {
            .keep_alive => "keep-alive",
            .close => "close",
        };
    }
};

pub const TransferEncoding = enum(u1) {
    chunked = 0,
    deflate = 1,

    pub fn getValue(self: @This()) []const u8 {
        return @tagName(self);
    }
};

/// A Server-Sent Event with optional id, event type, retry hint, and data.
///
/// Per the HTML Living Standard SSE spec, `data` may contain `\n` to be split
/// across multiple `data:` field lines in the emitted event.
pub const SSEMessage = struct {
    id: ?[]const u8 = null,
    event: ?[]const u8 = null,
    data: []const u8 = "",
    retry_ms: ?u32 = null,
};

pub const ExtraHeader = struct {
    name: []const u8 = "",
    value: []const u8 = "",
};

pub const Headers = struct {
    transfer_encoding: ?TransferEncoding = null,
    content_length: ?usize = null,
    content_type: []const u8 = "",
    cache_control: []const u8 = "",
    connection: ?Connection = null,
    location: []const u8 = "",
    set_cookie: []const u8 = "",

    extra: []const ExtraHeader = &.{},
};

/// HTTP response builder with state tracking for incremental sending.
///
/// The response can be sent in multiple ways:
/// 1. Simple: Set body and call send() - sends everything at once
/// 2. Chunked: Call writeChunk() multiple times, then end()
pub const Response = struct {
    version: request.Version = .HTTP_1_1,

    status: Status = .OK,
    headers: Headers = .{},
    body: []const u8 = "",

    /// True after the status line (e.g., "HTTP/1.1 200 OK\r\n") has been sent
    sent_status: bool = false,
    /// True after all headers have been sent (but before the blank line)
    sent_headers: bool = false,
    /// True after the blank line separating headers from body has been sent
    sent_newline: bool = false,

    buffer: [9]u8 = undefined,

    writer: *std.Io.Writer,

    /// Create a response pre-configured from the request.
    /// Copies the HTTP version and Connection header from the request.
    pub fn fromRequest(src: Request) @This() {
        const conn: ?Connection = if (src.headers.connection) |conn| @enumFromInt(@intFromEnum(conn)) else null;
        return .{
            .version = src.version,
            .headers = .{
                .connection = conn,
            },
            .writer = src.writer,
        };
    }

    pub fn send(self: *@This()) !void {
        try self.sendStatus();
        try self.sendHeaders();
        try self.sendNewline();
        if (self.body.len != 0) {
            try self.sendBody();
        }
    }

    fn sendStatus(
        self: *@This(),
    ) !void {
        var code_txt: [24]u8 = undefined;
        _ = std.mem.replace(u8, @tagName(self.status), "_", " ", &code_txt);
        const code_name = code_txt[0..@tagName(self.status).len];

        try self.writer.print(
            "{s} {d} {s}\r\n",
            .{
                self.version.string(),
                self.status.int(),
                code_name,
            },
        );
        self.sent_status = true;
    }

    fn sendHeaders(
        self: *@This(),
    ) !void {
        // set content-length if not set and we have a string body
        if (self.headers.content_length == null and self.body.len > 0) {
            self.headers.content_length = self.body.len;
        }
        inline for (std.meta.fields(Headers)) |field| {
            const headerName = comptime capitalize(field.name);
            if (field.type == []const u8) {
                if (@field(self.headers, field.name).len > 0) {
                    try self.sendHeader(self.writer, &headerName, @field(self.headers, field.name));
                }
            } else if (field.type == ?Connection) {
                if (@field(self.headers, field.name)) |conn| {
                    try self.sendHeader(self.writer, &headerName, conn.getValue());
                }
            } else if (field.type == ?TransferEncoding) {
                if (@field(self.headers, field.name)) |te| {
                    try self.sendHeader(self.writer, &headerName, te.getValue());
                }
            } else if (field.type == ?usize) {
                if (@field(self.headers, field.name)) |val| {
                    try self.writer.print("{s}: {d}\r\n", .{ &headerName, val });
                }
            }
        }
        for (self.headers.extra) |header| {
            if (header.name.len > 0) {
                try self.writer.print("{s}: {s}\r\n", .{ header.name, header.value });
            }
        }
        self.sent_headers = true;
    }

    fn sendNewline(
        self: *@This(),
    ) !void {
        _ = try self.writer.write("\r\n");
        self.sent_newline = true;
    }

    fn sendHeader(
        _: *@This(),
        writer: *std.Io.Writer,
        header: []const u8,
        value: []const u8,
    ) !void {
        try writer.print("{s}: {s}\r\n", .{ header, value });
    }

    fn sendBody(self: *@This()) !void {
        _ = try self.writer.write(self.body);
    }

    pub fn setContentLength(
        self: *@This(),
        len: usize,
    ) void {
        self.headers.content_length = len;
    }

    pub fn writeChunk(
        self: *@This(),
        chunk: []const u8,
    ) !void {
        if (!self.sent_status) {
            try self.sendStatus();
        }
        if (self.headers.transfer_encoding == null) {
            self.headers.transfer_encoding = .chunked;
            if (!self.sent_headers) {
                try self.sendHeaders();
            }
            if (!self.sent_newline) {
                try self.sendNewline();
            }
        }
        try self.writer.print("{d}\r\n", .{chunk.len});
        _ = try self.writer.write(chunk);
        _ = try self.writer.write("\r\n");
    }

    pub fn end(self: *@This()) !void {
        if (!self.sent_newline) {
            try self.sendNewline();
        }
        if (self.headers.transfer_encoding == .chunked) {
            _ = try self.writer.write("0\r\n\r\n");
        }
    }

    /// Write a Server-Sent Event. Sends status and headers on first call,
    /// setting Content-Type to text/event-stream and Cache-Control to no-cache
    /// if not already set.
    ///
    /// Format: "event: <type>\ndata: <data>\n\n" or "data: <data>\n\n"
    pub fn writeEvent(self: *@This(), event_type: ?[]const u8, data: []const u8) !void {
        if (!self.sent_status) {
            if (self.headers.content_type.len == 0) {
                self.headers.content_type = "text/event-stream";
            }
            if (self.headers.cache_control.len == 0) {
                self.headers.cache_control = "no-cache";
            }
            try self.sendStatus();
            try self.sendHeaders();
            try self.sendNewline();
        }
        if (event_type) |et| {
            try self.writer.print("event: {s}\n", .{et});
        }
        try self.writer.print("data: {s}\n\n", .{data});
    }

    /// Ensure SSE status + headers are sent (once). Sets Content-Type to
    /// text/event-stream and Cache-Control to no-cache if unset.
    fn ensureSSEHeaders(self: *@This()) !void {
        if (self.sent_status) return;
        if (self.headers.content_type.len == 0) {
            self.headers.content_type = "text/event-stream";
        }
        if (self.headers.cache_control.len == 0) {
            self.headers.cache_control = "no-cache";
        }
        try self.sendStatus();
        try self.sendHeaders();
        try self.sendNewline();
    }

    /// Write a Server-Sent Event with optional id, event type, and retry hint.
    /// Multi-line `data` is split on `\n` into multiple `data:` lines per SSE spec.
    /// Auto-sets `Content-Type: text/event-stream` and `Cache-Control: no-cache`
    /// on the first call (like `writeEvent`).
    pub fn writeSSE(self: *@This(), ev: SSEMessage) !void {
        try self.ensureSSEHeaders();

        if (ev.id) |id| {
            try self.writer.print("id: {s}\n", .{id});
        }
        if (ev.event) |event| {
            try self.writer.print("event: {s}\n", .{event});
        }
        if (ev.retry_ms) |retry| {
            try self.writer.print("retry: {d}\n", .{retry});
        }

        if (ev.data.len == 0) {
            _ = try self.writer.write("data:\n");
        } else {
            var it = std.mem.splitScalar(u8, ev.data, '\n');
            while (it.next()) |line| {
                try self.writer.print("data: {s}\n", .{line});
            }
        }

        _ = try self.writer.write("\n");
    }

    /// Emit an SSE comment line (`: <text>\n\n`). Used for heartbeats and debug.
    /// Auto-sets SSE headers on first call. If `text` contains `\n`, each line
    /// after the first is prefixed with a fresh `: `.
    pub fn writeSSEComment(self: *@This(), text: []const u8) !void {
        try self.ensureSSEHeaders();

        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            try self.writer.print(": {s}\n", .{line});
        }

        _ = try self.writer.write("\n");
    }

    /// Flush the underlying writer to ensure data is sent to the client.
    pub fn flush(self: *@This()) !void {
        try self.writer.flush();
    }
};

test "basic response writing" {
    var buffer: [4 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var res = Response{
        .status = .Not_Found,
        .headers = .{ .content_type = "text/plain" },
        .body = "hello",
        .writer = &writer,
    };
    try res.send();

    const content = buffer[0..writer.end];

    try testing.expectEqualStrings("HTTP/1.1 404 Not Found\r\nContent-Length: 5\r\nContent-Type: text/plain\r\n\r\nhello", content);
}

test "chunked response writing" {
    var buffer: [4 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var res = Response{
        .status = .OK,
        .headers = .{ .content_type = "text/plain" },
        .writer = &writer,
    };
    try res.writeChunk("hello");
    try res.end();

    const content = buffer[0..writer.end];

    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: text/plain\r\n\r\n5\r\nhello\r\n0\r\n\r\n", content);
}

fn capitalize(comptime name: []const u8) [name.len]u8 {
    var tmp: [name.len]u8 = undefined;
    var cap = true;
    for (name, 0..) |b, i| {
        if (b == '_') {
            tmp[i] = '-';
            cap = true;
        } else {
            if (cap) {
                tmp[i] = std.ascii.toUpper(b);
                cap = false;
            } else {
                tmp[i] = b;
            }
        }
    }
    return tmp;
}

test "capitalize" {
    try testing.expectEqualStrings("Content-Length", &capitalize("content_length"));
}

test "multiple chunks in chunked response" {
    var buffer: [4 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var res = Response{
        .status = .OK,
        .writer = &writer,
    };
    try res.writeChunk("first");
    try res.writeChunk("second");
    try res.writeChunk("third");
    try res.end();

    const content = buffer[0..writer.end];
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nfirst\r\n6\r\nsecond\r\n5\r\nthird\r\n0\r\n\r\n", content);
}

test "SSE event writing" {
    var buffer: [4 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var res = Response{
        .status = .OK,
        .writer = &writer,
    };
    try res.writeEvent("message", "{\"hello\":\"world\"}");

    const content = buffer[0..writer.end];
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\nevent: message\ndata: {\"hello\":\"world\"}\n\n", content);
}

test "SSE event without event type" {
    var buffer: [4 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var res = Response{
        .status = .OK,
        .writer = &writer,
    };
    try res.writeEvent(null, "{\"data\":1}");

    const content = buffer[0..writer.end];
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\ndata: {\"data\":1}\n\n", content);
}

test "SSE multiple events" {
    var buffer: [4 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var res = Response{
        .status = .OK,
        .writer = &writer,
    };
    try res.writeEvent("message", "first");
    try res.writeEvent("message", "second");

    const content = buffer[0..writer.end];
    try testing.expectEqualStrings("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\nevent: message\ndata: first\n\nevent: message\ndata: second\n\n", content);
}

test "writeSSE with only data emits SSE headers and data line" {
    var buffer: [4 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var res = Response{
        .status = .OK,
        .writer = &writer,
    };
    try res.writeSSE(.{ .data = "hello" });

    const content = buffer[0..writer.end];
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\ndata: hello\n\n",
        content,
    );
}

test "writeSSE with id, event, and data emits fields in spec order" {
    var buffer: [4 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var res = Response{
        .status = .OK,
        .writer = &writer,
    };
    try res.writeSSE(.{ .id = "42", .event = "token", .data = "hi" });

    const content = buffer[0..writer.end];
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\nid: 42\nevent: token\ndata: hi\n\n",
        content,
    );
}

test "writeSSE splits multi-line data into multiple data lines" {
    var buffer: [4 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var res = Response{
        .status = .OK,
        .writer = &writer,
    };
    try res.writeSSE(.{ .data = "line1\nline2" });

    const content = buffer[0..writer.end];
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\ndata: line1\ndata: line2\n\n",
        content,
    );
}

test "writeSSE with empty data emits bare data field" {
    var buffer: [4 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var res = Response{
        .status = .OK,
        .writer = &writer,
    };
    try res.writeSSE(.{});

    const content = buffer[0..writer.end];
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\ndata:\n\n",
        content,
    );
}

test "writeSSE with retry_ms emits retry field" {
    var buffer: [4 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var res = Response{
        .status = .OK,
        .writer = &writer,
    };
    try res.writeSSE(.{ .retry_ms = 5000, .data = "soon" });

    const content = buffer[0..writer.end];
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\nretry: 5000\ndata: soon\n\n",
        content,
    );
}

test "writeSSEComment emits comment line" {
    var buffer: [4 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var res = Response{
        .status = .OK,
        .writer = &writer,
    };
    try res.writeSSEComment("heartbeat");

    const content = buffer[0..writer.end];
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\n: heartbeat\n\n",
        content,
    );
}

test "writeSSEComment with multi-line text prefixes each line" {
    var buffer: [4 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var res = Response{
        .status = .OK,
        .writer = &writer,
    };
    try res.writeSSEComment("first\nsecond\nthird");

    const content = buffer[0..writer.end];
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\n: first\n: second\n: third\n\n",
        content,
    );
}

test "multiple writeSSE and writeSSEComment calls send headers once" {
    var buffer: [4 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var res = Response{
        .status = .OK,
        .writer = &writer,
    };
    try res.writeSSE(.{ .id = "1", .data = "a" });
    try res.writeSSEComment("ping");
    try res.writeSSE(.{ .id = "2", .data = "b" });

    const content = buffer[0..writer.end];
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\n" ++
            "id: 1\ndata: a\n\n" ++
            ": ping\n\n" ++
            "id: 2\ndata: b\n\n",
        content,
    );
}

test "new status codes render correct status line" {
    const cases = [_]struct { status: Status, expected: []const u8 }{
        .{ .status = .Gone, .expected = "HTTP/1.1 410 Gone\r\n\r\n" },
        .{ .status = .Precondition_Failed, .expected = "HTTP/1.1 412 Precondition Failed\r\n\r\n" },
        .{ .status = .Payload_Too_Large, .expected = "HTTP/1.1 413 Payload Too Large\r\n\r\n" },
        .{ .status = .Precondition_Required, .expected = "HTTP/1.1 428 Precondition Required\r\n\r\n" },
        .{ .status = .Service_Unavailable, .expected = "HTTP/1.1 503 Service Unavailable\r\n\r\n" },
    };

    for (cases) |case| {
        var buffer: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        var res = Response{ .status = case.status, .writer = &writer };
        try res.send();
        const content = buffer[0..writer.end];
        try testing.expectEqualStrings(case.expected, content);
    }
}

test "setContentLength updates headers" {
    var buffer: [4 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var res = Response{
        .status = .OK,
        .writer = &writer,
    };
    res.setContentLength(42);

    try testing.expectEqual(@as(?usize, 42), res.headers.content_length);
}

test "empty body response" {
    var buffer: [4 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var res = Response{
        .status = .Not_Modified,
        .writer = &writer,
    };
    try res.send();

    const content = buffer[0..writer.end];
    // 304 responses typically have no body, but blank line is always required
    try testing.expectEqualStrings("HTTP/1.1 304 Not Modified\r\n\r\n", content);
}

const std = @import("std");
const testing = std.testing;

const request = @import("request.zig");
const Request = request.Request;

const log = std.log.scoped(.http);
