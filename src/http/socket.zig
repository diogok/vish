//! Socket configuration utilities for TCP server operations.
//!
//! Provides cross-platform utilities for configuring TCP sockets,
//! like timeout, keep-alive, and TCP No Delay.

/// Set send and receive timeout on the socket.
pub fn setTimeout(
    fd: std.posix.socket_t,
    read_timeout_in_millis: u32,
    write_timeout_in_millis: u32,
) !void {
    const read_timeout = makeTimevalue(read_timeout_in_millis);
    const read_value: []const u8 = std.mem.toBytes(read_timeout)[0..];
    try std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        read_value,
    );

    const write_timeout = makeTimevalue(write_timeout_in_millis);
    const write_value: []const u8 = std.mem.toBytes(write_timeout)[0..];
    try std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDTIMEO,
        write_value,
    );
}

/// Convert milliseconds to a POSIX timeval structure.
///
/// This is used for setting socket timeout options (SO_RCVTIMEO, SO_SNDTIMEO).
/// The timeval structure splits time into seconds and microseconds.
pub fn makeTimevalue(millis: u32) std.posix.timeval {
    const micros: i32 = @as(i32, @intCast(millis)) * 1000;

    var timeval: std.posix.timeval = undefined;
    timeval.sec = @intCast(@divTrunc(micros, 1000000));
    timeval.usec = @intCast(@mod(micros, 1000000));

    return timeval;
}

/// Wait until a connection is ready to be accepted on the given socket.
///
/// Uses platform-specific polling mechanisms:
/// - Windows: select() with fd_set
/// - Other platforms: poll() with pollfd
///
/// Returns `error.Timeout` if no connection is ready within the timeout period.
/// This allows the server to periodically check for shutdown signals.
pub fn wait(fd: std.posix.socket_t, timeout_in_ms: u32) !void {
    switch (builtin.os.tag) {
        .windows => {
            var fd_set = std.mem.zeroes(std.os.windows.ws2_32.fd_set);
            fd_set.fd_count = 1;
            fd_set.fd_array[0] = fd;
            const pTimeval = makeTimevalue(timeout_in_ms);
            const timeval = std.os.windows.ws2_32.timeval{
                .tv_sec = pTimeval.tv_sec,
                .tv_usec = pTimeval.tv_usec,
            };
            const timeout: ?*const @TypeOf(timeval) = &timeval;
            const r = std.os.windows.ws2_32.select(1, &fd_set, null, null, timeout);
            if (r == 0) {
                return error.Timeout;
            }
        },
        else => {
            var fds = [_]std.posix.pollfd{
                .{ .fd = fd, .events = 1, .revents = 0 },
            };
            const r = try std.posix.poll(&fds, @as(i32, @intCast(timeout_in_ms)));
            if (r == 0) {
                return error.Timeout;
            }
        },
    }
    return;
}

/// Set common TCP server socket options.
///
/// ## Options
/// - `tcp_keep_alive`: Enable TCP keep-alive probes to detect dead connections
/// - `tcp_no_delay`: Disable Nagle's algorithm for lower latency (sends small packets immediately)
///
/// Note: Currently only implemented for Linux. Other platforms are no-ops.
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

test "makeTimevalue converts milliseconds to seconds and microseconds" {
    // Test exact seconds
    const tv1 = makeTimevalue(1000);
    try testing.expectEqual(@as(isize, 1), tv1.sec);
    try testing.expectEqual(@as(isize, 0), tv1.usec);

    // Test with microseconds remainder
    const tv2 = makeTimevalue(1500);
    try testing.expectEqual(@as(isize, 1), tv2.sec);
    try testing.expectEqual(@as(isize, 500000), tv2.usec);

    // Test zero
    const tv3 = makeTimevalue(0);
    try testing.expectEqual(@as(isize, 0), tv3.sec);
    try testing.expectEqual(@as(isize, 0), tv3.usec);

    // Test milliseconds only (less than 1 second)
    const tv4 = makeTimevalue(250);
    try testing.expectEqual(@as(isize, 0), tv4.sec);
    try testing.expectEqual(@as(isize, 250000), tv4.usec);

    // Test multiple seconds
    const tv5 = makeTimevalue(5000);
    try testing.expectEqual(@as(isize, 5), tv5.sec);
    try testing.expectEqual(@as(isize, 0), tv5.usec);
}

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
