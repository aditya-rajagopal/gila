const std = @import("std");
const assert = std.debug.assert;

const gila = @import("root.zig");
const stdx = @import("stdx");

const log = std.log.scoped(.gila);

const Task = @This();

id: []const u8,
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
extra_lines: ?[]const []const u8,

pub const default = Task{
    .id = &.{},
    .title = &.{},
    .status = undefined,
    .priority = undefined,
    .priority_value = 0,
    .owner = &.{},
    .created = .default,
    .completed = null,
    .waiting_on = null,
    .tags = null,
    .description = &.{},
    .extra_lines = null,
};

pub fn init(id: []const u8) error{Invalid}!Task {
    if (!gila.id.isValid(id)) {
        log.err("Invalid task_id `{s}` a task is of the form word_word_ccc", .{id});
        return error.Invalid;
    }
    var task = default;
    task.id = id;
    return task;
}

pub const Diagnostic = struct {
    line: usize,
    column_start: usize,
    column_end: usize,
    message: []const u8,
};

pub fn fromReader(
    self: *Task,
    reader: *std.Io.Reader,
    arena: *stdx.Arena,
    diagnostics: *?Diagnostic,
) error{Invalid}!void {
    const seperator = (reader.takeDelimiter('\n') catch return Error(diagnostics, "Insufficient data", 0, 0, 0)) orelse return Error(diagnostics, "Insufficient data", 0, 0, 0);
    if (!std.mem.eql(u8, seperator, gila.seperator)) return Error(diagnostics, "Task description file does not start with `" ++ gila.seperator ++ "`", 0, 0, 0);

    var line = reader.takeDelimiter('\n') catch return Error(diagnostics, "Insufficient data", 1, 0, 0);
    var line_number: usize = 0;

    var extra_lines: std.ArrayList([]const u8) = .empty;

    const fields = comptime blk: {
        var out: []const std.builtin.Type.StructField = &.{};
        for (@typeInfo(Task).@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, "extra_lines") or std.mem.eql(u8, field.name, "description") or std.mem.eql(u8, field.name, "id")) {
                continue;
            }
            out = out ++ &[_]std.builtin.Type.StructField{field};
        }
        break :blk out;
    };

    var counts = std.enums.EnumFieldStruct(std.meta.FieldEnum(Task), u32, 0){};

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
                @field(self, field.name) = parseValue(T, arena, &line, &line_number, &column, reader, &diagnostic) catch |err| switch (err) {
                    error.EmptyList => blk: {
                        if (T == []const u8) unreachable;
                        if (@typeInfo(field.type) == .optional) {
                            break :blk null;
                        } else {
                            return Error(diagnostics, "Failed to find any elements in field for a list parameter in header", line_number, column, column);
                        }
                    },
                    else => return error.Invalid,
                };
                @field(counts, field.name) += 1;
                if (line_number > current_line_number) {
                    continue :parsing_next_paramter;
                }
                line = reader.takeDelimiter('\n') catch return Error(diagnostics, "Insufficient data", line_number, 0, 0);
                continue :parsing_next_paramter;
            }
        }
        extra_lines.append(arena.allocator(), arena.pushString(l)) catch return Error(diagnostics, "Failed to append extra line: Out of memory", line_number, 0, 0);
        line = reader.takeDelimiter('\n') catch return Error(diagnostics, "Insufficient data", line_number, 0, 0);
    }
    if (extra_lines.items.len > 0) {
        self.extra_lines = extra_lines.toOwnedSlice(arena.allocator()) catch return Error(diagnostics, "Failed to allocate extra lines: Out of memory", line_number, 0, 0);
    }

    inline for (fields) |field| {
        switch (@field(counts, field.name)) {
            0 => if (@typeInfo(field.type) == .optional) {
                @field(self, field.name) = null;
            } else if (std.mem.eql(u8, field.name, "description")) {} else {
                return Error(diagnostics, "Parameter `" ++ field.name ++ "` is missing", 0, 0, 0);
            },
            1 => {},
            else => return Error(diagnostics, "Parameter `" ++ field.name ++ "` is not unique", 0, 0, 0),
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
) error{ Invalid, EmptyList }!T {
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
        const start = arena.currentPosition();
        if (l.len != column.*) return Error(diagnostics, "Unexpected data", line_number.*, column.*, l.len);
        line.* = reader.takeDelimiter('\n') catch return Error(diagnostics, "Insufficient data", line_number.*, column.*, column.*);
        var num_elements: usize = 0;
        column.* = 0;
        while (line.*) |nl| {
            line_number.* += 1;
            var i: usize = 0;
            while (nl[i] == ' ' or nl[i] == '\t') : (i += 1) {}
            if (std.mem.startsWith(u8, nl[i..], "- ")) {
                if (nl[i..].len < 3) return Error(diagnostics, "Insufficient data", line_number.*, column.*, column.*);
                num_elements += 1;
                _ = arena.pushString(nl[i + 2 ..]);
                const v = arena.push(u8);
                v.* = '\n';
                line.* = reader.takeDelimiter('\n') catch return Error(diagnostics, "Buffer too small for line or read failed", line_number.*, column.*, column.*);
            } else {
                break;
            }
        }
        if (num_elements == 0) return error.EmptyList; //return Error(diagnostics, "Failed to find any elements in field for a list parameter in header", line_number.*, column.*, column.*);
        var lines = arena.memory[start..arena.currentPosition()];
        const elements = arena.pushArray([]const u8, num_elements);
        for (0..num_elements) |index| {
            const end = std.mem.indexOfScalar(u8, lines, '\n') orelse lines.len;
            elements[index] = arena.pushString(lines[0..end]);
            lines = lines[end + 1 ..];
        }
        return elements;
    }
}

pub const FindAndReadResult = struct {
    task: Task,
    status: gila.Status,
};
/// Returns the folder status of the task. The slices in task point to a buffer allocated on the arena.
/// It is expected that the arena lifetime is atleast as long as you want the Task to exist.
pub fn findTaskAndRead(id: []const u8, io: std.Io, arena: *stdx.Arena, gila_dir: std.Io.Dir) error{Failed}!FindAndReadResult {
    var task = Task.init(id) catch {
        log.err("Invalid task_id `{s}` a task is of the form word_word_ccc", .{id});
        return error.Failed;
    };

    var result = getTaskFileById(io, task.id, arena, gila_dir) catch |err| switch (err) {
        error.TaskNotFound => {
            log.err("Task {s} does not exist in gila directory", .{task.id});
            return error.Failed;
        },
        else => |e| {
            log.err("Failed to open task {s}: {s}", .{ task.id, @errorName(e) });
            return error.Failed;
        },
    };
    defer result.fd.close(io);

    try task.fromFile(result.fd, io, arena);

    if (result.folder != task.status) {
        log.warn(
            "Task '{s}' was found in the '{s}' folder but was marked as '{s}' in the description. The description file wins",
            .{ task.id, @tagName(result.folder), @tagName(task.status) },
        );
    }

    return .{ .task = task, .status = result.folder };
}

pub fn fromFile(self: *Task, task_file: std.Io.File, io: std.Io, arena: *stdx.Arena) error{Failed}!void {
    var buffer: [4096]u8 = undefined;
    var reader = task_file.reader(io, &buffer);
    reader.interface.fillMore() catch {
        log.err("Failed to read task description file {s}", .{self.id});
        return error.Failed;
    };

    var diagnostic: ?Diagnostic = null;
    self.fromReader(&reader.interface, arena, &diagnostic) catch {
        log.err("Failed to parse task description file {s}: {s}", .{ self.id, diagnostic.?.message });
        return error.Failed;
    };
    log.info("Successfully parsed task {s}", .{self.id});
}

const FindError = error{TaskNotFound} || std.Io.File.OpenError;
pub const FindResult = struct {
    fd: std.Io.File,
    folder: gila.Status,
};
pub fn getTaskFileById(io: std.Io, id: []const u8, arena: *stdx.Arena, gila_dir: std.Io.Dir) FindError!FindResult {
    var buffer: [128]u8 = undefined;
    const task_file_name = std.fmt.bufPrint(&buffer, "{s}.md", .{id}) catch unreachable;

    const fixed_buffer: []u8 = arena.pushArray(u8, std.fs.max_path_bytes);
    defer arena.popArray(u8, fixed_buffer);
    var path_arena = std.heap.FixedBufferAllocator.init(fixed_buffer);
    const allocator = path_arena.allocator();

    inline for (std.meta.fields(gila.Status)) |field| {
        path_arena.reset();
        result: {
            const name = std.fs.path.join(allocator, &.{ field.name, id, task_file_name }) catch unreachable;

            const file = gila_dir.openFile(io, name, .{ .mode = .read_only }) catch |err| switch (err) {
                error.FileNotFound => {
                    log.debug("Task {s} does not exist in {s} directory", .{ id, name });
                    break :result;
                },
                else => |e| return e,
            };
            const status = comptime std.meta.stringToEnum(gila.Status, field.name).?;
            log.debug("Found task {s} at {s}", .{ id, name });
            return .{ .fd = file, .folder = status };
        }
    }

    log.err("Task {s} does not exist in gila directory", .{id});
    return error.TaskNotFound;
}

pub fn toTaskFile(self: *const Task, io: std.Io, make_new: bool, arena: *stdx.Arena, gila_dir: std.Io.Dir) error{Invalid}![]u8 {
    if (!gila.id.isValid(self.id)) {
        log.err("Invalid task_id `{s}` a task is of the form word_word_ccc", .{self.id});
        return error.Invalid;
    }
    var file_name_buffer: [32]u8 = undefined;
    const file_name_md = std.fmt.bufPrint(&file_name_buffer, "{s}.md", .{self.id}) catch unreachable;

    const path_description_file = std.fs.path.join(arena.allocator(), &.{ @tagName(self.status), self.id, file_name_md }) catch unreachable;

    var found_file: bool = true;
    const file = gila_dir.openFile(io, path_description_file, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => blk: {
            if (!make_new) {
                log.err("Task {s} does not exist in gila directory", .{self.id});
                return error.Invalid;
            }
            found_file = false;

            const task_dir_name = std.fs.path.join(arena.allocator(), &.{ @tagName(self.status), self.id }) catch unreachable;
            gila_dir.createDirPath(io, task_dir_name) catch |e| {
                log.err("Failed to create task directory {s}: {s}", .{ self.id, @errorName(e) });
                return error.Invalid;
            };
            log.info("Successfully created task directory {s}", .{task_dir_name});

            const description_file = gila_dir.createFile(io, path_description_file, .{}) catch |e| {
                log.err("Failed to create {s}.md file: {s}", .{ self.id, @errorName(e) });
                return error.Invalid;
            };
            log.info("Successfully created description file {s}", .{self.id});
            break :blk description_file;
        },
        else => |e| {
            log.err("Failed to open done file {s}: {s}", .{ path_description_file, @errorName(e) });
            return error.Invalid;
        },
    };
    defer file.close(io);

    if (found_file and make_new) {
        log.err("Task {s} already exists. If you want to create a new task you can wait for 1 second and try again.", .{self.id});
        return error.Invalid;
    }

    self.flushToFile(io, file, path_description_file) catch return error.Invalid;

    return path_description_file;
}

pub fn flushToFile(self: *const Task, io: std.Io, file: std.Io.File, file_path: []const u8) error{Invalid}!void {
    file.setLength(io, 0) catch |err| {
        log.err("Failed to set end position of done file {s}: {s}", .{ file_path, @errorName(err) });
        return error.Invalid;
    };

    var write_buffer: [4096]u8 align(16) = undefined;
    var file_writer = file.writer(io, &write_buffer);
    const writer = &file_writer.interface;

    writer.print("{f}", .{self.*}) catch |err| {
        log.err("Failed to write to {s}.md: {s}", .{ self.id, @errorName(err) });
        return error.Invalid;
    };
    // @IMPORTANT I never forget to flush
    writer.flush() catch |err| {
        log.err("Failed to flush {s}.md: {s}", .{ self.id, @errorName(err) });
        return error.Invalid;
    };
    file.sync(io) catch |err| {
        log.err("Failed to sync {s}.md: {s}", .{ self.id, @errorName(err) });
        return error.Invalid;
    };
}

pub fn format(self: *const Task, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("{s}\n", .{gila.seperator});
    const fields = std.meta.fields(Task);
    inline for (fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "description") or std.mem.eql(u8, field.name, "extra_lines") or std.mem.eql(u8, field.name, "id")) {
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
    if (self.extra_lines) |extra_lines| {
        for (extra_lines) |line| {
            try writer.print("{s}\n", .{line});
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

pub const TransitionError = error{
    ShouldBeWaiting,
    ShouldBeDone,
    ShouldBeCancelled,
};
pub fn transition(self: *Task, to: gila.Status) TransitionError!void {
    const status = self.status;
    switch (to) {
        .waiting => {
            if (self.waiting_on == null) {
                log.err("Task '{s}' is in waiting state but has no waiting_on list", .{self.id});
                return error.ShouldBeWaiting;
            }
            self.status = .waiting;
            self.completed = null;
        },
        .started, .todo => |s| {
            if (self.waiting_on != null) {
                log.err("Task '{s}' is in {s} state but has a waiting_on list", .{ self.id, @tagName(s) });
                return error.ShouldBeWaiting;
            }
            self.status = s;
            self.completed = null;
        },
        .cancelled => {
            if (self.waiting_on != null) {
                log.err("Task '{s}' is in cancelled state but has a waiting_on list", .{self.title});
                return error.ShouldBeWaiting;
            }
            switch (status) {
                else => self.status = .cancelled,
                .done => {
                    log.err("Task '{s}' is in the done state but wants to moe to cancelled. This is strange", .{self.title});
                    return error.ShouldBeDone;
                },
            }
            if (self.completed) |_| {
                return;
            }
            self.completed = stdx.DateTimeUTC.now();
        },
        .done => {
            if (self.waiting_on != null) {
                log.err("Task '{s}' is in done state but has a waiting_on list", .{self.title});
                return error.ShouldBeWaiting;
            }
            switch (status) {
                else => self.status = .cancelled,
                .cancelled => {
                    log.err("Task '{s}' is in the cancelled state but wants to move to done. This is strange", .{self.id});
                    return error.ShouldBeCancelled;
                },
            }
            self.status = .done;
            if (self.completed) |_| {
                return;
            }
            self.completed = stdx.DateTimeUTC.now();
        },
    }
}

pub const ValidateError = error{
    Invalid,
    WaitingFoundButAllValid,
    WaitingNotFoundWhenWaitingStatus,
    CompletedFoundWhenNotCompletedStatus,
    CompletedNotFoundWhenCompletedStatus,
};
pub fn validate(self: *const Task, error_out: *?[]const u8) ValidateError!void {
    // @TODO [[powerful_gecko_m5d]]
    if (!gila.id.isValid(self.id)) {
        error_out.* = "Task id must be a valid task_id";
        return error.Invalid;
    }

    if (!titleIsValid(self.title)) {
        error_out.* = "Task title is invalid. Empty or contains \\r or \\n";
        return error.Invalid;
    }

    if (self.owner.len == 0) {
        error_out.* = "Task owner cannot be empty";
        return error.Invalid;
    }

    if (self.tags) |tags| {
        if (tags.len == 0) {
            error_out.* = "Task tags cannot be empty";
            return error.Invalid;
        }
        for (tags) |tag| {
            if (tag.len == 0) {
                error_out.* = "Task tag cannot be empty";
                return error.Invalid;
            }

            const invalid_characters = std.mem.indexOfAny(u8, tag, "\r\n");
            if (invalid_characters != null) {
                error_out.* = "Task tag cannot contain '\\r' or '\\n'";
                return error.Invalid;
            }
        }
    }

    if (self.waiting_on) |waiting_on| {
        if (waiting_on.len == 0) {
            error_out.* = "Task waiting_on cannot be empty";
            return error.Invalid;
        }
        for (waiting_on) |waiting_on_item| {
            if (waiting_on_item.len == 0) {
                error_out.* = "Task waiting_on item cannot be empty";
                return error.Invalid;
            }
            const task_start = (std.mem.find(u8, waiting_on_item, "\"[[") orelse {
                error_out.* = "Task waiting_on item must start with \"[[\"";
                return error.Invalid;
            }) + 3;
            const task_end = std.mem.indexOf(u8, waiting_on_item, "]]\"") orelse {
                error_out.* = "Task waiting_on item must end with \"]]\"";
                return error.Invalid;
            };
            if (task_end <= task_start) {
                error_out.* = "Task waiting_on item must contain a valid task id";
                return error.Invalid;
            }
            if (!gila.id.isValid(waiting_on_item[task_start..task_end])) {
                error_out.* = "Task must be a valid task id";
                return error.Invalid;
            }
            const invalid_characters = std.mem.indexOfAny(u8, waiting_on_item, "\r\n");
            if (invalid_characters != null) {
                error_out.* = "Task waiting_on item cannot contain '\\r' or '\\n'";
                return error.Invalid;
            }
        }
        if (self.status != .waiting) {
            return error.WaitingFoundButAllValid;
        }
    }

    switch (self.status) {
        .todo, .started => if (self.completed != null) {
            error_out.* = "Task cannot be in todo or started state with a completed date";
            return error.CompletedFoundWhenNotCompletedStatus;
        },
        .done, .cancelled => if (self.completed == null) {
            error_out.* = "Task cannot be in done or cancelled state without a completed date";
            return error.CompletedNotFoundWhenCompletedStatus;
        },
        .waiting => if (self.waiting_on == null) {
            error_out.* = "Task cannot be in waiting state without a waiting_on list";
            return error.WaitingNotFoundWhenWaitingStatus;
        },
    }
}

fn titleIsValid(title: []const u8) bool {
    if (title.len == 0) {
        log.err("Title cannot be empty", .{});
        return false;
    }
    const invalids: []const u8 = "\r\n";
    const invalid_char = std.mem.findAny(
        u8,
        title,
        invalids,
    );

    if (invalid_char) |index| {
        const invalids_escaped: []const u8 = "\\r\\n";
        log.err("Title cannot contain any of '{s}'. Found one at index {d}", .{ invalids_escaped, index });
        return false;
    }
    return true;
}

inline fn Error(diagnostics: *?Diagnostic, message: []const u8, line: usize, column_start: usize, column_end: usize) error{Invalid} {
    diagnostics.* = .{
        .line = line,
        .column_start = column_start,
        .column_end = column_end,
        .message = message,
    };
    return error.Invalid;
}

test "Task.parse" {
    const buffer =
        \\---
        \\title: test
        \\status: todo
        \\priority_value: 50
        \\priority: medium
        \\custom_property:
        \\- text
        \\- random
        \\data: test
        \\owner: adiraj
        \\created: 2025-12-13T08:42:53Z
        \\completed: 2025-12-13T08:43:53Z
        \\waiting_on: 
        \\- "[[word_word_ccc]]"
        \\- "[[test_another_15c]]"
        \\Random line
        \\Another random line
        \\tags: 
        \\- a
        \\- b
        \\- c
        \\---
        \\
        \\test description
        \\
    ;
    const expected_write =
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
        \\custom_property:
        \\- text
        \\- random
        \\data: test
        \\Random line
        \\Another random line
        \\---
        \\
        \\test description
        \\
    ;
    const data = try std.testing.allocator.dupe(u8, buffer);
    defer std.testing.allocator.free(data);
    var reader = std.Io.Reader.fixed(data);
    var memory: [4096 * 2]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&memory);

    var task = Task.init("abc_def_123") catch return error.InvalidId;

    var diagnostic: ?Diagnostic = null;
    task.fromReader(&reader, &arena, &diagnostic) catch {
        std.debug.print("Diagnostic: {s}\n", .{diagnostic.?.message});
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
    writer.print("{f}", .{task}) catch {
        std.debug.print("Data: \n{s}", .{output});
        return error.TestFailedToWrite;
    };

    try std.testing.expectEqual(expected_write.len, writer.buffered().len);
    try std.testing.expectEqualStrings(expected_write, writer.buffered());

    var error_out: ?[]const u8 = null;
    try std.testing.expectError(error.WaitingFoundButAllValid, task.validate(&error_out));
}
