//! Signal handling utils.
//!
//! Block the calling task until SIGINT or SIGHUP is received. Typical
//! use is at the bottom of `main` after starting the server loop, so
//! Ctrl-C triggers a clean shutdown.

var interrupt_event: std.Io.Event = .unset;
var interrupt_io: ?std.Io = null;

/// Wait on default interrupt (INT or HUP) signals.
pub fn wait(io: std.Io) void {
    interrupt_io = io;

    const sigact = &std.posix.Sigaction{
        .handler = .{ .handler = receive },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, sigact, null);
    std.posix.sigaction(.HUP, sigact, null);

    log.info("Waiting for stop signal.", .{});
    interrupt_event.waitUncancelable(io);
}

fn receive(sig: std.posix.SIG) callconv(.c) void {
    log.info("Signal received: {t}", .{sig});
    if (interrupt_io) |io| {
        interrupt_event.set(io);
    }
}

const std = @import("std");
const log = std.log.scoped(.vish);
