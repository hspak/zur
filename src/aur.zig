//! AUR RPC client: info/search queries and the snapshot download URL.

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.aur);

const Request = @import("Request.zig");

const ErrorSet = std.mem.Allocator.Error || Request.Error || std.json.ParseError(std.json.Scanner) ||
    error{ RpcRejected, InvalidRpcResponse, QueryTooLong };
pub const Error = ErrorSet;

const host = "https://aur.archlinux.org/rpc/?v=5";
// Stay below the official instance's documented 4443-byte URI limit.
// https://wiki.archlinux.org/title/Aurweb_RPC_interface
const max_query_bytes: usize = 4096;

pub const packages = "https://aur.archlinux.org/packages";
pub const snapshot = "https://aur.archlinux.org/cgit/aur.git/snapshot";

/// Which field the RPC `search` endpoint matches against.
pub const SearchBy = enum {
    name,
    name_desc,
    provides,

    fn field(self: SearchBy) []const u8 {
        return switch (self) {
            .name => "name",
            .name_desc => "name-desc",
            .provides => "provides",
        };
    }
};

fn RpcResp(comptime T: type) type {
    return struct {
        const Self = @This();

        version: usize,
        type: []const u8,
        resultcount: usize = 0,
        results: []T = &.{},
        @"error": ?[]const u8 = null,
    };
}

pub const RpcRespV5 = RpcResp(Info);
pub const RpcSearchRespV5 = RpcResp(Search);

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

fn mapSearchResp(allocator: std.mem.Allocator, json_resp: RpcResp(SearchJson)) !RpcSearchRespV5 {
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

fn parseResponse(comptime T: type, allocator: std.mem.Allocator, body: []const u8, expected_type: []const u8) Error!RpcResp(T) {
    const response = try std.json.parseFromSliceLeaky(RpcResp(T), allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    if (response.@"error" != null or std.mem.eql(u8, response.type, "error")) {
        log.warn("AUR rejected the request: {s}", .{response.@"error" orelse "unspecified RPC error"});
        return error.RpcRejected;
    }
    if (response.version != 5 or !std.mem.eql(u8, response.type, expected_type) or
        response.resultcount != response.results.len) return error.InvalidRpcResponse;
    return response;
}

/// Fetch AUR info for the supplied package names.
///
/// Strings inside the returned value are allocated from `allocator` (leaky
/// JSON parse). The caller owns `results` and must free that slice; the
/// string graph is freed with `allocator` (use an arena, or accept the leak
/// until the allocator is torn down).
pub fn queryAll(
    allocator: std.mem.Allocator,
    request: *Request,
    names: []const []const u8,
) Error!RpcRespV5 {
    return queryAllUsing(allocator, request, names);
}

fn queryAllUsing(allocator: std.mem.Allocator, request: anytype, names: []const []const u8) !RpcRespV5 {
    var results: std.ArrayList(Info) = .empty;
    errdefer results.deinit(allocator);
    var offset: usize = 0;
    while (offset < names.len) {
        var uri: std.ArrayList(u8) = .empty;
        defer uri.deinit(allocator);
        try uri.appendSlice(allocator, host ++ "&type=info");
        const start = offset;
        while (offset < names.len) {
            const previous_len = uri.items.len;
            try appendInfoArgument(allocator, &uri, names[offset]);
            if (uri.items.len > max_query_bytes) {
                if (offset == start) return error.QueryTooLong;
                uri.shrinkRetainingCapacity(previous_len);
                break;
            }
            offset += 1;
        }
        const body = try request.get(uri.items);
        defer allocator.free(body);
        const response = try parseResponse(InfoJson, allocator, body, "multiinfo");
        try results.ensureUnusedCapacity(allocator, response.results.len);
        for (response.results) |result| results.appendAssumeCapacity(infoFromJson(result));
    }
    const owned = try results.toOwnedSlice(allocator);
    return .{ .version = 5, .type = "multiinfo", .resultcount = owned.len, .results = owned };
}

/// Query the AUR for a single package's full info (including its Depends /
/// MakeDepends lists). Returns null if `name` is not an AUR package, which is
/// how callers distinguish AUR-only deps from official/repo deps.
///
/// Strings inside the returned `Info` are allocated from `allocator` and are
/// not freed here (same lifetime as `queryAll`).
pub fn queryName(allocator: std.mem.Allocator, request: *Request, name: []const u8) Error!?Info {
    return queryNameUsing(allocator, request, name);
}

fn queryNameUsing(allocator: std.mem.Allocator, request: anytype, name: []const u8) !?Info {
    const uri = try buildInfoQuery(allocator, &.{name});
    defer allocator.free(uri);

    const body = try request.get(uri);
    defer allocator.free(body);

    const json_resp = try parseResponse(InfoJson, allocator, body, "multiinfo");
    if (json_resp.resultcount == 0) return null;
    return infoFromJson(json_resp.results[0]);
}

/// Search the AUR. The caller owns `results` and must free that slice.
/// Strings inside each hit are allocated from `allocator` (same lifetime
/// as `queryAll`).
pub fn search(
    allocator: std.mem.Allocator,
    request: *Request,
    search_name: []const u8,
    by: SearchBy,
) Error!RpcSearchRespV5 {
    return searchUsing(allocator, request, search_name, by);
}

fn searchUsing(allocator: std.mem.Allocator, request: anytype, search_name: []const u8, by: SearchBy) !RpcSearchRespV5 {
    var uri: std.ArrayList(u8) = .empty;
    defer uri.deinit(allocator);

    try uri.appendSlice(allocator, host);
    try uri.appendSlice(allocator, "&type=search&by=");
    try uri.appendSlice(allocator, by.field());
    try uri.appendSlice(allocator, "&arg=");
    try appendQueryValue(allocator, &uri, search_name);

    const body = try request.get(uri.items);
    defer allocator.free(body);

    const json_resp = try parseResponse(SearchJson, allocator, body, "search");

    const response = try mapSearchResp(allocator, json_resp);
    return response;
}

fn appendQueryValue(allocator: std.mem.Allocator, uri: *std.ArrayList(u8), raw: []const u8) !void {
    try uri.print(allocator, "{f}", .{std.fmt.alt(std.Uri.Component{ .raw = raw }, .formatEscaped)});
}

fn appendInfoArgument(allocator: std.mem.Allocator, uri: *std.ArrayList(u8), name: []const u8) !void {
    if (name.len > max_query_bytes) return error.QueryTooLong;
    try uri.appendSlice(allocator, "&arg[]=");
    try appendQueryValue(allocator, uri, name);
}

fn buildInfoQuery(
    allocator: std.mem.Allocator,
    names: []const []const u8,
) ![]const u8 {
    var uri: std.ArrayList(u8) = .empty;
    errdefer uri.deinit(allocator);

    try uri.appendSlice(allocator, host);
    try uri.appendSlice(allocator, "&type=info");

    for (names) |name| {
        try appendInfoArgument(allocator, &uri, name);
        if (uri.items.len > max_query_bytes) return error.QueryTooLong;
    }
    const value = try uri.toOwnedSlice(allocator);
    return value;
}

const testing = std.testing;

test "buildInfoQuery builds the complete single-package URL" {
    const result = try buildInfoQuery(testing.allocator, &.{"neovim-git"});
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(
        "https://aur.archlinux.org/rpc/?v=5&type=info&arg[]=neovim-git",
        result,
    );
}

test "buildInfoQuery includes every package exactly once" {
    const result = try buildInfoQuery(testing.allocator, &.{ "pkg-a", "pkg-b" });
    defer testing.allocator.free(result);

    try testing.expect(std.mem.startsWith(u8, result, host ++ "&type=info"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, result, "&arg[]=pkg-a"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, result, "&arg[]=pkg-b"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, result, "&arg[]="));
}

const TestQueryRequest = struct {
    allocator: std.mem.Allocator,
    expected_url: []const u8,
    response_type: []const u8 = "multiinfo",

    fn get(self: TestQueryRequest, url: []const u8) ![]u8 {
        try testing.expectEqualStrings(self.expected_url, url);
        return std.fmt.allocPrint(self.allocator, "{{\"version\":5,\"type\":\"{s}\",\"resultcount\":0,\"results\":[]}}", .{self.response_type});
    }
};

test "RPC query values preserve plus signs and reserved search characters" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const name_request: TestQueryRequest = .{
        .allocator = allocator,
        .expected_url = host ++ "&type=info&arg[]=libstdc%2B%2B5",
    };
    try testing.expectEqual(null, try queryNameUsing(allocator, name_request, "libstdc++5"));
    const search_request: TestQueryRequest = .{
        .allocator = allocator,
        .expected_url = host ++ "&type=search&by=name&arg=c%2B%2B%20%26%20%23%25%2F%C3%A9",
        .response_type = "search",
    };
    _ = try searchUsing(allocator, search_request, "c++ & #%/é", .name);
    const url = try buildInfoQuery(allocator, &.{"libstdc++5"});
    defer allocator.free(url);
    try testing.expectEqualStrings(name_request.expected_url, url);
}

const TestRpcRequest = struct {
    allocator: std.mem.Allocator,
    body: []const u8,

    fn get(self: TestRpcRequest, _: []const u8) ![]u8 {
        return self.allocator.dupe(u8, self.body);
    }
};

test "RPC errors remain errors instead of empty package results" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const request: TestRpcRequest = .{
        .allocator = arena.allocator(),
        .body = "{\"version\":5,\"type\":\"error\",\"resultcount\":0,\"results\":[],\"error\":\"Too many requests\"}",
    };
    try testing.expectError(error.RpcRejected, queryNameUsing(arena.allocator(), request, "review-cli"));
}

test "RPC rejects inconsistent counts before indexing results" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const request: TestRpcRequest = .{
        .allocator = arena.allocator(),
        .body = "{\"version\":5,\"type\":\"multiinfo\",\"resultcount\":1,\"results\":[]}",
    };
    try testing.expectError(error.InvalidRpcResponse, queryNameUsing(arena.allocator(), request, "review-cli"));
}

const TestBatchRequest = struct {
    allocator: std.mem.Allocator,
    calls: usize = 0,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    fail_on_call: ?usize = null,

    fn get(self: *TestBatchRequest, url: []const u8) ![]u8 {
        self.calls += 1;
        try testing.expect(url.len <= 4096);
        if (self.fail_on_call == self.calls) return error.TestRpcUnavailable;
        var results: std.ArrayList(InfoJson) = .empty;
        defer results.deinit(self.allocator);
        var fields = std.mem.splitSequence(u8, url, "&arg[]=");
        _ = fields.next();
        while (fields.next()) |encoded| {
            const component: std.Uri.Component = .{ .percent_encoded = encoded };
            const name = try component.toRawMaybeAlloc(self.allocator);
            try testing.expect(!self.seen.contains(name));
            try self.seen.put(self.allocator, name, {});
            try results.append(self.allocator, .{
                .ID = self.seen.count(),
                .Name = name,
                .PackageBaseID = self.seen.count(),
                .PackageBase = name,
                .Version = "1-1",
                .URL = "https://example.test",
                .NumVotes = 0,
                .Popularity = 0,
                .FirstSubmitted = 0,
                .LastModified = 0,
                .URLPath = "/snapshot.tar.gz",
            });
        }
        return std.json.Stringify.valueAlloc(self.allocator, .{
            .version = 5,
            .type = "multiinfo",
            .resultcount = results.items.len,
            .results = results.items,
        }, .{});
    }
};

test "RPC info batches by encoded URL bytes and combines every response" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    for (0..80) |index| {
        try names.append(allocator, try std.fmt.allocPrint(allocator, "review-{d}-{s}", .{ index, "lib++" ** 20 }));
    }
    var request: TestBatchRequest = .{ .allocator = allocator };
    defer request.seen.deinit(allocator);
    const response = try queryAllUsing(allocator, &request, names.items);
    defer allocator.free(response.results);
    try testing.expect(request.calls > 1);
    try testing.expectEqual(names.items.len, response.resultcount);
    try testing.expectEqual(names.items.len, request.seen.count());
    for (names.items, response.results) |name, result| try testing.expectEqualStrings(name, result.name);
}

test "RPC info skips empty input and rejects an oversized name before requesting" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var request: TestBatchRequest = .{ .allocator = allocator };
    defer request.seen.deinit(allocator);
    const response = try queryAllUsing(allocator, &request, &.{});
    defer allocator.free(response.results);
    try testing.expectEqual(@as(usize, 0), response.resultcount);
    try testing.expectEqual(@as(usize, 0), request.calls);
    try testing.expectError(error.QueryTooLong, queryAllUsing(allocator, &request, &.{"+" ** 1400}));
    try testing.expectEqual(@as(usize, 0), request.calls);
}

test "RPC info propagates a later batch failure instead of returning partial results" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var request: TestBatchRequest = .{ .allocator = allocator, .fail_on_call = 2 };
    defer request.seen.deinit(allocator);
    try testing.expectError(error.TestRpcUnavailable, queryAllUsing(allocator, &request, &.{
        "first-" ++ "a" ** 2400,
        "second-" ++ "b" ** 2400,
    }));
    try testing.expectEqual(@as(usize, 2), request.calls);
}
