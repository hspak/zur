const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

const aur = @import("aur.zig");
const curl = @import("curl.zig");
const v = @import("version.zig");

pub const Pacman = struct {
    allocator: *mem.Allocator,
    pkgs: std.StringHashMap(*Package),
    zur_path: []const u8,
    updates: usize = 0,

    const Self = @This();

    pub fn init(allocator: *mem.Allocator) !Self {
        const home = os.getenv("HOME") orelse return error.NoHomeEnvVarFound;
        const zur_dir = ".zur";

        try curl.init();
        return Self{
            .allocator = allocator,
            .pkgs = std.StringHashMap(*Package).init(allocator),
            .zur_path = try mem.concat(allocator, u8, &[_][]const u8{ home, "/", zur_dir }),
        };
    }

    pub fn deinit(self: *Self) void {
        var pkgs_iter = self.pkgs.iterator();
        while (pkgs_iter.next()) |pkg| {
            self.allocator.destroy(pkg);
        }
        self.pkgs.deinit();
        curl.deinit();
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
                self.updates += 1;
            }
        }
    }

    pub fn downloadUpdates(self: *Self) !void {
        if (self.updates == 0) {
            // TODO output some helpful msg
            return;
        }
        try fs.cwd().makePath(self.zur_path);

        var pkgs_iter = self.pkgs.iterator();
        while (pkgs_iter.next()) |pkg| {
            if (pkg.value.requires_update) {
                std.log.info("Updating {s}: {s} -> {s}", .{ pkg.key, pkg.value.version, pkg.value.aur_version.? });
                const snapshot_path = try self.downloadPackage(pkg.key, pkg.value);
                std.log.info("Downloading snapshot: {s}/{s}.tar.gz", .{ snapshot_path, pkg.key });
                try self.extractPackage(snapshot_path, pkg.key);
            }
        }
    }

    fn downloadPackage(self: *Self, pkg_name: []const u8, pkg: *Package) ![]const u8 {
        var url = try std.fmt.allocPrintZ(self.allocator, "https://aur.archlinux.org/cgit/aur.git/snapshot/{s}.tar.gz", .{pkg_name});
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}-{s}", .{ self.zur_path, pkg_name, pkg.aur_version });
        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.tar.gz", .{ path, pkg_name });

        const snapshot = try curl.get(self.allocator, url);
        try fs.cwd().makePath(path);
        const snapshot_file = try fs.cwd().createFile(file_path, .{});
        try snapshot_file.writeAll(snapshot.items);
        return path;
    }

    fn extractPackage(self: *Self, snapshot_path: []const u8, pkg_name: []const u8) !void {
        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.tar.gz", .{ snapshot_path, pkg_name });
        const result = try std.ChildProcess.exec(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "tar", "-xf", file_path, "-C", snapshot_path, "--strip-components=1" },
        });
        try fs.cwd().deleteFile(file_path);
    }
};

pub const Package = struct {
    version: []const u8,
    aur_version: ?[]const u8 = null,
    requires_update: bool = false,
};
