//! Test root: pull each child file into the test binary.

const pkgbuild = @import("Pkgbuild.zig");
const alpm = @import("Alpm.zig");
const args = @import("Args.zig");
const aur = @import("aur.zig");
const pacman = @import("Pacman.zig");

test {
    _ = pkgbuild;
    _ = alpm;
    _ = args;
    _ = aur;
    _ = pacman;
}
