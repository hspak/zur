//! AUR RPC client: info/search queries and the snapshot download URL.

const std = @import("std");
const Io = std.Io;

const Request = @import("Request.zig");
const Pacman = @import("Pacman.zig");

pub const Error = std.mem.Allocator.Error || Request.Error || std.json.ParseError(std.json.Scanner);

const host = "https://aur.archlinux.org/rpc/?v=5";

pub const snapshot = "https://aur.archlinux.org/cgit/aur.git/snapshot";

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
        const Self = @This();

        version: usize,
        type: []const u8,
        resultcount: usize,
        results: []T,
    };
}

pub const RPCRespV5 = RPCResp(Info);
pub const RPCSearchRespV5 = RPCResp(Search);

// Wire names match the AUR RPC JSON object; public Info/Search are snake_case.
const InfoJson = struct {
    ID: usize,
    Name: []const u8,
    PackageBaseID: usize,
    PackageBase: []const u8,
    Version: []const u8,
    Description: ?[]const u8 = null,
    URL: []const u8,
    NumVotes: usize,
    Popularity: f64,
    OutOfDate: ?i64 = null,
    Maintainer: ?[]const u8 = null,
    FirstSubmitted: i64,
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

const SearchJson = struct {
    ID: usize,
    Name: []const u8,
    PackageBaseID: usize,
    PackageBase: []const u8,
    Version: []const u8,
    Description: ?[]const u8 = null,
    URL: ?[]const u8 = null,
    NumVotes: usize,
    Popularity: f64,
    OutOfDate: ?i64 = null,
    Maintainer: ?[]const u8 = null,
    FirstSubmitted: i64,
    LastModified: i64,
    URLPath: []const u8,
};

pub const Info = struct {
    id: usize,
    name: []const u8,
    package_base_id: usize,
    package_base: []const u8,
    version: []const u8,
    description: ?[]const u8 = null,
    url: []const u8,
    num_votes: usize,
    popularity: f64,
    /// Unix epoch seconds; null if the package is not flagged out-of-date.
    out_of_date: ?i64 = null,
    maintainer: ?[]const u8 = null,
    /// Unix epoch seconds.
    first_submitted: i64,
    /// Unix epoch seconds.
    last_modified: i64,
    url_path: []const u8,
    depends: ?[][]const u8 = null,
    make_depends: ?[][]const u8 = null,
    opt_depends: ?[][]const u8 = null,
    check_depends: ?[][]const u8 = null,
    conflicts: ?[][]const u8 = null,
    provides: ?[][]const u8 = null,
    replaces: ?[][]const u8 = null,
    groups: ?[][]const u8 = null,
    license: ?[][]const u8 = null,
    keywords: ?[][]const u8 = null,
};

pub const Search = struct {
    id: usize,
    name: []const u8,
    package_base_id: usize,
    package_base: []const u8,
    version: []const u8,
    description: ?[]const u8 = null,
    url: ?[]const u8 = null,
    num_votes: usize,
    popularity: f64,
    /// Unix epoch seconds; null if the package is not flagged out-of-date.
    out_of_date: ?i64 = null,
    maintainer: ?[]const u8 = null,
    /// Unix epoch seconds.
    first_submitted: i64,
    /// Unix epoch seconds.
    last_modified: i64,
    url_path: []const u8,
};

fn infoFromJson(j: InfoJson) Info {
    return .{
        .id = j.ID,
        .name = j.Name,
        .package_base_id = j.PackageBaseID,
        .package_base = j.PackageBase,
        .version = j.Version,
        .description = j.Description,
        .url = j.URL,
        .num_votes = j.NumVotes,
        .popularity = j.Popularity,
        .out_of_date = j.OutOfDate,
        .maintainer = j.Maintainer,
        .first_submitted = j.FirstSubmitted,
        .last_modified = j.LastModified,
        .url_path = j.URLPath,
        .depends = j.Depends,
        .make_depends = j.MakeDepends,
        .opt_depends = j.OptDepends,
        .check_depends = j.CheckDepends,
        .conflicts = j.Conflicts,
        .provides = j.Provides,
        .replaces = j.Replaces,
        .groups = j.Groups,
        .license = j.License,
        .keywords = j.Keywords,
    };
}

fn searchFromJson(j: SearchJson) Search {
    return .{
        .id = j.ID,
        .name = j.Name,
        .package_base_id = j.PackageBaseID,
        .package_base = j.PackageBase,
        .version = j.Version,
        .description = j.Description,
        .url = j.URL,
        .num_votes = j.NumVotes,
        .popularity = j.Popularity,
        .out_of_date = j.OutOfDate,
        .maintainer = j.Maintainer,
        .first_submitted = j.FirstSubmitted,
        .last_modified = j.LastModified,
        .url_path = j.URLPath,
    };
}

fn mapInfoResp(allocator: std.mem.Allocator, json_resp: RPCResp(InfoJson)) !RPCRespV5 {
    const results = try allocator.alloc(Info, json_resp.results.len);
    for (json_resp.results, results) |item, *out| {
        out.* = infoFromJson(item);
    }
    return .{
        .version = json_resp.version,
        .type = json_resp.type,
        .resultcount = json_resp.resultcount,
        .results = results,
    };
}

fn mapSearchResp(allocator: std.mem.Allocator, json_resp: RPCResp(SearchJson)) !RPCSearchRespV5 {
    const results = try allocator.alloc(Search, json_resp.results.len);
    for (json_resp.results, results) |item, *out| {
        out.* = searchFromJson(item);
    }
    return .{
        .version = json_resp.version,
        .type = json_resp.type,
        .resultcount = json_resp.resultcount,
        .results = results,
    };
}

/// Fetch AUR info for every key in `pkgs`.
///
/// Strings inside the returned value are allocated from `allocator` (leaky
/// JSON parse). The caller owns `results` and must free that slice; the
/// string graph is freed with `allocator` (use an arena, or accept the leak
/// until the allocator is torn down).
pub fn queryAll(allocator: std.mem.Allocator, request: *Request, pkgs: std.StringHashMapUnmanaged(*Pacman.Package)) Error!RPCRespV5 {
    const uri = try buildInfoQuery(allocator, pkgs);
    defer allocator.free(uri);

    const body = try request.getRequest(uri);
    defer allocator.free(body);

    const json_resp = try std.json.parseFromSliceLeaky(RPCResp(InfoJson), allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    return try mapInfoResp(allocator, json_resp);
}

/// Query the AUR for a single package's full info (including its Depends /
/// MakeDepends lists). Returns null if `name` is not an AUR package, which is
/// how callers distinguish AUR-only deps from official/repo deps.
///
/// Strings inside the returned `Info` are allocated from `allocator` and are
/// not freed here (same lifetime as `queryAll`).
pub fn queryName(allocator: std.mem.Allocator, request: *Request, name: []const u8) Error!?Info {
    var uri: std.ArrayList(u8) = .empty;
    defer uri.deinit(allocator);

    try uri.appendSlice(allocator, host);
    try uri.appendSlice(allocator, "&type=info&arg[]=");
    try uri.appendSlice(allocator, name);

    const body = try request.getRequest(uri.items);
    defer allocator.free(body);

    const json_resp = try std.json.parseFromSliceLeaky(RPCResp(InfoJson), allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    if (json_resp.resultcount == 0) return null;
    return infoFromJson(json_resp.results[0]);
}

/// Search the AUR. The caller owns `results` and must free that slice.
/// Strings inside each hit are allocated from `allocator` (same lifetime
/// as `queryAll`).
pub fn search(allocator: std.mem.Allocator, request: *Request, search_name: []const u8, by: SearchBy) Error!RPCSearchRespV5 {
    var uri: std.ArrayList(u8) = .empty;
    defer uri.deinit(allocator);

    try uri.appendSlice(allocator, host);
    try uri.appendSlice(allocator, "&type=search&by=");
    try uri.appendSlice(allocator, by.field());
    try uri.appendSlice(allocator, "&arg=");
    try uri.appendSlice(allocator, search_name);

    const body = try request.getRequest(uri.items);
    defer allocator.free(body);

    const json_resp = try std.json.parseFromSliceLeaky(RPCResp(SearchJson), allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    return try mapSearchResp(allocator, json_resp);
}

fn buildInfoQuery(allocator: std.mem.Allocator, pkgs: std.StringHashMapUnmanaged(*Pacman.Package)) ![]const u8 {
    var uri: std.ArrayList(u8) = .empty;
    errdefer uri.deinit(allocator);

    try uri.appendSlice(allocator, host);
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
    var pkgs: std.StringHashMapUnmanaged(*Pacman.Package) = .empty;
    defer pkgs.deinit(testing.allocator);

    const pkg1 = try testing.allocator.create(Pacman.Package);
    defer testing.allocator.destroy(pkg1);
    pkg1.* = .init("1.0.0");
    try pkgs.put(testing.allocator, "neovim-git", pkg1);

    const result = try buildInfoQuery(testing.allocator, pkgs);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.containsAtLeast(u8, result, 1, host));
    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "&type=info"));
    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "&arg[]=neovim-git"));
}

test "buildInfoQuery - no memory leaks with testing allocator" {
    var pkgs: std.StringHashMapUnmanaged(*Pacman.Package) = .empty;
    defer pkgs.deinit(testing.allocator);

    const pkg1 = try testing.allocator.create(Pacman.Package);
    defer testing.allocator.destroy(pkg1);
    pkg1.* = .init("1.0");
    const pkg2 = try testing.allocator.create(Pacman.Package);
    defer testing.allocator.destroy(pkg2);
    pkg2.* = .init("2.0");

    try pkgs.put(testing.allocator, "pkg-a", pkg1);
    try pkgs.put(testing.allocator, "pkg-b", pkg2);

    const result = try buildInfoQuery(testing.allocator, pkgs);
    defer testing.allocator.free(result);

    // Testing allocator will fail if there are leaks
}
