//! Long-lived libalpm handle for local-db and sync-repo queries.

const std = @import("std");
const alpm = @cImport({
    @cInclude("alpm.h");
});

const Alpm = @This();

pub const Error = std.mem.Allocator.Error || error{
    AlpmNoHandle,
    AlpmNoSyncDb,
    AlpmNoLocalDb,
    AlpmNoCache,
};

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
const repos = [_][*:0]const u8{ "core", "extra", "multilib" };

const sig_level = alpm.ALPM_SIG_PACKAGE_OPTIONAL | alpm.ALPM_SIG_DATABASE_OPTIONAL;

/// Open a libalpm handle and register the sync repos. Expensive; reuse one instance.
pub fn init(allocator: std.mem.Allocator) Error!Alpm {
    var err: alpm.alpm_errno_t = 0;
    const handle = alpm.alpm_initialize("/", "/var/lib/pacman/", &err) orelse {
        return error.AlpmNoHandle;
    };
    errdefer _ = alpm.alpm_release(handle);

    // We only read each repo's package cache (never sync or verify), so a
    // permissive signature level is fine here.
    for (repos) |repo| {
        if (alpm.alpm_register_syncdb(handle, repo, sig_level) == null) {
            return error.AlpmNoSyncDb;
        }
    }

    const local_db = alpm.alpm_get_localdb(handle) orelse return error.AlpmNoLocalDb;

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
    const cache = alpm.alpm_db_get_pkgcache(self.local_db) orelse return error.AlpmNoCache;

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
            const version_copy = try self.allocator.dupe(u8, std.mem.span(alpm.alpm_pkg_get_version(@constCast(pkg))));
            errdefer self.allocator.free(version_copy);
            try list.append(self.allocator, .{
                .name = name_copy,
                .version = version_copy,
            });
        }
    }
    return try list.toOwnedSlice(self.allocator);
}

/// True if a package `name` is installed in the local database.
pub fn isInstalled(self: *Alpm, name: []const u8) Error!bool {
    const name_cstr = try std.mem.concatWithSentinel(self.allocator, u8, &.{name}, 0);
    defer self.allocator.free(name_cstr);
    return alpm.alpm_db_get_pkg(self.local_db, @ptrCast(name_cstr.ptr)) != null;
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

test "isNewerThan - basic version comparison" {
    // Test that newer version is detected
    try testing.expect(try isNewerThan(testing.allocator, "2.0.0", "1.0.0"));
    try testing.expect(!try isNewerThan(testing.allocator, "1.0.0", "2.0.0"));
    try testing.expect(!try isNewerThan(testing.allocator, "1.0.0", "1.0.0"));
}
