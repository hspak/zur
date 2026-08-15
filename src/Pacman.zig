//! Install and update AUR packages: version compare, deps, build, and pacman -U.

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.pacman);
const mem = std.mem;
const Allocator = mem.Allocator;
const Dir = Io.Dir;
const File = Io.File;

const tar = std.tar;
const flate = std.compress.flate;

// For `tcgetpgrp`/`tcsetpgrp` (terminal foreground process group control),
// which the libc-backed `std.posix` layer doesn't expose. zur links libc for
// libalpm, so these come straight from libc.
const c = @cImport({
    @cInclude("unistd.h");
});

const Alpm = @import("Alpm.zig");
const aur = @import("aur.zig");
const color = @import("color.zig");
const Pkgbuild = @import("Pkgbuild.zig");
const Request = @import("Request.zig");

const Pacman = @This();

pub const TarExtractError = error{
    EndOfStream,
    UnexpectedEndOfStream,
    TarHeader,
    TarHeaderChksum,
    TarNumericValueNegative,
    TarNumericValueTooBig,
    TarInsufficientBuffer,
    PaxNullInKeyword,
    PaxInvalidAttributeEnd,
    PaxSizeAttrOverflow,
    PaxNullInValue,
    TarHeadersTooBig,
    TarUnsupportedHeader,
    TarComponentsOutsideStrippedPrefix,
    UnableToCreateSymLink,
};

pub const Error =
    Allocator.Error ||
    Alpm.Error ||
    aur.Error ||
    Pkgbuild.Error ||
    Dir.OpenError ||
    Dir.CreateDirPathError ||
    Dir.DeleteTreeError ||
    Dir.DeleteFileError ||
    Dir.ReadFileAllocError ||
    Dir.WriteFileError ||
    Dir.RenameError ||
    File.OpenError ||
    File.StatError ||
    std.process.SpawnError ||
    std.process.Child.WaitError ||
    TarExtractError ||
    Io.Reader.DelimiterError ||
    error{
        NoHomeEnvVarFound,
        BadInitialPkgsState,
        ZeroResultsFromAurQuery,
        NonzeroStatus,
        EmptyDependency,
        VariableDependency,
        TarCreate,
    };

allocator: Allocator,
io: Io,
environ_map: *const std.process.Environ.Map,
pkgs: std.StringHashMapUnmanaged(*Package) = .empty,
aur_resp: ?aur.RPCRespV5 = null,
pacman_output: ?[]u8 = null,
zur_path: []const u8,
zur_pkg_dir: []const u8,
updates: usize = 0,
// Package bases already resolved this run, so dep recursion cannot loop.
aur_deps_done: std.StringHashMapUnmanaged(void) = .empty,
// Lazily-initialized libalpm handle (see getAlpm).
alpm_state: ?Alpm = null,
// Persisted HTTP client (see getRequest).
request_state: ?Request = null,

stdout_buffer: [4096]u8 = undefined,
stdout_writer: ?File.Writer = null,
stdin_buffer: [4096]u8 = undefined,
stdin_reader: ?File.Reader = null,

/// One local/AUR package tracked for install or update.
pub const Package = struct {
    base_name: ?[]const u8 = null,
    version: []const u8,
    aur_version: ?[]const u8 = null,
    requires_update: bool = false,

    /// `version` is borrowed. `"0"` is the fresh-install sentinel.
    pub fn init(version: []const u8) Package {
        return .{ .version = version };
    }
};

// Files larger than this are skipped when diffing a package snapshot.
const max_snapshot_diff_bytes: usize = 4096;

// Architecture component in built package filenames (native compile target).
fn machineArch() []const u8 {
    return switch (@import("builtin").cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .riscv64 => "riscv64",
        else => @compileError("unsupported architecture for package filenames"),
    };
}

// VCS/-git packages (e.g. neovim-git): rebuild even when pkgver is unchanged.
fn isGitPkg(name: []const u8) bool {
    return mem.endsWith(u8, name, "-git");
}

// Whether a package needs an update/install. `remote_newer` is alpm vercmp.
fn shouldUpdate(name: []const u8, local: []const u8, remote: []const u8, remote_newer: bool) bool {
    // A -git package is rebuilt whenever its AUR pkgver matches the installed
    // one: the version string rarely changes, but the upstream source may have
    // moved since the last build.
    if (isGitPkg(name) and mem.eql(u8, remote, local)) {
        return true;
    }
    // Version "0" is the sentinel for a freshly-requested install.
    if (mem.eql(u8, local, "0")) {
        return true;
    }
    return remote_newer;
}

// True if `name` refers to package `want` as a full leading component, so
// "foo" doesn't also match "foobar-...".
fn artifactNameForPkg(name: []const u8, want: []const u8) bool {
    if (name.len < want.len) return false;
    if (!mem.startsWith(u8, name, want)) return false;
    if (name.len == want.len) return true;
    return name[want.len] == '-'; // next component boundary
}

// Bare package name from an AUR Depends/MakeDepends string.
// "foo>=1.2.3" -> "foo", "foo|bar" -> "foo", "$pkgname" -> error.
// The caller owns the returned slice.
fn normalizeDepName(allocator: Allocator, dep: []const u8) ![]const u8 {
    const trimmed = mem.trim(u8, dep, " \t");
    if (trimmed.len == 0) return error.EmptyDependency;

    // Take the first alternative of an OR-list ("a|b" means "a" or "b").
    const first = if (mem.indexOfScalar(u8, trimmed, '|')) |idx| trimmed[0..idx] else trimmed;

    // Strip a version constraint suffix: "foo>=1.0", "foo=1.0", "foo<2".
    const ops = [_][]const u8{ ">=", "<=", "==", "=", ">", "<" };
    var name = mem.trim(u8, first, " \t");
    for (ops) |op| {
        if (mem.indexOf(u8, name, op)) |idx| {
            name = mem.trim(u8, name[0..idx], " \t");
            break;
        }
    }
    if (name.len == 0) return error.EmptyDependency;

    // A literal "$" (e.g. "$pkgname" / "$pkgver") is a self-reference we
    // can't resolve through the AUR; the dependency isn't an external package.
    if (mem.indexOfScalar(u8, name, '$') != null) return error.VariableDependency;

    return try allocator.dupe(u8, name);
}

// Extract `archive_name` in `dest_dir`, stripping the AUR snapshot top dir.
fn extractTarGz(io: Io, dest_dir: Io.Dir, archive_name: []const u8) !void {
    const file = try dest_dir.openFile(io, archive_name, .{});
    defer file.close(io);

    var file_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);

    var gzip_buffer: [flate.max_window_len]u8 = undefined;
    var decompress = flate.Decompress.init(&file_reader.interface, .gzip, &gzip_buffer);

    // std.tar sanitizes paths and applies the executable bit from the archive.
    try tar.extract(io, dest_dir, &decompress.reader, .{
        .strip_components = 1,
        .mode_mode = .executable_bit_only,
    });

    // The archive file is consumed once extracted.
    try dest_dir.deleteFile(io, archive_name);
}

/// Create `~/.zur/.pkg` and an empty package set. `allocator` should outlive the run.
pub fn init(allocator: Allocator, io: Io, environ_map: *const std.process.Environ.Map) Error!Pacman {
    const home = environ_map.get("HOME") orelse return error.NoHomeEnvVarFound;
    const zur_dir = ".zur";

    const zur_path = try Dir.path.join(allocator, &[_][]const u8{ home, zur_dir });
    errdefer allocator.free(zur_path);
    const pkg_dir = try Dir.path.join(allocator, &[_][]const u8{ zur_path, ".pkg" });
    errdefer allocator.free(pkg_dir);
    try Dir.cwd().createDirPath(io, pkg_dir);
    log.debug("zur_path={s}", .{zur_path});

    return .{
        .allocator = allocator,
        .io = io,
        .environ_map = environ_map,
        .zur_path = zur_path,
        .zur_pkg_dir = pkg_dir,
    };
}

/// Free owned packages, maps, alpm, and the HTTP client.
pub fn deinit(self: *Pacman) void {
    self.flushStdout();
    if (self.pacman_output) |out| self.allocator.free(out);
    if (self.aur_resp) |resp| self.allocator.free(resp.results);
    // pkg keys are borrowed slices (into pacman_output or argv), so only
    // the Package structs themselves are owned here.
    var it = self.pkgs.iterator();
    while (it.next()) |e| {
        self.allocator.destroy(e.value_ptr.*);
    }
    self.pkgs.deinit(self.allocator);
    self.aur_deps_done.deinit(self.allocator);
    if (self.alpm_state) |*state| state.deinit();
    if (self.request_state) |*req| req.deinit();
    self.* = undefined;
}

fn getAlpm(self: *Pacman) !*Alpm {
    if (self.alpm_state == null) {
        self.alpm_state = try Alpm.init(self.allocator);
    }
    return &self.alpm_state.?;
}

fn getRequest(self: *Pacman) *Request {
    if (self.request_state == null) {
        self.request_state = Request.init(self.allocator, self.io);
    }
    return &self.request_state.?;
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

// Flush before prompts, before a child inherits stdout, and on teardown.
fn flushStdout(self: *Pacman) void {
    const w = self.stdout();
    w.flush() catch {};
}

/// Load installed foreign (AUR) packages from libalpm into `pkgs`.
pub fn fetchLocalPackages(self: *Pacman) Error!void {
    if (self.pkgs.count() != 0) {
        return error.BadInitialPkgsState;
    }

    const foreign = try (try self.getAlpm()).fetchForeignPackages();
    // The name/version strings are arena-owned (see init's allocator), so
    // they stay alive for the whole run and the pkg map keys/versions may
    // borrow them; nothing is freed individually here.
    for (foreign) |pkg_info| {
        const new_pkg = try self.allocator.create(Package);
        errdefer self.allocator.destroy(new_pkg);
        new_pkg.* = .init(pkg_info.version);
        try self.pkgs.putNoClobber(self.allocator, pkg_info.name, new_pkg);
    }
}

/// Queue `pkg_list` for install using the version-`"0"` sentinel.
pub fn setInstallPackages(self: *Pacman, pkg_list: std.ArrayList([]const u8)) Error!void {
    if (self.pkgs.count() != 0) {
        return error.BadInitialPkgsState;
    }

    for (pkg_list.items) |pkg_name| {
        // This is the hack:
        // We're setting an impossible version to initialize the packages to install.
        const new_pkg = try self.allocator.create(Package);
        errdefer self.allocator.destroy(new_pkg);
        new_pkg.* = .init("0");

        try self.pkgs.putNoClobber(self.allocator, pkg_name, new_pkg);
    }
}

/// Fill each tracked package's `aur_version` (and `base_name` if split).
pub fn fetchRemoteAurVersions(self: *Pacman) Error!void {
    self.aur_resp = try aur.queryAll(self.allocator, self.getRequest(), self.pkgs);
    if (self.aur_resp.?.resultcount == 0) {
        return error.ZeroResultsFromAurQuery;
    }
    for (self.aur_resp.?.results) |result| {
        // Skip results the AUR returns for packages we didn't ask about
        // (e.g. a dependency that also came back) rather than crashing.
        const curr_pkg = self.pkgs.get(result.name) orelse continue;
        curr_pkg.aur_version = result.version;

        // Null base_name means the pkgname is the base. A non-null base
        // (a split package) is de-duplicated in processOutOfDate so the
        // shared base is only installed once.
        if (!mem.eql(u8, result.name, result.package_base)) {
            curr_pkg.base_name = result.package_base;
        }
    }
}

/// Mark packages that need install/update and print the list.
pub fn compareVersions(self: *Pacman) Error!void {
    var pkgs_iter = self.pkgs.iterator();
    while (pkgs_iter.next()) |pkg| {
        const local_version = pkg.value_ptr.*.version;

        if (pkg.value_ptr.*.aur_version == null) {
            try self.print("{s}warning:{s} {s}{s}{s} was orphaned or non-existant in AUR, skipping\n", .{
                color.bold_foreground_yellow,
                color.reset,
                color.bold,
                pkg.key_ptr.*,
                color.reset,
            });
            continue;
        }

        const remote_version = pkg.value_ptr.*.aur_version.?;
        const remote_newer = try Alpm.isNewerThan(self.allocator, remote_version, local_version);
        if (shouldUpdate(pkg.key_ptr.*, local_version, remote_version, remote_newer)) {
            pkg.value_ptr.*.requires_update = true;
            self.updates += 1;
        }
    }

    if (self.updates == 0) {
        return;
    }
    pkgs_iter = self.pkgs.iterator();
    try self.print("{s}::{s} Packages to be installed or updated:\n", .{ color.bold_foreground_blue, color.reset });
    while (pkgs_iter.next()) |pkg| {
        if (pkg.value_ptr.*.requires_update) {
            try self.print(" {s}\n", .{pkg.key_ptr.*});
        }
    }
}

/// Download, review, build, and install every package marked for update.
pub fn processOutOfDate(self: *Pacman) Error!void {
    if (self.updates == 0) {
        try self.print("{s}::{s} {s}All AUR packages are up-to-date.{s}\n", .{
            color.bold_foreground_blue,
            color.reset,
            color.bold,
            color.reset,
        });
        return;
    }
    try Dir.cwd().createDirPath(self.io, self.zur_path);

    // De-dup split packages: a PKGBUILD with multiple pkgnames shares a
    // package base, and installing a base once builds and installs all of
    // its pkgnames. Track bases already handled and skip the rest, so the
    // same base isn't downloaded/built/installed once per pkgname.
    var processed_bases: std.StringHashMapUnmanaged(void) = .empty;
    defer processed_bases.deinit(self.allocator);

    var pkgs_iter = self.pkgs.iterator();
    while (pkgs_iter.next()) |pkg| {
        if (pkg.value_ptr.*.requires_update) {
            if (pkg.value_ptr.*.base_name) |base| {
                if (processed_bases.get(base) != null) {
                    try self.print("{s}::{s} {s}{s}{s} is part of base {s}{s}{s}, already handled\n", .{
                        color.bold_foreground_blue,
                        color.reset,
                        color.bold,
                        pkg.key_ptr.*,
                        color.reset,
                        color.bold,
                        base,
                        color.reset,
                    });
                    continue;
                }
                try processed_bases.putNoClobber(self.allocator, base, {});
            }
            if (try self.findExistingPackage(pkg.key_ptr.*, pkg.value_ptr.*.aur_version.?)) |full_pkg_name| {
                defer self.allocator.free(full_pkg_name);
                try self.print("{s}warning:{s} Found existing up-to-date package: {s}{s}-{s}{s}, deferring to pacman -U...\n", .{
                    color.bold_foreground_yellow,
                    color.reset,
                    color.bold,
                    pkg.key_ptr.*,
                    pkg.value_ptr.*.aur_version.?,
                    color.reset,
                });
                try self.installExistingPackage(full_pkg_name);
                // Keep going: other packages may also be out of date. An
                // early return here would skip the rest of the loop and
                // leave them uninstalled.
                continue;
            }

            // The install hack is bleeding into here.
            if (!mem.eql(u8, pkg.value_ptr.*.version, "0")) {
                try self.print("{s}::{s} Updating {s}{s}{s}: {s}{s}{s} -> {s}{s}{s}\n", .{
                    color.bold_foreground_blue,
                    color.reset,
                    color.bold,
                    pkg.key_ptr.*,
                    color.reset,
                    color.foreground_red,
                    pkg.value_ptr.*.version,
                    color.reset,
                    color.foreground_green,
                    pkg.value_ptr.*.aur_version.?,
                    color.reset,
                });
            } else {
                try self.print("{s}::{s} Installing {s}{s}{s} {s}{s}{s}\n", .{
                    color.bold_foreground_blue,
                    color.reset,
                    color.bold,
                    pkg.key_ptr.*,
                    color.reset,
                    color.foreground_green,
                    pkg.value_ptr.*.aur_version.?,
                    color.reset,
                });
            }
            try self.installWithDeps(pkg.key_ptr.*, pkg.value_ptr.*);
        }
    }
}

// Official/repo deps are left for `makepkg -s`.
fn installWithDeps(self: *Pacman, pkg_name: []const u8, pkg: *Package) !void {
    try self.ensureAurDepsInstalled(pkg_name);
    try self.downloadAndExtractPackage(pkg_name, pkg);
    try self.compareUpdateAndInstall(pkg_name, pkg);
}

// Mark `pkg_name` handled first so cycles and repeats terminate.
fn ensureAurDepsInstalled(self: *Pacman, pkg_name: []const u8) !void {
    if (self.aur_deps_done.contains(pkg_name)) return;
    try self.aur_deps_done.put(self.allocator, pkg_name, {});

    const info = (try self.getAurInfo(pkg_name)) orelse return;
    const dep_lists = [_]?[][]const u8{ info.depends, info.make_depends };
    for (dep_lists) |maybe_list| {
        const list = maybe_list orelse continue;
        for (list) |dep| {
            const dep_name = normalizeDepName(self.allocator, dep) catch continue;
            defer self.allocator.free(dep_name);
            if (dep_name.len == 0) continue;

            if (self.aur_deps_done.contains(dep_name)) continue;
            if (try (try self.getAlpm()).isInstalled(dep_name)) continue;
            const dep_info = (try self.getAurInfo(dep_name)) orelse continue;

            try self.ensureAurDepsInstalled(dep_name);

            const dep_pkg = try self.allocator.create(Package);
            defer self.allocator.destroy(dep_pkg);
            dep_pkg.* = .init("0");
            dep_pkg.aur_version = dep_info.version;
            // A split-package dep shares its base's snapshot; set base_name
            // (mirroring fetchRemoteAurVersions) so the right archive and
            // directory are used.
            if (!mem.eql(u8, dep_info.name, dep_info.package_base)) {
                dep_pkg.base_name = dep_info.package_base;
            }
            try self.downloadAndExtractPackage(dep_name, dep_pkg);
            try self.compareUpdateAndInstall(dep_name, dep_pkg);
        }
    }
}

// Full AUR info for `name`, or null if it is an official/repo dependency.
fn getAurInfo(self: *Pacman, name: []const u8) !?aur.Info {
    if (self.aurInfoFor(name)) |info| return info;
    return try aur.queryName(self.allocator, self.getRequest(), name);
}

fn aurInfoFor(self: *Pacman, name: []const u8) ?aur.Info {
    const resp = self.aur_resp orelse return null;
    for (resp.results) |info| {
        if (mem.eql(u8, info.name, name)) return info;
    }
    return null;
}

// Returns the filename of an already-built package for (pkg_name, version)
// in zur_pkg_dir, considering both the machine arch and "any" packages.
// The caller owns the returned slice.
fn findExistingPackage(self: *Pacman, pkg_name: []const u8, version: []const u8) !?[]u8 {
    // For -git packages we always force an install (we don't know if
    // there's been a source update), so don't treat them as existing.
    if (isGitPkg(pkg_name)) {
        return null;
    }

    const archs = [_][]const u8{ machineArch(), "any" };
    for (archs) |arch| {
        const name = try mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, version, arch, "pkg.tar.zst" });
        const full_path = try Dir.path.join(self.allocator, &[_][]const u8{ self.zur_pkg_dir, name });
        var found = false;
        defer {
            self.allocator.free(full_path);
            if (!found) self.allocator.free(name);
        }
        const f = Dir.openFileAbsolute(self.io, full_path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => {
                @branchHint(.cold);
                return err;
            },
        };
        if (f) |file| {
            file.close(self.io);
            found = true;
            return name;
        }
    }
    return null;
}

fn downloadAndExtractPackage(self: *Pacman, pkg_name: []const u8, pkg: *Package) !void {
    const file_name = try mem.join(self.allocator, ".", &[_][]const u8{ pkg_name, "tar.gz" });
    const dir_name = try mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, pkg.aur_version.? });

    const full_dir = try Dir.path.join(self.allocator, &[_][]const u8{ self.zur_path, dir_name });
    const full_file_path = try Dir.path.join(self.allocator, &[_][]const u8{ full_dir, file_name });

    // Only skip the download if the existing directory is a real,
    // fully-extracted snapshot (it contains a PKGBUILD). A leftover or
    // partially-extracted dir from an interrupted run must be removed and
    // re-downloaded, otherwise a stale or incomplete source could be built
    // and the wrong package version installed.
    var existing = Dir.openDirAbsolute(self.io, full_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };

    if (existing) |*d| {
        var is_valid = false;
        var existing_iter = d.iterate();
        while (try existing_iter.next(self.io)) |node| {
            if (mem.eql(u8, node.name, "PKGBUILD")) {
                is_valid = true;
                break;
            }
        }
        d.close(self.io);
        if (is_valid) {
            try self.print(" skipping download, {s}{s}{s} already exists...\n", .{ color.bold, full_dir, color.reset });
            return;
        }
        try self.print(" removing incomplete snapshot {s}{s}{s}, re-downloading...\n", .{ color.bold, full_dir, color.reset });
        var zur_dir = try Dir.openDirAbsolute(self.io, self.zur_path, .{});
        defer zur_dir.close(self.io);
        try zur_dir.deleteTree(self.io, dir_name);
    }

    const url = if (pkg.base_name) |base_name| url: {
        const name = try mem.join(self.allocator, ".", &[_][]const u8{ base_name, "tar.gz" });
        break :url try mem.join(self.allocator, "/", &[_][]const u8{ aur.snapshot, name });
    } else try mem.join(self.allocator, "/", &[_][]const u8{ aur.snapshot, file_name });

    try self.print(" downloading from: {s}{s}{s}\n", .{ color.bold, url, color.reset });
    const snapshot = try self.getRequest().getRequest(url);
    defer self.allocator.free(snapshot);
    try self.print(" downloaded to: {s}{s}{s}\n", .{ color.bold, full_file_path, color.reset });

    try Dir.cwd().createDirPath(self.io, full_dir);
    var dl_dir = try Dir.openDirAbsolute(self.io, full_dir, .{});
    defer dl_dir.close(self.io);
    try dl_dir.writeFile(self.io, .{
        .sub_path = file_name,
        .data = snapshot,
    });
    try self.extractPackage(full_dir, pkg_name);
}

fn extractPackage(self: *Pacman, snapshot_path: []const u8, pkg_name: []const u8) !void {
    const file_name = try mem.join(self.allocator, ".", &[_][]const u8{ pkg_name, "tar.gz" });
    var dir = try Dir.openDirAbsolute(self.io, snapshot_path, .{});
    defer dir.close(self.io);
    try extractTarGz(self.io, dir, file_name);
}

fn compareUpdateAndInstall(self: *Pacman, pkg_name: []const u8, pkg: *Package) !void {
    // pkg.version = 0 is the hack to forcibly install manually specified
    // packages. This causes us to read the same dir twice.
    const empty_map: std.StringHashMapUnmanaged([]u8) = .empty;
    var old_files = if (!std.mem.eql(u8, pkg.version, "0")) try self.snapshotFiles(pkg_name, pkg.version) else empty_map;
    defer deinitSnapshotFiles(self.allocator, &old_files);

    var new_files = try self.snapshotFiles(pkg_name, pkg.aur_version.?);
    defer deinitSnapshotFiles(self.allocator, &new_files);

    // A diff needs both the old and new snapshots present, each with a
    // PKGBUILD to parse. If either is missing (no prior snapshot, or an
    // unusual snapshot without a PKGBUILD), fall back to a plain install
    // rather than silently skipping the package.
    if (old_files.count() == 0 or new_files.count() == 0 or
        old_files.get("PKGBUILD") == null or new_files.get("PKGBUILD") == null)
    {
        return self.bareInstall(pkg_name, new_files, pkg.aur_version.?);
    }

    var old_pkgbuild = Pkgbuild.init(self.allocator, old_files.get("PKGBUILD").?);
    defer old_pkgbuild.deinit();
    try old_pkgbuild.readLines();
    var new_pkgbuild = Pkgbuild.init(self.allocator, new_files.get("PKGBUILD").?);
    defer new_pkgbuild.deinit();
    try new_pkgbuild.readLines();

    var at_least_one_diff = false;
    try new_pkgbuild.comparePrev(old_pkgbuild);
    try new_pkgbuild.indentValues(2);
    var new_pkgbuild_iter = new_pkgbuild.fields.iterator();
    while (new_pkgbuild_iter.next()) |field| {
        if (field.value_ptr.*.updated) {
            at_least_one_diff = true;
            try self.print("{s}::{s} {s}{s}{s} was updated: {s}\n", .{
                color.bold_foreground_blue,
                color.reset,
                color.bold,
                field.key_ptr.*,
                color.reset,
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
                    color.foreground_blue,
                    color.reset,
                    color.bold,
                    file.key_ptr.*,
                    color.reset,
                });
                continue;
            }

            const old_content = old_content_maybe.?;
            const new_content = new_content_maybe.?;
            if (!mem.eql(u8, old_content, new_content)) {
                at_least_one_diff = true;
                try self.printDiff(file.key_ptr.*, old_content, new_content);
            }
        }
    }
    if (at_least_one_diff) {
        try self.print("\nContinue? [Y/n]: ", .{});
        const input = try self.stdinReadByte();
        if (input != 'y' and input != 'Y') {
            return;
        } else {
            try self.print("\n", .{});
        }
    } else {
        try self.print("{s}::{s} No meaningful diff's found\n", .{ color.foreground_blue, color.reset });
    }
    try self.install(pkg_name, pkg.aur_version.?);
}

// Print a minimal line-based diff between two file contents using an LCS
// (longest common subsequence) to align unchanged lines.
fn printDiff(self: *Pacman, name: []const u8, old_content: []const u8, new_content: []const u8) !void {
    var old_list: std.ArrayList([]const u8) = .empty;
    defer old_list.deinit(self.allocator);
    var new_list: std.ArrayList([]const u8) = .empty;
    defer new_list.deinit(self.allocator);
    var it = mem.splitScalar(u8, old_content, '\n');
    while (it.next()) |line| try old_list.append(self.allocator, line);
    it = mem.splitScalar(u8, new_content, '\n');
    while (it.next()) |line| try new_list.append(self.allocator, line);
    const old = old_list.items;
    const new = new_list.items;
    const n = old.len;
    const m = new.len;

    // LCS length table. dp[i][j] = length of LCS of old[i..] and new[j..].
    const dp = try self.allocator.alloc(usize, (n + 1) * (m + 1));
    defer self.allocator.free(dp);
    @memset(dp, 0);
    const row = struct {
        fn get(table: []usize, width: usize, r: usize) []usize {
            return table[r * (width + 1) ..][0 .. width + 1];
        }
    }.get;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        var j: usize = m;
        while (j > 0) {
            j -= 1;
            if (mem.eql(u8, old[i], new[j])) {
                row(dp, m, i)[j] = row(dp, m, i + 1)[j + 1] + 1;
            } else {
                row(dp, m, i)[j] = @max(row(dp, m, i + 1)[j], row(dp, m, i)[j + 1]);
            }
        }
    }

    try self.print("{s}::{s} {s}{s}{s} was updated:{s}\n", .{
        color.bold_foreground_blue,
        color.reset,
        color.bold,
        name,
        color.reset,
        color.reset,
    });
    i = 0;
    var j: usize = 0;
    while (i < n and j < m) {
        if (mem.eql(u8, old[i], new[j])) {
            i += 1;
            j += 1;
        } else if (row(dp, m, i + 1)[j] >= row(dp, m, i)[j + 1]) {
            try self.print("{s}- {s}{s}\n", .{ color.foreground_red, old[i], color.reset });
            i += 1;
        } else {
            try self.print("{s}+ {s}{s}\n", .{ color.foreground_green, new[j], color.reset });
            j += 1;
        }
    }
    while (i < n) : (i += 1) {
        try self.print("{s}- {s}{s}\n", .{ color.foreground_red, old[i], color.reset });
    }
    while (j < m) : (j += 1) {
        try self.print("{s}+ {s}{s}\n", .{ color.foreground_green, new[j], color.reset });
    }
}

fn printBarePkgbuildFields(allocator: Allocator, writer: *Io.Writer, file_contents: []const u8) !void {
    var pkgbuild = Pkgbuild.init(allocator, file_contents);
    defer pkgbuild.deinit();
    try pkgbuild.readLines();
    try pkgbuild.indentValues(2);

    if (pkgbuild.fields.get("source")) |source| {
        try writer.print("  source {s}\n\n", .{source.value});
    }

    var fields_iter = pkgbuild.fields.iterator();
    while (fields_iter.next()) |field| {
        const name = field.key_ptr.*;
        if (!mem.eql(u8, name, "install") and !mem.endsWith(u8, name, "()")) continue;
        try writer.print("  {s} {s}\n", .{ field.key_ptr.*, field.value_ptr.*.value });
    }
}

fn bareInstall(self: *Pacman, pkg_name: []const u8, pkg_files: std.StringHashMapUnmanaged([]u8), update_version: []const u8) !void {
    var pkg_files_iter = pkg_files.iterator();
    while (pkg_files_iter.next()) |pkg_file| {
        if (mem.eql(u8, pkg_file.key_ptr.*, "PKGBUILD")) {
            const format = "\n{s}::{s} File: {s}PKGBUILD{s} {s}===================={s}\n";
            try self.print(format, .{
                color.bold_foreground_blue,
                color.reset,
                color.bold,
                color.reset,
                color.bold_foreground_blue,
                color.reset,
            });

            try printBarePkgbuildFields(self.allocator, self.stdout(), pkg_file.value_ptr.*);
        } else {
            // snapshotFiles stores raw contents; indent them here for the
            // display only, so the hot diff path stays copy-free.
            const format = "\n{s}::{s} File: {s}{s}{s} {s}===================={s}\n";
            try self.print(format, .{
                color.bold_foreground_blue,
                color.reset,
                color.bold,
                pkg_file.key_ptr.*,
                color.reset,
                color.bold_foreground_blue,
                color.reset,
            });
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.allocator);
            var lines_iter = mem.splitScalar(u8, pkg_file.value_ptr.*, '\n');
            while (lines_iter.next()) |line| {
                try buf.appendSlice(self.allocator, "  ");
                try buf.appendSlice(self.allocator, line);
                try buf.append(self.allocator, '\n');
            }
            try self.print("{s}\n", .{buf.items});
        }
    }

    try self.print("Install? [Y/n]: ", .{});
    const input = try self.stdinReadByte();
    if (input == 'y' or input == 'Y') {
        try self.install(pkg_name, update_version);
    } else {
        try self.print("\n", .{});
    }
}

fn install(self: *Pacman, pkg_name: []const u8, update_version: []const u8) !void {
    const pkg_dir = try mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, update_version });
    const full_pkg_dir = try Dir.path.join(self.allocator, &[_][]const u8{ self.zur_path, pkg_dir });
    try std.process.setCurrentPath(self.io, full_pkg_dir);

    const argv = &[_][]const u8{ "makepkg", "-sicC" };
    try self.execCommand(argv);

    try self.removeStaleArtifacts(pkg_name, self.zur_pkg_dir);
    try self.moveBuiltPackages(pkg_name, update_version);
}

fn installExistingPackage(self: *Pacman, full_pkg_name: []const u8) !void {
    try std.process.setCurrentPath(self.io, self.zur_pkg_dir);

    const argv = &[_][]const u8{ "sudo", "pacman", "-U", full_pkg_name };
    try self.execCommand(argv);
}

fn execCommand(self: *Pacman, argv: []const []const u8) !void {
    // Our pending output must be flushed before the child inherits stdout,
    // otherwise it could appear after the child's own output.
    self.flushStdout();

    var child = try std.process.spawn(self.io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .pgid = 0, // child becomes the leader of its own process group
    });

    // If stdin is a terminal, make the child's process group the foreground
    // one, so Ctrl+C (SIGINT) reaches the child (e.g. a `[sudo]` prompt)
    // instead of zur. zur then survives to reap the child and hand the
    // terminal back, which is what keeps the output from looking garbled.
    // The previous foreground group is captured so it can be restored.
    const stdin_fd = std.posix.STDIN_FILENO;
    const original_fg: ?std.posix.pid_t = original_fg: {
        const pgrp = c.tcgetpgrp(stdin_fd);
        if (pgrp == -1) break :original_fg null; // not a terminal, or not a member
        break :original_fg pgrp;
    };
    if (original_fg != null) {
        _ = c.tcsetpgrp(stdin_fd, child.id.?);
    }

    // Surface a child failure instead of treating it as success: a
    // non-zero exit or termination by a signal means the build/install
    // didn't complete, so abort the operation rather than continuing.
    const term = child.wait(self.io) catch |err| {
        // Hand the terminal back before propagating the error.
        if (original_fg) |fg| _ = c.tcsetpgrp(stdin_fd, fg);
        return err;
    };

    if (original_fg) |fg| {
        // The child's group is gone; hand the terminal back to zur's group.
        // This restore runs while zur is in the background group, which
        // would otherwise send SIGTTOU and stop us, so ignore it briefly.
        var old_act: std.posix.Sigaction = undefined;
        std.posix.sigaction(
            std.posix.SIG.TTOU,
            &.{
                .handler = .{ .handler = std.posix.SIG.IGN },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            },
            &old_act,
        );
        _ = c.tcsetpgrp(stdin_fd, fg);
        std.posix.sigaction(std.posix.SIG.TTOU, &old_act, null);
    }

    switch (term) {
        .exited => |code| if (code != 0) {
            @branchHint(.cold);
            return error.NonzeroStatus;
        },
        .signal, .stopped, .unknown => {
            @branchHint(.cold);
            return error.NonzeroStatus;
        },
    }
}

fn moveBuiltPackages(self: *Pacman, pkg_name: []const u8, update_version: []const u8) !void {
    const pkg_dir = try mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, update_version });
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
        if (!artifactNameForPkg(node.name, pkg_name)) {
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
                color.foreground_blue,
                color.reset,
                artifact.name,
            });
        }
    }
}

fn deinitSnapshotFiles(allocator: Allocator, files: *std.StringHashMapUnmanaged([]u8)) void {
    var it = files.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    files.deinit(allocator);
}

fn snapshotFiles(self: *Pacman, pkg_name: []const u8, pkg_version: []const u8) !std.StringHashMapUnmanaged([]u8) {
    const dir_name = try mem.join(self.allocator, "-", &[_][]const u8{ pkg_name, pkg_version });
    const path = try Dir.path.join(self.allocator, &[_][]const u8{ self.zur_path, dir_name });

    var dir = Dir.openDirAbsolute(self.io, path, .{ .iterate = true, .access_sub_paths = false, .follow_symlinks = false }) catch |err| switch (err) {
        // No snapshot directory yet (e.g. a package that was never
        // downloaded): return an empty map so callers avoid unwrapping
        // an optional.
        error.FileNotFound => return .empty,
        else => return err,
    };
    defer dir.close(self.io);
    try self.print(" reading files in {s}{s}{s}\n", .{ color.bold, path, color.reset });

    var files_map: std.StringHashMapUnmanaged([]u8) = .empty;
    errdefer deinitSnapshotFiles(self.allocator, &files_map);
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
                @branchHint(.cold);
                try self.print("  {s}->{s} skipping diff for large file: {s}{s}{s}\n", .{
                    color.foreground_blue,
                    color.reset,
                    color.bold,
                    node.name,
                    color.reset,
                });
                continue;
            },
            else => return err,
        };

        // Store raw file contents. Any indentation is applied only at
        // display time (bareInstall), so the update/diff path never copies
        // every snapshot file.
        errdefer self.allocator.free(file_contents);
        const copy_name = try self.allocator.dupe(u8, node.name);
        errdefer self.allocator.free(copy_name);
        try files_map.putNoClobber(self.allocator, copy_name, file_contents);
    }
    return files_map;
}

fn stdinReadByte(self: *Pacman) !u8 {
    self.flushStdout();
    // Read the whole line so leftover input isn't exposed to a child
    // that inherits stdin.
    const reader = self.stdin();
    const line = try reader.interface.takeDelimiterInclusive('\n');
    if (line.len == 0) return 0;
    return line[0];
}

/// Search the AUR by name and print hits, marking already-installed packages.
pub fn search(
    allocator: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    pkg: []const u8,
) Error!void {
    var pacman = try Pacman.init(allocator, io, environ_map);
    defer pacman.deinit();
    try pacman.fetchLocalPackages();

    const installed = color.bold_foreground_cyan ++ "[Installed]" ++ color.reset;
    const resp = try aur.search(allocator, pacman.getRequest(), pkg, .name);
    defer allocator.free(resp.results);
    for (resp.results) |result| {
        const installed_text = if (pacman.pkgs.get(result.name) == null) "" else installed;
        const desc = result.description orelse "(missing)";
        try pacman.print("{s}aur/{s}{s}{s}{s} {s}{s}{s} {s} ({d})\n    {s}\n", .{
            color.bold_foreground_magenta,
            color.reset,
            color.bold,
            result.name,
            color.reset,
            color.bold_foreground_green,
            result.version,
            color.reset,
            installed_text,
            result.popularity,
            desc,
        });
    }
}

test "shouldUpdate - fresh install sentinel version 0" {
    const testing = std.testing;
    try testing.expect(shouldUpdate("foo", "0", "1.0.0", true));
    try testing.expect(shouldUpdate("foo", "0", "0.0.0", false));
}

test "shouldUpdate - normal package only when remote is newer" {
    const testing = std.testing;
    try testing.expect(shouldUpdate("foo", "1.0", "2.0", true));
    try testing.expect(!shouldUpdate("foo", "1.0", "1.0", false));
    try testing.expect(!shouldUpdate("foo", "2.0", "1.0", false));
}

test "shouldUpdate - git packages rebuild when pkgver matches" {
    const testing = std.testing;
    // neovim-git: AUR pkgver equals installed -> rebuild to catch new commits.
    try testing.expect(shouldUpdate("neovim-git", "r100.abc", "r100.abc", false));
    // AUR pkgver differs from installed -> rely on the version comparison.
    try testing.expect(!shouldUpdate("neovim-git", "r100.abc", "r200.def", false));
    try testing.expect(shouldUpdate("neovim-git", "r100.abc", "r200.def", true));
    // A non-git package must not rebuild when versions match.
    try testing.expect(!shouldUpdate("neovim", "1.0", "1.0", false));
}

test "normalizeDepName - resolves common AUR dependency forms" {
    const testing = std.testing;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "foo", .want = "foo" },
        .{ .in = "foo>=1.2.3", .want = "foo" },
        .{ .in = "foo=1.0", .want = "foo" },
        .{ .in = "foo<2", .want = "foo" },
        .{ .in = "foo|bar", .want = "foo" },
        .{ .in = "  libluv ", .want = "libluv" },
        .{ .in = "libvterm>=0.1.git5", .want = "libvterm" },
        .{ .in = "foo-bar_baz", .want = "foo-bar_baz" },
    };
    for (cases) |case| {
        const got = try normalizeDepName(testing.allocator, case.in);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(case.want, got);
    }
}

test "normalizeDepName - rejects self-references" {
    const testing = std.testing;
    try testing.expectError(error.VariableDependency, normalizeDepName(testing.allocator, "$pkgname"));
    try testing.expectError(error.VariableDependency, normalizeDepName(testing.allocator, "$pkgver"));
}

test "isGitPkg - only true for a -git suffix" {
    const testing = std.testing;
    try testing.expect(isGitPkg("neovim-git"));
    try testing.expect(isGitPkg("foo-git"));
    try testing.expect(!isGitPkg("neovim"));
    try testing.expect(!isGitPkg("foo-git-tools")); // "-git" must be the suffix
    try testing.expect(!isGitPkg(""));
}

test "artifactNameForPkg - matches only full leading components" {
    const testing = std.testing;
    try testing.expect(artifactNameForPkg("foo", "foo"));
    try testing.expect(artifactNameForPkg("foo-2.0-1-x86_64.pkg.tar.zst", "foo"));
    // "foo" must not also match a different package named "foobar-...".
    try testing.expect(!artifactNameForPkg("foobar-2.0-1-x86_64.pkg.tar.zst", "foo"));
    try testing.expect(!artifactNameForPkg("foo", "foobar"));
    try testing.expect(artifactNameForPkg("neovim-git-r100.abc-x86_64.pkg.tar.zst", "neovim-git"));
    try testing.expect(!artifactNameForPkg("foo-lib-1.0-1-x86_64.pkg.tar.zst", "foo-l"));
}

test "printBarePkgbuildFields includes reviewed assignments and functions" {
    const testing = std.testing;
    const pkgbuild_contents =
        \\pkgname=testpkg
        \\source=('https://example.com/testpkg.tar.gz')
        \\install=testpkg.install
        \\install() {
        \\  install -Dm755 testpkg "$pkgdir/usr/bin/testpkg"
        \\}
    ;

    var output_buffer: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&output_buffer);
    try printBarePkgbuildFields(testing.allocator, &writer, pkgbuild_contents);

    const output = writer.buffered();
    try testing.expect(mem.startsWith(u8, output, "  source 'https://example.com/testpkg.tar.gz'\n\n"));
    try testing.expect(mem.indexOf(u8, output, "install testpkg.install") != null);
    try testing.expect(mem.indexOf(u8, output, "install()") != null);
    try testing.expect(mem.indexOf(u8, output, "pkgname") == null);
}

test "extractTarGz - strips the top-level snapshot directory" {
    const testing = std.testing;
    const io = testing.io;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Build a fake AUR snapshot tree with a single top-level directory.
    try tmp.dir.createDirPath(io, "pkg-1.0/nested");
    var src = try tmp.dir.openDir(io, "pkg-1.0", .{});
    defer src.close(io);
    try src.writeFile(io, .{ .sub_path = "PKGBUILD", .data = "pkgname=pkg\n" });
    try src.writeFile(io, .{ .sub_path = "nested/hook.sh", .data = "#!/bin/sh\necho hi\n" });

    // Create pkg.tar.gz using the same tools zur relies on at runtime. Change
    // into the temp dir first so the archive is always written there (the
    // archive name is relative to the process's working directory, which can
    // differ from where testing.tmpDir created the dir).
    const rel_tmp = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(rel_tmp);
    const tar_run = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "sh", "-c", "cd \"$1\" && tar czf pkg.tar.gz pkg-1.0", "sh", rel_tmp },
    });
    defer allocator.free(tar_run.stdout);
    defer allocator.free(tar_run.stderr);
    if (tar_run.term != .exited or tar_run.term.exited != 0) return error.TarCreate;

    // Remove the source tree so only the archive remains in the dir.
    try tmp.dir.deleteTree(io, "pkg-1.0");

    try extractTarGz(io, tmp.dir, "pkg.tar.gz");

    const pkgbuild = try tmp.dir.readFileAlloc(io, "PKGBUILD", allocator, .unlimited);
    defer allocator.free(pkgbuild);
    try testing.expectEqualStrings("pkgname=pkg\n", pkgbuild);

    const hook = try tmp.dir.readFileAlloc(io, "nested/hook.sh", allocator, .unlimited);
    defer allocator.free(hook);
    try testing.expectEqualStrings("#!/bin/sh\necho hi\n", hook);

    const leftover = tmp.dir.openFile(io, "pkg.tar.gz", .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    try testing.expect(leftover == null);
    if (leftover) |f| f.close(io);
}
