const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("stdx");
const assert = std.debug.assert;

pub const logo = @embedFile("ascii.txt");
pub const dir_name = ".gila";

const log = std.log.scoped(.gila);

pub const Status = enum(u8) {
    todo,
    in_progress,
    done,
    cancelled,
    waiting,

    pub const folder_names: []const []const u8 = blk: {
        var names: []const []const u8 = &.{};
        for (std.meta.fields(Status)) |field| {
            names = names ++ &[_][]const u8{field.name};
        }
        break :blk names;
    };
};

pub const TaskId = struct {
    date_time: stdx.DateTimeUTC,
    user_name: []const u8,

    pub fn new(gpa: std.mem.Allocator) std.process.GetEnvVarOwnedError!TaskId {
        var result: TaskId = undefined;
        result.date_time = stdx.DateTimeUTC.now();
        const user_env = if (builtin.os.tag == .windows) "USERNAME" else "USER";
        result.user_name = try std.process.getEnvVarOwned(gpa, user_env);
        return result;
    }

    pub fn fromString(str: []const u8) error{InvalidTaskId}!TaskId {
        var result: TaskId = undefined;
        // @NOTE string for taskId must start with YYYYMMDD_HHMMSS_ followed by username
        if (str.len < 15) {
            log.err("Invalid task_id `{s}` a task is of the form YYYYMMDD_HHMMSS_username", .{str});
            return error.InvalidTaskId;
        }
        result.date_time = stdx.DateTimeUTC.fromString(str[0..15], .YYYYMMDD_HHMMSS) catch |err| {
            log.err("Failed to parse date_time `{s}` from task_id `{s}`: {s}", .{ str[0..15], str, @errorName(err) });
            return error.InvalidTaskId;
        };
        if (str[15] != '_') {
            log.err("Invalid task_id `{s}` a task is of the form YYYYMMDD_HHMMSS_username", .{str});
            return error.InvalidTaskId;
        }
        result.user_name = str[16..];
        return result;
    }

    pub fn isValidFormat(str: []const u8) bool {
        if (str.len < 15) return false;
        if (str[15] != '_') return false;
        _ = stdx.DateTimeUTC.fromString(str[0..15], .YYYYMMDD_HHMMSS) catch return false;
        return true;
    }

    pub fn format(self: TaskId, writer: *std.Io.Writer) !void {
        try writer.print("{d}_{d}_{s}", .{ self.date_time.dateAsNumber(), self.date_time.timeAsNumber(), self.user_name });
    }
};

pub const Priority = enum {
    low,
    medium,
    high,
    urgent,
};

pub const description_header_template =
    seperator ++
    \\
    \\title: {s}
    \\status: {s}
    \\priority: {s}
    \\priority_value: {d}
    \\owner: {s}
    \\created: {f}
    \\
    ;

pub const description_compeleted_template =
    \\completed: {s}
;

pub const description_waiting_on_template =
    \\waiting_on:
;

pub const description_tags_template =
    \\tags: 
;

pub const seperator =
    \\---
;

pub const description_body_template =
    \\{s}
    \\
;
