const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("stdx");
const assert = std.debug.assert;

pub const logo = @embedFile("ascii.txt");
pub const dir_name = ".gila";
pub const Task = @import("task.zig");
pub const id = @import("id.zig");

const log = std.log.scoped(.gila);

pub const Status = enum(u8) {
    todo,
    started,
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

pub const Priority = enum(u8) {
    low = 0,
    medium = 1,
    high = 2,
    urgent = 3,
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
    \\
;

pub const description_tags_template =
    \\tags: 
    \\
;

pub const seperator =
    \\---
;

pub const description_body_template =
    \\{s}
    \\
;

test {
    _ = std.testing.refAllDecls(@This());
}
