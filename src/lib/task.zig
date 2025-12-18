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
        error_out.* = "Task description file does not start with `" ++ gila.seperator ++ "`";
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

/// Returns the folder status of the task. The slices in task point to a buffer allocated on the arena.
/// It is expected that the arena lifetime is atleast as long as you want the Task to exist.
pub fn read(self: *Task, arena: *stdx.Arena, task_name: []const u8, gila_dir: std.fs.Dir) ?gila.Status {
    if (!gila.id.isValid(task_name)) {
        log.err("Invalid task_id `{s}` a task is of the form word_word_ccc", .{task_name});
        return null;
    }
    var file, const status = gila.Task.find(arena.allocator(), task_name, gila_dir) orelse return null;
    defer file.close();

    const buffer = read_all: {
        const size = file.getEndPos() catch |err| {
            log.err("Failed to get file size: {s}", .{@errorName(err)});
            return null;
        };
        log.debug("File size: {any}", .{size});

        const buffer = arena.pushArray(u8, size);

        file.seekTo(0) catch |err| {
            log.err("Failed to seek to start of file: {s}", .{@errorName(err)});
            return null;
        };
        const read_size = file.preadAll(buffer, 0) catch |err| {
            log.err("Failed to read file: {s}", .{@errorName(err)});
            return null;
        };
        assert(read_size == size);
        break :read_all buffer;
    };
    log.info("Read description file contents: {d} bytes", .{buffer.len});

    var error_out: ?[]const u8 = null;
    self.parse(arena.allocator(), buffer, &error_out) catch {
        log.err("Failed to parse task description file {s}: {s}", .{ task_name, error_out.? });
        return null;
    };

    if (!std.mem.eql(u8, @tagName(status), self.status.data)) {
        log.warn(
            "Task '{s}' was found in the '{s}' folder but was marked as '{s}' in the description. The description file wins",
            .{ task_name, @tagName(status), self.status.data },
        );
    }

    return status;
}

pub fn find(gpa: std.mem.Allocator, task_name: []const u8, gila_dir: std.fs.Dir) ?struct { std.fs.File, gila.Status } {
    var buffer: [128]u8 = undefined;
    const task_file_name = std.fmt.bufPrint(&buffer, "{s}.md", .{task_name}) catch unreachable;

    const fixed_buffer: []u8 = gpa.alloc(u8, std.fs.max_path_bytes) catch |err| {
        log.err("Failed to allocate path buffer: {s}", .{@errorName(err)});
        return null;
    };
    defer gpa.free(fixed_buffer);
    var path_arena = std.heap.FixedBufferAllocator.init(fixed_buffer);

    inline for (std.meta.fields(gila.Status)) |field| {
        path_arena.reset();
        result: {
            const name = std.fs.path.join(path_arena.allocator(), &.{ field.name, task_name, task_file_name }) catch |err| {
                log.err("Unexpected error when constructing path to task: {s}", .{@errorName(err)});
                return null;
            };

            const file = gila_dir.openFile(name, .{ .mode = .read_only }) catch |err| switch (err) {
                error.FileNotFound => {
                    log.debug("Task {s} does not exist in {s} directory", .{ task_name, name });
                    break :result;
                },
                else => |e| {
                    log.err("Failed to open task {s}: {s}", .{ task_name, @errorName(e) });
                    return null;
                },
            };
            const status = comptime std.meta.stringToEnum(gila.Status, field.name).?;
            log.debug("Found task {s} at {s}", .{ task_name, name });
            return .{ file, status };
        }
    }

    log.err("Task {s} does not exist in gila directory", .{task_name});
    return null;
}

pub fn transition(self: *Task, gpa: std.mem.Allocator, to: gila.Status, error_out: *?[]const u8) error{Invalid}!void {
    const status = std.meta.stringToEnum(gila.Status, self.status.data) orelse {
        error_out.* = "Invalid status";
        return error.Invalid;
    };
    switch (to) {
        .todo => {
            switch (status) {
                .todo => {
                    if (self.completed != null) {
                        log.info("Task '{s}' is in todo state with a completed date and time. Removing it", .{self.title.data});
                        self.completed = null;
                    }
                },
                .done => {
                    // NOTE: todo and done have the same length so this is safe
                    const todo_text = "todo";
                    @memcpy(self.status.data[0..todo_text.len], todo_text);
                    self.status.data = self.status.data[0..todo_text.len];
                    self.completed = null;
                },
                else => @panic("Not implemented"),
            }
        },
        .done => {
            switch (status) {
                .todo => {
                    const done_text = "done";
                    @memcpy(self.status.data[0..done_text.len], done_text);
                    self.status.data = self.status.data[0..done_text.len];
                },
                .done => {},
                else => @panic("Not implemented"),
            }
            if (self.completed) |*completed| cont: {
                _ = stdx.DateTimeUTC.fromString(completed.data, .@"YYYY-MM-DDTHH:MM:SSZ") catch |err| {
                    log.err("Failed to parse completed date and time for Task '{s}': {s}. Redoing it", .{ self.title.data, @errorName(err) });
                    break :cont;
                };
                return;
            }

            var completed: Buffer = self.completed orelse .{ .data = undefined, .capacity = 0 };
            if (completed.capacity < @tagName(.@"YYYY-MM-DDTHH:MM:SSZ").len) {
                completed.data = gpa.alloc(u8, @tagName(.@"YYYY-MM-DDTHH:MM:SSZ").len) catch {
                    error_out.* = "Failed to allocate memory for completed date and time";
                    return error.Invalid;
                };
                completed.capacity = @tagName(.@"YYYY-MM-DDTHH:MM:SSZ").len;
            }
            completed.data = std.fmt.bufPrint(completed.data, "{f}", .{stdx.DateTimeUTC.now().as(.@"YYYY-MM-DDTHH:MM:SSZ")}) catch {
                error_out.* = "Failed to format completed date and time";
                return error.Invalid;
            };
            self.completed = completed;
        },
        else => @panic("Not implemented"),
    }
}

pub fn validate(self: *Task, error_out: *?[]const u8) error{Invalid}!void {
    if (self.title.data.len == 0) {
        error_out.* = "Task title cannot be empty";
        return error.Invalid;
    }

    if (self.status.data.len == 0) {
        error_out.* = "Task status cannot be empty";
        return error.Invalid;
    }

    if (self.priority.data.len == 0) {
        error_out.* = "Task priority cannot be empty";
        return error.Invalid;
    }

    if (self.priority_value.data.len == 0) {
        error_out.* = "Task priority_value cannot be empty";
        return error.Invalid;
    }
    _ = std.fmt.parseInt(u8, self.priority_value.data, 10) catch |err| switch (err) {
        error.Overflow => {
            error_out.* = "Task priority_value cannot be larger than 255";
            return error.Invalid;
        },
        else => {
            error_out.* = "Failed to parse Task priority_value as an integer";
            return error.Invalid;
        },
    };
    if (self.owner.data.len == 0) {
        error_out.* = "Task owner cannot be empty";
        return error.Invalid;
    }

    if (self.created.data.len == 0) {
        error_out.* = "Task created cannot be empty";
        return error.Invalid;
    }
    _ = stdx.DateTimeUTC.fromString(self.created.data, .@"YYYY-MM-DDTHH:MM:SSZ") catch {
        error_out.* = "Failed to parse Task created date and time in the format YYYY-MM-DDTHH:MM:SSZ";
        return error.Invalid;
    };

    if (self.completed) |*completed| {
        _ = stdx.DateTimeUTC.fromString(completed.data, .@"YYYY-MM-DDTHH:MM:SSZ") catch {
            error_out.* = "Failed to parse completed date and time in the format YYYY-MM-DDTHH:MM:SSZ";
            return error.Invalid;
        };
    }
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

    try task.validate(&error_out);

    if (task.tags) |tags| {
        std.testing.allocator.free(tags);
    }
}
