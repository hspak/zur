const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const aur = @import("aur.zig");
const curl = @import("curl.zig");
const v = @import("version.zig");

pub const Pacman = struct {
    allocator: *mem.Allocator,
    pkgs: std.StringHashMap(*Package),

    const Self = @This();

    pub fn init(allocator: *mem.Allocator) !Self {
        try curl.init();
        return Self{
            .allocator = allocator,
            .pkgs = std.StringHashMap(*Package).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var pkgs_iter = self.pkgs.iterator();
        while (pkgs_iter.next()) |pkg| {
            self.allocator.destroy(pkg);
        }
        self.pkgs.deinit();
    }

    // TODO: use libalpm once this issue is fixed:
    // https://github.com/ziglang/zig/issues/1499
    pub fn fetchLocalPackages(self: *Self) !void {
        const result = try std.ChildProcess.exec(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "pacman", "-Qm" },
        });

        var lines = mem.split(result.stdout, "\n");
        while (lines.next()) |line| {
            // ignore empty lines if they exist
            if (line.len <= 1) {
                continue;
            }

            var line_iter = mem.split(line, " ");
            const name = line_iter.next() orelse return error.UnknownPacmanQmOutputFormat;
            const version = line_iter.next() orelse return error.UnknownPacmanQmOutputFormat;

            var new_pkg = try self.allocator.create(Package);
            new_pkg.version = version;
            try self.pkgs.putNoClobber(name, new_pkg);
        }
    }

    pub fn fetchRemoteAurVersions(self: *Self) !void {
        var remote_resp = try aur.query(self.allocator, self);
        for (remote_resp.results) |result| {
            var curr_pkg = self.pkgs.get(result.Name).?;
            curr_pkg.aur_version = result.Version;
        }
    }

    // TODO: maybe use libalpm once this issue is fixed:
    // https://github.com/ziglang/zig/issues/1499
    pub fn compareVersions(self: *Self) !void {
        var pkgs_iter = self.pkgs.iterator();

        while (pkgs_iter.next()) |pkg| {
            const local_version = try v.Version.init(pkg.value.version);
            const remote_version = try v.Version.init(pkg.value.aur_version.?);
            if (local_version.olderThan(remote_version)) {
                pkg.value.requires_update = true;
                std.debug.print("{s} is out of date {s} -> {s}!\n", .{ pkg.key, pkg.value.version, pkg.value.aur_version.? });
            }
        }
    }

    pub fn downloadUpdates(self: *Self) !void {}
};

pub const Package = struct {
    version: []const u8,
    aur_version: ?[]const u8 = null,
    requires_update: bool = false,
};
