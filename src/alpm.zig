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

const testing = std.testing;

test "is_newer_than - basic version comparison" {
    // Test that newer version is detected
    try testing.expect(try is_newer_than(testing.allocator, "2.0.0", "1.0.0"));
    try testing.expect(!try is_newer_than(testing.allocator, "1.0.0", "2.0.0"));
    try testing.expect(!try is_newer_than(testing.allocator, "1.0.0", "1.0.0"));
}
