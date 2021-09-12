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
};

// TODO: maybe handle <pkg>-git packages like yay
pub const Pacman = struct {
    const Self = @This();

    allocator: *mem.Allocator,
    pkgs: std.StringHashMap(*Package),
    aur_resp: ?aur.RPCRespV5,
    pacman_output: ?[]u8,
    zur_path: []const u8,
    zur_pkg_dir: []const u8,
    updates: usize = 0,
    stdin_has_input: bool = false,

    pub fn init(allocator: *mem.Allocator) !Self {
        const home = os.getenv("HOME") orelse return error.NoHomeEnvVarFound;
        const zur_dir = ".zur";

        const zur_path = try fs.path.join(allocator, &[_][]const u8{ home, zur_dir });
        const pkg_dir = try fs.path.join(allocator, &[_][]const u8{ zur_path, ".pkg" });
        try fs.cwd().makePath(pkg_dir);

        return Self{
            .allocator = allocator,
            .pkgs = std.StringHashMap(*Package).init(allocator),
            .zur_path = zur_path,
            .zur_pkg_dir = pkg_dir,
            .aur_resp = null,
            .pacman_output = null,
            .updates = 0,
            .stdin_has_input = false,
        };
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
        self.pacman_output = result.stdout;

        var lines = mem.split(u8, result.stdout, "\n");
        while (lines.next()) |line| {
            // ignore empty lines if they exist
            if (line.len <= 1) {
                continue;
            }

            var line_iter = mem.split(u8, line, " ");
            const name = line_iter.next() orelse return error.UnknownPacmanQmOutputFormat;
            const version = line_iter.next() orelse return error.UnknownPacmanQmOutputFormat;

            var new_pkg = try Package.init(self.allocator, version);

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

            try self.pkgs.putNoClobber(pkg_name, new_pkg);
        }
    }

    pub fn fetchRemoteAurVersions(self: *Self) !void {
        self.aur_resp = try aur.queryAll(self.allocator, self.pkgs);
        if (self.aur_resp.?.resultcount == 0) {
            return error.ZeroResultsFromAurQuery;
        }
        for (self.aur_resp.?.results) |result| {
            var curr_pkg = self.pkgs.get(result.Name).?;
            curr_pkg.aur_version = result.Version;

            // Only store Package.base_name if the name doesn't match base name.
            // We use the null state to see if they defer.
            // TODO: Actually, PKGBUILDs with multiple pkgnames' install multiple packages;
            // zur currently duplicates these package installs because of this.
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
            const local_version = try Version.init(pkg.value_ptr.*.version);

            if (pkg.value_ptr.*.aur_version == null) {
                print("{s}warning:{s} {s}{s}{s} was orphaned or non-existant in AUR, skipping\n", .{
                    color.BoldForegroundYellow,
                    color.Reset,
                    color.Bold,
                    pkg.key_ptr.*,
                    color.Reset,
                });
                continue;
            }

            const remote_version = try Version.init(pkg.value_ptr.*.aur_version.?);
            if (local_version.olderThan(remote_version)) {
                pkg.value_ptr.*.requires_update = true;
                self.updates += 1;
            }
        }

        if (self.updates == 0) {
            return;
        }
        pkgs_iter = self.pkgs.iterator();
        print("{s}::{s} Packages to be installed or updated:\n", .{ color.BoldForegroundBlue, color.Reset });
        while (pkgs_iter.next()) |pkg| {
            if (pkg.value_ptr.*.requires_update) {
                print(" {s}\n", .{pkg.key_ptr.*});
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
            if (pkg.value_ptr.*.requires_update) {
                if (try self.localPackageExists(pkg.key_ptr.*, pkg.value_ptr.*.aur_version.?)) {
                    print("{s}warning:{s} Found existing up-to-date package: {s}{s}-{s}{s}, deferring to pacman -U...\n", .{
                        color.BoldForegroundYellow,
                        color.Reset,
                        color.Bold,
                        pkg.key_ptr.*,
                        pkg.value_ptr.*.aur_version.?,
                        color.Reset,
                    });
                    try self.installExistingPackage(pkg.key_ptr.*, pkg.value_ptr.*);
                    return;
                }

                // The install hack is bleeding into here.
                if (!mem.eql(u8, pkg.value_ptr.*.version, "0-0")) {
                    print("{s}::{s} Updating {s}{s}{s}: {s}{s}{s} -> {s}{s}{s}\n", .{
                        color.BoldForegroundBlue,
                        color.Reset,
                        color.Bold,
                        pkg.key_ptr.*,
                        color.Reset,
                        color.ForegroundRed,
                        pkg.value_ptr.*.version,
                        color.Reset,
                        color.ForegroundGreen,
                        pkg.value_ptr.*.aur_version.?,
                        color.Reset,
                    });
                } else {
                    print("{s}::{s} Installing {s}{s}{s} {s}{s}{s}\n", .{
                        color.BoldForegroundBlue,
                        color.Reset,
                        color.Bold,
                        pkg.key_ptr.*,
                        color.Reset,
                        color.ForegroundGreen,
                        pkg.value_ptr.*.aur_version.?,
                        color.Reset,
                    });
                }
                try self.downloadAndExtractPackage(pkg.key_ptr.*, pkg.value_ptr.*);
                try self.compareUpdateAndInstall(pkg.key_ptr.*, pkg.value_ptr.*);
            }
        }
    }

    fn localPackageExists(self: *Self, pkg_name: []const u8, new_ver: []const u8) !bool {
        // TODO: Handle "any" arch package names.
        const full_pkg_name = try mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, new_ver, "x86_64.pkg.tar.zst" });

        // TODO: maybe we want to be like yay and also find some VCS info to do this correctly.
        // For -git packages, we need to force zur to always install because we don't know if there's been an update or not.
        var dir = try fs.openDirAbsolute(self.zur_pkg_dir, .{ .access_sub_paths = false, .iterate = true, .no_follow = true });
        var dir_iter = dir.iterate();
        while (try dir_iter.next()) |node| {
            if (mem.eql(u8, node.name, full_pkg_name) and !mem.containsAtLeast(u8, node.name, 1, "-git")) {
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
        _ = try std.ChildProcess.exec(.{
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

        var new_files_maybe = try self.snapshotFiles(pkg_name, pkg.aur_version.?);
        var new_files = new_files_maybe.?;

        var old_pkgbuild = Pkgbuild.init(self.allocator, old_files.get("PKGBUILD").?);
        try old_pkgbuild.readLines();
        var new_pkgbuild = Pkgbuild.init(self.allocator, new_files.get("PKGBUILD").?);
        try new_pkgbuild.readLines();

        var at_least_one_diff = false;
        try new_pkgbuild.comparePrev(old_pkgbuild);
        try new_pkgbuild.indentValues(2);
        var new_pkgbuild_iter = new_pkgbuild.fields.iterator();
        while (new_pkgbuild_iter.next()) |field| {
            if (field.value_ptr.*.updated) {
                at_least_one_diff = true;
                print("{s}::{s} {s}{s}{s} was updated: {s}\n", .{
                    color.BoldForegroundBlue,
                    color.Reset,
                    color.Bold,
                    field.key_ptr.*,
                    color.Reset,
                    field.value_ptr.*.value,
                });
            }
        }

        var new_iter = new_files.iterator();
        while (new_iter.next()) |file| {
            if (mem.endsWith(u8, file.key_ptr.*, ".install") or mem.endsWith(u8, file.key_ptr.*, ".sh")) {
                const old_content = old_files.get(file.key_ptr.*).?;
                const new_content = new_files.get(file.key_ptr.*).?;
                if (!mem.eql(u8, old_content, new_content)) {
                    at_least_one_diff = true;

                    // TODO: would be cool to show a real diff here
                    print("{s}::{s} {s}{s}{s} was updated:\n{s}\n", .{
                        color.BoldForegroundBlue,
                        color.Reset,
                        color.Bold,
                        file.key_ptr.*,
                        color.Reset,
                        // new_files.get(file.key).?,
                        self.printDiff(old_content, new_content),
                    });
                }
            }
        }
        if (at_least_one_diff) {
            print("\nContinue? [Y/n]: ", .{});
            const input = try self.stdinReadByte();
            if (input != 'y' and input != 'Y') {
                return;
            } else {
                try self.stdinClearByte();
                print("\n", .{});
            }
        } else {
            print("{s}::{s} No meaningful diff's found\n", .{ color.ForegroundBlue, color.Reset });
        }
        try self.install(pkg_name, pkg);
    }

    fn printDiff(self: *Self, old: []const u8, new: []const u8) !void {
        var old_stream = std.io.fixedBufferStream(old).reader();
        var new_stream = std.io.fixedBufferStream(new).reader();

        while (true) {
            const old_line_maybe = try old_stream.readUntilDelimiterOrEofAlloc(self.allocator, '\n', 4096);
            const old_line = if (old_line_maybe == null) break else old_line_maybe.?;
            if (old_line.len == 0) break;

            const new_line_maybe = try new_stream.readUntilDelimiterOrEofAlloc(self.allocator, '\n', 4096);
            const new_line = if (new_line_maybe == null) break else new_line_maybe.?;
            if (new_line.len == 0) break;
            // if (!mem.eql(u8, old_line, new_line)) {
            std.debug.print("line: {s}              {s}\n", .{ old_line, new_line });
            // }
        }
    }

    // TODO: handle recursively installing dependencies from AUR
    // 0. Parse the dep list from .SRCINFO
    // 1. We need a strategy to split official/AUR deps
    // 2. Install official deps
    // 3. Install AUR deps
    // 4. Then install the package
    fn bareInstall(self: *Self, pkg_name: []const u8, pkg: *Package) !void {
        // TODO: Rethink the optional here.
        var pkg_files = try self.snapshotFiles(pkg_name, pkg.aur_version.?);
        var pkg_files_iter = pkg_files.?.iterator();
        while (pkg_files_iter.next()) |pkg_file| {
            if (mem.eql(u8, pkg_file.key_ptr.*, "PKGBUILD")) {
                var pkgbuild = Pkgbuild.init(self.allocator, pkg_file.value_ptr.*);
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

                try pkgbuild.indentValues(2);
                var fields_iter = pkgbuild.fields.iterator();
                while (fields_iter.next()) |field| {
                    if (!mem.containsAtLeast(u8, field.key_ptr.*, 1, "()")) continue;
                    print("  {s} {s}\n", .{ field.key_ptr.*, field.value_ptr.*.value });
                }
            } else {
                const format = "\n{s}::{s} File: {s}{s}{s} {s}===================={s}\n{s}";
                print(format, .{
                    color.BoldForegroundBlue,
                    color.Reset,
                    color.Bold,
                    pkg_file.key_ptr.*,
                    color.Reset,
                    color.BoldForegroundBlue,
                    color.Reset,
                    pkg_file.value_ptr.*,
                });
            }
        }

        print("Install? [Y/n]: ", .{});
        const input = try self.stdinReadByte();
        if (input == 'y' or input == 'Y') {
            try self.install(pkg_name, pkg);
        } else {
            print("\n", .{});
            try self.stdinClearByte();
        }
    }

    fn install(self: *Self, pkg_name: []const u8, pkg: *Package) !void {
        const pkg_dir = try mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, pkg.aur_version.? });
        const full_pkg_dir = try fs.path.join(self.allocator, &[_][]const u8{ self.zur_path, pkg_dir });
        try os.chdir(full_pkg_dir);

        const argv = &[_][]const u8{ "makepkg", "-sicC" };
        try self.execCommand(argv);

        try self.removeStaleArtifacts(pkg_name, self.zur_pkg_dir);
        try self.moveBuiltPackages(pkg_name, pkg);
    }

    fn installExistingPackage(self: *Self, pkg_name: []const u8, pkg: *Package) !void {
        try os.chdir(self.zur_pkg_dir);

        // TODO: Dynamically get the right arch
        const full_pkg_name = try mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, pkg.aur_version.?, "x86_64.pkg.tar.zst" });
        const argv = &[_][]const u8{ "sudo", "pacman", "-U", full_pkg_name };
        try self.execCommand(argv);
    }

    fn execCommand(self: *Self, argv: []const []const u8) !void {
        const runner = try std.ChildProcess.init(argv, self.allocator);

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

        var dir = fs.openDirAbsolute(full_pkg_dir, .{ .access_sub_paths = false, .iterate = true, .no_follow = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => unreachable,
        };
        defer dir.close();

        var dir_iter = dir.iterate();
        while (try dir_iter.next()) |node| {
            if (!mem.containsAtLeast(u8, node.name, 1, ".pkg.tar.zst")) {
                continue;
            }
            const full_old_name = try fs.path.join(self.allocator, &[_][]const u8{ full_pkg_dir, node.name });
            const full_new_name = try fs.path.join(self.allocator, &[_][]const u8{ self.zur_pkg_dir, node.name });
            try fs.cwd().rename(full_old_name, full_new_name);
        }

        try self.removeStaleArtifacts(pkg_name, self.zur_path);
    }

    fn removeStaleArtifacts(self: *Self, pkg_name: []const u8, dir_path: []const u8) !void {
        var dir = fs.openDirAbsolute(dir_path, .{ .access_sub_paths = false, .iterate = true, .no_follow = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => unreachable,
        };
        defer dir.close();

        // TODO: Implement better method to sorting these files by mtime.
        var list = std.ArrayList(i128).init(self.allocator);
        var map = std.AutoHashMap(i128, []const u8).init(self.allocator);
        var dir_iter = dir.iterate();
        while (try dir_iter.next()) |node| {
            if (!mem.containsAtLeast(u8, node.name, 1, pkg_name)) {
                continue;
            }
            const path = try fs.path.join(self.allocator, &[_][]const u8{ dir_path, node.name });
            var f = try fs.openFileAbsolute(path, .{});
            defer f.close();
            const stat = try f.stat();
            try map.putNoClobber(stat.mtime, path);
            try list.append(stat.mtime);
        }

        // Keep the last 3 installed versions of the package.
        if (list.items.len > 3) {
            const asc_i128 = comptime std.sort.asc(i128);
            std.sort.sort(i128, list.items, {}, asc_i128);

            const marked_for_removal = list.items[0 .. list.items.len - 3];
            for (marked_for_removal) |mtime| {
                const file_name = map.get(mtime).?;
                try fs.deleteTreeAbsolute(file_name);
                print("  {s}->{s} deleting stale file or dir: {s}\n", .{
                    color.ForegroundBlue,
                    color.Reset,
                    file_name,
                });
            }
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

            // TODO: The arbitrary 4096 byte file size limit is _probably_ fine here.
            // No one is going to want to read a novel before installing.
            var file_contents = dir.readFileAlloc(self.allocator, node.name, 4096) catch |err| switch (err) {
                error.FileTooBig => {
                    print("  {s}->{s} skipping diff for large file: {s}{s}{s}\n", .{
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
                var lines_iter = mem.split(u8, file_contents, "\n");
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
    // TODO: There's likely a more correct way to handle this.
    fn stdinClearByte(self: *Self) !void {
        if (!self.stdin_has_input) {
            return;
        }
        var stdin = std.io.getStdIn();
        _ = try stdin.reader().readBytesNoEof(1);
        self.stdin_has_input = false;
    }
};

pub fn search(allocator: *std.mem.Allocator, pkg: []const u8) !void {
    var pacman = try Pacman.init(allocator);
    try pacman.fetchLocalPackages();

    const installed = color.BoldForegroundCyan ++ "[Installed]" ++ color.Reset;
    const resp = try aur.search(allocator, pkg);
    for (resp.results) |result| {
        const installed_text = if (pacman.pkgs.get(result.Name) == null) "" else installed;
        print("{s}aur/{s}{s}{s}{s} {s}{s}{s} {s} ({d})\n    {s}\n", .{
            color.BoldForegroundMagenta,
            color.Reset,
            color.Bold,
            result.Name,
            color.Reset,
            color.BoldForegroundGreen,
            result.Version,
            color.Reset,
            installed_text,
            result.Popularity,
            result.Description,
        });
    }
}

fn print(comptime format: []const u8, args: anytype) void {
    var stdout_writer = std.io.getStdOut().writer();
    std.fmt.format(stdout_writer, format, args) catch unreachable;
}
