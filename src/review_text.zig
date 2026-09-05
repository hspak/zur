//! Shared indentation for source-file previews and parsed PKGBUILD bodies.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const log = std.log.scoped(.review_text);

pub const Options = struct {
    spaces_count: usize = 2,
    /// The first line follows a field label that already includes the margin.
    inline_first: bool = false,
    /// Retain whitespace that carries meaning, such as patch context markers.
    preserve_whitespace: bool = false,
};

pub const WriteError = Allocator.Error || std.Io.Writer.Error;

/// Write a complete preview with an outer margin and normalized nesting.
/// Literal strings and files containing heredocs retain their source whitespace.
pub fn write(
    allocator: Allocator,
    writer: *std.Io.Writer,
    contents: []const u8,
    options: Options,
) WriteError!void {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try append(allocator, &output, contents, options);
    try writer.writeAll(output.items);
}

/// Append a preview to caller-owned storage. On error, the output may be partial.
/// Literal strings and files containing heredocs retain their source whitespace.
pub fn append(
    allocator: Allocator,
    output: *std.ArrayList(u8),
    contents: []const u8,
    options: Options,
) Allocator.Error!void {
    var widths: std.ArrayList(usize) = .empty;
    defer widths.deinit(allocator);
    var quote: ?u8 = null;
    var first_line = true;
    // Heredoc bodies can contain arbitrary text. Keep their whitespace until
    // a shell parser can identify the delimiters and separate code from literals.
    const preserve_whitespace = options.preserve_whitespace or
        mem.indexOf(u8, contents, "<<") != null;
    var lines = mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 and lines.peek() == null) break;
        if (first_line and options.inline_first) {
            try output.appendSlice(allocator, line);
        } else if (preserve_whitespace or quote != null) {
            try output.appendNTimes(allocator, ' ', options.spaces_count);
            try output.appendSlice(allocator, line);
        } else {
            const text = mem.trimStart(u8, line, " \t");
            var width: usize = 0;
            for (line[0 .. line.len - text.len]) |byte| {
                width = if (byte == '\t') (width / 8 + 1) * 8 else width + 1;
            }
            if (text.len != 0) {
                // Each increase in source indentation becomes one level, even
                // when the source mixes alignment, spaces, and tabs.
                while (widths.items.len != 0 and widths.items[widths.items.len - 1] > width) {
                    _ = widths.pop();
                }
                if (width != 0 and (widths.items.len == 0 or
                    widths.items[widths.items.len - 1] < width))
                {
                    try widths.append(allocator, width);
                }
            }
            const levels = if (text.len == 0) 1 else widths.items.len + 1;
            try output.appendNTimes(allocator, ' ', options.spaces_count * levels);
            try output.appendSlice(allocator, text);
        }
        scanQuotes(&quote, line);
        try output.append(allocator, '\n');
        first_line = false;
    }
}

fn scanQuotes(quote: *?u8, line: []const u8) void {
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        const byte = line[index];
        if (byte == '\\' and quote.* != '\'') {
            index += 1;
            continue;
        }
        if (quote.*) |delimiter| {
            if (byte == delimiter) quote.* = null;
        } else if (byte == '\'' or byte == '"') {
            quote.* = byte;
        } else if (byte == '#' and (index == 0 or std.ascii.isWhitespace(line[index - 1]))) {
            break;
        }
    }
}

test "write propagates destination errors" {
    var writer = std.Io.Writer.fixed(&.{});
    try std.testing.expectError(error.WriteFailed, write(std.testing.allocator, &writer, "content", .{}));
}
