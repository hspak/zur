//! zur: install and update AUR packages.

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.main);

const Args = @import("Args.zig");
const Pacman = @import("Pacman.zig");
const search = Pacman.search;

const build_version = @import("build_options").version;

pub const log_level: std.log.Level = .info;

const MainError = Pacman.Error || error{
    CouldntResolveHost,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();

    var args = Args.init(allocator);
    defer args.deinit();
    try args.parse(init.minimal.args);
    log.debug("starting action={t}", .{args.action});

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    switch (args.action) {
        .print_help => {
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
        .print_version => {
            try stderr.writeAll("version: " ++ build_version ++ "\n");
        },
        .search => search(allocator, io, init.environ_map, args.pkgs.items[0]) catch |err| {
            if (err == MainError.CouldntResolveHost) {
                try stderr.print("Please check your connection\n", .{});
            } else {
                try stderr.print("Found error {any}\n", .{err});
            }
        },
        .install_or_upgrade => installOrUpdate(allocator, io, init.environ_map, args.pkgs) catch |err| {
            if (err == MainError.ZeroResultsFromAurQuery) {
                try stderr.print("No aur packages found\n", .{});
            } else if (err == MainError.CouldntResolveHost) {
                try stderr.print("Please check your connection\n", .{});
            } else {
                try stderr.print("Found error {any}\n", .{err});
            }
        },
        // parse() never leaves action unset; Unset is only the pre-parse default.
        .unset => unreachable,
    }
    try stderr.flush();
}

fn installOrUpdate(
    allocator: std.mem.Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    pkg_list: std.ArrayList([]const u8),
) MainError!void {
    var pacman = try Pacman.init(allocator, io, environ_map);
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
