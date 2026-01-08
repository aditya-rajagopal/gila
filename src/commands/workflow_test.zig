const std = @import("std");
const testing = std.testing;
const gila = @import("gila");
const stdx = @import("stdx");
const TestFs = @import("../testfs/root.zig").TestFs;
const test_utils = @import("test_utils.zig");

const Init = @import("init.zig");
const Todo = @import("todo.zig");
const Done = @import("done.zig");
const Sync = @import("sync.zig");

const initGilaProject = test_utils.initGilaProjectMinimal;
const createTaskFile = test_utils.createTaskFile;
const readAndParseTask = test_utils.readAndParseTask;
const validateTask = test_utils.validateTask;
const expectStdoutContains = test_utils.expectStdoutContains;
const extractTaskId = test_utils.extractTaskIdFromStdout;

test "init -> todo -> done" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    var arena_buffer: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buffer);

    const init_cmd: Init = .{
        .bare = false,
        .verbose = false,
        .positional = .{ .directory = null },
    };
    init_cmd.execute(fs.io(), &arena);
    try expectStdoutContains(fs, "Initialized GILA project:");
    fs.clearStdout();

    const todo_cmd: Todo = .{
        .priority = .high,
        .priority_value = 75,
        .description = "Integration test task",
        .tags = null,
        .waiting_on = null,
        .blocks = null,
        .verbose = false,
        .edit = false,
        .positional = .{ .title = "Integration Test Task" },
    };

    arena.reset(false);
    todo_cmd.execute(fs.io(), &arena);

    try expectStdoutContains(fs, "New task created:");
    const task_id_raw = extractTaskId(fs.getStdout()) orelse return error.TaskIdNotFound;

    var task_id_buf: [64]u8 = undefined;
    @memcpy(task_id_buf[0..task_id_raw.len], task_id_raw);
    const task_id = task_id_buf[0..task_id_raw.len];

    const todo_task = try readAndParseTask(fs, task_id, .todo);
    try validateTask(&todo_task);
    try testing.expectEqual(gila.Status.todo, todo_task.status);
    try testing.expectEqual(gila.Priority.high, todo_task.priority);
    try testing.expectEqual(@as(u8, 75), todo_task.priority_value);

    fs.clearStdout();

    const done_cmd: Done = .{
        .verbose = false,
        .edit = false,
        .positional = .{ .task = task_id },
    };

    arena.reset(false);
    done_cmd.execute(fs.io(), &arena);

    try expectStdoutContains(fs, "Successfully completed task");
    try expectStdoutContains(fs, "Great success!");

    const done_task = try readAndParseTask(fs, task_id, .done);
    try validateTask(&done_task);
    try testing.expectEqual(gila.Status.done, done_task.status);
    try testing.expect(done_task.completed != null);
    try testing.expectEqualStrings("Integration Test Task", done_task.title);
}

test "waiting dependency chain" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    var arena_buffer: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buffer);

    try createTaskFile(fs, "todo", "task_a_abc", "Task A", "medium", "", "Base task A\n");

    const task_b_content =
        \\---
        \\title: Task B
        \\status: waiting
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\waiting_on:
        \\- "[[task_a_abc]]"
        \\---
        \\Waiting on Task A
        \\
    ;
    try fs.createFile(".gila/waiting/task_b_abc/task_b_abc.md", task_b_content);

    const task_a_initial = try readAndParseTask(fs, "task_a_abc", .todo);
    try validateTask(&task_a_initial);
    try testing.expectEqual(gila.Status.todo, task_a_initial.status);

    const task_b_initial = try readAndParseTask(fs, "task_b_abc", .waiting);
    try testing.expectEqual(gila.Status.waiting, task_b_initial.status);
    try testing.expect(task_b_initial.waiting_on != null);

    const done_cmd: Done = .{
        .verbose = false,
        .edit = false,
        .positional = .{ .task = "task_a_abc" },
    };
    done_cmd.execute(fs.io(), &arena);
    try expectStdoutContains(fs, "Successfully completed task task_a_abc");
    fs.clearStdout();

    const task_a_done = try readAndParseTask(fs, "task_a_abc", .done);
    try validateTask(&task_a_done);
    try testing.expectEqual(gila.Status.done, task_a_done.status);
    try testing.expect(task_a_done.completed != null);

    const sync_cmd: Sync = .{
        .verbose = false,
    };

    arena.reset(false);
    sync_cmd.execute(fs.io(), &arena);

    try testing.expect(!fs.dirExists(".gila/waiting/task_b_abc"));
    try testing.expect(fs.dirExists(".gila/todo/task_b_abc"));

    const task_b_after = try readAndParseTask(fs, "task_b_abc", .todo);
    try validateTask(&task_b_after);
    try testing.expectEqual(gila.Status.todo, task_b_after.status);
    try testing.expect(task_b_after.waiting_on == null);

    try expectStdoutContains(fs, "Moved task_b_abc:");
}
