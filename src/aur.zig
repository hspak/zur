const std = @import("std");

const Request = @import("req.zig").Request;
const pacman = @import("pacman.zig");

const Host = "https://aur.archlinux.org/rpc/?v=5";

pub const Snapshot = "https://aur.archlinux.org/cgit/aur.git/snapshot";

pub const RPCRespV5 = struct {
    version: usize,
    type: []const u8,
    resultcount: usize,
    results: []Info,
};

// TODO: Maybe some opportunity to de-dep this
pub const RPCSearchRespV5 = struct {
    version: usize,
    type: []const u8,
    resultcount: usize,
    results: []Search,
};

pub const Info = struct {
    ID: usize,
    Name: []const u8,
    PackageBaseID: usize,
    PackageBase: []const u8,
    Version: []const u8,
    Description: ?[]const u8 = null,
    URL: []const u8,
    NumVotes: usize,
    Popularity: f64,
    OutOfDate: ?i32 = null, // TODO: parse this unixtime
    Maintainer: ?[]const u8 = null,
    FirstSubmitted: i32, // TODO: parse this unixtime
    LastModified: i32, // TODO: parse this unixtime
    URLPath: []const u8,
    Depends: ?[][]const u8 = null,
    MakeDepends: ?[][]const u8 = null,
    OptDepends: ?[][]const u8 = null,
    CheckDepends: ?[][]const u8 = null,
    Conflicts: ?[][]const u8 = null,
    Provides: ?[][]const u8 = null,
    Replaces: ?[][]const u8 = null,
    Groups: ?[][]const u8 = null,
    License: ?[][]const u8 = null,
    Keywords: ?[][]const u8 = null,
};

pub const Search = struct {
    ID: usize,
    Name: []const u8,
    PackageBaseID: usize,
    PackageBase: []const u8,
    Version: []const u8,
    Description: ?[]const u8 = null,
    URL: ?[]const u8 = null,
    NumVotes: usize,
    Popularity: f64,
    OutOfDate: ?i32 = null, // TODO: parse this unixtime
    Maintainer: ?[]const u8 = null,
    FirstSubmitted: i32, // TODO: parse this unixtime
    LastModified: i32, // TODO: parse this unixtime
    URLPath: []const u8,
};

pub fn queryAll(allocator: std.mem.Allocator, pkgs: std.StringHashMap(*pacman.Package)) !RPCRespV5 {
    const uri = try buildInfoQuery(allocator, pkgs);
    const url = try std.Uri.parse(uri);

    const http = try Request.init(allocator);
    defer http.deinit();
    const body = try http.request(.GET, url);

    const result = try std.json.parseFromSlice(RPCRespV5, allocator, body, .{ .ignore_unknown_fields = true });

    return result.value;
}

pub fn search(allocator: std.mem.Allocator, search_name: []const u8) !RPCSearchRespV5 {
    var uri = std.ArrayList(u8).init(allocator);

    try uri.appendSlice(Host);
    try uri.appendSlice("&type=search&by=name&arg="); // TODO: maybe consider opening this up
    try uri.appendSlice(search_name);

    const http = try Request.init(allocator);
    defer http.deinit();

    const url = try std.Uri.parse(try uri.toOwnedSlice());
    const body = try http.request(.GET, url);

    const result = try std.json.parseFromSlice(RPCSearchRespV5, allocator, body, .{ .ignore_unknown_fields = true });

    return result.value;
}

fn buildInfoQuery(allocator: std.mem.Allocator, pkgs: std.StringHashMap(*pacman.Package)) ![]const u8 {
    var uri = std.ArrayList(u8).init(allocator);

    try uri.appendSlice(Host);
    try uri.appendSlice("&type=info");

    var pkgs_iter = pkgs.iterator();
    while (pkgs_iter.next()) |pkg| {
        try uri.appendSlice("&arg[]=");

        const copyKey = try allocator.alloc(u8, pkg.key_ptr.*.len);
        std.mem.copyForwards(u8, copyKey, pkg.key_ptr.*);
        try uri.appendSlice(copyKey);
        defer allocator.free(copyKey);
    }
    return try uri.toOwnedSlice();
}
