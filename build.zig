const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("zur", "src/main.zig");
    exe.linkLibC();
    exe.linkSystemLibrary("curl");

    // Maybe one day
    // exe.linkSystemLibrary("alpm");

    exe.setBuildMode(mode);
    exe.setTarget(target);

    const version = b.option([]const u8, "version", "Set the build version") orelse "unset";
    exe.addBuildOption([]const u8, "version", version);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
