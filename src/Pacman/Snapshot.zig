//! A validated source archive and a disposable extraction for one build.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.snapshot);

const Snapshot = @This();

archive_path: []u8,
source_path: []u8,
io: Io,

pub const Error = Allocator.Error || Dir.OpenError || Dir.CreateDirPathError ||
    Dir.CreateDirError || Dir.DeleteTreeError || Dir.DeleteFileError ||
    Dir.ReadFileAllocError || Dir.WriteFileError || Dir.RenameError ||
    Io.File.OpenError || Io.File.StatError || Io.Reader.Error || Io.Writer.Error || error{
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
/// validation. Owns both returned paths; deinit removes the disposable source
/// tree but retains the saved archive for subsequent update review.
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
    defer dir.deleteTree(io, stage_name) catch |err| log.warn("cannot remove staging directory: {t}", .{err});
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
    const build_parent = try Dir.path.join(allocator, &.{ root, ".build", base });
    defer allocator.free(build_parent);
    try Dir.cwd().createDirPath(io, build_parent);
    const build_name = std.fmt.bytesToHex(random, .lower);
    const source_path = try Dir.path.join(allocator, &.{ build_parent, &build_name });
    errdefer allocator.free(source_path);
    const staged_source = try Dir.path.join(allocator, &.{ parent, stage_name, "source" });
    defer allocator.free(staged_source);

    try stage.rename("snapshot.tar.gz", dir, archive_name, io);
    try Dir.renameAbsolute(staged_source, source_path, io);
    return .{ .archive_path = archive_path, .source_path = source_path, .io = io };
}

/// Retains the immutable saved archive, removes build files, and frees paths.
pub fn deinit(self: *Snapshot, allocator: Allocator) void {
    Dir.cwd().deleteTree(self.io, self.source_path) catch |err| log.warn("cannot remove build directory: {t}", .{err});
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
