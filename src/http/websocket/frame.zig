//! WebSocket frame codec (RFC 6455 §5): header decode and encode,
//! payload masking, opcodes and close codes, and the handshake's
//! accept-key derivation (§4.2.2). Shared by the server session in
//! `websocket.zig` and the client in `websocket/client.zig`.

/// Frame opcode (RFC 6455 §5.5). Tags 3-7 and 11-15 are reserved
/// and never named: `readHeader` rejects them.
pub const OpCode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,

    /// Control frames (Close, Ping, Pong) may interleave with a
    /// fragmented message and are never fragmented themselves.
    pub fn control(opcode: OpCode) bool {
        return @intFromEnum(opcode) >= 8;
    }
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

/// Maximum payload of a control frame (RFC 6455 §5.5).
pub const control_payload_max = 125;
/// Largest header: two fixed bytes, an 8-byte length, a 4-byte mask
/// key.
pub const header_max = 14;
/// `Sec-WebSocket-Key` is base64 of exactly 16 bytes (RFC 6455
/// §4.1); in the standard alphabet with padding that is 24 chars.
pub const key_b64_len = 24;
/// The 16 bytes a valid key decodes to.
pub const key_raw_len = 16;
/// `Sec-WebSocket-Accept` is base64 of a 20-byte SHA-1.
pub const accept_len = 28;
/// The GUID concatenated with the key before the SHA-1 (RFC 6455
/// §4.2.2).
const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// A frame header as read off the wire. When `masked`, the 4-byte
/// key follows it on the wire: `readMaskKey`.
pub const Header = struct {
    fin: bool,
    opcode: OpCode,
    masked: bool,
    len: usize,
};

pub const DecodeError = error{
    /// An RSV bit set (no extension is ever negotiated), a reserved
    /// opcode, a fragmented or over-long control frame, or a length
    /// beyond the address space (RFC 6455 §5.2, §5.5).
    ProtocolViolation,
} || std.Io.Reader.Error;

/// Read and validate one frame header, up to but not including the
/// mask key.
pub fn readHeader(reader: *std.Io.Reader) DecodeError!Header {
    const head = try reader.take(2);
    const fin = head[0] & 0x80 != 0;
    const rsv = (head[0] >> 4) & 0x07;
    const op = head[0] & 0x0F;
    const masked = head[1] & 0x80 != 0;
    var len: usize = head[1] & 0x7F;
    if (len == 126) {
        const ext = try reader.take(2);
        len = @as(usize, ext[0]) * 256 + ext[1];
    } else if (len == 127) {
        const ext = try reader.take(8);
        var len64: u64 = 0;
        for (ext) |byte| len64 = (len64 << 8) | byte;
        if (len64 > @as(u64, std.math.maxInt(usize))) return error.ProtocolViolation;
        len = @intCast(len64);
    }
    // Reserved opcodes are rejected before the enum conversion.
    if (rsv != 0 or (op >= 3 and op <= 7) or op >= 11) return error.ProtocolViolation;
    const opcode: OpCode = @enumFromInt(op);
    if (opcode.control() and (!fin or len > control_payload_max)) return error.ProtocolViolation;
    return .{ .fin = fin, .opcode = opcode, .masked = masked, .len = len };
}

/// Read the 4-byte mask key that follows a masked frame's header.
/// Returned by value: a slice into the reader would not survive the
/// payload read that follows.
pub fn readMaskKey(reader: *std.Io.Reader) std.Io.Reader.Error![4]u8 {
    return (try reader.takeArray(4)).*;
}

/// XOR `payload` with `key`, starting `offset` bytes into the frame's
/// payload so a payload processed in pieces continues the key cycle.
/// Masking and unmasking are the same operation (RFC 6455 §5.3).
pub fn mask(payload: []u8, key: [4]u8, offset: usize) void {
    for (payload, 0..) |*byte, i| byte.* ^= key[(offset + i) % 4];
}

/// Encode a frame header into `buffer`: FIN and opcode, the payload
/// length in its shortest form, and the mask bit with `mask_key`
/// when given. Returns the encoded prefix of `buffer`.
pub fn encodeHeader(
    buffer: *[header_max]u8,
    fin: bool,
    opcode: OpCode,
    len: usize,
    mask_key: ?[4]u8,
) []const u8 {
    var i: usize = 0;
    buffer[i] = (@as(u8, @intFromBool(fin)) << 7) | @intFromEnum(opcode);
    i += 1;
    const mask_bit: u8 = @as(u8, @intFromBool(mask_key != null)) << 7;
    if (len < 126) {
        buffer[i] = mask_bit | @as(u8, @intCast(len));
        i += 1;
    } else if (len <= std.math.maxInt(u16)) {
        buffer[i] = mask_bit | 126;
        i += 1;
        std.mem.writeInt(u16, buffer[i..][0..2], @intCast(len), .big);
        i += 2;
    } else {
        buffer[i] = mask_bit | 127;
        i += 1;
        std.mem.writeInt(u64, buffer[i..][0..8], len, .big);
        i += 8;
    }
    if (mask_key) |key| {
        @memcpy(buffer[i..][0..4], &key);
        i += 4;
    }
    return buffer[0..i];
}

/// The `Sec-WebSocket-Accept` value for a `Sec-WebSocket-Key` as it
/// appears on the wire (RFC 6455 §4.2.2): base64 of the SHA-1 of the
/// key followed by the GUID.
pub fn acceptKey(key: *const [key_b64_len]u8) [accept_len]u8 {
    var input: [key_b64_len + magic.len]u8 = undefined;
    @memcpy(input[0..key_b64_len], key);
    @memcpy(input[key_b64_len..], magic);
    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(&input, &digest, .{});
    var accept: [accept_len]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept, &digest);
    return accept;
}

test "acceptKey derives the RFC 6455 §1.3 sample" {
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &acceptKey("dGhlIHNhbXBsZSBub25jZQ=="));
}

test "encodeHeader and readHeader round-trip every length form" {
    const cases = [_]struct { len: usize, header_len: usize }{
        .{ .len = 0, .header_len = 2 },
        .{ .len = 5, .header_len = 2 },
        .{ .len = 125, .header_len = 2 },
        .{ .len = 126, .header_len = 4 },
        .{ .len = 65535, .header_len = 4 },
        .{ .len = 65536, .header_len = 10 },
    };
    const keys = [_]?[4]u8{ null, .{ 1, 2, 3, 4 } };
    for (cases) |case| {
        for (keys) |key| {
            var buffer: [header_max]u8 = undefined;
            const encoded = encodeHeader(&buffer, true, .binary, case.len, key);
            // Shortest form, plus the key when masked.
            try testing.expectEqual(case.header_len + @as(usize, if (key != null) 4 else 0), encoded.len);

            var reader = std.Io.Reader.fixed(encoded);
            const header = try readHeader(&reader);
            try testing.expect(header.fin);
            try testing.expectEqual(OpCode.binary, header.opcode);
            try testing.expectEqual(key != null, header.masked);
            try testing.expectEqual(case.len, header.len);
            if (key) |expected| {
                const got = try readMaskKey(&reader);
                try testing.expectEqualSlices(u8, &expected, &got);
            }
            try testing.expectEqual(@as(usize, 0), reader.bufferedLen());
        }
    }
}

test "readHeader rejects reserved bits, reserved opcodes and malformed control frames" {
    const bad = [_][]const u8{
        &.{ 0x91, 0x00 }, // RSV1 set
        &.{ 0x83, 0x00 }, // opcode 3, reserved
        &.{ 0x8b, 0x00 }, // opcode 11, reserved
        &.{ 0x09, 0x00 }, // ping without FIN
        &.{ 0x89, 0x7e, 0x00, 0x7e }, // ping with a 126-byte payload
    };
    for (bad) |bytes| {
        var reader = std.Io.Reader.fixed(bytes);
        try testing.expectError(error.ProtocolViolation, readHeader(&reader));
    }
}

test "mask reproduces the RFC 6455 §5.7 masked Hello" {
    var payload = "Hello".*;
    mask(&payload, .{ 0x37, 0xfa, 0x21, 0x3d }, 0);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x7f, 0x9f, 0x4d, 0x51, 0x58 }, &payload);
}

test "mask continues the key cycle across offsets and undoes itself" {
    const key = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };
    var whole = "Hello, WebSocket".*;
    var pieces = whole;
    mask(&whole, key, 0);
    mask(pieces[0..5], key, 0);
    mask(pieces[5..], key, 5);
    try testing.expectEqualSlices(u8, &whole, &pieces);
    mask(&whole, key, 0);
    try testing.expectEqualStrings("Hello, WebSocket", &whole);
}

const std = @import("std");
const testing = std.testing;
