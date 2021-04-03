const std = @import("std");
const pacman = @import("pacman.zig");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    var allocator = &arena_state.allocator;

    var pm = try pacman.Pacman.init(allocator);
    defer pm.deinit();

    try pm.fetchLocalPackages();
    try pm.fetchRemoteAurVersions();
    try pm.compareVersions();
    try pm.downloadUpdates();
    // Save the PKGBUILDS and hooks and stuff
}
