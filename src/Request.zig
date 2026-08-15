//! Persisted HTTP client used for AUR RPC and snapshot downloads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.request);

const Request = @This();

pub const Error = Allocator.Error || std.http.Client.FetchError;

client: std.http.Client,
allocator: Allocator,

/// Wrap a new `std.http.Client`. Reuse one instance across requests.
pub fn init(allocator: Allocator, io: Io) Request {
    return .{
        .client = .{
            .allocator = allocator,
            .io = io,
        },
        .allocator = allocator,
    };
}

/// Tear down the HTTP client.
pub fn deinit(self: *Request) void {
    self.client.deinit();
    self.* = undefined;
}

/// GET `url` and return the response body. The caller owns the slice and
/// must free it with `self.allocator`.
pub fn getRequest(self: *Request, url: []const u8) Error![]u8 {
    var body: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer body.deinit();

    log.debug("GET {s}", .{url});
    _ = try self.client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &body.writer,
    });

    return try body.toOwnedSlice();
}
