//! `wait(io)` blocks until SIGINT, SIGTERM, or SIGHUP arrives
//! (console ctrl events on Windows).

var state: struct {
    event: std.Io.Event = .unset,
    io: ?std.Io = null,
    last_signo: std.atomic.Value(u32) = .init(0),
} = .{};

/// Wait on default interrupt (INT, TERM, or HUP) signals.
pub fn wait(io: std.Io) void {
    state.io = io;

    if (builtin.os.tag == .windows) {
        _ = SetConsoleCtrlHandler(receiveWindows, .TRUE);
    } else {
        var mask = std.posix.sigemptyset();
        std.posix.sigaddset(&mask, std.posix.SIG.INT);
        std.posix.sigaddset(&mask, std.posix.SIG.TERM);
        std.posix.sigaddset(&mask, std.posix.SIG.HUP);

        const sigact: std.posix.Sigaction = .{
            .handler = .{ .handler = receive },
            .mask = mask,
            .flags = 0,
        };
        std.posix.sigaction(.INT, &sigact, null);
        std.posix.sigaction(.TERM, &sigact, null);
        std.posix.sigaction(.HUP, &sigact, null);
    }

    log.info("Waiting for stop signal.", .{});
    state.event.waitUncancelable(io);
    log.info("Signal received: {d}", .{state.last_signo.load(.acquire)});
}

fn receive(sig: std.posix.SIG) callconv(.c) void {
    state.last_signo.store(@intFromEnum(sig), .release);
    if (state.io) |io| state.event.set(io);
}

fn receiveWindows(ctrl_type: windows.DWORD) callconv(.winapi) windows.BOOL {
    state.last_signo.store(ctrl_type, .release);
    if (state.io) |io| state.event.set(io);
    return .TRUE;
}

extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?*const fn (windows.DWORD) callconv(.winapi) windows.BOOL,
    add: windows.BOOL,
) callconv(.winapi) windows.BOOL;

const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;
const log = std.log.scoped(.vish);
