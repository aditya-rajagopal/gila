const std = @import("std");

pub fn build(b: *std.Build) void {
    // @NOTE Setting this to a higher value by default helps with debugging a lot
    b.reference_trace = 16;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const stdx = b.dependency("stdx", .{ .target = target }).module("stdx");

    const mod = b.addModule("gila", .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "stdx", .module = stdx },
        },
    });
    const zon_mod = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
        .target = target,
    });

    const exe_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "gila", .module = mod },
        .{ .name = "zon", .module = zon_mod },
        .{ .name = "stdx", .module = stdx },
    } });

    const exe = b.addExecutable(.{
        .name = if (optimize == .Debug) "gila_debug" else "gila",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const check_exe = b.addExecutable(.{ .name = "check", .root_module = exe_mod });
    const check_step = b.step("check", "Run ast check");
    check_step.dependOn(&check_exe.step);
}
