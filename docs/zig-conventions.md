# Zig Coding Conventions

Generic conventions for all Zig projects.

## Naming

| Kind              | Style        | Examples                                     |
|-------------------|--------------|----------------------------------------------|
| Types / structs   | `PascalCase` | `Image`, `Window`, `FlushTarget`, `BBox`     |
| Functions         | `camelCase`  | `setPixels`, `getContext`, `fillText`         |
| Variables / fields| `snake_case` | `fill_color`, `line_width`, `pixel_buffer`   |
| Tagged union tags | `snake_case` | `move_to`, `line_to`, `key_pressed`          |
| Type aliases      | `PascalCase` | `WindowID`, `Height`, `Width`, `Scancode`    |

### Spell out names

Avoid single-letter and cryptic abbreviations. Loop variables should say what
they iterate over.

```zig
// Bad
for (0..n) |i| { ... }

// Good
for (0..config.layers) |layer| { ... }
```

Exception: `i` is fine for pure index iteration in tight arithmetic
(e.g. `for (0..half_dim) |i|`).

### Public function parameters should be self-documenting

```zig
// Bad
pub fn process(pool: ?*Pool, in: []const f32, n: usize) void

// Good
pub fn process(pool: ?*Pool, input: []const f32, batch_size: usize) void
```

### Scratch buffers — name by role or add a comment

```zig
// Bad
const batch_a = try allocator.alloc(f32, num_tokens * dim);
const batch_b = try allocator.alloc(f32, num_tokens * dim);

// Good — named by role, with comment explaining reuse
// scratch_a and scratch_b alternate as input/output across stages.
const scratch_a = try allocator.alloc(f32, num_tokens * dim);
const scratch_b = try allocator.alloc(f32, num_tokens * dim);
```

## File-as-struct

When a file defines a single primary type, the file _is_ the struct — bare
fields at the top, methods below, no wrapping `pub const Foo = struct { ... }`.

```zig
// image.zig — the file IS the Image struct
platform_image: PlatformImage,
window: *Window,
bbox: common.BBox,
scaling: f32,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, window: *Window, bbox: common.BBox) !@This() {
    ...
}

pub fn deinit(self: *@This()) void { ... }
```

Callers get the type name from the import:
```zig
const Image = @import("image.zig");
```

When a file exports multiple types (e.g. `common.zig`), use named `pub const`
structs instead.

## @This() usage

Use `@This()` directly in method signatures for file-as-struct modules.
Use `const Self = @This()` when inside a returned generic struct (e.g. from a
`fn Foo(comptime T: type) type` function).

```zig
// File-as-struct — use @This() directly
pub fn init(allocator: std.mem.Allocator) @This() { ... }
pub fn deinit(self: *@This()) void { ... }

// Generic returned struct — Self alias is clearer
pub fn ThreadSafeQueue(Type: type) type {
    return struct {
        const Self = @This();
        pub fn push(self: *Self, item: Type) void { ... }
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
fill_color: [4]u8 = .{ 0, 0, 0, 255 },
stroke_color: [4]u8 = .{ 0, 0, 0, 255 },
line_width: u16 = 1,

// Lifecycle
pub fn init(...) @This() { ... }
pub fn deinit(self: *@This()) void { ... }

// Public API
pub fn setPixels(self: *@This(), pixels: []const u8) !void { ... }
pub fn getContext(self: *@This()) !Context { ... }

// Private
fn nearestNeighbor(...) ![]u8 { ... }
```

## Self parameter conventions

Use `*@This()` for methods that mutate, `@This()` (by value) for pure queries.

```zig
pub fn setX(self: *@This(), x: X) void { self.dst_bbox.x = x; }
pub fn get(self: @This(), codepoint: u21) ?Glyph { return self.glyphs.get(codepoint); }
```

Use `_:` for unused self parameters instead of `_ = self`:

```zig
// Bad
pub fn destroyContext(self: *Self, ctx: *Context) void {
    _ = self;
    ctx.deinit();
}

// Good
pub fn destroyContext(_: *Self, ctx: *Context) void {
    ctx.deinit();
}
```

## Parameter passing

Pass structs by value unless the callee needs to mutate them or they are
genuinely large (e.g. contain unbounded buffers). Zig passes small structs in
registers — a `*const T` adds indirection for no benefit.

```zig
// Bad — unnecessary pointer for a read-only snapshot
pub fn update(self: *@This(), input: *const InputState, dt: f64) void { ... }

// Good — pass by value
pub fn update(self: *@This(), input: InputState, dt: f64) void { ... }
```

Use pointers only when:
- The callee needs to mutate the value (`*T`).
- The struct is large or variable-size (contains slices that alias external
  data and copying would be misleading).
- You need the address to outlive the call (storing a reference).

## Type-erased interfaces

Follow the `std.io.Reader` pattern for polymorphic interfaces. The interface
is a small value type (two pointers). VTable functions take a pointer to the
interface as the first parameter. `wrap(T)` returns a typed wrapper that
produces the type-erased interface on demand.

```zig
// The interface: ptr + vtable.
pub const Widget = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // VTable functions take a pointer to the interface, not *anyopaque.
        render: *const fn (*Widget, *Surface) void,
        rect: *const fn (*Widget) Rect,
    };

    // Convenience methods forward to vtable, passing self.
    pub fn render(self: *Widget, ctx: *Surface) void {
        self.vtable.render(self, ctx);
    }
    pub fn rect(self: *Widget) Rect {
        return self.vtable.rect(self);
    }

    /// Return a typed wrapper for the given concrete type.
    pub fn wrap(T: type) type {
        return struct {
            ptr: *T,

            pub fn init(ptr: *T) @This() {
                return .{ .ptr = ptr };
            }

            /// Produce the type-erased interface.
            pub fn widget(self: @This()) Widget {
                return .{ .ptr = self.ptr, .vtable = &vtable_instance };
            }

            const vtable_instance = VTable{
                .render = renderFn,
                .rect = rectFn,
            };

            fn renderFn(w: *Widget, ctx: *Surface) void {
                const concrete: *T = @ptrCast(@alignCast(w.ptr));
                concrete.render(ctx);
            }

            fn rectFn(w: *Widget) Rect {
                const concrete: *T = @ptrCast(@alignCast(w.ptr));
                return concrete.rect();
            }
        };
    }
};
```

Concrete type — caller-owned, implements methods by duck typing:

```zig
const Button = struct {
    node_rect: Rect = .{},

    pub fn render(self: *Button, ctx: *Surface) void { ... }
    pub fn rect(self: *Button) Rect { return self.node_rect; }

    /// Return the type-erased interface.
    pub fn widget(self: *Button) Widget {
        return Widget.wrap(Button).init(self).widget();
    }
};
```

Usage:

```zig
var btn = Button{ ... };
var w = btn.widget();     // type-erased Widget
w.render(ctx);            // dispatches through vtable
```

Rules:

- VTable functions take a **pointer to the interface type** as the first
  parameter (not `*anyopaque`). The wrapper casts `w.ptr` to the concrete type.
- VTable field names match the convenience method names (no `Fn` suffix).
- `wrap(T)` returns a comptime-generated wrapper struct with a typed pointer
  and a static vtable instance.
- Optional vtable methods use `?*const fn` and are auto-detected with
  `@hasDecl` in the wrapper.
- Concrete types provide a named method returning the interface
  (e.g. `.widget()`, `.component()`).
- The caller owns the concrete type. The interface borrows a pointer.
- The interface does not have `deinit` — lifetime is the caller's
  responsibility, like `ArrayList` not freeing its elements.

## Imports

Imports go at the **bottom** of the file (Zig convention for file-as-struct
modules — fields must come first).

```zig
// At the bottom of image.zig
const std = @import("std");
const common = @import("common.zig");
const Window = @import("any.zig").Window;
```

## Return values

Prefer `.{}` anonymous struct literal returns:

```zig
pub fn init(allocator: std.mem.Allocator) @This() {
    return .{ .allocator = allocator, .images = .{} };
}
```

## Error handling

- Propagate errors with `!` return types and `try`.
- Use `errdefer` for cleanup on error paths.
- Use `catch |err| switch (err) { ... }` for selective error handling.

```zig
pub fn init(allocator: std.mem.Allocator, path: []const u8) !@This() {
    const resource = try openResource(path);
    errdefer resource.close();
    return .{ .resource = resource, .allocator = allocator };
}
```

## Memory management

- Always pass `std.mem.Allocator` explicitly — no globals.
- Pair every `init` with a `deinit`, every `create` with a `destroy`.
- Use `defer`/`errdefer` at the call site.

```zig
var img = try Image.init(allocator, config);
defer img.deinit();
```

## Io parameter (Zig 0.16+)

Anything that touches the OS (filesystem, network, sleep, sync,
randomness) takes `io: std.Io` as its first parameter, before the
allocator. Same rule as allocators: thread it through, never construct
one at the call site.

```zig
pub fn loadConfig(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}
```

Sync primitives now live under `std.Io` (`std.Io.Mutex`,
`std.Io.Condition`, `std.Io.RwLock`, `std.Io.Event`) and their methods
take `io`. Use `io.async` / `io.concurrent` for tasks; the
`std.Thread.Pool` is gone.

## Juicy Main

`main` takes a `std.process.Init` and pulls `io` and `gpa` from it,
rather than constructing them. This is the only place either should be
created — every other function receives them as parameters.

```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // ...
}
```

For tests use `std.testing.io` and `std.testing.allocator`. For places
genuinely without a parent `Io` (one-off scripts, library internals
during migration), construct one explicitly:

```zig
var threaded: std.Io.Threaded = .init_single_threaded;
const io = threaded.io();
```

Command-line args come from `init.minimal.args` — they live in the
init arena and don't need a separate free:

```zig
const args = try init.minimal.args.toSlice(init.arena.allocator());
```

## Tagged unions and enums

Use tagged unions for event systems and command types:

```zig
pub const Event = union(enum) {
    nop: void,
    close: WindowID,
    draw: struct { window_id: WindowID, area: BBox = .{} },
    mouse_pressed: struct { x: X, y: Y, button: MouseButton, window_id: WindowID },
    key_pressed: struct { scancode: Scancode, key: Key, modifiers: Modifiers, window_id: WindowID },
};
```

Use enums for finite sets:

```zig
pub const Status = enum {
    created,
    ready,
    in_progress,
    done,
    cancelled,
};
```

## Comptime and generics

Use `anytype` for duck-typed parameters. Use comptime functions that return
`type` for generic containers.

```zig
// anytype for simple generics
pub fn applyScaling(v: anytype, scaling: f32) @TypeOf(v) { ... }

// Comptime function returning a type
pub fn EventLoop(Sources: type) type {
    return struct { ... };
}

// Convenience wrapper
pub fn eventLoop(sources: anytype) EventLoop(@TypeOf(sources)) {
    return EventLoop(@TypeOf(sources)).init(sources);
}
```

Use `inline for` when iterating comptime-known fields:

```zig
inline for (source_fields, 0..) |field, i| {
    self.threads[i] = try std.Thread.spawn(.{}, pollSource(field.name), .{self});
}
```

## Function organization

### Extract duplicated logic into shared helpers

```zig
// Bad — softmax duplicated across multiple call sites
{
    var max_val: f32 = scores[0];
    for (scores[1..]) |score| max_val = @max(max_val, score);
    var sum_exp: f32 = 0.0;
    for (scores) |*score| {
        score.* = @exp(score.* - max_val);
        sum_exp += score.*;
    }
    ...
}

// Good — extracted to a shared function
fn softmax(scores: []f32) void { ... }
```

### Use semantic function names

```zig
// Bad — which parameter is the output?
pub fn weightedSum(values: []const f32, scale: f32, output: []f32) void

// Good — output comes first, reads naturally: output += values * scale
pub fn scaledAdd(output: []f32, values: []const f32, scale: f32) void
```

## Comments

- `//!` for module-level doc comments (top of file).
- `///` for public API doc comments.
- `//` for inline explanations. Only where the code isn't self-evident.

```zig
//! A positioned image with DPI scaling.

/// Initialize an image bound to a window at the given position and size.
pub fn init(allocator: std.mem.Allocator, window: *Window, bbox: common.BBox) !@This() { ... }

// P4: packed binary bits, MSB first, rows padded to byte boundary
```

## Tests

Tests live at the bottom of the file they test, after a `test` block:

```zig
test "nearestNeighbor 2x upscale" {
    const allocator = testing.allocator;
    const src = [_]u8{ 0xFF, 0x00, 0xFF, 0xFF, ... };
    const result = try nearestNeighbor(allocator, &src, 2, 2, 4, 4);
    defer allocator.free(result);
    try testing.expectEqual(@as(usize, 64), result.len);
}
```

Use `testing.allocator` (detects leaks) and `std.testing.expect*` assertions.

## Code hygiene

- Remove dead code, unused imports, and unused struct fields — version control
  has them.
- Name magic numbers when the meaning isn't obvious from context.
- Don't keep code "just in case".

```zig
// Bad — what does 85 mean?
const threshold = max_freq * 85 / 100;

// Good — intent is clear
const p_core_freq_threshold_percent = 85;
const threshold = max_freq * p_core_freq_threshold_percent / 100;
```

## Performance and vectorization

Prefer simple, clear loops over hand-written SIMD. LLVM auto-vectorizes common
patterns in ReleaseFast — often with wider registers (AVX2 256-bit) than
explicit `@Vector` code uses.

### When simple loops are enough

Constant-value fills and simple arithmetic auto-vectorize well.
Write them as straightforward loops:

```zig
// Preferred — compiler auto-vectorizes this
for (0..dim) |i| {
    output[i] += input[i] * scale;
}
```

Use `@setFloatMode(.optimized)` in hot paths to enable FMA and reassociation:

```zig
fn dotProduct(a: []const f32, b: []const f32) f32 {
    @setFloatMode(.optimized);
    var sum: f32 = 0.0;
    for (a, b) |x, y| {
        sum += x * y;
    }
    return sum;
}
```

### When explicit SIMD helps

Use `@Vector` when the compiler cannot auto-vectorize — typically with
data-dependent branches or complex per-element logic:

```zig
const V8f = @Vector(8, f32);
var j: usize = 0;
while (j + 8 <= dim) : (j += 8) {
    const in: V8f = input[j..][0..8].*;
    const out: V8f = output[j..][0..8].*;
    output[j..][0..8].* = out + in * @as(V8f, @splat(scale));
}
```

Verify with `objdump -d -M intel` on a `-OReleaseFast` build before adding
explicit SIMD — if LLVM already vectorizes the loop, the explicit version adds
complexity for no gain (or worse, limits register width).

### Centralize repeated operations

Extract common patterns into shared functions rather than duplicating loops at
each call site. The compiler inlines them in release builds.

## Platform dispatch

Use comptime `switch` on `builtin.os.tag` for platform-specific types:

```zig
pub const WindowManager = switch (builtin.os.tag) {
    .linux => x11.WindowManager,
    .windows => windows.WindowManager,
    else => @compileError("platform not supported"),
};
```
