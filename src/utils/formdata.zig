pub fn read_formdata(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    target: anytype,
) !void {
    const TargetType = @typeInfo(@TypeOf(target)).pointer.child;

    var array: std.ArrayList(u8) = .empty;
    var array_alloc = std.Io.Writer.Allocating.fromArrayList(allocator, &array);
    defer array_alloc.deinit();
    const writer = &array_alloc.writer;

    outer: while (true) {
        const maybe_key: ?[]u8 = try reader.takeDelimiter('=');
        if (maybe_key) |src_key| {
            var key_reader = std.Io.Reader.fixed(src_key);
            try decode(&key_reader, writer);
            const key = try array_alloc.toOwnedSlice();
            defer allocator.free(key);

            inline for (std.meta.fields(TargetType)) |field| {
                if (std.mem.eql(u8, field.name, key)) {
                    const maybe_value = try reader.takeDelimiter('&');
                    if (maybe_value) |src_value| {
                        var src_reader = std.Io.Reader.fixed(src_value);
                        try decode(&src_reader, writer);
                        const value = try array_alloc.toOwnedSlice();
                        @field(target, field.name) = value;
                    }
                    continue :outer;
                }
            }
            _ = try reader.discardDelimiterInclusive('&');
        } else {
            break;
        }
    }
}

test "read form-data" {
    const formdata = "key=value&fuz=baz&foo=bar";
    var reader = std.Io.Reader.fixed(formdata);

    const Data = struct {
        key: []u8 = "",
        foo: []u8 = "",
    };
    var target = Data{};

    try read_formdata(testing.allocator, &reader, &target);
    defer testing.allocator.free(target.key);
    defer testing.allocator.free(target.foo);

    try testing.expectEqualStrings("value", target.key);
    try testing.expectEqualStrings("bar", target.foo);
}

test "read form-data decode" {
    const formdata = "key=value&fuz=baz&foo%2Fbar=bar%20zz";
    var reader = std.Io.Reader.fixed(formdata);

    const Data = struct {
        key: []u8 = "",
        @"foo/bar": []u8 = "",
    };
    var target = Data{};

    try read_formdata(testing.allocator, &reader, &target);
    defer testing.allocator.free(target.key);
    defer testing.allocator.free(target.@"foo/bar");

    try testing.expectEqualStrings("value", target.key);
    try testing.expectEqualStrings("bar zz", target.@"foo/bar");
}

/// Get the raw (URL-encoded) value for a key from a query string or form data.
/// Returns null if the key is not found.
pub fn get(data: []const u8, key: []const u8) ?[]const u8 {
    var iter = std.mem.splitScalar(u8, data, '&');
    while (iter.next()) |segment| {
        if (segment.len == 0) continue;
        if (std.mem.indexOfScalar(u8, segment, '=')) |eq_pos| {
            if (std.mem.eql(u8, segment[0..eq_pos], key)) {
                return segment[eq_pos + 1 ..];
            }
        }
    }
    return null;
}

/// Get the decoded value for a key from a query string or form data.
/// Returns null if the key is not found.
/// Caller owns the returned memory.
pub fn getDecoded(allocator: std.mem.Allocator, data: []const u8, key: []const u8) !?[]u8 {
    const raw = get(data, key) orelse return null;
    return try uriencode.decodeAlloc(allocator, raw);
}

test "get" {
    try testing.expectEqualStrings("bar", get("foo=bar&baz=qux", "foo").?);
    try testing.expectEqualStrings("qux", get("foo=bar&baz=qux", "baz").?);
    try testing.expectEqualStrings("hello%20world", get("path=hello%20world", "path").?);
    try testing.expect(get("foo=bar", "missing") == null);
    try testing.expectEqualStrings("", get("empty=&foo=bar", "empty").?);
}

test "getDecoded" {
    const result = try getDecoded(testing.allocator, "path=hello%20world&foo=bar", "path");
    defer testing.allocator.free(result.?);
    try testing.expectEqualStrings("hello world", result.?);

    try testing.expect(try getDecoded(testing.allocator, "foo=bar", "missing") == null);
}

const std = @import("std");
const testing = std.testing;
const uriencode = @import("uriencode.zig");
const decode = uriencode.decode;
