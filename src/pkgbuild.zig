const std = @import("std");
const testing = std.testing;

const RelevantFields = &[_][]const u8{
    "install",
    "source",
    "pkgver()",
    "check()",
    "package()",
    "install()",
};

const Content = struct {
    const Self = @This();

    value: []const u8,
    updated: bool = false,

    // allocator.create does not respect default values so safeguard via an init() call
    pub fn init(allocator: *std.mem.Allocator, value: []const u8) !*Self {
        var new = try allocator.create(Self);
        new.value = value;
        new.updated = false;
        return new;
    }

    pub fn deinit(self: *Self, allocator: *std.mem.Allocator) void {
        allocator.free(self.value);
        allocator.destroy(self);
    }
};

pub const Pkgbuild = struct {
    const Self = @This();

    allocator: *std.mem.Allocator,
    file_contents: []const u8,
    relevant_fields: std.StringHashMap(*Content),

    pub fn init(allocator: *std.mem.Allocator, file_contents: []const u8) Self {
        return Self{
            .allocator = allocator,
            .file_contents = file_contents,
            .relevant_fields = std.StringHashMap(*Content).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        defer self.relevant_fields.deinit();
        var iter = self.relevant_fields.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key);
            entry.value.deinit(self.allocator);
        }
    }

    pub fn readLines(self: *Self) !void {
        var stream = std.io.fixedBufferStream(self.file_contents).reader();
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        while (true) {
            const byte = stream.readByte() catch |err| switch (err) {
                error.EndOfStream => break,
            };
            switch (byte) {
                // PKGBUILD comments
                '#' => {
                    while (true) {
                        const lookahead = try stream.readByte();
                        if (lookahead == '\n') break;
                    }
                },
                // PKGBUILD key=value
                '=' => {
                    var key = buf.toOwnedSlice();
                    while (true) {
                        const lookahead = try stream.readByte();
                        if (lookahead == '(') {
                            while (true) {
                                const moreahead = try stream.readByte();
                                if (moreahead == ')') break;
                                if (moreahead != ' ' and moreahead != '\t') {
                                    try buf.append(moreahead);
                                }
                            }
                        } else if (lookahead == '\n') {
                            var content = try Content.init(self.allocator, buf.toOwnedSlice());
                            // Content.deinit() happens in Pkgbuild.deinit()

                            try self.relevant_fields.putNoClobber(key, content);
                            break;
                        } else {
                            try buf.append(lookahead);
                        }
                    }
                },
                // PKGBUILD functions() {}
                '(' => {
                    // functions get a () in their keys because
                    // 'pkgver' can both be a function and a key=value
                    try buf.appendSlice("()");

                    var key = buf.toOwnedSlice();
                    const close_paren = try stream.readByte();
                    if (close_paren != ')') {
                        return error.MalformedPkgbuildFunction;
                    }
                    const maybe_space = try stream.readByte();
                    if (maybe_space != ' ') {
                        try buf.append(maybe_space);
                    }
                    var prev: u8 = undefined;
                    while (true) {
                        const lookahead = try stream.readByte();
                        try buf.append(lookahead);
                        // TODO: Is it a valid assumption that the function closing paren is always on a new line?
                        if (lookahead == '}' and prev == '\n') {
                            var content = try Content.init(self.allocator, buf.toOwnedSlice());
                            // Content.deinit() happens in Pkgbuild.deinit()

                            try self.relevant_fields.putNoClobber(key, content);
                            break;
                        }
                        prev = lookahead;
                    }
                },
                '\n' => {},
                else => {
                    try buf.append(byte);
                },
            }
        }
    }

    pub fn comparePrev(self: *Self, prev_pkgbuild: Pkgbuild) !void {
        for (RelevantFields) |field| {
            const prev = prev_pkgbuild.relevant_fields.get(field);
            const curr = self.relevant_fields.get(field);
            if (prev == null and curr != null) {
                curr.?.updated = true;
            } else if (prev != null and curr == null) {
                curr.?.value = "(removed)";
                curr.?.updated = true;
            } else if (prev == null and curr == null) {
                continue;
            }

            if (!std.mem.eql(u8, prev.?.value, curr.?.value)) {
                curr.?.updated = true;
            }
        }
    }

    pub fn printUpdated(self: *Self) void {
        var iter = self.relevant_fields.iterator();
        while (iter.next()) |field| {
            if (field.value.updated) {
                std.log.info("{s} was updated {s}", .{ field.key, field.value.value });
            }
        }
    }
};

test "Pkgbuild - readLines - google-chrome-dev" {
    var file_contents =
        \\# Maintainer: Knut Ahlers <knut at ahlers dot me>
        \\# Contributor: Det <nimetonmaili g-mail>
        \\# Contributors: t3ddy, Lex Rivera aka x-demon, ruario
        \\
        \\# Check for new Linux releases in: http://googlechromereleases.blogspot.com/search/label/Dev%20updates
        \\# or use: $ curl -s https://dl.google.com/linux/chrome/rpm/stable/x86_64/repodata/other.xml.gz | gzip -df | awk -F\" '/pkgid/{ sub(".*-","",$4); print $4": "$10 }'
        \\
        \\pkgname=google-chrome-dev
        \\pkgver=91.0.4464.5
        \\pkgrel=1
        \\pkgdesc="The popular and trusted web browser by Google (Dev Channel)"
        \\arch=('x86_64')
        \\url="https://www.google.com/chrome"
        \\license=('custom:chrome')
        \\depends=('alsa-lib' 'gtk3' 'libcups' 'libxss' 'libxtst' 'nss')
        \\optdepends=(
        \\	'libpipewire02: WebRTC desktop sharing under Wayland'
        \\	'kdialog: for file dialogs in KDE'
        \\	'gnome-keyring: for storing passwords in GNOME keyring'
        \\	'kwallet: for storing passwords in KWallet'
        \\	'libunity: for download progress on KDE'
        \\	'ttf-liberation: fix fonts for some PDFs - CRBug #369991'
        \\	'xdg-utils'
        \\)
        \\provides=('google-chrome')
        \\options=('!emptydirs' '!strip')
        \\install=$pkgname.install
        \\_channel=unstable
        \\source=("https://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-${_channel}/google-chrome-${_channel}_${pkgver}-1_amd64.deb"
        \\	'eula_text.html'
        \\	"google-chrome-$_channel.sh")
        \\sha512sums=('7ab84e51b0cd80c51e0092fe67af1e4e9dd886c6437d9d0fec1552e511c1924d2dac21c02153382cbb7c8c52ef82df97428fbb12139ebc048f1db6964ddc3b45'
        \\            'a225555c06b7c32f9f2657004558e3f996c981481dbb0d3cd79b1d59fa3f05d591af88399422d3ab29d9446c103e98d567aeafe061d9550817ab6e7eb0498396'
        \\            '349fc419796bdea83ebcda2c33b262984ce4d37f2a0a13ef7e1c87a9f619fd05eb8ff1d41687f51b907b43b9a2c3b4a33b9b7c3a3b28c12cf9527ffdbd1ddf2e')
        \\
        \\package() {
        \\	msg2 "Extracting the data.tar.xz..."
        \\	bsdtar -xf data.tar.xz -C "$pkgdir/"
        \\
        \\	msg2 "Moving stuff in place..."
        \\	# Launcher
        \\	install -m755 google-chrome-$_channel.sh "$pkgdir"/usr/bin/google-chrome-$_channel
        \\
        \\	# Icons
        \\	for i in 16x16 24x24 32x32 48x48 64x64 128x128 256x256; do
        \\		install -Dm644 "$pkgdir"/opt/google/chrome-$_channel/product_logo_${i/x*/}_${pkgname/*-/}.png \
        \\			"$pkgdir"/usr/share/icons/hicolor/$i/apps/google-chrome-$_channel.png
        \\	done
        \\
        \\	# License
        \\	install -Dm644 eula_text.html "$pkgdir"/usr/share/licenses/google-chrome-$_channel/eula_text.html
        \\
        \\	msg2 "Fixing Chrome icon resolution..."
        \\	sed -i \
        \\		-e "/Exec=/i\StartupWMClass=Google-chrome-$_channel" \
        \\		-e "s/x-scheme-handler\/ftp;\?//g" \
        \\		"$pkgdir"/usr/share/applications/google-chrome-$_channel.desktop
        \\
        \\	msg2 "Removing Debian Cron job and duplicate product logos..."
        \\	rm -r "$pkgdir"/etc/cron.daily/ "$pkgdir"/opt/google/chrome-$_channel/cron/
        \\	rm "$pkgdir"/opt/google/chrome-$_channel/product_logo_*.png
        \\}
    ;
    var expectedMap = std.StringHashMap(*Content).init(testing.allocator);
    defer expectedMap.deinit();

    var install_val = std.ArrayList(u8).init(testing.allocator);
    try install_val.appendSlice("$pkgname.install");
    var install_content = try Content.init(testing.allocator, install_val.toOwnedSlice());
    defer install_content.deinit(testing.allocator);
    try expectedMap.putNoClobber("install", install_content);

    var source_val = std.ArrayList(u8).init(testing.allocator);
    try source_val.appendSlice(
        \\"https://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-${_channel}/google-chrome-${_channel}_${pkgver}-1_amd64.deb"
        \\'eula_text.html'
        \\"google-chrome-$_channel.sh"
    );
    var source_content = try Content.init(testing.allocator, source_val.toOwnedSlice());
    defer source_content.deinit(testing.allocator);
    try expectedMap.putNoClobber("source", source_content);

    var package_val = std.ArrayList(u8).init(testing.allocator);
    try package_val.appendSlice(
        \\{
        \\	msg2 "Extracting the data.tar.xz..."
        \\	bsdtar -xf data.tar.xz -C "$pkgdir/"
        \\
        \\	msg2 "Moving stuff in place..."
        \\	# Launcher
        \\	install -m755 google-chrome-$_channel.sh "$pkgdir"/usr/bin/google-chrome-$_channel
        \\
        \\	# Icons
        \\	for i in 16x16 24x24 32x32 48x48 64x64 128x128 256x256; do
        \\		install -Dm644 "$pkgdir"/opt/google/chrome-$_channel/product_logo_${i/x*/}_${pkgname/*-/}.png \
        \\			"$pkgdir"/usr/share/icons/hicolor/$i/apps/google-chrome-$_channel.png
        \\	done
        \\
        \\	# License
        \\	install -Dm644 eula_text.html "$pkgdir"/usr/share/licenses/google-chrome-$_channel/eula_text.html
        \\
        \\	msg2 "Fixing Chrome icon resolution..."
        \\	sed -i \
        \\		-e "/Exec=/i\StartupWMClass=Google-chrome-$_channel" \
        \\		-e "s/x-scheme-handler\/ftp;\?//g" \
        \\		"$pkgdir"/usr/share/applications/google-chrome-$_channel.desktop
        \\
        \\	msg2 "Removing Debian Cron job and duplicate product logos..."
        \\	rm -r "$pkgdir"/etc/cron.daily/ "$pkgdir"/opt/google/chrome-$_channel/cron/
        \\	rm "$pkgdir"/opt/google/chrome-$_channel/product_logo_*.png
        \\}
    );
    var package_content = try Content.init(testing.allocator, package_val.toOwnedSlice());
    defer package_content.deinit(testing.allocator);
    try expectedMap.putNoClobber("package()", package_content);

    var pkgbuild = Pkgbuild.init(testing.allocator, file_contents);
    defer pkgbuild.deinit();
    try pkgbuild.readLines();

    testing.expectEqualStrings(expectedMap.get("install").?.value, pkgbuild.relevant_fields.get("install").?.value);
    testing.expectEqualStrings(expectedMap.get("source").?.value, pkgbuild.relevant_fields.get("source").?.value);
    testing.expectEqualStrings(expectedMap.get("package()").?.value, pkgbuild.relevant_fields.get("package()").?.value);
}

test "Pkgbuild - compare" {
    var old =
        \\pkgname=google-chrome-dev
        \\pkgver=91.0.4464.5
        \\pkgrel=1
        \\pkgdesc="The popular and trusted web browser by Google (Dev Channel)"
        \\arch=('x86_64')
        \\url="https://www.google.com/chrome"
        \\license=('custom:chrome')
        \\depends=('alsa-lib' 'gtk3' 'libcups' 'libxss' 'libxtst' 'nss')
        \\optdepends=('optdepends')
        \\provides=('google-chrome')
        \\options=('!emptydirs' '!strip')
        \\install=$pkgname.install
        \\_channel=unstable
        \\source=("source")
        \\sha512sums=('sha' 'sum' '512')
        \\pkgver() {
        \\    pkgver function
        \\}
        \\check() {
        \\    check function
        \\}
        \\package() {
        \\    package function
        \\}
        \\install() {
        \\    install function
        \\}
    ;
    var new =
        \\pkgname=google-chrome-dev
        \\pkgver=9001
        \\pkgrel=1
        \\pkgdesc="The popular and trusted web browser by Google (Dev Channel)"
        \\arch=('x86_64')
        \\url="https://www.google.com/chrome"
        \\license=('custom:chrome')
        \\depends=('alsa-lib' 'gtk3' 'libcups' 'libxss' 'libxtst' 'nss')
        \\optdepends=('optdepends')
        \\provides=('google-chrome')
        \\options=('!emptydirs' '!strip')
        \\install=malicious.install
        \\_channel=unstable
        \\source=("source")
        \\sha512sums=('sha' 'sum' '512')
        \\pkgver() {
        \\    pkgver function
        \\    aha! I changed to perform some nasty shell commands
        \\}
        \\check() {
        \\    check function
        \\}
        \\package() {
        \\    package function
        \\}
        \\install() {
        \\    install function
        \\}
    ;

    var pkgbuild_old = Pkgbuild.init(testing.allocator, old);
    defer pkgbuild_old.deinit();
    try pkgbuild_old.readLines();
    var pkgbuild_new = Pkgbuild.init(testing.allocator, new);
    defer pkgbuild_new.deinit();
    try pkgbuild_new.readLines();

    try pkgbuild_new.comparePrev(pkgbuild_old);
    testing.expect(pkgbuild_new.relevant_fields.get("install").?.updated);
    testing.expect(pkgbuild_new.relevant_fields.get("pkgver()").?.updated);
}
