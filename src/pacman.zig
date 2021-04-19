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

// TODO
// - Basic search functionality
// - Periodic cleanup of ~/.zur and ~/.zur/pkg
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
        print("{s}::{s} Packages to be installed or updated:\n", .{ color.BoldForegroundBlue, color.Reset });
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
                if (try self.localPackageExists(pkg.key, pkg.value.aur_version.?)) {
                    print("{s}warning:{s} Found existing up-to-date package: {s}{s}-{s}{s}, deferring to pacman -U...\n", .{
                        color.BoldForegroundYellow,
                        color.Reset,
                        color.Bold,
                        pkg.key,
                        pkg.value.aur_version.?,
                        color.Reset,
                    });
                    try self.installExistingPackage(pkg.key, pkg.value);
                    return;
                }

                // The install hack is bleeding into here.
                if (!mem.eql(u8, pkg.value.version, "0-0")) {
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
                try self.downloadAndExtractPackage(pkg.key, pkg.value);
                try self.compareUpdateAndInstall(pkg.key, pkg.value);
            }
        }
    }

    fn localPackageExists(self: *Self, pkg_name: []const u8, new_ver: []const u8) !bool {
        const full_pkg_name = try mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, new_ver, "x86_64.pkg.tar.zst" });
        const zur_pkg_dir = try fs.path.join(self.allocator, &[_][]const u8{ self.zur_path, "pkg" });

        var dir = try fs.openDirAbsolute(zur_pkg_dir, .{ .access_sub_paths = false, .iterate = true, .no_follow = true });
        var dir_iter = dir.iterate();
        while (try dir_iter.next()) |node| {
            if (mem.eql(u8, node.name, full_pkg_name)) {
                return true;
            }
        }
        return false;
    }

    fn downloadAndExtractPackage(self: *Self, pkg_name: []const u8, pkg: *Package) !void {
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

        // This is not perfect (not robust against manual changes), but it's sufficient for it's purpose (short-circuiting)
        var dir = fs.cwd().openDir(full_dir, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => unreachable,
        };
        if (dir != null) {
            dir.?.close();
            print(" skipping download, {s}{s}{s} already exists...\n", .{ color.Bold, full_dir, color.Reset });
            return;
        }

        print(" downloading from: {s}{s}{s}\n", .{ color.Bold, url, color.Reset });
        const snapshot = try curl.get(self.allocator, url);
        defer snapshot.deinit();
        print(" downloaded to: {s}{s}{s}\n", .{ color.Bold, full_file_path, color.Reset });

        try fs.cwd().makePath(full_dir);
        const snapshot_file = try fs.cwd().createFile(full_file_path, .{});
        defer snapshot_file.close();

        try snapshot_file.writeAll(snapshot.items);
        try self.extractPackage(full_dir, pkg_name);
        return;
    }

    // TODO: Maybe one day if there's and easy way to extract tar.gz archives in Zig (be it stdlib or 3rd party), we can replace this.
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
        var new_pkgbuild_iter = new_pkgbuild.fields.iterator();
        while (new_pkgbuild_iter.next()) |field| {
            if (field.value.updated) {
                print("{s}::{s} {s}{s}{s} was updated {s}", .{
                    color.BoldForegroundBlue,
                    color.Reset,
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
                if (!mem.eql(u8, old_files.get(file.key).?, new_files.get(file.key).?)) {
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
            if (mem.eql(u8, pkg_file.key, "PKGBUILD")) {
                var pkgbuild = Pkgbuild.init(self.allocator, pkg_file.value);
                defer pkgbuild.deinit();
                try pkgbuild.readLines();
                const format = "\n{s}::{s} File: {s}PKGBUILD{s} {s}===================={s}\n";
                print(format, .{
                    color.BoldForegroundBlue,
                    color.Reset,
                    color.Bold,
                    color.Reset,
                    color.BoldForegroundBlue,
                    color.Reset,
                });

                // TODO: Might be worth looking into an ordered Hash Map so this is a non-issue
                // Loop twice so that the PKGBUILD functions come after all the key=value
                try pkgbuild.indentValues(2);
                var fields_iter = pkgbuild.fields.iterator();
                while (fields_iter.next()) |field| {
                    if (!mem.containsAtLeast(u8, field.key, 1, "()")) continue;
                    print("  {s} {s}\n", .{ field.key, field.value.value });
                }
            } else {
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
        }

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
        const pkg_dir = try mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, pkg.aur_version.? });
        const full_pkg_dir = try fs.path.join(self.allocator, &[_][]const u8{ self.zur_path, pkg_dir });
        try os.chdir(full_pkg_dir);

        const argv = &[_][]const u8{ "makepkg", "-sicC" };
        try self.execCommand(argv);

        // TODO: Clean up older package after N updates?
        try self.moveBuiltPackages(pkg_name, pkg);
    }

    fn installExistingPackage(self: *Self, pkg_name: []const u8, pkg: *Package) !void {
        const pkg_dir = try mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, pkg.aur_version.? });
        const full_pkg_dir = try fs.path.join(self.allocator, &[_][]const u8{ self.zur_path, "pkg" });
        try os.chdir(full_pkg_dir);

        // TODO: Dynamically get the right arch
        const full_pkg_name = try mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, pkg.aur_version.?, "x86_64.pkg.tar.zst" });
        const argv = &[_][]const u8{ "sudo", "pacman", "-U", full_pkg_name };
        try self.execCommand(argv);
    }

    fn execCommand(self: *Self, argv: []const []const u8) !void {
        const runner = try std.ChildProcess.init(argv, self.allocator);
        defer runner.deinit();

        try self.stdinClearByte();
        runner.stdin = std.io.getStdIn();
        runner.stdout = std.io.getStdOut();
        runner.stdin_behavior = std.ChildProcess.StdIo.Inherit;
        runner.stdout_behavior = std.ChildProcess.StdIo.Inherit;

        // TODO: Ctrl+c from a [sudo] prompt causes some weird output behavior.
        // I probably need signal handling for this to properly work.
        // TODO: We also need some additional cleanup steps if it fails.
        _ = try runner.spawnAndWait();
    }

    fn moveBuiltPackages(self: *Self, pkg_name: []const u8, pkg: *Package) !void {
        const pkg_dir = try mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, pkg.aur_version.? });
        const full_pkg_dir = try fs.path.join(self.allocator, &[_][]const u8{ self.zur_path, pkg_dir });

        try os.chdir(self.zur_path);
        const archive_dir = try fs.path.join(self.allocator, &[_][]const u8{ self.zur_path, "pkg" });
        try fs.cwd().makePath(archive_dir);

        var dir = fs.openDirAbsolute(full_pkg_dir, .{ .access_sub_paths = false, .iterate = true, .no_follow = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => unreachable,
        };
        var dir_iter = dir.iterate();
        while (try dir_iter.next()) |node| {
            if (!mem.containsAtLeast(u8, node.name, 1, ".pkg.tar.zst")) {
                continue;
            }
            const full_old_name = try fs.path.join(self.allocator, &[_][]const u8{ full_pkg_dir, node.name });
            const full_new_name = try fs.path.join(self.allocator, &[_][]const u8{ archive_dir, node.name });
            try fs.cwd().rename(full_old_name, full_new_name);
        }
    }

    fn snapshotFiles(self: *Self, pkg_name: []const u8, pkg_version: []const u8) !?std.StringHashMap([]u8) {
        const dir_name = try mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, pkg_version });
        const path = try fs.path.join(self.allocator, &[_][]const u8{ self.zur_path, dir_name });

        var dir = fs.openDirAbsolute(path, .{ .access_sub_paths = false, .iterate = true, .no_follow = true }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => unreachable,
        };
        defer dir.close();
        print(" reading files in {s}{s}{s}\n", .{ color.Bold, path, color.Reset });

        var files_map = std.StringHashMap([]u8).init(self.allocator);
        var dir_iter = dir.iterate();
        while (try dir_iter.next()) |node| {
            if (mem.eql(u8, node.name, ".SRCINFO")) {
                continue;
            }
            if (mem.eql(u8, node.name, ".gitignore")) {
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

            // PKGBUILD's have their own indent logic
            if (!mem.eql(u8, node.name, "PKGBUILD")) {
                var buf = std.ArrayList(u8).init(self.allocator);
                var lines_iter = mem.split(file_contents, "\n");
                while (lines_iter.next()) |line| {
                    try buf.appendSlice("  ");
                    try buf.appendSlice(line);
                    try buf.append('\n');
                }
                var copyName = try self.allocator.alloc(u8, node.name.len);
                mem.copy(u8, copyName, node.name);
                try files_map.putNoClobber(copyName, buf.toOwnedSlice());
            } else {
                var copyName = try self.allocator.alloc(u8, node.name.len);
                mem.copy(u8, copyName, node.name);
                try files_map.putNoClobber(copyName, file_contents);
            }
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
