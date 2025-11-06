pub const ListenOptions = struct {
    kernel_backlog: u31 = 1024,
    reuse_address: bool = true,
    tcp_keep_alive: bool = true,
    tcp_no_delay: bool = false,

    accept_timeout_in_millis: u32 = 1000,
    read_timeout_in_millis: u32 = 1000,
    write_timeout_in_millis: u32 = 1000,

    read_buffer_size: usize = 4 * 1024,
    write_buffer_size: usize = 4 * 1024,
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
        if (self.server) |server| {
            log.warn("Shutdown!", .{});
            std.posix.shutdown(server.stream.handle, .both) catch {};
            server.deinit();
            self.allocator.destroy(self.server.?);
            self.server = null;
        }
    }

    pub fn stop(self: *@This()) void {
        if (self.server) |server| {
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

    net_reader: *std.net.Stream.Reader,
    net_writer: *std.net.Stream.Writer,

    pub fn init(
        server: *Server,
        connection: std.net.Server.Connection,
    ) !@This() {
        const read_buffer = try server.allocator.alloc(u8, server.options.read_buffer_size);
        const write_buffer = try server.allocator.alloc(u8, server.options.write_buffer_size);

        const net_reader = try server.allocator.create(std.net.Stream.Reader);
        net_reader.* = connection.stream.reader(read_buffer);

        const net_writer = try server.allocator.create(std.net.Stream.Writer);
        net_writer.* = connection.stream.writer(write_buffer);

        return @This(){
            .server = server,
            .connection = connection,
            .read_buffer = read_buffer,
            .write_buffer = write_buffer,
            .net_reader = net_reader,
            .net_writer = net_writer,
        };
    }

    pub fn deinit(self: @This()) void {
        self.server.allocator.free(self.read_buffer);
        self.server.allocator.free(self.write_buffer);
        self.server.allocator.destroy(self.net_reader);
        self.server.allocator.destroy(self.net_writer);
        self.connection.stream.close();
    }

    pub fn next(self: @This()) !?Request {
        return Request.read(self.server.allocator, self.net_reader.interface()) catch |err| {
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

    pub fn writer(self: @This()) *std.Io.Writer {
        return &self.net_writer.interface;
    }
};

const log = std.log.scoped(.http);

const std = @import("std");
const testing = std.testing;

const socket = @import("socket.zig");
const Request = @import("request.zig").Request;
