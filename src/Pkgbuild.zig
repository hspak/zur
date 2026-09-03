//! Static PKGBUILD parser: extract top-level assignments and function
//! bodies without evaluating Bash, so zur can review and display changes.

const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const Allocator = mem.Allocator;
const log = std.log.scoped(.pkgbuild);

// Supported forms: name=value, name=( ... ), name() { ... }, package_foo() { ... }.
// $var/${var}, command substitution, and conditionals are left as literal text.
// Quotes are preserved. Unquoted array whitespace collapses to a single space.

const Pkgbuild = @This();

const ErrorSet = Allocator.Error || error{
    MalformedFunction,
    UnterminatedArray,
    UnterminatedFunction,
};
pub const Error = ErrorSet;

allocator: Allocator,
file_contents: []const u8,
fields: std.StringHashMapUnmanaged(*Content) = .empty,

// Fields compared when reviewing PKGBUILD changes between versions.
const relevant_fields = &[_][]const u8{
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

    fn init(value: []const u8) Content {
        return .{ .value = value };
    }

    fn deinit(self: *Content, allocator: Allocator) void {
        allocator.free(self.value);
        self.* = undefined;
    }
};

const Parser = struct {
    src: []const u8,
    pos: usize,
    allocator: Allocator,
    fields: *std.StringHashMapUnmanaged(*Content),

    fn parse(self: *Parser) !void {
        while (self.pos < self.src.len) {
            self.skipBlanksAndComments();
            if (self.pos >= self.src.len) break;

            const name_start = self.pos;
            if (!self.scanName()) {
                // Unknown top-level statement (not an assignment or function).
                self.skipToEol();
                continue;
            }
            const name = self.src[name_start..self.pos];

            self.skipSpacesAndTabs();
            if (self.pos >= self.src.len) break;

            const c = self.src[self.pos];
            if (c == '=') {
                self.pos += 1;
                try self.parseAssignment(name);
            } else if (c == '(') {
                try self.parseFunction(name);
            } else {
                self.skipToEol();
            }
        }
    }

    fn parseAssignment(self: *Parser, name: []const u8) !void {
        self.skipSpacesAndTabs();
        if (self.pos < self.src.len and self.src[self.pos] == '(') {
            self.pos += 1;
            const value = try self.readArrayBody();
            errdefer self.allocator.free(value);
            try self.putField(name, value);
        } else {
            const value = try self.readScalarValue();
            errdefer self.allocator.free(value);
            try self.putField(name, value);
        }
    }

    fn parseFunction(self: *Parser, name: []const u8) !void {
        if (self.pos >= self.src.len or self.src[self.pos] != '(') return error.MalformedFunction;
        self.pos += 1;
        self.skipSpacesAndTabs();
        if (self.pos >= self.src.len or self.src[self.pos] != ')') return error.MalformedFunction;
        self.pos += 1;
        self.skipSpacesAndTabs();
        // Allow a newline between () and {
        self.skipNewlines();
        self.skipSpacesAndTabs();
        if (self.pos >= self.src.len or self.src[self.pos] != '{') return error.MalformedFunction;

        const body = try self.readBraceGroup();
        errdefer self.allocator.free(body);

        // Key is "name()" so pkgver variable and pkgver() function don't collide
        var key_buf: std.ArrayList(u8) = .empty;
        errdefer key_buf.deinit(self.allocator);
        try key_buf.appendSlice(self.allocator, name);
        try key_buf.appendSlice(self.allocator, "()");
        const key = try key_buf.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(key);

        try self.putFieldOwnedKey(key, body);
    }

    /// Read a scalar value up to end-of-line, respecting quotes and line continuations (\).
    fn readScalarValue(self: *Parser) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        var quote: ?u8 = null;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];

            if (quote) |q| {
                try out.append(self.allocator, c);
                self.pos += 1;
                if (c == '\\' and q == '"' and self.pos < self.src.len) {
                    try out.append(self.allocator, self.src[self.pos]);
                    self.pos += 1;
                } else if (c == q) {
                    quote = null;
                }
                continue;
            }

            switch (c) {
                '\'', '"' => {
                    quote = c;
                    try out.append(self.allocator, c);
                    self.pos += 1;
                },
                '\\' => {
                    self.pos += 1;
                    if (self.pos < self.src.len and self.src[self.pos] == '\n') {
                        try out.append(self.allocator, '\\');
                        try out.append(self.allocator, '\n');
                        self.pos += 1;
                    } else if (self.pos < self.src.len) {
                        try out.append(self.allocator, '\\');
                        try out.append(self.allocator, self.src[self.pos]);
                        self.pos += 1;
                    } else {
                        try out.append(self.allocator, '\\');
                    }
                },
                '\n' => {
                    self.pos += 1;
                    break;
                },
                '#' => {
                    // Unquoted comment to EOL — not part of the value
                    self.skipToEol();
                    break;
                },
                else => {
                    try out.append(self.allocator, c);
                    self.pos += 1;
                },
            }
        }
        const value = try out.toOwnedSlice(self.allocator);
        return value;
    }

    /// Read array body after the opening '('. Strips unquoted spaces/tabs
    /// (legacy display format) while preserving quotes, newlines, and content.
    fn readArrayBody(self: *Parser) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        var quote: ?u8 = null;
        var depth: usize = 1; // already consumed the outer '('

        while (self.pos < self.src.len) {
            const c = self.src[self.pos];

            if (quote) |q| {
                try out.append(self.allocator, c);
                self.pos += 1;
                if (c == '\\' and q == '"' and self.pos < self.src.len) {
                    try out.append(self.allocator, self.src[self.pos]);
                    self.pos += 1;
                } else if (c == q) {
                    quote = null;
                }
                continue;
            }

            switch (c) {
                '\'', '"' => {
                    quote = c;
                    try out.append(self.allocator, c);
                    self.pos += 1;
                },
                '(' => {
                    depth += 1;
                    try out.append(self.allocator, c);
                    self.pos += 1;
                },
                ')' => {
                    depth -= 1;
                    self.pos += 1;
                    if (depth == 0) {
                        self.skipSpacesAndTabs();
                        if (self.pos < self.src.len and self.src[self.pos] == '\n') self.pos += 1;
                        return try out.toOwnedSlice(self.allocator);
                    }
                    try out.append(self.allocator, c);
                },
                ' ', '\t' => {
                    // Collapse runs of unquoted whitespace to a single space so
                    // adjacent array elements never get merged together.
                    var saw_ws = false;
                    while (self.pos < self.src.len and
                        (self.src[self.pos] == ' ' or self.src[self.pos] == '\t'))
                    {
                        saw_ws = true;
                        self.pos += 1;
                    }
                    if (saw_ws and out.items.len != 0 and !isArrayWs(out.items[out.items.len - 1])) {
                        try out.append(self.allocator, ' ');
                    }
                },
                '\\' => {
                    self.pos += 1;
                    if (self.pos < self.src.len) {
                        try out.append(self.allocator, '\\');
                        try out.append(self.allocator, self.src[self.pos]);
                        self.pos += 1;
                    }
                },
                '#' => {
                    // Unlike a scalar, the array continues on the next line.
                    self.skipToEol();
                },
                else => {
                    try out.append(self.allocator, c);
                    self.pos += 1;
                },
            }
        }
        return error.UnterminatedArray;
    }

    /// Read `{ ... }` with brace nesting, quotes, and comments. Includes the braces.
    fn readBraceGroup(self: *Parser) ![]u8 {
        std.debug.assert(self.src[self.pos] == '{');
        const start = self.pos;
        self.pos += 1;

        var quote: ?u8 = null;
        var depth: usize = 1;

        while (self.pos < self.src.len) {
            const c = self.src[self.pos];

            if (quote) |q| {
                self.pos += 1;
                if (c == '\\' and q == '"' and self.pos < self.src.len) {
                    self.pos += 1;
                } else if (c == q) {
                    quote = null;
                }
                continue;
            }

            switch (c) {
                '\'', '"' => {
                    quote = c;
                    self.pos += 1;
                },
                '#' => {
                    self.skipToEol();
                },
                '{' => {
                    depth += 1;
                    self.pos += 1;
                },
                '}' => {
                    depth -= 1;
                    self.pos += 1;
                    if (depth == 0) {
                        return try self.allocator.dupe(u8, self.src[start..self.pos]);
                    }
                },
                else => self.pos += 1,
            }
        }
        return error.UnterminatedFunction;
    }

    fn putField(self: *Parser, name: []const u8, value: []u8) !void {
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        try self.putFieldOwnedKey(key, value);
    }

    fn putFieldOwnedKey(self: *Parser, key: []u8, value: []u8) !void {
        const content = try self.allocator.create(Content);
        content.* = .init(value);
        errdefer self.allocator.destroy(content);
        errdefer content.deinit(self.allocator);
        // Last assignment wins (bash semantics). getOrPut first so a failed
        // insert cannot drop an existing entry.
        const gop = try self.fields.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            self.allocator.free(key);
            gop.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = key;
        }
        gop.value_ptr.* = content;
    }

    fn scanName(self: *Parser) bool {
        if (self.pos >= self.src.len) return false;
        const c0 = self.src[self.pos];
        // Bash name: [a-zA-Z_][a-zA-Z0-9_]*
        if (!isNameStart(c0)) return false;
        self.pos += 1;
        while (self.pos < self.src.len and isNameCont(self.src[self.pos])) {
            self.pos += 1;
        }
        return true;
    }

    fn skipBlanksAndComments(self: *Parser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else if (c == '#') {
                self.skipToEol();
            } else {
                break;
            }
        }
    }

    fn skipSpacesAndTabs(self: *Parser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t') self.pos += 1 else break;
        }
    }

    fn skipNewlines(self: *Parser) void {
        while (self.pos < self.src.len and
            (self.src[self.pos] == '\n' or self.src[self.pos] == '\r'))
        {
            self.pos += 1;
        }
    }

    fn skipToEol(self: *Parser) void {
        while (self.pos < self.src.len and self.src[self.pos] != '\n') {
            self.pos += 1;
        }
        if (self.pos < self.src.len and self.src[self.pos] == '\n') {
            self.pos += 1;
        }
    }
};

/// Bind `file_contents` (not copied) and an empty field map.
pub fn init(allocator: Allocator, file_contents: []const u8) Pkgbuild {
    return .{
        .allocator = allocator,
        .file_contents = file_contents,
    };
}

/// Free parsed field keys and values. Does not free `file_contents`.
pub fn deinit(self: *Pkgbuild) void {
    var iter = self.fields.iterator();
    while (iter.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        entry.value_ptr.*.deinit(self.allocator);
        self.allocator.destroy(entry.value_ptr.*);
    }
    self.fields.deinit(self.allocator);
    self.* = undefined;
}

/// Parse `file_contents` into `fields`. Last assignment of a name wins.
pub fn readLines(self: *Pkgbuild) Error!void {
    var parser: Parser = .{
        .src = self.file_contents,
        .pos = 0,
        .allocator = self.allocator,
        .fields = &self.fields,
    };
    try parser.parse();
    log.debug("parsed {d} fields", .{self.fields.count()});
}

/// Mark relevant fields as `updated` when they differ from `prev_pkgbuild`.
pub fn comparePrev(self: *Pkgbuild, prev_pkgbuild: Pkgbuild) Error!void {
    for (relevant_fields) |field| {
        try self.compareField(prev_pkgbuild, field);
    }
}

/// Mark the `source_<architecture>` field as updated when it differs.
pub fn compareArchSource(
    self: *Pkgbuild,
    prev_pkgbuild: Pkgbuild,
    architecture: []const u8,
) Error!void {
    const field = try std.fmt.allocPrint(self.allocator, "source_{s}", .{architecture});
    defer self.allocator.free(field);
    try self.compareField(prev_pkgbuild, field);
}

fn compareField(self: *Pkgbuild, prev_pkgbuild: Pkgbuild, field: []const u8) Error!void {
    const prev = prev_pkgbuild.fields.get(field);
    const curr = self.fields.get(field);
    if (prev == null and curr != null) {
        curr.?.updated = true;
    } else if (prev != null and curr == null) {
        const removed = try self.allocator.dupe(u8, "(removed)");
        errdefer self.allocator.free(removed);
        const content = try self.allocator.create(Content);
        errdefer self.allocator.destroy(content);
        content.* = .init(removed);
        content.updated = true;
        const key_copy = try self.allocator.dupe(u8, field);
        errdefer self.allocator.free(key_copy);
        try self.fields.put(self.allocator, key_copy, content);
    } else if (prev == null and curr == null) {
        return;
    } else if (prev != null and curr != null and !mem.eql(u8, prev.?.value, curr.?.value)) {
        curr.?.updated = true;
    }
}

/// Prefix every line of function-body fields with `spaces_count` spaces.
pub fn indentValues(self: *Pkgbuild, spaces_count: usize) Error!void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);

    var fields_iter = self.fields.iterator();
    while (fields_iter.next()) |field| {
        if (!mem.endsWith(u8, field.key_ptr.*, "()")) continue;

        buf.clearRetainingCapacity();
        var lines_iter = mem.splitScalar(u8, field.value_ptr.*.value, '\n');
        while (lines_iter.next()) |line| {
            try buf.appendNTimes(self.allocator, ' ', spaces_count);
            try buf.appendSlice(self.allocator, line);
            try buf.append(self.allocator, '\n');
        }
        const indented = try buf.toOwnedSlice(self.allocator);
        self.allocator.free(field.value_ptr.*.value);
        field.value_ptr.*.value = indented;
    }
}

/// Look up a field value by name (e.g. "pkgver", "depends", "package()").
pub fn get(self: *const Pkgbuild, name: []const u8) ?[]const u8 {
    const content = self.fields.get(name) orelse return null;
    return content.value;
}

fn isArrayWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isNameStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isNameCont(c: u8) bool {
    return isNameStart(c) or (c >= '0' and c <= '9');
}

test "readLines parses a real neovim-git PKGBUILD" {
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

    var pkgbuild = Pkgbuild.init(testing.allocator, file_contents);
    defer pkgbuild.deinit();
    try pkgbuild.readLines();

    try testing.expectEqualStrings("neovim-git.install", pkgbuild.get("install").?);
    try testing.expectEqualStrings("neovim-git", pkgbuild.get("pkgname").?);
    try testing.expectEqualStrings("0.4.0.r2972.g3fbff98cf", pkgbuild.get("pkgver").?);

    const package_body = pkgbuild.get("package()").?;
    try testing.expect(mem.indexOf(u8, package_body, "DESTDIR=\"${pkgdir}\"") != null);
    try testing.expect(mem.indexOf(u8, package_body, "archlinux.vim") != null);

    // Function keys use () suffix so they don't collide with variables
    try testing.expect(pkgbuild.get("pkgver()") != null);
    try testing.expect(pkgbuild.get("build()") != null);
    try testing.expect(pkgbuild.get("check()") != null);
}

test "readLines parses a real google-chrome-dev PKGBUILD" {
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
        \\              -e "s/x-scheme-handler\/ftp;\\?//g" \
        \\              "$pkgdir"/usr/share/applications/google-chrome-$_channel.desktop
        \\
        \\      msg2 "Removing Debian Cron job and duplicate product logos..."
        \\      rm -r "$pkgdir"/etc/cron.daily/ "$pkgdir"/opt/google/chrome-$_channel/cron/
        \\      rm "$pkgdir"/opt/google/chrome-$_channel/product_logo_*.png
        \\}
    ;

    var pkgbuild = Pkgbuild.init(testing.allocator, file_contents);
    defer pkgbuild.deinit();
    try pkgbuild.readLines();

    try testing.expectEqualStrings("$pkgname.install", pkgbuild.get("install").?);
    try testing.expectEqualStrings("unstable", pkgbuild.get("_channel").?);

    const source_val = pkgbuild.get("source").?;
    try testing.expect(mem.indexOf(u8, source_val, "google-chrome-${_channel}") != null);
    try testing.expect(mem.indexOf(u8, source_val, "eula_text.html") != null);
    try testing.expect(mem.indexOf(u8, source_val, "google-chrome-$_channel.sh") != null);

    const package_body = pkgbuild.get("package()").?;
    try testing.expect(mem.indexOf(u8, package_body, "bsdtar -xf data.tar.xz") != null);
    try testing.expect(mem.indexOf(u8, package_body, "product_logo_") != null);
}

test "comparePrev marks only changed review fields" {
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
        \\source=("https://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-${_channel}/google-chrome-${_channel}_${pkgver}-1_amd64.deb"
        \\      'eula_text.html'
        \\      "google-chrome-$_channel.sh")
        \\sha512sums=('sha' 'sum' '512')
        \\
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
        \\install=CHANGED.install
        \\_channel=unstable
        \\source=("https://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-${_channel}/google-chrome-${_channel}_${pkgver}-1_amd64.deb"
        \\      'eula_text.html'
        \\      "google-chrome-$_channel.sh")
        \\sha512sums=('sha' 'sum' '512')
        \\
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
    try testing.expect(!pkgbuild_new.fields.get("pkgver").?.updated);
    try testing.expect(!pkgbuild_new.fields.get("source").?.updated);
    try testing.expect(!pkgbuild_new.fields.get("sha512sums").?.updated);
    try testing.expect(!pkgbuild_new.fields.get("pkgdesc").?.updated);
    try testing.expect(!pkgbuild_new.fields.get("install()").?.updated);
}

test "indentValues prefixes every function-body line" {
    const file_contents =
        \\pkgname=google-chrome-dev
        \\package() {
        \\      msg2 "Extracting the data.tar.xz..."
        \\      bsdtar -xf data.tar.xz -C "$pkgdir/"
        \\}
    ;

    var pkgbuild = Pkgbuild.init(testing.allocator, file_contents);
    defer pkgbuild.deinit();
    try pkgbuild.readLines();
    try pkgbuild.indentValues(2);

    const expected =
        "  {\n" ++
        "        msg2 \"Extracting the data.tar.xz...\"\n" ++
        "        bsdtar -xf data.tar.xz -C \"$pkgdir/\"\n" ++
        "  }\n";
    try testing.expectEqualStrings(expected, pkgbuild.get("package()").?);
}

test "comparePrev records a removed review field as updated" {
    const old =
        \\pkgname=testpkg
        \\install=test.install
        \\package() {
        \\    echo "hello"
        \\}
    ;
    const new =
        \\pkgname=testpkg
        \\package() {
        \\    echo "hello"
        \\}
    ;

    var pkgbuild_old = Pkgbuild.init(testing.allocator, old);
    defer pkgbuild_old.deinit();
    try pkgbuild_old.readLines();

    var pkgbuild_new = Pkgbuild.init(testing.allocator, new);
    defer pkgbuild_new.deinit();
    try pkgbuild_new.readLines();

    try pkgbuild_new.comparePrev(pkgbuild_old);

    const install_field = pkgbuild_new.fields.get("install");
    try testing.expect(install_field != null);
    try testing.expectEqualStrings("(removed)", install_field.?.value);
    try testing.expect(install_field.?.updated);
}

test "compareArchSource marks only the selected architecture" {
    const old =
        \\source_x86_64=('https://example.com/old-x86_64.tar.gz')
        \\source_aarch64=('https://example.com/old-aarch64.tar.gz')
    ;
    const new =
        \\source_x86_64=('https://example.com/new-x86_64.tar.gz')
        \\source_aarch64=('https://example.com/new-aarch64.tar.gz')
    ;

    var pkgbuild_old = Pkgbuild.init(testing.allocator, old);
    defer pkgbuild_old.deinit();
    try pkgbuild_old.readLines();

    var pkgbuild_new = Pkgbuild.init(testing.allocator, new);
    defer pkgbuild_new.deinit();
    try pkgbuild_new.readLines();

    try pkgbuild_new.compareArchSource(pkgbuild_old, "x86_64");

    try testing.expect(pkgbuild_new.fields.get("source_x86_64").?.updated);
    try testing.expect(!pkgbuild_new.fields.get("source_aarch64").?.updated);
}

test "indentValues keeps multiple function bodies independent" {
    const file_contents =
        \\pkgname=testpkg
        \\build() {
        \\    make
        \\}
        \\package() {
        \\    make install
        \\}
    ;

    var pkgbuild = Pkgbuild.init(testing.allocator, file_contents);
    defer pkgbuild.deinit();
    try pkgbuild.readLines();
    try pkgbuild.indentValues(2);

    const build_val = pkgbuild.get("build()").?;
    const package_val = pkgbuild.get("package()").?;

    try testing.expectEqualStrings("  {\n      make\n  }\n", build_val);
    try testing.expectEqualStrings("  {\n      make install\n  }\n", package_val);
}

test "readLines preserves a minimal function body" {
    const file_contents =
        \\pkgname=testpkg
        \\pkgver() {
        \\}
    ;

    var pkgbuild = Pkgbuild.init(testing.allocator, file_contents);
    defer pkgbuild.deinit();
    try pkgbuild.readLines();

    try testing.expectEqualStrings("{\n}", pkgbuild.get("pkgver()").?);
}

test "readLines preserves parentheses inside double-quoted array elements" {
    const file_contents =
        \\pkgname=testpkg
        \\source=("http://example.com/file(1).tar.gz" "other.patch")
        \\depends=('dep1' 'dep2')
        \\
    ;

    var pkgbuild = Pkgbuild.init(testing.allocator, file_contents);
    defer pkgbuild.deinit();
    try pkgbuild.readLines();

    try testing.expectEqualStrings(
        "\"http://example.com/file(1).tar.gz\" \"other.patch\"",
        pkgbuild.get("source").?,
    );
    try testing.expectEqualStrings("'dep1' 'dep2'", pkgbuild.get("depends").?);
}

test "readLines preserves parentheses in mixed-quote array elements" {
    const file_contents =
        \\pkgname=testpkg
        \\optdepends=('pkg1: for feature (optional)' "pkg2: another (thing)")
        \\
    ;

    var pkgbuild = Pkgbuild.init(testing.allocator, file_contents);
    defer pkgbuild.deinit();
    try pkgbuild.readLines();

    try testing.expectEqualStrings(
        "'pkg1: for feature (optional)' \"pkg2: another (thing)\"",
        pkgbuild.get("optdepends").?,
    );
}

test "readLines keeps nested braces inside their function" {
    const file_contents =
        \\pkgname=testpkg
        \\package() {
        \\  if true; then
        \\    echo nested
        \\  fi
        \\  {
        \\    echo group
        \\  }
        \\}
        \\pkgrel=1
    ;

    var pkgbuild = Pkgbuild.init(testing.allocator, file_contents);
    defer pkgbuild.deinit();
    try pkgbuild.readLines();

    const expected =
        "{\n" ++
        "  if true; then\n" ++
        "    echo nested\n" ++
        "  fi\n" ++
        "  {\n" ++
        "    echo group\n" ++
        "  }\n" ++
        "}";
    try testing.expectEqualStrings(expected, pkgbuild.get("package()").?);
    try testing.expectEqualStrings("1", pkgbuild.get("pkgrel").?);
}

test "readLines keeps split-package functions independent" {
    const file_contents =
        \\pkgname=('foo' 'bar')
        \\package_foo() {
        \\  depends=('a')
        \\  echo foo
        \\}
        \\package_bar() {
        \\  echo bar
        \\}
    ;

    var pkgbuild = Pkgbuild.init(testing.allocator, file_contents);
    defer pkgbuild.deinit();
    try pkgbuild.readLines();

    try testing.expectEqualStrings(
        "{\n  depends=('a')\n  echo foo\n}",
        pkgbuild.get("package_foo()").?,
    );
    try testing.expectEqualStrings("{\n  echo bar\n}", pkgbuild.get("package_bar()").?);
}

test "readLines parses architecture arrays without comment text" {
    const file_contents =
        \\pkgname=testpkg
        \\depends_x86_64=('libfoo')
        \\source=(
        \\  # primary tarball
        \\  "https://example.com/foo.tar.gz"
        \\  'local.patch'
        \\)
        \\sha256sums=('abc' 'def')
    ;

    var pkgbuild = Pkgbuild.init(testing.allocator, file_contents);
    defer pkgbuild.deinit();
    try pkgbuild.readLines();

    try testing.expectEqualStrings("'libfoo'", pkgbuild.get("depends_x86_64").?);
    try testing.expectEqualStrings(
        "\n\"https://example.com/foo.tar.gz\"\n'local.patch'\n",
        pkgbuild.get("source").?,
    );
    try testing.expectEqualStrings("'abc' 'def'", pkgbuild.get("sha256sums").?);
}

test "readLines preserves hash characters inside quotes" {
    const file_contents =
        \\pkgname=testpkg
        \\pkgdesc="use #hashtags carefully"
        \\source=('file#1.tar.gz')
    ;

    var pkgbuild = Pkgbuild.init(testing.allocator, file_contents);
    defer pkgbuild.deinit();
    try pkgbuild.readLines();

    try testing.expectEqualStrings("\"use #hashtags carefully\"", pkgbuild.get("pkgdesc").?);
    try testing.expectEqualStrings("'file#1.tar.gz'", pkgbuild.get("source").?);
}

test "readLines uses the final assignment to a field" {
    const file_contents =
        \\pkgname=first
        \\pkgname=second
    ;

    var pkgbuild = Pkgbuild.init(testing.allocator, file_contents);
    defer pkgbuild.deinit();
    try pkgbuild.readLines();

    try testing.expectEqualStrings("second", pkgbuild.get("pkgname").?);
}
