const std = @import("std");
const mem = std.mem;

pub const Action = enum {
    Unset,
    Search,
    InstallOrUpgrade, // Both actions take the same codepath
    PrintVersion,
    PrintHelp,
};

pub const Args = struct {
    const Self = @This();

    allocator: mem.Allocator,
    pkgs: std.ArrayList([]const u8),
    action: Action,

    pub fn init(allocator: mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .pkgs = std.ArrayList([]const u8).init(allocator),
            .action = .Unset,
        };
    }

    pub fn parse(self: *Self) !void {
        var args_iter = std.process.args();
        _ = (try args_iter.next(self.allocator)).?; // exe
        var action = (try args_iter.next(self.allocator)).?;
        if (mem.eql(u8, action, "-h") or mem.eql(u8, action, "--help")) {
            self.action = .PrintHelp;
            return;
        } else if (mem.eql(u8, action, "-v") or mem.eql(u8, action, "--version")) {
            self.action = .PrintVersion;
            return;
        } else if (mem.eql(u8, action, "-Ss")) {
            self.action = .Search;
            const search_name = try args_iter.next(self.allocator);
            if (search_name == null) {
                self.action = .PrintHelp;
                return;
            }
            try self.pkgs.append(search_name.?);
        } else if (mem.eql(u8, action, "-S")) {
            self.action = .InstallOrUpgrade;
            while (try args_iter.next(self.allocator)) |arg| {
                try self.pkgs.append(arg);
            }
        } else if (action.len == 0) {
            self.action = .InstallOrUpgrade;
        } else {
            self.action = .PrintHelp;
        }
    }
};
