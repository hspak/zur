//! Long-lived libalpm handle for local-db and sync-repo queries.

const std = @import("std");
const log = std.log.scoped(.alpm);
const alpm = @cImport({
    @cInclude("alpm.h");
});

const Alpm = @This();

const ErrorSet = std.mem.Allocator.Error || error{
    NoHandle,
    NoSyncDb,
    NoLocalDb,
    NoCache,
    InvalidPackageArchive,
};
pub const Error = ErrorSet;

allocator: std.mem.Allocator,
handle: *alpm.alpm_handle_t,
local_db: *alpm.alpm_db_t,

/// A package installed locally, with its name and version. The slices are
/// copies owned by the caller's allocator.
pub const ForeignPackage = struct {
    name: []const u8,
    version: []const u8,
};

// The sync repos zur knows about. Hardcoded to the standard core/extra/multilib
// set, which covers the default Arch installation zur targets.
const repos = [_][*:0]const u8{
    "core",
    "extra",
    "multilib",
};

const sig_level = alpm.ALPM_SIG_PACKAGE_OPTIONAL | alpm.ALPM_SIG_DATABASE_OPTIONAL;

pub const Options = struct {
    root: [:0]const u8 = "/",
    db_path: [:0]const u8 = "/var/lib/pacman/",
};

/// Open a libalpm handle and register the sync repos. Paths are borrowed during initialization.
pub fn init(allocator: std.mem.Allocator, options: Options) Error!Alpm {
    var err: alpm.alpm_errno_t = 0;
    const handle = alpm.alpm_initialize(options.root, options.db_path, &err) orelse {
        return error.NoHandle;
    };
    errdefer _ = alpm.alpm_release(handle);

    // We only read each repo's package cache (never sync or verify), so a
    // permissive signature level is fine here.
    for (repos) |repo| {
        if (alpm.alpm_register_syncdb(handle, repo, sig_level) == null) {
            return error.NoSyncDb;
        }
    }

    const local_db = alpm.alpm_get_localdb(handle) orelse return error.NoLocalDb;
    log.debug("initialized libalpm", .{});

    return .{
        .allocator = allocator,
        .handle = handle,
        .local_db = local_db,
    };
}

/// Release the libalpm handle.
pub fn deinit(self: *Alpm) void {
    _ = alpm.alpm_release(self.handle);
    self.* = undefined;
}

/// Enumerate installed packages that are not present in any registered sync
/// repository ("foreign" / AUR packages, i.e. what `pacman -Qm` lists).
/// The returned name/version strings are duped into `self.allocator`; the
/// caller owns the returned slice.
pub fn fetchForeignPackages(self: *Alpm) Error![]ForeignPackage {
    const cache = alpm.alpm_db_get_pkgcache(self.local_db) orelse return error.NoCache;

    var list: std.ArrayList(ForeignPackage) = .empty;
    defer list.deinit(self.allocator);
    errdefer {
        for (list.items) |pkg_info| {
            self.allocator.free(pkg_info.name);
            self.allocator.free(pkg_info.version);
        }
    }

    var node = cache;
    while (node != null) : (node = node.*.next) {
        // Every cache entry is a package, so the data pointer is never null.
        const pkg: *const alpm.alpm_pkg_t = @ptrCast(node.*.data.?);
        const name = std.mem.span(alpm.alpm_pkg_get_name(@constCast(pkg)));
        if (!try self.isInSyncDbs(name)) {
            const name_copy = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(name_copy);
            const version = std.mem.span(alpm.alpm_pkg_get_version(@constCast(pkg)));
            const version_copy = try self.allocator.dupe(u8, version);
            errdefer self.allocator.free(version_copy);
            try list.append(self.allocator, .{
                .name = name_copy,
                .version = version_copy,
            });
        }
    }
    const value = try list.toOwnedSlice(self.allocator);
    return value;
}

/// True if a package `name` is installed in the local database.
pub fn isInstalled(self: *Alpm, name: []const u8) Error!bool {
    const name_cstr = try std.mem.concatWithSentinel(self.allocator, u8, &.{name}, 0);
    defer self.allocator.free(name_cstr);
    return alpm.alpm_db_get_pkg(self.local_db, @ptrCast(name_cstr.ptr)) != null;
}

/// Return an installed package satisfying the complete dependency, including
/// versioned provisions. The name is borrowed until this handle is released.
pub fn installedSatisfier(self: *Alpm, dependency: []const u8) Error!?[]const u8 {
    const expression = try self.allocator.dupeZ(u8, dependency);
    defer self.allocator.free(expression);
    const cache = alpm.alpm_db_get_pkgcache(self.local_db);
    const pkg = alpm.alpm_find_satisfier(cache, expression) orelse return null;
    return std.mem.span(alpm.alpm_pkg_get_name(pkg));
}

/// Whether a registered binary repository can satisfy the complete dependency.
pub fn syncSatisfies(self: *Alpm, dependency: []const u8) Error!bool {
    const expression = try self.allocator.dupeZ(u8, dependency);
    defer self.allocator.free(expression);
    var dbs = alpm.alpm_get_syncdbs(self.handle);
    while (dbs != null) : (dbs = dbs.*.next) {
        const db: *alpm.alpm_db_t = @ptrCast(dbs.*.data.?);
        if (alpm.alpm_find_satisfier(alpm.alpm_db_get_pkgcache(db), expression) != null) return true;
    }
    return false;
}

/// Match remote metadata using libalpm's dependency parser and version ordering.
/// All input strings are borrowed for the duration of the call.
pub fn satisfies(
    allocator: std.mem.Allocator,
    dependency: []const u8,
    name: []const u8,
    version: []const u8,
    provides: []const []const u8,
) Error!bool {
    const expression = try allocator.dupeZ(u8, dependency);
    defer allocator.free(expression);
    const dep: *alpm.alpm_depend_t = alpm.alpm_dep_from_string(expression) orelse return error.OutOfMemory;
    defer alpm.alpm_dep_free(dep);
    if (std.mem.eql(u8, std.mem.span(dep.name), name) and
        try versionSatisfies(allocator, dep, version)) return true;

    for (provides) |provision| {
        const provision_z = try allocator.dupeZ(u8, provision);
        defer allocator.free(provision_z);
        const provided: *alpm.alpm_depend_t = alpm.alpm_dep_from_string(provision_z) orelse return error.OutOfMemory;
        defer alpm.alpm_dep_free(provided);
        if (!std.mem.eql(u8, std.mem.span(dep.name), std.mem.span(provided.name))) continue;
        if (dep.mod == alpm.ALPM_DEP_MOD_ANY) return true;
        // Unversioned provisions cannot satisfy a versioned dependency.
        if (provided.mod != alpm.ALPM_DEP_MOD_EQ) continue;
        if (try versionSatisfies(allocator, dep, std.mem.span(provided.version))) return true;
    }
    return false;
}

fn versionSatisfies(
    allocator: std.mem.Allocator,
    dep: *const alpm.alpm_depend_t,
    version: []const u8,
) Error!bool {
    if (dep.mod == alpm.ALPM_DEP_MOD_ANY) return true;
    const version_z = try allocator.dupeZ(u8, version);
    defer allocator.free(version_z);
    const comparison = alpm.alpm_pkg_vercmp(version_z, dep.version);
    return switch (dep.mod) {
        alpm.ALPM_DEP_MOD_EQ => comparison == 0,
        alpm.ALPM_DEP_MOD_GE => comparison >= 0,
        alpm.ALPM_DEP_MOD_LE => comparison <= 0,
        alpm.ALPM_DEP_MOD_GT => comparison > 0,
        alpm.ALPM_DEP_MOD_LT => comparison < 0,
        else => unreachable, // alpm_dep_from_string returns a defined comparison.
    };
}

// True if `name` appears in any of the registered sync database caches.
// alpm_db_get_pkg wants a C string, so this makes a sentinel copy (like
// isInstalled) rather than trusting that `name` is already terminated.
fn isInSyncDbs(self: *Alpm, name: []const u8) !bool {
    const name_cstr = try std.mem.concatWithSentinel(self.allocator, u8, &.{name}, 0);
    defer self.allocator.free(name_cstr);

    var dbs = alpm.alpm_get_syncdbs(self.handle);
    while (dbs != null) : (dbs = dbs.*.next) {
        // Every sync-db entry is a database, so the data pointer is never null.
        const sync_db: *const alpm.alpm_db_t = @ptrCast(dbs.*.data.?);
        if (alpm.alpm_db_get_pkg(@constCast(sync_db), @ptrCast(name_cstr.ptr)) != null) return true;
    }
    return false;
}

/// Metadata copied from a package archive. The caller owns both strings.
pub const Archive = struct {
    name: []const u8,
    version: []const u8,

    pub fn deinit(self: *Archive, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        self.* = undefined;
    }
};

/// Inspect a package file without installing it. The caller must deinit the result.
pub fn readArchive(self: *Alpm, path: []const u8) Error!Archive {
    const path_z = try self.allocator.dupeZ(u8, path);
    defer self.allocator.free(path_z);
    var pkg: ?*alpm.alpm_pkg_t = null;
    if (alpm.alpm_pkg_load(self.handle, path_z, 0, 0, &pkg) != 0) {
        if (alpm.alpm_errno(self.handle) == alpm.ALPM_ERR_MEMORY) return error.OutOfMemory;
        return error.InvalidPackageArchive;
    }
    defer _ = alpm.alpm_pkg_free(pkg);
    const name = try self.allocator.dupe(u8, std.mem.span(alpm.alpm_pkg_get_name(pkg)));
    errdefer self.allocator.free(name);
    const version = try self.allocator.dupe(u8, std.mem.span(alpm.alpm_pkg_get_version(pkg)));
    return .{ .name = name, .version = version };
}

/// True if `ver_a` is a newer alpm version than `ver_b`.
pub fn isNewerThan(allocator: std.mem.Allocator, ver_a: []const u8, ver_b: []const u8) Error!bool {
    const ver_a_sentinel = try std.mem.concatWithSentinel(allocator, u8, &.{ver_a}, 0);
    defer allocator.free(ver_a_sentinel);
    const ver_b_sentinel = try std.mem.concatWithSentinel(allocator, u8, &.{ver_b}, 0);
    defer allocator.free(ver_b_sentinel);

    const ver_a_cstr: [*c]const u8 = @ptrCast(ver_a_sentinel.ptr);
    const ver_b_cstr: [*c]const u8 = @ptrCast(ver_b_sentinel.ptr);

    const ret = alpm.alpm_pkg_vercmp(ver_a_cstr, ver_b_cstr);
    if (ret == 1) {
        return true;
    }
    return false;
}

const testing = std.testing;

test "isNewerThan follows libalpm version ordering" {
    const cases = [_]struct {
        candidate: []const u8,
        installed: []const u8,
        newer: bool,
    }{
        .{ .candidate = "2.0.0", .installed = "1.0.0", .newer = true },
        .{ .candidate = "1.0.0", .installed = "2.0.0", .newer = false },
        .{ .candidate = "1.0.0", .installed = "1.0.0", .newer = false },
        .{ .candidate = "2:1.0-1", .installed = "1:9.0-9", .newer = true },
        .{ .candidate = "1.0-2", .installed = "1.0-1", .newer = true },
    };

    for (cases) |case| {
        try testing.expectEqual(
            case.newer,
            try isNewerThan(testing.allocator, case.candidate, case.installed),
        );
    }
}

test "satisfies uses dependency constraints and provision versions" {
    const cases = [_]struct {
        dependency: []const u8,
        version: []const u8,
        provides: []const []const u8 = &.{},
        expected: bool,
    }{
        .{ .dependency = "foo>=2", .version = "1", .expected = false },
        .{ .dependency = "foo>=2", .version = "2", .expected = true },
        .{ .dependency = "foo<2", .version = "2", .expected = false },
        .{ .dependency = "foo<=2", .version = "2", .expected = true },
        .{ .dependency = "foo>2", .version = "3", .expected = true },
        .{ .dependency = "foo=2", .version = "3", .expected = false },
        .{ .dependency = "foo>=2:1", .version = "1:99", .expected = false },
        .{ .dependency = "virtual", .version = "99", .provides = &.{"virtual"}, .expected = true },
        .{ .dependency = "virtual>=2", .version = "99", .provides = &.{"virtual"}, .expected = false },
        .{ .dependency = "virtual>=2", .version = "99", .provides = &.{"virtual=1"}, .expected = false },
        .{ .dependency = "virtual>=2", .version = "1", .provides = &.{"virtual=2"}, .expected = true },
    };
    for (cases) |case| {
        try testing.expectEqual(case.expected, try satisfies(
            testing.allocator,
            case.dependency,
            "foo",
            case.version,
            case.provides,
        ));
    }
}
