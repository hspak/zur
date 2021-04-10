const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

const aur = @import("aur.zig");
const curl = @import("curl.zig");
const Pkgbuild = @import("pkgbuild.zig").Pkgbuild;
const Version = @import("version.zig").Version;

pub const Package = struct {
    version: []const u8,
    aur_version: ?[]const u8 = null,
    requires_update: bool = false,
};

pub const Pacman = struct {
    const Self = @This();

    allocator: *mem.Allocator,
    pkgs: std.StringHashMap(*Package),
    zur_path: []const u8,
    updates: usize = 0,

    pub fn init(allocator: *mem.Allocator) !Self {
        const home = os.getenv("HOME") orelse return error.NoHomeEnvVarFound;
        const zur_dir = ".zur";

        return Self{
            .allocator = allocator,
            .pkgs = std.StringHashMap(*Package).init(allocator),
            .zur_path = try fs.path.join(allocator, &[_][]const u8{ home, zur_dir }),
        };
    }

    pub fn deinit(self: *Self) void {
        var pkgs_iter = self.pkgs.iterator();
        while (pkgs_iter.next()) |pkg| {
            self.allocator.destroy(pkg.value);
        }
        self.pkgs.deinit();
    }

    // TODO: use libalpm once this issue is fixed:
    // https://github.com/ziglang/zig/issues/1499
    pub fn fetchLocalPackages(self: *Self) !void {
        if (self.pkgs.count() != 0) {
            return error.BadInitialPkgsState;
        }

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

    pub fn setInstallPackages(self: *Self, pkg_list: std.ArrayList([]const u8)) !void {
        if (self.pkgs.count() != 0) {
            return error.BadInitialPkgsState;
        }

        for (pkg_list.items) |pkg_name| {
            std.log.info("Installing {s}", .{pkg_name});

            // This is the hack:
            // We're setting an impossible version to initialize the packages to install.
            var new_pkg = try self.allocator.create(Package);
            new_pkg.version = "0-0";
            try self.pkgs.putNoClobber(pkg_name, new_pkg);
        }
    }

    pub fn fetchRemoteAurVersions(self: *Self) !void {
        var remote_resp = try aur.queryAll(self.allocator, self);
        if (remote_resp.resultcount == 0) {
            return error.ZeroResultsFromAurQuery;
        }
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
            const local_version = try Version.init(pkg.value.version);
            const remote_version = try Version.init(pkg.value.aur_version.?);
            if (local_version.olderThan(remote_version)) {
                pkg.value.requires_update = true;
                self.updates += 1;
            }
        }
    }

    pub fn processOutOfDate(self: *Self) !void {
        if (self.updates == 0) {
            std.log.info("All AUR packages are up-to-date.", .{});
            return;
        }
        try fs.cwd().makePath(self.zur_path);

        var pkgs_iter = self.pkgs.iterator();
        while (pkgs_iter.next()) |pkg| {
            if (pkg.value.requires_update) {
                // The install hack is bleeding into here.
                if (!std.mem.eql(u8, pkg.value.version, "0-0")) {
                    std.log.info("Updating {s}: {s} -> {s}", .{ pkg.key, pkg.value.version, pkg.value.aur_version.? });
                }
                const snapshot_path = try self.downloadPackage(pkg.key, pkg.value);
                try self.extractPackage(snapshot_path, pkg.key);
                try self.compareUpdateAndInstall(pkg.key, pkg.value);
            }
        }
    }

    fn downloadPackage(self: *Self, pkg_name: []const u8, pkg: *Package) ![]const u8 {
        const file_name = try mem.join(self.allocator, ".", &[_][]const u8{ pkg_name, "tar.gz" });
        const dir_name = try mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, pkg.aur_version.? });

        const full_dir = try fs.path.join(self.allocator, &[_][]const u8{ self.zur_path, dir_name });
        const full_file_path = try fs.path.join(self.allocator, &[_][]const u8{ full_dir, file_name });

        const url = try mem.joinZ(self.allocator, "/", &[_][]const u8{ aur.Snapshot, file_name });
        std.log.info("Downloading from: {s}", .{url});
        const snapshot = try curl.get(self.allocator, url);
        defer snapshot.deinit();
        std.log.info("Downloaded to: {s}", .{full_file_path});

        try fs.cwd().makePath(full_dir);
        const snapshot_file = try fs.cwd().createFile(full_file_path, .{});
        defer snapshot_file.close();

        try snapshot_file.writeAll(snapshot.items);
        return full_dir;
    }

    fn extractPackage(self: *Self, snapshot_path: []const u8, pkg_name: []const u8) !void {
        const file_name = try mem.join(self.allocator, ".", &[_][]const u8{ pkg_name, "tar.gz" });
        const file_path = try fs.path.join(self.allocator, &[_][]const u8{ snapshot_path, file_name });
        const result = try std.ChildProcess.exec(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "tar", "-xf", file_path, "-C", snapshot_path, "--strip-components=1" },
        });
        try fs.cwd().deleteFile(file_path);
    }

    fn compareUpdateAndInstall(self: *Self, pkg_name: []const u8, pkg: *Package) !void {
        var old_files = try self.snapshotFiles(pkg_name, pkg.version);
        if (old_files == null) {
            // We have no older version in stored in the filesystem.
            // Fallback to just installing
            return self.bareInstall(pkg_name, pkg);
        }
        defer old_files.?.deinit();
        var new_files = try self.snapshotFiles(pkg_name, pkg.aur_version.?);
        defer new_files.?.deinit();

        var old_pkgbuild = Pkgbuild.init(self.allocator, old_files.?.get("PKGBUILD").?);
        defer old_pkgbuild.deinit();
        try old_pkgbuild.readLines();
        var new_pkgbuild = Pkgbuild.init(self.allocator, new_files.?.get("PKGBUILD").?);
        defer new_pkgbuild.deinit();
        try new_pkgbuild.readLines();

        try new_pkgbuild.comparePrev(old_pkgbuild);
        new_pkgbuild.printUpdated();
        // TODO *.install: diff the entire file
        // TODO *.sh: diff the entire file
        // TODO manual input

        try self.install(pkg_name, pkg);
    }

    // TODO: handle recursively installing dependencies from AUR
    // 0. Parse the dep list from .SRCINFO
    // 1. We need a strategy to split official/AUR deps
    // 2. Install official deps
    // 3. Install AUR deps
    // 4. Then install the package
    fn bareInstall(self: *Self, pkg_name: []const u8, pkg: *Package) !void {
        var pkg_files = try self.snapshotFiles(pkg_name, pkg.aur_version.?);
        var pkg_files_iter = pkg_files.?.iterator();
        var stdout_writer = &std.io.getStdOut().writer();
        while (pkg_files_iter.next()) |pkg_file| {
            const format = "==== File: {s} =================================\n{s}";
            const output = try std.fmt.allocPrint(self.allocator, format, .{ pkg_file.key, pkg_file.value });
            _ = try stdout_writer.write(output);
        }

        _ = try stdout_writer.write("Install? [y/n]: ");
        const stdin = std.io.getStdIn();
        const input = try stdin.reader().readByte();
        if (input == 'y') {
            try self.install(pkg_name, pkg);
        } else {
            _ = try stdout_writer.write("Install declined. Goodbye!\n");
        }
    }

    fn install(self: *Self, pkg_name: []const u8, pkg: *Package) !void {
        const pkg_dir = try std.mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, pkg.aur_version.? });
        const full_pkg_dir = try fs.path.join(self.allocator, &[_][]const u8{ self.zur_path, pkg_dir });
        try os.chdir(full_pkg_dir);

        const argv = &[_][]const u8{ "makepkg", "-sicC" };
        const makepkg_runner = try std.ChildProcess.init(argv, self.allocator);
        defer makepkg_runner.deinit();

        // TODO: when `makepkg` invokes `sudo` it seems to take the confirmation character from earlier.
        // Find out how to prevent that.
        const stdin = std.io.getStdIn();
        makepkg_runner.stdin = stdin;
        makepkg_runner.stdout = std.io.getStdOut();
        makepkg_runner.stdin_behavior = std.ChildProcess.StdIo.Inherit;
        makepkg_runner.stdout_behavior = std.ChildProcess.StdIo.Inherit;
        try makepkg_runner.spawn();
        _ = try makepkg_runner.wait();
    }

    fn snapshotFiles(self: *Self, pkg_name: []const u8, pkg_version: []const u8) !?std.StringHashMap([]u8) {
        const dir_name = try mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, pkg_version });
        const path = try fs.path.join(self.allocator, &[_][]const u8{ self.zur_path, dir_name });
        var dir = fs.openDirAbsolute(path, .{ .access_sub_paths = false, .iterate = true, .no_follow = true }) catch |err| switch (err) {
            error.FileNotFound => {
                return null;
            },
            else => unreachable,
        };
        defer dir.close();

        var files_map = std.StringHashMap([]u8).init(self.allocator);
        var dir_iter = dir.iterate();
        while (try dir_iter.next()) |node| {
            if (std.mem.eql(u8, node.name, ".SRCINFO")) {
                continue;
            }
            if (node.kind != fs.File.Kind.File) {
                continue;
            }

            var file_contents = dir.readFileAlloc(self.allocator, node.name, 4096) catch |err| switch (err) {
                error.FileTooBig => {
                    std.log.warn("skipping diff setup for large file: '{s}'", .{node.name});
                    continue;
                },
                else => unreachable,
            };

            var copyName = try self.allocator.alloc(u8, node.name.len);
            std.mem.copy(u8, copyName, node.name);
            try files_map.putNoClobber(copyName, file_contents);
        }
        return files_map;
    }
};
