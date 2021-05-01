const std = @import("std");
const io = std.io;

const Args = @import("argparse.zig").Args;
const curl = @import("curl.zig");
const search = @import("pacman.zig").search;
const Pacman = @import("pacman.zig").Pacman;

const build_version = @import("build_options").version;

pub const log_level: std.log.Level = .info;

pub fn main() !void {
    // var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    // defer arena_state.deinit();
    // var allocator = &arena_state.allocator;

    // Technically, it makes more sense to use the arena allocator here,
    // but I want to build some muscle memory with deallocating.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = &gpa.allocator;
    defer {
        const leaked = gpa.deinit();
        if (leaked) @panic("memory leak");
    }

    var args = Args.init(allocator);
    defer {
        for (args.pkgs.items) |pkg| {
            allocator.free(pkg);
        }
        args.deinit();
    }
    try args.parse();

    switch (args.action) {
        .PrintHelp => try printHelp(),
        .PrintVersion => try printVersion(),
        .Search => try search(allocator, args.pkgs.items[0]),
        .InstallOrUpgrade => try installOrUpdate(allocator, args.pkgs),
        .Unset => @panic("Args somehow ended up with 'Unset' state"),
    }
}

fn installOrUpdate(allocator: *std.mem.Allocator, pkg_list: std.ArrayList([]const u8)) !void {
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

fn printHelp() !void {
    const msg =
        \\usage: zur [action]
        \\
        \\  actions:
        \\    -S <pkg1> [pkg2]...  install packages
        \\    -Ss <pkg>            search for packages by name
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
