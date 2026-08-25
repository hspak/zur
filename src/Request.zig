//! Persisted HTTP client used for AUR RPC and snapshot downloads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.request);

const Request = @This();

const ErrorSet = Allocator.Error || std.http.Client.FetchError;
pub const Error = ErrorSet;

client: std.http.Client,
allocator: Allocator,

const max_retries = 2;
const retry_delays_ms = [max_retries]i64{ 100, 500 };

const ClientFetcher = struct {
    fn fetch(
        _: ClientFetcher,
        client: *std.http.Client,
        options: std.http.Client.FetchOptions,
    ) std.http.Client.FetchError!std.http.Client.FetchResult {
        return client.fetch(options);
    }
};

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

fn isRetryable(err: Error) bool {
    return switch (err) {
        // A server may close an idle keep-alive connection between requests.
        error.HttpConnectionClosing,
        error.HttpRequestTruncated,
        error.HttpChunkTruncated,
        // GET is idempotent, so an interrupted transport can be attempted again.
        error.ReadFailed,
        error.WriteFailed,
        error.ConnectionResetByPeer,
        error.ConnectionRefused,
        error.NetworkDown,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.Timeout,
        error.NameServerFailure,
        error.NoAddressReturned,
        => true,
        else => false,
    };
}

// Drop all pooled connections after a transport failure. `Client.fetch`
// releases its request before returning, so there are no active connections.
fn resetClient(self: *Request) void {
    const io = self.client.io;
    self.client.deinit();
    self.client = .{
        .allocator = self.allocator,
        .io = io,
    };
}

/// GET `url` and return the response body. The caller owns the slice and
/// must free it with `self.allocator`.
pub fn get(self: *Request, url: []const u8) Error![]u8 {
    return self.getWithFetcher(url, ClientFetcher{});
}

fn fetchBody(self: *Request, url: []const u8, fetcher: anytype) Error![]u8 {
    var body: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer body.deinit();

    log.debug("GET {s}", .{url});
    _ = try fetcher.fetch(&self.client, .{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &body.writer,
    });
    return try body.toOwnedSlice();
}

fn getWithFetcher(self: *Request, url: []const u8, fetcher: anytype) Error![]u8 {
    var retries: usize = 0;
    while (true) {
        return self.fetchBody(url, fetcher) catch |err| {
            if (!isRetryable(err) or retries == max_retries) return err;

            retries += 1;
            log.debug("GET {s} failed with {}; retrying ({d}/{d})", .{
                url,
                err,
                retries,
                max_retries,
            });
            self.resetClient();
            try Io.sleep(
                self.client.io,
                .fromMilliseconds(retry_delays_ms[retries - 1]),
                .awake,
            );
            continue;
        };
    }
}

const FakeFetcher = struct {
    calls: usize = 0,
    failures_remaining: usize = 0,
    failure: std.http.Client.FetchError = error.HttpConnectionClosing,
    failed_body: []const u8 = "",
    response_body: []const u8 = "snapshot",

    fn fetch(
        self: *FakeFetcher,
        _: *std.http.Client,
        options: std.http.Client.FetchOptions,
    ) std.http.Client.FetchError!std.http.Client.FetchResult {
        self.calls += 1;
        if (self.failures_remaining > 0) {
            self.failures_remaining -= 1;
            try options.response_writer.?.writeAll(self.failed_body);
            return self.failure;
        }
        try options.response_writer.?.writeAll(self.response_body);
        return .{ .status = .ok };
    }
};

test "get retries a closed keep-alive connection and discards the partial body" {
    var request = Request.init(std.testing.allocator, std.testing.io);
    defer request.deinit();
    var fetcher: FakeFetcher = .{
        .failures_remaining = 1,
        .failure = error.HttpConnectionClosing,
        .failed_body = "partial",
        .response_body = "complete",
    };

    const body = try request.getWithFetcher("https://example.test/snapshot", &fetcher);
    defer std.testing.allocator.free(body);

    try std.testing.expectEqual(@as(usize, 2), fetcher.calls);
    try std.testing.expectEqualStrings("complete", body);
}

test "get stops after the built-in retry limit" {
    var request = Request.init(std.testing.allocator, std.testing.io);
    defer request.deinit();
    var fetcher: FakeFetcher = .{
        .failures_remaining = max_retries + 1,
        .failure = error.ConnectionResetByPeer,
    };

    try std.testing.expectError(
        error.ConnectionResetByPeer,
        request.getWithFetcher("https://example.test/snapshot", &fetcher),
    );
    try std.testing.expectEqual(@as(usize, max_retries + 1), fetcher.calls);
}

test "get does not retry permanent HTTP errors" {
    var request = Request.init(std.testing.allocator, std.testing.io);
    defer request.deinit();
    var fetcher: FakeFetcher = .{
        .failures_remaining = 1,
        .failure = error.HttpHeadersInvalid,
    };

    try std.testing.expectError(
        error.HttpHeadersInvalid,
        request.getWithFetcher("https://example.test/snapshot", &fetcher),
    );
    try std.testing.expectEqual(@as(usize, 1), fetcher.calls);
}
