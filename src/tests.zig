const pkgbuild = @import("Pkgbuild.zig");
const alpm = @import("alpm.zig");
const args = @import("Args.zig");
const aur = @import("aur.zig");
const pacman = @import("pacman.zig");

test {
    _ = pkgbuild;
    _ = alpm;
    _ = args;
    _ = aur;
    _ = pacman;
}
