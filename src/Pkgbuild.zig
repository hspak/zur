//! Static PKGBUILD parser: extract top-level assignments and function
//! bodies without evaluating Bash, so zur can review and display changes.

const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const Allocator = mem.Allocator;
const log = std.log.scoped(.pkgbuild);

const review_text = @import("review_text.zig");

// Supported forms: name=value, name=( ... ), name() { ... }, package_foo() { ... }.
// $var/${var}, command substitution, and conditionals are left as literal text.
// Quotes are preserved. Unquoted array whitespace collapses to a single space.

const Pkgbuild = @This();

allocator: Allocator,
file_contents: []const u8,
fields: std.StringArrayHashMapUnmanaged(*Content) = .empty,
/// True when presentation must use the original text to avoid omitting shell code.
unparsed: bool = false,

pub const Error = Allocator.Error || error{
    MalformedFunction,
    UnterminatedArray,
    UnterminatedFunction,
};

const Content = struct {
    /// Owned by this field; source borrows the original PKGBUILD.
    value: []const u8,
    /// Exact borrowed statement, including syntax omitted from the display value.
    source: []const u8,
    start: usize,
    form: enum {
        scalar,
        array,
        function,
    },

    fn deinit(self: *Content, allocator: Allocator) void {
        allocator.free(self.value);
        self.* = undefined;
    }
};

const Parser = struct {
    src: []const u8,
    pos: usize,
    allocator: Allocator,
    fields: *std.StringArrayHashMapUnmanaged(*Content),
    unparsed: *bool,
    statement_start: usize = 0,
    form: @FieldType(Content, "form") = .scalar,

    fn parse(self: *Parser) !void {
        while (self.pos < self.src.len) {
            self.skipBlanksAndComments();
            if (self.pos >= self.src.len) break;

            const name_start = self.pos;
            self.statement_start = name_start;
            if (!self.scanName()) {
                // Unknown top-level statement (not an assignment or function).
                self.unparsed.* = true;
                self.skipToEol();
                continue;
            }
            const name = self.src[name_start..self.pos];
            const name_end = self.pos;

            self.skipSpacesAndTabs();
            if (self.pos >= self.src.len) {
                self.unparsed.* = true;
                break;
            }

            const c = self.src[self.pos];
            if (c == '=') {
                if (self.pos != name_end) self.unparsed.* = true;
                for (name) |character| {
                    if (!isNameCont(character)) self.unparsed.* = true;
                }
                self.pos += 1;
                try self.parseAssignment(name);
            } else if (c == '(') {
                try self.parseFunction(name);
            } else {
                self.unparsed.* = true;
                self.skipToEol();
            }
        }
    }

    fn parseAssignment(self: *Parser, name: []const u8) !void {
        const value_start = self.pos;
        self.skipSpacesAndTabs();
        if (self.pos != value_start) self.unparsed.* = true;
        if (self.pos < self.src.len and self.src[self.pos] == '(') {
            self.form = .array;
            self.pos += 1;
            const value = try self.readArrayBody();
            errdefer self.allocator.free(value);
            // A display array is a list of literal shell words. Nested shell
            // evaluation needs the original syntax, including its delimiters.
            if (mem.indexOf(u8, value, "$(") != null or
                mem.indexOfScalar(u8, value, '`') != null or
                mem.indexOf(u8, value, "<(") != null or
                mem.indexOf(u8, value, ">(") != null)
            {
                self.unparsed.* = true;
            }
            try self.putField(name, value);
        } else {
            self.form = .scalar;
            const value = try self.readScalarValue();
            errdefer self.allocator.free(value);
            if (mem.indexOf(u8, value, "$(") != null or mem.indexOfScalar(u8, value, '`') != null) {
                self.unparsed.* = true;
            }
            if ((mem.eql(u8, name, "source") or mem.startsWith(u8, name, "source_")) and
                mem.indexOfScalar(u8, value, '\n') != null) self.unparsed.* = true;
            try self.putField(name, value);
        }
    }

    fn parseFunction(self: *Parser, name: []const u8) !void {
        self.form = .function;
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
    fn readScalarValue(self: *Parser) ![]const u8 {
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
                ';', '&', '|', '<', '>' => {
                    self.unparsed.* = true;
                    try out.append(self.allocator, c);
                    self.pos += 1;
                },
                ' ', '\t' => {
                    const start = self.pos;
                    self.skipSpacesAndTabs();
                    if (self.pos < self.src.len and
                        self.src[self.pos] != '\n' and self.src[self.pos] != '#')
                    {
                        self.unparsed.* = true;
                    }
                    try out.appendSlice(self.allocator, self.src[start..self.pos]);
                },
                '#' => {
                    if (self.startsComment()) {
                        self.skipToEol();
                        break;
                    }
                    try out.append(self.allocator, c);
                    self.pos += 1;
                },
                else => {
                    try out.append(self.allocator, c);
                    self.pos += 1;
                },
            }
        }
        if (quote != null) self.unparsed.* = true;
        return try out.toOwnedSlice(self.allocator);
    }

    /// Read the array body after '(', collapsing unquoted spaces/tabs while
    /// preserving quotes and newlines for display.
    fn readArrayBody(self: *Parser) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        var quote: ?u8 = null;
        var depth: usize = 1; // already consumed the outer '('

        while (self.pos < self.src.len) {
            const c = self.src[self.pos];

            if (quote) |q| {
                // Indenting array lines would alter a literal multiline word.
                if (c == '\n') self.unparsed.* = true;
                try out.append(self.allocator, c);
                self.pos += 1;
                if (c == '\\' and q == '"' and self.pos < self.src.len) {
                    if (self.src[self.pos] == '\n') self.unparsed.* = true;
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
                    if (saw_ws and out.items.len != 0 and
                        !isArrayWs(out.items[out.items.len - 1]))
                    {
                        try out.append(self.allocator, ' ');
                    }
                },
                '\\' => {
                    self.pos += 1;
                    if (self.pos < self.src.len) {
                        if (isArrayWs(self.src[self.pos])) self.unparsed.* = true;
                        try out.append(self.allocator, '\\');
                        try out.append(self.allocator, self.src[self.pos]);
                        self.pos += 1;
                    }
                },
                '#' => {
                    if (self.startsComment()) {
                        self.skipToEol();
                    } else {
                        try out.append(self.allocator, c);
                        self.pos += 1;
                    }
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
    fn readBraceGroup(self: *Parser) ![]const u8 {
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
                    if (self.startsComment()) self.skipToEol() else self.pos += 1;
                },
                '\\' => self.pos += @min(@as(usize, 2), self.src.len - self.pos),
                '<' => {
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '<') {
                        // Heredoc contents are shell text, not brace-group tokens.
                        self.unparsed.* = true;
                    }
                    self.pos += 1;
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

    fn putField(self: *Parser, name: []const u8, value: []const u8) !void {
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        try self.putFieldOwnedKey(key, value);
    }

    // Takes ownership of key and value only on success.
    fn putFieldOwnedKey(self: *Parser, key: []const u8, value: []const u8) !void {
        const content = try self.allocator.create(Content);
        errdefer self.allocator.destroy(content);
        content.* = .{
            .value = value,
            .source = self.src[self.statement_start..self.pos],
            .start = self.statement_start,
            .form = self.form,
        };
        // Last assignment wins (bash semantics). getOrPut first so a failed
        // insert cannot drop an existing entry.
        const gop = try self.fields.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            // Earlier assignments and definitions can execute or affect later fields.
            self.unparsed.* = true;
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
        // Bash functions may include package-name punctuation.
        if (!isNameStart(c0)) return false;
        self.pos += 1;
        while (self.pos < self.src.len and
            (isNameCont(self.src[self.pos]) or mem.indexOfScalar(
                u8,
                "-+.@",
                self.src[self.pos],
            ) != null))
        {
            self.pos += 1;
        }
        return true;
    }

    fn startsComment(self: *const Parser) bool {
        return self.pos == 0 or mem.indexOfScalar(
            u8,
            " \t\r\n;|&()",
            self.src[self.pos - 1],
        ) != null;
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
    return .{ .allocator = allocator, .file_contents = file_contents };
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
        .unparsed = &self.unparsed,
    };
    try parser.parse();
    log.debug("parsed {d} fields", .{self.fields.count()});
}

/// Return whether every statement can be presented as a unique field without
/// losing executable text. Unsupported Bash stays available in `file_contents`.
pub fn readForReview(self: *Pkgbuild) Allocator.Error!bool {
    self.readLines() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MalformedFunction,
        error.UnterminatedArray,
        error.UnterminatedFunction,
        => return false,
    };
    return !self.unparsed;
}

/// Return the comments and whitespace between parsed statements. The caller
/// owns the result; use only after `readForReview` returns true.
pub fn remainingText(self: *const Pkgbuild, allocator: Allocator) Allocator.Error![]const u8 {
    var remaining: std.ArrayList(u8) = .empty;
    errdefer remaining.deinit(allocator);
    var end: usize = 0;
    for (self.fields.values()) |field| {
        try remaining.appendSlice(allocator, self.file_contents[end..field.start]);
        end = field.start + field.source.len;
    }
    try remaining.appendSlice(allocator, self.file_contents[end..]);
    return try remaining.toOwnedSlice(allocator);
}

/// Normalize display indentation to `spaces_count` per level. The first line
/// follows a field label; subsequent lines include the outer review margin.
/// Original statements remain in `Content.source` for comparison.
pub fn indentValues(self: *Pkgbuild, spaces_count: usize) Allocator.Error!void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);
    for (self.fields.values()) |field| {
        if (mem.indexOfScalar(u8, field.value, '\n') == null) continue;
        buf.clearRetainingCapacity();
        switch (field.form) {
            .array => {
                var lines = mem.splitScalar(u8, field.value, '\n');
                while (lines.next()) |line| {
                    const item = mem.trim(u8, line, " \t\r");
                    if (item.len == 0) continue;
                    try buf.append(self.allocator, '\n');
                    try buf.appendNTimes(self.allocator, ' ', spaces_count * 2);
                    try buf.appendSlice(self.allocator, item);
                }
            },
            .scalar => {
                // Whitespace in a multiline scalar can be literal data.
                var first_line = true;
                var lines = mem.splitScalar(u8, field.value, '\n');
                while (lines.next()) |line| {
                    if (!first_line) {
                        try buf.append(self.allocator, '\n');
                        try buf.appendNTimes(self.allocator, ' ', spaces_count);
                    }
                    try buf.appendSlice(self.allocator, line);
                    first_line = false;
                }
            },
            .function => try review_text.append(
                self.allocator,
                &buf,
                field.value,
                .{ .spaces_count = spaces_count, .inline_first = true },
            ),
        }
        const indented = try buf.toOwnedSlice(self.allocator);
        self.allocator.free(field.value);
        field.value = indented;
    }
}

/// Return a borrowed field value, or null if the name was not parsed. The slice
/// remains valid until the fields are parsed, indented, or freed again.
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
    const file_contents = @embedFile("Pkgbuild/fixtures/neovim_git.pkgbuild");

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
    const file_contents = @embedFile("Pkgbuild/fixtures/google_chrome_dev.pkgbuild");

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

test "indentValues normalizes function-body indentation" {
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
        "{\n" ++
        "    msg2 \"Extracting the data.tar.xz...\"\n" ++
        "    bsdtar -xf data.tar.xz -C \"$pkgdir/\"\n" ++
        "  }\n";
    try testing.expectEqualStrings(expected, pkgbuild.get("package()").?);
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

    try testing.expectEqualStrings("{\n    make\n  }\n", build_val);
    try testing.expectEqualStrings("{\n    make install\n  }\n", package_val);
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

test "readLines releases each field exactly once on allocation failure" {
    for ([_][]const u8{
        "pkgname=foo\n",
        "source=(one two)\n",
        "package() { echo hello; }\n",
        "pkgname=old\npkgname=new\nsource=(one two)\npackage() { echo hello; }\n",
    }) |source| {
        try testing.checkAllAllocationFailures(testing.allocator, testParseAllocations, .{source});
    }
}

fn testParseAllocations(allocator: Allocator, source: []const u8) !void {
    var pkgbuild = Pkgbuild.init(allocator, source);
    defer pkgbuild.deinit();
    try pkgbuild.readLines();
    try testing.expect(pkgbuild.fields.count() > 0);
}
