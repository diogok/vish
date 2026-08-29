//! TCP socket helpers: listener option setters (Linux only; other
//! platforms are no-ops) and a timed wait for input.

/// Block until `socket` has input to read or `timeout_ms` elapses.
/// Peeks, so the bytes stay for the caller's reader; when the peer
/// has closed or the socket has failed, the call returns normally and
/// the caller's next read reports it. An Io that cannot wait with a
/// deadline also returns normally, and that read blocks without one.
pub fn waitReadable(io: std.Io, socket: std.Io.net.Socket, timeout_ms: u32) error{Timeout}!void {
    var peek_buf: [1]u8 = undefined;
    var messages: [1]std.Io.net.IncomingMessage = .{.init};
    const maybe_err, _ = socket.receiveManyTimeout(
        io,
        &messages,
        &peek_buf,
        .{ .peek = true },
        .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } },
    );
    if (maybe_err) |err| switch (err) {
        error.Timeout => return error.Timeout,
        error.ConcurrencyUnavailable => log.warn("read deadline unavailable for this cycle", .{}),
        else => {},
    };
}

/// Set listener socket options. `tcp_keep_alive` enables `SO_KEEPALIVE`;
/// `tcp_no_delay` enables `TCP_NODELAY` (disables Nagle).
pub fn setServerFlags(fd: std.posix.socket_t, options: struct { tcp_keep_alive: bool, tcp_no_delay: bool }) !void {
    switch (builtin.os.tag) {
        .linux => {
            if (options.tcp_keep_alive) {
                try std.posix.setsockopt(
                    fd,
                    std.posix.SOL.SOCKET,
                    std.posix.SO.KEEPALIVE,
                    &std.mem.toBytes(@as(c_int, 1)),
                );
            }
            if (options.tcp_no_delay) {
                try std.posix.setsockopt(
                    fd,
                    std.posix.IPPROTO.TCP,
                    std.posix.TCP.NODELAY,
                    &std.mem.toBytes(@as(c_int, 1)),
                );
            }
        },
        else => {},
    }
}

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.vish);
