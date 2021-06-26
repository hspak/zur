const std = @import("std");
const fs = std.fs;

// setting to prevent curl.curl_* stutter
usingnamespace @cImport(@cInclude("curl/curl.h"));

pub fn init() !void {
    // global curl init, or fail
    if (curl_global_init(CURL_GLOBAL_ALL) != CURLE_OK) {
        return error.CURLGlobalInitFailed;
    }
}

pub fn deinit() void {
    curl_global_cleanup();
}

pub fn get(allocator: *std.mem.Allocator, uri: [*:0]const u8) !std.ArrayList(u8) {
    const handle = curl_easy_init() orelse return error.CURLHandleInitFailed;
    defer curl_easy_cleanup(handle);

    var resp_buffer = std.ArrayList(u8).init(allocator);

    try wrap(curl_easy_setopt(handle, CURLOPT_URL, uri));
    try wrap(curl_easy_setopt(handle, CURLOPT_ACCEPT_ENCODING, ""));
    try wrap(curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, writeRespCallback));
    try wrap(curl_easy_setopt(handle, CURLOPT_WRITEDATA, &resp_buffer));
    try wrap(curl_easy_perform(handle));

    return resp_buffer;
}

fn writeRespCallback(data: *c_void, size: c_uint, count: c_uint, user_data: *c_void) callconv(.C) c_uint {
    var buff = @intToPtr(*std.ArrayList(u8), @ptrToInt(user_data));
    var typed_data = @intToPtr([*]u8, @ptrToInt(data));
    buff.appendSlice(typed_data[0 .. count * size]) catch {
        // TODO: some real error handling
        std.debug.print("oh no\n", .{});
        return 0;
    };
    return count * size;
}

fn wrap(result: anytype) !void {
    switch (result) {
        CURLE_OK => return,
        else => {
            std.debug.print("curl error: {d}\n", .{result});
            // TODO: some real error handling
            @panic("curl did not respond with CURLE_OK");
        },
    }
}
