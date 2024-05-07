const std = @import("std");
const alpm = @cImport({
    @cInclude("alpm.h");
});

pub fn is_newer_than(allocator: std.mem.Allocator, ver_a: []const u8, ver_b: []const u8) !bool {
    // TODO: there must be a better way to convert a string to null terminated string.
    const ver_a_cstr = try std.fmt.allocPrintZ(allocator, "{s}", .{ver_a});
    const ver_b_cstr = try std.fmt.allocPrintZ(allocator, "{s}", .{ver_b});

    const ret = alpm.alpm_pkg_vercmp(ver_a_cstr, ver_b_cstr);
    if (ret == 1) {
        return true;
    }
    return false;
}
