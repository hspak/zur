const std = @import("std");
const Allocator = @import("std").mem.Allocator;

pub const Request = struct {
    client: std.http.Client,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !*Request {
        var new = try allocator.create(Request);
        new.client = std.http.Client{ .allocator = allocator };
        new.allocator = allocator;
        return new;
    }

    pub fn deinit(self: *Request) void {
        self.allocator.destroy(self);
    }

    pub fn request(self: *Request, method: std.http.Method, url: std.Uri) ![]u8 {
        var header_buffer: [4096 * 2]u8 = undefined; // TODO: no idea what happens when this overflows
        var req = try self.client.open(method, url, .{ .server_header_buffer = &header_buffer });
        defer req.deinit();
        try req.send();
        try req.wait();
        const body = req.reader().readAllAlloc(self.allocator, 10000000) catch unreachable;
        errdefer self.allocator.free(body);
        return body;
    }
};
