const std = @import("std");
const io = std.io;
const process = std.process;

const curl = @import("curl.zig");
const pacman = @import("pacman.zig");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    var allocator = &arena_state.allocator;

    var pkg_list = try parseArgs(allocator);
    defer pkg_list.deinit();

    try curl.init();
    defer curl.deinit();

    var pm = try pacman.Pacman.init(allocator);
    defer pm.deinit();

    // default to updating all AUR packages
    if (pkg_list.items.len == 0) {
        try pm.fetchLocalPackages();
    } else {
        // This is a slight hack to have the install process share
        // the same code path as the update process.
        try pm.setInstallPackages(pkg_list);
    }
    try pm.fetchRemoteAurVersions();
    try pm.compareVersions();
    try pm.processOutOfDate();
}

fn parseArgs(allocator: *std.mem.Allocator) !std.ArrayList([]const u8) {
    var args_iter = process.args();
    var exe = try args_iter.next(allocator).?;
    var action = args_iter.next(allocator) orelse return std.ArrayList([]const u8).init(allocator);
    if (std.mem.eql(u8, try action, "-h") or std.mem.eql(u8, try action, "--help")) {
        try printHelp();
    } else if (std.mem.eql(u8, try action, "-v") or std.mem.eql(u8, try action, "--version")) {
        try printHelp();
    } else if (!std.mem.eql(u8, try action, "-S")) {
        return error.UnsupportedAction;
    }

    var pkg_list = std.ArrayList([]const u8).init(allocator);
    while (args_iter.next(allocator)) |arg_or_err| {
        const arg = arg_or_err catch unreachable;
        try pkg_list.append(arg);
    }
    return pkg_list;
}

fn printHelp() !void {
    const msg =
        \\usage: zur [action]
        \\
        \\  actions:
        \\    -S <pkg1> <pkg2>  install packages
        \\
        \\  default action: update out-of-date AUR packages
        \\
    ;
    var stderr = &io.getStdErr().writer();
    const btyes_written = try stderr.write(msg);
}

fn printVersion() !void {
    var stdout = &io.getStdOut().writer();
    const btyes_written = try stdout.write("version: TODO\n");
}
