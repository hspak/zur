const std = @import("std");
const alpm = @cImport({
    @cInclude("alpm.h");
});

pub fn is_newer_than(ver_a: []const u8, ver_b: []const u8) !bool {
    var buf_a: [1024]u8 = undefined;
    var buf_b: [1024]u8 = undefined;
    const ver_a_cstr = try std.fmt.bufPrintZ(&buf_a, "{s}", .{ver_a});
    const ver_b_cstr = try std.fmt.bufPrintZ(&buf_b, "{s}", .{ver_b});

    const ret = alpm.alpm_pkg_vercmp(ver_a_cstr, ver_b_cstr);
    if (ret == 1) {
        return true;
    }
    return false;
}
