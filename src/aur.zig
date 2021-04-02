const std = @import("std");

const curl = @import("curl.zig");
const pacman = @import("pacman.zig");

const Host = "https://aur.archlinux.org/rpc/?v=5&type=info";

pub const RPCRespV5 = struct {
    version: usize,
    type: []const u8,
    resultcount: usize,
    results: []Info,
};

pub const Info = struct {
    ID: usize,
    Name: []const u8,
    PackageBaseID: usize,
    PackageBase: []const u8,
    Version: []const u8,
    Description: []const u8,
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

pub fn query(allocator: *std.mem.Allocator, pm: *pacman.Pacman) !RPCRespV5 {
    const uri = try buildInfoQuery(allocator, pm);
    var resp = try curl.get(allocator, uri);
    defer resp.deinit();

    // TODO: just setting this arbitrarily high so I can kick the can
    @setEvalBranchQuota(100000);
    var json_resp = std.json.TokenStream.init(resp.items);
    var result = try std.json.parse(RPCRespV5, &json_resp, std.json.ParseOptions{ .allocator = allocator });
    // defer std.json.parseFree(aur.RPCRespV5, result, std.json.ParseOptions{ .allocator = allocator });

    return result;
}

fn buildInfoQuery(allocator: *std.mem.Allocator, pm: *pacman.Pacman) ![*:0]const u8 {
    var uri = std.ArrayList(u8).init(allocator);
    try uri.appendSlice(Host);

    var pkgsIter = pm.pkgs.iterator();
    while (pkgsIter.next()) |pkg| {
        try uri.appendSlice("&arg[]=");

        var copyKey = try allocator.alloc(u8, pkg.key.len);
        std.mem.copy(u8, copyKey, pkg.key);
        try uri.appendSlice(copyKey);
    }
    return try uri.toOwnedSliceSentinel(0);
}
