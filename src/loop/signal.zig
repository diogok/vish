const Signal = std.atomic.Value(u32);
const interrupt = Signal.init(0);

pub fn wait() void {
    const sigact = &std.posix.Sigaction{
        .handler = .{ .handler = receive },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.c.SIG.INT, sigact, null);
    std.posix.sigaction(std.c.SIG.HUP, sigact, null);

    log.warn("Waiting for stop signal.", .{});
    std.Thread.Futex.wait(&interrupt, 0);
}

fn receive(sig: c_int) callconv(.c) void {
    log.warn("Signal received: {d}", .{sig});
    switch (sig) {
        std.c.SIG.INT, std.c.SIG.HUP => {
            std.Thread.Futex.wake(&interrupt, 1);
        },
        else => {},
    }
}

const std = @import("std");
const log = std.log.scoped(.http);
