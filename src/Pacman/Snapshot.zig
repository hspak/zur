//! A validated source archive, isolated review extraction, and reusable build tree.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.snapshot);

const BuildCache = @import("BuildCache.zig");

const Snapshot = @This();

archive_path: []u8,
source_path: []u8,
io: Io,
persistent: bool = false,

pub const BuildOptions = BuildCache.PrepareOptions;

pub const Error = Allocator.Error || Dir.OpenError || Dir.CreateDirPathError ||
    Dir.CreateDirError || Dir.DeleteTreeError || Dir.DeleteFileError ||
    Dir.ReadFileAllocError || Dir.WriteFileError || Dir.RenameError ||
    Io.File.OpenError || Io.File.StatError || Io.Reader.Error || Io.Writer.Error || BuildCache.PrepareError || error{
    InvalidSnapshot,
    Overflow,
    InvalidCharacter,
    EndOfStream,
    UnexpectedEndOfStream,
    TarHeader,
    TarHeaderChksum,
    TarNumericValueNegative,
    TarNumericValueTooBig,
    TarInsufficientBuffer,
    PaxNullInKeyword,
    PaxInvalidAttributeEnd,
    PaxSizeAttrOverflow,
    PaxNullInValue,
    TarHeadersTooBig,
    TarUnsupportedHeader,
    TarComponentsOutsideStrippedPrefix,
    UnableToCreateSymLink,
};

/// Extract into private staging storage and publish the archive only after
/// validation. Owns both returned paths; deinit removes the review extraction
/// unless useBuild has promoted it to a persistent build tree.
pub fn create(allocator: Allocator, io: Io, root: []const u8, base: []const u8, bytes: []const u8) Error!Snapshot {
    try validateArchive(allocator, bytes);
    const parent = try Dir.path.join(allocator, &.{ root, ".src", base });
    defer allocator.free(parent);
    try Dir.cwd().createDirPath(io, parent);
    var dir = try Dir.openDirAbsolute(io, parent, .{});
    defer dir.close(io);

    var random: [16]u8 = undefined;
    Io.random(io, &random);
    const stage_name = try std.fmt.allocPrint(allocator, ".pending-{s}", .{std.fmt.bytesToHex(random, .lower)});
    defer allocator.free(stage_name);
    try dir.createDir(io, stage_name, .default_dir);
    defer {
        log.debug("removing staging directory: {s}/{s}", .{ parent, stage_name });
        dir.deleteTree(io, stage_name) catch |err| log.debug("cannot remove staging directory {s}/{s}: {t}", .{
            parent,
            stage_name,
            err,
        });
    }
    var stage = try dir.openDir(io, stage_name, .{});
    defer stage.close(io);
    try stage.writeFile(io, .{ .sub_path = "snapshot.tar.gz", .data = bytes });
    try stage.createDir(io, "source", .default_dir);
    var source = try stage.openDir(io, "source", .{});
    defer source.close(io);
    const archive_file = try stage.openFile(io, "snapshot.tar.gz", .{});
    defer archive_file.close(io);
    try extractFromFile(io, source, archive_file);
    const pkgbuild = source.statFile(io, "PKGBUILD", .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.InvalidSnapshot,
        else => return err,
    };
    if (pkgbuild.kind != .file) return error.InvalidSnapshot;

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const archive_name = try std.fmt.allocPrint(allocator, "{s}.tar.gz", .{std.fmt.bytesToHex(digest, .lower)});
    defer allocator.free(archive_name);
    const archive_path = try Dir.path.join(allocator, &.{ parent, archive_name });
    errdefer allocator.free(archive_path);
    const review_name = try std.fmt.allocPrint(allocator, ".review-{s}", .{std.fmt.bytesToHex(random, .lower)});
    defer allocator.free(review_name);
    const source_path = try Dir.path.join(allocator, &.{ parent, review_name });
    errdefer allocator.free(source_path);
    const staged_source = try Dir.path.join(allocator, &.{ parent, stage_name, "source" });
    defer allocator.free(staged_source);

    try stage.rename("snapshot.tar.gz", dir, archive_name, io);
    try Dir.renameAbsolute(staged_source, source_path, io);
    return .{ .archive_path = archive_path, .source_path = source_path, .io = io };
}

/// Assumes the operation lock is held and review is complete. Replace the
/// temporary extraction with a versioned build tree, retaining generated files.
pub fn useBuild(self: *Snapshot, allocator: Allocator, options: BuildOptions) Error!void {
    std.debug.assert(!self.persistent);
    const path = try BuildCache.prepare(allocator, self.io, self.source_path, options);
    errdefer allocator.free(path);
    try Dir.cwd().deleteTree(self.io, self.source_path);
    allocator.free(self.source_path);
    self.source_path = path;
    self.persistent = true;
}

/// Retains saved archives and persistent build trees, and frees owned paths.
pub fn deinit(self: *Snapshot, allocator: Allocator) void {
    if (!self.persistent) {
        log.debug("removing review directory: {s}", .{self.source_path});
        Dir.cwd().deleteTree(self.io, self.source_path) catch |err| log.debug("cannot remove review directory {s}: {t}", .{
            self.source_path,
            err,
        });
    }
    allocator.free(self.source_path);
    allocator.free(self.archive_path);
    self.* = undefined;
}

/// Extract an AUR gzip archive, strip its root directory, and consume the file.
pub fn extractTarGz(io: Io, dest_dir: Dir, archive_name: []const u8) Error!void {
    const file = try dest_dir.openFile(io, archive_name, .{});
    defer file.close(io);
    try extractFromFile(io, dest_dir, file);
    try dest_dir.deleteFile(io, archive_name);
}

fn extractFromFile(io: Io, dest_dir: Dir, file: Io.File) Error!void {
    var file_buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &file_buffer);
    var gzip_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&reader.interface, .gzip, &gzip_buffer);
    try std.tar.extract(io, dest_dir, &decompress.reader, .{
        .strip_components = 1,
        .mode_mode = .executable_bit_only,
    });
    // Consume the gzip trailer too: tar can stop before a truncated stream ends.
    var trailing: [8192]u8 = undefined;
    while (try decompress.reader.readSliceShort(&trailing) != 0) {}
}

// Git cannot track a file below a tracked symlink. Reject such archives before
// extraction so an earlier link cannot redirect later writes outside staging.
fn validateArchive(allocator: Allocator, bytes: []const u8) Error!void {
    var input: Io.Reader = .fixed(bytes);
    var gzip_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&input, .gzip, &gzip_buffer);
    var archive_root: ?[]const u8 = null;
    var names: std.StringHashMapUnmanaged(bool) = .empty;
    defer {
        var keys = names.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        names.deinit(allocator);
    }
    var file_name_buffer: [Dir.max_path_bytes]u8 = undefined;
    var link_name_buffer: [Dir.max_path_bytes]u8 = undefined;
    var iterator: std.tar.Iterator = .init(&decompress.reader, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });
    while (try iterator.next()) |entry| {
        if (Dir.path.isAbsolute(entry.name)) return error.InvalidSnapshot;
        const name = std.mem.trimEnd(u8, entry.name, "/");
        var components = std.mem.splitScalar(u8, name, '/');
        while (components.next()) |component| {
            if (component.len == 0 or std.mem.eql(u8, component, ".") or
                std.mem.eql(u8, component, "..")) return error.InvalidSnapshot;
        }
        const root_end = std.mem.indexOfScalar(u8, name, '/') orelse name.len;
        if (archive_root) |root| {
            // All paths must share the prefix discarded by strip_components.
            if (!std.mem.eql(u8, root, name[0..root_end])) return error.InvalidSnapshot;
        }
        const key = try allocator.dupe(u8, name);
        errdefer allocator.free(key);
        if (names.contains(key)) return error.InvalidSnapshot;
        try names.put(allocator, key, entry.kind == .sym_link);
        if (archive_root == null) archive_root = key[0..root_end];
    }
    var entries = names.keyIterator();
    while (entries.next()) |name| {
        var parent = Dir.path.dirname(name.*);
        while (parent) |path| : (parent = Dir.path.dirname(path)) {
            if (names.get(path) orelse false) return error.InvalidSnapshot;
        }
    }
}

fn testArchive(tmp: Dir, root: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "tar", "-czf", "input.tar.gz", "pkg" },
        .cwd = .{ .path = root },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.TarCreate;
    return tmp.readFileAlloc(std.testing.io, "input.tar.gz", allocator, .unlimited);
}

test "snapshot publishes complete archives and isolates build mutations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];
    try tmp.dir.createDirPath(testing.io, "pkg/nested");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pkg/PKGBUILD", .data = "pkgname=original\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pkg/nested/patch", .data = "patch content\n" });
    const bytes = try testArchive(tmp.dir, root);
    defer allocator.free(bytes);
    var first = try create(allocator, testing.io, root, "pkg", bytes);
    defer first.deinit(allocator);
    var build_dir = try Dir.openDirAbsolute(testing.io, first.source_path, .{});
    defer build_dir.close(testing.io);
    try build_dir.writeFile(testing.io, .{ .sub_path = "PKGBUILD", .data = "pkgname=mutated\n" });
    const saved = try Dir.cwd().readFileAlloc(testing.io, first.archive_path, allocator, .unlimited);
    defer allocator.free(saved);
    try testing.expectEqualSlices(u8, bytes, saved);
    var second = try create(allocator, testing.io, root, "pkg", saved);
    defer second.deinit(allocator);
    var review_dir = try Dir.openDirAbsolute(testing.io, second.source_path, .{});
    defer review_dir.close(testing.io);
    const pkgbuild = try review_dir.readFileAlloc(testing.io, "PKGBUILD", allocator, .unlimited);
    defer allocator.free(pkgbuild);
    try testing.expectEqualStrings("pkgname=original\n", pkgbuild);
    const patch = try review_dir.readFileAlloc(testing.io, "nested/patch", allocator, .unlimited);
    defer allocator.free(patch);
    try testing.expectEqualStrings("patch content\n", patch);
}

test "versioned builds refresh reviewed files and retain generated sources" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];
    try tmp.dir.createDirPath(testing.io, "pkg/nested");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pkg/PKGBUILD", .data = "pkgver=1\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pkg/obsolete.patch", .data = "old patch\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pkg/nested/hook", .data = "old hook\n" });
    {
        const bytes = try testArchive(tmp.dir, root);
        defer allocator.free(bytes);
        var snapshot = try create(allocator, testing.io, root, "pkg", bytes);
        defer snapshot.deinit(allocator);
        try snapshot.useBuild(allocator, .{ .root_path = root, .base = "pkg", .version = "1-1" });
        var build = try Dir.openDirAbsolute(testing.io, snapshot.source_path, .{});
        defer build.close(testing.io);
        try build.createDirPath(testing.io, "src/checkout");
        try build.writeFile(testing.io, .{ .sub_path = "src/checkout/keep", .data = "downloaded\n" });
        try build.writeFile(testing.io, .{ .sub_path = "built", .data = "compiled\n" });
        try build.writeFile(testing.io, .{ .sub_path = "PKGBUILD", .data = "pkgver=mutated\n" });
        try build.deleteTree(testing.io, "nested");
        try tmp.dir.createDirPath(testing.io, "outside");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside/hook", .data = "untouched\n" });
        try build.symLink(testing.io, "../../../outside", "nested", .{});
    }
    try tmp.dir.deleteFile(testing.io, "pkg/obsolete.patch");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pkg/nested/hook", .data = "reviewed hook\n" });
    const bytes = try testArchive(tmp.dir, root);
    defer allocator.free(bytes);
    var snapshot = try create(allocator, testing.io, root, "pkg", bytes);
    defer snapshot.deinit(allocator);
    {
        var review = try Dir.openDirAbsolute(testing.io, snapshot.source_path, .{});
        defer review.close(testing.io);
        try testing.expectError(error.FileNotFound, review.statFile(testing.io, "built", .{}));
    }
    try snapshot.useBuild(allocator, .{ .root_path = root, .base = "pkg", .version = "1-2" });
    try testing.expectEqualStrings("1", Dir.path.basename(snapshot.source_path));
    const retained = [_]struct { path: []const u8, contents: []const u8 }{
        .{ .path = ".build/pkg/1/PKGBUILD", .contents = "pkgver=1\n" },
        .{ .path = ".build/pkg/1/nested/hook", .contents = "reviewed hook\n" },
        .{ .path = ".build/pkg/1/src/checkout/keep", .contents = "downloaded\n" },
        .{ .path = ".build/pkg/1/built", .contents = "compiled\n" },
        .{ .path = "outside/hook", .contents = "untouched\n" },
    };
    for (retained) |entry| {
        const contents = try tmp.dir.readFileAlloc(testing.io, entry.path, allocator, .unlimited);
        defer allocator.free(contents);
        try testing.expectEqualStrings(entry.contents, contents);
    }
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, ".build/pkg/1/obsolete.patch", .{}));
}

test "snapshot rejects a directory PKGBUILD without publishing an archive" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];
    try tmp.dir.createDirPath(testing.io, "pkg/PKGBUILD");
    const bytes = try testArchive(tmp.dir, root);
    defer allocator.free(bytes);
    try testing.expectError(error.InvalidSnapshot, create(allocator, testing.io, root, "pkg", bytes));
    var dir = try tmp.dir.openDir(testing.io, ".src/pkg", .{ .iterate = true });
    defer dir.close(testing.io);
    var iterator = dir.iterate();
    try testing.expectEqual(null, try iterator.next(testing.io));
}

test "snapshot rejects a truncated gzip after the PKGBUILD" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];
    try tmp.dir.createDirPath(testing.io, "pkg");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pkg/PKGBUILD", .data = "pkgname=pkg\n" });
    const bytes = try testArchive(tmp.dir, root);
    defer allocator.free(bytes);
    if (create(allocator, testing.io, root, "pkg", bytes[0 .. bytes.len - 8])) |created| {
        var unexpected = created;
        unexpected.deinit(allocator);
        return error.TruncatedSnapshotAccepted;
    } else |_| {}
    var dir = tmp.dir.openDir(testing.io, ".src/pkg", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(testing.io);
    var iterator = dir.iterate();
    try testing.expectEqual(null, try iterator.next(testing.io));
}

test "snapshot rejects archive writes beneath a symlink before extraction" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];
    try tmp.dir.createDirPath(testing.io, "pkg");
    try tmp.dir.createDirPath(testing.io, "outside");
    try tmp.dir.symLink(testing.io, "../../../outside", "pkg/link", .{});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pkg/PKGBUILD", .data = "pkgname=pkg\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "injected", .data = "unreviewed write\n" });
    const result = try std.process.run(allocator, testing.io, .{
        .argv = &.{
            "tar", "-czf", "input.tar.gz", "--transform=s|^injected$|pkg/link/payload|", "pkg", "injected",
        },
        .cwd = .{ .path = root },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.TarCreate;
    const bytes = try tmp.dir.readFileAlloc(testing.io, "input.tar.gz", allocator, .unlimited);
    defer allocator.free(bytes);
    try testing.expectError(error.InvalidSnapshot, create(allocator, testing.io, root, "pkg", bytes));
    try testing.expectError(error.FileNotFound, tmp.dir.openDir(testing.io, ".src", .{}));
}

test "snapshot rejects multiple archive roots before stripping their prefixes" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [Dir.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];
    try tmp.dir.createDirPath(testing.io, "pkg");
    try tmp.dir.createDirPath(testing.io, "other/link");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "pkg/PKGBUILD", .data = "pkgname=pkg\n" });
    try tmp.dir.symLink(testing.io, ".", "pkg/link", .{});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "other/link/payload", .data = "wrong destination\n" });
    const result = try std.process.run(allocator, testing.io, .{
        .argv = &.{ "tar", "-czf", "input.tar.gz", "pkg", "other/link/payload" },
        .cwd = .{ .path = root },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.TarCreate;
    const bytes = try tmp.dir.readFileAlloc(testing.io, "input.tar.gz", allocator, .unlimited);
    defer allocator.free(bytes);
    if (create(allocator, testing.io, root, "pkg", bytes)) |created| {
        var unexpected = created;
        unexpected.deinit(allocator);
        return error.MultipleRootsAccepted;
    } else |err| {
        try testing.expectEqual(error.InvalidSnapshot, err);
    }
}
