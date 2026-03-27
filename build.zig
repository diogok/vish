const std = @import("std");

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
    const source = wf.add("_assets.zig",
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
    );

    return b.createModule(.{
        .root_source_file = source,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
        },
    });
}

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
