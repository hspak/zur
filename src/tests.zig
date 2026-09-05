//! Test root: pull each child file into the test binary.

test {
    _ = @import("Alpm.zig");
    _ = @import("Args.zig");
    _ = @import("Pacman.zig");
    _ = @import("Pkgbuild.zig");
    _ = @import("Request.zig");
    _ = @import("aur.zig");
    _ = @import("color.zig");
    _ = @import("review_text.zig");
}
