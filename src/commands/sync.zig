const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const builtin = @import("builtin");

const gila = @import("gila");
const stdx = @import("stdx");
const root = @import("root");

const common = @import("common.zig");

const log = std.log.scoped(.sync);

const Sync = @This();

verbose: bool = false,

pub const help =
    \\Usage:
    \\
    \\    gila sync [-h | --help] [--verbose]
    \\
    \\Synchronizes the tasks in the gila directory by analyzing the tasks and moving them to their appropriate folders
    \\and modifying the necessary properties.
    \\
    \\Options:
    \\    -h, --help
    \\        Prints this help message.
    \\
    \\    --verbose
    \\        Run verbosely.
    \\
;

const TaskSet = std.StringArrayHashMapUnmanaged(void);
const Transition = struct {
    task_id: []const u8,
    from: gila.Status,
    to: gila.Status,
};
const Transitions = std.ArrayList(Transition);
const Update = struct {
    task_id: []const u8,
    change: []const u8,
    dependency: []const u8,
};
const Updates = std.ArrayList(Update);

const TaskSets = struct {
    todo: ?TaskSet,
    started: ?TaskSet,
    waiting: ?TaskSet,
    done: ?TaskSet,
    cancelled: ?TaskSet,

    pub const empty = TaskSets{
        .todo = null,
        .started = null,
        .waiting = null,
        .done = null,
        .cancelled = null,
    };
};

pub fn execute(self: Sync, ctx: common.CommandContext) void {
    if (!self.verbose) {
        root.log_level = .warn;
    }
    const transitions, const updates = self.run(ctx) catch return;
    const io = ctx.io;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    for (transitions) |transition| {
        writer.interface.print("Moved {s}: {t} -> {t}\n", .{ transition.task_id, transition.from, transition.to }) catch unreachable;
    }
    for (updates) |update| {
        writer.interface.print("Updated {s}: {s}: {s}\n", .{ update.task_id, update.change, update.dependency }) catch unreachable;
    }
    writer.interface.flush() catch unreachable;
}

// @TODO pass around an error context to fill inc ase of an error
pub const Error = error{
    GilaNotFound,
    DirIterationFailed,
    DirOpenFailed,
    OutOfMemory,
};
pub fn run(self: Sync, ctx: common.CommandContext) !struct { []Transition, []Update } {
    _ = self;
    const io = ctx.io;
    const arena = ctx.arena;
    // @TODO [[massive_raid_664]]
    const allocator = arena.allocator();

    _, var gila_dir = common.getGilaDir(io, allocator) orelse return Error.GilaNotFound;
    defer gila_dir.close(io);

    const fixed_buffer: []u8 = allocator.alloc(u8, 128 * 1024) catch unreachable;
    var local_arena = stdx.Arena.initBuffer(fixed_buffer);

    var maps: TaskSets = .empty;
    var transitions: Transitions = .empty;
    var updates: Updates = .empty;

    inline for (@typeInfo(TaskSets).@"struct".fields) |field| {
        var dir_n: ?std.Io.Dir = gila_dir.openDir(io, field.name, .{ .iterate = true }) catch null;
        if (dir_n) |*dir| {
            var map = TaskSet.init(allocator, &.{}, &.{}) catch unreachable;
            defer dir.close(io);
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
                        const path = std.fs.path.join(local_arena.allocator(), &.{ entry.name, file_name }) catch unreachable;
                        dir.access(io, path, .{}) catch continue;
                        const name = arena.pushString(entry.name);
                        map.put(arena.allocator(), name, {}) catch unreachable;
                    }
                }
            }
            @field(maps, field.name) = map;
        }
    }

    if (maps.done) |*done_map| {
        try parseFolder(io, gila_dir, gila.Status.done, &local_arena, &maps, done_map, arena, &transitions);
    }

    if (maps.todo) |*todo_map| {
        try parseFolder(io, gila_dir, gila.Status.todo, &local_arena, &maps, todo_map, arena, &transitions);
    }

    if (maps.started) |*started_map| {
        try parseFolder(io, gila_dir, gila.Status.started, &local_arena, &maps, started_map, arena, &transitions);
    }

    if (maps.cancelled) |*cancelled_map| {
        try parseFolder(io, gila_dir, gila.Status.cancelled, &local_arena, &maps, cancelled_map, arena, &transitions);
    }

    if (maps.waiting) |*waiting_map| {
        var dir: std.Io.Dir = gila_dir.openDir(io, "waiting", .{}) catch {
            @branchHint(.cold);
            log.err("Unexpected error while opening 'waiting' directory", .{});
            return Error.DirOpenFailed;
        };
        defer dir.close(io);
        var index: usize = 0;
        while (index < waiting_map.keys().len) {
            defer local_arena.reset(false);
            const task_name = waiting_map.keys()[index];

            var buffer: [128]u8 = undefined;
            const file_name = std.fmt.bufPrint(&buffer, "{s}.md", .{task_name}) catch unreachable;
            const path = std.fs.path.join(local_arena.allocator(), &.{ task_name, file_name }) catch unreachable;
            const file = dir.openFile(io, path, .{ .mode = .read_write }) catch |err| {
                log.err("Unexpected error while opening todo file {s}: {s}", .{ task_name, @errorName(err) });
                index += 1;
                continue;
            };

            var task = gila.Task.init(task_name) catch unreachable;
            task.fromFile(file, io, &local_arena) catch {
                index += 1;
                continue;
            };

            var error_out: ?[]const u8 = null;
            task.validate(&error_out) catch |err| switch (err) {
                error.Invalid => {
                    log.err("Failed to validate task description file {s}: {s}", .{ task_name, error_out.? });
                    index += 1;
                    continue;
                },
                error.WaitingFoundButAllValid => {
                    task.transition(.waiting) catch unreachable;
                    log.info("Task '{s}' found in '{s}' folder and marked as '{s}' status had a waiting_on list. Transitioning back to 'waiting' status", .{ task_name, @tagName(.waiting), @tagName(task.status) });
                },
                else => {},
            };

            if (task.waiting_on) |waiting_on| {
                var new_array = try std.ArrayList([]const u8).initCapacity(local_arena.allocator(), waiting_on.len);
                for (waiting_on) |name| {
                    assert(name.len > 3);
                    const waiting_task = name[3 .. name.len - 3];
                    var found: bool = false;
                    var done: bool = false;
                    inline for (@typeInfo(TaskSets).@"struct".fields) |field| {
                        if (comptime std.mem.eql(u8, field.name, "waiting")) {
                            continue;
                        }

                        if (@field(maps, field.name)) |map| {
                            const exists = if (map.get(waiting_task)) |_| true else false;
                            found = found or exists;
                            if (comptime std.mem.eql(u8, field.name, "done") or std.mem.eql(u8, field.name, "cancelled")) {
                                done = done or exists;
                            }
                        }
                    }
                    if (!found) {
                        const missing_task = try arena.allocator().dupe(u8, waiting_task);
                        try updates.append(arena.allocator(), .{ .task_id = task_name, .change = "missing_task", .dependency = missing_task });
                    } else {
                        if (done) {
                            try updates.append(arena.allocator(), .{ .task_id = task_name, .change = "removed_completed_dependency", .dependency = waiting_task });
                        } else {
                            new_array.appendAssumeCapacity(name);
                        }
                    }
                }

                if (new_array.items.len == 0) {
                    task.waiting_on = null;
                } else if (new_array.items.len != waiting_on.len) {
                    task.waiting_on = new_array.toOwnedSlice(local_arena.allocator()) catch unreachable;
                    task.flushToFile(io, file, file_name) catch {};
                    index += 1;
                    continue;
                } else {
                    // NOTE All waiting tasks are still undone
                    index += 1;
                    continue;
                }
            }
            file.close(io);

            log.info("Task {s} is not waiting on anything", .{task_name});
            const target_status = switch (task.status) {
                .todo, .started => |s| if (task.completed) |_| .done else s,
                .done, .cancelled => |s| if (task.completed) |_| s else .todo,
                .waiting => .todo,
            };
            const result = moveTask(io, &local_arena, file_name, &task, .waiting, target_status, gila_dir);
            switch (result) {
                .err => {
                    index += 1;
                    continue;
                },
                .moved => |to_state| switch (to_state) {
                    inline else => |s| {
                        if (task.status != .waiting) {
                            if (@field(maps, @tagName(s))) |*m| {
                                try m.put(arena.allocator(), task_name, {});
                            } else {
                                var m = try TaskSet.init(arena.allocator(), &.{}, &.{});
                                try m.put(arena.allocator(), task_name, {});
                                @field(maps, @tagName(s)) = m;
                            }
                            _ = waiting_map.swapRemove(task_name);
                        } else {
                            index += 1;
                        }
                        try transitions.append(arena.allocator(), .{ .task_id = task_name, .from = .waiting, .to = s });
                    },
                },
            }
        }
    }

    return .{ try transitions.toOwnedSlice(arena.allocator()), try updates.toOwnedSlice(arena.allocator()) };
}

fn parseFolder(
    io: std.Io,
    gila_dir: std.Io.Dir,
    folder: gila.Status,
    local_arena: *stdx.Arena,
    sets: *TaskSets,
    set: *TaskSet,
    arena: *stdx.Arena,
    transitions: *Transitions,
) Error!void {
    var dir: std.Io.Dir = gila_dir.openDir(io, @tagName(folder), .{}) catch {
        @branchHint(.cold);
        log.err("Unexpected error while opening '{s}' directory", .{@tagName(folder)});
        return Error.DirOpenFailed;
    };
    defer dir.close(io);
    var index: usize = 0;
    while (index < set.keys().len) {
        const task_name = set.keys()[index];
        defer local_arena.reset(false);
        const file_name = local_arena.pushArray(u8, task_name.len + 3);
        @memcpy(file_name[0..task_name.len], task_name);
        @memcpy(file_name[task_name.len..][0..3], ".md");
        const path = try std.fs.path.join(local_arena.allocator(), &.{ task_name, file_name });

        const file = dir.openFile(io, path, .{}) catch |err| {
            log.err("Unexpected error while opening task file {s}: {s}", .{ task_name, @errorName(err) });
            index += 1;
            continue;
        };

        var task = gila.Task.init(task_name) catch unreachable;
        task.fromFile(file, io, local_arena) catch {
            index += 1;
            continue;
        };

        file.close(io);

        var error_out: ?[]const u8 = null;
        var changed: bool = false;
        task.validate(&error_out) catch |err| switch (err) {
            error.Invalid => {
                log.err("Failed to validate task description file {s}: {s}", .{ task_name, error_out.? });
                index += 1;
                continue;
            },
            error.WaitingFoundButAllValid => {
                task.transition(.waiting) catch {
                    log.err("Invalid task '{s}' with 'waiting' status: Skipping", .{task_name});
                    index += 1;
                    continue;
                };
                log.info("Task '{s}' found in '{s}' folder and marked as '{s}' status had a waiting_on list. Transitioning to 'waiting' status", .{ task_name, @tagName(folder), @tagName(task.status) });
                changed = true;
            },
            error.WaitingNotFoundWhenWaitingStatus => {
                log.warn("Invalid task '{s}' had 'waiting' status but no waiting_on list: Reverting to '{s}' status", .{ task_name, @tagName(folder) });
                task.transition(folder) catch {
                    log.err("Failed to revert task '{s}' to '{s}' status", .{ task_name, @tagName(folder) });
                    index += 1;
                    continue;
                };
                changed = true;
            },
            else => {},
        };
        if (task.status == folder and !changed) {
            index += 1;
            log.info("Task '{s}' is in the same state as the folder. Skipping", .{task_name});
        } else {
            const result = moveTask(io, local_arena, file_name, &task, folder, task.status, gila_dir);
            switch (result) {
                .err => {
                    index += 1;
                },
                .moved => |to_state| switch (to_state) {
                    inline else => |s| {
                        if (@field(sets, @tagName(s))) |*m| {
                            try m.put(arena.allocator(), task_name, {});
                        } else {
                            var m = try TaskSet.init(arena.allocator(), &.{}, &.{});
                            try m.put(arena.allocator(), task_name, {});
                            @field(sets, @tagName(s)) = m;
                        }
                        _ = set.swapRemove(task_name);
                        try transitions.append(arena.allocator(), .{ .task_id = task_name, .from = folder, .to = s });
                    },
                },
            }
        }
    }
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
const readAndParseTask = test_utils.readAndParseTask;
const validateTask = test_utils.validateTask;
const expectStdoutContains = test_utils.expectStdoutContains;

test "file status overrides folder" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    const task_content =
        \\---
        \\title: Misplaced Task
        \\status: started
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\---
        \\Misplaced description
        \\
    ;
    try fs.createFile(".gila/todo/misplaced_tsk_abc/misplaced_tsk_abc.md", task_content);

    const cmd: Sync = .{
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

    try testing.expect(!fs.dirExists(".gila/todo/misplaced_tsk_abc"));
    try testing.expect(fs.dirExists(".gila/started/misplaced_tsk_abc"));

    const task = try readAndParseTask(fs, "misplaced_tsk_abc", .started);
    try validateTask(&task);
    try testing.expectEqual(gila.Status.started, task.status);

    try expectStdoutContains(fs, "Moved misplaced_tsk_abc:");
}

test "waiting task with done deps" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    const done_content =
        \\---
        \\title: Done Dependency
        \\status: done
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\completed: 2025-01-07T14:00:00Z
        \\---
        \\Completed task
        \\
    ;
    try fs.createFile(".gila/done/done_dep_abc/done_dep_abc.md", done_content);

    const waiting_content =
        \\---
        \\title: Waiting Task
        \\status: waiting
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\waiting_on:
        \\- "[[done_dep_abc]]"
        \\---
        \\Waiting description
        \\
    ;
    try fs.createFile(".gila/waiting/wait_task_abc/wait_task_abc.md", waiting_content);

    const cmd: Sync = .{
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

    try testing.expect(!fs.dirExists(".gila/waiting/wait_task_abc"));
    try testing.expect(fs.dirExists(".gila/todo/wait_task_abc"));

    const task = try readAndParseTask(fs, "wait_task_abc", .todo);
    try validateTask(&task);
    try testing.expectEqual(gila.Status.todo, task.status);
    try testing.expect(task.waiting_on == null);
}

test "multiple transitions" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    const task1_content =
        \\---
        \\title: Task One
        \\status: started
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\---
        \\Task one desc
        \\
    ;
    try fs.createFile(".gila/todo/task_one_abc/task_one_abc.md", task1_content);

    const task2_content =
        \\---
        \\title: Task Two
        \\status: done
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\completed: 2025-01-07T15:00:00Z
        \\---
        \\Task two desc
        \\
    ;
    try fs.createFile(".gila/started/task_two_abc/task_two_abc.md", task2_content);

    const cmd: Sync = .{
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

    try testing.expect(fs.dirExists(".gila/started/task_one_abc"));
    try testing.expect(fs.dirExists(".gila/done/task_two_abc"));
    try testing.expect(!fs.dirExists(".gila/todo/task_one_abc"));
    try testing.expect(!fs.dirExists(".gila/started/task_two_abc"));

    const task1 = try readAndParseTask(fs, "task_one_abc", .started);
    try validateTask(&task1);
    try testing.expectEqual(gila.Status.started, task1.status);

    const task2 = try readAndParseTask(fs, "task_two_abc", .done);
    try validateTask(&task2);
    try testing.expectEqual(gila.Status.done, task2.status);
    try testing.expect(task2.completed != null);
}

test "no changes needed" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    try createTaskFile(fs, "todo", "correct_tsk_abc", "Correct Task", "medium", "", "Properly placed\n");

    const cmd: Sync = .{
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
    try testing.expect(std.mem.indexOf(u8, stdout, "Moved") == null);
}

test "waiting task all deps done" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    const done1_content =
        \\---
        \\title: Done Dep 1
        \\status: done
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\completed: 2025-01-07T14:00:00Z
        \\---
        \\Done 1
        \\
    ;
    try fs.createFile(".gila/done/done_one_abc/done_one_abc.md", done1_content);

    const done2_content =
        \\---
        \\title: Done Dep 2
        \\status: done
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\completed: 2025-01-07T14:30:00Z
        \\---
        \\Done 2
        \\
    ;
    try fs.createFile(".gila/done/done_two_abc/done_two_abc.md", done2_content);

    const waiting_content =
        \\---
        \\title: Multi Dep Waiting
        \\status: waiting
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\waiting_on:
        \\- "[[done_one_abc]]"
        \\- "[[done_two_abc]]"
        \\---
        \\Waiting on multiple
        \\
    ;
    try fs.createFile(".gila/waiting/multi_wait_abc/multi_wait_abc.md", waiting_content);

    const cmd: Sync = .{
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

    try testing.expect(!fs.dirExists(".gila/waiting/multi_wait_abc"));
    try testing.expect(fs.dirExists(".gila/todo/multi_wait_abc"));
}

test "preserves custom frontmatter" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    const task_content =
        \\---
        \\title: Custom Fields Task
        \\status: started
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\my_custom_field: some value
        \\another_field:
        \\- item1
        \\- item2
        \\Unstructured data line
        \\---
        \\Description
        \\
    ;
    try fs.createFile(".gila/todo/custom_syn_abc/custom_syn_abc.md", task_content);

    const cmd: Sync = .{
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

    try testing.expect(fs.dirExists(".gila/started/custom_syn_abc"));

    const task = try readAndParseTask(fs, "custom_syn_abc", .started);
    try validateTask(&task);
    try testing.expectEqual(gila.Status.started, task.status);

    const extra_lines = task.extra_lines orelse return error.ExpectedExtraLines;
    try testing.expectEqual(5, extra_lines.len);
    try testing.expectEqualStrings("my_custom_field: some value", extra_lines[0]);
    try testing.expectEqualStrings("another_field:", extra_lines[1]);
    try testing.expectEqualStrings("- item1", extra_lines[2]);
    try testing.expectEqualStrings("- item2", extra_lines[3]);
    try testing.expectEqualStrings("Unstructured data line", extra_lines[4]);
}
