//! `wait(io)` blocks until SIGINT or SIGHUP arrives. Called at the end
//! of `main` to hold the program until Ctrl-C, then let the deferred
//! `Loop`/`Server` deinit run.

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
