//! `multipart/form-data` parser (RFC 7578). The body is parsed in
//! place: parts reference slices of the buffer they were parsed from,
//! so nothing is copied and the caller owns one allocation — the body
//! itself. Read the body first (`Request.bodyReader` with whatever cap
//! the route enforces), then iterate:
//!
//! ```zig
//! const body = try reader.allocRemaining(req.allocator, .limited(cap));
//! const boundary = multipart.boundary(req.headers.content_type) orelse
//!     return error.BadRequest;
//! var parts = multipart.iterate(body, boundary);
//! while (parts.next()) |part| {
//!     // part.name, part.filename, part.content_type, part.body
//! }
//! ```

/// One part of the body. Every slice points into the parsed buffer.
pub const Part = struct {
    /// The `name` the form gave the field.
    name: []const u8,
    /// The client's file name, or null for a plain field. Sent by the
    /// client, so treat it like any other untrusted input — it can hold
    /// path separators and worse.
    filename: ?[]const u8 = null,
    /// The part's `Content-Type`, or empty when the part has none.
    content_type: []const u8 = "",
    body: []const u8,
};

/// The `boundary` parameter of a `multipart/form-data` content type, or
/// null when `content_type` is not multipart or names no boundary.
pub fn boundary(content_type: []const u8) ?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(content_type, "multipart/form-data")) return null;

    var params = std.mem.splitScalar(u8, content_type, ';');
    _ = params.next(); // the media type itself
    while (params.next()) |param| {
        const trimmed = std.mem.trim(u8, param, " \t");
        const value = valueOf(trimmed, "boundary") orelse continue;
        if (value.len == 0 or value.len > 70) return null; // RFC 2046 cap
        return value;
    }
    return null;
}

pub fn iterate(body: []const u8, boundary_value: []const u8) Iterator {
    return .{ .body = body, .boundary = boundary_value };
}

pub const Iterator = struct {
    body: []const u8,
    boundary: []const u8,
    /// Byte offset of the next delimiter search. Starts at 0: the first
    /// delimiter has no preceding CRLF requirement, and any preamble
    /// before it is skipped as RFC 2046 allows.
    pos: usize = 0,
    done: bool = false,

    /// The next part, or null at the closing delimiter. A malformed
    /// body — no closing delimiter, a part without headers — yields the
    /// parts before the damage and then null.
    pub fn next(self: *Iterator) ?Part {
        while (!self.done) {
            const part_start = self.startOfNextPart() orelse return null;

            // Headers run to the blank line; the body runs from there
            // to the next delimiter.
            const headers_end = std.mem.indexOfPos(u8, self.body, part_start, "\r\n\r\n") orelse {
                self.done = true;
                return null;
            };
            const content_start = headers_end + "\r\n\r\n".len;
            const content_end = self.findDelimiter(content_start) orelse {
                self.done = true;
                return null;
            };
            self.pos = content_end;

            const part = parseHeaders(self.body[part_start..headers_end]) orelse continue;
            return .{
                .name = part.name,
                .filename = part.filename,
                .content_type = part.content_type,
                .body = self.body[content_start..content_end],
            };
        }
        return null;
    }

    /// Advance past the delimiter at `pos` and return the offset the
    /// part's headers start at, or null at the closing delimiter.
    fn startOfNextPart(self: *Iterator) ?usize {
        const delimiter_start = self.findDelimiter(self.pos) orelse {
            self.done = true;
            return null;
        };

        var offset = delimiter_start;
        if (self.body[offset] == '\r') offset += 2; // the CRLF before an inner delimiter
        offset += "--".len + self.boundary.len;

        // `--` after the boundary closes the body; a CRLF continues it.
        if (std.mem.startsWith(u8, self.body[offset..], "--")) {
            self.done = true;
            return null;
        }
        if (!std.mem.startsWith(u8, self.body[offset..], "\r\n")) {
            self.done = true;
            return null;
        }
        return offset + "\r\n".len;
    }

    /// Offset of the next delimiter at or after `from`: `--boundary` at
    /// the very start of the body, or `\r\n--boundary` anywhere after.
    fn findDelimiter(self: *Iterator, from: usize) ?usize {
        if (from == 0) {
            if (std.mem.startsWith(u8, self.body, "--") and
                std.mem.startsWith(u8, self.body["--".len..], self.boundary))
            {
                return 0;
            }
        }

        var search = from;
        while (std.mem.indexOfPos(u8, self.body, search, "\r\n--")) |candidate| {
            const after = candidate + "\r\n--".len;
            if (std.mem.startsWith(u8, self.body[after..], self.boundary)) return candidate;
            search = candidate + 1;
        }
        return null;
    }
};

/// The Content-Disposition pieces of one part's header block, or null
/// for a part with no usable disposition.
fn parseHeaders(block: []const u8) ?struct {
    name: []const u8,
    filename: ?[]const u8,
    content_type: []const u8,
} {
    var name: ?[]const u8 = null;
    var filename: ?[]const u8 = null;
    var content_type: []const u8 = "";

    var lines = std.mem.splitSequence(u8, block, "\r\n");
    while (lines.next()) |line| {
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const header = std.mem.trim(u8, line[0..separator], " \t");
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(header, "content-type")) {
            content_type = value;
        } else if (std.ascii.eqlIgnoreCase(header, "content-disposition")) {
            var params = std.mem.splitScalar(u8, value, ';');
            while (params.next()) |param| {
                const trimmed = std.mem.trim(u8, param, " \t");
                if (valueOf(trimmed, "name")) |found| name = found;
                if (valueOf(trimmed, "filename")) |found| filename = found;
            }
        }
    }

    return .{
        .name = name orelse return null,
        .filename = filename,
        .content_type = content_type,
    };
}

/// The value of a `key=value` or `key="value"` parameter, or null when
/// `param` names a different key.
fn valueOf(param: []const u8, key: []const u8) ?[]const u8 {
    const separator = std.mem.indexOfScalar(u8, param, '=') orelse return null;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, param[0..separator], " \t"), key)) return null;

    var value = std.mem.trim(u8, param[separator + 1 ..], " \t");
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        value = value[1 .. value.len - 1];
    }
    return value;
}

test "boundary reads the content-type parameter" {
    try testing.expectEqualStrings(
        "----WebKitFormBoundaryX",
        boundary("multipart/form-data; boundary=----WebKitFormBoundaryX").?,
    );
    try testing.expectEqualStrings(
        "abc",
        boundary("multipart/form-data; charset=utf-8; boundary=\"abc\"").?,
    );

    try testing.expect(boundary("application/x-www-form-urlencoded") == null);
    try testing.expect(boundary("multipart/form-data") == null);
    try testing.expect(boundary("multipart/form-data; boundary=") == null);
}

test "iterate walks fields and files" {
    const body = "--B\r\n" ++
        "Content-Disposition: form-data; name=\"note\"\r\n" ++
        "\r\n" ++
        "hello\r\n" ++
        "--B\r\n" ++
        "Content-Disposition: form-data; name=\"upload\"; filename=\"a.png\"\r\n" ++
        "Content-Type: image/png\r\n" ++
        "\r\n" ++
        "PNGDATA\x00\x01\r\n" ++
        "--B--\r\n";

    var parts = iterate(body, "B");

    const field = parts.next().?;
    try testing.expectEqualStrings("note", field.name);
    try testing.expect(field.filename == null);
    try testing.expectEqualStrings("hello", field.body);

    const file = parts.next().?;
    try testing.expectEqualStrings("upload", file.name);
    try testing.expectEqualStrings("a.png", file.filename.?);
    try testing.expectEqualStrings("image/png", file.content_type);
    try testing.expectEqualStrings("PNGDATA\x00\x01", file.body);

    try testing.expect(parts.next() == null);
    try testing.expect(parts.next() == null); // stays done
}

test "iterate keeps a body holding CRLF and dashes intact" {
    const body = "--B\r\n" ++
        "Content-Disposition: form-data; name=\"f\"; filename=\"x\"\r\n" ++
        "\r\n" ++
        "line one\r\n--not-the-boundary\r\nline two\r\n" ++
        "--B--\r\n";

    var parts = iterate(body, "B");
    const part = parts.next().?;
    try testing.expectEqualStrings("line one\r\n--not-the-boundary\r\nline two", part.body);
    try testing.expect(parts.next() == null);
}

test "iterate skips a preamble and tolerates a missing close" {
    const with_preamble = "ignored preamble\r\n" ++
        "--B\r\n" ++
        "Content-Disposition: form-data; name=\"a\"\r\n" ++
        "\r\n" ++
        "1\r\n" ++
        "--B--\r\n";
    var parts = iterate(with_preamble, "B");
    try testing.expectEqualStrings("1", parts.next().?.body);
    try testing.expect(parts.next() == null);

    // Truncated upload: the finished parts still come through.
    const truncated = "--B\r\n" ++
        "Content-Disposition: form-data; name=\"a\"\r\n" ++
        "\r\n" ++
        "1\r\n" ++
        "--B\r\n" ++
        "Content-Disposition: form-data; name=\"b\"\r\n" ++
        "\r\n" ++
        "cut off";
    var truncated_parts = iterate(truncated, "B");
    try testing.expectEqualStrings("1", truncated_parts.next().?.body);
    try testing.expect(truncated_parts.next() == null);
}

test "a part without a disposition is skipped" {
    const body = "--B\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "nameless\r\n" ++
        "--B\r\n" ++
        "Content-Disposition: form-data; name=\"ok\"\r\n" ++
        "\r\n" ++
        "fine\r\n" ++
        "--B--\r\n";

    var parts = iterate(body, "B");
    try testing.expectEqualStrings("ok", parts.next().?.name);
    try testing.expect(parts.next() == null);
}

const std = @import("std");
const testing = std.testing;
