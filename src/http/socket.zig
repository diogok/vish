//! Socket configuration utilities for TCP server operations.
//!
//! Provides helpers for setting common TCP server socket options
//! (keep-alive, no-delay) on the listening socket.

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

const std = @import("std");
const builtin = @import("builtin");
