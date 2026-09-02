//! WebSocket client (RFC 6455 §4.1). `connect` opens the TCP
//! connection, runs the opening handshake and returns a client whose
//! `next()` and send methods follow the server session's contract,
//! every outbound frame masked. The client owns its socket and
//! buffers; `deinit` releases them.

/// The session. Its `max_payload` and `idle_timeout_in_millis` come
/// from `Options` and may still be changed before the first `next()`.
session: WebSocket,
allocator: std.mem.Allocator,
io: std.Io,
stream: std.Io.net.Stream,
/// Heap objects: the session holds pointers to their interfaces, so
/// a client returned by value stays valid.
stream_reader: *std.Io.net.Stream.Reader,
stream_writer: *std.Io.net.Stream.Writer,
read_buffer: []u8,
write_buffer: []u8,
/// The subprotocol the server selected — one of those offered — or
/// null when none was offered. Owned by the client.
subprotocol: ?[]const u8 = null,

pub const Message = WebSocket.Message;
pub const CloseCode = WebSocket.CloseCode;

pub const Options = struct {
    /// Host name or IP literal to connect to; also the `Host` header.
    host: []const u8,
    port: u16 = default_port,
    /// Request target of the handshake.
    path: []const u8 = "/",
    /// Additional request headers (`Authorization`, `Cookie`), sent
    /// as given.
    headers: []const ExtraHeader = &.{},
    /// Subprotocols to offer, in preference order. When any is
    /// offered the server must select one of them or the handshake
    /// fails.
    subprotocols: []const []const u8 = &.{},
    /// See `WebSocket.max_payload`.
    max_payload: usize = WebSocket.max_payload_default,
    /// See `WebSocket.idle_timeout_in_millis`.
    idle_timeout_in_millis: u32 = 0,
    /// Socket buffers. A handshake response line must fit the read
    /// buffer.
    read_buffer_size: usize = 8 * 1024,
    write_buffer_size: usize = 8 * 1024,
};

/// The handshake's own errors; `connect` also returns the resolver's,
/// the socket's and the allocator's. `HandshakeRejected`: a status
/// other than 101. `HandshakeInvalid`: a 101 without
/// `Upgrade: websocket`, `Connection: Upgrade` or the expected
/// `Sec-WebSocket-Accept`, or a malformed response.
/// `SubprotocolMismatch`: subprotocols were offered and the server
/// selected none of them, or one that was not offered. A peer that
/// closes mid-handshake is `error.EndOfStream`.
pub const HandshakeError = error{ HandshakeRejected, HandshakeInvalid, SubprotocolMismatch };

/// The port implied by `ws://` (RFC 6455 §3).
const default_port = 80;
/// Bytes of a refused status line that make it into the debug log.
const status_log_max = 64;

/// Connect, handshake and return the open session. Returns the
/// `HandshakeError`s, `error.EndOfStream` for a peer that closed
/// mid-handshake, and the resolver's, socket's and allocator's errors.
pub fn connect(io: std.Io, allocator: std.mem.Allocator, options: Options) !@This() {
    const read_buffer = try allocator.alloc(u8, options.read_buffer_size);
    errdefer allocator.free(read_buffer);
    const write_buffer = try allocator.alloc(u8, options.write_buffer_size);
    errdefer allocator.free(write_buffer);
    const stream_reader = try allocator.create(std.Io.net.Stream.Reader);
    errdefer allocator.destroy(stream_reader);
    const stream_writer = try allocator.create(std.Io.net.Stream.Writer);
    errdefer allocator.destroy(stream_writer);

    const stream = try connectTcp(io, options.host, options.port);
    errdefer stream.close(io);
    stream_reader.* = stream.reader(io, read_buffer);
    stream_writer.* = stream.writer(io, write_buffer);

    var key_raw: [frame.key_raw_len]u8 = undefined;
    io.random(&key_raw);
    var key: [frame.key_b64_len]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key, &key_raw);
    const selected = try handshake(&stream_reader.interface, &stream_writer.interface, &key, options);
    const subprotocol: ?[]const u8 = if (selected) |name| try allocator.dupe(u8, name) else null;

    return .{
        .session = .{
            .reader = &stream_reader.interface,
            .writer = &stream_writer.interface,
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .role = .client,
            .max_payload = options.max_payload,
            .idle_timeout_in_millis = options.idle_timeout_in_millis,
        },
        .allocator = allocator,
        .io = io,
        .stream = stream,
        .stream_reader = stream_reader,
        .stream_writer = stream_writer,
        .read_buffer = read_buffer,
        .write_buffer = write_buffer,
        .subprotocol = subprotocol,
    };
}

/// Close the socket and free the client's memory. Runs no close
/// handshake: for an orderly shutdown call `close`, read until
/// `next()` returns `.close` or fails, then `deinit`.
pub fn deinit(self: *@This()) void {
    self.session.deinit();
    self.stream.close(self.io);
    if (self.subprotocol) |name| self.allocator.free(name);
    self.allocator.free(self.read_buffer);
    self.allocator.free(self.write_buffer);
    self.allocator.destroy(self.stream_reader);
    self.allocator.destroy(self.stream_writer);
}

/// Read the next complete message; the contract is `WebSocket.next`.
pub fn next(self: *@This()) !Message {
    return self.session.next();
}

/// Send a complete text message in one frame.
pub fn sendText(self: *@This(), payload: []const u8) void {
    self.session.sendText(payload);
}

/// Send a complete binary message in one frame.
pub fn sendBinary(self: *@This(), payload: []const u8) void {
    self.session.sendBinary(payload);
}

/// Send a Ping. Payloads over the 125-byte control-frame limit
/// are dropped (RFC 6455 §5.5).
pub fn ping(self: *@This(), payload: []const u8) void {
    self.session.ping(payload);
}

/// Send a Pong. Payloads over the 125-byte control-frame limit
/// are dropped (RFC 6455 §5.5).
pub fn pong(self: *@This(), payload: []const u8) void {
    self.session.pong(payload);
}

/// Send a Close frame and mark the session over; the server's reply
/// then surfaces from `next()` as `.close`, followed by
/// `error.EndOfStream` when it drops the connection. A no-op once
/// the session is already closed.
pub fn close(self: *@This(), code: CloseCode, reason: []const u8) void {
    self.session.close(code, reason);
}

/// Connect to `host`:`port`: an IP literal directly, a name through
/// the resolver.
fn connectTcp(io: std.Io, host: []const u8, port: u16) !std.Io.net.Stream {
    if (std.Io.net.IpAddress.parse(host, port)) |address| {
        return std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream });
    } else |_| {}
    const name = try std.Io.net.HostName.init(host);
    return name.connect(io, port, .{ .mode = .stream });
}

/// Send the opening handshake carrying `key` and validate the
/// response (RFC 6455 §4.1, §4.2.2). Returns the subprotocol the
/// server selected — a member of `options.subprotocols` — or null.
/// The reader is left at the first byte after the response head.
fn handshake(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    key: *const [frame.key_b64_len]u8,
    options: Options,
) (HandshakeError || std.Io.Reader.Error || std.Io.Writer.Error)!?[]const u8 {
    try writer.print("GET {s} HTTP/1.1\r\nHost: {s}", .{ options.path, options.host });
    // The default port is implied by the scheme; any other one is
    // spelled out (§4.1).
    if (options.port != default_port) try writer.print(":{d}", .{options.port});
    try writer.writeAll("\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ");
    try writer.writeAll(key);
    try writer.writeAll("\r\nSec-WebSocket-Version: 13\r\n");
    if (options.subprotocols.len > 0) {
        try writer.writeAll("Sec-WebSocket-Protocol: ");
        for (options.subprotocols, 0..) |name, index| {
            if (index > 0) try writer.writeAll(", ");
            try writer.writeAll(name);
        }
        try writer.writeAll("\r\n");
    }
    for (options.headers) |header| try writer.print("{s}: {s}\r\n", .{ header.name, header.value });
    try writer.writeAll("\r\n");
    try writer.flush();

    const status_line = try takeLine(reader);
    if (!statusIs101(status_line)) {
        // Server-controlled bytes: capped and escaped before logging.
        const shown = status_line[0..@min(status_line.len, status_log_max)];
        log.debug("WebSocket handshake refused: {f}", .{std.ascii.hexEscape(shown, .lower)});
        return error.HandshakeRejected;
    }
    const expected_accept = frame.acceptKey(key);
    var upgrade_ok = false;
    var connection_ok = false;
    var accept_ok = false;
    var selected: ?[]const u8 = null;
    while (true) {
        const line = try takeLine(reader);
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.HandshakeInvalid;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Upgrade")) {
            upgrade_ok = std.ascii.eqlIgnoreCase(value, "websocket");
        } else if (std.ascii.eqlIgnoreCase(name, "Connection")) {
            connection_ok = hasToken(value, "Upgrade");
        } else if (std.ascii.eqlIgnoreCase(name, "Sec-WebSocket-Accept")) {
            accept_ok = std.mem.eql(u8, value, &expected_accept);
        } else if (std.ascii.eqlIgnoreCase(name, "Sec-WebSocket-Protocol")) {
            // §4.1 step 6: a subprotocol that was not offered fails
            // the handshake.
            selected = offered(options.subprotocols, value) orelse return error.SubprotocolMismatch;
        }
    }
    if (!upgrade_ok or !connection_ok or !accept_ok) return error.HandshakeInvalid;
    // An offer the server answered with no selection is a failed
    // handshake too: the application asked for a subprotocol.
    if (options.subprotocols.len > 0 and selected == null) return error.SubprotocolMismatch;
    return selected;
}

/// One line of the response head without its terminator. A line that
/// does not fit the read buffer is `HandshakeInvalid`.
fn takeLine(reader: *std.Io.Reader) (HandshakeError || std.Io.Reader.Error)![]const u8 {
    const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
        error.StreamTooLong => return error.HandshakeInvalid,
        else => |other| return other,
    };
    return std.mem.trimEnd(u8, line, "\r\n");
}

/// `HTTP/1.x 101 ...`: only the version and the status code count.
fn statusIs101(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "HTTP/1.")) return false;
    const space = std.mem.indexOfScalar(u8, line, ' ') orelse return false;
    const rest = line[space + 1 ..];
    return rest.len >= 3 and std.mem.eql(u8, rest[0..3], "101") and (rest.len == 3 or rest[3] == ' ');
}

/// Whether the comma-separated `list` carries `token`, compared
/// case-insensitively (`Connection` may be a list, RFC 6455 §4.2.1).
fn hasToken(list: []const u8, token: []const u8) bool {
    var items = std.mem.splitScalar(u8, list, ',');
    while (items.next()) |item| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, item, " \t"), token)) return true;
    }
    return false;
}

/// The offered subprotocol equal to `value` — byte-wise: subprotocol
/// names are case-sensitive tokens — or null.
fn offered(subprotocols: []const []const u8, value: []const u8) ?[]const u8 {
    for (subprotocols) |name| {
        if (std.mem.eql(u8, name, value)) return name;
    }
    return null;
}

const sample_key: *const [frame.key_b64_len]u8 = "dGhlIHNhbXBsZSBub25jZQ==";
const valid_101 =
    "HTTP/1.1 101 Switching Protocols\r\n" ++
    "Upgrade: websocket\r\n" ++
    "Connection: Upgrade\r\n" ++
    "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
    "\r\n";

/// Run `handshake` with the RFC sample key against a canned
/// response, discarding the request bytes.
fn handshakeAgainst(response_bytes: []const u8, options: Options) !?[]const u8 {
    var out: [512]u8 = undefined;
    var request = std.Io.Writer.fixed(&out);
    var reader = std.Io.Reader.fixed(response_bytes);
    return handshake(&reader, &request, sample_key, options);
}

test "handshake sends the request and accepts a valid 101" {
    var out: [512]u8 = undefined;
    var request = std.Io.Writer.fixed(&out);
    var reader = std.Io.Reader.fixed(valid_101 ++ "\x81");
    const selected = try handshake(&reader, &request, sample_key, .{
        .host = "example.com",
        .port = 8080,
        .path = "/chat",
        .headers = &.{.{ .name = "Authorization", .value = "Bearer t" }},
    });
    try testing.expect(selected == null);
    try testing.expectEqualStrings(
        "GET /chat HTTP/1.1\r\n" ++
            "Host: example.com:8080\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "Authorization: Bearer t\r\n" ++
            "\r\n",
        out[0..request.end],
    );
    // The byte after the head is left for the session.
    try testing.expectEqual(@as(usize, 1), reader.bufferedLen());
}

test "handshake omits the default port from Host and lists the offered subprotocols" {
    var out: [512]u8 = undefined;
    var request = std.Io.Writer.fixed(&out);
    var reader = std.Io.Reader.fixed(
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
            "Sec-WebSocket-Protocol: chat\r\n" ++
            "\r\n",
    );
    const selected = try handshake(&reader, &request, sample_key, .{
        .host = "example.com",
        .subprotocols = &.{ "chat", "superchat" },
    });
    try testing.expectEqualStrings("chat", selected.?);
    const sent = out[0..request.end];
    try testing.expect(std.mem.indexOf(u8, sent, "Host: example.com\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "Sec-WebSocket-Protocol: chat, superchat\r\n") != null);
}

test "handshake rejects a status other than 101" {
    try testing.expectError(
        error.HandshakeRejected,
        handshakeAgainst("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n", .{ .host = "h" }),
    );
}

test "handshake rejects a 101 with a wrong accept value" {
    try testing.expectError(error.HandshakeInvalid, handshakeAgainst(
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: AAAAAAAAAAAAAAAAAAAAAAAAAAA=\r\n" ++
            "\r\n",
        .{ .host = "h" },
    ));
}

test "handshake rejects a 101 without Connection: Upgrade" {
    try testing.expectError(error.HandshakeInvalid, handshakeAgainst(
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: keep-alive\r\n" ++
            "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
            "\r\n",
        .{ .host = "h" },
    ));
}

test "handshake accepts a Connection token list and mixed-case names" {
    const selected = try handshakeAgainst(
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "upgrade: WebSocket\r\n" ++
            "connection: keep-alive, Upgrade\r\n" ++
            "sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
            "\r\n",
        .{ .host = "h" },
    );
    try testing.expect(selected == null);
}

test "handshake rejects a malformed header line" {
    try testing.expectError(error.HandshakeInvalid, handshakeAgainst(
        "HTTP/1.1 101 Switching Protocols\r\ngarbage\r\n\r\n",
        .{ .host = "h" },
    ));
}

test "handshake reports a peer that closes mid-handshake" {
    try testing.expectError(error.EndOfStream, handshakeAgainst(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: web",
        .{ .host = "h" },
    ));
}

test "handshake takes the selected subprotocol only from the offered list" {
    const offered_list = [_][]const u8{ "chat", "superchat" };
    const with_other = valid_101[0 .. valid_101.len - 2] ++ "Sec-WebSocket-Protocol: other\r\n\r\n";
    try testing.expectError(
        error.SubprotocolMismatch,
        handshakeAgainst(with_other, .{ .host = "h", .subprotocols = &offered_list }),
    );
    // Offered, but the server selected none.
    try testing.expectError(
        error.SubprotocolMismatch,
        handshakeAgainst(valid_101, .{ .host = "h", .subprotocols = &offered_list }),
    );
    // Nothing offered, yet the server names one.
    const with_chat = valid_101[0 .. valid_101.len - 2] ++ "Sec-WebSocket-Protocol: chat\r\n\r\n";
    try testing.expectError(error.SubprotocolMismatch, handshakeAgainst(with_chat, .{ .host = "h" }));
    // Offered and selected.
    const selected = try handshakeAgainst(with_chat, .{ .host = "h", .subprotocols = &offered_list });
    try testing.expectEqualStrings("chat", selected.?);
}

test "statusIs101 reads only the version and the code" {
    try testing.expect(statusIs101("HTTP/1.1 101 Switching Protocols"));
    try testing.expect(statusIs101("HTTP/1.0 101"));
    try testing.expect(!statusIs101("HTTP/1.1 1010"));
    try testing.expect(!statusIs101("HTTP/1.1 200 OK"));
    try testing.expect(!statusIs101("HTTP/2 101"));
    try testing.expect(!statusIs101("101"));
}

const std = @import("std");
const testing = std.testing;
const log = std.log.scoped(.vish);

const WebSocket = @import("../websocket.zig");
const frame = @import("frame.zig");
const ExtraHeader = @import("../response.zig").ExtraHeader;
