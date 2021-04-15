const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

const aur = @import("aur.zig");
const color = @import("color.zig");
const curl = @import("curl.zig");
const Pkgbuild = @import("pkgbuild.zig").Pkgbuild;
const Version = @import("version.zig").Version;

pub const Package = struct {
    const Self = @This();

    base_name: ?[]const u8 = null,
    version: []const u8,
    aur_version: ?[]const u8 = null,
    requires_update: bool = false,

    // allocator.create does not respect default values so safeguard via an init() call
    pub fn init(allocator: *mem.Allocator, version: []const u8) !*Self {
        var new_pkg = try allocator.create(Self);
        new_pkg.base_name = null;
        new_pkg.version = version;
        new_pkg.aur_version = null;
        new_pkg.requires_update = false;
        return new_pkg;
    }

    pub fn deinit(self: *Self, allocator: *mem.Allocator) void {
        if (self.base_name != null) allocator.free(self.base_name.?);
        if (self.aur_version != null) allocator.free(self.aur_version.?);
        allocator.destroy(self);
    }
};

pub const Pacman = struct {
    const Self = @This();

    allocator: *mem.Allocator,
    pkgs: std.StringHashMap(*Package),
    aur_resp: aur.RPCRespV5,
    zur_path: []const u8,
    updates: usize = 0,
    stdin_has_input: bool = false,

    pub fn init(allocator: *mem.Allocator) !Self {
        const home = os.getenv("HOME") orelse return error.NoHomeEnvVarFound;
        const zur_dir = ".zur";

        return Self{
            .allocator = allocator,
            .pkgs = std.StringHashMap(*Package).init(allocator),
            .zur_path = try fs.path.join(allocator, &[_][]const u8{ home, zur_dir }),
            .aur_resp = undefined,
            .updates = 0,
            .stdin_has_input = false,
        };
    }

    pub fn deinit(self: *Self) void {
        var pkgs_iter = self.pkgs.iterator();
        while (pkgs_iter.next()) |pkg| {
            pkg.value.deinit(self.allocator);
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

            var new_pkg = try Package.init(self.allocator, version);
            // deinit happens at Pacman.deinit()

            try self.pkgs.putNoClobber(name, new_pkg);
        }
    }

    pub fn setInstallPackages(self: *Self, pkg_list: std.ArrayList([]const u8)) !void {
        if (self.pkgs.count() != 0) {
            return error.BadInitialPkgsState;
        }

        for (pkg_list.items) |pkg_name| {
            // This is the hack:
            // We're setting an impossible version to initialize the packages to install.
            var new_pkg = try Package.init(self.allocator, "0-0");
            // deinit happens at Pacman.deinit()

            try self.pkgs.putNoClobber(pkg_name, new_pkg);
        }
    }

    pub fn fetchRemoteAurVersions(self: *Self) !void {
        var remote_resp = try aur.queryAll(self.allocator, self.pkgs);
        if (remote_resp.resultcount == 0) {
            return error.ZeroResultsFromAurQuery;
        }
        for (remote_resp.results) |result| {
            var curr_pkg = self.pkgs.get(result.Name).?;
            curr_pkg.aur_version = result.Version;

            // Only store Package.base_name if the name doesn't match base name.
            // We use the null state to see if they defer.
            if (!mem.eql(u8, result.Name, result.PackageBase)) {
                curr_pkg.base_name = result.PackageBase;
            }
        }
    }

    // TODO: maybe use libalpm once this issue is fixed:
    // https://github.com/ziglang/zig/issues/1499
    pub fn compareVersions(self: *Self) !void {
        var pkgs_iter = self.pkgs.iterator();
        while (pkgs_iter.next()) |pkg| {
            const local_version = try Version.init(pkg.value.version);

            if (pkg.value.aur_version == null) {
                print("{s}warning:{s} {s}{s}{s} was orphaned or non-existant in AUR, skipping\n", .{
                    color.BoldForegroundYellow,
                    color.Reset,
                    color.Bold,
                    pkg.key,
                    color.Reset,
                });
                continue;
            }

            const remote_version = try Version.init(pkg.value.aur_version.?);
            if (local_version.olderThan(remote_version)) {
                pkg.value.requires_update = true;
                self.updates += 1;
            }
        }

        if (self.updates == 0) {
            return;
        }
        pkgs_iter = self.pkgs.iterator();
        print("{s}::{s} Packages to be updated:\n", .{ color.BoldForegroundBlue, color.Reset });
        while (pkgs_iter.next()) |pkg| {
            if (pkg.value.requires_update) {
                print(" {s}\n", .{pkg.key});
            }
        }
    }

    pub fn processOutOfDate(self: *Self) !void {
        if (self.updates == 0) {
            print("{s}::{s} {s}All AUR packages are up-to-date.{s}\n", .{
                color.BoldForegroundBlue,
                color.Reset,
                color.Bold,
                color.Reset,
            });
            return;
        }
        try fs.cwd().makePath(self.zur_path);

        var pkgs_iter = self.pkgs.iterator();
        while (pkgs_iter.next()) |pkg| {
            if (pkg.value.requires_update) {
                // The install hack is bleeding into here.
                if (!std.mem.eql(u8, pkg.value.version, "0-0")) {
                    print("{s}::{s} Updating {s}{s}{s}: {s}{s}{s} -> {s}{s}{s}\n", .{
                        color.BoldForegroundBlue,
                        color.Reset,
                        color.Bold,
                        pkg.key,
                        color.Reset,
                        color.ForegroundRed,
                        pkg.value.version,
                        color.Reset,
                        color.ForegroundGreen,
                        pkg.value.aur_version.?,
                        color.Reset,
                    });
                } else {
                    print("{s}::{s} Installing {s}{s}{s} {s}{s}{s}\n", .{
                        color.BoldForegroundBlue,
                        color.Reset,
                        color.Bold,
                        pkg.key,
                        color.Reset,
                        color.ForegroundGreen,
                        pkg.value.aur_version.?,
                        color.Reset,
                    });
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

        // TODO: There must be a more idiomatic way of doing this
        var url: [:0]const u8 = undefined;
        if (pkg.base_name) |base_name| {
            const name = try mem.join(self.allocator, ".", &[_][]const u8{ base_name, "tar.gz" });
            url = try mem.joinZ(self.allocator, "/", &[_][]const u8{ aur.Snapshot, name });
        } else {
            url = try mem.joinZ(self.allocator, "/", &[_][]const u8{ aur.Snapshot, file_name });
        }

        print(" downloading from: {s}{s}{s}\n", .{ color.Bold, url, color.Reset });
        const snapshot = try curl.get(self.allocator, url);
        defer snapshot.deinit();
        print(" downloaded to: {s}{s}{s}\n", .{ color.Bold, full_file_path, color.Reset });

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
        var old_files_maybe = try self.snapshotFiles(pkg_name, pkg.version);
        if (old_files_maybe == null) {
            // We have no older version in stored in the filesystem.
            // Fallback to just installing
            return self.bareInstall(pkg_name, pkg);
        }
        var old_files = old_files_maybe.?;
        defer old_files.deinit();

        var new_files_maybe = try self.snapshotFiles(pkg_name, pkg.aur_version.?);
        var new_files = new_files_maybe.?;
        defer new_files.deinit();

        var old_pkgbuild = Pkgbuild.init(self.allocator, old_files.get("PKGBUILD").?);
        defer old_pkgbuild.deinit();
        try old_pkgbuild.readLines();
        var new_pkgbuild = Pkgbuild.init(self.allocator, new_files.get("PKGBUILD").?);
        defer new_pkgbuild.deinit();
        try new_pkgbuild.readLines();

        try new_pkgbuild.comparePrev(old_pkgbuild);
        try new_pkgbuild.indentValues(2);
        var new_pkgbuild_iter = new_pkgbuild.relevant_fields.iterator();
        while (new_pkgbuild_iter.next()) |field| {
            if (field.value.updated) {
                print("{s}{s}{s} was updated {s}", .{
                    color.Bold,
                    field.key,
                    color.Reset,
                    field.value.value,
                });
            }
        }

        var at_least_one_diff = false;
        var new_iter = new_files.iterator();
        while (new_iter.next()) |file| {
            if (mem.endsWith(u8, file.key, ".install") or mem.endsWith(u8, file.key, ".sh")) {
                if (!std.mem.eql(u8, old_files.get(file.key).?, new_files.get(file.key).?)) {
                    at_least_one_diff = true;
                    print("{s}{s}{s} was updated:\n{s}\n", .{
                        color.Bold,
                        file.key,
                        color.Reset,
                        new_files.get(file.key).?,
                    });

                    print("\nContinue? [Y/n]: ", .{});
                    var stdin = std.io.getStdIn();
                    const input = try self.stdinReadByte();
                    if (input != 'y' and input != 'Y') {
                        return;
                    } else {
                        print("\n", .{});
                    }
                }
            }
        }
        if (!at_least_one_diff) {
            print("{s}::{s} No meaningful diff's found\n", .{ color.ForegroundBlue, color.Reset });
        }
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
        while (pkg_files_iter.next()) |pkg_file| {
            const format = "\n{s}::{s} File: {s}{s}{s} {s}===================={s}\n{s}";
            print(format, .{
                color.BoldForegroundBlue,
                color.Reset,
                color.Bold,
                pkg_file.key,
                color.Reset,
                color.BoldForegroundBlue,
                color.Reset,
                pkg_file.value,
            });
        }

        // TODO: stdin flushing is a non-zig problem opt to manually read and stuff
        print("Install? [Y/n]: ", .{});
        var stdin = std.io.getStdIn();
        const input = try self.stdinReadByte();
        if (input == 'y' or input == 'Y') {
            try self.install(pkg_name, pkg);
        } else {
            print("\n", .{});
        }
    }

    fn install(self: *Self, pkg_name: []const u8, pkg: *Package) !void {
        const pkg_dir = try std.mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, pkg.aur_version.? });
        const full_pkg_dir = try fs.path.join(self.allocator, &[_][]const u8{ self.zur_path, pkg_dir });
        try os.chdir(full_pkg_dir);

        const argv = &[_][]const u8{ "makepkg", "-sicC" };
        const makepkg_runner = try std.ChildProcess.init(argv, self.allocator);
        defer makepkg_runner.deinit();

        try self.stdinClearByte();
        makepkg_runner.stdin = std.io.getStdIn();
        makepkg_runner.stdout = std.io.getStdOut();
        makepkg_runner.stdin_behavior = std.ChildProcess.StdIo.Inherit;
        makepkg_runner.stdout_behavior = std.ChildProcess.StdIo.Inherit;

        // TODO: Ctrl+c from a [sudo] prompt causes some weird output behavior.
        // I probably need signal handling for this to properly work.
        const term_id = try makepkg_runner.spawnAndWait();
    }

    // TODO: We need to handle package-base: some AUR packages' snapshots are stored as the base, and not the actual package name
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
        print(" reading files in {s}{s}{s}\n", .{ color.Bold, path, color.Reset });

        var files_map = std.StringHashMap([]u8).init(self.allocator);
        var dir_iter = dir.iterate();
        while (try dir_iter.next()) |node| {
            if (std.mem.eql(u8, node.name, ".SRCINFO")) {
                continue;
            }
            if (mem.containsAtLeast(u8, node.name, 1, ".tar.")) {
                continue;
            }
            if (node.kind != fs.File.Kind.File) {
                continue;
            }

            // The arbitrary 4096 byte file size limit is _probably_ fine here.
            // No one is going to want to read a novel before installing.
            var file_contents = dir.readFileAlloc(self.allocator, node.name, 4096) catch |err| switch (err) {
                error.FileTooBig => {
                    print("  {s}-->{s} skipping diff for large file: {s}{s}{s}\n", .{
                        color.ForegroundBlue,
                        color.Reset,
                        color.Bold,
                        node.name,
                        color.Reset,
                    });
                    continue;
                },
                else => unreachable,
            };

            var buf = std.ArrayList(u8).init(self.allocator);
            var lines_iter = mem.split(file_contents, "\n");
            while (lines_iter.next()) |line| {
                try buf.appendSlice("  ");
                try buf.appendSlice(line);
                try buf.append('\n');
            }

            var copyName = try self.allocator.alloc(u8, node.name.len);
            std.mem.copy(u8, copyName, node.name);
            try files_map.putNoClobber(copyName, buf.toOwnedSlice());
        }
        return files_map;
    }

    fn stdinReadByte(self: *Self) !u8 {
        var stdin = std.io.getStdIn();
        const input = try stdin.reader().readByte();
        self.stdin_has_input = true;
        return input;
    }

    // We want to "eat" a character so that it doesn't get exposed to the child process.
    // There's likely a more correct way to handle this.
    fn stdinClearByte(self: *Self) !void {
        if (!self.stdin_has_input) {
            return;
        }
        var stdin = std.io.getStdIn();
        _ = try stdin.reader().readBytesNoEof(1);
        self.stdin_has_input = false;
    }
};

fn print(comptime format: []const u8, args: anytype) void {
    var stdout_writer = std.io.getStdOut().writer();
    std.fmt.format(stdout_writer, format, args) catch unreachable;
}
