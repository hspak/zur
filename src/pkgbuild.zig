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
    value: []const u8,
    updated: bool = false,

    // allocator.create does not respect default values so safeguard via an init() call
    pub fn init(allocator: std.mem.Allocator, value: []const u8) !*Content {
        var new = try allocator.create(Content);
        new.value = value;
        new.updated = false;
        return new;
    }

    pub fn deinit(self: *Content, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
        allocator.destroy(self);
    }
};

pub const Pkgbuild = struct {
    allocator: std.mem.Allocator,
    file_contents: []const u8,
    fields: std.StringHashMap(*Content),

    pub fn init(allocator: std.mem.Allocator, file_contents: []const u8) Pkgbuild {
        return Pkgbuild{
            .allocator = allocator,
            .file_contents = file_contents,
            .fields = std.StringHashMap(*Content).init(allocator),
        };
    }

    pub fn deinit(self: *Pkgbuild) void {
        defer self.fields.deinit();
        var iter = self.fields.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
        }
    }

    pub fn readLines(self: *Pkgbuild) !void {
        var fixedbufferstream = std.io.fixedBufferStream(self.file_contents);
        var stream = fixedbufferstream.reader();
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
                        // footer comments cause this to return EndOfStream error
                        const lookahead = stream.readByte() catch |err| switch (err) {
                            error.EndOfStream => break,
                        };
                        if (lookahead == '\n') break;
                    }
                },
                // PKGBUILD key=value
                '=' => {
                    const key = try buf.toOwnedSlice();
                    var in_quotes = false;
                    while (true) {
                        const lookahead = try stream.readByte();
                        if (lookahead == '(') {
                            while (true) {
                                const moreahead = try stream.readByte();

                                // This naive parsing goofs when there are parens in quotes
                                if (moreahead == '\'') in_quotes = !in_quotes;

                                if (moreahead == ')' and !in_quotes) break;
                                if (moreahead != ' ' and moreahead != '\t') {
                                    try buf.append(moreahead);
                                }
                            }
                        } else if (lookahead == '\n') {
                            const content = try Content.init(self.allocator, try buf.toOwnedSlice());
                            // Content.deinit() happens in Pkgbuild.deinit()

                            try self.fields.putNoClobber(key, content);
                            break;
                        } else {
                            try buf.append(lookahead);
                        }
                    }
                },
                // PKGBUILD functions() {}
                // TODO: looks like PKGBUILDS shared across multiple packages can do something like package_PKGNAME()
                '(' => {
                    // functions get a () in their keys because
                    // 'pkgver' can both be a function and a key=value
                    try buf.appendSlice("()");

                    const key = try buf.toOwnedSlice();
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
                            const content = try Content.init(self.allocator, try buf.toOwnedSlice());
                            // Content.deinit() happens in Pkgbuild.deinit()

                            try self.fields.putNoClobber(key, content);
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

    pub fn comparePrev(self: *Pkgbuild, prev_pkgbuild: Pkgbuild) !void {
        for (RelevantFields) |field| {
            const prev = prev_pkgbuild.fields.get(field);
            const curr = self.fields.get(field);
            if (prev == null and curr != null) {
                curr.?.updated = true;
            } else if (prev != null and curr == null) {
                curr.?.value = "(removed)";
                curr.?.updated = true;
            } else if (prev == null and curr == null) {
                continue;
            } else if (prev != null and curr != null and !std.mem.eql(u8, prev.?.value, curr.?.value)) {
                curr.?.updated = true;
            }
        }
    }

    pub fn indentValues(self: *Pkgbuild, spaces_count: usize) !void {
        var buf = std.ArrayList(u8).init(self.allocator);
        var fields_iter = self.fields.iterator();
        while (fields_iter.next()) |field| {
            if (!std.mem.containsAtLeast(u8, field.key_ptr.*, 1, "()")) {
                continue;
            }
            var lines_iter = std.mem.splitScalar(u8, field.value_ptr.*.value, '\n');
            while (lines_iter.next()) |line| {
                var count: usize = 0;
                while (count < spaces_count) {
                    try buf.append(' ');
                    count += 1;
                }
                try buf.appendSlice(line);
                try buf.append('\n');
            }
            self.allocator.free(field.value_ptr.*.value);
            field.value_ptr.*.value = try buf.toOwnedSlice();
        }
    }
};

test "Pkgbuild - readLines - neovim-git" {
    const file_contents =
        \\# Maintainer: Florian Walch <florian+aur@fwalch.com>
        \\# Contributor: Florian Hahn <flo@fhahn.com>
        \\# Contributor: Sven-Hendrik Haase <svenstaro@gmail.com>
        \\
        \\pkgname=neovim-git
        \\pkgver=0.4.0.r2972.g3fbff98cf
        \\pkgrel=1
        \\pkgdesc='Fork of Vim aiming to improve user experience, plugins, and GUIs.'
        \\arch=('i686' 'x86_64' 'armv7h' 'armv6h' 'aarch64')
        \\url='https://neovim.io'
        \\backup=('etc/xdg/nvim/sysinit.vim')
        \\license=('custom:neovim')
        \\depends=('libluv' 'libtermkey' 'libutf8proc' 'libuv' 'libvterm>=0.1.git5' 'luajit' 'msgpack-c' 'unibilium' 'tree-sitter')
        \\makedepends=('cmake' 'git' 'gperf' 'lua51-mpack' 'lua51-lpeg')
        \\optdepends=('python2-neovim: for Python 2 plugin support (see :help provider-python)'
        \\            'python-neovim: for Python 3 plugin support (see :help provider-python)'
        \\            'ruby-neovim: for Ruby plugin support (see :help provider-ruby)'
        \\            'xclip: for clipboard support (or xsel) (see :help provider-clipboard)'
        \\            'xsel: for clipboard support (or xclip) (see :help provider-clipboard)'
        \\            'wl-clipboard: for clipboard support on wayland (see :help clipboard)')
        \\source=("${pkgname}::git+https://github.com/neovim/neovim.git")
        \\sha256sums=('SKIP')
        \\provides=("neovim=${pkgver}" 'vim-plugin-runtime')
        \\conflicts=('neovim')
        \\install=neovim-git.install
        \\options=(!strip)
        \\
        \\pkgver() {
        \\  cd "${pkgname}"
        \\  git describe --long | sed 's/^v//;s/\([^-]*-g\)/r\1/;s/-/./g'
        \\}
        \\
        \\build() {
        \\  cmake -S"${pkgname}" -Bbuild \
        \\        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        \\        -DCMAKE_INSTALL_PREFIX=/usr
        \\  cmake --build build
        \\}
        \\
        \\check() {
        \\  cd "${srcdir}/build"
        \\  ./bin/nvim --version
        \\  ./bin/nvim --headless -u NONE -i NONE -c ':quit'
        \\}
        \\
        \\package() {
        \\  cd "${srcdir}/build"
        \\  DESTDIR="${pkgdir}" cmake --build . --target install
        \\
        \\  cd "${srcdir}/${pkgname}"
        \\  install -Dm644 LICENSE "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
        \\  install -Dm644 runtime/nvim.desktop "${pkgdir}/usr/share/applications/nvim.desktop"
        \\  install -Dm644 runtime/nvim.png "${pkgdir}/usr/share/pixmaps/nvim.png"
        \\
        \\  # Make Arch vim packages work
        \\  mkdir -p "${pkgdir}"/etc/xdg/nvim
        \\  echo "\" This line makes pacman-installed global Arch Linux vim packages work." > "${pkgdir}"/etc/xdg/nvim/sysinit.vim
        \\  echo "source /usr/share/nvim/archlinux.vim" >> "${pkgdir}"/etc/xdg/nvim/sysinit.vim
        \\
        \\  mkdir -p "${pkgdir}"/usr/share/vim
        \\  echo "set runtimepath+=/usr/share/vim/vimfiles" > "${pkgdir}"/usr/share/nvim/archlinux.vim
        \\}
        \\
        \\# vim:set sw=2 sts=2 et:
    ;
    var expectedMap = std.StringHashMap(*Content).init(testing.allocator);
    defer expectedMap.deinit();

    var install_val = std.ArrayList(u8).init(testing.allocator);
    try install_val.appendSlice("neovim-git.install");
    var install_content = try Content.init(testing.allocator, try install_val.toOwnedSlice());
    defer install_content.deinit(testing.allocator);
    try expectedMap.putNoClobber("install", install_content);

    var package_val = std.ArrayList(u8).init(testing.allocator);
    try package_val.appendSlice(
        \\{
        \\  cd "${srcdir}/build"
        \\  DESTDIR="${pkgdir}" cmake --build . --target install
        \\
        \\  cd "${srcdir}/${pkgname}"
        \\  install -Dm644 LICENSE "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
        \\  install -Dm644 runtime/nvim.desktop "${pkgdir}/usr/share/applications/nvim.desktop"
        \\  install -Dm644 runtime/nvim.png "${pkgdir}/usr/share/pixmaps/nvim.png"
        \\
        \\  # Make Arch vim packages work
        \\  mkdir -p "${pkgdir}"/etc/xdg/nvim
        \\  echo "\" This line makes pacman-installed global Arch Linux vim packages work." > "${pkgdir}"/etc/xdg/nvim/sysinit.vim
        \\  echo "source /usr/share/nvim/archlinux.vim" >> "${pkgdir}"/etc/xdg/nvim/sysinit.vim
        \\
        \\  mkdir -p "${pkgdir}"/usr/share/vim
        \\  echo "set runtimepath+=/usr/share/vim/vimfiles" > "${pkgdir}"/usr/share/nvim/archlinux.vim
        \\}
    );
    var package_content = try Content.init(testing.allocator, try package_val.toOwnedSlice());
    defer package_content.deinit(testing.allocator);
    try expectedMap.putNoClobber("package()", package_content);

    var pkgbuild = Pkgbuild.init(testing.allocator, file_contents);
    defer pkgbuild.deinit();
    try pkgbuild.readLines();

    try testing.expectEqualStrings(expectedMap.get("install").?.value, pkgbuild.fields.get("install").?.value);
    try testing.expectEqualStrings(expectedMap.get("package()").?.value, pkgbuild.fields.get("package()").?.value);
}

test "Pkgbuild - readLines - google-chrome-dev" {
    const file_contents =
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
        \\      'libpipewire02: WebRTC desktop sharing under Wayland'
        \\      'kdialog: for file dialogs in KDE'
        \\      'gnome-keyring: for storing passwords in GNOME keyring'
        \\      'kwallet: for storing passwords in KWallet'
        \\      'libunity: for download progress on KDE'
        \\      'ttf-liberation: fix fonts for some PDFs - CRBug #369991'
        \\      'xdg-utils'
        \\)
        \\provides=('google-chrome')
        \\options=('!emptydirs' '!strip')
        \\install=$pkgname.install
        \\_channel=unstable
        \\source=("https://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-${_channel}/google-chrome-${_channel}_${pkgver}-1_amd64.deb"
        \\      'eula_text.html'
        \\      "google-chrome-$_channel.sh")
        \\sha512sums=('7ab84e51b0cd80c51e0092fe67af1e4e9dd886c6437d9d0fec1552e511c1924d2dac21c02153382cbb7c8c52ef82df97428fbb12139ebc048f1db6964ddc3b45'
        \\            'a225555c06b7c32f9f2657004558e3f996c981481dbb0d3cd79b1d59fa3f05d591af88399422d3ab29d9446c103e98d567aeafe061d9550817ab6e7eb0498396'
        \\            '349fc419796bdea83ebcda2c33b262984ce4d37f2a0a13ef7e1c87a9f619fd05eb8ff1d41687f51b907b43b9a2c3b4a33b9b7c3a3b28c12cf9527ffdbd1ddf2e')
        \\
        \\package() {
        \\      msg2 "Extracting the data.tar.xz..."
        \\      bsdtar -xf data.tar.xz -C "$pkgdir/"
        \\
        \\      msg2 "Moving stuff in place..."
        \\      # Launcher
        \\      install -m755 google-chrome-$_channel.sh "$pkgdir"/usr/bin/google-chrome-$_channel
        \\
        \\      # Icons
        \\      for i in 16x16 24x24 32x32 48x48 64x64 128x128 256x256; do
        \\              install -Dm644 "$pkgdir"/opt/google/chrome-$_channel/product_logo_${i/x*/}_${pkgname/*-/}.png \
        \\                      "$pkgdir"/usr/share/icons/hicolor/$i/apps/google-chrome-$_channel.png
        \\      done
        \\
        \\      # License
        \\      install -Dm644 eula_text.html "$pkgdir"/usr/share/licenses/google-chrome-$_channel/eula_text.html
        \\
        \\      msg2 "Fixing Chrome icon resolution..."
        \\      sed -i \
        \\              -e "/Exec=/i\StartupWMClass=Google-chrome-$_channel" \
        \\              -e "s/x-scheme-handler\/ftp;\?//g" \
        \\              "$pkgdir"/usr/share/applications/google-chrome-$_channel.desktop
        \\
        \\      msg2 "Removing Debian Cron job and duplicate product logos..."
        \\      rm -r "$pkgdir"/etc/cron.daily/ "$pkgdir"/opt/google/chrome-$_channel/cron/
        \\      rm "$pkgdir"/opt/google/chrome-$_channel/product_logo_*.png
        \\}
    ;
    var expectedMap = std.StringHashMap(*Content).init(testing.allocator);
    defer expectedMap.deinit();

    var install_val = std.ArrayList(u8).init(testing.allocator);
    try install_val.appendSlice("$pkgname.install");
    var install_content = try Content.init(testing.allocator, try install_val.toOwnedSlice());
    defer install_content.deinit(testing.allocator);
    try expectedMap.putNoClobber("install", install_content);

    var source_val = std.ArrayList(u8).init(testing.allocator);
    try source_val.appendSlice(
        \\"https://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-${_channel}/google-chrome-${_channel}_${pkgver}-1_amd64.deb"
        \\'eula_text.html'
        \\"google-chrome-$_channel.sh"
    );
    var source_content = try Content.init(testing.allocator, try source_val.toOwnedSlice());
    defer source_content.deinit(testing.allocator);
    try expectedMap.putNoClobber("source", source_content);

    var package_val = std.ArrayList(u8).init(testing.allocator);
    try package_val.appendSlice(
        \\{
        \\      msg2 "Extracting the data.tar.xz..."
        \\      bsdtar -xf data.tar.xz -C "$pkgdir/"
        \\
        \\      msg2 "Moving stuff in place..."
        \\      # Launcher
        \\      install -m755 google-chrome-$_channel.sh "$pkgdir"/usr/bin/google-chrome-$_channel
        \\
        \\      # Icons
        \\      for i in 16x16 24x24 32x32 48x48 64x64 128x128 256x256; do
        \\              install -Dm644 "$pkgdir"/opt/google/chrome-$_channel/product_logo_${i/x*/}_${pkgname/*-/}.png \
        \\                      "$pkgdir"/usr/share/icons/hicolor/$i/apps/google-chrome-$_channel.png
        \\      done
        \\
        \\      # License
        \\      install -Dm644 eula_text.html "$pkgdir"/usr/share/licenses/google-chrome-$_channel/eula_text.html
        \\
        \\      msg2 "Fixing Chrome icon resolution..."
        \\      sed -i \
        \\              -e "/Exec=/i\StartupWMClass=Google-chrome-$_channel" \
        \\              -e "s/x-scheme-handler\/ftp;\?//g" \
        \\              "$pkgdir"/usr/share/applications/google-chrome-$_channel.desktop
        \\
        \\      msg2 "Removing Debian Cron job and duplicate product logos..."
        \\      rm -r "$pkgdir"/etc/cron.daily/ "$pkgdir"/opt/google/chrome-$_channel/cron/
        \\      rm "$pkgdir"/opt/google/chrome-$_channel/product_logo_*.png
        \\}
    );
    var package_content = try Content.init(testing.allocator, try package_val.toOwnedSlice());
    defer package_content.deinit(testing.allocator);
    try expectedMap.putNoClobber("package()", package_content);

    var pkgbuild = Pkgbuild.init(testing.allocator, file_contents);
    defer pkgbuild.deinit();
    try pkgbuild.readLines();

    try testing.expectEqualStrings(expectedMap.get("install").?.value, pkgbuild.fields.get("install").?.value);
    try testing.expectEqualStrings(expectedMap.get("source").?.value, pkgbuild.fields.get("source").?.value);
    try testing.expectEqualStrings(expectedMap.get("package()").?.value, pkgbuild.fields.get("package()").?.value);
}

test "Pkgbuild - compare" {
    const old =
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
    const new =
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
    try testing.expect(pkgbuild_new.fields.get("install").?.updated);
    try testing.expect(pkgbuild_new.fields.get("pkgver()").?.updated);
}

test "Pkgbuild - indentValue - google-chrome-dev" {
    const file_contents =
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
        \\      'libpipewire02: WebRTC desktop sharing under Wayland'
        \\      'kdialog: for file dialogs in KDE'
        \\      'gnome-keyring: for storing passwords in GNOME keyring'
        \\      'kwallet: for storing passwords in KWallet'
        \\      'libunity: for download progress on KDE'
        \\      'ttf-liberation: fix fonts for some PDFs - CRBug #369991'
        \\      'xdg-utils'
        \\)
        \\provides=('google-chrome')
        \\options=('!emptydirs' '!strip')
        \\install=$pkgname.install
        \\_channel=unstable
        \\source=("https://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-${_channel}/google-chrome-${_channel}_${pkgver}-1_amd64.deb"
        \\      'eula_text.html'
        \\      "google-chrome-$_channel.sh")
        \\sha512sums=('7ab84e51b0cd80c51e0092fe67af1e4e9dd886c6437d9d0fec1552e511c1924d2dac21c02153382cbb7c8c52ef82df97428fbb12139ebc048f1db6964ddc3b45'
        \\            'a225555c06b7c32f9f2657004558e3f996c981481dbb0d3cd79b1d59fa3f05d591af88399422d3ab29d9446c103e98d567aeafe061d9550817ab6e7eb0498396'
        \\            '349fc419796bdea83ebcda2c33b262984ce4d37f2a0a13ef7e1c87a9f619fd05eb8ff1d41687f51b907b43b9a2c3b4a33b9b7c3a3b28c12cf9527ffdbd1ddf2e')
        \\
        \\package() {
        \\    msg2 "Extracting the data.tar.xz..."
        \\    bsdtar -xf data.tar.xz -C "$pkgdir/"
        \\
        \\    msg2 "Moving stuff in place..."
        \\    # Launcher
        \\    install -m755 google-chrome-$_channel.sh "$pkgdir"/usr/bin/google-chrome-$_channel
        \\
        \\    # Icons
        \\    for i in 16x16 24x24 32x32 48x48 64x64 128x128 256x256; do
        \\            install -Dm644 "$pkgdir"/opt/google/chrome-$_channel/product_logo_${i/x*/}_${pkgname/*-/}.png \
        \\                    "$pkgdir"/usr/share/icons/hicolor/$i/apps/google-chrome-$_channel.png
        \\    done
        \\
        \\    # License
        \\    install -Dm644 eula_text.html "$pkgdir"/usr/share/licenses/google-chrome-$_channel/eula_text.html
        \\
        \\    msg2 "Fixing Chrome icon resolution..."
        \\    sed -i \
        \\            -e "/Exec=/i\StartupWMClass=Google-chrome-$_channel" \
        \\            -e "s/x-scheme-handler\/ftp;\?//g" \
        \\            "$pkgdir"/usr/share/applications/google-chrome-$_channel.desktop
        \\
        \\    msg2 "Removing Debian Cron job and duplicate product logos..."
        \\    rm -r "$pkgdir"/etc/cron.daily/ "$pkgdir"/opt/google/chrome-$_channel/cron/
        \\    rm "$pkgdir"/opt/google/chrome-$_channel/product_logo_*.png
        \\}
    ;
    var expectedMap = std.StringHashMap(*Content).init(testing.allocator);
    defer expectedMap.deinit();

    var package_val = std.ArrayList(u8).init(testing.allocator);
    try package_val.appendSlice(
        \\  {
        \\      msg2 "Extracting the data.tar.xz..."
        \\      bsdtar -xf data.tar.xz -C "$pkgdir/"
        \\  
        \\      msg2 "Moving stuff in place..."
        \\      # Launcher
        \\      install -m755 google-chrome-$_channel.sh "$pkgdir"/usr/bin/google-chrome-$_channel
        \\  
        \\      # Icons
        \\      for i in 16x16 24x24 32x32 48x48 64x64 128x128 256x256; do
        \\              install -Dm644 "$pkgdir"/opt/google/chrome-$_channel/product_logo_${i/x*/}_${pkgname/*-/}.png \
        \\                      "$pkgdir"/usr/share/icons/hicolor/$i/apps/google-chrome-$_channel.png
        \\      done
        \\  
        \\      # License
        \\      install -Dm644 eula_text.html "$pkgdir"/usr/share/licenses/google-chrome-$_channel/eula_text.html
        \\  
        \\      msg2 "Fixing Chrome icon resolution..."
        \\      sed -i \
        \\              -e "/Exec=/i\StartupWMClass=Google-chrome-$_channel" \
        \\              -e "s/x-scheme-handler\/ftp;\?//g" \
        \\              "$pkgdir"/usr/share/applications/google-chrome-$_channel.desktop
        \\  
        \\      msg2 "Removing Debian Cron job and duplicate product logos..."
        \\      rm -r "$pkgdir"/etc/cron.daily/ "$pkgdir"/opt/google/chrome-$_channel/cron/
        \\      rm "$pkgdir"/opt/google/chrome-$_channel/product_logo_*.png
        \\  }
        \\
    );
    var package_content = try Content.init(testing.allocator, try package_val.toOwnedSlice());
    defer package_content.deinit(testing.allocator);
    try expectedMap.putNoClobber("package()", package_content);

    var pkgbuild = Pkgbuild.init(testing.allocator, file_contents);
    defer pkgbuild.deinit();
    try pkgbuild.readLines();
    try pkgbuild.indentValues(2);

    try testing.expectEqualStrings(expectedMap.get("package()").?.value, pkgbuild.fields.get("package()").?.value);
}
