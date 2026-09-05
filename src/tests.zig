//! Test root: pull each child file into the test binary.

test {
    _ = @import("Alpm.zig");
    _ = @import("Args.zig");
    _ = @import("Pacman.zig");
    _ = @import("Request.zig");
    _ = @import("aur.zig");
    _ = @import("color.zig");
}
