//! Install and update AUR packages: version compare, deps, build, and pacman -U.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const log = std.log.scoped(.pacman);
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Dir = Io.Dir;
const File = Io.File;

// For `tcgetpgrp`/`tcsetpgrp` (terminal foreground process group control),
// which the libc-backed `std.posix` layer doesn't expose. zur links libc for
// libalpm, so these come straight from libc.
const c = @cImport({
    @cInclude("unistd.h");
});

const Alpm = @import("Alpm.zig");
const aur = @import("aur.zig");
const color = @import("color.zig");
const Request = @import("Request.zig");
const Pkgbuild = @import("Pkgbuild.zig");
const Snapshot = @import("Pacman/Snapshot.zig");

const Pacman = @This();

const ErrorSet =
    Allocator.Error ||
    Alpm.Error ||
    aur.Error ||
    Dir.OpenError ||
    Dir.CreateDirPathError ||
    Dir.DeleteTreeError ||
    Dir.DeleteFileError ||
    Dir.ReadFileAllocError ||
    Dir.ReadLinkError ||
    Dir.WriteFileError ||
    Dir.RenameError ||
    File.OpenError ||
    File.StatError ||
    std.process.SpawnError ||
    std.process.RunError ||
    std.process.Child.WaitError ||
    Snapshot.Error ||
    std.json.ParseError(std.json.Scanner) ||
    Io.Reader.DelimiterError ||
    error{
        NoHomeEnvVarFound,
        PkgsAlreadyLoaded,
        ZeroResultsFromAurQuery,
        NonzeroStatus,
        EmptyDependency,
        VariableDependency,
        TarCreate,
        UnsatisfiedDependency,
        DependencyCycle,
        DependencyConflict,
        MissingPackageOutput,
        DuplicatePackageOutput,
        UserDeclined,
    };
pub const Error = ErrorSet;

allocator: Allocator,
io: Io,
environ_map: *const std.process.Environ.Map,
pkgs: std.StringHashMapUnmanaged(Package) = .empty,
zur_path: []const u8,
zur_pkg_dir: []const u8,
// Package bases already resolved this run, so dep recursion cannot loop.
aur_deps_done: std.StringHashMapUnmanaged(enum { visiting, done }) = .empty,
aur_cache: std.StringHashMapUnmanaged(?aur.Info) = .empty,
provider_cache: std.StringHashMapUnmanaged([]aur.Info) = .empty,
// Lazily-initialized libalpm handle (see getAlpm).
alpm_state: ?Alpm = null,
// Persisted HTTP client (see getRequest).
request_state: ?Request = null,

stdout_buffer: [4096]u8 = undefined,
stdout_writer: ?File.Writer = null,
stdin_buffer: [4096]u8 = undefined,
stdin_reader: ?File.Reader = null,

/// One local/AUR package tracked for install or update.
const Package = struct {
    base_name: ?[]const u8 = null,
    installed_version: ?[]const u8 = null,
    requested: bool = false,
    aur_version: ?[]const u8 = null,
    requires_update: bool = false,
};

// Larger diffs use a linear-memory full-file display.
const max_diff_cells: usize = 1024 * 1024;

// Names and package metadata are borrowed for the Pacman lifetime. Output
// artifact paths and both containers are owned by this build record.
const PendingPackage = struct {
    name: []const u8,
    pkg: Package,
    outputs: std.StringArrayHashMapUnmanaged(Output) = .empty,
    dependencies: std.StringHashMapUnmanaged(void) = .empty,
    snapshot: ?Snapshot = null,

    const Output = struct {
        pkg: Package,
        artifact: ?[]u8 = null,
        reason: Alpm.InstallReason = .explicit,
        was_installed: bool = false,
    };

    fn base(self: PendingPackage) []const u8 {
        return self.pkg.base_name orelse self.name;
    }

    fn isCached(self: PendingPackage) bool {
        if (self.outputs.count() == 0) return false;
        for (self.outputs.values()) |output| {
            if (output.artifact == null) return false;
        }
        return true;
    }

    fn deinit(self: *PendingPackage, allocator: Allocator) void {
        for (self.outputs.values()) |output| {
            if (output.artifact) |artifact| allocator.free(artifact);
        }
        if (self.snapshot) |*snapshot| snapshot.deinit(allocator);
        self.outputs.deinit(allocator);
        self.dependencies.deinit(allocator);
        self.* = undefined;
    }
};

fn deinitPendingPackages(allocator: Allocator, pending: *std.ArrayList(PendingPackage)) void {
    for (pending.items) |*item| item.deinit(allocator);
    pending.deinit(allocator);
}

// `existing_artifact` ownership transfers to the named output on success.
fn queuePendingPackage(
    allocator: Allocator,
    pending: *std.ArrayList(PendingPackage),
    queued_bases: *std.StringHashMapUnmanaged(usize),
    pkg_name: []const u8,
    pkg: Package,
    existing_artifact: ?[]u8,
) !void {
    const base = pkg.base_name orelse pkg_name;
    if (queued_bases.get(base)) |index| {
        const item = &pending.items[index];
        const output = try item.outputs.getOrPut(allocator, pkg_name);
        if (!output.found_existing) output.value_ptr.* = .{ .pkg = pkg };
        if (pkg.installed_version != null or pkg.requested or pkg.requires_update) {
            output.value_ptr.pkg = pkg;
            item.name = pkg_name;
            item.pkg = pkg;
        }
        if (existing_artifact) |artifact| {
            if (output.value_ptr.artifact) |old| allocator.free(old);
            output.value_ptr.artifact = artifact;
            output.value_ptr.pkg = pkg;
            item.name = pkg_name;
            item.pkg = pkg;
        }
        return;
    }

    try pending.ensureUnusedCapacity(allocator, 1);
    try queued_bases.ensureUnusedCapacity(allocator, 1);
    var outputs: std.StringArrayHashMapUnmanaged(PendingPackage.Output) = .empty;
    errdefer outputs.deinit(allocator);
    try outputs.put(allocator, pkg_name, .{ .pkg = pkg, .artifact = existing_artifact });
    const index = pending.items.len;
    pending.appendAssumeCapacity(.{ .name = pkg_name, .pkg = pkg, .outputs = outputs });
    queued_bases.putAssumeCapacityNoClobber(base, index);
}

const Visit = enum { unseen, visiting, done };

fn orderPendingPackages(
    allocator: Allocator,
    pending: *std.ArrayList(PendingPackage),
    bases: *std.StringHashMapUnmanaged(usize),
) Error!void {
    const visits = try allocator.alloc(Visit, pending.items.len);
    defer allocator.free(visits);
    @memset(visits, .unseen);
    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(allocator);
    try order.ensureTotalCapacity(allocator, pending.items.len);
    for (pending.items, 0..) |_, index| {
        try visitPendingPackage(pending.items, bases.*, visits, &order, index);
    }
    var ordered: std.ArrayList(PendingPackage) = .empty;
    try ordered.ensureTotalCapacity(allocator, pending.items.len);
    for (order.items, 0..) |index, position| {
        const item = pending.items[index];
        ordered.appendAssumeCapacity(item);
        bases.getPtr(item.base()).?.* = position;
    }
    // Ownership of each build's containers moves to the ordered list.
    pending.deinit(allocator);
    pending.* = ordered;
}

fn visitPendingPackage(
    pending: []const PendingPackage,
    bases: std.StringHashMapUnmanaged(usize),
    visits: []Visit,
    order: *std.ArrayList(usize),
    index: usize,
) Error!void {
    switch (visits[index]) {
        .done => return,
        .visiting => return error.DependencyCycle,
        .unseen => {},
    }
    visits[index] = .visiting;
    var dependencies = pending[index].dependencies.keyIterator();
    while (dependencies.next()) |base| {
        // Every edge is recorded only after its dependency has been queued.
        try visitPendingPackage(pending, bases, visits, order, bases.get(base.*).?);
    }
    visits[index] = .done;
    order.appendAssumeCapacity(index);
}

// Architecture component in built package filenames (native compile target).
fn machineArch() []const u8 {
    return switch (builtin.cpu.arch) {
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
fn shouldUpdate(name: []const u8, installed_version: ?[]const u8, requested: bool, remote_newer: bool) bool {
    // pkgver() can advance development versions beyond the RPC version.
    return requested or installed_version == null or isGitPkg(name) or remote_newer;
}

// Bare package name from an AUR Depends/MakeDepends string.
// "foo>=1.2.3" -> "foo", "foo|bar" -> "foo", "$pkgname" -> error.
// The caller owns the returned slice.
fn normalizeDepName(allocator: Allocator, dep: []const u8) ![]const u8 {
    const trimmed = mem.trim(u8, dep, " \t");
    if (trimmed.len == 0) return error.EmptyDependency;

    // Take the first alternative of an OR-list ("a|b" means "a" or "b").
    const first = if (mem.findScalar(u8, trimmed, '|')) |idx| trimmed[0..idx] else trimmed;

    // Strip a version constraint suffix: "foo>=1.0", "foo=1.0", "foo<2".
    const ops = [_][]const u8{
        ">=",
        "<=",
        "==",
        "=",
        ">",
        "<",
    };
    var name = mem.trim(u8, first, " \t");
    for (ops) |op| {
        if (mem.find(u8, name, op)) |idx| {
            name = mem.trim(u8, name[0..idx], " \t");
            break;
        }
    }
    if (name.len == 0) return error.EmptyDependency;

    // A literal "$" (e.g. "$pkgname" / "$pkgver") is a self-reference we
    // can't resolve through the AUR; the dependency isn't an external package.
    if (mem.findScalar(u8, name, '$') != null) return error.VariableDependency;

    const value = try allocator.dupe(u8, name);
    return value;
}

const extractTarGz = Snapshot.extractTarGz;

/// Create `~/.zur/.pkg` and an empty package set. Use an arena allocator
/// released after deinit: RPC metadata and installed-package strings live for the run.
pub fn init(
    allocator: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
) Error!Pacman {
    const home = environ_map.get("HOME") orelse return error.NoHomeEnvVarFound;
    const zur_dir = ".zur";

    const zur_path = try Dir.path.join(allocator, &.{ home, zur_dir });
    errdefer allocator.free(zur_path);
    const pkg_dir = try Dir.path.join(allocator, &.{ zur_path, ".pkg" });
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
    // Package names and metadata are borrowed from argv, libalpm, or the run arena.
    self.pkgs.deinit(self.allocator);
    self.aur_deps_done.deinit(self.allocator);
    var cached = self.aur_cache.keyIterator();
    while (cached.next()) |key| self.allocator.free(key.*);
    self.aur_cache.deinit(self.allocator);
    var providers = self.provider_cache.iterator();
    while (providers.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.provider_cache.deinit(self.allocator);
    if (self.alpm_state) |*state| state.deinit();
    if (self.request_state) |*req| req.deinit();
    self.* = undefined;
}

fn getAlpm(self: *Pacman) !*Alpm {
    if (self.alpm_state == null) {
        self.alpm_state = try Alpm.init(self.allocator, .{});
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
    w.flush() catch |err| log.debug("failed to flush stdout: {}", .{err});
}

/// Resolve, review, and install requested names, or update foreign packages
/// when names is empty. Metadata is allocated for this Pacman run.
pub fn installOrUpdate(self: *Pacman, names: []const []const u8) Error!void {
    if (names.len == 0) {
        try self.fetchLocalPackages();
    } else {
        try self.setInstallPackages(names);
    }
    try self.fetchRemoteAurVersions();
    try self.compareVersions();
    try self.processOutOfDate();
}

/// Load installed foreign (AUR) packages from libalpm into `pkgs`.
fn fetchLocalPackages(self: *Pacman) Error!void {
    if (self.pkgs.count() != 0) {
        return error.PkgsAlreadyLoaded;
    }

    const foreign = try (try self.getAlpm()).fetchForeignPackages();
    // The name/version strings are arena-owned (see init's allocator), so
    // they stay alive for the whole run and the pkg map keys/versions may
    // borrow them; nothing is freed individually here.
    for (foreign) |pkg_info| {
        try self.pkgs.putNoClobber(self.allocator, pkg_info.name, .{ .installed_version = pkg_info.version });
    }
}

/// Queue explicit requests while retaining any currently installed version.
fn setInstallPackages(self: *Pacman, pkg_list: []const []const u8) Error!void {
    if (self.pkgs.count() != 0) {
        return error.PkgsAlreadyLoaded;
    }

    for (pkg_list) |pkg_name| {
        const entry = try self.pkgs.getOrPut(self.allocator, pkg_name);
        if (entry.found_existing) continue;
        errdefer _ = self.pkgs.remove(pkg_name);
        entry.value_ptr.* = .{
            .installed_version = try (try self.getAlpm()).installedVersion(pkg_name),
            .requested = true,
        };
    }
}

/// Fill each tracked package's `aur_version` (and `base_name` if split).
fn fetchRemoteAurVersions(self: *Pacman) Error!void {
    if (self.pkgs.count() == 0) return;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(self.allocator);
    var keys = self.pkgs.keyIterator();
    while (keys.next()) |name| try names.append(self.allocator, name.*);
    const response = try aur.queryAll(self.allocator, self.getRequest(), names.items);
    defer self.allocator.free(response.results);
    try self.cacheAurResponse(names.items, response.results);
    if (response.resultcount == 0) {
        return error.ZeroResultsFromAurQuery;
    }
    for (response.results) |result| {
        // Skip results the AUR returns for packages we didn't ask about
        // (e.g. a dependency that also came back) rather than crashing.
        const curr_pkg = self.pkgs.getPtr(result.name) orelse continue;
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
fn compareVersions(self: *Pacman) Error!void {
    var any_updates = false;
    var pkgs_iter = self.pkgs.iterator();
    while (pkgs_iter.next()) |pkg| {
        pkg.value_ptr.requires_update = false;
        const local_version = pkg.value_ptr.installed_version;

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
        const remote_newer = if (local_version) |installed|
            try Alpm.isNewerThan(self.allocator, remote_version, installed)
        else
            false;
        if (shouldUpdate(pkg.key_ptr.*, local_version, pkg.value_ptr.requested, remote_newer)) {
            pkg.value_ptr.*.requires_update = true;
            any_updates = true;
        }
    }

    if (!any_updates) return;
    pkgs_iter = self.pkgs.iterator();
    try self.print("{s}::{s} Packages to be installed or updated:\n", .{
        color.bold_foreground_blue,
        color.reset,
    });
    while (pkgs_iter.next()) |pkg| {
        if (pkg.value_ptr.*.requires_update) {
            try self.print(" {s}\n", .{pkg.key_ptr.*});
        }
    }
}

/// Download, review, build, and install every package marked for update.
fn processOutOfDate(self: *Pacman) Error!void {
    try Dir.cwd().createDirPath(self.io, self.zur_path);

    // Collect missing AUR dependencies in postorder so the build phase remains
    // dependency-first even though every snapshot is downloaded up front.
    var pending: std.ArrayList(PendingPackage) = .empty;
    defer deinitPendingPackages(self.allocator, &pending);
    var queued_bases: std.StringHashMapUnmanaged(usize) = .empty;
    defer queued_bases.deinit(self.allocator);

    try self.planPackages(&pending, &queued_bases);
    if (pending.items.len == 0) {
        try self.print("{s}::{s} {s}All AUR packages are up-to-date.{s}\n", .{
            color.bold_foreground_blue,
            color.reset,
            color.bold,
            color.reset,
        });
        return;
    }

    for (pending.items) |*item| {
        for (item.outputs.keys(), item.outputs.values()) |name, *output| {
            output.artifact = try self.findExistingPackage(name, output.pkg.aur_version.?);
        }
        if (!item.isCached()) try self.downloadAndExtractPackage(item);
    }
    for (pending.items) |*item| {
        try self.print(":: Selected outputs from {s}:\n", .{item.base()});
        for (item.outputs.keys(), item.outputs.values()) |name, output| {
            try self.print("  {s} ({t})\n", .{ name, output.reason });
        }
        if (item.isCached()) {
            try self.installArtifacts(item, self);
        } else {
            try self.compareUpdateAndInstall(item);
        }
    }
}

fn planPackages(
    self: *Pacman,
    pending: *std.ArrayList(PendingPackage),
    queued_bases: *std.StringHashMapUnmanaged(usize),
) Error!void {
    var roots = self.pkgs.iterator();
    while (roots.next()) |pkg| {
        if (!pkg.value_ptr.*.requires_update) continue;
        try self.queuePackageWithDeps(pending, queued_bases, pkg.key_ptr.*, pkg.value_ptr.*);
    }
    // Additional outputs may introduce dependencies after their base was first
    // queued. Sort the merged base graph only after visiting every root.
    try orderPendingPackages(self.allocator, pending, queued_bases);
    const db = try self.getAlpm();
    for (pending.items) |*item| {
        for (item.outputs.keys(), item.outputs.values()) |name, *output| {
            const existing = try db.installedReason(name);
            output.was_installed = existing != null;
            output.reason = existing orelse if (self.pkgs.contains(name)) .explicit else .dependency;
        }
    }
}

// Visit all scheduled AUR dependencies before appending their consumer.
fn queuePackageWithDeps(
    self: *Pacman,
    pending: *std.ArrayList(PendingPackage),
    queued_bases: *std.StringHashMapUnmanaged(usize),
    pkg_name: []const u8,
    pkg: Package,
) Error!void {
    if (self.aur_deps_done.get(pkg_name)) |visit| {
        if (visit == .visiting) return error.DependencyCycle;
        try queuePendingPackage(self.allocator, pending, queued_bases, pkg_name, pkg, null);
        return;
    }
    try self.aur_deps_done.put(self.allocator, pkg_name, .visiting);
    errdefer _ = self.aur_deps_done.remove(pkg_name);

    var dependency_bases: std.ArrayList([]const u8) = .empty;
    defer dependency_bases.deinit(self.allocator);
    if (try self.getAurInfo(pkg_name)) |info| {
        const dep_lists = [_]?[][]const u8{
            info.depends,
            info.make_depends,
            info.check_depends,
        };
        try self.prefetchDependencies(&dep_lists);
        for (dep_lists) |maybe_list| {
            for (maybe_list orelse continue) |dep| {
                const dep_info = (try self.resolveDependency(dep)) orelse continue;
                var dep_pkg = if (self.pkgs.get(dep_info.name)) |tracked|
                    tracked
                else
                    Package{ .installed_version = try (try self.getAlpm()).installedVersion(dep_info.name) };
                dep_pkg.aur_version = dep_info.version;
                if (!mem.eql(u8, dep_info.name, dep_info.package_base)) {
                    dep_pkg.base_name = dep_info.package_base;
                }
                if (mem.eql(u8, dep_info.package_base, info.package_base)) {
                    if (self.aur_deps_done.get(dep_info.name) == .visiting) {
                        try queuePendingPackage(self.allocator, pending, queued_bases, dep_info.name, dep_pkg, null);
                        continue;
                    }
                } else {
                    try dependency_bases.append(self.allocator, dep_info.package_base);
                }
                try self.queuePackageWithDeps(
                    pending,
                    queued_bases,
                    dep_info.name,
                    dep_pkg,
                );
            }
        }
    }
    try queuePendingPackage(self.allocator, pending, queued_bases, pkg_name, pkg, null);
    const index = queued_bases.get(pkg.base_name orelse pkg_name).?;
    for (dependency_bases.items) |base| {
        try pending.items[index].dependencies.put(self.allocator, base, {});
    }
    self.aur_deps_done.getPtr(pkg_name).?.* = .done;
}

fn infoSatisfies(self: *Pacman, dependency: []const u8, info: aur.Info) Error!bool {
    return Alpm.satisfies(
        self.allocator,
        dependency,
        info.name,
        info.version,
        info.provides orelse &.{},
    );
}

// Null means the installed system or makepkg's binary-repository resolver can
// satisfy this edge. A returned package must precede its consumer in our plan.
fn resolveDependency(self: *Pacman, dependency: []const u8) Error!?aur.Info {
    const db = try self.getAlpm();
    if (try db.installedSatisfier(dependency)) |installed_name| {
        if (self.pkgs.get(installed_name)) |pkg| {
            if (pkg.requires_update) {
                const info = (try self.getAurInfo(installed_name)) orelse return error.UnsatisfiedDependency;
                if (!try self.infoSatisfies(dependency, info)) return error.DependencyConflict;
                return info;
            }
        }
        return null;
    }

    // Prefer a root already requested for installation, including providers.
    var roots = self.pkgs.iterator();
    while (roots.next()) |entry| {
        if (!entry.value_ptr.*.requires_update) continue;
        const info = (try self.getAurInfo(entry.key_ptr.*)) orelse continue;
        if (try self.infoSatisfies(dependency, info)) return info;
    }
    if (try db.syncSatisfies(dependency)) return null;

    const name = try normalizeDepName(self.allocator, dependency);
    defer self.allocator.free(name);
    if (try self.getAurInfo(name)) |info| {
        if (try self.infoSatisfies(dependency, info)) return info;
    }
    const providers = try self.getProviders(name);
    for (providers) |info| {
        if (!try self.infoSatisfies(dependency, info)) continue;
        try self.print(":: {s} provides {s}\n", .{ info.name, dependency });
        return info;
    }
    try self.print("Cannot satisfy dependency: {s}\n", .{dependency});
    return error.UnsatisfiedDependency;
}

fn getProviders(self: *Pacman, name: []const u8) Error![]aur.Info {
    if (self.provider_cache.get(name)) |infos| return infos;
    const response = try aur.search(self.allocator, self.getRequest(), name, .provides);
    defer self.allocator.free(response.results);
    var infos: std.ArrayList(aur.Info) = .empty;
    defer infos.deinit(self.allocator);
    for (response.results) |result| {
        if (try self.getAurInfo(result.name)) |info| try infos.append(self.allocator, info);
    }
    // RPC result order is not a provider-selection policy.
    std.mem.sort(aur.Info, infos.items, {}, struct {
        fn lessThan(_: void, left: aur.Info, right: aur.Info) bool {
            return mem.lessThan(u8, left.name, right.name);
        }
    }.lessThan);
    const owned = try infos.toOwnedSlice(self.allocator);
    errdefer self.allocator.free(owned);
    const key = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(key);
    try self.provider_cache.put(self.allocator, key, owned);
    return owned;
}

fn prefetchDependencies(self: *Pacman, lists: []const ?[][]const u8) Error!void {
    var missing: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer {
        for (missing.keys()) |name| self.allocator.free(name);
        missing.deinit(self.allocator);
    }
    for (lists) |maybe_list| {
        for (maybe_list orelse continue) |dependency| {
            const db = try self.getAlpm();
            if (try db.installedSatisfier(dependency) != null or try db.syncSatisfies(dependency)) continue;
            const name = try normalizeDepName(self.allocator, dependency);
            errdefer self.allocator.free(name);
            if (self.aur_cache.contains(name) or missing.contains(name)) {
                self.allocator.free(name);
                continue;
            }
            try missing.putNoClobber(self.allocator, name, {});
        }
    }
    if (missing.count() == 0) return;
    const response = try aur.queryAll(self.allocator, self.getRequest(), missing.keys());
    defer self.allocator.free(response.results);
    try self.cacheAurResponse(missing.keys(), response.results);
}

// Only call after every batch succeeds; outages must not become cached absence.
fn cacheAurResponse(self: *Pacman, names: []const []const u8, results: []const aur.Info) Error!void {
    for (names) |name| try self.cacheAurInfo(name, null);
    for (results) |info| try self.cacheAurInfo(info.name, info);
}

fn cacheAurInfo(self: *Pacman, name: []const u8, info: ?aur.Info) Error!void {
    if (self.aur_cache.getPtr(name)) |cached| {
        cached.* = info;
        return;
    }
    const key = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(key);
    try self.aur_cache.putNoClobber(self.allocator, key, info);
}

fn getAurInfo(self: *Pacman, name: []const u8) Error!?aur.Info {
    if (self.aur_cache.get(name)) |cached| return cached;
    const info = try aur.queryName(self.allocator, self.getRequest(), name);
    try self.cacheAurInfo(name, info);
    return info;
}

// Return an owned absolute path for an exact package/version/native-arch match.
// Archive metadata is authoritative; PKGEXT and filename spelling may vary.
fn findExistingPackage(self: *Pacman, pkg_name: []const u8, version: []const u8) !?[]u8 {
    if (isGitPkg(pkg_name)) return null;
    const directory = try Dir.path.join(self.allocator, &.{ self.zur_pkg_dir, pkg_name });
    defer self.allocator.free(directory);
    if (try self.findCachedInDir(directory, pkg_name, version)) |path| return path;
    // Migrate only a verified requested artifact from the former flat cache.
    const legacy = (try self.findCachedInDir(self.zur_pkg_dir, pkg_name, version)) orelse return null;
    defer self.allocator.free(legacy);
    return try self.moveArchiveToCache(pkg_name, legacy);
}

fn findCachedInDir(self: *Pacman, directory: []const u8, name: []const u8, version: []const u8) !?[]u8 {
    var dir = Dir.openDirAbsolute(self.io, directory, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(self.io);
    var entries = dir.iterate();
    while (try entries.next(self.io)) |entry| {
        if (entry.kind != .file or mem.endsWith(u8, entry.name, ".sig") or
            mem.indexOf(u8, entry.name, ".pkg.tar") == null) continue;
        const path = try Dir.path.join(self.allocator, &.{ directory, entry.name });
        var keep = false;
        defer if (!keep) self.allocator.free(path);
        var archive = (try self.getAlpm()).readArchive(path) catch |err| switch (err) {
            error.InvalidPackageArchive => continue,
            else => return err,
        };
        defer archive.deinit(self.allocator);
        if (!mem.eql(u8, archive.name, name) or !mem.eql(u8, archive.version, version)) continue;
        if (!mem.eql(u8, archive.arch, "any") and !mem.eql(u8, archive.arch, machineArch())) continue;
        keep = true;
        return path;
    }
    return null;
}

fn moveArchiveToCache(self: *Pacman, name: []const u8, source: []const u8) ![]u8 {
    const parent = try Dir.path.join(self.allocator, &.{ self.zur_pkg_dir, name });
    defer self.allocator.free(parent);
    try Dir.cwd().createDirPath(self.io, parent);
    const dest = try Dir.path.join(self.allocator, &.{ parent, Dir.path.basename(source) });
    errdefer self.allocator.free(dest);
    const source_sig = try std.fmt.allocPrint(self.allocator, "{s}.sig", .{source});
    defer self.allocator.free(source_sig);
    const dest_sig = try std.fmt.allocPrint(self.allocator, "{s}.sig", .{dest});
    defer self.allocator.free(dest_sig);
    Dir.renameAbsolute(source_sig, dest_sig, self.io) catch |err| switch (err) {
        error.FileNotFound => {
            Dir.cwd().deleteFile(self.io, dest_sig) catch |delete_err| switch (delete_err) {
                error.FileNotFound => {},
                else => return delete_err,
            };
        },
        else => return err,
    };
    try Dir.renameAbsolute(source, dest, self.io);
    return dest;
}

fn snapshotPath(self: *Pacman, base: []const u8, version: []const u8) Allocator.Error![]u8 {
    return Dir.path.join(self.allocator, &.{ self.zur_path, ".src", base, version });
}

fn downloadAndExtractPackage(self: *Pacman, item: *PendingPackage) !void {
    item.snapshot = try self.downloadAndExtractPackageUsing(item.name, &item.pkg, self.getRequest());
}

fn downloadAndExtractPackageUsing(self: *Pacman, pkg_name: []const u8, pkg: *const Package, request: anytype) !Snapshot {
    const base = pkg.base_name orelse pkg_name;
    const url = try std.fmt.allocPrint(self.allocator, "{s}/{s}.tar.gz", .{ aur.snapshot, base });
    defer self.allocator.free(url);
    try self.print(" downloading from: {s}{s}{s}\n", .{ color.bold, url, color.reset });
    const bytes = try request.get(url);
    defer self.allocator.free(bytes);
    return Snapshot.create(self.allocator, self.io, self.zur_path, base, bytes);
}

const InstalledSnapshot = struct {
    version: []const u8,
    archive: []const u8,
};

fn installedSnapshotPath(self: *Pacman, base: []const u8, name: []const u8) ![]u8 {
    const filename = try std.fmt.allocPrint(self.allocator, ".installed-{s}.json", .{name});
    defer self.allocator.free(filename);
    return self.snapshotPath(base, filename);
}

fn loadInstalledSnapshot(self: *Pacman, item: *const PendingPackage) !?Snapshot {
    const installed_version = item.pkg.installed_version orelse return null;
    const path = try self.installedSnapshotPath(item.base(), item.name);
    defer self.allocator.free(path);
    const bytes = Dir.cwd().readFileAlloc(self.io, path, self.allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer self.allocator.free(bytes);
    const parsed = std.json.parseFromSlice(InstalledSnapshot, self.allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    if (!mem.eql(u8, parsed.value.version, installed_version)) return null;
    const name = parsed.value.archive;
    if (name.len != 71 or !mem.endsWith(u8, name, ".tar.gz")) return null;
    for (name[0..64]) |char| if (!std.ascii.isHex(char)) return null;
    const archive_path = try self.snapshotPath(item.base(), name);
    defer self.allocator.free(archive_path);
    const archive = Dir.cwd().readFileAlloc(self.io, archive_path, self.allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer self.allocator.free(archive);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(archive, &digest, .{});
    if (!mem.eql(u8, name[0..64], &std.fmt.bytesToHex(digest, .lower))) return null;
    return try Snapshot.create(self.allocator, self.io, self.zur_path, item.base(), archive);
}

fn recordInstalledSnapshot(self: *Pacman, item: *const PendingPackage) !void {
    const snapshot = item.snapshot orelse return;
    for (item.outputs.keys(), item.outputs.values()) |name, output| {
        var archive = try (try self.getAlpm()).readArchive(output.artifact.?);
        defer archive.deinit(self.allocator);
        const record: InstalledSnapshot = .{
            .version = archive.version,
            .archive = Dir.path.basename(snapshot.archive_path),
        };
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, record, .{});
        defer self.allocator.free(bytes);
        const path = try self.installedSnapshotPath(item.base(), name);
        defer self.allocator.free(path);
        const temporary = try std.fmt.allocPrint(self.allocator, "{s}.pending", .{path});
        defer self.allocator.free(temporary);
        defer Dir.cwd().deleteFile(self.io, temporary) catch {};
        try Dir.cwd().writeFile(self.io, .{ .sub_path = temporary, .data = bytes });
        try Dir.renameAbsolute(temporary, path, self.io);
    }
}

fn compareUpdateAndInstall(self: *Pacman, item: *PendingPackage) !void {
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    var previous = try self.loadInstalledSnapshot(item);
    defer if (previous) |*snapshot| snapshot.deinit(self.allocator);
    var old_files = if (previous) |snapshot|
        try self.readSnapshotFiles(allocator, snapshot.source_path)
    else
        SourceFiles.empty;
    defer deinitSnapshotFiles(allocator, &old_files);
    var new_files = try self.readSnapshotFiles(allocator, item.snapshot.?.source_path);
    defer deinitSnapshotFiles(allocator, &new_files);

    // Without an installed-source baseline, display every new source file.
    if (old_files.count() == 0 or new_files.count() == 0 or
        old_files.get("PKGBUILD") == null or new_files.get("PKGBUILD") == null)
    {
        return self.bareInstall(item, new_files);
    }

    const at_least_one_diff = try self.reviewSnapshotChanges(allocator, old_files, new_files);
    if (at_least_one_diff) {
        try self.confirmInstall("\nContinue? [Y/n]: ");
    } else {
        try self.print("{s}::{s} No snapshot changes found\n", .{
            color.foreground_blue,
            color.reset,
        });
    }
    try self.install(item);
}

const SourceFile = struct {
    contents: []const u8,
    kind: File.Kind = .file,
    mode: u32 = 0o644,
};
const SourceFiles = std.StringHashMapUnmanaged(SourceFile);

fn reviewSnapshotChanges(
    self: *Pacman,
    allocator: Allocator,
    old_files: SourceFiles,
    new_files: SourceFiles,
) !bool {
    var changed = false;
    var new_iter = new_files.iterator();
    while (new_iter.next()) |file| {
        const old = old_files.get(file.key_ptr.*);
        const new = file.value_ptr.*;
        if (old) |previous| {
            if (previous.kind == new.kind and previous.mode == new.mode and
                mem.eql(u8, previous.contents, new.contents)) continue;
            if (previous.kind != new.kind or previous.mode != new.mode) {
                try self.print(":: {s}: {t} mode {o} -> {t} mode {o}\n", .{
                    file.key_ptr.*, previous.kind, previous.mode, new.kind, new.mode,
                });
            }
        } else {
            try self.print(":: Added {s}: {t} mode {o}\n", .{ file.key_ptr.*, new.kind, new.mode });
        }
        changed = true;
        if (mem.eql(u8, file.key_ptr.*, "PKGBUILD") and new.kind == .file and
            (old == null or old.?.kind == .file))
        {
            try self.printPkgbuildChanges(allocator, if (old) |previous| previous.contents else "", new.contents);
        } else {
            try self.printDiff(allocator, file.key_ptr.*, if (old) |previous| previous.contents else "", new.contents);
        }
    }
    var old_iter = old_files.iterator();
    while (old_iter.next()) |file| {
        if (new_files.contains(file.key_ptr.*)) continue;
        changed = true;
        try self.printDiff(allocator, file.key_ptr.*, file.value_ptr.contents, "");
    }
    return changed;
}

fn printPkgbuildChanges(
    self: *Pacman,
    allocator: Allocator,
    old_contents: []const u8,
    new_contents: []const u8,
) !void {
    if (mem.eql(u8, old_contents, new_contents)) return;
    var old = Pkgbuild.init(allocator, old_contents);
    defer old.deinit();
    var new = Pkgbuild.init(allocator, new_contents);
    defer new.deinit();
    if (!try old.readForReview() or !try new.readForReview() or
        !pkgbuildOrderMatches(old, new))
    {
        return self.printDiff(allocator, "PKGBUILD", old_contents, new_contents);
    }

    try old.indentValues(2);
    try new.indentValues(2);
    for (new.fields.keys(), new.fields.values()) |name, field| {
        if (old.fields.get(name)) |previous| {
            if (mem.eql(u8, previous.source, field.source)) continue;
            // Normalized display values alone cannot reveal changes to array
            // delimiters, comments, or whitespace inside shell words.
            if (mem.eql(u8, previous.value, field.value)) {
                try self.printDiff(allocator, name, previous.source, field.source);
                continue;
            }
        }
        try printUpdatedPkgbuildField(self.stdout(), name, field.value);
    }
    for (old.fields.keys(), old.fields.values()) |name, field| {
        if (new.fields.contains(name)) continue;
        try printPkgbuildFieldChange(self.stdout(), name, field.value, "removed");
    }

    const old_remaining = try old.remainingText(allocator);
    defer allocator.free(old_remaining);
    const new_remaining = try new.remainingText(allocator);
    defer allocator.free(new_remaining);
    if (!mem.eql(u8, old_remaining, new_remaining)) {
        try self.printDiff(allocator, "PKGBUILD comments and spacing", old_remaining, new_remaining);
    }
}

// Reordering assignments or definitions can change their meaning even if every
// individual field is identical. Added and removed fields have their own display.
fn pkgbuildOrderMatches(old: Pkgbuild, new: Pkgbuild) bool {
    var old_index: usize = 0;
    for (new.fields.keys()) |name| {
        if (!old.fields.contains(name)) continue;
        while (old_index < old.fields.count() and
            !new.fields.contains(old.fields.keys()[old_index])) : (old_index += 1)
        {}
        if (!mem.eql(u8, old.fields.keys()[old_index], name)) return false;
        old_index += 1;
    }
    return true;
}

// Print a minimal line-based diff between two file contents using an LCS
// (longest common subsequence) to align unchanged lines.
fn printDiff(
    self: *Pacman,
    allocator: Allocator,
    name: []const u8,
    old_content: []const u8,
    new_content: []const u8,
) !void {
    var old_list: std.ArrayList([]const u8) = .empty;
    defer old_list.deinit(allocator);
    var new_list: std.ArrayList([]const u8) = .empty;
    defer new_list.deinit(allocator);
    var it = mem.splitScalar(u8, old_content, '\n');
    while (it.next()) |line| try old_list.append(allocator, line);
    it = mem.splitScalar(u8, new_content, '\n');
    while (it.next()) |line| try new_list.append(allocator, line);
    const old = old_list.items;
    const new = new_list.items;
    const n = old.len;
    const m = new.len;

    // A byte-size limit cannot bound a line-count matrix. Display both complete
    // versions when alignment would exceed the memory budget.
    if (n + 1 > max_diff_cells / (m + 1)) {
        try self.print(":: {s} changed (complete old/new contents):\n", .{name});
        for (old) |line| try self.print("- {s}\n", .{line});
        for (new) |line| try self.print("+ {s}\n", .{line});
        return;
    }

    // LCS length table. dp[i][j] = length of LCS of old[i..] and new[j..].
    const dp = try allocator.alloc(usize, (n + 1) * (m + 1));
    defer allocator.free(dp);
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

fn isSourceField(name: []const u8) bool {
    return mem.eql(u8, name, "source") or
        (mem.startsWith(u8, name, "source_") and !mem.endsWith(u8, name, "()"));
}

fn printSourceLines(writer: *Io.Writer, value: []const u8, indentation: []const u8) !void {
    var lines = mem.splitScalar(u8, value, '\n');
    while (lines.next()) |raw_line| {
        const line = mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        try writer.print("{s}{s}\n", .{ indentation, line });
    }
}

fn printUpdatedPkgbuildField(
    writer: *Io.Writer,
    name: []const u8,
    value: []const u8,
) !void {
    return printPkgbuildFieldChange(writer, name, value, "updated");
}

fn printPkgbuildFieldChange(
    writer: *Io.Writer,
    name: []const u8,
    value: []const u8,
    change: []const u8,
) !void {
    if (!isSourceField(name)) {
        return writer.print("{s}::{s} {s}{s}{s} was {s}: {s}\n", .{
            color.bold_foreground_blue,
            color.reset,
            color.bold,
            name,
            color.reset,
            change,
            value,
        });
    }

    const normalized = mem.trim(u8, value, " \t\r\n");
    if (normalized.len != 0 and mem.indexOfScalar(u8, normalized, '\n') == null) {
        return writer.print("{s}::{s} {s}{s}{s} was {s}: {s}\n", .{
            color.bold_foreground_blue,
            color.reset,
            color.bold,
            name,
            color.reset,
            change,
            normalized,
        });
    }

    try writer.print("{s}::{s} {s}{s}{s} was {s}:\n", .{
        color.bold_foreground_blue,
        color.reset,
        color.bold,
        name,
        color.reset,
        change,
    });
    try printSourceLines(writer, normalized, "  ");
}

fn printBarePkgbuildSource(
    writer: *Io.Writer,
    name: []const u8,
    value: []const u8,
) !void {
    const normalized = mem.trim(u8, value, " \t\r\n");
    if (normalized.len != 0 and mem.indexOfScalar(u8, normalized, '\n') == null) {
        return writer.print("  {s} {s}\n", .{ name, normalized });
    }

    try writer.print("  {s}\n", .{name});
    try printSourceLines(writer, normalized, "    ");
}

fn printBarePkgbuildFields(
    allocator: Allocator,
    writer: *Io.Writer,
    file_contents: []const u8,
) !void {
    var pkgbuild = Pkgbuild.init(allocator, file_contents);
    defer pkgbuild.deinit();
    if (!try pkgbuild.readForReview()) {
        try writer.writeAll(file_contents);
        if (!mem.endsWith(u8, file_contents, "\n")) try writer.writeByte('\n');
        return;
    }
    try pkgbuild.indentValues(2);

    var printed_source = false;
    if (pkgbuild.fields.get("source")) |source| {
        try printBarePkgbuildSource(writer, "source", source.value);
        printed_source = true;
    }

    var source_arch_name_buffer: [32]u8 = undefined;
    const source_arch_name = try std.fmt.bufPrint(
        &source_arch_name_buffer,
        "source_{s}",
        .{machineArch()},
    );
    if (pkgbuild.fields.get(source_arch_name)) |source| {
        try printBarePkgbuildSource(writer, source_arch_name, source.value);
        printed_source = true;
    }

    if (printed_source) {
        try writer.print("\n", .{});
    }

    var fields_iter = pkgbuild.fields.iterator();
    while (fields_iter.next()) |field| {
        const name = field.key_ptr.*;
        if (mem.eql(u8, name, "source") or mem.eql(u8, name, source_arch_name)) continue;
        // Other architecture lists can be omitted only when their words have
        // no shell expansion. Supporting variables and functions remain visible.
        if (isSourceField(name) and field.value_ptr.*.form == .array and
            mem.indexOfAny(u8, field.value_ptr.*.value, "$`\\[=") == null) continue;
        if (isSourceField(name)) {
            try printBarePkgbuildSource(writer, name, field.value_ptr.*.value);
        } else {
            try writer.print("  {s} {s}\n", .{ name, field.value_ptr.*.value });
        }
    }
}

fn printSourceFile(allocator: Allocator, writer: *Io.Writer, name: []const u8, file: SourceFile) !void {
    try writer.print("\n:: File: {s} ({t}, mode {o})\n", .{ name, file.kind, file.mode });
    if (mem.eql(u8, name, "PKGBUILD") and file.kind == .file) {
        try printBarePkgbuildFields(allocator, writer, file.contents);
    } else {
        try writer.print("{s}\n", .{file.contents});
    }
}

fn bareInstall(
    self: *Pacman,
    item: *PendingPackage,
    pkg_files: SourceFiles,
) !void {
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    var files = pkg_files.iterator();
    while (files.next()) |file| {
        try printSourceFile(scratch.allocator(), self.stdout(), file.key_ptr.*, file.value_ptr.*);
    }

    try self.confirmInstall("Install? [Y/n]: ");
    try self.install(item);
}

fn confirmInstall(self: *Pacman, prompt: []const u8) !void {
    try self.print("{s}", .{prompt});
    const input = try self.stdinReadByte();
    try self.print("\n", .{});
    if (input != 'y' and input != 'Y') return error.UserDeclined;
}

fn install(self: *Pacman, item: *PendingPackage) !void {
    try self.installUsing(item, self);
}

fn installUsing(self: *Pacman, item: *PendingPackage, runner: anytype) !void {
    const full_pkg_dir = (item.snapshot orelse return error.InvalidSnapshot).source_path;
    try runner.execCommand(&.{ "makepkg", "-scC" }, full_pkg_dir);
    const listing = try runner.captureCommand(&.{ "makepkg", "--packagelist" }, full_pkg_dir);
    defer self.allocator.free(listing);
    try self.selectBuiltArtifacts(item, full_pkg_dir, listing);
    try self.installArtifacts(item, runner);
    try self.recordInstalledSnapshot(item);
    for (item.outputs.keys()) |name| try self.removeStaleArtifacts(name, self.zur_pkg_dir);
    const source_root = try Dir.path.join(self.allocator, &.{ self.zur_path, ".src" });
    defer self.allocator.free(source_root);
    try self.removeStaleArtifacts(item.base(), source_root);
}

fn selectBuiltArtifacts(self: *Pacman, item: *PendingPackage, build_dir: []const u8, listing: []const u8) !void {
    for (item.outputs.values()) |*output| {
        if (output.artifact) |old| self.allocator.free(old);
        output.artifact = null;
    }
    var paths = mem.splitScalar(u8, listing, '\n');
    while (paths.next()) |raw_path| {
        const path = mem.trim(u8, raw_path, "\r");
        if (path.len == 0) continue;
        const absolute = try Dir.path.resolve(self.allocator, &.{ build_dir, path });
        errdefer self.allocator.free(absolute);
        const file = Dir.openFileAbsolute(self.io, absolute, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                // makepkg can list an optional debug archive it did not emit.
                self.allocator.free(absolute);
                continue;
            },
            else => return err,
        };
        file.close(self.io);
        var archive = try (try self.getAlpm()).readArchive(absolute);
        defer archive.deinit(self.allocator);
        if (item.outputs.getPtr(archive.name)) |output| {
            if (output.artifact != null) return error.DuplicatePackageOutput;
            output.artifact = absolute;
        } else {
            self.allocator.free(absolute);
        }
    }
    if (!item.isCached()) return error.MissingPackageOutput;

    // Validate the entire selected set before moving anything into the cache.
    for (item.outputs.keys(), item.outputs.values()) |name, *output| {
        const source = output.artifact.?;
        output.artifact = try self.moveArchiveToCache(name, source);
        self.allocator.free(source);
    }
}

fn installArtifacts(self: *Pacman, item: *const PendingPackage, runner: anytype) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(self.allocator);
    var all_dependencies = true;
    for (item.outputs.values()) |output| {
        if (output.reason == .explicit) all_dependencies = false;
    }
    try argv.appendSlice(self.allocator, &.{ "sudo", "pacman", "-U" });
    if (all_dependencies) try argv.append(self.allocator, "--asdeps");
    try argv.append(self.allocator, "--");
    for (item.outputs.values()) |output| {
        try argv.append(self.allocator, output.artifact orelse return error.MissingPackageOutput);
    }

    // Split siblings may depend on one another, so install them in one
    // transaction. Default -U preserves existing reasons. For a mixed group,
    // change only newly installed dependency outputs after that transaction.
    var reasons: std.ArrayList([]const u8) = .empty;
    defer reasons.deinit(self.allocator);
    if (!all_dependencies) {
        try reasons.appendSlice(self.allocator, &.{ "sudo", "pacman", "-D", "--asdeps", "--" });
        for (item.outputs.keys(), item.outputs.values()) |name, output| {
            if (output.reason == .dependency and !output.was_installed) {
                try reasons.append(self.allocator, name);
            }
        }
    }
    try runner.execCommand(argv.items, self.zur_pkg_dir);
    if (reasons.items.len > 5) try runner.execCommand(reasons.items, self.zur_pkg_dir);
}

fn makepkgEnviron(self: *Pacman, cwd: []const u8) !std.process.Environ.Map {
    var environ = try self.environ_map.clone(self.allocator);
    errdefer environ.deinit();
    // Snapshot source paths have the shape .build/<base>/<unique build>.
    const base = Dir.path.basename(Dir.path.dirname(cwd) orelse return error.InvalidSnapshot);
    try environ.put("PKGDEST", cwd);
    try environ.put("BUILDDIR", cwd);
    const shared = [_]struct { variable: []const u8, directory: []const u8 }{
        .{ .variable = "SRCDEST", .directory = ".sources" },
        .{ .variable = "SRCPKGDEST", .directory = ".source_packages" },
        .{ .variable = "LOGDEST", .directory = ".logs" },
    };
    for (shared) |entry| {
        const path = try Dir.path.join(self.allocator, &.{ self.zur_path, entry.directory, base });
        defer self.allocator.free(path);
        try Dir.cwd().createDirPath(self.io, path);
        try environ.put(entry.variable, path);
    }
    const temporary = try Dir.path.join(self.allocator, &.{ cwd, ".tmp" });
    defer self.allocator.free(temporary);
    try Dir.cwd().createDirPath(self.io, temporary);
    try environ.put("TMPDIR", temporary);
    return environ;
}

fn captureCommand(self: *Pacman, argv: []const []const u8, cwd: []const u8) ![]u8 {
    var environ = if (mem.eql(u8, Dir.path.basename(argv[0]), "makepkg"))
        try self.makepkgEnviron(cwd)
    else
        null;
    defer if (environ) |*map| map.deinit();
    const result = try std.process.run(self.allocator, self.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = if (environ) |*map| map else self.environ_map,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(16 * 1024 * 1024),
    });
    errdefer self.allocator.free(result.stdout);
    defer self.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        try self.print("{s}", .{result.stderr});
        return error.NonzeroStatus;
    }
    return result.stdout;
}

fn execCommand(self: *Pacman, argv: []const []const u8, cwd: []const u8) !void {
    var environ = if (mem.eql(u8, Dir.path.basename(argv[0]), "makepkg"))
        try self.makepkgEnviron(cwd)
    else
        null;
    defer if (environ) |*map| map.deinit();
    // Our pending output must be flushed before the child inherits stdout,
    // otherwise it could appear after the child's own output.
    self.flushStdout();

    var child = try std.process.spawn(self.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = if (environ) |*map| map else self.environ_map,
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

fn removeStaleArtifacts(self: *Pacman, pkg_name: []const u8, dir_path: []const u8) !void {
    const package_dir = try Dir.path.join(self.allocator, &.{ dir_path, pkg_name });
    defer self.allocator.free(package_dir);
    var dir = Dir.openDirAbsolute(self.io, package_dir, .{
        .iterate = true,
        .access_sub_paths = false,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
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
        if (node.kind != .file and node.kind != .directory) continue;
        if (mem.endsWith(u8, node.name, ".sig") or mem.startsWith(u8, node.name, ".")) continue;
        const path = try Dir.path.join(self.allocator, &.{ package_dir, node.name });
        defer self.allocator.free(path);
        var f = try Dir.openFileAbsolute(self.io, path, .{});
        defer f.close(self.io);
        const stat = try f.stat(self.io);
        // Store an owned copy of the entry name (dir_iter buffers are
        // reused) so we can delete via a Dir handle after iteration.
        const name_copy = try self.allocator.dupe(u8, node.name);
        errdefer self.allocator.free(name_copy);
        try artifacts.append(self.allocator, .{
            .mtime = stat.mtime.nanoseconds,
            .name = name_copy,
        });
    }

    // Keep the last 3 installed versions of the package.
    if (artifacts.items.len > 3) {
        const less_than = struct {
            fn lessThan(_: void, a: Artifact, b: Artifact) bool {
                return a.mtime < b.mtime;
            }
        };
        std.mem.sort(Artifact, artifacts.items, {}, less_than.lessThan);

        const marked_for_removal = artifacts.items[0 .. artifacts.items.len - 3];
        // deleteTree is relative to a Dir handle, so open the (absolute)
        // parent directory once and delete by entry name rather than
        // resolving an absolute path through cwd.
        var parent = try Dir.openDirAbsolute(self.io, package_dir, .{});
        defer parent.close(self.io);
        for (marked_for_removal) |artifact| {
            try parent.deleteTree(self.io, artifact.name);
            const signature = try std.fmt.allocPrint(self.allocator, "{s}.sig", .{artifact.name});
            defer self.allocator.free(signature);
            parent.deleteFile(self.io, signature) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            try self.print("  {s}->{s} deleting stale file or dir: {s}/{s}\n", .{
                color.foreground_blue,
                color.reset,
                package_dir,
                artifact.name,
            });
        }
    }
}

fn deinitSnapshotFiles(allocator: Allocator, files: *SourceFiles) void {
    var it = files.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.contents);
    }
    files.deinit(allocator);
}

fn snapshotFiles(
    self: *Pacman,
    pkg_name: []const u8,
    pkg_version: []const u8,
) !SourceFiles {
    const path = try self.snapshotPath(pkg_name, pkg_version);
    defer self.allocator.free(path);
    return self.readSnapshotFiles(self.allocator, path);
}

fn readSnapshotFiles(self: *Pacman, allocator: Allocator, path: []const u8) !SourceFiles {
    var dir = Dir.openDirAbsolute(self.io, path, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        // No snapshot directory yet (e.g. a package that was never
        // downloaded): return an empty map so callers avoid unwrapping
        // an optional.
        error.FileNotFound => return .empty,
        else => return err,
    };
    defer dir.close(self.io);
    try self.print(" reading files in {s}{s}{s}\n", .{ color.bold, path, color.reset });

    var files_map: SourceFiles = .empty;
    errdefer deinitSnapshotFiles(allocator, &files_map);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(self.io)) |node| {
        if (node.kind != .file and node.kind != .sym_link) continue;
        const stat = try dir.statFile(self.io, node.path, .{ .follow_symlinks = false });
        const file_contents = if (node.kind == .sym_link) target: {
            var buffer: [Dir.max_path_bytes]u8 = undefined;
            const len = try dir.readLink(self.io, node.path, &buffer);
            break :target try allocator.dupe(u8, buffer[0..len]);
        } else try dir.readFileAlloc(self.io, node.path, allocator, .unlimited);

        // Store raw file contents. Any indentation is applied only at
        // display time (bareInstall), so the update/diff path never copies
        // every snapshot file.
        errdefer allocator.free(file_contents);
        const copy_name = try allocator.dupe(u8, node.path);
        errdefer allocator.free(copy_name);
        try files_map.putNoClobber(allocator, copy_name, .{
            .contents = file_contents,
            .kind = node.kind,
            .mode = stat.permissions.toMode(),
        });
    }
    return files_map;
}

fn stdinReadByte(self: *Pacman) !u8 {
    self.flushStdout();
    // Read the whole line so leftover input isn't exposed to a child
    // that inherits stdin.
    const reader = self.stdin();
    const line = try reader.interface.takeDelimiterInclusive('\n');
    const answer = mem.trim(u8, line, " \t\r\n");
    return if (answer.len == 0) 'y' else answer[0];
}

fn printSearchResult(writer: *Io.Writer, result: aur.Search, is_installed: bool) !void {
    const installed = color.bold_foreground_cyan ++ "[Installed]" ++ color.reset;
    const installed_text = if (is_installed) installed else "";
    const desc = result.description orelse "(missing)";
    try writer.print("{s}aur/{s}{s}{s}{s} {s}{s}{s} {s} ({d}) {s}{s}/{s}{s}\n    {s}\n", .{
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
        color.foreground_blue,
        aur.packages,
        result.name,
        color.reset,
        desc,
    });
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

    const resp = try aur.search(allocator, pacman.getRequest(), pkg, .name);
    defer allocator.free(resp.results);
    for (resp.results) |result| {
        try printSearchResult(
            pacman.stdout(),
            result,
            pacman.pkgs.get(result.name) != null,
        );
    }
}

test "printSearchResult puts the AUR package link after popularity" {
    const testing = std.testing;
    const result: aur.Search = .{
        .id = 1,
        .name = "test-package",
        .package_base_id = 1,
        .package_base = "test-package",
        .version = "1.2.3-1",
        .description = "A package used for testing",
        .url = null,
        .num_votes = 42,
        .popularity = 3.5,
        .first_submitted = 0,
        .last_modified = 0,
        .url_path = "/cgit/aur.git/snapshot/test-package.tar.gz",
    };
    var output_buffer: [512]u8 = undefined;
    var writer = Io.Writer.fixed(&output_buffer);
    try printSearchResult(&writer, result, false);

    const expected =
        color.bold_foreground_magenta ++ "aur/" ++ color.reset ++
        color.bold ++ "test-package" ++ color.reset ++ " " ++
        color.bold_foreground_green ++ "1.2.3-1" ++ color.reset ++
        "  (3.5) " ++ color.foreground_blue ++
        "https://aur.archlinux.org/packages/test-package" ++ color.reset ++ "\n" ++
        "    A package used for testing\n";
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "shouldUpdate always selects a fresh install" {
    const testing = std.testing;
    try testing.expect(shouldUpdate("foo", null, false, true));
    try testing.expect(shouldUpdate("foo", null, false, false));
}

test "shouldUpdate selects a normal package only when its remote version is newer" {
    const testing = std.testing;
    try testing.expect(shouldUpdate("foo", "1.0", false, true));
    try testing.expect(!shouldUpdate("foo", "1.0", false, false));
    try testing.expect(!shouldUpdate("foo", "2.0", false, false));
}

test "shouldUpdate rebuilds a git package when its pkgver still matches" {
    const testing = std.testing;
    try testing.expect(shouldUpdate("neovim-git", "r100.abc", false, false));
    try testing.expect(shouldUpdate("neovim-git", "r100.abc", false, false));
    try testing.expect(shouldUpdate("neovim-git", "r100.abc", false, true));
    try testing.expect(!shouldUpdate("neovim", "1.0", false, false));
}

test "normalizeDepName strips alternatives and version constraints" {
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

test "normalizeDepName rejects empty and variable dependencies" {
    const testing = std.testing;
    try testing.expectError(error.EmptyDependency, normalizeDepName(testing.allocator, ""));
    try testing.expectError(error.EmptyDependency, normalizeDepName(testing.allocator, ">=1.0"));
    try testing.expectError(
        error.VariableDependency,
        normalizeDepName(testing.allocator, "$pkgname"),
    );
    try testing.expectError(
        error.VariableDependency,
        normalizeDepName(testing.allocator, "$pkgver"),
    );
}

test "isGitPkg requires git to be the final suffix" {
    const testing = std.testing;
    try testing.expect(isGitPkg("neovim-git"));
    try testing.expect(isGitPkg("foo-git"));
    try testing.expect(!isGitPkg("neovim"));
    try testing.expect(!isGitPkg("foo-git-tools"));
    try testing.expect(!isGitPkg(""));
}

test "queuePendingPackage preserves dependency-first insertion order" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var pending: std.ArrayList(PendingPackage) = .empty;
    defer deinitPendingPackages(allocator, &pending);
    var queued_bases: std.StringHashMapUnmanaged(usize) = .empty;
    defer queued_bases.deinit(allocator);

    var dependency: Package = .{};
    dependency.aur_version = "2.0";
    try queuePendingPackage(allocator, &pending, &queued_bases, "dependency", dependency, null);

    var root: Package = .{ .installed_version = "1.0" };
    root.aur_version = "2.0";
    try queuePendingPackage(allocator, &pending, &queued_bases, "root", root, null);

    try testing.expectEqual(@as(usize, 2), pending.items.len);
    try testing.expectEqualStrings("dependency", pending.items[0].name);
    try testing.expectEqualStrings("root", pending.items[1].name);
}

test "queuePendingPackage deduplicates bases and promotes root metadata" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var pending: std.ArrayList(PendingPackage) = .empty;
    defer deinitPendingPackages(allocator, &pending);
    var queued_bases: std.StringHashMapUnmanaged(usize) = .empty;
    defer queued_bases.deinit(allocator);

    var dependency: Package = .{};
    dependency.aur_version = "2.0";
    dependency.base_name = "shared-base";
    try queuePendingPackage(allocator, &pending, &queued_bases, "shared-lib", dependency, null);

    var root: Package = .{ .installed_version = "1.0" };
    root.aur_version = "2.0";
    root.base_name = "shared-base";
    try queuePendingPackage(allocator, &pending, &queued_bases, "shared-cli", root, null);

    try testing.expectEqual(@as(usize, 1), pending.items.len);
    try testing.expectEqual(@as(usize, 1), queued_bases.count());
    try testing.expectEqual(@as(usize, 0), queued_bases.get("shared-base").?);
    try testing.expectEqualStrings("shared-cli", pending.items[0].name);
    try testing.expectEqualStrings("1.0", pending.items[0].pkg.installed_version.?);
    try testing.expectEqualStrings("2.0", pending.items[0].pkg.aur_version.?);
    try testing.expectEqualStrings("shared-base", pending.items[0].pkg.base_name.?);
}

test "queuePendingPackage replaces a queued build with an existing artifact" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var pending: std.ArrayList(PendingPackage) = .empty;
    defer deinitPendingPackages(allocator, &pending);
    var queued_bases: std.StringHashMapUnmanaged(usize) = .empty;
    defer queued_bases.deinit(allocator);

    var dependency: Package = .{};
    dependency.aur_version = "2.0";
    try queuePendingPackage(allocator, &pending, &queued_bases, "shared", dependency, null);

    var root: Package = .{ .installed_version = "1.0" };
    root.aur_version = "2.0";
    const artifact = artifact: {
        const value = try allocator.dupe(u8, "shared-2.0-x86_64.pkg.tar.zst");
        errdefer allocator.free(value);
        try queuePendingPackage(allocator, &pending, &queued_bases, "shared", root, value);
        break :artifact value;
    };

    try testing.expectEqual(@as(usize, 1), pending.items.len);
    try testing.expectEqualStrings(artifact, pending.items[0].outputs.get("shared").?.artifact.?);
    try testing.expectEqualStrings("1.0", pending.items[0].pkg.installed_version.?);
}

test "extractTarGz strips the snapshot root and consumes the archive" {
    const testing = std.testing;
    const io = testing.io;
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

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
        .argv = &.{
            "sh",
            "-c",
            "cd \"$1\" && tar czf pkg.tar.gz pkg-1.0",
            "sh",
            rel_tmp,
        },
    });
    defer allocator.free(tar_run.stdout);
    defer allocator.free(tar_run.stderr);
    if (tar_run.term != .exited or tar_run.term.exited != 0) return error.TarCreate;

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
    if (leftover) |file| {
        defer file.close(io);
        return error.ArchiveNotConsumed;
    }
}

test "snapshot review detects executable changes and added or removed files" {
    const testing = std.testing;
    const cases = [_]struct {
        file_name: []const u8,
        old: ?[]const u8,
        new: ?[]const u8,
    }{
        .{ .file_name = "PKGBUILD", .old = "build() { echo old; }\n", .new = "build() { echo new; }\n" },
        .{ .file_name = "PKGBUILD", .old = "prepare() { echo old; }\n", .new = "prepare() { echo new; }\n" },
        .{ .file_name = "PKGBUILD", .old = "package_foo() { echo old; }\n", .new = "package_foo() { echo new; }\n" },
        .{ .file_name = "PKGBUILD", .old = "helper() { echo old; }\n", .new = "helper() { echo new; }\n" },
        .{ .file_name = "PKGBUILD", .old = "echo old\n", .new = "echo new\n" },
        .{ .file_name = "PKGBUILD", .old = "_url=old\nsource=(\"$_url\")\n", .new = "_url=new\nsource=(\"$_url\")\n" },
        .{ .file_name = "post.install", .old = null, .new = "post_install() { echo added; }\n" },
        .{ .file_name = "prepare.sh", .old = "echo removed\n", .new = null },
        .{ .file_name = "fix.patch", .old = "old\n", .new = "new\n" },
    };
    for (cases) |case| {
        try testing.expect(try testSnapshotReview(case.file_name, case.old, case.new));
    }
    try testing.expect(!try testSnapshotReview("PKGBUILD", "pkgname=foo\n", "pkgname=foo\n"));
}

fn testSnapshotReview(name: []const u8, old: ?[]const u8, new: ?[]const u8) !bool {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var output_file = try tmp.dir.createFile(testing.io, "review-output", .{});
    defer output_file.close(testing.io);
    var output_buffer: [4096]u8 = undefined;
    var environ: std.process.Environ.Map = .init(allocator);
    defer environ.deinit();
    var pacman: Pacman = .{
        .allocator = allocator,
        .io = testing.io,
        .environ_map = &environ,
        .stdout_writer = output_file.writer(testing.io, &output_buffer),
        .zur_path = "",
        .zur_pkg_dir = "",
    };
    defer pacman.deinit();
    var old_files: SourceFiles = .empty;
    defer deinitSnapshotFiles(allocator, &old_files);
    var new_files: SourceFiles = .empty;
    defer deinitSnapshotFiles(allocator, &new_files);
    for ([_]*SourceFiles{ &old_files, &new_files }) |files| {
        try files.put(allocator, try allocator.dupe(u8, "PKGBUILD"), .{ .contents = try allocator.dupe(u8, "pkgname=foo\n") });
    }
    if (old) |content| try old_files.put(allocator, try allocator.dupe(u8, name), .{ .contents = try allocator.dupe(u8, content) });
    if (new) |content| try new_files.put(allocator, try allocator.dupe(u8, name), .{ .contents = try allocator.dupe(u8, content) });
    return pacman.reviewSnapshotChanges(allocator, old_files, new_files);
}

test "snapshot review retains scripts larger than four kilobytes" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".src/foo/2");
    const script = "echo reviewed\n" ** 400;
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = ".src/foo/2/prepare.sh",
        .data = script,
    });
    var path_buffer: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &path_buffer);
    var output_file = try tmp.dir.createFile(testing.io, "review-output", .{});
    defer output_file.close(testing.io);
    var output_buffer: [4096]u8 = undefined;
    var environ: std.process.Environ.Map = .init(allocator);
    defer environ.deinit();
    var pacman: Pacman = .{
        .allocator = allocator,
        .io = testing.io,
        .environ_map = &environ,
        .stdout_writer = output_file.writer(testing.io, &output_buffer),
        .zur_path = path_buffer[0..len],
        .zur_pkg_dir = path_buffer[0..len],
    };
    defer pacman.deinit();
    var files = try pacman.snapshotFiles("foo", "2");
    defer deinitSnapshotFiles(allocator, &files);
    try testing.expect(files.contains("prepare.sh"));
    try testing.expectEqualStrings(script, files.get("prepare.sh").?.contents);
}

test "PKGBUILD review preserves valid Bash and unsupported statements" {
    const testing = std.testing;
    const cases = [_]struct { contents: []const u8, visible: []const u8 }{
        .{ .contents = "package() {\n  name=${pkgname#prefix}\n}\n", .visible = "name=${pkgname#prefix}" },
        .{ .contents = "package_foo-bar() { echo hello; }\n", .visible = "package_foo-bar()" },
        .{ .contents = "echo top-level-command\n", .visible = "echo top-level-command" },
        .{ .contents = "function package { echo alternate-syntax; }\n", .visible = "function package { echo alternate-syntax; }" },
        .{ .contents = "package() {\ncat <<'END'\n}\nhello\nEND\n}\n", .visible = "cat <<'END'\n}\nhello\nEND" },
    };
    for (cases) |case| {
        var output: Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        try printSourceFile(std.testing.allocator, &output.writer, "PKGBUILD", .{ .contents = case.contents });
        try testing.expect(mem.indexOf(u8, output.written(), case.visible) != null);
    }
}

test "dependency planning upgrades an insufficient installed version before its consumer" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    try testing.expect(try fixture.pacman.alpm_state.?.isInstalled("review-lib"));
    var dependencies = [_][]const u8{"review-lib>=2"};
    var infos = [_]aur.Info{
        testAurInfo("review-app", "2"),
        testAurInfo("review-lib", "2"),
    };
    infos[0].depends = &dependencies;
    for (infos) |info| try fixture.pacman.cacheAurInfo(info.name, info);
    var pending: std.ArrayList(PendingPackage) = .empty;
    defer deinitPendingPackages(allocator, &pending);
    var bases: std.StringHashMapUnmanaged(usize) = .empty;
    defer bases.deinit(allocator);
    try fixture.pacman.queuePackageWithDeps(&pending, &bases, "review-app", .{
        .installed_version = "1",
        .aur_version = "2",
    });
    try testing.expectEqual(@as(usize, 2), pending.items.len);
    try testing.expectEqualStrings("review-lib", pending.items[0].name);
    try testing.expectEqualStrings("review-app", pending.items[1].name);
}

fn testAurInfo(name: []const u8, version: []const u8) aur.Info {
    return .{
        .id = 1,
        .name = name,
        .package_base_id = 1,
        .package_base = name,
        .version = version,
        .url = "",
        .num_votes = 0,
        .popularity = 0,
        .first_submitted = 0,
        .last_modified = 0,
        .url_path = "",
    };
}

const TestDependencies = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    environ: std.process.Environ.Map,
    output: File,
    output_buffer: [4096]u8 = undefined,
    pacman: Pacman,

    fn init(self: *TestDependencies) !void {
        const testing = std.testing;
        self.arena = .init(testing.allocator);
        errdefer self.arena.deinit();
        const allocator = self.arena.allocator();
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        try self.tmp.dir.createDirPath(testing.io, "local/review-lib-1-1");
        try self.tmp.dir.writeFile(testing.io, .{
            .sub_path = "local/ALPM_DB_VERSION",
            .data = "9\n",
        });
        try self.tmp.dir.writeFile(testing.io, .{
            .sub_path = "local/review-lib-1-1/desc",
            .data = "%NAME%\nreview-lib\n\n%VERSION%\n1-1\n\n%PROVIDES%\nreview-virtual=1\n\n%REASON%\n1\n\n",
        });
        try self.tmp.dir.createDirPath(testing.io, "local/review-explicit-1-1");
        try self.tmp.dir.writeFile(testing.io, .{
            .sub_path = "local/review-explicit-1-1/desc",
            .data = "%NAME%\nreview-explicit\n\n%VERSION%\n1-1\n\n%REASON%\n0\n\n",
        });
        var path_buffer: [4096]u8 = undefined;
        const len = try self.tmp.dir.realPath(testing.io, &path_buffer);
        const path = try allocator.dupeZ(u8, path_buffer[0..len]);
        self.environ = .init(allocator);
        errdefer self.environ.deinit();
        self.output = try self.tmp.dir.createFile(testing.io, "output", .{});
        errdefer self.output.close(testing.io);
        self.pacman = .{
            .allocator = allocator,
            .io = testing.io,
            .environ_map = &self.environ,
            .zur_path = path,
            .zur_pkg_dir = path,
            .alpm_state = try Alpm.init(allocator, .{ .db_path = path }),
            .stdout_writer = self.output.writer(testing.io, &self.output_buffer),
        };
    }

    fn deinit(self: *TestDependencies) void {
        self.pacman.deinit();
        self.output.close(std.testing.io);
        self.environ.deinit();
        self.tmp.cleanup();
        self.arena.deinit();
        self.* = undefined;
    }
};

test "dependency planning recognizes installed versioned providers" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const alpm = &fixture.pacman.alpm_state.?;
    const installed = try alpm.installedSatisfier("review-virtual>=1");
    try testing.expect(installed != null);
    try testing.expectEqualStrings("review-lib", installed.?);
    try testing.expectEqual(null, try alpm.installedSatisfier("review-virtual>=2"));
    try testing.expectEqual(null, try fixture.pacman.resolveDependency("review-virtual>=1"));
}

test "dependency planning retains scheduled upgrade edges and rejects incompatible updates" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    var dependencies = [_][]const u8{"review-lib>=1"};
    var infos = [_]aur.Info{
        testAurInfo("review-app", "2"),
        testAurInfo("review-lib", "2"),
    };
    infos[0].depends = &dependencies;
    for (infos) |info| try fixture.pacman.cacheAurInfo(info.name, info);
    const library: Package = .{ .installed_version = "1", .aur_version = "2", .requires_update = true };
    try fixture.pacman.pkgs.put(allocator, "review-lib", library);
    var pending: std.ArrayList(PendingPackage) = .empty;
    defer deinitPendingPackages(allocator, &pending);
    var bases: std.StringHashMapUnmanaged(usize) = .empty;
    defer bases.deinit(allocator);
    try fixture.pacman.queuePackageWithDeps(&pending, &bases, "review-app", .{
        .installed_version = "1",
        .aur_version = "2",
    });
    try testing.expectEqual(@as(usize, 2), pending.items.len);
    try testing.expectEqualStrings("review-lib", pending.items[0].name);
    try testing.expectEqualStrings("1", pending.items[0].pkg.installed_version.?);
    try testing.expectError(error.DependencyConflict, fixture.pacman.resolveDependency("review-lib=1"));
}

test "dependency planning selects an AUR provider that meets the required provision version" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    var old_provides = [_][]const u8{"review-virtual=1"};
    var new_provides = [_][]const u8{"review-virtual=2"};
    var infos = [_]aur.Info{
        testAurInfo("review-old-provider", "99"),
        testAurInfo("review-provider", "1"),
    };
    infos[0].provides = &old_provides;
    infos[1].provides = &new_provides;
    try fixture.pacman.aur_cache.put(allocator, try allocator.dupe(u8, "review-virtual"), null);
    try fixture.pacman.provider_cache.put(
        allocator,
        try allocator.dupe(u8, "review-virtual"),
        try allocator.dupe(aur.Info, &infos),
    );
    const selected = try fixture.pacman.resolveDependency("review-virtual>=2");
    try testing.expect(selected != null);
    try testing.expectEqualStrings("review-provider", selected.?.name);
    try testing.expectError(error.UnsatisfiedDependency, fixture.pacman.resolveDependency("review-virtual>=3"));
}

test "dependency planning rejects a build cycle before installing anything" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    var first_deps = [_][]const u8{"review-other"};
    var second_deps = [_][]const u8{"review-app"};
    var first = testAurInfo("review-app", "1");
    first.depends = &first_deps;
    var second = testAurInfo("review-other", "1");
    second.depends = &second_deps;
    try fixture.pacman.cacheAurInfo(first.name, first);
    try fixture.pacman.cacheAurInfo(second.name, second);
    var pending: std.ArrayList(PendingPackage) = .empty;
    defer deinitPendingPackages(allocator, &pending);
    var bases: std.StringHashMapUnmanaged(usize) = .empty;
    defer bases.deinit(allocator);
    try testing.expectError(error.DependencyCycle, fixture.pacman.queuePackageWithDeps(
        &pending,
        &bases,
        first.name,
        .{ .installed_version = null, .aur_version = "1" },
    ));
    try testing.expectEqual(@as(usize, 0), pending.items.len);
}

test "dependency planning installs AUR check dependencies before the consumer" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    var dependencies = [_][]const u8{"review-checker>=2"};
    var root = testAurInfo("review-app", "1");
    root.check_depends = &dependencies;
    try fixture.pacman.cacheAurInfo(root.name, root);
    try fixture.pacman.cacheAurInfo("review-checker", testAurInfo("review-checker", "2"));
    var pending: std.ArrayList(PendingPackage) = .empty;
    defer deinitPendingPackages(allocator, &pending);
    var bases: std.StringHashMapUnmanaged(usize) = .empty;
    defer bases.deinit(allocator);
    try fixture.pacman.queuePackageWithDeps(&pending, &bases, root.name, .{
        .installed_version = null,
        .aur_version = "1",
    });
    try testing.expectEqual(@as(usize, 2), pending.items.len);
    try testing.expectEqualStrings("review-checker", pending.items[0].name);
    try testing.expectEqualStrings("review-app", pending.items[1].name);
}

test "shouldUpdate rebuilds a git package whose generated version is ahead of AUR" {
    try std.testing.expect(shouldUpdate("foo-git", "r200.def-1", false, false));
}

test "split planning retains dependencies of every selected output before their shared build" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    var first_deps = [_][]const u8{"review-dep-a"};
    var second_deps = [_][]const u8{"review-dep-b"};
    var first = testAurInfo("review-output-a", "2");
    first.package_base = "review-base";
    first.depends = &first_deps;
    var second = testAurInfo("review-output-b", "2");
    second.package_base = "review-base";
    second.depends = &second_deps;
    for ([_]aur.Info{ first, second }) |info| {
        try fixture.pacman.cacheAurInfo(info.name, info);
        const pkg: Package = .{ .installed_version = "1", .aur_version = "2", .requires_update = true, .base_name = info.package_base };
        try fixture.pacman.pkgs.put(allocator, info.name, pkg);
    }
    try fixture.pacman.cacheAurInfo(first_deps[0], testAurInfo(first_deps[0], "1"));
    try fixture.pacman.cacheAurInfo(second_deps[0], testAurInfo(second_deps[0], "1"));
    var pending: std.ArrayList(PendingPackage) = .empty;
    defer deinitPendingPackages(allocator, &pending);
    var bases: std.StringHashMapUnmanaged(usize) = .empty;
    defer bases.deinit(allocator);
    try fixture.pacman.planPackages(&pending, &bases);
    try testing.expectEqual(@as(usize, 3), pending.items.len);
    try testing.expectEqualStrings("review-base", pending.items[2].pkg.base_name.?);
    try testing.expect(!mem.eql(u8, pending.items[0].name, pending.items[1].name));
    for (pending.items[0..2]) |item| {
        try testing.expect(mem.eql(u8, item.name, "review-dep-a") or mem.eql(u8, item.name, "review-dep-b"));
    }
}

test "split builds install only selected archive identities" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    try fixture.tmp.dir.createDirPath(testing.io, "cache");
    try fixture.tmp.dir.createDirPath(testing.io, ".src/review-base/2");
    fixture.pacman.zur_pkg_dir = try Dir.path.join(allocator, &.{ fixture.pacman.zur_path, "cache" });
    const cli = try testPackageArchive(&fixture, "cli-produced.pkg.tar", "review-cli");
    const gui = try testPackageArchive(&fixture, "gui-produced.pkg.tar", "review-gui");
    const listing = try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}/missing-debug.pkg.tar\n", .{
        cli,
        gui,
        fixture.pacman.zur_path,
    });
    var runner: TestBuildRunner = .{ .allocator = allocator, .listing = listing };
    defer runner.deinit();
    var pending: std.ArrayList(PendingPackage) = .empty;
    defer deinitPendingPackages(allocator, &pending);
    var bases: std.StringHashMapUnmanaged(usize) = .empty;
    defer bases.deinit(allocator);
    try queuePendingPackage(allocator, &pending, &bases, "review-cli", .{
        .installed_version = null,
        .aur_version = "2",
        .base_name = "review-base",
    }, null);
    pending.items[0].snapshot = try testSnapshot(&fixture, "review-base");
    try fixture.pacman.installUsing(&pending.items[0], &runner);
    try testing.expectEqual(@as(usize, 1), runner.builds);
    try testing.expectEqual(@as(usize, 1), runner.installs);
    try testing.expectEqual(@as(usize, 1), runner.installed.items.len);
    var archive = try fixture.pacman.alpm_state.?.readArchive(runner.installed.items[0]);
    defer archive.deinit(allocator);
    try testing.expectEqualStrings("review-cli", archive.name);
    const unselected = try Dir.openFileAbsolute(testing.io, gui, .{});
    unselected.close(testing.io);
}

test "split builds reject missing selected output before installing" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const gui = try testPackageArchive(&fixture, "gui-produced.pkg.tar", "review-gui");
    var runner: TestBuildRunner = .{ .allocator = allocator, .listing = gui };
    defer runner.deinit();
    var pending: std.ArrayList(PendingPackage) = .empty;
    defer deinitPendingPackages(allocator, &pending);
    var bases: std.StringHashMapUnmanaged(usize) = .empty;
    defer bases.deinit(allocator);
    try queuePendingPackage(allocator, &pending, &bases, "review-cli", .{
        .installed_version = null,
        .aur_version = "2",
        .base_name = "review-base",
    }, null);
    pending.items[0].snapshot = try testSnapshot(&fixture, "review-base");
    try testing.expectError(error.MissingPackageOutput, fixture.pacman.installUsing(&pending.items[0], &runner));
    try testing.expectEqual(@as(usize, 0), runner.installs);
    const unselected = try Dir.openFileAbsolute(testing.io, gui, .{});
    unselected.close(testing.io);
}

test "split cache requires every selected output and installs them together" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    var pending: std.ArrayList(PendingPackage) = .empty;
    defer deinitPendingPackages(allocator, &pending);
    var bases: std.StringHashMapUnmanaged(usize) = .empty;
    defer bases.deinit(allocator);
    const pkg: Package = .{ .installed_version = null, .aur_version = "2", .base_name = "review-base" };
    try queuePendingPackage(allocator, &pending, &bases, "review-cli", pkg, try allocator.dupe(u8, "/cache/cli.pkg.tar"));
    try queuePendingPackage(allocator, &pending, &bases, "review-lib", pkg, null);
    try testing.expectEqual(@as(usize, 1), pending.items.len);
    try testing.expect(!pending.items[0].isCached());
    try queuePendingPackage(allocator, &pending, &bases, "review-lib", pkg, try allocator.dupe(u8, "/cache/lib.pkg.tar"));
    try testing.expect(pending.items[0].isCached());
    var runner: TestBuildRunner = .{ .allocator = allocator, .listing = "" };
    defer runner.deinit();
    try fixture.pacman.installArtifacts(&pending.items[0], &runner);
    try testing.expectEqual(@as(usize, 0), runner.builds);
    try testing.expectEqual(@as(usize, 1), runner.installs);
    try testing.expectEqual(@as(usize, 2), runner.installed.items.len);
    try testing.expectEqualStrings("/cache/cli.pkg.tar", runner.installed.items[0]);
    try testing.expectEqualStrings("/cache/lib.pkg.tar", runner.installed.items[1]);
}

fn testPackageArchive(fixture: *TestDependencies, filename: []const u8, name: []const u8) ![]const u8 {
    return testPackageArchiveFor(fixture, filename, name, "any");
}

fn testPackageArchiveFor(fixture: *TestDependencies, filename: []const u8, name: []const u8, arch: []const u8) ![]const u8 {
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const metadata = try std.fmt.allocPrint(
        allocator,
        "pkgname = {s}\npkgver = 2-1\npkgdesc = Test fixture\narch = {s}\nbuilddate = 1\nsize = 0\n",
        .{ name, arch },
    );
    try fixture.tmp.dir.writeFile(io, .{ .sub_path = ".PKGINFO", .data = metadata });
    const path = try Dir.path.join(allocator, &.{ fixture.pacman.zur_path, filename });
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "tar", "-cf", path, ".PKGINFO" },
        .cwd = .{ .path = fixture.pacman.zur_path },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.TarCreate;
    return path;
}

const TestBuildRunner = struct {
    allocator: Allocator,
    listing: []const u8,
    builds: usize = 0,
    installs: usize = 0,
    installed: std.ArrayList([]u8) = .empty,

    fn deinit(self: *TestBuildRunner) void {
        for (self.installed.items) |path| self.allocator.free(path);
        self.installed.deinit(self.allocator);
    }

    fn execCommand(self: *TestBuildRunner, argv: []const []const u8, _: []const u8) !void {
        if (mem.eql(u8, argv[0], "makepkg")) {
            for (argv[1..]) |arg| {
                if (mem.eql(u8, arg, "--install") or
                    (mem.startsWith(u8, arg, "-") and !mem.startsWith(u8, arg, "--") and
                        mem.indexOfScalar(u8, arg, 'i') != null)) return error.UnselectedOutputsInstalled;
            }
            self.builds += 1;
            return;
        }
        try std.testing.expectEqualStrings("sudo", argv[0]);
        try std.testing.expectEqualStrings("pacman", argv[1]);
        try std.testing.expectEqualStrings("-U", argv[2]);
        try std.testing.expectEqualStrings("--", argv[3]);
        for (argv[4..]) |path| try self.installed.append(self.allocator, try self.allocator.dupe(u8, path));
        self.installs += 1;
    }

    fn captureCommand(self: *TestBuildRunner, argv: []const []const u8, _: []const u8) ![]u8 {
        try std.testing.expectEqualStrings("makepkg", argv[0]);
        try std.testing.expectEqualStrings("--packagelist", argv[1]);
        return self.allocator.dupe(u8, self.listing);
    }
};

test "split runtime dependencies retain required siblings and their external dependencies" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    var cli_deps = [_][]const u8{"review-sibling"};
    var sibling_deps = [_][]const u8{ "review-cli", "review-external" };
    var cli = testAurInfo("review-cli", "2");
    cli.package_base = "review-base";
    cli.depends = &cli_deps;
    var sibling = testAurInfo("review-sibling", "2");
    sibling.package_base = "review-base";
    sibling.depends = &sibling_deps;
    try fixture.pacman.cacheAurInfo(cli.name, cli);
    try fixture.pacman.cacheAurInfo(sibling.name, sibling);
    try fixture.pacman.cacheAurInfo("review-external", testAurInfo("review-external", "1"));
    const pkg: Package = .{ .installed_version = null, .aur_version = "2", .requires_update = true, .base_name = "review-base" };
    try fixture.pacman.pkgs.put(allocator, cli.name, pkg);
    var pending: std.ArrayList(PendingPackage) = .empty;
    defer deinitPendingPackages(allocator, &pending);
    var bases: std.StringHashMapUnmanaged(usize) = .empty;
    defer bases.deinit(allocator);
    try fixture.pacman.planPackages(&pending, &bases);
    try testing.expectEqual(@as(usize, 2), pending.items.len);
    try testing.expectEqualStrings("review-external", pending.items[0].name);
    try testing.expectEqual(@as(usize, 2), pending.items[1].outputs.count());
    try testing.expect(pending.items[1].outputs.contains("review-cli"));
    try testing.expect(pending.items[1].outputs.contains("review-sibling"));
}

test "cleanup does not delete a different package sharing a name prefix" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const names = [_][]const u8{
        "foo-bar-1.0-1",
        "foo-1.0-1",
        "foo-2.0-1",
        "foo-3.0-1",
    };
    for (names) |name| {
        try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "fixture" });
        try Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    }
    try fixture.pacman.removeStaleArtifacts("foo", fixture.pacman.zur_path);
    const file = try fixture.tmp.dir.openFile(testing.io, names[0], .{});
    file.close(testing.io);
}

test "cleanup keeps three versions with their signatures inside the owning package directory" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    try fixture.tmp.dir.createDirPath(testing.io, "foo");
    try fixture.tmp.dir.createDirPath(testing.io, "foo-bar");
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "foo/.review", .data = "marker" });
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "foo-bar/old.pkg.tar", .data = "other package" });
    for (1..5) |version| {
        const path = try std.fmt.allocPrint(allocator, "foo/{d}.pkg.tar", .{version});
        const signature = try std.fmt.allocPrint(allocator, "{s}.sig", .{path});
        try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = "archive" });
        try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = signature, .data = "signature" });
        try Io.sleep(testing.io, .fromMilliseconds(10), .awake);
    }
    try fixture.pacman.removeStaleArtifacts("foo", fixture.pacman.zur_path);
    for ([_][]const u8{ "foo/1.pkg.tar", "foo/1.pkg.tar.sig" }) |path| {
        try testing.expectError(error.FileNotFound, fixture.tmp.dir.openFile(testing.io, path, .{}));
    }
    for (2..5) |version| {
        const path = try std.fmt.allocPrint(allocator, "foo/{d}.pkg.tar", .{version});
        const signature = try std.fmt.allocPrint(allocator, "{s}.sig", .{path});
        const archive_file = try fixture.tmp.dir.openFile(testing.io, path, .{});
        archive_file.close(testing.io);
        const signature_file = try fixture.tmp.dir.openFile(testing.io, signature, .{});
        signature_file.close(testing.io);
    }
    for ([_][]const u8{ "foo/.review", "foo-bar/old.pkg.tar" }) |path| {
        const file = try fixture.tmp.dir.openFile(testing.io, path, .{});
        file.close(testing.io);
    }
}

test "archive caching preserves detached signatures in the package directory" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const path = try testPackageArchive(&fixture, "produced.pkg.tar", "review-cli");
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "produced.pkg.tar.sig", .data = "signature fixture" });
    var pending: std.ArrayList(PendingPackage) = .empty;
    defer deinitPendingPackages(allocator, &pending);
    var bases: std.StringHashMapUnmanaged(usize) = .empty;
    defer bases.deinit(allocator);
    try queuePendingPackage(allocator, &pending, &bases, "review-cli", .{ .installed_version = null, .aur_version = "2-1" }, null);
    try fixture.pacman.selectBuiltArtifacts(&pending.items[0], fixture.pacman.zur_path, path);
    const signature = try fixture.tmp.dir.readFileAlloc(testing.io, "review-cli/produced.pkg.tar.sig", allocator, .unlimited);
    defer allocator.free(signature);
    try testing.expectEqualStrings("signature fixture", signature);
}

test "cache lookup finds the filename produced by makepkg" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    try fixture.tmp.dir.createDirPath(testing.io, "review-cli");
    const path = try testPackageArchive(&fixture, "review-cli/review-cli-2-1-any.pkg.tar.zst", "review-cli");
    const found = try fixture.pacman.findExistingPackage("review-cli", "2-1");
    defer if (found) |artifact| allocator.free(artifact);
    try testing.expect(found != null);
    try testing.expectEqualStrings(path, found.?);
}

test "cache lookup uses archive identity and supports alternate extensions" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    try fixture.tmp.dir.createDirPath(testing.io, "review-cli");
    _ = try testPackageArchive(&fixture, "review-cli/review-cli-2-1-any.pkg.tar.zst", "another-package");
    _ = try testPackageArchiveFor(&fixture, "review-cli/foreign-arch.pkg.tar", "review-cli", "wrong_arch");
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "review-cli/broken.pkg.tar", .data = "not an archive" });
    try testing.expectEqual(null, try fixture.pacman.findExistingPackage("review-cli", "2-1"));
    const archive = try testPackageArchive(&fixture, "review-cli/custom.pkg.tar.xz", "review-cli");
    const found = try fixture.pacman.findExistingPackage("review-cli", "2-1");
    defer if (found) |path| allocator.free(path);
    try testing.expect(found != null);
    try testing.expectEqualStrings(archive, found.?);
    try testing.expectEqual(null, try fixture.pacman.findExistingPackage("review-cli", "3-1"));
}

test "cache lookup migrates verified legacy archives with their signatures" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    _ = try testPackageArchive(&fixture, "legacy.pkg.tar", "review-cli");
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "legacy.pkg.tar.sig", .data = "signature" });
    const found = try fixture.pacman.findExistingPackage("review-cli", "2-1");
    defer if (found) |path| allocator.free(path);
    try testing.expect(found != null);
    try testing.expect(mem.endsWith(u8, found.?, "/review-cli/legacy.pkg.tar"));
    const signature = try fixture.tmp.dir.readFileAlloc(testing.io, "review-cli/legacy.pkg.tar.sig", allocator, .unlimited);
    defer allocator.free(signature);
    try testing.expectEqualStrings("signature", signature);
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.openFile(testing.io, "legacy.pkg.tar", .{}));
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.openFile(testing.io, "legacy.pkg.tar.sig", .{}));
}

test "cache lookup never reuses development package archives" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.createDirPath(testing.io, "review-git");
    _ = try testPackageArchive(&fixture, "review-git/review-git-2-1-any.pkg.tar.zst", "review-git");
    try testing.expectEqual(null, try fixture.pacman.findExistingPackage("review-git", "2-1"));
}

const TestSnapshotRequest = struct {
    fn get(_: *TestSnapshotRequest, _: []const u8) error{TestDownloadRequired}![]u8 {
        return error.TestDownloadRequired;
    }
};

test "snapshot download retries a legacy extraction containing only PKGBUILD" {
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.createDirPath(std.testing.io, ".src/review-base/2");
    try fixture.tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".src/review-base/2/PKGBUILD",
        .data = "source=(missing.patch)\n",
    });
    var pkg: Package = .{ .installed_version = "1", .aur_version = "2", .base_name = "review-base" };
    var request: TestSnapshotRequest = .{};
    try std.testing.expectError(error.TestDownloadRequired, fixture.pacman.downloadAndExtractPackageUsing("review-cli", &pkg, &request));
}

fn testSnapshot(fixture: *TestDependencies, base: []const u8) !Snapshot {
    const allocator = fixture.arena.allocator();
    try fixture.tmp.dir.createDirPath(std.testing.io, "snapshot-input/nested");
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "snapshot-input/PKGBUILD", .data = "pkgname=review-cli\npkgver=2\npkgrel=1\n" });
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "snapshot-input/nested/hook.sh", .data = "echo original\n" });
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "tar", "-czf", "fixture.tar.gz", "snapshot-input" },
        .cwd = .{ .path = fixture.pacman.zur_path },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.TarCreate;
    const bytes = try fixture.tmp.dir.readFileAlloc(std.testing.io, "fixture.tar.gz", allocator, .unlimited);
    defer allocator.free(bytes);
    return Snapshot.create(allocator, std.testing.io, fixture.pacman.zur_path, base, bytes);
}

test "installed snapshot records survive build mutations and use actual output versions" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    var item: PendingPackage = .{
        .name = "review-cli",
        .pkg = .{ .installed_version = "2-1", .aur_version = "2", .base_name = "review-base" },
    };
    defer item.deinit(allocator);
    item.snapshot = try testSnapshot(&fixture, item.base());
    const produced = try testPackageArchive(&fixture, "produced.pkg.tar", item.name);
    try item.outputs.put(allocator, item.name, .{ .pkg = item.pkg, .artifact = try allocator.dupe(u8, produced) });
    try testing.expectEqual(null, try fixture.pacman.loadInstalledSnapshot(&item));
    try fixture.pacman.recordInstalledSnapshot(&item);
    var build = try Dir.openDirAbsolute(testing.io, item.snapshot.?.source_path, .{});
    defer build.close(testing.io);
    try build.writeFile(testing.io, .{ .sub_path = "PKGBUILD", .data = "mutated by makepkg\n" });
    var previous = (try fixture.pacman.loadInstalledSnapshot(&item)).?;
    defer previous.deinit(allocator);
    var files = try fixture.pacman.readSnapshotFiles(allocator, previous.source_path);
    defer deinitSnapshotFiles(allocator, &files);
    try testing.expectEqualStrings("pkgname=review-cli\npkgver=2\npkgrel=1\n", files.get("PKGBUILD").?.contents);
    try testing.expectEqualStrings("echo original\n", files.get("nested/hook.sh").?.contents);
    item.pkg.installed_version = "9-1";
    try testing.expectEqual(null, try fixture.pacman.loadInstalledSnapshot(&item));
}

test "snapshot review detects permission and symlink target changes" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    try fixture.tmp.dir.createDirPath(testing.io, "review/nested");
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "review/nested/hook", .data = "echo hi\n" });
    try fixture.tmp.dir.symLink(testing.io, "nested/hook", "review/link", .{});
    const path = try Dir.path.join(allocator, &.{ fixture.pacman.zur_path, "review" });
    var before = try fixture.pacman.readSnapshotFiles(allocator, path);
    defer deinitSnapshotFiles(allocator, &before);
    try fixture.tmp.dir.setFilePermissions(testing.io, "review/nested/hook", .fromMode(0o755), .{});
    var executable = try fixture.pacman.readSnapshotFiles(allocator, path);
    defer deinitSnapshotFiles(allocator, &executable);
    try testing.expect(try fixture.pacman.reviewSnapshotChanges(allocator, before, executable));
    try fixture.tmp.dir.deleteFile(testing.io, "review/link");
    try fixture.tmp.dir.symLink(testing.io, "another-target", "review/link", .{});
    var relinked = try fixture.pacman.readSnapshotFiles(allocator, path);
    defer deinitSnapshotFiles(allocator, &relinked);
    try testing.expect(try fixture.pacman.reviewSnapshotChanges(allocator, executable, relinked));
    try testing.expectEqualStrings("another-target", relinked.get("link").?.contents);
}

test "install requests deduplicate repeated package names" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    try names.appendSlice(allocator, &.{ "review-cli", "review-cli", "review-lib", "review-cli" });
    try fixture.pacman.setInstallPackages(names.items);
    try testing.expectEqual(@as(usize, 2), fixture.pacman.pkgs.count());
    try testing.expect(fixture.pacman.pkgs.contains("review-cli"));
    try testing.expect(fixture.pacman.pkgs.contains("review-lib"));
}

test "update skips remote initialization when no foreign packages are installed" {
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.pacman.fetchRemoteAurVersions();
    try fixture.pacman.compareVersions();
    try fixture.pacman.processOutOfDate();
    try std.testing.expect(fixture.pacman.request_state == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.pacman.pkgs.count());
}

const TestReasonRunner = struct {
    allocator: Allocator,
    commands: std.ArrayList([]const []const u8) = .empty,
    reject_reason_change: bool = false,

    fn deinit(self: *TestReasonRunner) void {
        for (self.commands.items) |command| {
            for (command) |arg| self.allocator.free(arg);
            self.allocator.free(command);
        }
        self.commands.deinit(self.allocator);
    }

    fn execCommand(self: *TestReasonRunner, argv: []const []const u8, _: []const u8) !void {
        const command = try self.allocator.alloc([]const u8, argv.len);
        for (argv, command) |arg, *copy| copy.* = try self.allocator.dupe(u8, arg);
        try self.commands.append(self.allocator, command);
        if (self.reject_reason_change and mem.eql(u8, argv[2], "-D")) return error.NonzeroStatus;
    }
};

test "planned AUR dependencies are installed with dependency reasons" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    try names.append(allocator, "review-cli");
    try fixture.pacman.setInstallPackages(names.items);
    const root_pkg = fixture.pacman.pkgs.getPtr("review-cli").?;
    root_pkg.aur_version = "2-1";
    root_pkg.requires_update = true;
    var dependencies = [_][]const u8{"review-new-dep"};
    var root = testAurInfo("review-cli", "2-1");
    root.depends = &dependencies;
    try fixture.pacman.cacheAurInfo(root.name, root);
    try fixture.pacman.cacheAurInfo("review-new-dep", testAurInfo("review-new-dep", "2-1"));
    var pending: std.ArrayList(PendingPackage) = .empty;
    defer deinitPendingPackages(allocator, &pending);
    var bases: std.StringHashMapUnmanaged(usize) = .empty;
    defer bases.deinit(allocator);
    try fixture.pacman.planPackages(&pending, &bases);
    var runner: TestReasonRunner = .{ .allocator = allocator };
    defer runner.deinit();
    for (pending.items) |*item| {
        for (item.outputs.values()) |*output| output.artifact = try allocator.dupe(u8, "/cache/test.pkg.tar");
        try fixture.pacman.installArtifacts(item, &runner);
    }
    try testing.expectEqual(@as(usize, 2), runner.commands.items.len);
    try testing.expectEqualStrings("-U", runner.commands.items[0][2]);
    try testing.expectEqualStrings("--asdeps", runner.commands.items[0][3]);
    try testing.expectEqualStrings("-U", runner.commands.items[1][2]);
    try testing.expectEqualStrings("--", runner.commands.items[1][3]);
}

test "mixed split outputs preserve existing reasons and mark only new dependencies" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    try names.appendSlice(allocator, &.{ "review-cli", "review-lib" });
    try fixture.pacman.setInstallPackages(names.items);
    var deps = [_][]const u8{ "review-sibling", "review-lib>=2", "review-explicit>=2" };
    for ([_][]const u8{ "review-cli", "review-sibling", "review-lib", "review-explicit" }) |name| {
        var info = testAurInfo(name, "2-1");
        info.package_base = "review-base";
        if (mem.eql(u8, name, "review-cli")) info.depends = &deps;
        try fixture.pacman.cacheAurInfo(name, info);
        if (fixture.pacman.pkgs.getPtr(name)) |pkg| {
            pkg.aur_version = "2-1";
            pkg.base_name = info.package_base;
            pkg.requires_update = true;
        }
    }
    var pending: std.ArrayList(PendingPackage) = .empty;
    defer deinitPendingPackages(allocator, &pending);
    var bases: std.StringHashMapUnmanaged(usize) = .empty;
    defer bases.deinit(allocator);
    try fixture.pacman.planPackages(&pending, &bases);
    try testing.expectEqual(@as(usize, 1), pending.items.len);
    const item = &pending.items[0];
    try testing.expectEqual(Alpm.InstallReason.dependency, item.outputs.get("review-lib").?.reason);
    try testing.expect(item.outputs.get("review-lib").?.was_installed);
    try testing.expectEqual(Alpm.InstallReason.explicit, item.outputs.get("review-explicit").?.reason);
    try testing.expect(item.outputs.get("review-explicit").?.was_installed);
    try testing.expectEqual(Alpm.InstallReason.explicit, item.outputs.get("review-cli").?.reason);
    try testing.expectEqual(Alpm.InstallReason.dependency, item.outputs.get("review-sibling").?.reason);
    for (item.outputs.values()) |*output| output.artifact = try allocator.dupe(u8, "/cache/test.pkg.tar");
    var runner: TestReasonRunner = .{ .allocator = allocator };
    defer runner.deinit();
    try fixture.pacman.installArtifacts(item, &runner);
    try testing.expectEqual(@as(usize, 2), runner.commands.items.len);
    try testing.expectEqualStrings("-U", runner.commands.items[0][2]);
    try testing.expectEqual(@as(usize, 8), runner.commands.items[0].len);
    try testing.expectEqualStrings("--", runner.commands.items[0][3]);
    const marking = runner.commands.items[1];
    try testing.expectEqual(@as(usize, 6), marking.len);
    try testing.expectEqualStrings("-D", marking[2]);
    try testing.expectEqualStrings("--asdeps", marking[3]);
    try testing.expectEqualStrings("review-sibling", marking[5]);
    var rejecting: TestReasonRunner = .{ .allocator = allocator, .reject_reason_change = true };
    defer rejecting.deinit();
    try testing.expectError(error.NonzeroStatus, fixture.pacman.installArtifacts(item, &rejecting));
    try testing.expectEqual(@as(usize, 2), rejecting.commands.items.len);
}

test "makepkg child paths stay managed despite environment and configuration overrides" {
    const testing = std.testing;
    const library = Dir.openFileAbsolute(testing.io, "/usr/share/makepkg/util/config.sh", .{}) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    library.close(testing.io);
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    var snapshot = try testSnapshot(&fixture, "review-base");
    defer snapshot.deinit(allocator);
    try fixture.tmp.dir.createDirPath(testing.io, "bin");
    try fixture.tmp.dir.writeFile(testing.io, .{
        .sub_path = "bin/makepkg",
        .data =
        \\#!/bin/bash
        \\source /usr/share/makepkg/util/config.sh
        \\load_makepkg_config "$TEST_MAKEPKG_CONF"
        \\printf '%s\n' "$PKGDEST" "$SRCDEST" "$SRCPKGDEST" "$BUILDDIR" "$LOGDEST" "$PKGEXT" > "$TEST_REPORT"
        \\if [[ $1 == --packagelist ]]; then cat "$TEST_REPORT"; fi
        \\
        ,
    });
    try fixture.tmp.dir.setFilePermissions(testing.io, "bin/makepkg", .fromMode(0o755), .{});
    try fixture.tmp.dir.writeFile(testing.io, .{
        .sub_path = "makepkg.conf",
        .data = "PKGDEST=/external/config\nSRCDEST=/external/config\nSRCPKGDEST=/external/config\nBUILDDIR=/external/config\nLOGDEST=/external/config\nPKGEXT=.pkg.tar.xz\n",
    });
    const search_path = try std.fmt.allocPrint(allocator, "{s}/bin:/usr/bin:/bin", .{fixture.pacman.zur_path});
    try fixture.environ.put("PATH", search_path);
    const config = try Dir.path.join(allocator, &.{ fixture.pacman.zur_path, "makepkg.conf" });
    const report = try Dir.path.join(allocator, &.{ fixture.pacman.zur_path, "report" });
    try fixture.environ.put("TEST_MAKEPKG_CONF", config);
    try fixture.environ.put("TEST_REPORT", report);
    for ([_][]const u8{ "PKGDEST", "SRCDEST", "SRCPKGDEST", "BUILDDIR", "LOGDEST" }) |name| {
        try fixture.environ.put(name, "/external/environment");
    }
    const program = try Dir.path.join(allocator, &.{ fixture.pacman.zur_path, "bin/makepkg" });
    try fixture.pacman.execCommand(&.{ program, "-scC" }, snapshot.source_path);
    const build_report = try fixture.tmp.dir.readFileAlloc(testing.io, "report", allocator, .unlimited);
    defer allocator.free(build_report);
    var paths = mem.splitScalar(u8, build_report, '\n');
    for (0..5) |_| {
        const path = paths.next().?;
        try testing.expect(mem.startsWith(u8, path, fixture.pacman.zur_path));
        try testing.expectEqual(@as(u8, '/'), path[fixture.pacman.zur_path.len]);
        var dir = try Dir.openDirAbsolute(testing.io, path, .{});
        dir.close(testing.io);
    }
    try testing.expectEqualStrings(".pkg.tar.xz", paths.next().?);
    const listing_report = try fixture.pacman.captureCommand(&.{ program, "--packagelist" }, snapshot.source_path);
    defer allocator.free(listing_report);
    try testing.expectEqualStrings(build_report, listing_report);
    try testing.expectEqualStrings("/external/environment", fixture.environ.get("PKGDEST").?);
}

test "explicit requests retain installed versions and allow intentional reinstalls" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.pacman.setInstallPackages(&.{"review-lib"});
    const pkg = fixture.pacman.pkgs.getPtr("review-lib").?;
    try testing.expectEqualStrings("1-1", pkg.installed_version.?);
    try testing.expect(pkg.requested);
    pkg.aur_version = "1-1";
    try fixture.pacman.compareVersions();
    try testing.expect(pkg.requires_update);
    pkg.requested = false;
    try fixture.pacman.compareVersions();
    try testing.expect(!pkg.requires_update);
}

test "metadata cache indexes both returned and absent package names" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    const results = [_]aur.Info{testAurInfo("review-present", "2-1")};
    try fixture.pacman.cacheAurResponse(&.{ "review-present", "review-absent" }, &results);
    try testing.expect(fixture.pacman.aur_cache.contains("review-absent"));
    try testing.expectEqualStrings("2-1", (try fixture.pacman.getAurInfo("review-present")).?.version);
    try testing.expectEqual(null, try fixture.pacman.getAurInfo("review-absent"));
    try testing.expect(fixture.pacman.request_state == null);
}

test "source review prints metadata and multiline native architecture sources" {
    const contents =
        \\pkgname=testpkg
        \\pkgver=2
        \\pkgrel=1
        \\source=(
        \\  "https://example.test/source.tar.gz"
        \\  'fix.patch'
        \\)
        \\source_x86_64=('x86-source')
        \\source_aarch64=('arm-source')
        \\source_riscv64=('riscv-source')
        \\build() {
        \\  make
        \\}
        \\package_testpkg() {
        \\  install -Dm755 program "$pkgdir/usr/bin/program"
        \\}
    ;
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try printSourceFile(std.testing.allocator, &output.writer, "PKGBUILD", .{ .contents = contents });
    for ([_][]const u8{
        ":: File: PKGBUILD (file, mode 644)",
        "  pkgname testpkg\n",
        "  pkgver 2\n",
        "  pkgrel 1\n",
        "  source\n    \"https://example.test/source.tar.gz\"\n    'fix.patch'\n",
        "build()",
        "  make\n",
        "package_testpkg()",
        "install -Dm755 program",
    }) |visible| {
        try std.testing.expect(mem.indexOf(u8, output.written(), visible) != null);
    }
}

test "review cancellation stops the install pipeline" {
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input", .data = "n\n" });
    const input = try fixture.tmp.dir.openFile(std.testing.io, "input", .{});
    defer input.close(std.testing.io);
    var buffer: [128]u8 = undefined;
    fixture.pacman.stdin_reader = input.reader(std.testing.io, &buffer);
    var item: PendingPackage = .{ .name = "review-dependency", .pkg = .{} };
    defer item.deinit(fixture.arena.allocator());
    try std.testing.expectError(error.UserDeclined, fixture.pacman.bareInstall(&item, .empty));
}

test "review cancellation prompt accepts its advertised default" {
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input", .data = "\n" });
    const input = try fixture.tmp.dir.openFile(std.testing.io, "input", .{});
    defer input.close(std.testing.io);
    var buffer: [128]u8 = undefined;
    fixture.pacman.stdin_reader = input.reader(std.testing.io, &buffer);
    try std.testing.expectEqual(@as(u8, 'y'), try fixture.pacman.stdinReadByte());
}

test {
    _ = Snapshot;
}

test "install review formats sources before asking for confirmation" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "input", .data = "n\n" });
    const input = try fixture.tmp.dir.openFile(testing.io, "input", .{});
    defer input.close(testing.io);
    var buffer: [128]u8 = undefined;
    fixture.pacman.stdin_reader = input.reader(testing.io, &buffer);
    var files: SourceFiles = .empty;
    defer files.deinit(testing.allocator);
    try files.put(testing.allocator, "PKGBUILD", .{ .contents =
        \\pkgname=example
        \\_mirror=https://example.test
        \\source=(
        \\        "$_mirror/source.tar.gz"
        \\        'fix.patch'
        \\)
        \\prepare() {
        \\  patch -p1 < fix.patch
        \\}
    });
    var item: PendingPackage = .{ .name = "example", .pkg = .{} };
    defer item.deinit(fixture.arena.allocator());
    try testing.expectError(error.UserDeclined, fixture.pacman.bareInstall(&item, files));
    try fixture.pacman.stdout().flush();
    const output = try fixture.tmp.dir.readFileAlloc(testing.io, "output", testing.allocator, .unlimited);
    defer testing.allocator.free(output);
    try testing.expect(mem.indexOf(u8, output, "  source\n    \"$_mirror/source.tar.gz\"\n    'fix.patch'\n") != null);
    try testing.expect(mem.indexOf(u8, output, "_mirror https://example.test") != null);
    try testing.expect(mem.indexOf(u8, output, "prepare()") != null);
    try testing.expect(mem.indexOf(u8, output, "patch -p1 < fix.patch") != null);
    try testing.expect(mem.indexOf(u8, output, "Install? [Y/n]:") != null);
}

test "update review labels sources and retains changed function context" {
    const testing = std.testing;
    var fixture: TestDependencies = undefined;
    try fixture.init();
    defer fixture.deinit();
    var old: SourceFiles = .empty;
    defer old.deinit(testing.allocator);
    var new: SourceFiles = .empty;
    defer new.deinit(testing.allocator);
    try old.put(testing.allocator, "PKGBUILD", .{ .contents =
        \\_mirror=https://old.test
        \\source=("$_mirror/old.tar.gz")
        \\install=old.install
        \\prepare() {
        \\  cd "$srcdir"
        \\  echo old
        \\}
    });
    try new.put(testing.allocator, "PKGBUILD", .{ .contents =
        \\_mirror=https://new.test
        \\source=(
        \\          "$_mirror/new.tar.gz"
        \\          'fix.patch'
        \\)
        \\prepare() {
        \\  cd "$srcdir"
        \\  echo new
        \\}
    });
    try testing.expect(try fixture.pacman.reviewSnapshotChanges(testing.allocator, old, new));
    try fixture.pacman.stdout().flush();
    const output = try fixture.tmp.dir.readFileAlloc(testing.io, "output", testing.allocator, .unlimited);
    defer testing.allocator.free(output);
    try testing.expect(mem.indexOf(u8, output, color.bold ++ "source" ++ color.reset ++
        " was updated:\n  \"$_mirror/new.tar.gz\"\n  'fix.patch'\n") != null);
    try testing.expect(mem.indexOf(u8, output, color.bold ++ "_mirror" ++ color.reset ++
        " was updated: https://new.test") != null);
    try testing.expect(mem.indexOf(u8, output, color.bold ++ "install" ++ color.reset ++
        " was removed:") != null);
    try testing.expect(mem.indexOf(u8, output, "old.install") != null);
    try testing.expect(mem.indexOf(u8, output, "prepare()") != null);
    try testing.expect(mem.indexOf(u8, output, "cd \"$srcdir\"") != null);
    try testing.expect(mem.indexOf(u8, output, "echo new") != null);
}

test "printBarePkgbuildFields prints sources and every supporting field for review" {
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
    const source_output = "  source 'https://example.com/testpkg.tar.gz'\n\n";
    const install_output = "  install testpkg.install\n";
    const function_output =
        "  install()   {\n" ++
        "    install -Dm755 testpkg \"$pkgdir/usr/bin/testpkg\"\n" ++
        "  }\n\n";
    try testing.expect(mem.startsWith(u8, output, source_output));
    try testing.expectEqual(@as(usize, 1), mem.count(u8, output, install_output));
    try testing.expectEqual(@as(usize, 1), mem.count(u8, output, function_output));
    try testing.expectEqual(source_output.len + "  pkgname testpkg\n".len + install_output.len + function_output.len, output.len);
}

test "printBarePkgbuildFields formats multiline sources for review" {
    const testing = std.testing;
    const pkgbuild_contents =
        \\pkgname=testpkg
        \\source=(
        \\  "https://example.com/testpkg.tar.gz"
        \\  'fix-build.patch'
        \\)
        \\package() {
        \\  install -Dm755 testpkg "$pkgdir/usr/bin/testpkg"
        \\}
    ;

    var output_buffer: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&output_buffer);
    try printBarePkgbuildFields(testing.allocator, &writer, pkgbuild_contents);

    const expected =
        "  source\n" ++
        "    \"https://example.com/testpkg.tar.gz\"\n" ++
        "    'fix-build.patch'\n\n" ++
        "  pkgname testpkg\n" ++
        "  package()   {\n" ++
        "    install -Dm755 testpkg \"$pkgdir/usr/bin/testpkg\"\n" ++
        "  }\n\n";
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "printUpdatedPkgbuildField formats multiline sources for review" {
    const testing = std.testing;
    var output_buffer: [512]u8 = undefined;
    var writer = Io.Writer.fixed(&output_buffer);
    try printUpdatedPkgbuildField(
        &writer,
        "source_x86_64",
        "\n\"https://example.com/testpkg.tar.gz\"\n'fix-build.patch'\n",
    );

    const expected =
        color.bold_foreground_blue ++ "::" ++ color.reset ++ " " ++
        color.bold ++ "source_x86_64" ++ color.reset ++ " was updated:\n" ++
        "  \"https://example.com/testpkg.tar.gz\"\n" ++
        "  'fix-build.patch'\n";
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "printBarePkgbuildFields prints only the native architecture source" {
    const testing = std.testing;
    const pkgbuild_contents =
        \\pkgname=testpkg
        \\source_x86_64=('https://example.com/testpkg-x86_64.tar.gz')
        \\source_aarch64=('https://example.com/testpkg-aarch64.tar.gz')
        \\source_riscv64=('https://example.com/testpkg-riscv64.tar.gz')
        \\package() {
        \\  install -Dm755 testpkg "$pkgdir/usr/bin/testpkg"
        \\}
    ;

    var output_buffer: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&output_buffer);
    try printBarePkgbuildFields(testing.allocator, &writer, pkgbuild_contents);

    const output = writer.buffered();
    const expected_arch = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .riscv64 => "riscv64",
        else => @compileError("unsupported test architecture"),
    };
    var expected_buffer: [320]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buffer,
        "  source_{s} 'https://example.com/testpkg-{s}.tar.gz'\n\n" ++
            "  pkgname testpkg\n" ++
            "  package()   {{\n" ++
            "    install -Dm755 testpkg \"$pkgdir/usr/bin/testpkg\"\n" ++
            "  }}\n\n",
        .{ expected_arch, expected_arch },
    );
    try testing.expectEqualStrings(expected, output);
}

test "printBarePkgbuildFields formats the native architecture multiline source" {
    const testing = std.testing;
    const pkgbuild_contents =
        \\pkgname=testpkg
        \\source_x86_64=(
        \\  'https://example.com/testpkg-x86_64.tar.gz'
        \\  'launcher.sh'
        \\)
        \\source_aarch64=(
        \\  'https://example.com/testpkg-aarch64.tar.gz'
        \\  'launcher.sh'
        \\)
        \\source_riscv64=(
        \\  'https://example.com/testpkg-riscv64.tar.gz'
        \\  'launcher.sh'
        \\)
    ;

    var output_buffer: [1024]u8 = undefined;
    var writer = Io.Writer.fixed(&output_buffer);
    try printBarePkgbuildFields(testing.allocator, &writer, pkgbuild_contents);

    const expected_arch = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .riscv64 => "riscv64",
        else => @compileError("unsupported test architecture"),
    };
    var expected_buffer: [320]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buffer,
        "  source_{s}\n" ++
            "    'https://example.com/testpkg-{s}.tar.gz'\n" ++
            "    'launcher.sh'\n\n" ++
            "  pkgname testpkg\n",
        .{ expected_arch, expected_arch },
    );
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "structured review keeps source helpers and unquoted URL fragments visible" {
    const contents =
        \\source_url=https://example.test/repository#tag=v1
        \\source=(https://example.test/archive#fragment)
        \\source_helper() {
        \\  echo helper-command
        \\}
        \\source_aarch64=("${selected:=arm}")
        \\source_x86_64=("${selected:=x86}")
    ;
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try printSourceFile(std.testing.allocator, &output.writer, "PKGBUILD", .{ .contents = contents });
    for ([_][]const u8{
        "source_url https://example.test/repository#tag=v1",
        "source https://example.test/archive#fragment",
        "source_helper()",
        "echo helper-command",
        "${selected:=arm}",
        "${selected:=x86}",
    }) |visible| {
        try std.testing.expect(mem.indexOf(u8, output.written(), visible) != null);
    }
}

test "initial review falls back to complete text for unsupported shell syntax" {
    for ([_][]const u8{
        "source=(one)\nsource=(two)\n",
        "source=(\"$(echo executable)\")\n",
        "source=(<(echo process-substitution))\n",
        "pkgname=example; echo executable\n",
        "pkgname=example echo executable\n",
        "pkgname =example\n",
        "pkgname= echo executable\n",
        "source=('unterminated\n",
        "source=('line one\n  line two')\n",
        "source=(file\\ )\n",
        "source=(\"line\\\n  two\")\n",
        "source=\"line one\n  line two\"\n",
        "source=\"unterminated\n",
        "package() {\ncat <<'END'\n}\nhello\nEND\n}\n",
    }) |contents| {
        var output: Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try printSourceFile(std.testing.allocator, &output.writer, "PKGBUILD", .{ .contents = contents });
        try std.testing.expect(mem.endsWith(u8, output.written(), contents));
    }
}

test "update review exposes repeated reordered unsupported and normalized statements" {
    const testing = std.testing;
    const cases = [_]struct { old: []const u8, new: []const u8, visible: []const u8 }{
        .{
            .old = "origin=old\norigin=final\n",
            .new = "origin=new\norigin=final\n",
            .visible = "+ origin=new",
        },
        .{
            .old = "first=one\nsecond=$first\n",
            .new = "second=$first\nfirst=one\n",
            .visible = "+ first=one",
        },
        .{
            .old = "source=(one two)\n",
            .new = "source=(one  two)\n",
            .visible = "+ source=(one  two)",
        },
        .{
            .old = "source=one\n",
            .new = "source=(one)\n",
            .visible = "+ source=(one)",
        },
        .{
            .old = "echo old\n",
            .new = "echo new\n",
            .visible = "+ echo new",
        },
        .{
            .old = "package() {\ncat <<'END'\n}\nold\nEND\n}\n",
            .new = "package() {\ncat <<'END'\n}\nnew\nEND\n}\n",
            .visible = "+ new",
        },
        .{
            .old = "pkgname=example\n# old comment\n",
            .new = "pkgname=example\n# new comment\n",
            .visible = "+ # new comment",
        },
    };
    for (cases) |case| {
        var fixture: TestDependencies = undefined;
        try fixture.init();
        defer fixture.deinit();
        var old: SourceFiles = .empty;
        defer old.deinit(testing.allocator);
        var new: SourceFiles = .empty;
        defer new.deinit(testing.allocator);
        try old.put(testing.allocator, "PKGBUILD", .{ .contents = case.old });
        try new.put(testing.allocator, "PKGBUILD", .{ .contents = case.new });
        try testing.expect(try fixture.pacman.reviewSnapshotChanges(testing.allocator, old, new));
        try fixture.pacman.stdout().flush();
        const output = try fixture.tmp.dir.readFileAlloc(testing.io, "output", testing.allocator, .unlimited);
        defer testing.allocator.free(output);
        try testing.expect(mem.indexOf(u8, output, case.visible) != null);
    }
}

test "structured update review covers every function and architecture source" {
    const testing = std.testing;
    for ([_][]const u8{
        "prepare()",
        "build()",
        "check()",
        "pkgver()",
        "package_foo-bar()",
        "source_helper()",
        "source_aarch64",
        "source_x86_64",
    }) |name| {
        var fixture: TestDependencies = undefined;
        try fixture.init();
        defer fixture.deinit();
        const is_function = mem.endsWith(u8, name, "()");
        const old = try std.fmt.allocPrint(testing.allocator, "{s}{s}\n", .{
            name, if (is_function) " { echo old; }" else "=(old)",
        });
        defer testing.allocator.free(old);
        const new = try std.fmt.allocPrint(testing.allocator, "{s}{s}\n", .{
            name, if (is_function) " { echo new; }" else "=(new)",
        });
        defer testing.allocator.free(new);
        try fixture.pacman.printPkgbuildChanges(testing.allocator, old, new);
        try fixture.pacman.stdout().flush();
        const output = try fixture.tmp.dir.readFileAlloc(testing.io, "output", testing.allocator, .unlimited);
        defer testing.allocator.free(output);
        const label = try std.fmt.allocPrint(testing.allocator, "{s}{s}{s} was updated:", .{ color.bold, name, color.reset });
        defer testing.allocator.free(label);
        try testing.expect(mem.indexOf(u8, output, label) != null);
        try testing.expect(mem.indexOf(u8, output, if (is_function) "echo new" else "new") != null);
    }
}

test "structured review propagates allocation failures without leaking" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testReviewAllocations, .{});
}

fn testReviewAllocations(allocator: Allocator) !void {
    var buffer: [1024]u8 = undefined;
    var output = Io.Writer.fixed(&buffer);
    try printSourceFile(allocator, &output, "PKGBUILD", .{
        .contents = "pkgname=example\nsource=(one two)\npackage() { echo hello; }\n",
    });
    try std.testing.expect(mem.indexOf(u8, output.buffered(), "package()") != null);
}
