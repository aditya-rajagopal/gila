const std = @import("std");
const assert = std.debug.assert;

const gila = @import("root.zig");
const stdx = @import("stdx");

const log = std.log.scoped(.gila);

const Task = @This();

title: Buffer,
status: Buffer,
priority: Buffer,
priority_value: Buffer,
owner: Buffer,
created: Buffer,
completed: ?Buffer,
tags: ?[]Buffer,
description: Buffer,

pub const Buffer = struct {
    data: []u8,
    capacity: usize,
};

pub fn parse(
    self: *Task,
    gpa: std.mem.Allocator,
    noalias buffer: []u8,
    noalias error_out: *?[]const u8,
) error{Invalid}!void {
    if (buffer.len < 4) {
        error_out.* = "Task description file has insufficient information";
        return error.Invalid;
    }
    if (!std.mem.eql(u8, buffer[0 .. gila.seperator.len + 1], gila.seperator ++ "\n")) {
        error_out.* = "Task description file does not start with `" ++ gila.seperator ++ "\n`";
        return error.Invalid;
    }
    const header_end = std.mem.find(u8, buffer[gila.seperator.len + 1 ..], gila.seperator) orelse {
        error_out.* = "Task description file does not contain header end separator `" ++ gila.seperator ++ "`";
        return error.Invalid;
    };
    const header: []u8 = buffer[gila.seperator.len + 1 ..][0..header_end];

    const fields = std.meta.fields(Task);
    inline for (fields[0 .. fields.len - 1]) |field| {
        const line_prefix = field.name ++ ": ";
        const info = @typeInfo(field.type);
        const field_line_start: ?usize = std.mem.find(u8, header, line_prefix) orelse blk: {
            if (info == .optional) {
                break :blk null;
            }
            error_out.* = "Failed to find `" ++ line_prefix ++ "` in header";
            return error.Invalid;
        };
        if (field_line_start) |line_start| {
            const line_end = std.mem.findScalar(u8, header[line_start + line_prefix.len ..], '\n') orelse {
                error_out.* = "Failed to find end of line for field '" ++ field.name ++ "' in header";
                return error.Invalid;
            };

            const base_type = if (info == .optional) info.optional.child else field.type;
            const base_info = @typeInfo(base_type);
            switch (base_info) {
                .pointer => |p| {
                    comptime assert(p.size == .slice);
                    var num_elements: usize = 0;
                    var next_line = line_start + line_prefix.len + line_end + 1;
                    while (std.mem.findScalar(u8, header[next_line..], '\n')) |end| {
                        if (end < 2) {
                            error_out.* = "Invalid tag start";
                            return error.Invalid;
                        }
                        if (std.mem.eql(u8, header[next_line..][0..2], "- ")) {
                            num_elements += 1;
                            next_line += end + 1;
                        } else {
                            break;
                        }
                    }
                    if (num_elements == 0) {
                        error_out.* = "Failed to find any elements in field '" ++ field.name ++ "' in header";
                        return error.Invalid;
                    }
                    const elements = gpa.alloc(Buffer, num_elements) catch {
                        error_out.* = "Failed to allocate buffer for field '" ++ field.name ++ "' in header";
                        return error.Invalid;
                    };
                    next_line = line_start + line_prefix.len + line_end + 1;
                    for (0..num_elements) |index| {
                        const end = std.mem.findScalar(u8, header[next_line..], '\n').?;
                        elements[index] = Buffer{
                            .data = header[next_line..][2..end],
                            .capacity = end - 2,
                        };
                        next_line += end + 1;
                    }
                    @field(self, field.name) = elements;
                },
                else => {
                    const line = header[line_start + line_prefix.len ..][0..line_end];
                    @field(self, field.name) = Buffer{
                        .data = line,
                        .capacity = line.len,
                    };
                },
            }
        } else {
            if (info == .optional) {
                @field(self, field.name) = null;
                log.debug("Field '" ++ field.name ++ "' is optional and was not found in the header", .{});
            }
        }
    }
    const description_start = header_end + 2 * gila.seperator.len + 2;
    self.description = Buffer{
        .data = buffer[description_start..],
        .capacity = buffer.len - description_start,
    };
}

pub fn format(self: *const Task, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("{s}", .{gila.seperator});
    const fields = std.meta.fields(Task);
    inline for (fields[0 .. fields.len - 1]) |field| {
        const line_prefix = field.name ++ ": ";
        const info = @typeInfo(field.type);
        if (info == .optional) {
            if (@field(self, field.name)) |field_buffer| {
                try writer.print("\n{s}", .{line_prefix});
                try write(info.optional.child, writer, field_buffer);
            }
        } else {
            try writer.print("\n{s}", .{line_prefix});
            try write(field.type, writer, @field(self, field.name));
        }
    }
    try writer.print("\n{s}\n", .{gila.seperator});
    try writer.print("{s}", .{self.description.data});
}

fn write(comptime T: type, writer: *std.Io.Writer, data: T) !void {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            comptime assert(p.size == .slice);
            for (data) |item| {
                try writer.print("\n- {s}", .{item.data});
            }
        },
        .@"struct" => try writer.print("{s}", .{data.data}),
        else => @compileError("Not supported"),
    }
}

pub const FindResult = struct {
    file: ?std.fs.File,
    status: gila.Status,
};
const FindError = error{
    FailedToOpenGilaDirectory,
    TaskNotFound,
} || std.fs.File.OpenError;
pub fn find(gpa: std.mem.Allocator, task_name: []const u8, gila_dir: std.fs.Dir) FindError!FindResult {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writer.print("{s}.md", .{task_name}) catch unreachable;
    const task_file_name = writer.buffered();

    const fixed_buffer: []u8 = gpa.alloc(u8, std.fs.max_path_bytes) catch |err| {
        log.err("Failed to allocate path buffer: {s}", .{@errorName(err)});
        return error.FailedToOpenGilaDirectory;
    };
    defer gpa.free(fixed_buffer);
    var path_arena = std.heap.FixedBufferAllocator.init(fixed_buffer);

    var result: FindResult = .{ .file = null, .status = .todo };
    inline for (std.meta.fields(gila.Status)) |field| {
        path_arena.reset();
        if (result.file == null) {
            const name = std.fs.path.join(path_arena.allocator(), &.{ field.name, task_name, task_file_name }) catch |err| {
                log.err("Unexpected error when constructing path to task: {s}", .{@errorName(err)});
                return error.FailedToOpenGilaDirectory;
            };
            result.file = gila_dir.openFile(name, .{ .mode = .read_only }) catch |err| switch (err) {
                error.FileNotFound => blk: {
                    log.debug("Task {s} does not exist in {s} directory", .{ task_name, name });
                    break :blk null;
                },
                else => |e| {
                    log.err("Failed to open task {s}: {s}", .{ task_name, @errorName(e) });
                    return e;
                },
            };
            result.status = comptime std.meta.stringToEnum(gila.Status, field.name).?;
            if (result.file) |_| {
                log.debug("Found task {s} at {s}", .{ task_name, name });
            }
        }
    }

    return result;
}

test "Task.parse" {
    const buffer =
        \\---
        \\title: test
        \\status: todo
        \\priority: medium
        \\priority_value: 50
        \\owner: adiraj
        \\created: 2025-12-13T08:42:53Z
        \\completed: 2025-12-13T08:43:53Z
        \\tags: 
        \\- a
        \\- b
        \\- c
        \\---
        \\
        \\test description
        \\
    ;
    const data = try std.testing.allocator.dupe(u8, buffer);
    defer std.testing.allocator.free(data);
    var task: Task = undefined;
    var error_out: ?[]const u8 = null;
    try task.parse(std.testing.allocator, data, &error_out);
    if (task.tags) |tags| {
        try std.testing.expectEqual(@as(usize, 3), tags.len);
        try std.testing.expectEqualStrings("a", tags[0].data);
        try std.testing.expectEqualStrings("b", tags[1].data);
        try std.testing.expectEqualStrings("c", tags[2].data);
    }
    try std.testing.expectEqualStrings("test", task.title.data);
    try std.testing.expectEqualStrings("todo", task.status.data);
    try std.testing.expectEqualStrings("medium", task.priority.data);
    try std.testing.expectEqualStrings("50", task.priority_value.data);
    try std.testing.expectEqualStrings("adiraj", task.owner.data);
    try std.testing.expectEqualStrings("2025-12-13T08:42:53Z", task.created.data);
    try std.testing.expectEqualStrings("2025-12-13T08:43:53Z", task.completed.?.data);
    try std.testing.expectEqualStrings("\ntest description\n", task.description.data);

    const output = try std.testing.allocator.alloc(u8, buffer.len);
    defer std.testing.allocator.free(output);

    var writer = std.Io.Writer.fixed(output);
    try writer.print("{f}", .{task});

    try std.testing.expectEqual(data.len, writer.buffered().len);
    try std.testing.expectEqualStrings(data, writer.buffered());

    if (task.tags) |tags| {
        std.testing.allocator.free(tags);
    }
}
