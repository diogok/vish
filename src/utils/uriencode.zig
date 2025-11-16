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
        } else {
            try writer.writeByte(char);
        }
    }
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
    const writer = &array_alloc.writer;

    try decode(&reader, writer);

    const result = try array_alloc.toOwnedSlice();
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

const keep = "_.-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz";

const std = @import("std");
const testing = std.testing;
