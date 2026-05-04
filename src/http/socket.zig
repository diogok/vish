//! TCP listener socket option helpers. Linux only; other platforms are
//! no-ops.

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
