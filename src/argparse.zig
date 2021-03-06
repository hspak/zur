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
        //var args_iter = std.process.args();
        var args_iter = try std.process.argsWithAllocator(self.allocator);
        defer args_iter.deinit();
        //_ = (try args_iter.next()).?; // exe
        _ = args_iter.next().?;
        var action = args_iter.next() orelse "";
        if (mem.eql(u8, action, "-h") or mem.eql(u8, action, "--help")) {
            self.action = .PrintHelp;
            return;
        } else if (mem.eql(u8, action, "-v") or mem.eql(u8, action, "--version")) {
            self.action = .PrintVersion;
            return;
        } else if (mem.eql(u8, action, "-Ss")) {
            self.action = .Search;
            const search_name = args_iter.next();
            if (search_name == null) {
                self.action = .PrintHelp;
                return;
            }
            try self.pkgs.append(search_name.?);
        } else if (mem.eql(u8, action, "-S")) {
            self.action = .InstallOrUpgrade;
            while (args_iter.next()) |arg| {
                try self.pkgs.append(arg);
            }
        } else if (action.len == 0) {
            self.action = .InstallOrUpgrade;
        } else {
            self.action = .PrintHelp;
        }
    }
};
