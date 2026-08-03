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

/// A package installed locally, with its name and version. The slices are
/// copies owned by the caller's allocator.
pub const ForeignPackage = struct {
    name: []const u8,
    version: []const u8,
};

/// Enumerate installed packages that are not present in any configured sync
/// repository ("foreign" / AUR packages, i.e. what `pacman -Qm` lists). The
/// returned name/version strings are duped into `allocator`; the caller owns
/// the returned slice.
///
/// The sync repos are hardcoded to the standard core/extra/multilib set, which
/// covers the default Arch installation zur targets.
pub fn fetchForeignPackages(allocator: std.mem.Allocator) ![]ForeignPackage {
    var err: alpm.alpm_errno_t = 0;
    const handle = alpm.alpm_initialize("/", "/var/lib/pacman/", &err) orelse {
        return error.AlpmInitFailed;
    };
    defer _ = alpm.alpm_release(handle);

    const repos = [_][*:0]const u8{ "core", "extra", "multilib" };
    for (repos) |repo| {
        // We only read each repo's package cache (we never sync or verify), so
        // a permissive signature level is fine here.
        if (alpm.alpm_register_syncdb(handle, repo, sig_level) == null) {
            return error.AlpmRegisterDbFailed;
        }
    }

    const db = alpm.alpm_get_localdb(handle);
    const cache = alpm.alpm_db_get_pkgcache(db) orelse return error.AlpmNoCache;

    var list: std.ArrayList(ForeignPackage) = .empty;
    defer list.deinit(allocator);

    var node = cache;
    while (node != null) : (node = node.*.next) {
        const pkg: *const alpm.alpm_pkg_t = @ptrCast(node.*.data);
        const name = std.mem.span(alpm.alpm_pkg_get_name(@constCast(pkg)));
        if (!isInSyncDbs(handle, name)) {
            try list.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .version = try allocator.dupe(u8, std.mem.span(alpm.alpm_pkg_get_version(@constCast(pkg)))),
            });
        }
    }
    return try list.toOwnedSlice(allocator);
}

const sig_level = alpm.ALPM_SIG_PACKAGE_OPTIONAL | alpm.ALPM_SIG_DATABASE_OPTIONAL;

/// True if `name` appears in any of the registered sync database caches.
fn isInSyncDbs(handle: *const alpm.alpm_handle_t, name: []const u8) bool {
    var dbs = alpm.alpm_get_syncdbs(@constCast(handle));
    while (dbs != null) : (dbs = dbs.*.next) {
        const sync_db: *const alpm.alpm_db_t = @ptrCast(dbs.*.data);
        if (alpm.alpm_db_get_pkg(@constCast(sync_db), @ptrCast(name.ptr)) != null) return true;
    }
    return false;
}

const testing = std.testing;

test "is_newer_than - basic version comparison" {
    // Test that newer version is detected
    try testing.expect(try is_newer_than(testing.allocator, "2.0.0", "1.0.0"));
    try testing.expect(!try is_newer_than(testing.allocator, "1.0.0", "2.0.0"));
    try testing.expect(!try is_newer_than(testing.allocator, "1.0.0", "1.0.0"));
}
