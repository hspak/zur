//! Serialize install/update operations and retain the current cache version plus its history.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;
const mem = std.mem;
const log = std.log.scoped(.build_cache);

const color = @import("../color.zig");
const VersionCache = @import("VersionCache.zig");
const retention = @import("retention.zig");
const srcinfo = @import("srcinfo.zig");

const BuildCache = @This();

io: Io,
root: Dir,
root_path: []const u8,
lock: File,
writer: *Io.Writer,

const manifest_name = ".zur-build-files";
const retained_count = retention.total_versions;

const Kind = enum {
    build,
    sources,
    logs,
    source_packages,

    fn cacheKind(self: Kind) ?VersionCache.Kind {
        return switch (self) {
            .build => null,
            .sources => .sources,
            .logs => .logs,
            .source_packages => .source_packages,
        };
    }

    fn directory(self: Kind) []const u8 {
        return if (self.cacheKind()) |kind| kind.directory() else ".build";
    }

    fn label(self: Kind) []const u8 {
        return switch (self) {
            .build => "build",
            .sources => "source",
            .logs => "log",
            .source_packages => "source package",
        };
    }

    fn marker(self: Kind) []const u8 {
        return if (self.cacheKind()) |kind| kind.markerName() else manifest_name;
    }
};

pub const Error = Dir.OpenError || File.OpenError || File.LockError || Io.Writer.Error;

pub const PrepareError = Allocator.Error || Dir.OpenError || Dir.CreateDirError ||
    Dir.Reader.Error || Dir.ReadFileAllocError || Dir.DeleteTreeError || Dir.RenameError ||
    Dir.CreateFileAtomicError || File.OpenError || File.StatError || File.Writer.Error ||
    File.SyncError || error{InvalidBuildPath};

pub const PrepareOptions = struct {
    root_path: []const u8,
    base: []const u8,
    version: []const u8,
};

/// Assumes the operation lock is held. Move reviewed recipe files into
/// .build/<base>/<pkgver>, preserving generated files between attempts. Returns
/// an owned absolute path; on error, the cache remains available for a retry.
pub fn prepare(
    allocator: Allocator,
    io: Io,
    source_path: []const u8,
    options: PrepareOptions,
) PrepareError![]u8 {
    // Keep the upstream version stable across epoch and packaging release changes.
    const pkgver = srcinfo.upstreamVersion(options.version);
    if (!safeComponent(options.base) or !safeComponent(pkgver)) return error.InvalidBuildPath;
    const path = try Dir.path.join(allocator, &.{
        options.root_path,
        ".build",
        options.base,
        pkgver,
    });
    errdefer allocator.free(path);
    var root = try Dir.openDirAbsolute(io, options.root_path, .{});
    defer root.close(io);
    var builds = try ensureDir(io, root, ".build");
    defer builds.close(io);
    var package = try ensureDir(io, builds, options.base);
    defer package.close(io);
    var build = try ensureDir(io, package, pkgver);
    defer build.close(io);
    var source = try Dir.openDirAbsolute(io, source_path, .{ .iterate = true });
    defer source.close(io);

    var scratch: std.heap.ArenaAllocator = .init(allocator);
    defer scratch.deinit();
    const gpa = scratch.allocator();
    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
    const previous = previous: {
        const file = build.openFile(io, manifest_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => break :previous "",
            else => return err,
        };
        defer file.close(io);
        if ((try file.stat(io)).kind != .file) return error.InvalidBuildPath;
        var reader = file.reader(io, &.{});
        break :previous reader.interface.allocRemaining(gpa, .unlimited) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            error.OutOfMemory, error.StreamTooLong => |e| return e,
        };
    };
    var lines = mem.splitScalar(u8, previous, '\n');
    while (lines.next()) |name| {
        if (name.len == 0) continue;
        if (!safeComponent(name) or mem.eql(u8, name, manifest_name)) return error.InvalidBuildPath;
        try names.put(gpa, name, {});
    }
    var fresh: std.ArrayList([]const u8) = .empty;
    var entries = source.iterate();
    while (try entries.next(io)) |entry| {
        if (!safeComponent(entry.name) or mem.eql(u8, entry.name, manifest_name)) return error.InvalidBuildPath;
        const name = try gpa.dupe(u8, entry.name);
        try fresh.append(gpa, name);
        try names.put(gpa, name, {});
    }
    // Record the union first so interrupted refreshes can remove stale recipes
    // on retry. Only top-level names are used, so cached symlinks cannot redirect writes.
    try writeManifest(gpa, io, build, names.keys());
    for (names.keys()) |name| try build.deleteTree(io, name);
    for (fresh.items) |name| try source.rename(name, build, name, io);
    try writeManifest(gpa, io, build, fresh.items);
    return path;
}

fn ensureDir(io: Io, parent: Dir, name: []const u8) !Dir {
    parent.createDir(io, name, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return parent.openDir(io, name, .{ .follow_symlinks = false });
}

fn writeManifest(allocator: Allocator, io: Io, build: Dir, names: []const []const u8) !void {
    const bytes = try mem.join(allocator, "\n", names);
    defer allocator.free(bytes);
    var file = try build.createFileAtomic(io, manifest_name, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, bytes);
    try file.file.sync(io);
    try file.replace(io);
}

fn safeComponent(name: []const u8) bool {
    return name.len != 0 and !mem.eql(u8, name, ".") and !mem.eql(u8, name, "..") and
        mem.indexOfAny(u8, name, "/\\\x00\r\n") == null;
}

/// Hold the operation lock until deinit finishes cleanup. Borrows root_path and
/// writer for that lifetime; the caller must release its snapshots before deinit.
pub fn init(self: *BuildCache, io: Io, root_path: []const u8, writer: *Io.Writer) Error!void {
    const root = try Dir.openDirAbsolute(io, root_path, .{});
    errdefer root.close(io);
    try writer.print("{s}::{s} Acquiring build lock: {s}/.build.lock\n", .{
        color.bold_foreground_blue,
        color.reset,
        root_path,
    });
    try writer.flush();
    // Keep this file after unlocking: unlinking it would let later processes
    // lock a different inode while another process still holds the old one.
    const lock = try root.createFile(io, ".build.lock", .{
        .truncate = false,
        .resolve_beneath = true,
    });
    errdefer lock.close(io);
    if (!try lock.tryLock(io, .exclusive)) {
        try writer.print("{s}::{s} Waiting for another zur install/update to finish\n", .{
            color.bold_foreground_blue,
            color.reset,
        });
        try writer.flush();
        try lock.lock(io, .exclusive);
    }
    self.* = .{
        .io = io,
        .root = root,
        .root_path = root_path,
        .lock = lock,
        .writer = writer,
    };
}

/// Prune old cache versions and unexpected source entries, report cleanup errors,
/// then release the lock. Preserve review archives in .src and package archives
/// in .pkg. Poisons self.
pub fn deinit(self: *BuildCache) void {
    for ([_]Kind{
        .build,
        .sources,
        .logs,
        .source_packages,
    }) |kind| {
        self.cleanup(kind) catch |err| log.debug("cannot clean {s}/{s}: {t}", .{
            self.root_path,
            kind.directory(),
            err,
        });
    }
    self.print("{s}::{s} Releasing build lock: {s}/.build.lock\n", .{
        color.bold_foreground_blue,
        color.reset,
        self.root_path,
    }) catch |err|
        log.debug("cannot report build lock release: {t}", .{err});
    self.lock.close(self.io);
    self.root.close(self.io);
    self.* = undefined;
}

fn cleanup(self: *BuildCache, kind: Kind) !void {
    var builds = self.root.openDir(self.io, kind.directory(), .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer builds.close(self.io);
    var announced = false;
    var bases = builds.iterate();
    while (try bases.next(self.io)) |base| {
        if (base.kind != .directory) {
            if (kind == .sources) try self.announceCleanup(kind, &announced);
            try self.print("  {s} unexpected {s} entry: {s}/{s}/{s}\n", .{
                if (kind == .sources) "Removing" else "Keeping",
                kind.label(),
                self.root_path,
                kind.directory(),
                base.name,
            });
            if (kind == .sources) try builds.deleteTree(self.io, base.name);
            continue;
        }
        self.cleanupBase(kind, builds, base.name, &announced) catch |err| log.debug("cannot clean {s}/{s}/{s}: {t}", .{
            self.root_path,
            kind.directory(),
            base.name,
            err,
        });
    }
}

fn cleanupBase(
    self: *BuildCache,
    kind: Kind,
    builds: Dir,
    name: []const u8,
    announced: *bool,
) !void {
    var base = try builds.openDir(self.io, name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer base.close(self.io);
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    var build_base = if (kind != .build) try self.openBuildBase(name) else null;
    defer if (build_base) |*directory| directory.close(self.io);
    const Entry = struct {
        name: []const u8,
        used: Io.Timestamp,
        retained_build: bool = false,
    };
    var versions: std.ArrayList(Entry) = .empty;
    var entries = base.iterate();
    while (try entries.next(self.io)) |entry| {
        if (entry.kind == .directory) {
            var directory = try base.openDir(self.io, entry.name, .{ .follow_symlinks = false });
            defer directory.close(self.io);
            const manifest = directory.statFile(self.io, kind.marker(), .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            const used: ?Io.Timestamp = if (manifest) |file|
                if (file.kind == .file) file.mtime else null
            else
                null;
            if (used) |timestamp| {
                try versions.append(allocator, .{
                    .name = try allocator.dupe(u8, entry.name),
                    .used = timestamp,
                    .retained_build = if (build_base) |parent| try self.hasBuild(parent, entry.name) else false,
                });
                continue;
            }
        }
        if (kind == .sources) try self.announceCleanup(kind, announced);
        try self.print("  {s} unexpected {s} entry: {s}/{s}/{s}/{s}\n", .{
            if (kind == .sources) "Removing" else "Keeping",
            kind.label(),
            self.root_path,
            kind.directory(),
            name,
            entry.name,
        });
        if (kind == .sources) try base.deleteTree(self.io, entry.name);
    }
    mem.sort(Entry, versions.items, {}, struct {
        fn newer(_: void, a: Entry, b: Entry) bool {
            // Git working copies borrow objects from their source cache. Keep
            // caches used by the surviving build trees before any orphan caches.
            if (a.retained_build != b.retained_build) return a.retained_build;
            if (a.used.nanoseconds != b.used.nanoseconds) return a.used.nanoseconds > b.used.nanoseconds;
            return mem.lessThan(u8, a.name, b.name);
        }
    }.newer);
    for (versions.items[@min(retained_count, versions.items.len)..]) |entry| {
        // A failed build cleanup can leave more referenced caches than the limit.
        if (entry.retained_build) continue;
        try self.announceCleanup(kind, announced);
        try self.print("  Removing {s} directory: {s}/{s}/{s}/{s}\n", .{
            kind.label(),
            self.root_path,
            kind.directory(),
            name,
            entry.name,
        });
        try base.deleteTree(self.io, entry.name);
    }
}

fn announceCleanup(self: *BuildCache, kind: Kind, announced: *bool) Io.Writer.Error!void {
    if (announced.*) return;
    try self.print("{s}::{s} Cleaning {s} directories in {s}/{s}\n", .{
        color.bold_foreground_blue,
        color.reset,
        kind.label(),
        self.root_path,
        kind.directory(),
    });
    announced.* = true;
}

fn openBuildBase(self: *BuildCache, name: []const u8) !?Dir {
    var builds = self.root.openDir(self.io, ".build", .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer builds.close(self.io);
    return builds.openDir(self.io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn hasBuild(self: *BuildCache, base: Dir, version: []const u8) !bool {
    var build = base.openDir(self.io, version, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer build.close(self.io);
    const marker = build.statFile(self.io, manifest_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return marker.kind == .file;
}

fn print(self: *BuildCache, comptime format: []const u8, args: anytype) Io.Writer.Error!void {
    try self.writer.print(format, args);
    try self.writer.flush();
}

test "build cleanup expires old trees and preserves recent trees caches and empty directories" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];
    var output: Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    const abandoned = ".build/example/0";
    try tmp.dir.createDirPath(testing.io, abandoned ++ "/src");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = abandoned ++ "/src/artifact",
        .data = "build output\n",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = abandoned ++ "/.zur-build-files",
        .data = "PKGBUILD\n",
    });
    try tmp.dir.setTimestamps(testing.io, abandoned ++ "/.zur-build-files", .{
        .modify_timestamp = .{ .new = .zero },
    });
    for ([_][]const u8{ "1", "2", "3", "4" }) |name| {
        const path = try Dir.path.join(testing.allocator, &.{ ".build", "example", name });
        defer testing.allocator.free(path);
        try tmp.dir.createDirPath(testing.io, path);
        var directory = try tmp.dir.openDir(testing.io, path, .{});
        defer directory.close(testing.io);
        try directory.writeFile(testing.io, .{ .sub_path = ".zur-build-files", .data = "PKGBUILD\n" });
    }
    const retained = [_][]const u8{
        ".src/example/snapshot.tar.gz",
        ".pkg/example/package.pkg.tar.zst",
        ".sources/example/1/.zur-sources",
        ".sources/example/1/source.tar.gz",
        "example-1-1/PKGBUILD",
        ".build/example/notes",
        ".build/example/not-a-build-id/keep",
    };
    for (retained) |path| {
        try tmp.dir.createDirPath(testing.io, Dir.path.dirname(path).?);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = "keep\n" });
    }
    try tmp.dir.createDirPath(testing.io, ".build/empty");
    {
        var cache: BuildCache = undefined;
        try cache.init(testing.io, root, &output.writer);
        defer cache.deinit();
    }
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, abandoned, .{}));
    _ = try tmp.dir.statFile(testing.io, ".build/empty", .{});
    _ = try tmp.dir.statFile(testing.io, ".build/example/1", .{});
    for (retained) |path| {
        const contents = try tmp.dir.readFileAlloc(testing.io, path, testing.allocator, .unlimited);
        defer testing.allocator.free(contents);
        try testing.expectEqualStrings("keep\n", contents);
    }
    try testing.expect(std.mem.indexOf(u8, output.written(), "Removing build directory:") != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), abandoned) != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "Keeping unexpected build entry:") != null);
}

test "build cleanup does not follow symlinks outside the build tree" {
    const testing = std.testing;
    for ([_][]const u8{
        ".build",
        ".build/linked-base",
        ".build/example/0123456789abcdef0123456789abcdef",
        ".build/example/0123456789abcdef0123456789abcdef/link",
    }) |link| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_buffer: [Dir.max_path_bytes]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];
        var output: Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        try tmp.dir.createDirPath(testing.io, "outside");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside/keep", .data = "untouched\n" });
        if (Dir.path.dirname(link)) |parent| try tmp.dir.createDirPath(testing.io, parent);
        const outside = try Dir.path.join(testing.allocator, &.{ root, "outside" });
        defer testing.allocator.free(outside);
        try tmp.dir.symLink(testing.io, outside, link, .{});
        {
            var cache: BuildCache = undefined;
            try cache.init(testing.io, root, &output.writer);
            defer cache.deinit();
        }
        const contents = try tmp.dir.readFileAlloc(testing.io, "outside/keep", testing.allocator, .unlimited);
        defer testing.allocator.free(contents);
        try testing.expectEqualStrings("untouched\n", contents);
    }
}

test "build operation lock excludes other users and remains reusable after cleanup" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];
    var output: Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    const lock = try tmp.dir.createFile(testing.io, ".build.lock", .{ .read = true });
    defer lock.close(testing.io);
    const before = try lock.stat(testing.io);
    const abandoned = ".build/example/0123456789abcdef0123456789abcdef";
    try tmp.dir.createDirPath(testing.io, abandoned);
    {
        var cache: BuildCache = undefined;
        try cache.init(testing.io, root, &output.writer);
        defer cache.deinit();
        try testing.expect(!try lock.tryLock(testing.io, .exclusive));
        _ = try tmp.dir.statFile(testing.io, abandoned, .{});
    }
    _ = try tmp.dir.statFile(testing.io, abandoned, .{});
    const after = try tmp.dir.statFile(testing.io, ".build.lock", .{});
    try testing.expectEqual(before.inode, after.inode);
    try testing.expect(try lock.tryLock(testing.io, .exclusive));
    defer lock.unlock(testing.io);
    try testing.expect(std.mem.indexOf(u8, output.written(), "Releasing build lock:") != null);
}

test "build cleanup keeps the current and three older versions and refreshes recency" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try tmp.dir.createDirPath(testing.io, "review");
    const source = try Dir.path.join(allocator, &.{ root, "review" });
    defer allocator.free(source);
    const attempts = [_]struct { base: []const u8, version: []const u8 }{
        .{ .base = "other", .version = "1" },
        .{ .base = "other", .version = "2" },
        .{ .base = "other", .version = "3" },
        .{ .base = "example", .version = "4" },
        .{ .base = "example", .version = "1" },
        .{ .base = "example", .version = "9" },
        .{ .base = "example", .version = "4" },
        .{ .base = "example", .version = "2" },
        .{ .base = "example", .version = "8" },
    };
    for (attempts, 0..) |attempt, index| {
        var cache: BuildCache = undefined;
        try cache.init(testing.io, root, &output.writer);
        defer cache.deinit();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "review/PKGBUILD", .data = "recipe\n" });
        const path = try prepare(allocator, testing.io, source, .{
            .root_path = root,
            .base = attempt.base,
            .version = attempt.version,
        });
        defer allocator.free(path);
        var build = try Dir.openDirAbsolute(testing.io, path, .{});
        defer build.close(testing.io);
        if (index < 6) {
            try build.setTimestamps(testing.io, manifest_name, .{
                .modify_timestamp = .{ .new = .fromNanoseconds(@as(i96, @intCast(index + 1)) * std.time.ns_per_s) },
            });
        }
    }
    for ([_][]const u8{
        ".build/other/1/PKGBUILD",
        ".build/other/2/PKGBUILD",
        ".build/other/3/PKGBUILD",
        ".build/example/4/PKGBUILD",
        ".build/example/9/PKGBUILD",
        ".build/example/2/PKGBUILD",
        ".build/example/8/PKGBUILD",
    }) |path| _ = try tmp.dir.statFile(testing.io, path, .{});
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, ".build/example/1", .{}));
    try testing.expect(mem.indexOf(u8, output.written(), "Removing build directory:") != null);
    try testing.expect(mem.indexOf(u8, output.written(), ".build/example/1") != null);
}

test "build preparation rejects redirected directories and escaping manifest entries" {
    const testing = std.testing;
    const allocator = testing.allocator;
    for ([_][]const u8{
        ".build",
        ".build/example",
        ".build/example/1",
        ".build/example/1/.zur-build-files",
    }) |link| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_buffer: [Dir.max_path_bytes]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];
        try tmp.dir.createDirPath(testing.io, "outside");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside/PKGBUILD", .data = "untouched\n" });
        try tmp.dir.createDirPath(testing.io, "review");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "review/PKGBUILD", .data = "new recipe\n" });
        if (Dir.path.dirname(link)) |parent| try tmp.dir.createDirPath(testing.io, parent);
        const outside = try Dir.path.join(allocator, &.{ root, "outside" });
        defer allocator.free(outside);
        try tmp.dir.symLink(testing.io, outside, link, .{});
        const source = try Dir.path.join(allocator, &.{ root, "review" });
        defer allocator.free(source);
        if (prepare(allocator, testing.io, source, .{
            .root_path = root,
            .base = "example",
            .version = "1-1",
        })) |path| {
            allocator.free(path);
            return error.RedirectedBuildAccepted;
        } else |_| {}
        const contents = try tmp.dir.readFileAlloc(testing.io, "outside/PKGBUILD", allocator, .unlimited);
        defer allocator.free(contents);
        try testing.expectEqualStrings("untouched\n", contents);
    }

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];
    try tmp.dir.createDirPath(testing.io, "review");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "review/PKGBUILD", .data = "reviewed\n" });
    const source = try Dir.path.join(allocator, &.{ root, "review" });
    defer allocator.free(source);
    var options: PrepareOptions = .{ .root_path = root, .base = "../outside", .version = "1-1" };
    try testing.expectError(error.InvalidBuildPath, prepare(allocator, testing.io, source, options));
    options.base = "example";
    options.version = "../outside-1";
    try testing.expectError(error.InvalidBuildPath, prepare(allocator, testing.io, source, options));
    options.version = "1-1";
    try tmp.dir.createDirPath(testing.io, ".build/example/1");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = ".build/example/1/.zur-build-files",
        .data = "../../../review\n",
    });
    try testing.expectError(error.InvalidBuildPath, prepare(allocator, testing.io, source, options));
    const contents = try tmp.dir.readFileAlloc(testing.io, "review/PKGBUILD", allocator, .unlimited);
    defer allocator.free(contents);
    try testing.expectEqualStrings("reviewed\n", contents);
}

test "source cleanup preserves retained build mirrors before newer orphan caches" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const retained = [_][]const u8{
        ".build/example/1/.zur-build-files",
        ".build/example/2/.zur-build-files",
        ".build/example/3/.zur-build-files",
        ".build/example/4/.zur-build-files",
        ".sources/example/1/.zur-sources",
        ".sources/example/2/.zur-sources",
        ".sources/example/3/.zur-sources",
        ".sources/example/4/.zur-sources",
        ".sources/other/1/.zur-sources",
        ".sources/other/2/.zur-sources",
        ".sources/other/3/.zur-sources",
        ".sources/other/4/.zur-sources",
    };
    for (retained) |path| {
        try tmp.dir.createDirPath(testing.io, Dir.path.dirname(path).?);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = "keep\n" });
        try tmp.dir.setTimestamps(testing.io, path, .{
            .modify_timestamp = .{ .new = .fromNanoseconds(std.time.ns_per_s) },
        });
    }
    try tmp.dir.createDirPath(testing.io, ".sources/example/unrecognized");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = ".sources/example/unrecognized/keep",
        .data = "unmarked source\n",
    });
    try tmp.dir.createDirPath(testing.io, ".sources/example/orphan");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".sources/example/orphan/.zur-sources", .data = "1\n" });
    try tmp.dir.createDirPath(testing.io, ".sources/other/old");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".sources/other/old/.zur-sources", .data = "1\n" });
    try tmp.dir.setTimestamps(testing.io, ".sources/other/old/.zur-sources", .{
        .modify_timestamp = .{ .new = .zero },
    });
    try tmp.dir.createDirPath(testing.io, "outside");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside/keep", .data = "untouched\n" });
    const outside = try Dir.path.join(allocator, &.{ root, "outside" });
    defer allocator.free(outside);
    try tmp.dir.symLink(testing.io, outside, ".sources/example/orphan/link", .{});
    try tmp.dir.symLink(testing.io, outside, ".sources/example/linked", .{});
    {
        var cache: BuildCache = undefined;
        try cache.init(testing.io, root, &output.writer);
        defer cache.deinit();
    }
    for (retained) |path| _ = try tmp.dir.statFile(testing.io, path, .{});
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, ".sources/example/orphan", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, ".sources/other/old", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, ".sources/example/unrecognized", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, ".sources/example/linked", .{
        .follow_symlinks = false,
    }));
    const contents = try tmp.dir.readFileAlloc(testing.io, "outside/keep", allocator, .unlimited);
    defer allocator.free(contents);
    try testing.expectEqualStrings("untouched\n", contents);
}

test "source cleanup removes unexpected entries without following symlinks" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const retained = [_][]const u8{
        ".sources/example/1/.zur-sources",
        ".sources/example/1/download.tar.gz",
        ".build/example/notes",
        ".logs/example/notes",
        ".source_packages/example/notes",
        "outside/keep",
    };
    for (retained) |path| {
        try tmp.dir.createDirPath(testing.io, Dir.path.dirname(path).?);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = "1\n" });
    }
    for ([_][]const u8{
        ".sources/example/.zur-source-layout",
        ".sources/legacy/download.tar.gz",
        ".sources/legacy/.zur-source-pending/download.tar.gz",
        ".sources/stray-file",
        ".sources/example/stray-file",
        ".sources/example/unrecognized/nested/download",
        ".sources/example/invalid-marker/.zur-sources/stray-file",
    }) |path| {
        try tmp.dir.createDirPath(testing.io, Dir.path.dirname(path).?);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = "discard\n" });
    }
    const outside = try Dir.path.join(allocator, &.{ root, "outside" });
    defer allocator.free(outside);
    for ([_][]const u8{
        ".sources/linked-base",
        ".sources/example/linked-version",
        ".sources/example/unrecognized/link",
    }) |path| try tmp.dir.symLink(testing.io, outside, path, .{});
    try tmp.dir.symLink(testing.io, "missing", ".sources/example/dangling", .{});
    const removed = [_][]const u8{
        ".sources/example/.zur-source-layout",
        ".sources/legacy/download.tar.gz",
        ".sources/legacy/.zur-source-pending",
        ".sources/stray-file",
        ".sources/linked-base",
        ".sources/example/stray-file",
        ".sources/example/unrecognized",
        ".sources/example/invalid-marker",
        ".sources/example/linked-version",
        ".sources/example/dangling",
    };
    {
        var cache: BuildCache = undefined;
        try cache.init(testing.io, root, &output.writer);
        defer cache.deinit();
    }
    for (removed) |path| {
        try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, path, .{
            .follow_symlinks = false,
        }));
        const message = try std.fmt.allocPrint(
            allocator,
            "Removing unexpected source entry: {s}/{s}\n",
            .{ root, path },
        );
        defer allocator.free(message);
        try testing.expect(mem.indexOf(u8, output.written(), message) != null);
    }
    for (retained) |path| {
        const contents = try tmp.dir.readFileAlloc(testing.io, path, allocator, .unlimited);
        defer allocator.free(contents);
        try testing.expectEqualStrings("1\n", contents);
    }
    try testing.expect(mem.indexOf(u8, output.written(), "Keeping unexpected source entry:") == null);
    try testing.expect(mem.indexOf(u8, output.written(), "pending cache migration") == null);
}
