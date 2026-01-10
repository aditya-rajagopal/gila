const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const root = @import("root");

const log = std.log.scoped(.done);

const gila = @import("gila");
const stdx = @import("stdx");

const common = @import("common.zig");

const Done = @This();

verbose: bool = false,
edit: bool = false,
positional: struct {
    task: []const u8,
},

pub const help =
    \\Usage:
    \\
    \\    gila done [-h | --help] [--verbose] [--edit] <task_id>
    \\
    \\Marks a task as done copies it to the done directory and then deletes it from the todo directory.
    \\TODO: Move all the artifacts to the done directory.
    \\
    \\Options:
    \\    -h, --help
    \\        Prints this help message.
    \\
    \\    --verbose
    \\        Run verbosely.
    \\
    \\    --edit
    \\        Open the description file in the editor after moving files to the done directory.
    \\
    \\Examples:
    \\    gila done 20225125_120000_username
    \\    gila done --verbose --edit 20251213_055630_adiraj
    \\
;

pub fn execute(self: Done, ctx: common.CommandContext) void {
    const io = ctx.io;
    const arena = ctx.arena;
    const allocator = arena.allocator();
    if (!self.verbose) {
        root.log_level = .warn;
    }
    if (!gila.id.isValid(self.positional.task)) {
        log.err("Invalid task_id `{s}` a task is of the form word_word_ccc", .{self.positional.task});
        return;
    }

    const gila_path, var gila_dir = common.getGilaDir(io, allocator) orelse return;
    defer gila_dir.close(io);

    var result = gila.Task.findTaskAndRead(self.positional.task, io, arena, gila_dir) catch return;
    var task = &result.task;

    if (task.status == .cancelled) {
        log.debug("TODO: Move to cancelled folder", .{});
        return;
    }
    if (task.status == .waiting) {
        log.debug("TODO: Check if all the tasks that this task are waiting on are done.", .{});
        return;
    }

    log.info("Successfully parsed task description file contents", .{});

    if (task.status == .done) {
        if (result.status == .done and task.completed != null) {
            log.err("Task {s} is already marked as done and is in the right place", .{self.positional.task});
            return;
        }
        if (result.status == .done and task.completed == null) {
            log.warn("Task '{s}' was found in the done folder but has no completion time. Adding that", .{self.positional.task});
        }
    }

    task.transition(.done) catch |err| switch (err) {
        error.ShouldBeWaiting => {
            // @TODO Check if all the tasks that this task depends on are done. If they are, then transition to done.
            log.err("Task {s} has a waiting_on list and is trying to be marked as done. Use sync for now", .{self.positional.task});
            log.err("TODO: When executing done, if there is a waiting_on list we need to check the tasks in it before deciding to transition to done", .{});
            return;
        },
        error.ShouldBeDone => unreachable,
        error.ShouldBeCancelled => {
            log.err("Task {s} is in cancelled state and is trying to be marked as done.", .{self.positional.task});
            task.transition(.cancelled) catch {
                log.err("Failed to transition task {s} to cancelled state", .{self.positional.task});
                return;
            };
        },
    };

    common.moveTaskData(io, allocator, gila_dir, self.positional.task, result.status, task.status) catch return;

    const file_path = task.toTaskFile(io, false, arena, gila_dir) catch return;

    var stdout = std.Io.File.stdout().writer(io, &.{});
    stdout.interface.print("Successfully completed task {s}. Great success!\n", .{self.positional.task}) catch unreachable;

    if (self.edit) {
        const file_name = std.fs.path.join(allocator, &.{ gila_path, file_path }) catch |err| {
            log.err("Unexpected error while joining done/{s}: {s}", .{ self.positional.task, @errorName(err) });
            return;
        };

        log.debug("File path for editor: {s}", .{file_name});
        // @TODO make the default editor configurable
        const editor_name = ctx.editor;

        const res = std.process.run(std.heap.page_allocator, io, .{ .argv = &.{ editor_name, "+", file_name } }) catch |err| {
            log.err("Failed to open editor: {s}", .{@errorName(err)});
            return;
        };
        log.debug("Editor exited with code {any} at {f}", .{ res.term, stdx.DateTimeUTC.now() });
    }
}

const testing = std.testing;
const TestFs = if (builtin.is_test) @import("test_fs").TestFs else void;
const test_utils = @import("test_utils.zig");

const initGilaProject = test_utils.initGilaProjectMinimal;
const createTaskFile = test_utils.createTaskFile;
const readAndParseTask = test_utils.readAndParseTask;
const validateTask = test_utils.validateTask;
const expectStdoutContains = test_utils.expectStdoutContains;

test "marks todo task as done" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);
    try createTaskFile(fs, "todo", "done_task_abc", "Task To Complete", "medium", "", "Task description\n");

    const cmd: Done = .{
        .verbose = false,
        .edit = false,
        .positional = .{ .task = "done_task_abc" },
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

    try expectStdoutContains(fs, "Successfully completed task done_task_abc. Great success!");
    try testing.expect(fs.dirExists(".gila/done/done_task_abc"));
    try testing.expect(!fs.dirExists(".gila/todo/done_task_abc"));

    const task = try readAndParseTask(fs, "done_task_abc", .done);
    try validateTask(&task);

    try testing.expectEqual(gila.Status.done, task.status);
    try testing.expect(task.completed != null);
    try testing.expectEqualStrings("Task To Complete", task.title);
    try testing.expectEqual(50, task.priority_value);
    try testing.expectEqual(gila.Priority.medium, task.priority);
    try testing.expectEqualStrings("Task description\n", task.description);
}

test "invalid task id" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    const cmd: Done = .{
        .verbose = false,
        .edit = false,
        .positional = .{ .task = "invalid-id-format" },
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
    try testing.expectEqual(0, stdout.len);
}

test "already done task" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    const task_content =
        \\---
        \\title: Already Done Task
        \\status: done
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\completed: 2025-01-07T14:00:00Z
        \\---
        \\Already completed
        \\
    ;
    try fs.createFile(".gila/done/already_done_abc/already_done_abc.md", task_content);

    const cmd: Done = .{
        .verbose = false,
        .edit = false,
        .positional = .{ .task = "already_done_abc" },
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
    try testing.expect(std.mem.indexOf(u8, stdout, "Successfully completed task") == null);
}

test "task with waiting_on" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    const task_content =
        \\---
        \\title: Waiting Task
        \\status: todo
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\waiting_on:
        \\- "[[other_task_xyz]]"
        \\---
        \\Has dependencies
        \\
    ;
    try fs.createFile(".gila/todo/waiting_tsk_abc/waiting_tsk_abc.md", task_content);

    const cmd: Done = .{
        .verbose = false,
        .edit = false,
        .positional = .{ .task = "waiting_tsk_abc" },
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
    try testing.expect(std.mem.indexOf(u8, stdout, "Successfully completed task") == null);
}

test "preserves custom frontmatter" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    const task_content =
        \\---
        \\title: Task With Custom Fields
        \\status: todo
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\custom_property:
        \\- value1
        \\- value2
        \\created: 2025-01-07T12:00:00Z
        \\user_notes: Important context here
        \\Random unstructured line
        \\---
        \\Description body
        \\
    ;
    try fs.createFile(".gila/todo/custom_fld_abc/custom_fld_abc.md", task_content);

    const cmd: Done = .{
        .verbose = false,
        .edit = false,
        .positional = .{ .task = "custom_fld_abc" },
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

    try expectStdoutContains(fs, "Successfully completed task");

    const task = try readAndParseTask(fs, "custom_fld_abc", .done);
    try validateTask(&task);

    try testing.expectEqual(gila.Status.done, task.status);
    try testing.expect(task.completed != null);

    const extra_lines = task.extra_lines orelse return error.ExpectedExtraLines;
    try testing.expectEqual(5, extra_lines.len);
    try testing.expectEqualStrings("custom_property:", extra_lines[0]);
    try testing.expectEqualStrings("- value1", extra_lines[1]);
    try testing.expectEqualStrings("- value2", extra_lines[2]);
    try testing.expectEqualStrings("user_notes: Important context here", extra_lines[3]);
    try testing.expectEqualStrings("Random unstructured line", extra_lines[4]);
}
