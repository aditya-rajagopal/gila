const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const root = @import("root");

const log = std.log.scoped(.find);

const gila = @import("gila");
const stdx = @import("stdx");

const common = @import("common.zig");

const Find = @This();

const Op = enum { @"and", @"or" };

priority: ?gila.Priority = null,
tags: ?struct {
    op: Op,
    tag_list: common.Tags,

    pub fn parseFlagValue(gpa: std.mem.Allocator, flag_value: []const u8, error_out: *?[]const u8) error{Invalid}!@This() {
        if (flag_value.len == 0) {
            error_out.* = "Empty flag value";
            return error.Invalid;
        }
        const op_pos = std.mem.findScalar(u8, flag_value, ':');
        var data: []const u8 = flag_value;
        var result: @This() = undefined;
        if (op_pos) |pos| {
            result.op = std.meta.stringToEnum(Op, flag_value[0..pos]) orelse {
                error_out.* = "Invalid op provided in flag value. Must be one of 'and' or 'or'";
                return error.Invalid;
            };
            data = flag_value[pos + 1 ..];
        } else {
            result.op = .@"or";
        }
        result.tag_list = common.Tags.parseFlagValue(gpa, data, error_out) catch return error.Invalid;
        return result;
    }
} = null,
waiting_on: ?struct {
    op: Op,
    task_list: common.TaskList,

    pub fn parseFlagValue(gpa: std.mem.Allocator, flag_value: []const u8, error_out: *?[]const u8) error{Invalid}!@This() {
        if (flag_value.len == 0) {
            error_out.* = "Empty flag value";
            return error.Invalid;
        }
        const op_pos = std.mem.findScalar(u8, flag_value, ':');
        var data: []const u8 = flag_value;
        var result: @This() = undefined;
        if (op_pos) |pos| {
            result.op = std.meta.stringToEnum(Op, flag_value[0..pos]) orelse {
                error_out.* = "Invalid op provided in flag value. Must be one of 'and' or 'or'";
                return error.Invalid;
            };
            data = flag_value[pos + 1 ..];
        } else {
            result.op = .@"or";
        }
        result.task_list = common.TaskList.parseFlagValue(gpa, data, error_out) catch return error.Invalid;
        return result;
    }
} = null,
verbose: bool = false,

pub const help =
    \\Usage:
    \\
    \\    gila find [--priority=low|medium|high|urgent] [--tags="<[or|and]:><tag1>,<tag2>,..."]
    \\              [--waiting-on="<[or|and]:><task1>,<task2>,..."] [--verbose]
    \\
    \\Find tasks that match any one of the filters.
    \\
    \\Options:
    \\    -h, --help
    \\        Prints this help message.
    \\
    \\    --priority=<priority>
    \\        The priority of the task. Can be one of low, medium, high, or urgent.
    \\
    \\    --tags="<[or|and]:><tag1>,<tag2>,..."
    \\        An optional operation followed by a list of tags, separated by a : between the operation and the list.
    \\        The operation can be either 'or' or 'and'. If no operation is provided, it is assumed to be 'or'.
    \\        The tags should not contain any of '\n', '\r', '\t'.
    \\
    \\    --waiting-on=="<[or|and]:><task1>,<task2>,..."
    \\        An optional operation followed by a list of tasks, separated by a : between the operation and the list.
    \\        The operation can be either 'or' or 'and'. If no operation is provided, it is assumed to be 'or'.
    \\        Each task should be a valid task_id of the form `word_word_ccc'.
    \\
    \\    --verbose
    \\        Run verbosely. Prints the contents of the task description file to stdout.
    \\
;

const TaskList = std.ArrayList([]const u8);
const Transitions = std.StringArrayHashMapUnmanaged([2]gila.Status);

pub fn execute(self: Find, io: std.Io, arena: *stdx.Arena) void {
    const allocator = arena.allocator();
    if (!self.verbose) {
        root.log_level = .warn;
    }

    const gila_path, var gila_dir = common.getGilaDir(io, allocator) orelse return;
    defer gila_dir.close(io);

    const fixed_buffer: []u8 = allocator.alloc(u8, 128 * 1024) catch unreachable;
    var local_arena = stdx.Arena.initBuffer(fixed_buffer);

    const task_buffer: [][]const u8 = arena.pushArray([]const u8, 1024);
    var tasks = TaskList.initBuffer(task_buffer);

    var transitions: Transitions = .empty;
    transitions.ensureUnusedCapacity(allocator, 1024) catch unreachable;

    inline for (std.meta.fieldNames(gila.Status)) |field| {
        var dir_n: ?std.Io.Dir = gila_dir.openDir(io, field, .{ .iterate = true }) catch null;
        if (dir_n) |*dir| {
            var dir_walker = dir.iterateAssumeFirstIteration();
            while (dir_walker.next(io) catch |err| {
                log.err("Failed to iterate over done directory: {s}", .{@errorName(err)});
                return;
            }) |entry| {
                defer local_arena.reset(false);
                if (entry.kind == .directory) {
                    if (gila.id.isValid(entry.name)) {
                        var buffer: [1024]u8 = undefined;
                        const file_name = std.fmt.bufPrint(&buffer, "{s}.md", .{entry.name}) catch unreachable;
                        const path = std.fs.path.join(local_arena.allocator(), &.{ entry.name, file_name }) catch unreachable;
                        const file = dir.openFile(io, path, .{}) catch continue;
                        defer file.close(io);

                        const folder = std.meta.stringToEnum(gila.Status, field) orelse unreachable;
                        const task = parseTask(&local_arena, entry.name, file_name, io, folder, gila_dir, file, &transitions) catch continue;

                        if (task) |t| {
                            if (self.testTask(t)) {
                                const full_path = std.fs.path.join(arena.allocator(), &.{ gila_path, field, path }) catch unreachable;
                                tasks.append(arena.allocator(), full_path) catch {
                                    log.err("Ran out of memory while appending task name", .{});
                                    return;
                                };
                            }
                        }
                    }
                }
            }
        }
    }

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    var iter = transitions.iterator();

    writer.interface.writeAll("Tasks found:\n") catch unreachable;
    while (tasks.pop()) |task_name| {
        writer.interface.print("{s}\n", .{task_name}) catch unreachable;
    }

    if (transitions.count() != 0) {
        writer.interface.writeAll("\n") catch unreachable;

        writer.interface.writeAll("Tasks transitioned in the process of finding:\n") catch unreachable;
        while (iter.next()) |entry| {
            writer.interface.print("Moved {s}: {t} -> {t}\n", .{ entry.key_ptr.*, entry.value_ptr[0], entry.value_ptr[1] }) catch unreachable;
        }
    }
    writer.interface.flush() catch unreachable;
}

const find = common.findString;
pub fn testTask(self: Find, task: gila.Task) bool {
    if (self.priority) |priority| {
        if (priority == task.priority) return true;
    }
    if (self.tags) |tags| fail: {
        switch (tags.op) {
            .@"and" => {
                if (task.tags) |task_tags| {
                    for (tags.tag_list.tags) |tag| {
                        if (!find(task_tags, tag)) break :fail;
                    }
                } else break :fail;
                return true;
            },
            .@"or" => {
                if (task.tags) |task_tags| {
                    for (tags.tag_list.tags) |tag| {
                        if (find(task_tags, tag)) return true;
                    }
                } else break :fail;
            },
        }
    }
    if (self.waiting_on) |waiting_on| fail: {
        switch (waiting_on.op) {
            .@"and" => {
                if (task.waiting_on) |task_waiting_on| {
                    for (waiting_on.task_list.tasks) |waiting_on_task| {
                        if (!find(task_waiting_on, waiting_on_task)) break :fail;
                    }
                } else break :fail;
                return true;
            },
            .@"or" => {
                if (task.waiting_on) |task_waiting_on| {
                    for (waiting_on.task_list.tasks) |waiting_on_task| {
                        if (find(task_waiting_on, waiting_on_task)) return true;
                    }
                } else break :fail;
            },
        }
    }
    return false;
}

pub fn parseTask(
    arena: *stdx.Arena,
    task_name: []const u8,
    file_name: []const u8,
    io: std.Io,
    folder: gila.Status,
    gila_dir: std.Io.Dir,
    task_file: std.Io.File,
    transitions: *Transitions,
) !?gila.Task {
    var task = gila.Task.init(task_name) catch unreachable;
    task.fromFile(task_file, io, arena) catch return null;

    var error_out: ?[]const u8 = null;
    var changed: bool = false;
    task.validate(&error_out) catch |err| switch (err) {
        error.Invalid => {
            log.err("Failed to validate task description file {s}: {s}", .{ task_name, error_out.? });
            return null;
        },
        error.WaitingFoundButAllValid => {
            task.transition(.waiting) catch {
                log.err("Invalid task '{s}' with 'waiting' status: Skipping", .{task_name});
                return null;
            };
            log.info("Task '{s}' found in '{s}' folder and marked as '{s}' status had a waiting_on list. Transitioning to 'waiting' status", .{ task_name, @tagName(folder), @tagName(task.status) });
            changed = true;
        },
        error.WaitingNotFoundWhenWaitingStatus => {
            log.err("Invalid task '{s}' had 'waiting' status but no waiting_on list: Reverting to '{s}' status", .{ task_name, @tagName(folder) });
            task.transition(folder) catch {
                log.err("Failed to revert task '{s}' to '{s}' status", .{ task_name, @tagName(folder) });
                return null;
            };
            changed = true;
        },
        else => {},
    };
    if (task.status == folder and !changed) {} else {
        const result = moveTask(io, arena, file_name, &task, folder, task.status, gila_dir);
        switch (result) {
            .err => {
                return null;
            },
            .moved => |to_state| switch (to_state) {
                inline else => |s| {
                    transitions.put(arena.allocator(), task_name, [_]gila.Status{ folder, s }) catch unreachable;
                },
            },
        }
    }
    return task;
}

const Result = union(enum) {
    err,
    moved: gila.Status,
};

fn moveTask(
    io: std.Io,
    arena: *stdx.Arena,
    file_name: []const u8,
    task: *gila.Task,
    from: gila.Status,
    to: gila.Status,
    gila_dir: std.Io.Dir,
) Result {
    const task_name = file_name[0 .. file_name.len - 3];
    log.info(
        "Task '{s}' is in the wrong state. Expected '{s}' based on the folder but found '{s}' in the description. The file is taken as the truth.",
        .{ task_name, @tagName(from), @tagName(to) },
    );
    task.transition(to) catch {
        log.err("Failed to transition task '{s}' to '{s}'", .{ task_name, @tagName(to) });
        task.status = from;
        task.transition(task.status) catch {
            log.err("Failed to transition task '{s}' to '{s}'", .{ task_name, @tagName(task.status) });
            return .err;
        };
    };

    common.moveTaskData(io, arena.allocator(), gila_dir, task_name, from, task.status) catch return .err;

    _ = task.toTaskFile(io, false, arena, gila_dir) catch return .err;

    log.info("Successfully moved task {s} to {s}", .{ task_name, @tagName(task.status) });
    return .{ .moved = task.status };
}

const testing = std.testing;
const TestFs = @import("../testfs/root.zig").TestFs;
const test_utils = @import("test_utils.zig");

const initGilaProject = test_utils.initGilaProjectMinimal;
const createTaskFile = test_utils.createTaskFile;
const expectStdoutContains = test_utils.expectStdoutContains;

test "by priority" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    try createTaskFile(fs, "todo", "high_pri_abc", "High Priority", "high", "", "High priority task\n");
    try createTaskFile(fs, "todo", "low_pri_abc", "Low Priority", "low", "", "Low priority task\n");

    const cmd: Find = .{
        .priority = .high,
        .tags = null,
        .waiting_on = null,
        .verbose = false,
    };

    var arena_buffer: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buffer);

    cmd.execute(fs.io(), &arena);

    const stdout = fs.getStdout();
    try testing.expect(std.mem.indexOf(u8, stdout, "high_pri_abc") != null);
    try testing.expect(std.mem.indexOf(u8, stdout, "low_pri_abc") == null);
}

test "by tags with or" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    const feature_content =
        \\---
        \\title: Feature Task
        \\status: todo
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\tags:
        \\- feature
        \\---
        \\Feature description
        \\
    ;
    try fs.createFile(".gila/todo/feature_tsk_abc/feature_tsk_abc.md", feature_content);

    const bugfix_content =
        \\---
        \\title: Bugfix Task
        \\status: todo
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\tags:
        \\- bugfix
        \\---
        \\Bugfix description
        \\
    ;
    try fs.createFile(".gila/todo/bugfix_tsk_abc/bugfix_tsk_abc.md", bugfix_content);

    const other_content =
        \\---
        \\title: Other Task
        \\status: todo
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\tags:
        \\- other
        \\---
        \\Other description
        \\
    ;
    try fs.createFile(".gila/todo/other_tsk_abc/other_tsk_abc.md", other_content);

    var tags_storage: [2][]const u8 = undefined;
    tags_storage[0] = "feature";
    tags_storage[1] = "bugfix";

    const cmd: Find = .{
        .priority = null,
        .tags = .{
            .op = .@"or",
            .tag_list = .{ .tags = &tags_storage },
        },
        .waiting_on = null,
        .verbose = false,
    };

    var arena_buffer: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buffer);

    cmd.execute(fs.io(), &arena);

    const stdout = fs.getStdout();
    try testing.expect(std.mem.indexOf(u8, stdout, "feature_tsk_abc") != null);
    try testing.expect(std.mem.indexOf(u8, stdout, "bugfix_tsk_abc") != null);
    try testing.expect(std.mem.indexOf(u8, stdout, "other_tsk_abc") == null);
}

test "by tags with and" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    const both_content =
        \\---
        \\title: Both Tags Task
        \\status: todo
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\tags:
        \\- feature
        \\- urgent
        \\---
        \\Has both tags
        \\
    ;
    try fs.createFile(".gila/todo/both_tags_abc/both_tags_abc.md", both_content);

    const one_content =
        \\---
        \\title: One Tag Task
        \\status: todo
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\tags:
        \\- feature
        \\---
        \\Has one tag
        \\
    ;
    try fs.createFile(".gila/todo/one_tag_abc/one_tag_abc.md", one_content);

    var tags_storage: [2][]const u8 = undefined;
    tags_storage[0] = "feature";
    tags_storage[1] = "urgent";

    const cmd: Find = .{
        .priority = null,
        .tags = .{
            .op = .@"and",
            .tag_list = .{ .tags = &tags_storage },
        },
        .waiting_on = null,
        .verbose = false,
    };

    var arena_buffer: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buffer);

    cmd.execute(fs.io(), &arena);

    const stdout = fs.getStdout();
    try testing.expect(std.mem.indexOf(u8, stdout, "both_tags_abc") != null);
    try testing.expect(std.mem.indexOf(u8, stdout, "one_tag_abc") == null);
}

test "no matches" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    try createTaskFile(fs, "todo", "low_only_abc", "Low Task", "low", "", "Low priority only\n");

    const cmd: Find = .{
        .priority = .urgent,
        .tags = null,
        .waiting_on = null,
        .verbose = false,
    };

    var arena_buffer: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buffer);

    cmd.execute(fs.io(), &arena);

    try expectStdoutContains(fs, "Tasks found:");
    const stdout = fs.getStdout();
    try testing.expect(std.mem.indexOf(u8, stdout, "low_only_abc") == null);
}

// @TODO add tests for waiting_on
