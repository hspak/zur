//! zur: install and update AUR packages.

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.main);

const Args = @import("Args.zig");
const Pacman = @import("Pacman.zig");
const search = Pacman.search;

const build_version = @import("build_options").version;

pub const log_level: std.log.Level = .info;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const allocator = init.arena.allocator();

    var args = Args.init(allocator);
    defer args.deinit();
    try args.parse(init.minimal.args);
    log.debug("starting action={t}", .{args.action});

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    var exit_code: u8 = 0;
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
        .search => search(
            allocator,
            io,
            init.environ_map,
            args.pkgs.items[0],
        ) catch |err| {
            try printCaughtError(stderr, err);
            exit_code = 1;
        },
        .install_or_upgrade => installOrUpdate(
            allocator,
            io,
            init.environ_map,
            args.pkgs.items,
        ) catch |err| {
            try printCaughtError(stderr, err);
            exit_code = 1;
        },
        // parse() never leaves action unset; Unset is only the pre-parse default.
        .unset => unreachable,
    }
    try stderr.flush();
    return exit_code;
}

fn printCaughtError(stderr: *Io.Writer, err: Pacman.Error) !void {
    switch (err) {
        error.ZeroResultsFromAurQuery => try stderr.print("No aur packages found\n", .{}),
        // These are the DNS/connect failures std.http actually returns.
        error.UnknownHostName,
        error.NameServerFailure,
        error.NoAddressReturned,
        error.HostUnreachable,
        => try stderr.print("Please check your connection\n", .{}),
        else => try stderr.print("Found error {any}\n", .{err}),
    }
}

fn installOrUpdate(
    allocator: std.mem.Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    pkg_list: []const []const u8,
) Pacman.Error!void {
    var pacman = try Pacman.init(allocator, io, environ_map);
    defer pacman.deinit();

    try pacman.installOrUpdate(pkg_list);
}

test "CLI reports operational failures with a nonzero exit status" {
    const testing = std.testing;
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    for ([_][]const u8{ "-S", "-Ss" }) |action| {
        const result = try std.process.run(testing.allocator, testing.io, .{
            .argv = &.{ @import("cli_test_options").executable, action, "review-missing-home" },
            .environ_map = &environ,
        });
        defer testing.allocator.free(result.stdout);
        defer testing.allocator.free(result.stderr);
        try testing.expect(std.mem.indexOf(u8, result.stderr, "NoHomeEnvVarFound") != null);
        try testing.expect(result.term == .exited);
        try testing.expect(result.term.exited != 0);
    }
    const help = try std.process.run(testing.allocator, testing.io, .{
        .argv = &.{ @import("cli_test_options").executable, "--help" },
        .environ_map = &environ,
    });
    defer testing.allocator.free(help.stdout);
    defer testing.allocator.free(help.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, help.term);
    try testing.expect(std.mem.indexOf(u8, help.stderr, "usage: zur") != null);
}
