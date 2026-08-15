const pkgbuild = @import("Pkgbuild.zig");
const alpm = @import("alpm.zig");
const argparse = @import("argparse.zig");
const aur = @import("aur.zig");
const pacman = @import("pacman.zig");

test {
    _ = pkgbuild;
    _ = alpm;
    _ = argparse;
    _ = aur;
    _ = pacman;
}
