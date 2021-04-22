const std = @import("std");
const io = std.io;
const process = std.process;

const curl = @import("curl.zig");
const Pacman = @import("pacman.zig").Pacman;

const build_version = @import("build_options").version;

pub const log_level: std.log.Level = .info;

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    var allocator = &arena_state.allocator;

    var pkg_list = parseArgs(allocator) catch |err| switch (err) {
        error.NoAction => return,
        else => {
            try printHelp();
            return;
        },
    };
    defer pkg_list.deinit();

    try curl.init();
    defer curl.deinit();

    var pacman = try Pacman.init(allocator);
    defer pacman.deinit();

    // default to updating all AUR packages
    if (pkg_list.items.len == 0) {
        try pacman.fetchLocalPackages();
    } else {
        // This is a slight hack to have the install process share
        // the same code path as the update process.
        try pacman.setInstallPackages(pkg_list);
    }
    try pacman.fetchRemoteAurVersions();
    try pacman.compareVersions();
    try pacman.processOutOfDate();
}

fn parseArgs(allocator: *std.mem.Allocator) !std.ArrayList([]const u8) {
    var args_iter = process.args();
    var exe = try args_iter.next(allocator).?;
    var action = args_iter.next(allocator) orelse return std.ArrayList([]const u8).init(allocator);
    if (std.mem.eql(u8, try action, "-h") or std.mem.eql(u8, try action, "--help")) {
        try printHelp();
        return error.NoAction;
    } else if (std.mem.eql(u8, try action, "-v") or std.mem.eql(u8, try action, "--version")) {
        try printVersion();
        return error.NoAction;
    } else if (!std.mem.eql(u8, try action, "-S")) {
        return error.UnsupportedAction;
    }

    var pkg_list = std.ArrayList([]const u8).init(allocator);
    while (args_iter.next(allocator)) |arg_or_err| {
        const arg = arg_or_err catch unreachable;
        try pkg_list.append(arg);
    }
    if (pkg_list.items.len == 0) {
        return error.ActionMissingPackages;
    }
    return pkg_list;
}

fn printHelp() !void {
    const msg =
        \\usage: zur [action]
        \\
        \\  actions:
        \\    -S <pkg1> [pkg2]...  install packages
        \\
        \\  default action: update out-of-date AUR packages
        \\
    ;
    var stderr = &io.getStdErr().writer();
    const btyes_written = try stderr.write(msg);
}

fn printVersion() !void {
    var stdout = &io.getStdOut().writer();
    _ = try stdout.write("version: " ++ build_version ++ "\n");
}
