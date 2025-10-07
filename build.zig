const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addIncludePath(.{
        .cwd_relative = "/opt/homebrew/opt/zlib/include",
    });
    root_module.addLibraryPath(.{
        .cwd_relative = "/opt/homebrew/opt/zlib/lib",
    });
    root_module.linkSystemLibrary("crypto", .{});
    root_module.linkSystemLibrary("ssl", .{});
    root_module.linkSystemLibrary("yaml", .{});
    root_module.linkSystemLibrary("z", .{});

    const exe = b.addExecutable(.{
        .name = "borderlands_4_save_editor",
        .root_module = root_module,
    });
    const exe_tests = b.addTest(.{
        .name = "borderlands_4_save_editor-test",
        .root_module = root_module,
    });

    const run_step = b.step("run", "Run the application.");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Test the application.");
    const test_cmd = b.addRunArtifact(exe_tests);
    test_step.dependOn(&test_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
