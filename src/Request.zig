const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Request = @This();

client: std.http.Client,
allocator: Allocator,

pub fn init(allocator: Allocator, io: Io) Request {
    return .{
        .client = .{
            .allocator = allocator,
            .io = io,
        },
        .allocator = allocator,
    };
}

pub fn deinit(self: *Request) void {
    self.client.deinit();
    self.* = undefined;
}

pub fn getRequest(self: *Request, url: []const u8) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer body.deinit();

    _ = try self.client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &body.writer,
    });

    return try body.toOwnedSlice();
}
