//! Percent-encoding and decoding per RFC 3986. Used for URL components
//! and `application/x-www-form-urlencoded` payloads.

pub fn encode(reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    while (true) {
        const char = reader.takeByte() catch |err| {
            switch (err) {
                error.EndOfStream => return,
                else => return err,
            }
        };
        if (std.mem.containsAtLeastScalar(u8, keep, 1, char)) {
            try writer.writeByte(char);
        } else {
            try writer.writeByte('%');
            try writer.writeAll(&std.fmt.hex(char));
        }
    }
}

pub fn decode(reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    while (true) {
        const char = reader.takeByte() catch |err| {
            switch (err) {
                error.EndOfStream => return,
                else => return err,
            }
        };
        if (char == '%') {
            const hex = try reader.take(2);
            var buffer: [1]u8 = undefined;
            _ = try std.fmt.hexToBytes(&buffer, hex);
            try writer.writeByte(buffer[0]);
        } else if (char == '+') {
            try writer.writeByte(' ');
        } else {
            try writer.writeByte(char);
        }
    }
}

pub const DecodeError = error{ OutOfMemory, InvalidEncoding };

/// Decode a URL-encoded slice, returning an allocated slice.
/// Caller owns the returned memory.
pub fn decodeAlloc(allocator: std.mem.Allocator, encoded: []const u8) DecodeError![]u8 {
    var reader = std.Io.Reader.fixed(encoded);
    var array: std.ArrayList(u8) = .empty;
    var array_alloc = std.Io.Writer.Allocating.fromArrayList(allocator, &array);
    errdefer array_alloc.deinit();

    decode(&reader, &array_alloc.writer) catch |err| {
        switch (err) {
            error.NoSpaceLeft => return error.OutOfMemory,
            inline else => return error.InvalidEncoding,
        }
    };

    return array_alloc.toOwnedSlice();
}

test "encode" {
    const expected = "Hello%20wor%2fld%21";
    const value = "Hello wor/ld!";
    var reader = std.Io.Reader.fixed(value);

    var array: std.ArrayList(u8) = .empty;
    var array_alloc = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &array);
    defer array_alloc.deinit();
    const writer = &array_alloc.writer;

    try encode(&reader, writer);

    const result = try array_alloc.toOwnedSlice();
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

test "decode" {
    const expected = "Hello wor/ld/!";
    const value = "Hello%20wor/ld%2F!";

    var reader = std.Io.Reader.fixed(value);

    var array: std.ArrayList(u8) = .empty;
    var array_alloc = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &array);
    defer array_alloc.deinit();

    try decode(&reader, &array_alloc.writer);

    const result = try array_alloc.toOwnedSlice();
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

test "decode plus as space" {
    const expected = "Hello world!";
    const value = "Hello+world%21";

    var reader = std.Io.Reader.fixed(value);

    var array: std.ArrayList(u8) = .empty;
    var array_alloc = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &array);
    defer array_alloc.deinit();

    try decode(&reader, &array_alloc.writer);

    const result = try array_alloc.toOwnedSlice();
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

test "decodeAlloc" {
    const result = try decodeAlloc(testing.allocator, "Hello%20world%21");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Hello world!", result);
}

test "decodeAlloc plus as space" {
    const result = try decodeAlloc(testing.allocator, "Hello+world%21");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Hello world!", result);
}

const keep = "_.-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz";

const std = @import("std");
const testing = std.testing;
