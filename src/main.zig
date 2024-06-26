const std = @import("std");
const io = std.io;

const Args = @import("argparse.zig").Args;
const search = @import("pacman.zig").search;
const Pacman = @import("pacman.zig").Pacman;

const build_version = @import("build_options").version;

pub const log_level: std.log.Level = .info;

const mainerror = error{
    ZeroResultsFromAurQuery,
    CouldntResolveHost,
};

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var args = Args.init(allocator);
    defer args.deinit();
    try args.parse();

    switch (args.action) {
        .PrintHelp => try printHelp(),
        .PrintVersion => try printVersion(),
        .Search => search(allocator, args.pkgs.items[0]) catch |err| {
            if (err == mainerror.CouldntResolveHost) {
                try io.getStdOut().writer().print("Please check your connection\n", .{});
            } else {
                try io.getStdErr().writer().print("Found error {any}\n", .{err});
            }
        },
        .InstallOrUpgrade => installOrUpdate(allocator, args.pkgs) catch |err| {
            if (err == mainerror.ZeroResultsFromAurQuery) {
                try io.getStdOut().writer().print("No aur packages found\n", .{});
            } else if (err == mainerror.CouldntResolveHost) {
                try io.getStdOut().writer().print("Please check your connection\n", .{});
            } else {
                try io.getStdErr().writer().print("Found error {any}\n", .{err});
            }
        },
        .Unset => @panic("Args somehow ended up with 'Unset' state"),
    }
}

fn installOrUpdate(allocator: std.mem.Allocator, pkg_list: std.ArrayList([]const u8)) !void {
    var pacman = try Pacman.init(allocator);

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
    _ = try stderr.write(msg);
}

fn printVersion() !void {
    var stdout = &io.getStdOut().writer();
    _ = try stdout.write("version: " ++ build_version ++ "\n");
}
