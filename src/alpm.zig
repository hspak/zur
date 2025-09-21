const std = @import("std");
const alpm = @cImport({
    @cInclude("alpm.h");
});

pub fn is_newer_than(allocator: std.mem.Allocator, ver_a: []const u8, ver_b: []const u8) !bool {
    const ver_a_cstr: [*c]u8 = @ptrCast(try std.fmt.allocPrintSentinel(allocator, "{s}", .{ver_a}, '0'));
    const ver_b_cstr: [*c]u8 = @ptrCast(try std.fmt.allocPrintSentinel(allocator, "{s}", .{ver_b}, '0'));

    const ret = alpm.alpm_pkg_vercmp(ver_a_cstr, ver_b_cstr);
    if (ret == 1) {
        return true;
    }
    return false;
}
