const Build = @import("std").Build;
const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "zur",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });

    const version = b.option([]const u8, "version", "Set the build version") orelse "unset";
    const exe_options = b.addOptions();

    exe_options.addOption([]const u8, "version", version);

    exe.root_module.addOptions("build_options", exe_options);

    b.installArtifact(exe);
}
