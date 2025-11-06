const Signal = std.atomic.Value(u32);
const Interrupt = Signal.init(0);

pub fn wait() void {
    std.Thread.Futex.wait(&Interrupt, 0);
}

pub fn registerDefaultHandlers() void {
    const sigact = &std.posix.Sigaction{
        .handler = .{ .handler = receive },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.c.SIG.INT, sigact, null);
    std.posix.sigaction(std.c.SIG.HUP, sigact, null);
}

fn receive(sig: c_int) callconv(.c) void {
    log.warn("Signal received: {d}", .{sig});
    switch (sig) {
        std.c.SIG.INT => {
            std.Thread.Futex.wake(&Interrupt, 9);
        },
        else => {},
    }
}

const std = @import("std");

const log = std.log.scoped(.http);
