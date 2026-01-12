const pkgbuild = @import("pkgbuild.zig");
const alpm = @import("alpm.zig");
const argparse = @import("argparse.zig");
const aur = @import("aur.zig");

test {
    _ = pkgbuild;
    _ = alpm;
    _ = argparse;
    _ = aur;
}
