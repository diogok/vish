const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vish = b.addModule("vish", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/root.zig"),
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const run_test_step = b.step("test", "Run tests");
    run_test_step.dependOn(&run_tests.step);

    _ = addExecutableWithRun(b, target, optimize, vish, "demo", "src/demo.zig", "run", "Run demo");

    const demo2 = addExecutableWithRun(b, target, optimize, vish, "demo2", "src/demo2.zig", "run2", "Run demo2");
    demo2.root_module.addImport("assets", addStaticAssets(b, target, optimize, "src/assets"));

    _ = addExecutableWithRun(
        b,
        target,
        optimize,
        vish,
        "ws-echo",
        "src/ws_echo.zig",
        "ws-echo",
        "Run the WebSocket client probe (demo2's /ws by default)",
    );
}

/// Add an executable rooted at `source` that imports `vish_module`,
/// install it with the default step, and register `step_name` to run
/// it with the arguments given after `--`. Returns the compile step so
/// further imports can be added.
fn addExecutableWithRun(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    vish_module: *std.Build.Module,
    name: []const u8,
    source: []const u8,
    step_name: []const u8,
    description: []const u8,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .strip = optimize == .ReleaseSmall,
        }),
    });
    exe.root_module.addImport("vish", vish_module);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step(step_name, description);
    run_step.dependOn(&run_cmd.step);
    return exe;
}

/// Build a module that exposes the contents of `dir` as a static asset
/// table. Pair with `vish.utils.router.StaticRouter` to serve the files
/// over HTTP.
///
/// In Debug builds the lookup reads from disk on every call (so edits
/// to the asset directory are picked up without a rebuild). In release
/// builds the bytes are `@embedFile`'d into the binary.
///
/// The returned module exports:
///
/// ```
/// pub const Asset = struct {
///     content: []const u8,
///     pub fn deinit(self: Asset) void;
/// };
/// pub fn get(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ?Asset;
/// ```
pub fn addStaticAssets(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dir: []const u8,
) *std.Build.Module {
    const io = b.graph.io;

    const options = b.addOptions();
    options.addOption([]const u8, "asset_dir", b.pathFromRoot(dir));

    const wf = b.addWriteFiles();
    _ = wf.addCopyDirectory(b.path(dir), "", .{});

    // Collect file paths from the asset directory
    var file_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var abs_dir = std.Io.Dir.cwd().openDir(io, b.pathFromRoot(dir), .{ .iterate = true }) catch |err|
        std.debug.panic("failed to open asset directory '{s}': {t}", .{ b.pathFromRoot(dir), err });
    defer abs_dir.close(io);
    collectFiles(io, b.allocator, abs_dir, "", &file_list);

    // Generate the asset module: an `Asset` struct and a `get(io, allocator, path) ?Asset`
    // lookup. In Debug it reads from disk on each call (the asset directory is the source
    // tree, so edits show up without a rebuild); in release it returns @embedFile'd bytes.
    var src_alloc = std.Io.Writer.Allocating.init(b.allocator);
    defer src_alloc.deinit();
    const w = &src_alloc.writer;
    w.writeAll(
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\const options = @import("build_options");
        \\
        \\pub const Asset = struct {
        \\    content: []const u8,
        \\    owned_allocator: ?std.mem.Allocator,
        \\
        \\    pub fn deinit(self: Asset) void {
        \\        if (self.owned_allocator) |a| a.free(self.content);
        \\    }
        \\};
        \\
        \\pub fn get(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ?Asset {
        \\    if (comptime builtin.mode == .Debug) {
        \\        var asset_dir = std.Io.Dir.cwd().openDir(io, options.asset_dir, .{}) catch return null;
        \\        defer asset_dir.close(io);
        \\        const bytes = asset_dir.readFileAlloc(io, path, allocator, .unlimited) catch return null;
        \\        return .{ .content = bytes, .owned_allocator = allocator };
        \\    } else {
        \\        const bytes = files.get(path) orelse return null;
        \\        return .{ .content = bytes, .owned_allocator = null };
        \\    }
        \\}
        \\
        \\const files = std.StaticStringMap([]const u8).initComptime(.{
        \\
    ) catch unreachable;

    for (file_list.items) |file_path| {
        w.print("    .{{ \"{s}\", @embedFile(\"{s}\") }},\n", .{ file_path, file_path }) catch unreachable;
    }

    w.writeAll(
        \\});
        \\
    ) catch unreachable;

    const source = wf.add("_assets.zig", src_alloc.written());

    return b.createModule(.{
        .root_source_file = source,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
        },
    });
}

// Failures panic rather than skip: a silently half-empty asset table
// would only surface as unexplained 404s at runtime.
fn collectFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    base_dir: std.Io.Dir,
    prefix: []const u8,
    list: *std.ArrayList([]const u8),
) void {
    var iter = base_dir.iterate();
    while (iter.next(io) catch |err|
        std.debug.panic("failed to iterate asset directory '{s}': {t}", .{ prefix, err })) |entry|
    {
        const name = if (prefix.len > 0)
            std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name }) catch @panic("OOM")
        else
            allocator.dupe(u8, entry.name) catch @panic("OOM");

        switch (entry.kind) {
            .file => list.append(allocator, name) catch @panic("OOM"),
            .directory => {
                var sub = base_dir.openDir(io, entry.name, .{ .iterate = true }) catch |err|
                    std.debug.panic("failed to open asset directory '{s}': {t}", .{ name, err });
                defer sub.close(io);
                collectFiles(io, allocator, sub, name, list);
            },
            else => {},
        }
    }
}
