//! Read source metadata without evaluating package build scripts.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const log = std.log.scoped(.srcinfo);

pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

/// Returned slices borrow line; null means the line has no assignment.
pub fn parseLine(line: []const u8) ?Entry {
    const separator = mem.indexOfScalar(u8, line, '=') orelse return null;
    return .{
        .key = mem.trim(u8, line[0..separator], " \t\r"),
        .value = mem.trim(u8, line[separator + 1 ..], " \t\r"),
    };
}

pub const Error = Allocator.Error || error{InvalidSrcinfo};

/// Return the borrowed pkgver, omitting epoch and packaging release.
pub fn upstreamVersion(full_version: []const u8) []const u8 {
    const upstream = full_version[if (mem.indexOfScalar(u8, full_version, ':')) |i| i + 1 else 0..];
    return upstream[0 .. mem.lastIndexOfScalar(u8, upstream, '-') orelse upstream.len];
}

/// Return an owned full version from the pkgbase section. The caller frees it.
pub fn version(allocator: Allocator, contents: []const u8) Error![]u8 {
    var pkgver: ?[]const u8 = null;
    var pkgrel: ?[]const u8 = null;
    var epoch: ?[]const u8 = null;
    var lines = mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const entry = parseLine(line) orelse continue;
        if (mem.eql(u8, entry.key, "pkgname")) break;
        const field = if (mem.eql(u8, entry.key, "pkgver")) &pkgver else if (mem.eql(u8, entry.key, "pkgrel"))
            &pkgrel
        else if (mem.eql(u8, entry.key, "epoch"))
            &epoch
        else
            continue;
        if (field.* != null or entry.value.len == 0) return error.InvalidSrcinfo;
        field.* = entry.value;
    }
    const upstream = pkgver orelse return error.InvalidSrcinfo;
    const release = pkgrel orelse return error.InvalidSrcinfo;
    if (epoch) |prefix| return std.fmt.allocPrint(allocator, "{s}:{s}-{s}", .{
        prefix,
        upstream,
        release,
    });
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ upstream, release });
}

/// Return whether the metadata declares the named split output.
pub fn hasPackage(contents: []const u8, name: []const u8) bool {
    return hasEntry(contents, "pkgname", name);
}

/// Match an assignment after trimming metadata indentation.
pub fn hasEntry(contents: []const u8, key: []const u8, value: []const u8) bool {
    var lines = mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const entry = parseLine(line) orelse continue;
        if (mem.eql(u8, entry.key, key) and mem.eql(u8, entry.value, value)) return true;
    }
    return false;
}
