# Coding Conventions

This project follows the generic Zig conventions in
[`zig-conventions.md`](zig-conventions.md): naming, file-as-struct,
`@This()` usage, struct organization, error handling, comptime, tests
at the bottom of the file, etc. Read those first — what follows is
only the project-specific layer.

## std.Io is explicit

The library is built on Zig's I/O rework. There is no global runtime —
`std.Io` is threaded through every API that touches the network, the
filesystem, signals, or sleeps.

```zig
var server = http.Server.init(io, allocator, address, .{});
var loop = try http.Loop.init(io, &server, handler.interface());
http.waitInterrupt(io);
```

Handlers do **not** receive `io` as a parameter — they get it indirectly
via `req.allocator` (the per-request arena) and via the writer/reader on
the request. If your handler needs `std.Io` (e.g. to spawn a sub-task or
read from disk), capture it in your handler struct at construction time,
the way `Common` and `StaticRouter` do.

## Allocator discipline

- **Server allocator** (passed into `Server.init`) is the long-lived
  allocator. It owns connection buffers and backs each connection's
  arena. Use a real allocator here (GPA, `smp_allocator`).
- **Per-connection arena** — `Connection.arena`. Reset between requests
  with `.retain_capacity`. Don't deinit it from a handler; the loop
  manages the lifetime.
- **Per-request allocator** — `req.allocator`, which is the arena's
  allocator. Handlers should allocate from this freely. Don't `free` —
  the next request reset reclaims everything. Don't retain pointers past
  the handler return.
- Tests use `testing.allocator` and explicit `defer` / `errdefer`. Code
  must work under both: arena (frees are no-ops) and GPA (frees must be
  paired). That's why `Headers.free` and `BodyReader.deinit` exist —
  they're no-ops in production, leak-preventers in tests.

## Handler pattern

Two equivalent ways to expose a `Handler`:

**1. `Handler.wrap(T)` — for simple, stateless handlers.** The wrapper
generates the vtable; the concrete type just implements `handle`:

```zig
const Hello = struct {
    pub fn handle(_: @This(), _: http.Request, res: *http.Response) http.HandleError!void {
        res.body = "hi";
        try res.send();
    }
};

var state = Hello{};
const handler = http.Handler.wrap(Hello).init(&state).interface();
```

**2. Inline `interface()` method — for stateful handlers / routers.** Every
type in `utils/router.zig` follows this shape:

```zig
pub fn interface(self: *@This()) Handler {
    return .{ .ptr = self, .vtable = &.{ .handle = handle } };
}

fn handle(h: Handler, req: Request, res: *Response) HandlerError!void {
    const self: *@This() = @ptrCast(@alignCast(h.ptr));
    try self.route(req, res);
}
```

Use this form when the handler has state, owns child handlers, or needs
to be addressable by pointer (so `interface()` takes `*@This()` and the
caller `&`s the value).

## error.Skipped is a contract

Routers and middleware return `error.Skipped` to mean "I don't match,
try the next one." `CombinedRouter` treats it as a continuation;
`Loop.onRequest` converts an uncaught `Skipped` to `404 Not Found`.

If your handler legitimately can't process a request, return `Skipped`
rather than fabricating a 404 — let the chain decide. Reserve the other
errors in `HandleError` (`Internal`, `BadRequest`, `Unauthorized`) for
real failures.

## Errors come from a closed set

`HandleError` is the union of every error a handler may legitimately
return:

```zig
pub const Error = error{
    StreamTooLong, OutOfMemory, ReadFailed, WriteFailed, NoSpaceLeft,
    Skipped,
    Internal, BadRequest, Unauthorized,
};
```

When you catch a domain-specific error (e.g. `error.InvalidJson`),
translate it to one of these (`BadRequest`) before propagating. Don't
broaden the error set — every caller in the chain has to handle it.

## Imports go at the bottom

This project follows the file-as-struct style consistently — bare fields
at the top, methods next, **imports last**, tests last after imports
when they need test-only imports above them.

```zig
//! Module-level doc comment.

pub const Foo = struct { ... };

pub fn doThing(...) !void { ... }

test "doThing handles X" { ... }

const std = @import("std");
const testing = std.testing;
const Request = @import("../http/request.zig").Request;
```

`build.zig` and `build.zig.zon` are the exception (Zig build conventions
put imports at the top).

## Tests live with the code

Every `.zig` file ends with its tests. `src/root.zig` and
`src/utils/root.zig` contain `test { _ = some_module; ... }` blocks that
pull every submodule into the build's test set. When you add a new
module, add it there too — otherwise its tests don't run under
`zig build test`.

Tests use `testing.io` and `testing.allocator`. Integration tests for
the loop spin up a real `TestServer` on `127.0.0.1:0` and hit it via
`std.Io.net.IpAddress.connect` — see the bottom of `loop.zig` for the
pattern.

## Logging

```zig
const log = std.log.scoped(.http);
```

All library modules log under the `.http` scope. Demos use their own
scope (`.demo`). Set per-scope levels via `std_options`:

```zig
pub const std_options: std.Options = .{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .http, .level = .warn },
    },
};
```

## Header naming

`request.Headers` and `response.Headers` are structs with `snake_case`
fields. Wire format is generated by replacing `_` with `-` and
capitalizing each segment at comptime — `content_length` becomes
`Content-Length`. To add a new typed header, add the field; the parser
and serializer pick it up automatically (subject to type-dispatch in
`Headers.read`/`sendHeaders`).

For arbitrary inbound headers, opt in with
`ListenOptions.parse_extra_headers = true` and read via
`req.headers.get("X-Foo")`. For arbitrary outbound headers, append to
`res.headers.extra: []const ExtraHeader`.

## When you change public API

Update `src/root.zig` to re-export the new symbol — it is the single
public surface. The README usage example and `docs/usage.md` should
stay in sync with what `root.zig` exposes.
