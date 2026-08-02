const std = @import("std");
const Io = std.Io;

const Request = @import("req.zig").Request;
const pacman = @import("pacman.zig");

const Host = "https://aur.archlinux.org/rpc/?v=5";

pub const Snapshot = "https://aur.archlinux.org/cgit/aur.git/snapshot";

/// Which field the RPC `search` endpoint matches against.
pub const SearchBy = enum {
    name,
    name_desc,

    fn field(self: SearchBy) []const u8 {
        return switch (self) {
            .name => "name",
            .name_desc => "name-desc",
        };
    }
};

fn RPCResp(comptime T: type) type {
    return struct {
        version: usize,
        type: []const u8,
        resultcount: usize,
        results: []T,
    };
}

pub const RPCRespV5 = RPCResp(Info);
pub const RPCSearchRespV5 = RPCResp(Search);

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
    /// Unix epoch seconds; null if the package is not flagged out-of-date.
    OutOfDate: ?i64 = null,
    Maintainer: ?[]const u8 = null,
    /// Unix epoch seconds.
    FirstSubmitted: i64,
    /// Unix epoch seconds.
    LastModified: i64,
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
    /// Unix epoch seconds; null if the package is not flagged out-of-date.
    OutOfDate: ?i64 = null,
    Maintainer: ?[]const u8 = null,
    /// Unix epoch seconds.
    FirstSubmitted: i64,
    /// Unix epoch seconds.
    LastModified: i64,
    URLPath: []const u8,
};

pub fn queryAll(allocator: std.mem.Allocator, io: Io, pkgs: std.StringHashMap(*pacman.Package)) !RPCRespV5 {
    const uri = try buildInfoQuery(allocator, pkgs);

    const http = try Request.init(allocator, io);
    defer http.deinit();
    const body = try http.getRequest(uri);

    const result = try std.json.parseFromSlice(RPCRespV5, allocator, body, .{ .ignore_unknown_fields = true });

    return result.value;
}

pub fn search(allocator: std.mem.Allocator, io: Io, search_name: []const u8, by: SearchBy) !RPCSearchRespV5 {
    var uri: std.ArrayList(u8) = .empty;
    defer uri.deinit(allocator);

    try uri.appendSlice(allocator, Host);
    try uri.appendSlice(allocator, "&type=search&by=");
    try uri.appendSlice(allocator, by.field());
    try uri.appendSlice(allocator, "&arg=");
    try uri.appendSlice(allocator, search_name);

    const http = try Request.init(allocator, io);
    defer http.deinit();

    const body = try http.getRequest(uri.items);

    const result = try std.json.parseFromSlice(RPCSearchRespV5, allocator, body, .{ .ignore_unknown_fields = true });

    return result.value;
}

fn buildInfoQuery(allocator: std.mem.Allocator, pkgs: std.StringHashMap(*pacman.Package)) ![]const u8 {
    var uri: std.ArrayList(u8) = .empty;
    errdefer uri.deinit(allocator);

    try uri.appendSlice(allocator, Host);
    try uri.appendSlice(allocator, "&type=info");

    var pkgs_iter = pkgs.iterator();
    while (pkgs_iter.next()) |pkg| {
        try uri.appendSlice(allocator, "&arg[]=");
        try uri.appendSlice(allocator, pkg.key_ptr.*);
    }
    return try uri.toOwnedSlice(allocator);
}

const testing = std.testing;

test "buildInfoQuery - builds correct URL with packages" {
    var pkgs = std.StringHashMap(*pacman.Package).init(testing.allocator);
    defer pkgs.deinit();

    const pkg1 = try pacman.Package.init(testing.allocator, "1.0.0");
    defer testing.allocator.destroy(pkg1);
    try pkgs.put("neovim-git", pkg1);

    const result = try buildInfoQuery(testing.allocator, pkgs);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.containsAtLeast(u8, result, 1, Host));
    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "&type=info"));
    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "&arg[]=neovim-git"));
}

test "buildInfoQuery - no memory leaks with testing allocator" {
    var pkgs = std.StringHashMap(*pacman.Package).init(testing.allocator);
    defer pkgs.deinit();

    const pkg1 = try pacman.Package.init(testing.allocator, "1.0");
    defer testing.allocator.destroy(pkg1);
    const pkg2 = try pacman.Package.init(testing.allocator, "2.0");
    defer testing.allocator.destroy(pkg2);

    try pkgs.put("pkg-a", pkg1);
    try pkgs.put("pkg-b", pkg2);

    const result = try buildInfoQuery(testing.allocator, pkgs);
    defer testing.allocator.free(result);

    // Testing allocator will fail if there are leaks
}
