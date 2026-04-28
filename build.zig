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

    {
        const exe = b.addExecutable(.{
            .name = "demo",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/demo.zig"),
                .target = target,
                .optimize = optimize,
                .strip = optimize == .ReleaseSmall,
            }),
        });
        exe.root_module.addImport("vish", vish);
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run", "Run demo");
        run_step.dependOn(&run_cmd.step);
    }

    {
        const assets = addStaticAssets(b, target, optimize, "src/assets");

        const exe = b.addExecutable(.{
            .name = "demo2",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/demo2.zig"),
                .target = target,
                .optimize = optimize,
                .strip = optimize == .ReleaseSmall,
            }),
        });
        exe.root_module.addImport("vish", vish);
        exe.root_module.addImport("assets", assets);
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run2", "Run demo2");
        run_step.dependOn(&run_cmd.step);
    }
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
    var abs_dir = std.Io.Dir.cwd().openDir(io, b.pathFromRoot(dir), .{ .iterate = true }) catch
        @panic("failed to open asset directory");
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

fn collectFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    base_dir: std.Io.Dir,
    prefix: []const u8,
    list: *std.ArrayList([]const u8),
) void {
    var iter = base_dir.iterate();
    while (iter.next(io) catch null) |entry| {
        const name = if (prefix.len > 0)
            std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name }) catch continue
        else
            allocator.dupe(u8, entry.name) catch continue;

        switch (entry.kind) {
            .file => list.append(allocator, name) catch {},
            .directory => {
                var sub = base_dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                collectFiles(io, allocator, sub, name, list);
            },
            else => {},
        }
    }
}
