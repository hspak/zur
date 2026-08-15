const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const Args = @This();

pkgs: std.ArrayList([]const u8),
allocator: Allocator,
action: Action,

pub const Action = enum {
    unset,
    search,
    install_or_upgrade, // Both actions take the same codepath
    print_version,
    print_help,
};

pub fn init(allocator: Allocator) Args {
    return .{
        .pkgs = .empty,
        .allocator = allocator,
        .action = .unset,
    };
}

pub fn deinit(self: *Args) void {
    self.pkgs.deinit(self.allocator);
}

pub fn parse(self: *Args, process_args: std.process.Args) !void {
    var args_iter = process_args.iterate();
    _ = args_iter.next(); // skip argv[0]
    const action = args_iter.next() orelse "";
    if (mem.eql(u8, action, "-h") or mem.eql(u8, action, "--help")) {
        self.action = .print_help;
        return;
    } else if (mem.eql(u8, action, "-v") or mem.eql(u8, action, "--version")) {
        self.action = .print_version;
        return;
    } else if (mem.eql(u8, action, "-Ss")) {
        self.action = .search;
        const search_name = args_iter.next();
        if (search_name == null) {
            self.action = .print_help;
            return;
        }
        try self.pkgs.append(self.allocator, search_name.?);
    } else if (mem.eql(u8, action, "-S")) {
        self.action = .install_or_upgrade;
        while (args_iter.next()) |arg| {
            try self.pkgs.append(self.allocator, arg);
        }
    } else if (action.len == 0) {
        self.action = .install_or_upgrade;
    } else {
        self.action = .print_help;
    }
}
