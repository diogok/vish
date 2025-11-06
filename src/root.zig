//! Nothing yet

const request = @import("request.zig");
const response = @import("response.zig");
const socket = @import("socket.zig");
const server = @import("server.zig");

const signal = @import("signal.zig");
const handler = @import("handler.zig");
const loop = @import("loop.zig");

pub const Request = request.Request;
pub const Response = response.Response;

pub const Server = server.Server;
pub const Connection = server.Connection;
pub const ListenOptions = server.ListenOptions;

pub const Handler = handler.Handler;
pub const HandleError = handler.Error;
pub const Loop = loop.Loop;
pub const runAndWait = loop.runAndWait;

pub const registerDefaultHandlers = signal.registerDefaultHandlers;

test {
    _ = request;
    _ = response;
    _ = socket;
    _ = server;

    //_ = signal;
    _ = handler;
    _ = loop;
}
