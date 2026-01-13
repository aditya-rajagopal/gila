const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const root = @import("root");

const log = std.log.scoped(.find);

const gila = @import("gila");
const stdx = @import("stdx");

const common = @import("common.zig");

const Find = @This();

// @TODO GILA(swift_base_f2p)
status: ?gila.Status = null,
owner: ?common.StringList = null,
priority: ?common.PriorityFilter = null,
priority_value: ?common.PriorityValueFilter = null,
tags: ?common.TagsFilter = null,
waiting_on: ?common.WaitingOnFilter = null,
verbose: bool = false,

pub const help = gila.logo ++
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

pub const Entry = struct {
    path: []const u8,
    status: gila.Status,
};
const TaskList = std.ArrayList(Entry);
const Transitions = std.StringArrayHashMapUnmanaged([2]gila.Status);

pub fn execute(self: Find, ctx: common.CommandContext) void {
    const result = self.run(ctx) catch return;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(ctx.io, &buffer);

    writer.interface.writeAll("Tasks found:\n") catch unreachable;
    for (result.tasks) |task| {
        writer.interface.print("{s}/{s}\n", .{ result.gila_path, task.path }) catch unreachable;
    }

    writer.interface.flush() catch unreachable;
}

pub const Error = error{
    GilaNotFound,
    OutOfMemory,
    DirIterationFailed,
    FailedToGenerateTaskId,
    InvalidTask,
    FailedToWriteTaskDescriptionFile,
    FailedToOpenEditor,
    SyncFailed,
};

pub fn run(self: Find, ctx: common.CommandContext) Error!struct { tasks: []Entry, gila_path: []const u8 } {
    const io = ctx.io;
    const arena = ctx.arena;
    const allocator = arena.allocator();
    if (!self.verbose) {
        root.log_level = .warn;
    }

    const gila_path, var gila_dir = common.getGilaDir(io, allocator) orelse return Error.GilaNotFound;
    defer gila_dir.close(io);

    const Sync = @import("sync.zig");
    const sync = Sync{};
    const transitions, const updates = sync.run(ctx) catch return Error.SyncFailed;
    for (transitions) |transition| {
        log.info("Moved {s}: {s} -> {s}", .{ transition.task_id, @tagName(transition.from), @tagName(transition.to) });
    }
    for (updates) |update| {
        log.info("Updated {s}: {s}: {s}", .{ update.task_id, update.change, update.dependency });
    }

    const fixed_buffer: []u8 = try allocator.alloc(u8, 128 * 1024);
    var local_arena = stdx.Arena.initBuffer(fixed_buffer);

    var tasks = try TaskList.initCapacity(arena.allocator(), 1024);

    inline for (std.meta.fieldNames(gila.Status)) |field| {
        escape: {
            if (self.status) |status| {
                if (std.meta.stringToEnum(gila.Status, field) != status) {
                    break :escape;
                }
            }
            var dir_n: ?std.Io.Dir = gila_dir.openDir(io, field, .{ .iterate = true }) catch null;
            if (dir_n) |*dir| {
                var dir_walker = dir.iterateAssumeFirstIteration();
                while (dir_walker.next(io) catch |err| {
                    log.err("Failed to iterate over done directory: {s}", .{@errorName(err)});
                    return Error.DirIterationFailed;
                }) |entry| {
                    defer local_arena.reset(false);
                    if (entry.kind == .directory) {
                        if (gila.id.isValid(entry.name)) {
                            var buffer: [1024]u8 = undefined;
                            const file_name = std.fmt.bufPrint(&buffer, "{s}.md", .{entry.name}) catch unreachable;
                            const path = try std.fs.path.join(local_arena.allocator(), &.{ entry.name, file_name });
                            const file = dir.openFile(io, path, .{}) catch continue;
                            defer file.close(io);

                            const folder = std.meta.stringToEnum(gila.Status, field) orelse unreachable;
                            const task = parseTask(&local_arena, entry.name, file_name, io, folder, gila_dir, file) catch continue;

                            if (task) |t| {
                                if (self.testTask(t)) {
                                    const full_path = std.fs.path.join(arena.allocator(), &.{ field, path }) catch unreachable;
                                    try tasks.append(arena.allocator(), .{ .path = full_path, .status = folder });
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    return .{ .tasks = try tasks.toOwnedSlice(arena.allocator()), .gila_path = gila_path };
}

fn noFilter(self: Find) bool {
    return self.priority == null and
        self.priority_value == null and
        self.tags == null and
        self.waiting_on == null and
        self.owner == null;
}

const find = common.findString;
pub fn testTask(self: Find, task: gila.Task) bool {
    if (self.noFilter()) {
        return true;
    }
    if (self.priority) |priority| {
        const condition = switch (priority.direction) {
            .lt => @intFromEnum(task.priority) < @intFromEnum(priority.value),
            .gt => @intFromEnum(task.priority) > @intFromEnum(priority.value),
            .eq => @intFromEnum(task.priority) == @intFromEnum(priority.value),
            .lte => @intFromEnum(task.priority) <= @intFromEnum(priority.value),
            .gte => @intFromEnum(task.priority) >= @intFromEnum(priority.value),
        };
        if (condition) return true;
    }

    if (self.priority_value) |priority_value| {
        const condition = switch (priority_value.direction) {
            .lt => task.priority_value < priority_value.value,
            .gt => task.priority_value > priority_value.value,
            .eq => task.priority_value == priority_value.value,
            .lte => task.priority_value <= priority_value.value,
            .gte => task.priority_value >= priority_value.value,
        };
        if (condition) return true;
    }

    if (self.tags) |tags| fail: {
        switch (tags.op) {
            .@"and" => {
                if (task.tags) |task_tags| {
                    for (tags.tag_list.strings) |tag| {
                        if (!find(task_tags, tag)) break :fail;
                    }
                } else break :fail;
                return true;
            },
            .@"or" => {
                if (task.tags) |task_tags| {
                    for (tags.tag_list.strings) |tag| {
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
            .moved => {},
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
const TestFs = if (builtin.is_test) @import("test_fs").TestFs else void;
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
        .priority = .{ .direction = .eq, .value = .high },
        .tags = null,
        .waiting_on = null,
        .verbose = false,
    };

    var arena_buffer: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buffer);

    const context = common.CommandContext{
        .io = fs.io(),
        .arena = &arena,
        .username = "testuser",
        .editor = "vim",
    };
    cmd.execute(context);

    const stdout = fs.getStdout();
    try testing.expect(std.mem.indexOf(u8, stdout, "high_pri_abc") != null);
    try testing.expect(std.mem.indexOf(u8, stdout, "low_pri_abc") == null);
    fs.clearStdout();

    const cmd2: Find = .{
        .priority = .{ .direction = .lt, .value = .high },
        .tags = null,
        .waiting_on = null,
        .verbose = false,
    };
    arena.reset(false);
    cmd2.execute(context);

    const stdout2 = fs.getStdout();
    try testing.expect(std.mem.indexOf(u8, stdout2, "high_pri_abc") == null);
    try testing.expect(std.mem.indexOf(u8, stdout2, "low_pri_abc") != null);
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
            .tag_list = .{ .strings = &tags_storage },
        },
        .waiting_on = null,
        .verbose = false,
    };

    var arena_buffer: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buffer);

    const context = common.CommandContext{
        .io = fs.io(),
        .arena = &arena,
        .username = "testuser",
        .editor = "vim",
    };
    cmd.execute(context);

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
            .tag_list = .{ .strings = &tags_storage },
        },
        .waiting_on = null,
        .verbose = false,
    };

    var arena_buffer: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buffer);

    const context = common.CommandContext{
        .io = fs.io(),
        .arena = &arena,
        .username = "testuser",
        .editor = "vim",
    };
    cmd.execute(context);

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
        .priority = .{ .direction = .eq, .value = .urgent },
        .tags = null,
        .waiting_on = null,
        .verbose = false,
    };

    var arena_buffer: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buffer);

    const context = common.CommandContext{
        .io = fs.io(),
        .arena = &arena,
        .username = "testuser",
        .editor = "vim",
    };
    cmd.execute(context);

    try expectStdoutContains(fs, "Tasks found:");
    const stdout = fs.getStdout();
    try testing.expect(std.mem.indexOf(u8, stdout, "low_only_abc") == null);
}

// @TODO add tests for waiting_on
