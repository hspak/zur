const std = @import("std");
const alpm = @cImport({
    @cInclude("alpm.h");
});

pub fn is_newer_than(allocator: std.mem.Allocator, ver_a: []const u8, ver_b: []const u8) !bool {
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

/// The sync repos zur knows about. Hardcoded to the standard core/extra/multilib
/// set, which covers the default Arch installation zur targets.
const repos = [_][*:0]const u8{ "core", "extra", "multilib" };

/// A package installed locally, with its name and version. The slices are
/// copies owned by the caller's allocator.
pub const ForeignPackage = struct {
    name: []const u8,
    version: []const u8,
};

/// A long-lived libalpm handle. Initializing/releasing alpm is expensive, so
/// one `Alpm` instance is created up front and reused for every local-db
/// query. The sync repos are registered once here.
pub const Alpm = struct {
    allocator: std.mem.Allocator,
    handle: *alpm.alpm_handle_t,
    local_db: *alpm.alpm_db_t,

    pub fn init(allocator: std.mem.Allocator) !Alpm {
        var err: alpm.alpm_errno_t = 0;
        const handle = alpm.alpm_initialize("/", "/var/lib/pacman/", &err) orelse {
            return error.AlpmInitFailed;
        };
        errdefer _ = alpm.alpm_release(handle);

        // We only read each repo's package cache (never sync or verify), so a
        // permissive signature level is fine here.
        for (repos) |repo| {
            if (alpm.alpm_register_syncdb(handle, repo, sig_level) == null) {
                return error.AlpmRegisterDbFailed;
            }
        }

        const local_db = alpm.alpm_get_localdb(handle) orelse return error.AlpmNoLocalDb;

        return .{
            .allocator = allocator,
            .handle = handle,
            .local_db = local_db,
        };
    }

    pub fn deinit(self: *Alpm) void {
        _ = alpm.alpm_release(self.handle);
    }

    /// Enumerate installed packages that are not present in any registered sync
    /// repository ("foreign" / AUR packages, i.e. what `pacman -Qm` lists).
    /// The returned name/version strings are duped into `self.allocator`; the
    /// caller owns the returned slice.
    pub fn fetchForeignPackages(self: *Alpm) ![]ForeignPackage {
        const cache = alpm.alpm_db_get_pkgcache(self.local_db) orelse return error.AlpmNoCache;

        var list: std.ArrayList(ForeignPackage) = .empty;
        defer list.deinit(self.allocator);

        var node = cache;
        while (node != null) : (node = node.*.next) {
            const pkg: *const alpm.alpm_pkg_t = @ptrCast(node.*.data);
            const name = std.mem.span(alpm.alpm_pkg_get_name(@constCast(pkg)));
            if (!self.isInSyncDbs(name)) {
                try list.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, name),
                    .version = try self.allocator.dupe(u8, std.mem.span(alpm.alpm_pkg_get_version(@constCast(pkg)))),
                });
            }
        }
        return try list.toOwnedSlice(self.allocator);
    }

    /// True if a package `name` is installed in the local database.
    pub fn isInstalled(self: *Alpm, name: []const u8) !bool {
        const name_cstr = try std.mem.concatWithSentinel(self.allocator, u8, &.{name}, 0);
        defer self.allocator.free(name_cstr);
        return alpm.alpm_db_get_pkg(self.local_db, @ptrCast(name_cstr.ptr)) != null;
    }

    /// True if `name` appears in any of the registered sync database caches.
    fn isInSyncDbs(self: *Alpm, name: []const u8) bool {
        var dbs = alpm.alpm_get_syncdbs(self.handle);
        while (dbs != null) : (dbs = dbs.*.next) {
            const sync_db: *const alpm.alpm_db_t = @ptrCast(dbs.*.data);
            if (alpm.alpm_db_get_pkg(@constCast(sync_db), @ptrCast(name.ptr)) != null) return true;
        }
        return false;
    }
};

const sig_level = alpm.ALPM_SIG_PACKAGE_OPTIONAL | alpm.ALPM_SIG_DATABASE_OPTIONAL;

const testing = std.testing;

test "is_newer_than - basic version comparison" {
    // Test that newer version is detected
    try testing.expect(try is_newer_than(testing.allocator, "2.0.0", "1.0.0"));
    try testing.expect(!try is_newer_than(testing.allocator, "1.0.0", "2.0.0"));
    try testing.expect(!try is_newer_than(testing.allocator, "1.0.0", "1.0.0"));
}
