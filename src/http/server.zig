//! HTTP server and connection management module.
//!
//! This module provides the core server infrastructure for accepting TCP connections
//! and managing their lifecycle.
//!
//! It handles socket configuration, timeouts, and
//! buffer allocation for efficient request/response processing.
//!
//! The server uses a non-blocking accept with configurable timeout, allowing the
//! event loop to periodically check for shutdown signals.
//!
//! Each connection gets its own arena allocator that is reset between requests.
//! ```

pub const ListenOptions = struct {
    kernel_backlog: u31 = 1024,
    reuse_address: bool = true,
    tcp_keep_alive: bool = true,
    tcp_no_delay: bool = false,

    accept_timeout_in_millis: u32 = 1000,
    read_timeout_in_millis: u32 = 1000,
    write_timeout_in_millis: u32 = 1000,

    read_buffer_size: usize = 8 * 1024,
    write_buffer_size: usize = 8 * 1024,
};

pub const Server = struct {
    options: ListenOptions,

    allocator: std.mem.Allocator,
    address: std.net.Address,
    server: ?*std.net.Server = null,

    pub fn init(
        allocator: std.mem.Allocator,
        address: std.net.Address,
        options: ListenOptions,
    ) @This() {
        return @This(){
            .allocator = allocator,
            .address = address,
            .options = options,
        };
    }

    pub fn deinit(self: *@This()) void {
        log.info("Deinit server", .{});
        if (self.server) |server| {
            self.stop();
            server.deinit();
            self.allocator.destroy(self.server.?);
            self.server = null;
        }
    }

    pub fn stop(self: *@This()) void {
        if (self.server) |server| {
            log.info("Stop server", .{});
            std.posix.shutdown(server.stream.handle, .both) catch {};
        }
    }

    pub fn listen(self: *@This()) !void {
        const server = try self.allocator.create(std.net.Server);
        errdefer self.allocator.destroy(server);

        server.* = try self.address.listen(.{
            .kernel_backlog = self.options.kernel_backlog,
            .reuse_address = self.options.reuse_address,
        });

        try socket.setServerFlags(
            server.stream.handle,
            .{
                .tcp_no_delay = self.options.tcp_no_delay,
                .tcp_keep_alive = self.options.tcp_keep_alive,
            },
        );

        self.server = server;

        const addr = self.getAddressStringAlloc(self.allocator) catch null;
        if (addr) |add| {
            defer self.allocator.free(add);
            log.info("Listening on {s}", .{add});
        }
    }

    pub fn getAddress(self: @This()) ?std.net.Address {
        if (self.server) |svr| {
            return svr.listen_address;
        } else {
            return null;
        }
    }

    pub fn getAddressStringAlloc(self: *@This(), allocator: std.mem.Allocator) !?[]const u8 {
        if (self.getAddress()) |addr| {
            var alloc_writer = std.Io.Writer.Allocating.init(allocator);
            defer alloc_writer.deinit();
            addr.format(&alloc_writer.writer) catch return null;
            return try alloc_writer.toOwnedSlice();
        } else {
            return null;
        }
    }

    pub fn accept(self: *@This()) !?Connection {
        if (self.server) |server| {
            socket.wait(
                server.stream.handle,
                self.options.accept_timeout_in_millis,
            ) catch |err| {
                switch (err) {
                    error.Timeout => {
                        return null;
                    },
                    else => {
                        return err;
                    },
                }
            };
            const conn = server.accept() catch |err| {
                switch (err) {
                    error.WouldBlock, // timeout waiting
                    error.ConnectionAborted, // disconnect by client
                    error.ConnectionResetByPeer, // disconnect by client
                    => {
                        return null;
                    },
                    else => {
                        return err;
                    },
                }
            };

            try socket.setTimeout(
                conn.stream.handle,
                self.options.read_timeout_in_millis,
                self.options.write_timeout_in_millis,
            );

            return try Connection.init(self, conn);
        }
        return null;
    }
};

pub const Connection = struct {
    server: *Server,

    connection: std.net.Server.Connection,

    read_buffer: []u8,
    write_buffer: []u8,

    net_reader: std.net.Stream.Reader,
    net_writer: std.net.Stream.Writer,

    arena: std.heap.ArenaAllocator,

    pub fn init(
        server: *Server,
        connection: std.net.Server.Connection,
    ) !@This() {
        const read_buffer = try server.allocator.alloc(u8, server.options.read_buffer_size);
        const write_buffer = try server.allocator.alloc(u8, server.options.write_buffer_size);

        return @This(){
            .server = server,
            .connection = connection,
            .read_buffer = read_buffer,
            .write_buffer = write_buffer,
            .net_reader = connection.stream.reader(read_buffer),
            .net_writer = connection.stream.writer(write_buffer),
            .arena = std.heap.ArenaAllocator.init(server.allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.server.allocator.free(self.read_buffer);
        self.server.allocator.free(self.write_buffer);
        self.connection.stream.close();
    }

    pub fn next(self: *@This()) !?Request {
        // Reset arena for each new request (reuses memory from previous request)
        _ = self.arena.reset(.retain_capacity);

        return Request.read(
            self.arena.allocator(),
            self.net_reader.interface(),
            &self.net_writer.interface,
        ) catch |err| {
            if (err == error.NoData) {
                return null;
            } else if (self.net_reader.getError()) |net_err| {
                switch (net_err) {
                    error.WouldBlock, // timeout waiting
                    error.ConnectionResetByPeer, // disconnect by client
                    => {
                        return null;
                    },
                    else => {
                        return net_err;
                    },
                }
            } else {
                return err;
            }
        };
    }
};

const log = std.log.scoped(.http);

const std = @import("std");
const testing = std.testing;

const socket = @import("socket.zig");

pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;
