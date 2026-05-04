# Coding Conventions

Zig style for this project. Generic conventions first, then the vish-specific layer (std.Io, allocator discipline, handler pattern, `error.Skipped`, header naming). Comment style is in [`comment-conventions.md`](comment-conventions.md).

## Naming

| Kind              | Style        | Examples                                     |
|-------------------|--------------|----------------------------------------------|
| Types / structs   | `PascalCase` | `Request`, `Response`, `Server`, `Connection`|
| Functions         | `camelCase`  | `bodyReader`, `writeChunk`, `fromRequest`    |
| Variables / fields| `snake_case` | `content_length`, `read_buffer_size`         |
| Tagged union tags | `snake_case` | `gzip`, `deflate`, `chunked`                 |
| Type aliases      | `PascalCase` | `Status`, `Method`, `Version`                |

### Spell out names

Avoid single-letter and cryptic abbreviations. Loop variables should say what they iterate over.

```zig
// Bad
for (0..n) |i| { ... }

// Good
for (0..extras.len) |extra| { ... }
```

Exception: `i` is fine for pure index iteration in tight arithmetic.

### Drop the module prefix from nested types

When a file-as-struct module defines nested types, the import already provides the namespace — prefixing the type with the module name reads as duplication.

```zig
// request.zig — the file is `Request`
// Bad
pub const RequestHeaders = struct { ... };

// Good
pub const Headers = struct { ... };
```

Callers get `Request.Headers` / `Response.Status` — crisp and unambiguous. Keep the prefix when it carries distinct meaning (e.g. `Headers.ExtraHeader` — Extra ≠ Headers).

### Public function parameters should be self-documenting

```zig
// Bad
pub fn read(r: *std.Io.Reader, a: std.mem.Allocator, n: usize) !void

// Good
pub fn read(reader: *std.Io.Reader, allocator: std.mem.Allocator, max_bytes: usize) !void
```

### Scratch buffers — name by role or add a comment

```zig
// Bad
const buf_a = try allocator.alloc(u8, size);
const buf_b = try allocator.alloc(u8, size);

// Good — named by role, with comment explaining reuse
// scratch_a and scratch_b alternate as input/output across stages.
const scratch_a = try allocator.alloc(u8, size);
const scratch_b = try allocator.alloc(u8, size);
```

## File-as-struct

When a file defines a single primary type, the file _is_ the struct — bare fields at the top, methods below, no wrapping `pub const Foo = struct { ... }`.

```zig
// connection.zig — the file IS the Connection struct
stream: std.Io.net.Stream,
arena: std.heap.ArenaAllocator,
read_buffer: []u8,
write_buffer: []u8,

pub fn init(allocator: std.mem.Allocator, stream: std.Io.net.Stream, opts: Options) !@This() {
    ...
}

pub fn deinit(self: *@This()) void { ... }
```

Callers get the type name from the import:
```zig
const Connection = @import("connection.zig");
```

When a file exports multiple types (e.g. `request.zig` exports `Request`, `Headers`, `BodyReader`), use named `pub const` structs instead.

## @This() usage

Use `@This()` directly in method signatures for file-as-struct modules. Use `const Self = @This()` when inside a returned generic struct (e.g. from a `fn Foo(comptime T: type) type` function).

```zig
// File-as-struct — use @This() directly
pub fn init(allocator: std.mem.Allocator) @This() { ... }
pub fn deinit(self: *@This()) void { ... }

// Generic returned struct — Self alias is clearer
pub fn StructRouter(T: type) type {
    return struct {
        const Self = @This();
        pub fn route(self: *Self, req: Request, res: *Response) !void { ... }
    };
}
```

## Struct organization

1. Fields (with default values where sensible)
2. `init` / `deinit`
3. Public methods
4. Private helpers

```zig
// Fields
content_length: ?usize = null,
content_type: ?[]const u8 = null,
content_encoding: ?Encoding = null,

// Lifecycle
pub fn init(...) @This() { ... }
pub fn deinit(self: *@This()) void { ... }

// Public API
pub fn read(self: *@This(), reader: *std.Io.Reader, opts: Options) !void { ... }
pub fn get(self: @This(), name: []const u8) ?[]const u8 { ... }

// Private
fn parseExtra(self: *@This(), line: []const u8) !void { ... }
```

## Self parameter conventions

Use `*@This()` for methods that mutate, `@This()` (by value) for pure queries.

```zig
pub fn setStatus(self: *@This(), status: Status) void { self.status = status; }
pub fn get(self: @This(), name: []const u8) ?[]const u8 { ... }
```

Use `_:` for unused self parameters instead of `_ = self`:

```zig
// Bad
pub fn handle(self: @This(), req: Request, res: *Response) !void {
    _ = self;
    res.body = "hi";
    try res.send();
}

// Good
pub fn handle(_: @This(), _: Request, res: *Response) !void {
    res.body = "hi";
    try res.send();
}
```

## Parameter passing

Three forms:

| Form        | Callee can mutate caller's value | Cost            |
|-------------|----------------------------------|-----------------|
| `T`         | no                               | one copy        |
| `*const T`  | no                               | one indirection |
| `*T`        | yes                              | one indirection |

`T` and `*const T` give the callee the same capability — Zig parameters are immutable by default, so a by-value `T` is already read-only. The choice between them is copy-cost vs. indirection-cost, never about "protecting" the callee from mutation.

Default to `T`. Zig passes small structs in registers; `*const T` adds a load and can inhibit optimizations.

Use `*T` when the callee mutates the caller's value. If you find yourself writing `@constCast` on a `*const T` parameter to reach a mutation, the signature is wrong — change it to `*T`.

Use `*const T` only when both hold:
- The struct is genuinely large (kilobytes / unbounded buffers).
- The function is hot enough that the copy would matter.

"Genuinely large" is the exception. ~80 bytes of plain scalars is not large — pass by value. A 17-byte slice descriptor is not large either.

```zig
// Bad — unnecessary pointer for a small snapshot
pub fn fromRequest(req: *const Request) Response { ... }

// Good — pass by value
pub fn fromRequest(req: Request) Response { ... }

// Bad — *const T laundered into mutation via @constCast
pub fn next(self: *const Connection) !Request {
    const arena = @constCast(&self.arena);
    _ = arena.reset(.retain_capacity);
    ...
}

// Good — be honest about mutation
pub fn next(self: *Connection) !Request {
    _ = self.arena.reset(.retain_capacity);
    ...
}
```

You also need `*const T` (or `*T`) when the address must outlive the call — e.g. storing the reference somewhere.

## Type-erased interfaces

Follow the `std.io.Reader` pattern for polymorphic interfaces. The interface is a small value type (two pointers). VTable functions take a pointer to the interface as the first parameter. `wrap(T)` returns a typed wrapper that produces the type-erased interface on demand.

```zig
// The interface: ptr + vtable.
pub const Handler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // VTable functions take a pointer to the interface, not *anyopaque.
        handle: *const fn (Handler, Request, *Response) HandleError!void,
    };

    // Convenience methods forward to vtable, passing self.
    pub fn handle(self: Handler, req: Request, res: *Response) HandleError!void {
        return self.vtable.handle(self, req, res);
    }

    /// Return a typed wrapper for the given concrete type.
    pub fn wrap(T: type) type {
        return struct {
            ptr: *T,

            pub fn init(ptr: *T) @This() {
                return .{ .ptr = ptr };
            }

            /// Produce the type-erased interface.
            pub fn interface(self: @This()) Handler {
                return .{ .ptr = self.ptr, .vtable = &vtable_instance };
            }

            const vtable_instance = VTable{ .handle = handleFn };

            fn handleFn(h: Handler, req: Request, res: *Response) HandleError!void {
                const concrete: *T = @ptrCast(@alignCast(h.ptr));
                return concrete.handle(req, res);
            }
        };
    }
};
```

Two ways for a concrete type to plug in — see [Handler pattern](#handler-pattern) below.

Rules:

- VTable functions take a **pointer to the interface type** as the first parameter (not `*anyopaque`). The wrapper casts `h.ptr` to the concrete type.
- VTable field names match the convenience method names (no `Fn` suffix).
- `wrap(T)` returns a comptime-generated wrapper struct with a typed pointer and a static vtable instance.
- Concrete types provide a named method returning the interface (e.g. `.interface()`).
- The caller owns the concrete type. The interface borrows a pointer.
- The interface does not have `deinit` — lifetime is the caller's responsibility.

## Imports

Imports go at the **bottom** of the file (Zig convention for file-as-struct modules — fields must come first). Tests go before imports when they need test-only imports above them.

```zig
//! Module-level doc comment.

pub const Foo = struct { ... };

pub fn doThing(...) !void { ... }

test "doThing handles X" { ... }

const std = @import("std");
const testing = std.testing;
const Request = @import("../http/request.zig").Request;
```

`build.zig` and `build.zig.zon` are the exception (Zig build conventions put imports at the top).

## Return values

Prefer `.{}` anonymous struct literal returns:

```zig
pub fn init(allocator: std.mem.Allocator) @This() {
    return .{ .allocator = allocator, .extras = .{} };
}
```

## Error handling

- Propagate errors with `!` return types and `try`.
- Use `errdefer` for cleanup on error paths.
- Use `catch |err| switch (err) { ... }` for selective error handling.

```zig
pub fn init(allocator: std.mem.Allocator, stream: std.Io.net.Stream) !@This() {
    const buf = try allocator.alloc(u8, 8 * 1024);
    errdefer allocator.free(buf);
    return .{ .stream = stream, .read_buffer = buf, .allocator = allocator };
}
```

When you catch a domain-specific error (e.g. `error.InvalidJson`), translate it to one of `HandleError`'s arms (typically `BadRequest`) before propagating — see [HandleError is a closed set](#handleerror-is-a-closed-set).

## Memory management

- Always pass `std.mem.Allocator` explicitly — no globals.
- Pair every `init` with a `deinit`, every `create` with a `destroy`.
- Use `defer`/`errdefer` at the call site.

```zig
var server = try vish.Server.init(io, allocator, address, .{});
defer server.deinit();
```

## Io parameter (Zig 0.16+)

Anything that touches the OS (filesystem, network, sleep, sync, randomness) takes `io: std.Io` as its first parameter, before the allocator. Same rule as allocators: thread it through, never construct one at the call site.

```zig
pub fn init(io: std.Io, allocator: std.mem.Allocator, address: std.Io.net.IpAddress, opts: ListenOptions) @This() { ... }
```

Sync primitives now live under `std.Io` (`std.Io.Mutex`, `std.Io.Condition`, `std.Io.RwLock`, `std.Io.Event`) and their methods take `io`. Use `io.async` / `io.concurrent` for tasks; the `std.Thread.Pool` is gone.

## Juicy Main

`main` takes a `std.process.Init` and pulls `io` and `gpa` from it, rather than constructing them. This is the only place either should be created — every other function receives them as parameters.

```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // ...
}
```

For tests use `std.testing.io` and `std.testing.allocator`. For places genuinely without a parent `Io` (one-off scripts, library internals during migration), construct one explicitly:

```zig
var threaded: std.Io.Threaded = .init_single_threaded;
const io = threaded.io();
```

Command-line args come from `init.minimal.args` — they live in the init arena and don't need a separate free.

## Tagged unions and enums

Use tagged unions for variant payloads:

```zig
pub const Encoding = union(enum) {
    gzip: void,
    deflate: void,
    identity: void,
};
```

Use enums for finite sets:

```zig
pub const Method = enum {
    GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS,
};
```

## Comptime and generics

Use `anytype` for duck-typed parameters. Use comptime functions that return `type` for generic containers.

```zig
// Comptime function returning a type
pub fn StructRouter(T: type) type {
    return struct { ... };
}
```

Use `inline for` when iterating comptime-known fields — the comptime header serializer in `response.zig` walks `Headers`'s fields with `inline for` to emit one `writeAll` per typed field.

## Function organization

### Extract duplicated logic into shared helpers

```zig
// Bad — header-write boilerplate duplicated per field
try writer.writeAll("Content-Length: ");
try writer.print("{d}", .{value});
try writer.writeAll("\r\n");
...

// Good — one helper, called per field by the comptime serializer
fn writeHeaderField(writer: anytype, name: []const u8, value: anytype) !void { ... }
```

### Use semantic function names

```zig
// Bad — which parameter is the output?
pub fn copyHeaders(src: Headers, dst: *Headers) void

// Good — destination first, reads naturally: dst.fillFrom(src)
pub fn fillFrom(self: *Headers, src: Headers) void
```

## Comments

- `//!` for module-level doc comments (top of file).
- `///` for public API doc comments.
- `//` for inline explanations. Only where the code isn't self-evident.

```zig
//! HTTP request parser, headers, and body reader.

/// Look up an arbitrary request header by name (case-insensitive).
/// Returns `null` if the header is absent or extras parsing was disabled.
pub fn get(self: Headers, name: []const u8) ?[]const u8 { ... }

// Lazy: only allocate the decompress window the first time someone
// actually reads the body. Most requests skip the body entirely.
```

### Describe what the code IS, not what changed

Comments document the current state. History ("no longer depends on X", "moved from Y", "was previously Z") rots immediately and belongs in commit messages.

```zig
// Bad — refactor residue
/// Parser-native header set. The parser no longer depends on the legacy
/// Headers struct — callers route through readExtra and wrap via an adapter.
pub const Headers = struct { ... };

// Good — describes what it is, today
/// Typed HTTP request headers. Wire-format names are derived from field
/// names at comptime by replacing `_` with `-` and capitalizing each segment.
pub const Headers = struct { ... };
```

Good comments answer "why this non-obvious choice" — hidden constraints, surprising invariants, workarounds for specific bugs. They don't repeat what a reader can see from the signature or the code below. See [`comment-conventions.md`](comment-conventions.md) for the full treatment.

## Tests

Tests live at the bottom of the file they test, after a `test` block. Every `.zig` file ends with its tests; `src/root.zig` and `src/utils/root.zig` contain `test { _ = some_module; ... }` blocks that pull every submodule into the build's test set. When you add a new module, add it there too — otherwise its tests don't run under `zig build test`.

```zig
test "Headers parses Content-Length" {
    const allocator = testing.allocator;
    var stream = std.Io.Reader.fixed("Content-Length: 42\r\n\r\n");
    var headers: Headers = .{};
    try headers.read(allocator, &stream, .{});
    defer headers.free(allocator);
    try testing.expectEqual(@as(usize, 42), headers.content_length.?);
}
```

Use `testing.io` and `testing.allocator` (detects leaks) and `std.testing.expect*` assertions. Integration tests for the loop spin up a real `TestServer` on `127.0.0.1:0` and hit it via `std.Io.net.IpAddress.connect` — see the bottom of `loop.zig` for the pattern.

## Code hygiene

- Remove dead code, unused imports, and unused struct fields — version control has them.
- Name magic numbers when the meaning isn't obvious from context.
- Don't keep code "just in case".

```zig
// Bad — what does 8192 mean?
const buf = try allocator.alloc(u8, 8192);

// Good — intent is clear
const default_read_buffer_size = 8 * 1024;
const buf = try allocator.alloc(u8, default_read_buffer_size);
```

---

The sections below are vish-specific.

## std.Io is explicit

The library is built on Zig's I/O rework. There is no global runtime — `std.Io` is threaded through every API that touches the network, the filesystem, signals, or sleeps.

```zig
var server = vish.Server.init(io, allocator, address, .{});
var loop = try vish.Loop.init(io, &server, handler.interface());
vish.waitInterrupt(io);
```

Handlers do **not** receive `io` as a parameter — they get it indirectly via `req.allocator` (the per-request arena) and via the writer/reader on the request. If your handler needs `std.Io` (e.g. to spawn a sub-task or read from disk), capture it in your handler struct at construction time, the way `Common` and `StaticRouter` do.

## Allocator discipline

- **Server allocator** (passed into `Server.init`) is the long-lived allocator. It owns connection buffers and backs each connection's arena. Use a real allocator here (GPA, `smp_allocator`).
- **Per-connection arena** — `Connection.arena`. Reset between requests with `.retain_capacity`. Don't deinit it from a handler; the loop manages the lifetime.
- **Per-request allocator** — `req.allocator`, which is the arena's allocator. Handlers should allocate from this freely. Don't `free` — the next request reset reclaims everything. Don't retain pointers past the handler return.
- Tests use `testing.allocator` and explicit `defer` / `errdefer`. Code must work under both: arena (frees are no-ops) and GPA (frees must be paired). That's why `Headers.free` and `BodyReader.deinit` exist — they're no-ops in production, leak-preventers in tests.

## Handler pattern

Two equivalent ways to expose a `Handler`:

**1. `Handler.wrap(T)` — for simple, stateless handlers.** The wrapper generates the vtable; the concrete type just implements `handle`:

```zig
const Hello = struct {
    pub fn handle(_: @This(), _: vish.Request, res: *vish.Response) vish.HandleError!void {
        res.body = "hi";
        try res.send();
    }
};

var state = Hello{};
const handler = vish.Handler.wrap(Hello).init(&state).interface();
```

**2. Inline `interface()` method — for stateful handlers / routers.** Every type in `utils/router.zig` follows this shape:

```zig
pub fn interface(self: *@This()) Handler {
    return .{ .ptr = self, .vtable = &.{ .handle = handle } };
}

fn handle(h: Handler, req: Request, res: *Response) HandlerError!void {
    const self: *@This() = @ptrCast(@alignCast(h.ptr));
    try self.route(req, res);
}
```

Use this form when the handler has state, owns child handlers, or needs to be addressable by pointer (so `interface()` takes `*@This()` and the caller `&`s the value).

## error.Skipped is a contract

Routers and middleware return `error.Skipped` to mean "I don't match, try the next one." `CombinedRouter` treats it as a continuation; `Loop.onRequest` converts an uncaught `Skipped` to `404 Not Found`.

If your handler legitimately can't process a request, return `Skipped` rather than fabricating a 404 — let the chain decide. Reserve the other errors in `HandleError` (`Internal`, `BadRequest`, `Unauthorized`) for real failures.

## HandleError is a closed set

`HandleError` is the union of every error a handler may legitimately return:

```zig
pub const Error = error{
    StreamTooLong, OutOfMemory, ReadFailed, WriteFailed, NoSpaceLeft,
    Skipped,
    Internal, BadRequest, Unauthorized,
};
```

When you catch a domain-specific error (e.g. `error.InvalidJson`), translate it to one of these (`BadRequest`) before propagating. Don't broaden the error set — every caller in the chain has to handle it.

## Logging

```zig
const log = std.log.scoped(.vish);
```

All library modules log under the `.vish` scope. Demos use their own scope (`.demo`). Set per-scope levels via `std_options`:

```zig
pub const std_options: std.Options = .{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .vish, .level = .warn },
    },
};
```

## Header naming

`request.Headers` and `response.Headers` are structs with `snake_case` fields. Wire format is generated by replacing `_` with `-` and capitalizing each segment at comptime — `content_length` becomes `Content-Length`. To add a new typed header, add the field; the parser and serializer pick it up automatically (subject to type-dispatch in `Headers.read`/`sendHeaders`).

For arbitrary inbound headers, opt in with `ListenOptions.parse_extra_headers = true` and read via `req.headers.get("X-Foo")`. For arbitrary outbound headers, append to `res.headers.extra: []const ExtraHeader`.

## When you change public API

Update `src/root.zig` to re-export the new symbol — it is the single public surface. The README usage example and `docs/usage.md` should stay in sync with what `root.zig` exposes.
