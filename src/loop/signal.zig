//! `wait(io)` blocks until SIGINT, SIGTERM, or SIGHUP arrives
//! (console ctrl events on Windows).

var state: struct {
    event: std.Io.Event = .unset,
    // Signal handlers read the `Io` through this atomic pointer, never
    // directly: `io_storage` is multi-word, so an unsynchronized read
    // from a handler could observe a torn value.
    io: std.atomic.Value(?*const std.Io) = .init(null),
    io_storage: std.Io = undefined,
    last_signo: std.atomic.Value(u32) = .init(0),
} = .{};

/// Single waiter only: signal registration and the wakeup event live in
/// module-global state, so a second call overwrites the first caller's
/// registration.
pub fn wait(io: std.Io) void {
    // Fill the storage, then publish, then register the handlers — a
    // signal arriving mid-registration sees either null (no waiter yet)
    // or a fully written `Io`.
    state.io_storage = io;
    state.io.store(&state.io_storage, .release);

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
    if (state.io.load(.acquire)) |io| state.event.set(io.*);
}

fn receiveWindows(ctrl_type: windows.DWORD) callconv(.winapi) windows.BOOL {
    state.last_signo.store(ctrl_type, .release);
    if (state.io.load(.acquire)) |io| state.event.set(io.*);
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
