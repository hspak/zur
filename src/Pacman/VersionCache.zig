//! Persistent makepkg caches scoped to each package and upstream version.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;
const mem = std.mem;
const log = std.log.scoped(.version_cache);

const VersionCache = @This();

allocator: Allocator,
io: Io,
root_path: []const u8,
kind: Kind = .sources,

pub const Kind = enum {
    sources,
    logs,
    source_packages,

    pub fn directory(self: Kind) []const u8 {
        return switch (self) {
            .sources => ".sources",
            .logs => ".logs",
            .source_packages => ".source_packages",
        };
    }

    pub fn markerName(self: Kind) []const u8 {
        return if (self == .sources) ".zur-sources" else ".zur-version";
    }
};

pub const Error = Allocator.Error || Dir.OpenError || Dir.CreateDirError ||
    Dir.CreateFileAtomicError || Dir.RenameError || File.OpenError ||
    File.Writer.Error || File.SyncError || error{InvalidSourcePath};

/// Assumes the operation lock is held and build_path is a reviewed, managed
/// build tree. Return an owned version directory path; retain files on failure.
pub fn prepare(self: *VersionCache, build_path: []const u8) Error![]u8 {
    const base = Dir.path.basename(Dir.path.dirname(build_path) orelse return error.InvalidSourcePath);
    const version = Dir.path.basename(build_path);
    if (!safeComponent(base) or !safeComponent(version) or
        mem.startsWith(u8, version, ".zur-")) return error.InvalidSourcePath;
    const expected = try Dir.path.join(self.allocator, &.{
        self.root_path,
        ".build",
        base,
        version,
    });
    defer self.allocator.free(expected);
    if (!mem.eql(u8, expected, build_path)) return error.InvalidSourcePath;
    const path = try Dir.path.join(self.allocator, &.{
        self.root_path,
        self.kind.directory(),
        base,
        version,
    });
    errdefer self.allocator.free(path);
    var root = try Dir.openDirAbsolute(self.io, self.root_path, .{});
    defer root.close(self.io);
    var sources = try self.ensureDir(root, self.kind.directory());
    defer sources.close(self.io);
    var package = try self.ensureDir(sources, base);
    defer package.close(self.io);
    var directory = try self.ensureDir(package, version);
    defer directory.close(self.io);
    try self.writeAtomic(directory, self.kind.markerName(), "1\n");

    log.debug("using {s} cache: {s}", .{ self.kind.directory(), path });
    return path;
}

fn ensureDir(self: *VersionCache, parent: Dir, name: []const u8) !Dir {
    parent.createDir(self.io, name, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return parent.openDir(self.io, name, .{ .follow_symlinks = false });
}

fn writeAtomic(self: *VersionCache, directory: Dir, name: []const u8, bytes: []const u8) !void {
    var file = try directory.createFileAtomic(self.io, name, .{ .replace = true });
    defer file.deinit(self.io);
    try file.file.writeStreamingAll(self.io, bytes);
    try file.file.sync(self.io);
    try file.replace(self.io);
}

fn safeComponent(name: []const u8) bool {
    return name.len != 0 and !mem.eql(u8, name, ".") and !mem.eql(u8, name, "..") and
        mem.indexOfAny(u8, name, "/\\\x00\r\n") == null;
}

test "source cache preparation preserves versioned downloads and working sources" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];
    var cache: VersionCache = .{
        .allocator = allocator,
        .io = testing.io,
        .root_path = root,
    };
    try tmp.dir.createDirPath(testing.io, ".build/example/1/src");
    try tmp.dir.createDirPath(testing.io, ".sources/example/1");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".sources/example/1/HEAD", .data = "cached revision\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".sources/example/1/download.part", .data = "partial download\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".build/example/1/src/compiled", .data = "compiled object\n" });
    const build = try Dir.path.join(allocator, &.{ root, ".build/example/1" });
    defer allocator.free(build);
    const path = try cache.prepare(build);
    defer allocator.free(path);
    const saved = [_]struct { path: []const u8, contents: []const u8 }{
        .{ .path = ".sources/example/1/HEAD", .contents = "cached revision\n" },
        .{ .path = ".sources/example/1/download.part", .contents = "partial download\n" },
    };
    for (saved) |entry| {
        const contents = try tmp.dir.readFileAlloc(testing.io, entry.path, allocator, .unlimited);
        defer allocator.free(contents);
        try testing.expectEqualStrings(entry.contents, contents);
    }
    const compiled = try tmp.dir.readFileAlloc(testing.io, ".build/example/1/src/compiled", allocator, .unlimited);
    defer allocator.free(compiled);
    try testing.expectEqualStrings("compiled object\n", compiled);
    try tmp.dir.createDirPath(testing.io, ".build/example/1/src");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".build/example/1/src/fresh", .data = "reusable checkout\n" });
    const reused = try cache.prepare(build);
    defer allocator.free(reused);
    _ = try tmp.dir.statFile(testing.io, ".build/example/1/src/fresh", .{});
    try testing.expectEqualStrings(path, reused);
}

test "source cache preparation retains ordinary extracted sources" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];
    var cache: VersionCache = .{
        .allocator = allocator,
        .io = testing.io,
        .root_path = root,
    };
    try tmp.dir.createDirPath(testing.io, ".build/example/1/src");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = ".build/example/1/.SRCINFO",
        .data = "pkgbase = example\n\tsource = https://example.test/source.tar.gz\n",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = ".build/example/1/src/compiled",
        .data = "compiled object\n",
    });
    const build = try Dir.path.join(allocator, &.{ root, ".build/example/1" });
    defer allocator.free(build);
    const path = try cache.prepare(build);
    defer allocator.free(path);
    const compiled = try tmp.dir.readFileAlloc(testing.io, ".build/example/1/src/compiled", allocator, .unlimited);
    defer allocator.free(compiled);
    try testing.expectEqualStrings("compiled object\n", compiled);
}

test "log and source package caches reuse version directories" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];
    const build = try Dir.path.join(allocator, &.{ root, ".build/example/1" });
    defer allocator.free(build);
    for ([_]Kind{ .logs, .source_packages }) |kind| {
        var cache: VersionCache = .{
            .allocator = allocator,
            .io = testing.io,
            .root_path = root,
            .kind = kind,
        };
        const parent = try Dir.path.join(allocator, &.{ kind.directory(), "example" });
        defer allocator.free(parent);
        try tmp.dir.createDirPath(testing.io, parent);
        var directory = try tmp.dir.openDir(testing.io, parent, .{});
        defer directory.close(testing.io);
        try directory.createDir(testing.io, "1", .default_dir);
        try directory.writeFile(testing.io, .{ .sub_path = "1/saved", .data = "previous output\n" });
        const before = try directory.statFile(testing.io, "1/saved", .{});
        for (0..2) |_| {
            const path = try cache.prepare(build);
            defer allocator.free(path);
            const after = try directory.statFile(testing.io, "1/saved", .{});
            try testing.expectEqual(before.inode, after.inode);
            const contents = try directory.readFileAlloc(testing.io, "1/saved", allocator, .unlimited);
            defer allocator.free(contents);
            try testing.expectEqualStrings("previous output\n", contents);
        }
    }
}

test "source cache rejects redirected parents and version directories" {
    const testing = std.testing;
    const allocator = testing.allocator;
    for ([_][]const u8{
        ".sources",
        ".sources/example",
        ".sources/example/1",
    }) |link| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_buffer: [Dir.max_path_bytes]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];
        var cache: VersionCache = .{
            .allocator = allocator,
            .io = testing.io,
            .root_path = root,
        };
        try tmp.dir.createDirPath(testing.io, ".build/example/1");
        try tmp.dir.createDirPath(testing.io, "outside");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside/keep", .data = "untouched\n" });
        if (Dir.path.dirname(link)) |parent| try tmp.dir.createDirPath(testing.io, parent);
        const outside = try Dir.path.join(allocator, &.{ root, "outside" });
        defer allocator.free(outside);
        try tmp.dir.symLink(testing.io, outside, link, .{});
        const build = try Dir.path.join(allocator, &.{ root, ".build/example/1" });
        defer allocator.free(build);
        if (cache.prepare(build)) |path| {
            allocator.free(path);
            return error.RedirectedSourceCacheAccepted;
        } else |_| {}
        const contents = try tmp.dir.readFileAlloc(testing.io, "outside/keep", allocator, .unlimited);
        defer allocator.free(contents);
        try testing.expectEqualStrings("untouched\n", contents);
        try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "outside/.zur-sources", .{}));
    }
}
