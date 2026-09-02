//! Live probe for the WebSocket client: connect to an echo endpoint,
//! send one text message and print what comes back. Usage:
//! `ws-echo [ws://host[:port][/path] | wss://...] [message]`; the
//! defaults target demo2's `/ws` route with `hello`.

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| {
        log.err("ws-echo failed: {t}", .{err});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const url: []const u8 = if (args.len > 1) args[1] else "ws://127.0.0.1:8080/ws";
    const message: []const u8 = if (args.len > 2) args[2] else "hello";
    const target = try parseUrl(url);

    var client = try vish.WebSocketClient.connect(io, allocator, .{
        .host = target.host,
        .port = target.port,
        .path = target.path,
        .tls = target.tls,
    });
    defer client.deinit();
    log.info("connected to {s}", .{url});

    client.sendText(message);
    // Some public echo services greet before echoing: print every
    // text message until the echo itself arrives.
    while (true) {
        const msg = try client.next();
        switch (msg) {
            .text => |text| {
                std.debug.print("{s}\n", .{text});
                if (std.mem.eql(u8, text, message)) break;
            },
            .binary => |bytes| std.debug.print("binary message, {d} bytes\n", .{bytes.len}),
            .close => |closing| {
                std.debug.print("closed by peer: {d} {s}\n", .{ closing.code, closing.reason });
                return;
            },
        }
    }

    client.close(.normal_closure, "");
    // The peer's Close reply ends the session cleanly.
    while (client.next()) |msg| {
        if (msg == .close) break;
    } else |_| {}
}

const Target = struct {
    host: []const u8,
    port: ?u16,
    path: []const u8,
    tls: bool,
};

/// `ws://host[:port][/path]` or `wss://...`; the host is passed
/// through as given.
fn parseUrl(url: []const u8) !Target {
    const tls_on = std.mem.startsWith(u8, url, "wss://");
    if (!tls_on and !std.mem.startsWith(u8, url, "ws://")) return error.UnsupportedScheme;
    const rest = url[std.mem.indexOf(u8, url, "://").? + 3 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const path: []const u8 = if (slash < rest.len) rest[slash..] else "/";
    var host = authority;
    var port: ?u16 = null;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = try std.fmt.parseInt(u16, authority[colon + 1 ..], 10);
    }
    if (host.len == 0) return error.MissingHost;
    return .{ .host = host, .port = port, .path = path, .tls = tls_on };
}

const std = @import("std");
const vish = @import("vish");
const log = std.log.scoped(.ws_echo);

// A probe: the library's debug lines (the socket's error behind a
// failed handshake, a TLS alert) are the point of running it.
pub const std_options: std.Options = .{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .vish, .level = .debug },
    },
};
