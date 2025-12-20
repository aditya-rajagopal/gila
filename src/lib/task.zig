const std = @import("std");
const assert = std.debug.assert;

const gila = @import("root.zig");
const stdx = @import("stdx");

const log = std.log.scoped(.gila);

const Task = @This();

title: []const u8,
status: gila.Status,
priority_value: u8,
priority: gila.Priority,
owner: []const u8,
created: stdx.DateTimeUTC,
completed: ?stdx.DateTimeUTC,
waiting_on: ?[]const []const u8,
tags: ?[]const []const u8,
description: []const u8,

const default = Task{
    .title = undefined,
    .status = undefined,
    .priority = undefined,
    .priority_value = undefined,
    .owner = undefined,
    .created = undefined,
    .completed = null,
    .waiting_on = null,
    .tags = null,
    .description = undefined,
};

inline fn Error(diagnostics: *?Diagnostic, message: []const u8, line: usize, column_start: usize, column_end: usize) error{Invalid} {
    diagnostics.* = .{
        .line = line,
        .column_start = column_start,
        .column_end = column_end,
        .message = message,
    };
    return error.Invalid;
}

pub const Diagnostic = struct {
    line: usize,
    column_start: usize,
    column_end: usize,
    message: []const u8,
};

pub fn parse(
    self: *Task,
    reader: *std.Io.Reader,
    arena: *stdx.Arena,
    diagnostics: *?Diagnostic,
) error{Invalid}!void {
    // @TODO [[elliptical_ogre_78v]]
    self.* = default;
    const seperator = (reader.takeDelimiter('\n') catch return Error(diagnostics, "Insufficient data", 0, 0, 0)) orelse return Error(diagnostics, "Insufficient data", 0, 0, 0);
    if (!std.mem.eql(u8, seperator, gila.seperator)) return Error(diagnostics, "Task description file does not start with `" ++ gila.seperator ++ "`", 0, 0, 0);

    var line = reader.takeDelimiter('\n') catch return Error(diagnostics, "Insufficient data", 1, 0, 0);
    var line_number: usize = 0;

    const fields = @typeInfo(Task).@"struct".fields;
    // var task: Task = undefined;
    var finished_header = false;
    parsing_next_paramter: while (line) |l| {
        line_number += 1;
        if (std.mem.eql(u8, l, "---")) {
            finished_header = true;
            break;
        }
        inline for (fields) |field| {
            if (std.mem.startsWith(u8, l, field.name)) {
                var column: usize = field.name.len;
                while (column < l.len and (l[column] == ' ' or l[column] == '\t')) {
                    column += 1;
                }
                if (l[column] != ':') return Error(diagnostics, "Expected ':' after field name", line_number, column, column + 1);
                column += 1;
                while (column < l.len and (l[column] == ' ' or l[column] == '\t')) {
                    column += 1;
                }
                comptime var T: type = field.type;
                if (@typeInfo(field.type) == .optional) {
                    T = @typeInfo(field.type).optional.child;
                }
                // @TODO Better error messages
                const current_line_number = line_number;
                var diagnostic: ?Diagnostic = null;
                @field(self, field.name) = parseValue(T, arena, &line, &line_number, &column, reader, &diagnostic) catch return error.Invalid;
                if (line_number > current_line_number) {
                    continue :parsing_next_paramter;
                }
                line = reader.takeDelimiter('\n') catch return Error(diagnostics, "Insufficient data", line_number, 0, 0);
                continue :parsing_next_paramter;
            }
        }
    }
    if (!finished_header) return Error(diagnostics, "Failed to find end of header", line_number, 0, 0);
    self.description = reader.allocRemaining(arena.allocator(), @enumFromInt(arena.remainingCapacity())) catch return Error(diagnostics, "Failed to read description", line_number, 0, 0);
}

fn parseValue(
    comptime T: type,
    arena: *stdx.Arena,
    line: *?[]u8,
    line_number: *usize,
    column: *usize,
    reader: *std.Io.Reader,
    diagnostics: *?Diagnostic,
) error{Invalid}!T {
    const l = line.* orelse return Error(diagnostics, "Missing parameter value", line_number.*, column.*, 0);
    if (T == []const u8) {
        if (l[column.*..].len == 0) return Error(diagnostics, "Missing parameter value", line_number.*, column.*, l.len);
        return arena.pushString(l[column.*..]);
    }
    if (T == u8) {
        if (l[column.*..].len == 0) return Error(diagnostics, "Missing parameter value", line_number.*, column.*, l.len);
        return std.fmt.parseInt(u8, l[column.*..], 10) catch return Error(diagnostics, "Failed to parse parameter value as an integer", line_number.*, column.*, l.len);
    }
    if (T == stdx.DateTimeUTC) {
        if (l[column.*..].len == 0) return Error(diagnostics, "Missing parameter value", line_number.*, column.*, l.len);
        return stdx.DateTimeUTC.fromString(l[column.*..], .@"YYYY-MM-DDTHH:MM:SSZ") catch return Error(diagnostics, "Failed to parse parameter value as a YYYY-MM-DDTHH:MM:SSZ", line_number.*, column.*, l.len);
    }
    if (@typeInfo(T) == .@"enum") {
        if (l[column.*..].len == 0) return Error(diagnostics, "Missing parameter value", line_number.*, column.*, l.len);
        return std.meta.stringToEnum(T, l[column.*..]) orelse return Error(diagnostics, "Failed to parse parameter value as an enum of type " ++ @typeName(T), line_number.*, column.*, l.len);
    }
    if (T == []const []const u8) {
        const start = arena.current;
        if (l.len != column.*) return Error(diagnostics, "Unexpected data", line_number.*, column.*, l.len);
        line.* = reader.takeDelimiter('\n') catch return Error(diagnostics, "Insufficient data", line_number.*, column.*, column.*);
        var num_elements: usize = 0;
        column.* = 0;
        while (line.*) |nl| {
            line_number.* += 1;
            if (std.mem.startsWith(u8, nl, "- ")) {
                if (nl.len < 3) return Error(diagnostics, "Insufficient data", line_number.*, column.*, column.*);
                num_elements += 1;
                _ = arena.pushString(nl);
                line.* = reader.takeDelimiter('\n') catch return Error(diagnostics, "Buffer too small for line or read failed", line_number.*, column.*, column.*);
            } else {
                break;
            }
        }
        if (num_elements == 0) return Error(diagnostics, "Failed to find any elements in field for a list parameter in header", line_number.*, column.*, column.*);
        var lines = arena.memory[start..arena.current];
        const elements = arena.pushArray([]const u8, num_elements);
        for (0..num_elements) |index| {
            lines = lines[2..];
            const end = std.mem.indexOfScalar(u8, lines, '-') orelse lines.len;
            elements[index] = arena.pushString(lines[0..end]);
            lines = lines[end..];
        }
        return elements;
    }
}

pub fn format(self: *const Task, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("{s}\n", .{gila.seperator});
    const fields = std.meta.fields(Task);
    inline for (fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "description")) {
            continue;
        }
        const line_prefix = field.name ++ ": ";
        const info = @typeInfo(field.type);
        if (info == .optional) {
            if (@field(self, field.name)) |field_buffer| {
                try writer.print("{s}", .{line_prefix});
                try write(info.optional.child, writer, field_buffer);
            }
        } else {
            try writer.print("{s}", .{line_prefix});
            try write(field.type, writer, @field(self, field.name));
        }
    }
    try writer.print("{s}\n", .{gila.seperator});
    try writer.print("{s}", .{self.description});
}

fn write(comptime T: type, writer: *std.Io.Writer, data: T) !void {
    if (T == []const u8) {
        try writer.print("{s}\n", .{data});
    }
    if (T == u8) {
        try writer.print("{d}\n", .{data});
    }
    if (T == stdx.DateTimeUTC) {
        try writer.print("{f}\n", .{data.as(.@"YYYY-MM-DDTHH:MM:SSZ")});
    }
    if (@typeInfo(T) == .@"enum") {
        try writer.print("{s}\n", .{@tagName(data)});
    }
    if (T == []const []const u8) {
        for (data) |field| {
            try writer.writeByte('\n');
            try writer.writeAll("- ");
            try writer.writeAll(field);
        }
        try writer.writeByte('\n');
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

    var buffer: [4096]u8 = undefined;
    var reader = file.reader(&buffer);
    reader.interface.fillMore() catch {
        log.err("Failed to read task description file {s}", .{task_name});
        return null;
    };
    var diagnostic: ?Diagnostic = null;
    self.parse(&reader.interface, arena, &diagnostic) catch {
        log.err("Failed to parse task description file {s}: {s}", .{ task_name, diagnostic.?.message });
        return null;
    };

    if (status != self.status) {
        log.warn(
            "Task '{s}' was found in the '{s}' folder but was marked as '{s}' in the description. The description file wins",
            .{ task_name, @tagName(status), @tagName(self.status) },
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

pub fn transition(self: *Task, to: gila.Status) error{Invalid}!void {
    const status = self.status;
    switch (to) {
        .todo => {
            switch (status) {
                .todo => {
                    if (self.completed != null) {
                        log.info("Task '{s}' is in todo state with a completed date and time. Removing it", .{self.title});
                        self.completed = null;
                    }
                },
                .done => {
                    // NOTE: todo and done have the same length so this is safe
                    self.status = .todo;
                    self.completed = null;
                },
                else => @panic("Not implemented"),
            }
        },
        .done => {
            switch (status) {
                .todo => {
                    self.status = .done;
                },
                .done => {},
                else => @panic("Not implemented"),
            }
            if (self.completed) |_| {
                return;
            }
            self.completed = stdx.DateTimeUTC.now();
        },
        else => @panic("Not implemented"),
    }
}

pub fn validate(self: *Task, error_out: *?[]const u8) error{Invalid}!void {
    // @TODO [[weak_spark_74s]]
    if (self.title.len == 0) {
        error_out.* = "Task title cannot be empty";
        return error.Invalid;
    }

    if (self.owner.len == 0) {
        error_out.* = "Task owner cannot be empty";
        return error.Invalid;
    }
}

test "Task.parse" {
    const buffer =
        \\---
        \\title: test
        \\status: todo
        \\priority_value: 50
        \\priority: medium
        \\owner: adiraj
        \\created: 2025-12-13T08:42:53Z
        \\completed: 2025-12-13T08:43:53Z
        \\waiting_on: 
        \\- "[[word_word_ccc]]"
        \\- "[[test_another_15c]]"
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
    var diagnostic: ?Diagnostic = null;
    var reader = std.Io.Reader.fixed(data);
    var memory: [4096]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&memory);
    task.parse(&reader, &arena, &diagnostic) catch {
        return error.TestFailedToParse;
    };
    if (task.tags) |tags| {
        try std.testing.expectEqual(@as(usize, 3), tags.len);
        try std.testing.expectEqualStrings("a", tags[0]);
        try std.testing.expectEqualStrings("b", tags[1]);
        try std.testing.expectEqualStrings("c", tags[2]);
    } else {
        return error.TestExpectedTags;
    }
    if (task.waiting_on) |waiting_on| {
        try std.testing.expectEqual(@as(usize, 2), waiting_on.len);
        try std.testing.expectEqualStrings("\"[[word_word_ccc]]\"", waiting_on[0]);
        try std.testing.expectEqualStrings("\"[[test_another_15c]]\"", waiting_on[1]);
    } else return error.TestExpectedWaitingOn;

    try std.testing.expectEqualStrings("test", task.title);
    try std.testing.expectEqual(.todo, task.status);
    try std.testing.expectEqual(.medium, task.priority);
    try std.testing.expectEqual(50, task.priority_value);
    try std.testing.expectEqualStrings("adiraj", task.owner);
    try std.testing.expectEqual(stdx.DateTimeUTC.fromString("2025-12-13T08:42:53Z", .@"YYYY-MM-DDTHH:MM:SSZ") catch unreachable, task.created);
    try std.testing.expectEqual(stdx.DateTimeUTC.fromString("2025-12-13T08:43:53Z", .@"YYYY-MM-DDTHH:MM:SSZ") catch unreachable, task.completed.?);
    try std.testing.expectEqualStrings("\ntest description\n", task.description);

    const output = try std.testing.allocator.alloc(u8, buffer.len);
    defer std.testing.allocator.free(output);

    var writer = std.Io.Writer.fixed(output);
    try writer.print("{f}", .{task});

    try std.testing.expectEqual(data.len, writer.buffered().len);
    try std.testing.expectEqualStrings(data, writer.buffered());

    var error_out: ?[]const u8 = null;
    try task.validate(&error_out);
}
