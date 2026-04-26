//! HTTP server and connection management module.
//!
//! This module provides the core server infrastructure for accepting TCP
//! connections and managing their lifecycle.
//!
//! It handles socket configuration (keep-alive, no-delay) and buffer
//! allocation for efficient request/response processing.
//!
//! Each connection gets its own arena allocator that is reset between
//! requests. Calling `stop` unblocks the accept loop; `deinit` releases
//! resources.
//!
//! There is no per-connection idle/read timeout. An idle keep-alive
//! client holds its worker until it disconnects; place behind a load
//! balancer for public exposure.

pub const ListenOptions = struct {
    kernel_backlog: u31 = 1024,
    reuse_address: bool = true,
    tcp_keep_alive: bool = true,
    tcp_no_delay: bool = false,

    read_buffer_size: usize = 8 * 1024,
    write_buffer_size: usize = 8 * 1024,
};

pub const Server = struct {
    options: ListenOptions,

    io: std.Io,
    allocator: std.mem.Allocator,
    address: std.Io.net.IpAddress,
    server: ?std.Io.net.Server = null,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        address: std.Io.net.IpAddress,
        options: ListenOptions,
    ) @This() {
        return .{
            .io = io,
            .allocator = allocator,
            .address = address,
            .options = options,
        };
    }

    pub fn deinit(self: *@This()) void {
        log.info("Deinit server", .{});
        if (self.server) |*server| {
            server.deinit(self.io);
            self.server = null;
        }
    }

    /// Stop accepting new connections. Unblocks any in-flight `accept`.
    /// In-progress connections continue to run; call `deinit` to release
    /// resources and let workers unwind.
    pub fn stop(self: *@This()) void {
        if (self.server) |*server| {
            log.info("Stop server", .{});
            const stream: std.Io.net.Stream = .{ .socket = server.socket };
            stream.shutdown(self.io, .both) catch {};
        }
    }

    pub fn listen(self: *@This()) !void {
        var server = try self.address.listen(self.io, .{
            .kernel_backlog = self.options.kernel_backlog,
            .reuse_address = self.options.reuse_address,
        });
        errdefer server.deinit(self.io);

        try socket.setServerFlags(server.socket.handle, .{
            .tcp_no_delay = self.options.tcp_no_delay,
            .tcp_keep_alive = self.options.tcp_keep_alive,
        });

        self.server = server;

        const addr = self.getAddressStringAlloc(self.allocator) catch null;
        if (addr) |add| {
            defer self.allocator.free(add);
            log.info("Listening on {s}", .{add});
        }
    }

    pub fn getAddress(self: @This()) ?std.Io.net.IpAddress {
        if (self.server) |svr| {
            return svr.socket.address;
        }
        return null;
    }

    pub fn getAddressStringAlloc(self: *@This(), allocator: std.mem.Allocator) !?[]const u8 {
        if (self.getAddress()) |addr| {
            var alloc_writer = std.Io.Writer.Allocating.init(allocator);
            defer alloc_writer.deinit();
            addr.format(&alloc_writer.writer) catch return null;
            return try alloc_writer.toOwnedSlice();
        }
        return null;
    }

    pub fn accept(self: *@This()) !?Connection {
        if (self.server) |*server| {
            const stream = server.accept(self.io) catch |err| {
                switch (err) {
                    error.WouldBlock,
                    error.ConnectionAborted,
                    error.SocketNotListening,
                    => return null,
                    else => return err,
                }
            };

            return try Connection.init(self, stream);
        }
        return null;
    }
};

pub const Connection = struct {
    server: *Server,

    stream: std.Io.net.Stream,

    read_buffer: []u8,
    write_buffer: []u8,

    net_reader: std.Io.net.Stream.Reader,
    net_writer: std.Io.net.Stream.Writer,

    arena: std.heap.ArenaAllocator,

    pub fn init(server: *Server, stream: std.Io.net.Stream) !@This() {
        const read_buffer = try server.allocator.alloc(u8, server.options.read_buffer_size);
        errdefer server.allocator.free(read_buffer);
        const write_buffer = try server.allocator.alloc(u8, server.options.write_buffer_size);
        errdefer server.allocator.free(write_buffer);

        return .{
            .server = server,
            .stream = stream,
            .read_buffer = read_buffer,
            .write_buffer = write_buffer,
            .net_reader = stream.reader(server.io, read_buffer),
            .net_writer = stream.writer(server.io, write_buffer),
            .arena = std.heap.ArenaAllocator.init(server.allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.server.allocator.free(self.read_buffer);
        self.server.allocator.free(self.write_buffer);
        self.stream.close(self.server.io);
    }

    pub fn next(self: *@This()) !?Request {
        // Reset arena for each new request (reuses memory from previous request)
        _ = self.arena.reset(.retain_capacity);

        return Request.read(
            self.arena.allocator(),
            &self.net_reader.interface,
            &self.net_writer.interface,
        ) catch |err| {
            if (err == error.NoData) return null;
            if (self.net_reader.err) |net_err| {
                switch (net_err) {
                    error.ConnectionResetByPeer,
                    error.SocketUnconnected,
                    error.Timeout,
                    => return null,
                    else => return net_err,
                }
            }
            return err;
        };
    }
};

const log = std.log.scoped(.http);

const std = @import("std");
const testing = std.testing;

const socket = @import("socket.zig");

pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;
