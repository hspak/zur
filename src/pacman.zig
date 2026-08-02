const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const Allocator = mem.Allocator;
const Dir = Io.Dir;
const File = Io.File;

const alpm = @import("alpm.zig");
const aur = @import("aur.zig");
const color = @import("color.zig");
const Pkgbuild = @import("pkgbuild.zig").Pkgbuild;
const Request = @import("req.zig").Request;

pub const Package = struct {
    base_name: ?[]const u8 = null,
    version: []const u8,
    aur_version: ?[]const u8 = null,
    requires_update: bool = false,

    // allocator.create does not respect default values so safeguard via an init() call
    pub fn init(allocator: Allocator, version: []const u8) !*Package {
        const new_pkg = try allocator.create(Package);
        new_pkg.* = .{
            .base_name = null,
            .version = version,
            .aur_version = null,
            .requires_update = false,
        };
        return new_pkg;
    }
};

// TODO: maybe handle <pkg>-git packages like yay

/// Files larger than this are skipped when diffing a package snapshot. A
/// .install/.sh file that large is unusual, and diffing it would flood the
/// terminal, so a fixed limit keeps output sane.
const max_snapshot_diff_bytes: usize = 4096;

pub const Pacman = struct {
    allocator: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    pkgs: std.StringHashMap(*Package),
    aur_resp: ?aur.RPCRespV5,
    pacman_output: ?[]u8,
    zur_path: []const u8,
    zur_pkg_dir: []const u8,
    updates: usize = 0,
    stdin_has_input: bool = false,

    stdout_buffer: [4096]u8 = undefined,
    stdout_writer: ?File.Writer = null,
    stdin_buffer: [4096]u8 = undefined,
    stdin_reader: ?File.Reader = null,

    pub fn init(allocator: Allocator, io: Io, environ_map: *const std.process.Environ.Map) !Pacman {
        const home = environ_map.get("HOME") orelse return error.NoHomeEnvVarFound;
        const zur_dir = ".zur";

        const zur_path = try Dir.path.join(allocator, &[_][]const u8{ home, zur_dir });
        const pkg_dir = try Dir.path.join(allocator, &[_][]const u8{ zur_path, ".pkg" });
        try Dir.cwd().createDirPath(io, pkg_dir);

        return .{
            .allocator = allocator,
            .io = io,
            .environ_map = environ_map,
            .pkgs = std.StringHashMap(*Package).init(allocator),
            .zur_path = zur_path,
            .zur_pkg_dir = pkg_dir,
            .aur_resp = null,
            .pacman_output = null,
            .updates = 0,
            .stdin_has_input = false,
        };
    }

    pub fn deinit(self: *Pacman) void {
        self.flushStdout();
        if (self.pacman_output) |out| self.allocator.free(out);
        // pkg keys are borrowed slices (into pacman_output or argv), so only
        // the Package structs themselves are owned here.
        var it = self.pkgs.iterator();
        while (it.next()) |e| {
            self.allocator.destroy(e.value_ptr.*);
        }
        self.pkgs.deinit();
    }

    fn stdout(self: *Pacman) *Io.Writer {
        if (self.stdout_writer == null) {
            self.stdout_writer = File.stdout().writer(self.io, &self.stdout_buffer);
        }
        return &self.stdout_writer.?.interface;
    }

    fn stdin(self: *Pacman) *File.Reader {
        if (self.stdin_reader == null) {
            self.stdin_reader = File.stdin().reader(self.io, &self.stdin_buffer);
        }
        return &self.stdin_reader.?;
    }

    fn print(self: *Pacman, comptime format: []const u8, args: anytype) !void {
        const w = self.stdout();
        try w.print(format, args);
    }

    /// Flush buffered stdout at the points where visibility/ordering matters:
    /// before interactive prompts, before spawning a child that inherits
    /// stdout, and on teardown. This lets `print` batch output instead of
    /// doing a write syscall per line.
    fn flushStdout(self: *Pacman) void {
        const w = self.stdout();
        w.flush() catch {};
    }

    // TODO: use libalpm once this issue is fixed:
    // https://github.com/ziglang/zig/issues/1499
    pub fn fetchLocalPackages(self: *Pacman) !void {
        if (self.pkgs.count() != 0) {
            return error.BadInitialPkgsState;
        }

        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &[_][]const u8{ "pacman", "-Qm" },
        });
        defer self.allocator.free(result.stderr);
        self.pacman_output = result.stdout;

        var lines = mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            // ignore empty lines if they exist
            if (line.len <= 1) {
                continue;
            }

            var line_iter = mem.splitScalar(u8, line, ' ');
            const name = line_iter.next() orelse return error.UnknownPacmanQmOutputFormat;
            const version = line_iter.next() orelse return error.UnknownPacmanQmOutputFormat;

            const new_pkg = try Package.init(self.allocator, version);

            try self.pkgs.putNoClobber(name, new_pkg);
        }
    }

    pub fn setInstallPackages(self: *Pacman, pkg_list: std.ArrayList([]const u8)) !void {
        if (self.pkgs.count() != 0) {
            return error.BadInitialPkgsState;
        }

        for (pkg_list.items) |pkg_name| {
            // This is the hack:
            // We're setting an impossible version to initialize the packages to install.
            const new_pkg = try Package.init(self.allocator, "0");

            try self.pkgs.putNoClobber(pkg_name, new_pkg);
        }
    }

    pub fn fetchRemoteAurVersions(self: *Pacman) !void {
        self.aur_resp = try aur.queryAll(self.allocator, self.io, self.pkgs);
        if (self.aur_resp.?.resultcount == 0) {
            return error.ZeroResultsFromAurQuery;
        }
        for (self.aur_resp.?.results) |result| {
            const curr_pkg = self.pkgs.get(result.Name).?;
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

    pub fn compareVersions(self: *Pacman) !void {
        var pkgs_iter = self.pkgs.iterator();
        while (pkgs_iter.next()) |pkg| {
            const local_version = pkg.value_ptr.*.version;

            if (pkg.value_ptr.*.aur_version == null) {
                try self.print("{s}warning:{s} {s}{s}{s} was orphaned or non-existant in AUR, skipping\n", .{
                    color.BoldForegroundYellow,
                    color.Reset,
                    color.Bold,
                    pkg.key_ptr.*,
                    color.Reset,
                });
                continue;
            }

            const remote_version = pkg.value_ptr.*.aur_version.?;
            const git_package_stale = blk: {
                const is_git_package = mem.endsWith(u8, pkg.key_ptr.*, "-git");
                if (!is_git_package) {
                    break :blk false;
                }
                break :blk mem.eql(u8, remote_version, local_version);
            };
            if (git_package_stale or mem.eql(u8, local_version, "0") or try alpm.is_newer_than(self.allocator, remote_version, local_version)) {
                pkg.value_ptr.*.requires_update = true;
                self.updates += 1;
            }
        }

        if (self.updates == 0) {
            return;
        }
        pkgs_iter = self.pkgs.iterator();
        try self.print("{s}::{s} Packages to be installed or updated:\n", .{ color.BoldForegroundBlue, color.Reset });
        while (pkgs_iter.next()) |pkg| {
            if (pkg.value_ptr.*.requires_update) {
                try self.print(" {s}\n", .{pkg.key_ptr.*});
            }
        }
    }

    pub fn processOutOfDate(self: *Pacman) !void {
        if (self.updates == 0) {
            try self.print("{s}::{s} {s}All AUR packages are up-to-date.{s}\n", .{
                color.BoldForegroundBlue,
                color.Reset,
                color.Bold,
                color.Reset,
            });
            return;
        }
        try Dir.cwd().createDirPath(self.io, self.zur_path);

        var pkgs_iter = self.pkgs.iterator();
        while (pkgs_iter.next()) |pkg| {
            if (pkg.value_ptr.*.requires_update) {
                if (try self.localPackageExists(pkg.key_ptr.*, pkg.value_ptr.*.aur_version.?)) {
                    try self.print("{s}warning:{s} Found existing up-to-date package: {s}{s}-{s}{s}, deferring to pacman -U...\n", .{
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
                if (!mem.eql(u8, pkg.value_ptr.*.version, "0")) {
                    try self.print("{s}::{s} Updating {s}{s}{s}: {s}{s}{s} -> {s}{s}{s}\n", .{
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
                    try self.print("{s}::{s} Installing {s}{s}{s} {s}{s}{s}\n", .{
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

    fn localPackageExists(self: *Pacman, pkg_name: []const u8, new_ver: []const u8) !bool {
        // TODO: Handle "any" arch package names.
        const full_pkg_name = try mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, new_ver, "x86_64.pkg.tar.zst" });
        defer self.allocator.free(full_pkg_name);

        // For -git packages we always force an install (we don't know if
        // there's been a source update), so don't treat them as existing.
        if (mem.containsAtLeast(u8, full_pkg_name, 1, "-git")) {
            return false;
        }

        const full_path = try Dir.path.join(self.allocator, &[_][]const u8{ self.zur_pkg_dir, full_pkg_name });
        defer self.allocator.free(full_path);

        // Direct existence check rather than scanning the whole directory.
        var f = Dir.openFileAbsolute(self.io, full_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer f.close(self.io);
        return true;
    }

    fn downloadAndExtractPackage(self: *Pacman, pkg_name: []const u8, pkg: *Package) !void {
        const file_name = try mem.join(self.allocator, ".", &[_][]const u8{ pkg_name, "tar.gz" });
        const dir_name = try mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, pkg.aur_version.? });

        const full_dir = try Dir.path.join(self.allocator, &[_][]const u8{ self.zur_path, dir_name });
        const full_file_path = try Dir.path.join(self.allocator, &[_][]const u8{ full_dir, file_name });

        //This is not perfect (not robust against manual changes), but it's sufficient for it's purpose (short-circuiting)
        var existing = Dir.openDirAbsolute(self.io, full_dir, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };

        if (existing) |*d| {
            d.close(self.io);
            try self.print(" skipping download, {s}{s}{s} already exists...\n", .{ color.Bold, full_dir, color.Reset });
            return;
        }

        var url: []const u8 = undefined;
        if (pkg.base_name) |base_name| {
            const name = try mem.join(self.allocator, ".", &[_][]const u8{ base_name, "tar.gz" });
            url = try mem.join(self.allocator, "/", &[_][]const u8{ aur.Snapshot, name });
        } else {
            url = try mem.join(self.allocator, "/", &[_][]const u8{ aur.Snapshot, file_name });
        }

        try self.print(" downloading from: {s}{s}{s}\n", .{ color.Bold, url, color.Reset });
        const http = try Request.init(self.allocator, self.io);
        defer http.deinit();
        const snapshot = try http.getRequest(url);
        try self.print(" downloaded to: {s}{s}{s}\n", .{ color.Bold, full_file_path, color.Reset });

        try Dir.cwd().createDirPath(self.io, full_dir);
        var dl_dir = try Dir.openDirAbsolute(self.io, full_dir, .{});
        defer dl_dir.close(self.io);
        try dl_dir.writeFile(self.io, .{
            .sub_path = file_name,
            .data = snapshot,
        });
        try self.extractPackage(full_dir, pkg_name);
    }

    // TODO: Maybe one day if there's and easy way to extract tar.gz archives in Zig (be it stdlib or 3rd party), we can replace this.
    fn extractPackage(self: *Pacman, snapshot_path: []const u8, pkg_name: []const u8) !void {
        const file_name = try mem.join(self.allocator, ".", &[_][]const u8{ pkg_name, "tar.gz" });
        const file_path = try Dir.path.join(self.allocator, &[_][]const u8{ snapshot_path, file_name });
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &[_][]const u8{ "tar", "-xf", file_path, "-C", snapshot_path, "--strip-components=1" },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        try Dir.deleteFileAbsolute(self.io, file_path);
    }

    fn compareUpdateAndInstall(self: *Pacman, pkg_name: []const u8, pkg: *Package) !void {
        const old_files = try self.snapshotFiles(pkg_name, pkg.version);
        if (old_files.count() == 0) {
            // We have no older version stored in the filesystem.
            // Fallback to just installing
            return self.bareInstall(pkg_name, pkg);
        }

        const new_files = try self.snapshotFiles(pkg_name, pkg.aur_version.?);
        if (new_files.count() == 0) {
            return self.bareInstall(pkg_name, pkg);
        }

        const old_pkgbuild_content = old_files.get("PKGBUILD") orelse return;
        var old_pkgbuild = Pkgbuild.init(self.allocator, old_pkgbuild_content);
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
                try self.print("{s}::{s} {s}{s}{s} was updated: {s}\n", .{
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
                const old_content_maybe = old_files.get(file.key_ptr.*);
                const new_content_maybe = new_files.get(file.key_ptr.*);
                if (old_content_maybe == null or new_content_maybe == null) {
                    // One side is missing this file (added or removed in this
                    // update), so there's nothing to compare.
                    try self.print("{s}->{s} {s}{s}{s} only exists in one version; skipping diff\n", .{
                        color.ForegroundBlue,
                        color.Reset,
                        color.Bold,
                        file.key_ptr.*,
                        color.Reset,
                    });
                    continue;
                }

                const old_content = old_content_maybe.?;
                const new_content = new_content_maybe.?;
                if (!mem.eql(u8, old_content, new_content)) {
                    at_least_one_diff = true;

                    // TODO: would be cool to show a real diff here
                    try self.print("{s}::{s} {s}{s}{s} was updated:\n{s}\n", .{
                        color.BoldForegroundBlue,
                        color.Reset,
                        color.Bold,
                        file.key_ptr.*,
                        color.Reset,
                        new_files.get(file.key_ptr.*).?,
                    });
                }
            }
        }
        if (at_least_one_diff) {
            try self.print("\nContinue? [Y/n]: ", .{});
            const input = try self.stdinReadByte();
            if (input != 'y' and input != 'Y') {
                return;
            } else {
                try self.stdinClearByte();
                try self.print("\n", .{});
            }
        } else {
            try self.print("{s}::{s} No meaningful diff's found\n", .{ color.ForegroundBlue, color.Reset });
        }
        try self.install(pkg_name, pkg);
    }

    // TODO: handle recursively installing dependencies from AUR
    // 0. Parse the dep list from .SRCINFO
    // 1. We need a strategy to split official/AUR deps
    // 2. Install official deps
    // 3. Install AUR deps
    // 4. Then install the package
    fn bareInstall(self: *Pacman, pkg_name: []const u8, pkg: *Package) !void {
        var pkg_files = try self.snapshotFiles(pkg_name, pkg.aur_version.?);
        var pkg_files_iter = pkg_files.iterator();
        while (pkg_files_iter.next()) |pkg_file| {
            if (mem.eql(u8, pkg_file.key_ptr.*, "PKGBUILD")) {
                var pkgbuild = Pkgbuild.init(self.allocator, pkg_file.value_ptr.*);
                try pkgbuild.readLines();
                const format = "\n{s}::{s} File: {s}PKGBUILD{s} {s}===================={s}\n";
                try self.print(format, .{
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
                    if (!mem.endsWith(u8, field.key_ptr.*, "()")) continue;
                    try self.print("  {s} {s}\n", .{ field.key_ptr.*, field.value_ptr.*.value });
                }
            } else {
                const format = "\n{s}::{s} File: {s}{s}{s} {s}===================={s}\n{s}";
                try self.print(format, .{
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

        try self.print("Install? [Y/n]: ", .{});
        const input = try self.stdinReadByte();
        if (input == 'y' or input == 'Y') {
            try self.install(pkg_name, pkg);
        } else {
            try self.print("\n", .{});
            try self.stdinClearByte();
        }
    }

    fn install(self: *Pacman, pkg_name: []const u8, pkg: *Package) !void {
        const pkg_dir = try mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, pkg.aur_version.? });
        const full_pkg_dir = try Dir.path.join(self.allocator, &[_][]const u8{ self.zur_path, pkg_dir });
        try std.process.setCurrentPath(self.io, full_pkg_dir);

        const argv = &[_][]const u8{ "makepkg", "-sicC" };
        try self.execCommand(argv);

        try self.removeStaleArtifacts(pkg_name, self.zur_pkg_dir);
        try self.moveBuiltPackages(pkg_name, pkg);
    }

    fn installExistingPackage(self: *Pacman, pkg_name: []const u8, pkg: *Package) !void {
        try std.process.setCurrentPath(self.io, self.zur_pkg_dir);

        // TODO: Dynamically get the right arch
        const full_pkg_name = try mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, pkg.aur_version.?, "x86_64.pkg.tar.zst" });
        const argv = &[_][]const u8{ "sudo", "pacman", "-U", full_pkg_name };
        try self.execCommand(argv);
    }

    fn execCommand(self: *Pacman, argv: []const []const u8) !void {
        try self.stdinClearByte();
        // Our pending output must be flushed before the child inherits stdout,
        // otherwise it could appear after the child's own output.
        self.flushStdout();

        var child = try std.process.spawn(self.io, .{
            .argv = argv,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        // TODO: Ctrl+c from a [sudo] prompt causes some weird output behavior.
        // I probably need signal handling for this to properly work.
        // TODO: We also need some additional cleanup steps if it fails.
        _ = try child.wait(self.io);
    }

    fn moveBuiltPackages(self: *Pacman, pkg_name: []const u8, pkg: *Package) !void {
        const pkg_dir = try mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, pkg.aur_version.? });
        const full_pkg_dir = try Dir.path.join(self.allocator, &[_][]const u8{ self.zur_path, pkg_dir });

        var dir = Dir.openDirAbsolute(self.io, full_pkg_dir, .{ .iterate = true, .access_sub_paths = false, .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(self.io);

        var dir_iter = dir.iterate();
        while (try dir_iter.next(self.io)) |node| {
            if (!mem.containsAtLeast(u8, node.name, 1, ".pkg.tar.zst")) {
                continue;
            }
            const full_old_name = try Dir.path.join(self.allocator, &[_][]const u8{ full_pkg_dir, node.name });
            const full_new_name = try Dir.path.join(self.allocator, &[_][]const u8{ self.zur_pkg_dir, node.name });
            try Dir.renameAbsolute(full_old_name, full_new_name, self.io);
        }

        try self.removeStaleArtifacts(pkg_name, self.zur_path);
    }

    fn removeStaleArtifacts(self: *Pacman, pkg_name: []const u8, dir_path: []const u8) !void {
        var dir = Dir.openDirAbsolute(self.io, dir_path, .{ .iterate = true, .access_sub_paths = false, .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(self.io);

        // Collect (mtime, name) pairs in a single slice and sort it directly,
        // rather than keeping a parallel list + map keyed by mtime (which also
        // collided when two files shared a timestamp).
        const Artifact = struct {
            mtime: i128,
            name: []u8,
        };
        var artifacts: std.ArrayList(Artifact) = .empty;
        defer {
            for (artifacts.items) |a| self.allocator.free(a.name);
            artifacts.deinit(self.allocator);
        }
        var dir_iter = dir.iterate();
        while (try dir_iter.next(self.io)) |node| {
            // TODO: This is broken if the package name is a substring of another.
            if (!mem.containsAtLeast(u8, node.name, 1, pkg_name)) {
                continue;
            }
            const path = try Dir.path.join(self.allocator, &[_][]const u8{ dir_path, node.name });
            defer self.allocator.free(path);
            var f = try Dir.openFileAbsolute(self.io, path, .{});
            defer f.close(self.io);
            const stat = try f.stat(self.io);
            // Store an owned copy of the entry name (dir_iter buffers are
            // reused) so we can delete via a Dir handle after iteration.
            const name_copy = try self.allocator.dupe(u8, node.name);
            errdefer self.allocator.free(name_copy);
            try artifacts.append(self.allocator, .{ .mtime = stat.mtime.nanoseconds, .name = name_copy });
        }

        // Keep the last 3 installed versions of the package.
        if (artifacts.items.len > 3) {
            const LessThan = struct {
                fn lessThan(_: void, a: Artifact, b: Artifact) bool {
                    return a.mtime < b.mtime;
                }
            };
            std.mem.sort(Artifact, artifacts.items, {}, LessThan.lessThan);

            const marked_for_removal = artifacts.items[0 .. artifacts.items.len - 3];
            // deleteTree is relative to a Dir handle, so open the (absolute)
            // parent directory once and delete by entry name rather than
            // resolving an absolute path through cwd.
            var parent = try Dir.openDirAbsolute(self.io, dir_path, .{});
            defer parent.close(self.io);
            for (marked_for_removal) |artifact| {
                try parent.deleteTree(self.io, artifact.name);
                try self.print("  {s}->{s} deleting stale file or dir: {s}\n", .{
                    color.ForegroundBlue,
                    color.Reset,
                    artifact.name,
                });
            }
        }
    }

    fn snapshotFiles(self: *Pacman, pkg_name: []const u8, pkg_version: []const u8) !std.StringHashMap([]u8) {
        const dir_name = try mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, pkg_version });
        const path = try Dir.path.join(self.allocator, &[_][]const u8{ self.zur_path, dir_name });

        var dir = Dir.openDirAbsolute(self.io, path, .{ .iterate = true, .access_sub_paths = false, .follow_symlinks = false }) catch |err| switch (err) {
            // No snapshot directory yet (e.g. a package that was never
            // downloaded): return an empty map so callers avoid unwrapping
            // an optional.
            error.FileNotFound => return std.StringHashMap([]u8).init(self.allocator),
            else => return err,
        };
        defer dir.close(self.io);
        try self.print(" reading files in {s}{s}{s}\n", .{ color.Bold, path, color.Reset });

        var files_map = std.StringHashMap([]u8).init(self.allocator);
        var dir_iter = dir.iterate();
        while (try dir_iter.next(self.io)) |node| {
            if (mem.eql(u8, node.name, ".SRCINFO")) {
                continue;
            }
            if (mem.eql(u8, node.name, ".gitignore")) {
                continue;
            }
            if (mem.containsAtLeast(u8, node.name, 1, ".tar.")) {
                continue;
            }
            if (node.kind != .file) {
                continue;
            }

            const file_contents = dir.readFileAlloc(self.io, node.name, self.allocator, .limited(max_snapshot_diff_bytes)) catch |err| switch (err) {
                error.StreamTooLong => {
                    try self.print("  {s}->{s} skipping diff for large file: {s}{s}{s}\n", .{
                        color.ForegroundBlue,
                        color.Reset,
                        color.Bold,
                        node.name,
                        color.Reset,
                    });
                    continue;
                },
                else => return err,
            };

            // PKGBUILD's have their own indent logic
            if (!mem.eql(u8, node.name, "PKGBUILD")) {
                var buf: std.ArrayList(u8) = .empty;
                var lines_iter = mem.splitScalar(u8, file_contents, '\n');
                while (lines_iter.next()) |line| {
                    try buf.appendSlice(self.allocator, "  ");
                    try buf.appendSlice(self.allocator, line);
                    try buf.append(self.allocator, '\n');
                }
                const copyName = try self.allocator.dupe(u8, node.name);
                try files_map.putNoClobber(copyName, try buf.toOwnedSlice(self.allocator));
            } else {
                const copyName = try self.allocator.dupe(u8, node.name);
                try files_map.putNoClobber(copyName, file_contents);
            }
        }
        return files_map;
    }

    fn stdinReadByte(self: *Pacman) !u8 {
        // Make sure the prompt is flushed before we block waiting for input.
        self.flushStdout();
        const input = try self.stdin().interface.takeByte();
        self.stdin_has_input = true;
        return input;
    }

    // We want to "eat" a character so that it doesn't get exposed to the child process.
    // TODO: There's likely a more correct way to handle this.
    fn stdinClearByte(self: *Pacman) !void {
        if (!self.stdin_has_input) {
            return;
        }
        _ = try self.stdin().interface.takeArray(1);
        self.stdin_has_input = false;
    }
};

pub fn search(
    allocator: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    pkg: []const u8,
) !void {
    var pacman = try Pacman.init(allocator, io, environ_map);
    defer pacman.deinit();
    try pacman.fetchLocalPackages();

    const installed = color.BoldForegroundCyan ++ "[Installed]" ++ color.Reset;
    const resp = try aur.search(allocator, io, pkg, .name);
    for (resp.results) |result| {
        const installed_text = if (pacman.pkgs.get(result.Name) == null) "" else installed;
        const desc = result.Description orelse "(missing)";
        try pacman.print("{s}aur/{s}{s}{s}{s} {s}{s}{s} {s} ({d})\n    {s}\n", .{
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
            desc,
        });
    }
}
