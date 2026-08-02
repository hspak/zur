const Build = @import("std").Build;
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.linkSystemLibrary("alpm", .{});

    const exe = b.addExecutable(.{
        .name = "zur",
        .root_module = exe_mod,
    });

    const version = b.option([]const u8, "version", "Set the build version") orelse "unset";
    const exe_options = b.addOptions();

    exe_options.addOption([]const u8, "version", version);

    exe_mod.addOptions("build_options", exe_options);

    b.installArtifact(exe);

    // Add test step
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.linkSystemLibrary("alpm", .{});

    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
