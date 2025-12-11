const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const root = @import("root");

const log = std.log.scoped(.gila);

const gila = @import("gila");
const stdx = @import("stdx");

const common = @import("common.zig");

const Done = @This();

positional: struct {
    task_id: []const u8,
},

pub const help =
    \\Usage:
    \\
    \\    gila done [-h | --help] <task_id>
    \\
    \\Marks a task as done.
    \\
    \\Options:
    \\    -h, --help
    \\        Prints this help message.
    \\
    \\Examples:
    \\    gila done 20225125_120000_username
    \\
;

pub fn execute(self: Done, arena: *stdx.Arena) void {
    const allocator = arena.allocator();
    if (!self.verbose) {
        root.log_level = .warn;
    }

    const pwd: []const u8 = std.process.getCwdAlloc(allocator) catch |err| {
        log.err("Failed to get current directory: {s}", .{@errorName(err)});
        return;
    };
    const gila_dir_name = common.searchForGilaDir(pwd) orelse return;

    const task_id: gila.TaskId = .fromString(self.positional.task_id) catch |err| {
        log.err("Failed to parse task_id: {s}", .{@errorName(err)});
        return;
    };
}
