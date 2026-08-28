//! WebSocket server support (RFC 6455). The session lives inside the
//! handler: `upgrade()` opens the handshake, `next()` blocks for the
//! next complete message, and the loop closes the connection when the
//! handler returns.

/// Frame opcode (RFC 6455 §5.5). Tags 3-7 and 11-15 are reserved
/// and never named: receiving one fails the connection.
pub const OpCode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
};

/// RFC 6455 §7.4 close status codes an endpoint may put on the
/// wire. 1005 (no status) and 1006 (abnormal closure) are local
/// markers that MUST NOT appear in a frame, so they are absent.
pub const CloseCode = enum(u16) {
    normal_closure = 1000,
    going_away = 1001,
    protocol_error = 1002,
    unsupported_data = 1003,
    invalid_payload = 1007,
    policy_violation = 1008,
    message_too_big = 1009,
    internal_error = 1011,
};

/// One complete inbound message. Payloads are owned by the
/// connection (the per-request arena in production) and stay valid
/// until the next `next()` call or the session ends.
pub const Message = union(enum) {
    text: []const u8,
    binary: []const u8,
    /// The peer sent a Close frame. The library has already
    /// answered it and the session is ending; `code` is 0 when the
    /// peer sent no status code.
    close: struct {
        code: u16,
        reason: []const u8,
    },
};

reader: *std.Io.Reader,
writer: *std.Io.Writer,
allocator: std.mem.Allocator,

/// Opcode of the fragment sequence currently being assembled, null
/// when none is open.
frag_opcode: ?OpCode = null,
/// Accumulated payload of the open fragment sequence.
frag: []u8 = &.{},
/// Bytes currently held in `frag`.
frag_len: usize = 0,
/// Set once a Close frame has been sent or received: the session
/// is tearing down.
closed: bool = false,
/// Set once a Close frame from the peer has been consumed (surfaced
/// as `.close` or rejected): a second Close is a protocol violation.
close_seen: bool = false,
/// Sticky transport-failure flag: every later write is a no-op and
/// `next()` fails.
failed: bool = false,
/// Maximum inbound payload, per frame and per reassembled message;
/// over-size input fails the connection with 1009.
max_payload: usize = max_payload_default,

/// `Sec-WebSocket-Key` is base64 of exactly 16 bytes (RFC 6455
/// §4.1); in the standard alphabet with padding that is 24 chars.
const key_b64_len = 24;
/// The 16 bytes a valid key decodes to.
const key_raw_len = 16;
/// The magic GUID concatenated with the key before the SHA-1
/// (RFC 6455 §4.1).
const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
/// The default for `max_payload`.
const max_payload_default = 16 * 1024 * 1024;
/// Maximum payload of a control frame (RFC 6455 §5.5).
const control_payload_max = 125;

/// Errors from `upgrade`. `NotWebSocket`: the request is not a
/// WebSocket upgrade request and nothing was sent — the caller
/// returns `error.Skipped` so routing can continue.
/// `HandshakeRejected`: the request was an upgrade request but is
/// invalid — the 400 response has already been sent, the caller
/// returns `.handled`. `UpgradeFailed`: the 101 could not be
/// delivered (the client is already gone).
pub fn upgrade(req: Request, res: *Response) !@This() {
    // No Upgrade header: not an upgrade attempt, whatever the
    // method — return without sending so routing can continue.
    if (req.headers.upgrade.len == 0) return error.NotWebSocket;
    if (!std.ascii.eqlIgnoreCase(req.headers.upgrade, "websocket") or
        req.headers.connection != .upgrade)
    {
        reject(res, &.{});
        return error.HandshakeRejected;
    }
    // An upgrade request with a body would leave body bytes in the
    // buffer to corrupt the first frame, so only body-less GET is
    // admissible.
    if (req.method != .GET) {
        reject(res, &.{});
        return error.HandshakeRejected;
    }

    const version = req.headers.sec_websocket_version;
    if (version.len == 0) {
        reject(res, &.{});
        return error.HandshakeRejected;
    }
    if (!std.ascii.eqlIgnoreCase(version, "13")) {
        // RFC 6455 §4.1: the 400 for a version mismatch MUST carry
        // the version the server supports.
        const extra = [_]response.ExtraHeader{
            .{ .name = "Sec-WebSocket-Version", .value = "13" },
        };
        reject(res, &extra);
        return error.HandshakeRejected;
    }

    const key = req.headers.sec_websocket_key;
    if (key.len != key_b64_len) {
        reject(res, &.{});
        return error.HandshakeRejected;
    }
    const b64 = std.base64.standard;
    const decoded_len = b64.Decoder.calcSizeForSlice(key) catch {
        reject(res, &.{});
        return error.HandshakeRejected;
    };
    if (decoded_len != key_raw_len) {
        reject(res, &.{});
        return error.HandshakeRejected;
    }
    var key_raw: [key_raw_len]u8 = undefined;
    b64.Decoder.decode(&key_raw, key) catch {
        reject(res, &.{});
        return error.HandshakeRejected;
    };
    // RFC 6455 §4.1: the handshake carries no body. A body left in
    // the buffer would desync the first frame read.
    if (req.headers.content_length > 0 or req.headers.transfer_encoding != null) {
        reject(res, &.{});
        return error.HandshakeRejected;
    }

    // Sec-WebSocket-Accept = base64(SHA1(key ++ magic)).
    var input: [key_b64_len + magic.len]u8 = undefined;
    @memcpy(input[0..key_b64_len], key);
    @memcpy(input[key_b64_len..], magic);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(&input, &digest, .{});
    var accept: [@divTrunc(std.crypto.hash.Sha1.digest_length + 2, 3) * 4]u8 = undefined;
    const accept_b64 = b64.Encoder.encode(&accept, &digest);

    res.status = .Switching_Protocols;
    res.headers.upgrade = "websocket";
    // §4.1: when the client offered subprotocols, the 101 MUST
    // name the one selected — here, the first non-empty token.
    if (selectSubprotocol(req.headers.sec_websocket_protocol)) |sub| {
        const extra = [_]response.ExtraHeader{
            .{ .name = "Sec-WebSocket-Accept", .value = accept_b64 },
            .{ .name = "Sec-WebSocket-Protocol", .value = sub },
        };
        res.headers.extra = &extra;
    } else {
        const extra = [_]response.ExtraHeader{
            .{ .name = "Sec-WebSocket-Accept", .value = accept_b64 },
        };
        res.headers.extra = &extra;
    }
    res.send();
    if (res.failed) return error.UpgradeFailed;
    // The client waits for the 101 before speaking WebSocket: the
    // loop only flushes after the handler returns, so flush now.
    req.writer.flush() catch {
        res.failed = true;
        return error.UpgradeFailed;
    };
    res.upgraded = true;

    return .{
        .reader = req.reader,
        .writer = req.writer,
        .allocator = req.allocator,
    };
}

/// Read the next complete message. Control frames are consumed
/// internally: pings are answered with pong, pongs are discarded.
/// A received Close frame is answered and surfaced as `.close`
/// exactly once; once the session is closed — by a Close in either
/// direction or by a violation — any peer frame other than the
/// closing Close is a protocol violation. When the peer closes the
/// TCP connection, `next()` returns `error.EndOfStream`. A protocol
/// violation returns `error.ProtocolError`, the corresponding Close
/// frame sent best effort. A failed write of an automatic pong or
/// close echo returns `error.ReadFailed` and latches the session
/// failed.
pub fn next(self: *@This()) !Message {
    if (self.failed) return error.ReadFailed;
    while (true) {
        const f = try self.readFrame();
        // The session is tearing down: per RFC 6455 §5.5.1 the peer
        // may only send the closing Close itself, and only once — a
        // Close answering our own close() is that one.
        if (self.closed and (f.opcode != .close or self.close_seen)) {
            return self.failProtocol(.protocol_error, "");
        }
        switch (f.opcode) {
            .ping => {
                self.writeFrame(true, .pong, &[_][]const u8{f.payload}) catch {
                    // writeFrame latched `failed`; the transport
                    // is gone, do not leak the raw write error.
                    return error.ReadFailed;
                };
                continue;
            },
            .pong => continue,
            .close => {
                var code: u16 = 0;
                var reason: []const u8 = "";
                if (f.payload.len >= 2) {
                    code = (@as(u16, f.payload[0]) << 8) | @as(u16, f.payload[1]);
                    reason = f.payload[2..];
                }
                // Consumed a Close from the peer (valid or
                // malformed): a second one is a protocol
                // violation (RFC 6455 §5.5.1).
                self.close_seen = true;
                // Exactly one payload byte, a 0-999 code (an
                // explicit `0x0000` included), the local-only
                // 1005/1006 on the wire, or an out-of-range code
                // are protocol errors (RFC 6455 §7.1.5, §7.4). A
                // 0-byte payload is the legal "no status" and
                // stays admissible.
                if (f.payload.len == 1 or (f.payload.len >= 2 and
                    (code < 1000 or code > 4999 or code == 1005 or code == 1006)))
                {
                    return self.failProtocol(.protocol_error, "");
                }
                if (!std.unicode.utf8ValidateSlice(reason)) {
                    return self.failProtocol(.invalid_payload, "");
                }
                if (!self.closed) {
                    self.closed = true;
                    // Echo the peer's payload back: the spec allows
                    // it to carry a code, so keep whatever it had.
                    self.writeFrame(true, .close, &[_][]const u8{f.payload}) catch {
                        return error.ReadFailed;
                    };
                }
                return .{ .close = .{ .code = code, .reason = reason } };
            },
            // Data frames: text, binary, continuation.
            else => {
                const op = f.opcode;
                if (op == .continuation) {
                    if (self.frag_opcode == null) return self.failProtocol(.protocol_error, "");
                } else if (self.frag_opcode != null) {
                    // A new data frame while a sequence is open.
                    return self.failProtocol(.protocol_error, "");
                } else if (!f.fin) {
                    self.frag_opcode = op;
                }

                if (!f.fin) {
                    try self.appendFrag(f.payload);
                    continue;
                }

                if (self.frag_opcode == null) {
                    // A complete single-frame message: hand the
                    // frame's own buffer back, no copy.
                    if (op == .text) {
                        if (!std.unicode.utf8ValidateSlice(f.payload)) {
                            return self.failProtocol(.invalid_payload, "");
                        }
                        return .{ .text = f.payload };
                    }
                    return .{ .binary = f.payload };
                }

                // Final fragment of a sequence.
                const message_opcode = self.frag_opcode.?;
                self.frag_opcode = null;
                try self.appendFrag(f.payload);
                const msg_len = self.frag_len;
                // Reset the length, not the buffer: the returned
                // slice points into it, and the next sequence
                // reuses its capacity.
                self.frag_len = 0;
                if (message_opcode == .text) {
                    if (!std.unicode.utf8ValidateSlice(self.frag[0..msg_len])) {
                        return self.failProtocol(.invalid_payload, "");
                    }
                    return .{ .text = self.frag[0..msg_len] };
                }
                return .{ .binary = self.frag[0..msg_len] };
            },
        }
    }
}

/// Send a complete text message in one frame.
pub fn sendText(self: *@This(), payload: []const u8) void {
    self.sendData(.text, payload);
}

/// Send a complete binary message in one frame.
pub fn sendBinary(self: *@This(), payload: []const u8) void {
    self.sendData(.binary, payload);
}

/// Send a Ping. Payloads over the 125-byte control-frame limit
/// are dropped (RFC 6455 §5.5).
pub fn ping(self: *@This(), payload: []const u8) void {
    self.sendData(.ping, payload);
}

/// Send a Pong. Payloads over the 125-byte control-frame limit
/// are dropped (RFC 6455 §5.5).
pub fn pong(self: *@This(), payload: []const u8) void {
    self.sendData(.pong, payload);
}

/// Send a Close frame and mark the session over. A no-op once the
/// session is already closed. `reason` is clipped to 123 bytes so
/// the frame fits the 125-byte control-frame limit. The TCP
/// connection closes when the handler returns.
pub fn close(self: *@This(), code: CloseCode, reason: []const u8) void {
    if (self.closed or self.failed) return;
    self.closed = true;
    self.sendClosePayload(code, reason);
}

/// Free the fragment accumulator. No-op under the production
/// arena; call it after the session ends when using a plain
/// allocator (tests).
pub fn deinit(self: *@This()) void {
    if (self.frag.len > 0) self.allocator.free(self.frag);
}

fn sendData(self: *@This(), opcode: OpCode, payload: []const u8) void {
    if (self.closed or self.failed) return;
    // Control frames are limited to 125 payload bytes (RFC 6455
    // §5.5). Over-length input is dropped whole: a truncated pong
    // would no longer match its ping.
    if ((opcode == .ping or opcode == .pong) and payload.len > control_payload_max) return;
    self.writeFrame(true, opcode, &[_][]const u8{payload}) catch |err| {
        self.failed = true;
        log.debug("WebSocket write failed: {t}", .{err});
    };
}

/// Read and validate one frame. Client frames must be masked
/// (RFC 6455 §5.1); the payload is returned unmasked, owned by the
/// connection arena.
fn readFrame(self: *@This()) !Frame {
    const head = try self.reader.take(2);
    const fin = head[0] & 0x80 != 0;
    const rsv = (head[0] >> 4) & 0x07;
    const op = head[0] & 0x0F;
    const masked = head[1] & 0x80 != 0;
    var len: usize = head[1] & 0x7F;
    if (len == 126) {
        const ext = try self.reader.take(2);
        len = @as(usize, ext[0]) * 256 + ext[1];
    } else if (len == 127) {
        const ext = try self.reader.take(8);
        var len64: u64 = 0;
        for (ext) |b| len64 = (len64 << 8) | b;
        if (len64 > @as(u64, std.math.maxInt(usize))) {
            return self.failProtocol(.protocol_error, "");
        }
        len = @intCast(len64);
    }

    // No extensions were negotiated, so any RSV bit is a protocol
    // error (RFC 6455 §5.2); opcodes 3-7 and 11-15 are reserved
    // and rejected before the enum conversion.
    if (rsv != 0 or (op >= 3 and op <= 7) or op >= 11) {
        return self.failProtocol(.protocol_error, "");
    }
    const opcode = @as(OpCode, @enumFromInt(op));
    if (op >= 8 and (!fin or len > control_payload_max)) {
        return self.failProtocol(.protocol_error, "");
    }
    // "A server MUST close the connection upon receiving a frame
    // that does not have the MASK bit set" (RFC 6455 §5.1).
    if (!masked) return self.failProtocol(.protocol_error, "");
    // The payload length is attacker-supplied and unbounded on
    // the wire; cap it before readAlloc sizes the buffer (RFC
    // 6455 sets no limit).
    if (len > self.max_payload) {
        return self.failProtocol(.message_too_big, "");
    }

    const mask = try self.reader.take(4);
    var payload: []const u8 = &.{};
    if (len > 0) {
        const buf = try self.reader.readAlloc(self.allocator, len);
        for (buf, 0..) |*b, i| b.* ^= mask[i % 4];
        payload = buf;
    }
    return .{ .fin = fin, .opcode = opcode, .payload = payload };
}

/// Fail the connection: send the Close frame once (best effort)
/// and report `error.ProtocolError`.
fn failProtocol(self: *@This(), code: CloseCode, reason: []const u8) error{ProtocolError} {
    if (!self.closed) {
        self.closed = true;
        self.sendClosePayload(code, reason);
    }
    return error.ProtocolError;
}

/// Write a Close frame carrying `code` and `reason`, clipping the
/// reason so the frame fits the 125-byte control frame limit. Not
/// gated on `closed` — a failure Close may go out while the session
/// is already marked over.
fn sendClosePayload(self: *@This(), code: CloseCode, reason: []const u8) void {
    if (self.failed) return;
    const code_int = @intFromEnum(code);
    const code_bytes = [_]u8{ @truncate(code_int >> 8), @truncate(code_int) };
    const capped = reason[0 .. @min(reason.len, control_payload_max - 2)];
    self.writeFrame(true, .close, &[_][]const u8{ &code_bytes, capped }) catch |err| {
        self.failed = true;
        log.debug("WebSocket write failed: {t}", .{err});
    };
}

fn appendFrag(self: *@This(), chunk: []const u8) !void {
    // Single frames are capped in readFrame; this bounds the sum
    // across a fragment sequence.
    if (self.frag_len + chunk.len > self.max_payload) {
        return self.failProtocol(.message_too_big, "");
    }
    if (self.frag_len == 0) {
        // realloc rather than alloc: a finished message keeps the
        // buffer for reuse, and plain allocators would leak it.
        self.frag = try self.allocator.realloc(self.frag, chunk.len);
        @memcpy(self.frag, chunk);
        self.frag_len = chunk.len;
    } else {
        const grown = try self.allocator.realloc(self.frag, self.frag_len + chunk.len);
        @memcpy(grown[self.frag_len..], chunk);
        self.frag = grown;
        self.frag_len += chunk.len;
    }
}

/// Write one frame, unmasked (the server never masks), and flush
/// it to the peer. The payload is written as the given parts, in
/// order.
fn writeFrame(self: *@This(), fin: bool, opcode: OpCode, parts: []const []const u8) !void {
    var len: usize = 0;
    for (parts) |p| len += p.len;
    var header: [14]u8 = undefined;
    var hdr_len: usize = 0;
    header[hdr_len] = (@as(u8, @intFromBool(fin)) << 7) | @intFromEnum(opcode);
    hdr_len += 1;
    if (len < 126) {
        header[hdr_len] = @intCast(len);
        hdr_len += 1;
    } else if (len <= std.math.maxInt(u16)) {
        header[hdr_len] = 126;
        hdr_len += 1;
        std.mem.writeInt(u16, header[hdr_len..][0..2], @intCast(len), .big);
        hdr_len += 2;
    } else {
        header[hdr_len] = 127;
        hdr_len += 1;
        std.mem.writeInt(u64, header[hdr_len..][0..8], len, .big);
        hdr_len += 8;
    }
    self.writer.writeAll(header[0..hdr_len]) catch |err| {
        self.failed = true;
        return err;
    };
    for (parts) |p| {
        self.writer.writeAll(p) catch |err| {
            self.failed = true;
            return err;
        };
    }
    self.writer.flush() catch |err| {
        self.failed = true;
        return err;
    };
}

const Frame = struct {
    fin: bool,
    opcode: OpCode,
    payload: []const u8,
};

/// Send a 400 for a failed handshake. `extra` carries the
/// `Sec-WebSocket-Version: 13` hint on a version mismatch.
fn reject(res: *Response, extra: []const response.ExtraHeader) void {
    // Body-less, so `Connection: close` is what frames the
    // message; the Connection value copied from the request
    // (usually `Upgrade`) must not ride along on a 400.
    res.status = .Bad_Request;
    res.headers.connection = .close;
    res.headers.extra = extra;
    res.send();
}

/// The subprotocol a server echoes back from a
/// `Sec-WebSocket-Protocol` list (RFC 6455 §4.1): the first
/// non-empty token, OWS-trimmed. Returns a subslice of `value`; null
/// when the list carries no non-empty token.
fn selectSubprotocol(value: []const u8) ?[]const u8 {
    var rest = value;
    while (rest.len > 0) {
        const comma = std.mem.indexOfScalar(u8, rest, ',') orelse break;
        const token = std.mem.trim(u8, rest[0..comma], " \t");
        if (token.len > 0) return token;
        rest = rest[comma + 1 ..];
    }
    // The last token, after the final comma — or the whole value when
    // it has no comma at all.
    const token = std.mem.trim(u8, rest, " \t");
    return if (token.len > 0) token else null;
}

test "selectSubprotocol picks the first non-empty token" {
    try testing.expectEqualStrings("chat", selectSubprotocol("chat, superchat").?);
    try testing.expectEqualStrings("chat", selectSubprotocol("  chat ,\tsuperchat").?);
    try testing.expectEqualStrings("solo", selectSubprotocol("solo").?);
    try testing.expectEqualStrings("second", selectSubprotocol(" , second ").?);
    try testing.expectEqualStrings("a", selectSubprotocol("a, tail").?);
    try testing.expectEqualStrings("tail", selectSubprotocol(" , tail").?);
}

test "selectSubprotocol returns null for a list without tokens" {
    try testing.expect(selectSubprotocol("") == null);
    try testing.expect(selectSubprotocol(" , ,") == null);
    try testing.expect(selectSubprotocol(" \t ") == null);
}

/// Assemble a wire frame for tests (heap-allocated; the caller frees
/// it): `mask` applies a fixed key to the payload, since client frames
/// must be masked (RFC 6455 §5.1).
fn frame(fin: bool, opcode: u8, mask: bool, payload: []const u8) []u8 {
    const key = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };
    const len = payload.len;
    // Allocate exactly the wire size: the debug allocator validates
    // frees against the slice length.
    const size = 2 +
        (if (len < 126) @as(usize, 0) else if (len <= std.math.maxInt(u16)) @as(usize, 2) else @as(usize, 8)) +
        (if (mask) @as(usize, 4) else @as(usize, 0)) +
        len;
    const b = testing.allocator.alloc(u8, size) catch @panic("oom");
    errdefer testing.allocator.free(b);
    b[0] = (@as(u8, @intFromBool(fin)) << 7) | opcode;
    var i: usize = 1;
    if (len < 126) {
        b[i] = (@as(u8, @intFromBool(mask)) << 7 | @as(u8, @intCast(len)));
        i += 1;
    } else if (len <= std.math.maxInt(u16)) {
        b[i] = (@as(u8, @intFromBool(mask)) << 7 | 126);
        i += 1;
        std.mem.writeInt(u16, b[i..][0..2], @intCast(len), .big);
        i += 2;
    } else {
        b[i] = (@as(u8, @intFromBool(mask)) << 7 | 127);
        i += 1;
        std.mem.writeInt(u64, b[i..][0..8], len, .big);
        i += 8;
    }
    if (mask) {
        @memcpy(b[i..][0..4], &key);
        i += 4;
    }
    for (payload, 0..) |byte, j| {
        b[i + j] = if (mask) byte ^ key[j % 4] else byte;
    }
    return b;
}

/// A valid handshake header set for `upgrade()` unit tests. Header
/// values are comptime literals: any `Request` built from them must
/// NOT be `deinit()`ed (freeing a literal panics under the debug
/// allocator).
fn handshakeHeaders() request.Headers {
    return .{
        .upgrade = "websocket",
        .connection = .upgrade,
        .sec_websocket_key = "dGhlIHNhbXBsZSBub25jZQ==",
        .sec_websocket_version = "13",
    };
}

/// The outcome of `upgrade()` for unit tests. Error values do not
/// compare across error sets, so the result is flattened to an enum.
const UpgradeOutcome = enum { ok, not_websocket, handshake_rejected, upgrade_failed };

/// Run `upgrade()` against a fixed writer and report its outcome. The
/// caller asserts on the writer's contents.
fn upgradeOutcome(
    method: request.Method,
    headers: request.Headers,
    writer: *std.Io.Writer,
) UpgradeOutcome {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reader = std.Io.Reader.fixed("");
    const req = Request{
        .method = method,
        .uri = .{ .path = "/ws" },
        .version = .HTTP_1_1,
        .headers = headers,
        .reader = &reader,
        .writer = writer,
        .allocator = arena.allocator(),
    };
    var res = Response.fromRequest(req);
    const result = upgrade(req, &res);
    return if (result) |_| {
        return .ok;
    } else |err| switch (err) {
        error.NotWebSocket => .not_websocket,
        error.HandshakeRejected => .handshake_rejected,
        error.UpgradeFailed => .upgrade_failed,
    };
}

test "upgrade: a non-GET without an Upgrade header is NotWebSocket" {
    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const outcome = upgradeOutcome(.POST, .{}, &writer);
    try testing.expectEqual(UpgradeOutcome.not_websocket, outcome);
    // Nothing was sent: routing continues untouched.
    try testing.expectEqual(@as(usize, 0), writer.end);
}

test "upgrade: a missing Connection: Upgrade is rejected with a close 400" {
    var headers = handshakeHeaders();
    headers.connection = null;
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const outcome = upgradeOutcome(.GET, headers, &writer);
    try testing.expectEqual(UpgradeOutcome.handshake_rejected, outcome);
    const wire = buf[0..writer.end];
    try testing.expect(std.mem.indexOf(u8, wire, "400 Bad Request") != null);
    try testing.expect(std.mem.indexOf(u8, wire, "Connection: close") != null);
}

test "upgrade: a body-bearing GET is rejected" {
    var headers = handshakeHeaders();
    headers.content_length = 5;
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const outcome = upgradeOutcome(.GET, headers, &writer);
    try testing.expectEqual(UpgradeOutcome.handshake_rejected, outcome);
    const wire = buf[0..writer.end];
    try testing.expect(std.mem.indexOf(u8, wire, "400 Bad Request") != null);
    try testing.expect(std.mem.indexOf(u8, wire, "Connection: close") != null);
}

test "upgrade: a chunked GET is rejected" {
    var headers = handshakeHeaders();
    headers.transfer_encoding = .chunked;
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const outcome = upgradeOutcome(.GET, headers, &writer);
    try testing.expectEqual(UpgradeOutcome.handshake_rejected, outcome);
    const wire = buf[0..writer.end];
    try testing.expect(std.mem.indexOf(u8, wire, "400 Bad Request") != null);
}

test "upgrade: a key that is not 24 base64 characters is rejected" {
    var headers = handshakeHeaders();
    headers.sec_websocket_key = "not-base64!!!";
    var buf: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const outcome = upgradeOutcome(.GET, headers, &writer);
    try testing.expectEqual(UpgradeOutcome.handshake_rejected, outcome);
    const wire = buf[0..writer.end];
    try testing.expect(std.mem.indexOf(u8, wire, "400 Bad Request") != null);
    try testing.expect(std.mem.indexOf(u8, wire, "Connection: close") != null);
}

test "upgrade: a valid handshake echoes the first offered subprotocol" {
    var headers = handshakeHeaders();
    headers.sec_websocket_protocol = "chat, superchat";
    var buf: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const outcome = upgradeOutcome(.GET, headers, &writer);
    try testing.expectEqual(UpgradeOutcome.ok, outcome);
    const wire = buf[0..writer.end];
    try testing.expect(std.mem.indexOf(u8, wire, "101 Switching Protocols") != null);
    try testing.expect(std.mem.indexOf(u8, wire, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);
    // RFC 6455 §4.1: the offered subprotocol must be echoed.
    try testing.expect(std.mem.indexOf(u8, wire, "Sec-WebSocket-Protocol: chat") != null);
}

test "next returns a masked unfragmented text frame (RFC A.1)" {
    const bytes = frame(true, 0x1, true, "Hello");
    defer testing.allocator.free(bytes);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(bytes);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    const msg = try ws.next();
    try testing.expectEqualStrings("Hello", msg.text);
    try testing.expectEqual(@as(usize, 0), writer.end);
}

test "next reassembles a fragmented text message (RFC A.1)" {
    const first = frame(false, 0x1, true, "Hel");
    defer testing.allocator.free(first);
    const second = frame(true, 0x0, true, "lo");
    defer testing.allocator.free(second);
    const all = try testing.allocator.alloc(u8, first.len + second.len);
    defer testing.allocator.free(all);
    @memcpy(all[0..first.len], first);
    @memcpy(all[first.len..], second);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(all);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    const msg = try ws.next();
    try testing.expectEqualStrings("Hello", msg.text);
}

test "next reassembles two consecutive fragmented text messages" {
    // Regression: the finished first message left `frag_len` set, so
    // the second message came back prefixed with the first's payload
    // ("HelloWorld").
    const p1 = frame(false, 0x1, true, "Hel");
    defer testing.allocator.free(p1);
    const p2 = frame(true, 0x0, true, "lo");
    defer testing.allocator.free(p2);
    const p3 = frame(false, 0x1, true, "Wor");
    defer testing.allocator.free(p3);
    const p4 = frame(true, 0x0, true, "ld");
    defer testing.allocator.free(p4);
    const parts = [_][]const u8{ p1, p2, p3, p4 };
    var all: [128]u8 = undefined;
    var p: usize = 0;
    for (parts) |part| {
        @memcpy(all[p .. p + part.len], part);
        p += part.len;
    }
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(all[0..p]);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    const m1 = try ws.next();
    try testing.expectEqualStrings("Hello", m1.text);
    const m2 = try ws.next();
    try testing.expectEqualStrings("World", m2.text);
}

test "next interleaves single-frame and fragmented messages" {
    // Fragment "ab", single "c", fragment "de": the accumulator must
    // survive the single-frame message untouched.
    const p1 = frame(false, 0x1, true, "a");
    defer testing.allocator.free(p1);
    const p2 = frame(true, 0x0, true, "b");
    defer testing.allocator.free(p2);
    const p3 = frame(true, 0x1, true, "c");
    defer testing.allocator.free(p3);
    const p4 = frame(false, 0x2, true, "d");
    defer testing.allocator.free(p4);
    const p5 = frame(true, 0x0, true, "e");
    defer testing.allocator.free(p5);
    const parts = [_][]const u8{ p1, p2, p3, p4, p5 };
    var all: [160]u8 = undefined;
    var p: usize = 0;
    for (parts) |part| {
        @memcpy(all[p .. p + part.len], part);
        p += part.len;
    }
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(all[0..p]);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    const m1 = try ws.next();
    try testing.expectEqualStrings("ab", m1.text);
    const m2 = try ws.next();
    try testing.expectEqualStrings("c", m2.text);
    const m3 = try ws.next();
    try testing.expectEqualStrings("de", m3.binary);
}

test "next returns a masked binary frame (RFC A.1)" {
    const bytes = frame(true, 0x2, true, "Hello World");
    defer testing.allocator.free(bytes);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(bytes);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    const msg = try ws.next();
    try testing.expectEqualStrings("Hello World", msg.binary);
}

test "next returns an empty text frame (RFC A.1)" {
    const bytes = frame(true, 0x1, true, "");
    defer testing.allocator.free(bytes);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(bytes);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    const msg = try ws.next();
    try testing.expectEqualStrings("", msg.text);
}

test "next answers a ping with a pong carrying the same payload" {
    const ping_frame = frame(true, 0x9, true, "hi");
    defer testing.allocator.free(ping_frame);
    const text = frame(true, 0x1, true, "x");
    defer testing.allocator.free(text);
    const all = try testing.allocator.alloc(u8, ping_frame.len + text.len);
    defer testing.allocator.free(all);
    @memcpy(all[0..ping_frame.len], ping_frame);
    @memcpy(all[ping_frame.len..], text);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(all);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    const msg = try ws.next();
    try testing.expectEqualStrings("x", msg.text);
    // Unmasked pong: 0x8a, len 2, "hi".
    try testing.expectEqual(@as(u8, 0x8a), out[0]);
    try testing.expectEqual(@as(u8, 2), out[1]);
    try testing.expectEqualStrings("hi", out[2..4]);
}

test "next surfaces a close frame and echoes it back" {
    const code = [2]u8{ 0x03, 0xe8 }; // 1000
    const bytes = frame(true, 0x8, true, &code);
    defer testing.allocator.free(bytes);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(bytes);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    const msg = try ws.next();
    try testing.expectEqual(@as(u16, 1000), msg.close.code);
    try testing.expectEqualStrings("", msg.close.reason);
    try testing.expect(ws.closed);
    // Echoed close: 0x88, len 2, 0x03 0xe8.
    try testing.expectEqual(@as(u8, 0x88), out[0]);
    try testing.expectEqual(@as(u8, 2), out[1]);
    try testing.expectEqual(@as(u8, 0x03), out[2]);
    try testing.expectEqual(@as(u8, 0xe8), out[3]);
    // Session over: the reader is exhausted.
    try testing.expectError(error.EndOfStream, ws.next());
}

test "next fails the connection with 1002 on an unmasked client frame" {
    const bytes = frame(true, 0x1, false, "Hello");
    defer testing.allocator.free(bytes);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(bytes);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    try testing.expectError(error.ProtocolError, ws.next());
    // Close 1002: 0x88, len 2, 0x03 0xea.
    try testing.expectEqual(@as(u8, 0x88), out[0]);
    try testing.expectEqual(@as(u8, 2), out[1]);
    try testing.expectEqual(@as(u8, 0x03), out[2]);
    try testing.expectEqual(@as(u8, 0xea), out[3]);
}

test "next fails the connection with 1002 on a set RSV bit" {
    var bytes = frame(true, 0x1, true, "Hello");
    defer testing.allocator.free(bytes);
    bytes[0] |= 0x10; // RSV1.
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(bytes);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    try testing.expectError(error.ProtocolError, ws.next());
    try testing.expectEqual(@as(u8, 0x03), out[2]);
    try testing.expectEqual(@as(u8, 0xea), out[3]);
}

test "next fails the connection with 1002 on a reserved opcode" {
    const bytes = frame(true, 0x3, true, "x");
    defer testing.allocator.free(bytes);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(bytes);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    try testing.expectError(error.ProtocolError, ws.next());
}

test "next fails the connection with 1002 on an unfragmented control frame" {
    // FIN=0 on a ping.
    const bytes = frame(false, 0x9, true, "x");
    defer testing.allocator.free(bytes);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(bytes);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    try testing.expectError(error.ProtocolError, ws.next());
}

test "next fails the connection with 1002 on an oversized control frame" {
    const payload = [_]u8{0} ** 126;
    const bytes = frame(true, 0x9, true, &payload);
    defer testing.allocator.free(bytes);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(bytes);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    try testing.expectError(error.ProtocolError, ws.next());
}

test "next fails the connection with 1009 on a frame over max_payload" {
    const payload = [_]u8{0xAA} ** 50;
    const bytes = frame(true, 0x2, true, &payload);
    defer testing.allocator.free(bytes);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(bytes);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator(), .max_payload = 40 };

    try testing.expectError(error.ProtocolError, ws.next());
    // Close 1009: 0x88, len 2, 0x03 0xf1.
    try testing.expectEqual(@as(u8, 0x88), out[0]);
    try testing.expectEqual(@as(u8, 2), out[1]);
    try testing.expectEqual(@as(u8, 0x03), out[2]);
    try testing.expectEqual(@as(u8, 0xf1), out[3]);
}

test "next fails the connection with 1009 when fragments sum over max_payload" {
    const first = frame(false, 0x2, true, "0123456789");
    defer testing.allocator.free(first);
    const second = frame(true, 0x0, true, "0123456789");
    defer testing.allocator.free(second);
    var all: [32]u8 = undefined;
    @memcpy(all[0..first.len], first);
    @memcpy(all[first.len..][0..second.len], second);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(&all);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator(), .max_payload = 15 };

    try testing.expectError(error.ProtocolError, ws.next());
    try testing.expectEqual(@as(u8, 0x03), out[2]);
    try testing.expectEqual(@as(u8, 0xf1), out[3]);
}

test "next accepts a frame exactly at max_payload" {
    const payload = [_]u8{0xAA} ** 10;
    const bytes = frame(true, 0x2, true, &payload);
    defer testing.allocator.free(bytes);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(bytes);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator(), .max_payload = 10 };

    const msg = try ws.next();
    try testing.expectEqualSlices(u8, &payload, msg.binary);
}

test "next fails the connection with 1002 on a stray continuation frame" {
    const bytes = frame(true, 0x0, true, "x");
    defer testing.allocator.free(bytes);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(bytes);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    try testing.expectError(error.ProtocolError, ws.next());
}

test "next fails the connection with 1002 on a data frame while a sequence is open" {
    const first = frame(false, 0x1, true, "a");
    defer testing.allocator.free(first);
    const second = frame(true, 0x1, true, "b");
    defer testing.allocator.free(second);
    const all = try testing.allocator.alloc(u8, first.len + second.len);
    defer testing.allocator.free(all);
    @memcpy(all[0..first.len], first);
    @memcpy(all[first.len..], second);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(all);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    try testing.expectError(error.ProtocolError, ws.next());
}

test "ping and pong drop a payload over the 125-byte control frame limit" {
    const payload = [_]u8{0xA0} ** 126;
    const nothing: []const u8 = "";
    var reader = std.Io.Reader.fixed(nothing);
    var out: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    // Over-limit payloads are dropped whole: a truncated pong would
    // not match its ping, and no frame may exceed the limit.
    ws.ping(&payload);
    ws.pong(&payload);
    try testing.expectEqual(@as(usize, 0), writer.end);
    try testing.expect(!ws.failed);

    // In-range payloads still go out, unmasked: 0x89, len 2, "hi".
    ws.ping("hi");
    try testing.expectEqual(@as(usize, 4), writer.end);
    try testing.expectEqual(@as(u8, 0x89), out[0]);
    try testing.expectEqual(@as(u8, 2), out[1]);
    try testing.expectEqualStrings("hi", out[2..4]);
}

test "close clips the reason to the 125-byte frame limit" {
    const reason = [_]u8{'x'} ** 200;
    const nothing: []const u8 = "";
    var reader = std.Io.Reader.fixed(nothing);
    var out: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    ws.close(.normal_closure, &reason);
    // Close 1000 plus a 123-byte reason: the payload is clipped to 125.
    try testing.expectEqual(@as(u8, 0x88), out[0]);
    try testing.expectEqual(@as(u8, 125), out[1]);
    try testing.expectEqual(@as(u16, 1000), std.mem.readInt(u16, out[2..4], .big));
    try testing.expectEqualStrings("xxx", out[4..7]);
    try testing.expectEqual(@as(usize, 127), writer.end);
}

test "next fails the connection with 1002 on a data frame after close" {
    const code = [2]u8{ 0x03, 0xe8 }; // 1000
    const close_frame = frame(true, 0x8, true, &code);
    defer testing.allocator.free(close_frame);
    const text = frame(true, 0x1, true, "late");
    defer testing.allocator.free(text);
    const all = try testing.allocator.alloc(u8, close_frame.len + text.len);
    defer testing.allocator.free(all);
    @memcpy(all[0..close_frame.len], close_frame);
    @memcpy(all[close_frame.len..], text);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(all);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    const msg = try ws.next();
    try testing.expectEqual(@as(u16, 1000), msg.close.code);

    // A data frame after the Close violates RFC 6455 §5.5.1.
    try testing.expectError(error.ProtocolError, ws.next());
    try testing.expectEqual(@as(usize, 4), writer.end);
}

test "next fails the connection with 1002 on a ping after close" {
    const code = [2]u8{ 0x03, 0xe8 }; // 1000
    const close_frame = frame(true, 0x8, true, &code);
    defer testing.allocator.free(close_frame);
    const ping_frame = frame(true, 0x9, true, "abc");
    defer testing.allocator.free(ping_frame);
    const all = try testing.allocator.alloc(u8, close_frame.len + ping_frame.len);
    defer testing.allocator.free(all);
    @memcpy(all[0..close_frame.len], close_frame);
    @memcpy(all[close_frame.len..], ping_frame);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(all);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    const msg = try ws.next();
    try testing.expectEqual(@as(u16, 1000), msg.close.code);

    // A control frame after the Close violates RFC 6455 §5.5.1.
    try testing.expectError(error.ProtocolError, ws.next());
    // No pong is written, and the echoed close is the only output.
    try testing.expectEqual(@as(usize, 4), writer.end);
}

test "next fails the connection with 1002 on a second close after a malformed close" {
    const bad = [2]u8{ 0x03, 0xee }; // 1006: local-only, never on the wire
    const first = frame(true, 0x8, true, &bad);
    defer testing.allocator.free(first);
    const good = [2]u8{ 0x03, 0xe8 }; // 1000
    const second = frame(true, 0x8, true, &good);
    defer testing.allocator.free(second);
    const all = try testing.allocator.alloc(u8, first.len + second.len);
    defer testing.allocator.free(all);
    @memcpy(all[0..first.len], first);
    @memcpy(all[first.len..], second);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(all);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    // The local-only 1006 fails the connection with 1002: 0x88, len 2,
    // 0x03 0xea.
    try testing.expectError(error.ProtocolError, ws.next());
    try testing.expectEqual(@as(u8, 0x88), out[0]);
    try testing.expectEqual(@as(u8, 2), out[1]);
    try testing.expectEqual(@as(u8, 0x03), out[2]);
    try testing.expectEqual(@as(u8, 0xea), out[3]);

    // The peer's response Close is itself a second Close: it fails
    // again, and the session is already over so nothing more is
    // written.
    try testing.expectError(error.ProtocolError, ws.next());
    try testing.expectEqual(@as(usize, 4), writer.end);
}

test "next fails the connection with 1007 on invalid UTF-8 text" {
    const payload = [2]u8{ 0xff, 0xfe };
    const bytes = frame(true, 0x1, true, &payload);
    defer testing.allocator.free(bytes);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(bytes);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    try testing.expectError(error.ProtocolError, ws.next());
    // Close 1007: 0x03 0xef.
    try testing.expectEqual(@as(u8, 0x03), out[2]);
    try testing.expectEqual(@as(u8, 0xef), out[3]);
}

test "next fails the connection with 1002 on a malformed close payload" {
    const payloads = [_][]const u8{ &[_]u8{0x01}, &[_]u8{ 0x03, 0xe5 } };
    for (payloads) |close_payload| {
        // 1 byte; or 1005 on the wire.
        const bytes = frame(true, 0x8, true, close_payload);
        defer testing.allocator.free(bytes);
        var out: [64]u8 = undefined;
        var reader = std.Io.Reader.fixed(bytes);
        var writer = std.Io.Writer.fixed(&out);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

        try testing.expectError(error.ProtocolError, ws.next());
        try testing.expectEqual(@as(u8, 0x03), out[2]);
        try testing.expectEqual(@as(u8, 0xea), out[3]);
    }
}

test "next fails the connection with 1002 on a second close frame" {
    const code = [2]u8{ 0x03, 0xe8 }; // 1000
    const first = frame(true, 0x8, true, &code);
    defer testing.allocator.free(first);
    const second = frame(true, 0x8, true, &code);
    defer testing.allocator.free(second);
    var all: [16]u8 = undefined;
    @memcpy(all[0..first.len], first);
    @memcpy(all[first.len..][0..second.len], second);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(&all);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    const msg = try ws.next();
    try testing.expectEqual(@as(u16, 1000), msg.close.code);
    try testing.expectError(error.ProtocolError, ws.next());
    // The echo went out once; the violation adds no further frame.
    try testing.expectEqual(@as(usize, 4), writer.end);
    // The reader is exhausted: the session is over.
    try testing.expectError(error.EndOfStream, ws.next());
}

test "next fails the connection with 1002 on an explicit zero close code" {
    const payload = [2]u8{ 0x00, 0x00 };
    const bytes = frame(true, 0x8, true, &payload);
    defer testing.allocator.free(bytes);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(bytes);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    try testing.expectError(error.ProtocolError, ws.next());
    // Close 1002: 0x88, len 2, 0x03 0xea.
    try testing.expectEqual(@as(u8, 0x88), out[0]);
    try testing.expectEqual(@as(u8, 2), out[1]);
    try testing.expectEqual(@as(u8, 0x03), out[2]);
    try testing.expectEqual(@as(u8, 0xea), out[3]);
}

test "next accepts a close frame with no status code" {
    const bytes = frame(true, 0x8, true, &[_]u8{});
    defer testing.allocator.free(bytes);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(bytes);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    const msg = try ws.next();
    try testing.expectEqual(@as(u16, 0), msg.close.code);
    try testing.expectEqualStrings("", msg.close.reason);
    // Echoed close: 0x88, len 0.
    try testing.expectEqual(@as(u8, 0x88), out[0]);
    try testing.expectEqual(@as(u8, 0), out[1]);
}

test "next returns ReadFailed when the automatic pong write fails" {
    var bytes: [6]u8 = .{ 0x89, 0x80, 0x00, 0x00, 0x00, 0x00 }; // masked ping, no payload
    var reader = std.Io.Reader.fixed(&bytes);
    var failing = std.Io.Writer.failing;
    var ws = @This(){
        .reader = &reader,
        .writer = &failing,
        .allocator = testing.allocator,
    };

    try testing.expectError(error.ReadFailed, ws.next());
    // The latch is set: a later next() fails without reading.
    try testing.expect(ws.failed);
    try testing.expectError(error.ReadFailed, ws.next());
}

test "next returns a 16-bit extended-length binary message" {
    var payload: [200]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);
    const bytes = frame(true, 0x2, true, &payload);
    defer testing.allocator.free(bytes);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(bytes);
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    const msg = try ws.next();
    try testing.expectEqualSlices(u8, &payload, msg.binary);
}

test "next returns a 64-bit extended-length binary message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const payload = try arena.allocator().alloc(u8, 70000);
    for (payload, 0..) |*b, i| b.* = @truncate(i);
    const bytes = frame(true, 0x2, true, payload);
    defer testing.allocator.free(bytes);
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed(bytes);
    var writer = std.Io.Writer.fixed(&out);
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    const msg = try ws.next();
    try testing.expectEqualSlices(u8, payload, msg.binary);
}

test "sendText writes an unmasked text frame" {
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed("");
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    ws.sendText("Hello");
    // 0x81, len 5, "Hello".
    try testing.expectEqual(@as(u8, 0x81), out[0]);
    try testing.expectEqual(@as(u8, 5), out[1]);
    try testing.expectEqualStrings("Hello", out[2..7]);
}

test "sendBinary uses the 16-bit and 64-bit length encodings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var reader = std.Io.Reader.fixed("");
    var sink = std.Io.Writer.Allocating.init(arena.allocator());
    defer sink.deinit();
    var ws = @This(){ .reader = &reader, .writer = &sink.writer, .allocator = arena.allocator() };

    const small = [_]u8{0xAA} ** 300;
    ws.sendBinary(&small);
    var written = sink.written();
    try testing.expectEqual(@as(u8, 0x82), written[0]);
    try testing.expectEqual(@as(u8, 126), written[1]);
    try testing.expectEqual(@as(u16, 300), (@as(u16, written[2]) << 8) | @as(u16, written[3]));
    try testing.expectEqual(@as(u8, 0xAA), written[4]);

    const off = written.len;
    const big = try arena.allocator().alloc(u8, 70000);
    @memset(big, 0xBB);
    ws.sendBinary(big);
    written = sink.written();
    try testing.expectEqual(@as(u8, 127), written[off + 1]);
    var big_len: u64 = 0;
    for (written[off + 2 .. off + 10]) |b| big_len = (big_len << 8) | b;
    try testing.expectEqual(@as(u64, 70000), big_len);
    try testing.expectEqual(@as(u8, 0xBB), written[off + 10]);
}

test "close writes a close frame and subsequent sends are no-ops" {
    var out: [64]u8 = undefined;
    var reader = std.Io.Reader.fixed("");
    var writer = std.Io.Writer.fixed(&out);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ws = @This(){ .reader = &reader, .writer = &writer, .allocator = arena.allocator() };

    ws.close(.normal_closure, "bye");
    // 0x88, len 5, 0x03 0xe8, "bye".
    try testing.expectEqual(@as(u8, 0x88), out[0]);
    try testing.expectEqual(@as(u8, 5), out[1]);
    try testing.expectEqual(@as(u16, 1000), std.mem.readInt(u16, out[2..4], .big));
    try testing.expectEqualStrings("bye", out[4..7]);
    try testing.expect(ws.closed);

    const end = writer.end;
    ws.sendText("after close");
    ws.close(.going_away, "");
    try testing.expectEqual(end, writer.end);
}

test "a failed write latches failed and stops next() from reading" {
    var bytes: [7]u8 = .{ 0x81, 0x05, 'H', 'e', 'l', 'l', 'o' };
    var reader = std.Io.Reader.fixed(&bytes);
    var failing = std.Io.Writer.failing;
    var ws = @This(){
        .reader = &reader,
        .writer = &failing,
        .allocator = testing.allocator,
    };
    ws.sendText("x");
    try testing.expect(ws.failed);
    try testing.expectError(error.ReadFailed, ws.next());
}

// Integration tests: a live `Loop` over real TCP, with a raw
// (hand-assembled, masked) WebSocket client.

const WsEchoHandler = struct {
    pub fn handle(_: @This(), req: Request, res: *Response) !void {
        var ws = upgrade(req, res) catch |err| switch (err) {
            error.NotWebSocket => return error.Skipped,
            else => return,
        };
        while (true) {
            const msg = ws.next() catch return;
            switch (msg) {
                .text => |t| ws.sendText(t),
                .binary => |b| ws.sendBinary(b),
                .close => return,
            }
        }
    }
};

const WsTestServer = struct {
    server: http.Server,
    loop: Loop,
    state: WsEchoHandler,
    wrap: Handler.wrap(WsEchoHandler),

    fn start(self: *@This(), io: std.Io, allocator: std.mem.Allocator) !void {
        self.state = .{};
        self.wrap = Handler.wrap(WsEchoHandler).init(&self.state);

        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        self.server = http.Server.init(io, allocator, address, .{});
        try self.server.listen();
        errdefer self.server.deinit();

        self.loop = Loop.init(io, &self.server, self.wrap.interface()) catch |err| {
            self.server.deinit();
            return err;
        };
        try self.loop.start();
    }

    fn stop(self: *@This()) void {
        self.loop.deinit();
        self.server.deinit();
    }

    fn boundAddress(self: *@This()) std.Io.net.IpAddress {
        return self.server.getAddress().?;
    }
};

/// Read from the stream until the header terminator `\r\n\r\n` (inclusive).
fn readHandshake(r: *std.Io.Reader, buf: *[8192]u8) ![]const u8 {
    var i: usize = 0;
    while (true) {
        const b = (try r.take(1))[0];
        if (i >= buf.len) return error.StreamTooLong;
        buf[i] = b;
        i += 1;
        if (i >= 4 and buf[i - 4] == '\r' and buf[i - 3] == '\n' and
            buf[i - 2] == '\r' and buf[i - 1] == '\n')
        {
            return buf[0..i];
        }
    }
}

/// Decode one complete, unmasked server frame from the stream. The
/// payload is freshly allocated; the caller frees it.
fn readUnmaskedFrame(
    r: *std.Io.Reader,
    allocator: std.mem.Allocator,
) !struct { opcode: u8, payload: []u8 } {
    const b01 = try r.take(2);
    try testing.expect(b01[0] & 0x80 != 0); // FIN: the test server never fragments
    try testing.expect(b01[1] & 0x80 == 0); // the server never masks
    var len: usize = b01[1] & 0x7F;
    if (len == 126) {
        const ext = try r.take(2);
        len = @as(usize, ext[0]) * 256 + ext[1];
    } else if (len == 127) {
        const ext = try r.take(8);
        var l: u64 = 0;
        for (ext) |b| l = (l << 8) | b;
        len = @intCast(l);
    }
    const payload = try r.readAlloc(allocator, len);
    return .{ .opcode = b01[0] & 0x0F, .payload = payload };
}

test "integration: handshake, text echo, ping/pong, close over a live loop" {
    const io = testing.io;
    const allocator = testing.allocator;

    var ts: WsTestServer = undefined;
    try ts.start(io, allocator);
    defer ts.stop();

    var stream = try std.Io.net.IpAddress.connect(&ts.boundAddress(), io, .{ .mode = .stream });
    defer stream.close(io);

    var wbuf: [1024]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);

    // 1. Handshake with the RFC 6455 §1.3 sample key.
    try w.interface.writeAll(
        "GET /ws HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n",
    );
    try w.interface.flush();

    var hs_buf: [8192]u8 = undefined;
    const hs = try readHandshake(&r.interface, &hs_buf);
    try testing.expect(std.mem.indexOf(u8, hs, "101 Switching Protocols") != null);
    try testing.expect(std.mem.indexOf(u8, hs, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);

    // 2. A masked text frame is echoed back verbatim.
    const hello = frame(true, 0x1, true, "Hello WebSocket");
    defer allocator.free(hello);
    try w.interface.writeAll(hello);
    try w.interface.flush();
    const echo = try readUnmaskedFrame(&r.interface, allocator);
    defer allocator.free(echo.payload);
    try testing.expectEqual(@as(u8, 0x1), echo.opcode);
    try testing.expectEqualStrings("Hello WebSocket", echo.payload);

    // 3. A ping is answered with a pong carrying the same payload.
    const ping_frame = frame(true, 0x9, true, "ping-payload");
    defer allocator.free(ping_frame);
    try w.interface.writeAll(ping_frame);
    try w.interface.flush();
    const pong_frame = try readUnmaskedFrame(&r.interface, allocator);
    defer allocator.free(pong_frame.payload);
    try testing.expectEqual(@as(u8, 0xA), pong_frame.opcode);
    try testing.expectEqualStrings("ping-payload", pong_frame.payload);

    // 4. Close handshake: the server echoes the Close frame, then
    // closes the TCP connection.
    const close_code = [_]u8{ 0x03, 0xE8 }; // 1000.
    const close_frame = frame(true, 0x8, true, &close_code);
    defer allocator.free(close_frame);
    try w.interface.writeAll(close_frame);
    try w.interface.flush();
    const echoed = try readUnmaskedFrame(&r.interface, allocator);
    defer allocator.free(echoed.payload);
    try testing.expectEqual(@as(u8, 0x8), echoed.opcode);
    try testing.expectEqual(
        @as(u16, 1000),
        (@as(u16, echoed.payload[0]) << 8) | @as(u16, echoed.payload[1]),
    );
    // The session is over: the next read hits the closed connection.
    try testing.expectError(error.EndOfStream, r.interface.take(1));
}

test "integration: an invalid upgrade request gets a 400" {
    const io = testing.io;
    const allocator = testing.allocator;

    var ts: WsTestServer = undefined;
    try ts.start(io, allocator);
    defer ts.stop();

    var stream = try std.Io.net.IpAddress.connect(&ts.boundAddress(), io, .{ .mode = .stream });
    defer stream.close(io);

    var wbuf: [1024]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    // A well-formed upgrade request whose key is not 24 base64
    // characters. The 400 must carry `Connection: close` (it has no
    // body): that frames the message and drops the connection
    // immediately instead of waiting out the idle deadline.
    try w.interface.writeAll(
        "GET /ws HTTP/1.1\r\n" ++
            "Host: x\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Sec-WebSocket-Key: not-base64!!!\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n",
    );
    try w.interface.flush();

    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    const resp = try r.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "400 Bad Request") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "Connection: close") != null);
}

test "integration: the 101 echoes the first offered subprotocol" {
    const io = testing.io;
    const allocator = testing.allocator;

    var ts: WsTestServer = undefined;
    try ts.start(io, allocator);
    defer ts.stop();

    var stream = try std.Io.net.IpAddress.connect(&ts.boundAddress(), io, .{ .mode = .stream });
    defer stream.close(io);

    var wbuf: [1024]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll(
        "GET /ws HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "Sec-WebSocket-Protocol: chat, superchat\r\n" ++
            "\r\n",
    );
    try w.interface.flush();

    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var hs_buf: [8192]u8 = undefined;
    const hs = try readHandshake(&r.interface, &hs_buf);
    try testing.expect(std.mem.indexOf(u8, hs, "101 Switching Protocols") != null);
    // RFC 6455 §4.1: the server MUST echo the header when the client
    // sent it — clients that requested subprotocols and got none treat
    // the handshake as failed.
    try testing.expect(std.mem.indexOf(u8, hs, "Sec-WebSocket-Protocol: chat") != null);
}

const std = @import("std");
const testing = std.testing;
const log = std.log.scoped(.vish);

const http = @import("server.zig");
const Loop = @import("../loop/loop.zig").Loop;
const Handler = @import("../loop/handler.zig").Handler;

const request = @import("request.zig");
const Request = request.Request;
const Response = @import("response.zig").Response;
const response = @import("response.zig");

