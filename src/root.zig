const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("stdx");
const assert = std.debug.assert;

pub const logo = @embedFile("ascii.txt");
pub const dir_name = ".gila";
pub const description_file_name = "description.md";
pub const comments_file_name = "comments.md";

pub const Status = union(enum(u8)) {
    todo,
    in_progress,
    done,
    cancelled,
    waiting: ?[]const TaskId,
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

    pub fn fromString(str: []const u8) TaskId {
        var result: TaskId = undefined;
        // @NOTE string for taskId must start with YYYYMMDD_HHMMSS_ followed by username
        assert(str.len >= 15);
        result.date_time = .fromString(str[0..15], .YYYYMMDD_HHMMSS);
        assert(str[15] == '_');
        result.user_name = str[16..];
        return result;
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
    \\# {s}
    \\
    \\
++ seperator ++
    \\
    \\status: {s}
    \\priority: {s}, {d}
    \\owner: {s}
    \\created: {f}
    \\
;

pub const description_compeleted_template =
    \\completed: {s}
;

pub const description_tags_template =
    \\tags: 
;

pub const seperator =
    \\------
;

pub const description_body_template =
    \\
    \\# Description
    \\
    \\{s}
    \\
;
