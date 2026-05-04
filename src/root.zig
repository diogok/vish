//! Public surface of `vish`. Re-exports `Request`, `Response`, `Server`,
//! `Loop`, `Handler`, the error set, and the `utils` namespace. New
//! public symbols belong here.

const request = @import("http/request.zig");
const response = @import("http/response.zig");
const server = @import("http/server.zig");
const socket = @import("http/socket.zig");

const handler = @import("loop/handler.zig");
const loop = @import("loop/loop.zig");
const signal = @import("loop/signal.zig");

pub const Request = request.Request;
pub const Response = response.Response;
pub const ExtraHeader = response.ExtraHeader;
pub const Status = response.Status;
pub const SSEMessage = response.SSEMessage;

pub const Server = server.Server;
pub const Connection = server.Connection;
pub const ListenOptions = server.ListenOptions;

pub const Handler = handler.Handler;
pub const HandleError = handler.Error;
pub const Loop = loop.Loop;

pub const waitInterrupt = signal.wait;

pub const utils = @import("utils/root.zig");

test {
    _ = request;
    _ = response;
    _ = server;
    _ = socket;

    _ = signal;
    _ = handler;
    _ = loop;

    _ = utils;
}
