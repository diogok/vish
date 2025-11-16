pub const Status = enum(u16) {
    OK = 200,
    Moved_Permanentely = 301,
    Found = 302,
    See_Other = 303,
    Not_Modified = 304,
    Temporary_Redirect = 307,
    Permanent_Redirect = 308,
    Not_Found = 404,
    Internal_Server_Error = 500,
    // TODO: rest of standard codes

    pub fn int(self: @This()) u16 {
        return @intFromEnum(self);
    }
};

pub const Response = struct {
    version: request.Version = .HTTP_1_1,

    status: Status = .OK,
    headers: Headers = .{},
    body: []const u8 = "",

    sent_status: bool = false,
    sent_headers: bool = false,

    writer: *std.Io.Writer,

    pub fn fromRequest(src: Request) @This() {
        return .{
            .version = src.version,
            .headers = .{
                .connection = src.headers.connection,
            },
            .writer = src.writer,
        };
    }

    pub fn send(self: *@This()) !void {
        try self.sendStatus();
        try self.sendHeaders();
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
        var buffer: [10]u8 = undefined;
        if (self.headers.content_length.len == 0 and self.body.len > 0) {
            self.headers.content_length = try std.fmt.bufPrint(&buffer, "{d}", .{self.body.len});
        }
        inline for (std.meta.fields(Headers)) |field| {
            if (@field(self.headers, field.name).len > 0) {
                const headerName = comptime capitalize(field.name);
                try self.sendHeader(self.writer, &headerName, @field(self.headers, field.name));
            }
        }
        _ = try self.writer.write("\r\n");
        self.sent_headers = true;
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

    pub fn writeBody(
        self: *@This(),
        body: []const u8,
    ) !void {
        if (!self.sent_status) {
            try self.sendStatus();
        }
        if (!self.sent_headers) {
            try self.sendHeaders();
        }
        _ = try self.writer.write(body);
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
const std = @import("std");
const testing = std.testing;

const request = @import("request.zig");
const Headers = request.Headers;
const Request = request.Request;

const log = std.log.scoped(.http);
