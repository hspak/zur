const std = @import("std");
const Io = std.Io;

const Args = @import("argparse.zig").Args;
const search = @import("pacman.zig").search;
const Pacman = @import("pacman.zig").Pacman;

const build_version = @import("build_options").version;

pub const log_level: std.log.Level = .info;

const mainerror = error{
    ZeroResultsFromAurQuery,
    CouldntResolveHost,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    var args = Args.init(allocator);
    defer args.deinit();
    try args.parse(init.minimal.args);

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    switch (args.action) {
        .PrintHelp => {
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
            try stderr.writeAll(msg);
        },
        .PrintVersion => {
            try stderr.writeAll("version: " ++ build_version ++ "\n");
        },
        .Search => search(allocator, io, init.environ_map, args.pkgs.items[0]) catch |err| {
            if (err == mainerror.CouldntResolveHost) {
                try stderr.print("Please check your connection\n", .{});
            } else {
                try stderr.print("Found error {any}\n", .{err});
            }
        },
        .InstallOrUpgrade => installOrUpdate(allocator, io, init.environ_map, args.pkgs) catch |err| {
            if (err == mainerror.ZeroResultsFromAurQuery) {
                try stderr.print("No aur packages found\n", .{});
            } else if (err == mainerror.CouldntResolveHost) {
                try stderr.print("Please check your connection\n", .{});
            } else {
                try stderr.print("Found error {any}\n", .{err});
            }
        },
        .Unset => @panic("Args somehow ended up with 'Unset' state"),
    }
    try stderr.flush();
}

fn installOrUpdate(
    allocator: std.mem.Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    pkg_list: std.ArrayList([]const u8),
) !void {
    var pacman = try Pacman.init(allocator, io, environ_map);

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
