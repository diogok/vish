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

const std = @import("std");
const testing = std.testing;
const decode = @import("uriencode.zig").decode;
