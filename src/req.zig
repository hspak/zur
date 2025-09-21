const std = @import("std");
const Allocator = @import("std").mem.Allocator;

pub const Request = struct {
    client: std.http.Client,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !*Request {
        var new = try allocator.create(Request);
        new.client = .{ .allocator = allocator };
        new.allocator = allocator;
        return new;
    }

    pub fn deinit(self: *Request) void {
        self.client.deinit();
        self.allocator.destroy(self);
    }

    pub fn getRequest(self: *Request, url: []const u8) ![]u8 {
        var body: std.Io.Writer.Allocating = .init(self.allocator);
        defer body.deinit();

        _ = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &body.writer,
        });

        return body.toOwnedSlice();
    }
};
