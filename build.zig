const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const http = b.addModule("http", .{
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
        exe.root_module.addImport("http", http);
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
        exe.root_module.addImport("http", http);
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

pub fn addStaticAssets(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dir: []const u8,
) *std.Build.Module {
    const options = b.addOptions();
    options.addOption([]const u8, "asset_dir", b.pathFromRoot(dir));

    const wf = b.addWriteFiles();
    _ = wf.addCopyDirectory(b.path(dir), "", .{});

    // Collect file paths from the asset directory
    var file_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var abs_dir = std.fs.cwd().openDir(b.pathFromRoot(dir), .{ .iterate = true }) catch
        @panic("failed to open asset directory");
    defer abs_dir.close();
    collectFiles(b.allocator, abs_dir, "", &file_list);

    // Generate asset module source with load() and get() functions
    var src: std.ArrayListUnmanaged(u8) = .empty;
    const w = src.writer(b.allocator);
    w.writeAll(
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\const options = @import("build_options");
        \\
        \\pub fn load(comptime path: []const u8) []const u8 {
        \\    if (comptime builtin.mode == .Debug) {
        \\        const abs = options.asset_dir ++ "/" ++ path;
        \\        return std.fs.cwd().readFileAlloc(std.heap.page_allocator, abs, 10 * 1024 * 1024) catch |err| {
        \\            std.log.err("load asset '{s}': {}", .{ abs, err });
        \\            @panic("failed to load asset");
        \\        };
        \\    } else {
        \\        return @embedFile(path);
        \\    }
        \\}
        \\
        \\pub fn get(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
        \\    if (comptime builtin.mode == .Debug) {
        \\        var asset_dir = std.fs.cwd().openDir(options.asset_dir, .{}) catch return null;
        \\        defer asset_dir.close();
        \\        return asset_dir.readFileAlloc(allocator, path, 10 * 1024 * 1024) catch null;
        \\    } else {
        \\        return files.get(path);
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

    const source = wf.add("_assets.zig", src.items);

    return b.createModule(.{
        .root_source_file = source,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
        },
    });
}

fn collectFiles(allocator: std.mem.Allocator, base_dir: std.fs.Dir, prefix: []const u8, list: *std.ArrayListUnmanaged([]const u8)) void {
    var iter = base_dir.iterate();
    while (iter.next() catch null) |entry| {
        const name = if (prefix.len > 0)
            std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name }) catch continue
        else
            allocator.dupe(u8, entry.name) catch continue;

        switch (entry.kind) {
            .file => list.append(allocator, name) catch {},
            .directory => {
                var sub = base_dir.openDir(entry.name, .{ .iterate = true }) catch continue;
                defer sub.close();
                collectFiles(allocator, sub, name, list);
            },
            else => {},
        }
    }
}
