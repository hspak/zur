const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;
const testing = std.testing;

pub const Version = struct {
    epoch: isize,
    major: isize,
    minor: isize,
    patch: isize,

    // Some packages have MAJOR.MINOR.PATCH.EXTRA - just going to assume it stops there
    extra: isize,

    // I'm not even sure if this is a reliable pattern.
    // Most packages seem to have a <revision>-<short-sha1> format
    vcs_rev: isize,
    release: isize,

    const Self = @This();

    pub fn init(version: []const u8) !Self {
        // Epoch parsing, epoch is optional
        var epoch_iter = mem.split(u8, version, ":");
        const epoch_first_half = epoch_iter.next().?;
        const epoch_second_half = epoch_iter.next();
        const epochless_base = if (epoch_second_half == null) epoch_first_half else epoch_second_half;
        const epoch = if (epoch_second_half == null) null else epoch_first_half;

        // Release parsing, not optional
        var release_iter = mem.split(u8, epochless_base.?, "-");
        const releaseless_base = release_iter.next().?;
        const release = release_iter.next().?;

        // VCS version thingy
        var vcs_iter = mem.split(u8, releaseless_base, "+");
        const vcsless_base = vcs_iter.next().?;
        var vcs_rev: ?isize = null;
        while (vcs_iter.next()) |vcs| {
            // Go through each "+" segment and use the first valid number that we see
            vcs_rev = parseInt(vcs) catch {
                continue;
            };
            if (vcs_rev != null) {
                break;
            }
        }

        // Semver-ish-thing, anything goes here really
        var semver_iter = mem.split(u8, vcsless_base, ".");
        const major = semver_iter.next().?;
        const minor = semver_iter.next();
        const patch = if (minor != null) semver_iter.next() else null;
        const extra = if (patch != null) semver_iter.next() else null;


        return Version{
            .epoch = if (epoch != null) try parseInt(epoch.?) else 0,
            .major = try parseInt(major),
            .minor = if (minor != null) try parseInt(minor.?) else 0,
            .patch = if (patch != null) try parseInt(patch.?) else 0,
            .extra = if (extra != null) try parseInt(extra.?) else 0,
            .vcs_rev = vcs_rev orelse 0,
            .release = try parseInt(release),
        };
    }

    pub fn olderThan(self: Self, new_version: Version) bool {
        if (self.epoch < new_version.epoch) {
            return true;
        } else if (self.epoch > new_version.epoch) {
            return false;
        }

        if (self.major < new_version.major) {
            return true;
        } else if (self.major > new_version.major) {
            return false;
        }

        if (self.minor < new_version.minor) {
            return true;
        } else if (self.minor > new_version.minor) {
            return false;
        }

        if (self.patch < new_version.patch) {
            return true;
        } else if (self.patch > new_version.patch) {
            return false;
        }

        if (self.extra < new_version.extra) {
            return true;
        } else if (self.extra > new_version.extra) {
            return false;
        }

        if (self.vcs_rev < new_version.vcs_rev) {
            return true;
        } else if (self.vcs_rev > new_version.vcs_rev) {
            return false;
        }

        if (self.release < new_version.release) {
            return true;
        } else if (self.release > new_version.release) {
            return false;
        }

        // everything is equal
        return false;
    }

    // Hacky wrapper aruond std.fmt.parseInt to add a retry after stripping all non-number chars
    fn parseInt(str: []const u8) !isize {
        const num = std.fmt.parseUnsigned(isize, str, 10) catch {
            const buf_size = 16;
            var new_str: [buf_size]u8 = undefined;
            var new_str_i: u8 = 0;
            var found_num = false;
            for (str) |char| {
                if (ascii.isDigit(char)) {
                    new_str[new_str_i] = char;
                    new_str_i += 1;
                    if (new_str_i == buf_size) {
                        return error.ParseIntDigitTooLarge;
                    }
                    found_num = true;
                } else if (found_num) {
                    // Only consider contiguous digits
                    break;
                }
            }
            if (mem.eql(u8 , str, "alpha")) {
                return -2;
            } else if (mem.eql(u8 , str, "beta")) {
                return -1;
            } else {
                return -3;
            }

            if (new_str_i == 0) {
                return error.NotANumber;
            }

            const buf: []u8 = new_str[0..new_str_i];
            const p = try std.fmt.parseUnsigned(isize, buf, 10);
            return p;
        };
        return num;
    }
};

test "Version.init - standard semver without epoch" {
    const input = "1.2.3-4";
    const expected = Version{
        .epoch = 0,
        .major = 1,
        .minor = 2,
        .patch = 3,
        .extra = 0,
        .vcs_rev = 0,
        .release = 4,
    };
    try testing.expectEqual(expected, try Version.init(input));
}
test "Version.init - standard semver with epoch" {
    const input = "1:2.3.4-5";
    const expected = Version{
        .epoch = 1,
        .major = 2,
        .minor = 3,
        .patch = 4,
        .extra = 0,
        .vcs_rev = 0,
        .release = 5,
    };
    try testing.expectEqual(expected, try Version.init(input));
}
test "Version.init - everything" {
    const input = "1:2.3.4.69+42+abc1234-5";
    const expected = Version{
        .epoch = 1,
        .major = 2,
        .minor = 3,
        .patch = 4,
        .extra = 69,
        .vcs_rev = 42,
        .release = 5,
    };
    try testing.expectEqual(expected, try Version.init(input));
}
test "Version.init - only major" {
    const input = "1000-1";
    const expected = Version{
        .epoch = 0,
        .major = 1000,
        .minor = 0,
        .patch = 0,
        .extra = 0,
        .vcs_rev = 0,
        .release = 1,
    };
    try testing.expectEqual(expected, try Version.init(input));
}
test "Version.init - only major and minor" {
    const input = "1000.2-1";
    const expected = Version{
        .epoch = 0,
        .major = 1000,
        .minor = 2,
        .patch = 0,
        .extra = 0,
        .vcs_rev = 0,
        .release = 1,
    };
    try testing.expectEqual(expected, try Version.init(input));
}
test "Version.init - neovim-nightly-bin" {
    const input = "0.5.0+dev+1194+gc20ae3aad-1";
    const expected = Version{
        .epoch = 0,
        .major = 0,
        .minor = 5,
        .patch = 0,
        .extra = 0,
        .vcs_rev = 1194,
        .release = 1,
    };
    try testing.expectEqual(expected, try Version.init(input));
}
test "Version.init - gnome-backgrounds" {
    const input = "40rc-1";
    const expected = Version{
        .epoch = 0,
        .major = 40,
        .minor = 0,
        .patch = 0,
        .extra = 0,
        .vcs_rev = 0,
        .release = 1,
    };
    try testing.expectEqual(expected, try Version.init(input));
}

test "Version.olderThan - gnome-calculator" {
    const old = try Version.init("3.26.3-1");
    const new = try Version.init("3.26.3+2+g966ec1c5-1");
    const expected = true;
    const actual = old.olderThan(new);
    try testing.expectEqual(expected, actual);
}
test "Version.olderThan - slang" {
    const old = try Version.init("2.3.1a-1");
    const new = try Version.init("2.3.1a-2");
    const expected = true;
    const actual = old.olderThan(new);
    const reverse_expected = false;
    const reverse_actual = new.olderThan(old);
    try testing.expectEqual(expected, actual);
    try testing.expectEqual(reverse_expected, reverse_actual);
}
test "Version.olderThan - libinput - 1" {
    const old = try Version.init("1.10.0-1");
    const new = try Version.init("1.10.0+25+g3e77f2e9-1");
    const expected = true;
    const actual = old.olderThan(new);
    const reverse_expected = false;
    const reverse_actual = new.olderThan(old);
    try testing.expectEqual(expected, actual);
    try testing.expectEqual(reverse_expected, reverse_actual);
}
test "Version.olderThan - libinput - 2" {
    const old = try Version.init("1.10.0+25+g3e77f2e9-1");
    const new = try Version.init("1.10.1-1");
    const expected = true;
    const actual = old.olderThan(new);
    const reverse_expected = false;
    const reverse_actual = new.olderThan(old);
    try testing.expectEqual(expected, actual);
    try testing.expectEqual(reverse_expected, reverse_actual);
}
test "Version.olderThan - gnome-keyring" {
    const old = try Version.init("1:3.27.2-1");
    const new = try Version.init("1:3.27.4+8+gff229abc-1");
    const expected = true;
    const actual = old.olderThan(new);
    const reverse_expected = false;
    const reverse_actual = new.olderThan(old);
    try testing.expectEqual(expected, actual);
    try testing.expectEqual(reverse_expected, reverse_actual);
}
test "Version.olderThan - libxml2" {
    const old = try Version.init("2.9.7+4+g72182550-2");
    const new = try Version.init("2.9.8-1");
    const expected = true;
    const actual = old.olderThan(new);
    const reverse_expected = false;
    const reverse_actual = new.olderThan(old);
    try testing.expectEqual(expected, actual);
    try testing.expectEqual(reverse_expected, reverse_actual);
}
test "Version.olderThan - libnm" {
    const old = try Version.init("1.10.5dev+3+g5159c34ea-1");
    const new = try Version.init("1.10.6-1");
    const expected = true;
    const actual = old.olderThan(new);
    const reverse_expected = false;
    const reverse_actual = new.olderThan(old);
    try testing.expectEqual(expected, actual);
    try testing.expectEqual(reverse_expected, reverse_actual);
}
test "Version.olderThan - libytnef" {
    const old = try Version.init("1.9.3+7+g24fe30e-2");
    const new = try Version.init("1:1.9.3-1");
    const expected = true;
    const actual = old.olderThan(new);
    const reverse_expected = false;
    const reverse_actual = new.olderThan(old);
    try testing.expectEqual(expected, actual);
    try testing.expectEqual(reverse_expected, reverse_actual);
}
test "Version.olderThan - neovim-nightly-bin" {
    const old = try Version.init("0.5.0+dev+1130+g7c204af87-1");
    const new = try Version.init("0.5.0+dev+1157+g0ab88c2ea-1");
    const expected = true;
    const actual = old.olderThan(new);
    const reverse_expected = false;
    const reverse_actual = new.olderThan(old);
    try testing.expectEqual(expected, actual);
    try testing.expectEqual(reverse_expected, reverse_actual);
}

// TODO: Make this pass
// test "Version.olderThan - zoom" {
// const old = try Version.init("5.7.6-1");
// const new = try Version.init("5.7.6a-1");
// const expected = true;
// const actual = old.olderThan(new);
// const reverse_expected = false;
// const reverse_actual = new.olderThan(old);
// try testing.expectEqual(expected, actual);
// try testing.expectEqual(reverse_expected, reverse_actual);
// }
