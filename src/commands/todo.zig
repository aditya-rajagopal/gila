const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const root = @import("root");

const log = std.log.scoped(.todo);

const gila = @import("gila");
const stdx = @import("stdx");

const common = @import("common.zig");

const Todo = @This();

priority: gila.Priority = .medium,
priority_value: u8 = 50,
description: ?[]const u8 = null,
tags: ?common.Tags = null,
waiting_on: ?common.TaskList = null,
blocks: ?common.TaskList = null,
verbose: bool = false,
edit: bool = false,
positional: struct {
    title: []const u8,
},

pub const help =
    \\Usage:
    \\
    \\    gila todo [--priority=low|medium|high|urgent] [--priority-value=<integer value>]
    \\              [--description=<description>] [--tags="<tag1>,<tag2>,..."]
    \\              [--waiting-on="<task1>,<task2>,..."] [--blocks="<task1>,<task2>,..."]
    \\              [--verbose] [--edit] <title>
    \\
    \\Create a new task to the current project.
    \\
    \\Options:
    \\    -h, --help
    \\        Prints this help message.
    \\
    \\    --priority=<priority>
    \\        The priority of the task. Can be one of low, medium, high, or urgent.
    \\
    \\    --priority-value=<value>
    \\        The priority value of the task. Can be an integer between 0 to 255. Defaults to 50.
    \\
    \\    --description=<description>
    \\        The description of the task.
    \\
    \\    --tags="<tag1>,<tag2>,..."
    \\        The tags of the task. Should not contain any of '\n', '\r', '\t'.
    \\
    \\    --waiting-on="<task1>,<task2>,..."
    \\        The tasks that this task depends on. Each task should be a valid task_id of the form `word_word_ccc'.
    \\        If this is provided the task will be created as a waiting task.
    \\
    \\    --blocks="<task1>,<task2>,..."
    \\        The tasks that this new task will block. Blocked tasks will transition to waiting
    \\        status with this task added to their waiting_on list.
    \\
    \\    --verbose
    \\        Run verbosely. Prints the contents of the task description file to stdout.
    \\
    \\    --edit
    \\        Open the description file in the editor after creating the task and writing the header.
    \\
    \\    <title>
    \\        The title of the task.
    \\
    \\Examples:
    \\    gila todo --priority=low --priority-value=50 --description="This is a description" 'Title of the task'
    \\    gila todo --priority-value=200 'Title of the task'
    \\
;

pub fn execute(self: Todo, ctx: common.CommandContext) void {
    const result = self.run(ctx) catch return;
    var stdout = std.Io.File.stdout().writer(ctx.io, &.{});
    stdout.interface.print("New task created: {s}\n", .{result.task_id}) catch unreachable;
    return;
}

const Error = error{
    GilaNotFound,
    OutOfMemory,
    FailedToGenerateTaskId,
    InvalidTask,
    FailedToWriteTaskDescriptionFile,
    FailedToOpenEditor,
};
pub fn run(self: Todo, ctx: common.CommandContext) !struct { task_id: []const u8, description_file: []const u8, status: gila.Status } {
    const io = ctx.io;
    const arena = ctx.arena;
    const allocator = arena.allocator();
    if (!self.verbose) {
        root.log_level = .warn;
    }

    const gila_path, var gila_dir = common.getGilaDir(io, allocator) orelse return Error.GilaNotFound;
    defer gila_dir.close(io);

    const task_name = gila.id.new(allocator) catch |err| {
        log.err("Failed to get create task id: {s}", .{@errorName(err)});
        return Error.FailedToGenerateTaskId;
    };
    log.debug("Generated task_id: {s}", .{task_name});

    const user_name = ctx.username;
    const creation_dt = stdx.DateTimeUTC.now();

    const waiting_on: ?[]const []const u8 = if (self.waiting_on) |waiting_on| blk: {
        const new_list = arena.pushArray([]const u8, waiting_on.tasks.len);
        var array = std.ArrayList([]const u8).initBuffer(new_list);
        var fixed_buffer: [128 * 1024]u8 = undefined;
        var local_arena = stdx.Arena.initBuffer(&fixed_buffer);
        for (waiting_on.tasks) |waiting_task_id| {
            assert(waiting_task_id.len > 6);
            local_arena.reset(false);
            const task_id = waiting_task_id[3 .. waiting_task_id.len - 3];
            if (common.findString(array.items, waiting_task_id)) {
                log.err("Duplicate waiting task {s} in waiting_on list", .{task_id});
                continue;
            }

            var result = gila.Task.findTaskAndRead(task_id, io, &local_arena, gila_dir) catch |err| {
                log.err("Failed to find or read task {s}: {s}", .{ task_id, @errorName(err) });
                continue;
            };
            const blocked_task = &result.task;

            if (blocked_task.status == .done or blocked_task.status == .cancelled) {
                log.err("Cannot wait on task {s}: task is already {s}", .{ task_id, @tagName(blocked_task.status) });
                continue;
            }

            const new_entry: []u8 = arena.pushArray(u8, task_id.len + 6);
            @memcpy(new_entry[0..3], "\"[[");
            @memcpy(new_entry[3..][0..task_id.len], task_id);
            @memcpy(new_entry[3 + task_id.len ..], "]]\"");
            array.appendAssumeCapacity(new_entry);
        }
        break :blk array.items;
    } else null;

    const task: gila.Task = .{
        .id = task_name,
        .title = self.positional.title,
        .status = if (self.waiting_on) |_| .waiting else .todo,
        .priority = self.priority,
        .priority_value = self.priority_value,
        .owner = user_name,
        .created = creation_dt,
        .description = if (self.description) |description| description else "",
        .tags = if (self.tags) |tags| tags.tags else null,
        .waiting_on = waiting_on,
        .completed = null,
        .extra_lines = null,
    };

    var error_out: ?[]const u8 = null;
    task.validate(&error_out) catch {
        log.err("Failed to validate task description file {s}: {s}", .{ task_name, error_out.? });
        return Error.InvalidTask;
    };

    const description_file = task.toTaskFile(io, true, arena, gila_dir) catch return Error.FailedToWriteTaskDescriptionFile;
    log.debug("Successfully wrote task description file {s}", .{description_file});

    if (self.blocks) |blocks| {
        const fixed_buffer: []u8 = arena.pushArray(u8, 128 * 1024);
        var local_arena = stdx.Arena.initBuffer(fixed_buffer);
        for (blocks.tasks) |blocked_task_id| {
            assert(blocked_task_id.len > 3);
            const task_id = blocked_task_id[3 .. blocked_task_id.len - 3];

            local_arena.reset(false);

            var result = gila.Task.findTaskAndRead(task_id, io, &local_arena, gila_dir) catch |err| {
                log.err("Failed to find or read blocked task {s}: {s}", .{ task_id, @errorName(err) });
                continue;
            };
            const blocked_task = &result.task;

            if (blocked_task.status == .done or blocked_task.status == .cancelled) {
                log.err("Cannot block task {s}: task is already {s}", .{ task_id, @tagName(blocked_task.status) });
                continue;
            }

            const new_entry: []u8 = local_arena.pushArray(u8, task_name.len + 6);
            @memcpy(new_entry[0..3], "\"[[");
            @memcpy(new_entry[3..][0..task_name.len], task_name);
            @memcpy(new_entry[3 + task_name.len ..], "]]\"");

            if (blocked_task.waiting_on) |t| {
                const new_list = local_arena.pushArray([]const u8, t.len + 1);
                for (t, 0..) |item, index| {
                    new_list[index] = item;
                }
                new_list[t.len] = new_entry;
                blocked_task.waiting_on = new_list;
            } else {
                const new_list = local_arena.pushArray([]const u8, 1);
                new_list[0] = new_entry;
                blocked_task.waiting_on = new_list;
            }

            if (blocked_task.status != .waiting) {
                blocked_task.transition(.waiting) catch |err| {
                    log.err("Failed to transition task {s} to waiting: {s}", .{ task_id, @errorName(err) });
                    continue;
                };

                common.moveTaskData(io, local_arena.allocator(), gila_dir, task_id, result.status, .waiting) catch |err| {
                    log.err("Failed to move task {s} to waiting: {s}", .{ task_id, @errorName(err) });
                    continue;
                };
            }

            _ = blocked_task.toTaskFile(io, false, &local_arena, gila_dir) catch |err| {
                log.err("Failed to write task {s}: {s}", .{ task_id, @errorName(err) });
                continue;
            };

            log.info("Blocked task {s} is now waiting on {s}", .{ task_id, task_name });
        }
    }

    // @TODO make the default editor configurable
    if (self.edit) {
        const editor_name = ctx.editor;

        const file_name = try std.fs.path.join(allocator, &.{ gila_path, description_file });
        var result = std.process.run(std.heap.page_allocator, io, .{ .argv = &.{ editor_name, "+", file_name } }) catch |err| {
            log.err("Failed to open editor: {s}", .{@errorName(err)});
            return Error.FailedToOpenEditor;
        };
        log.debug("Opened editor {s} at {f}", .{ editor_name, stdx.DateTimeUTC.now() });
        log.debug("Editor exited with code {any} at {f}", .{ result.term, stdx.DateTimeUTC.now() });
    }

    return .{ .task_id = task.id, .description_file = description_file, .status = task.status };
}

const testing = std.testing;
const TestFs = @import("../testfs/root.zig").TestFs;
const test_utils = @import("test_utils.zig");

const initGilaProject = test_utils.initGilaProjectMinimal;
const createTaskFile = test_utils.createTaskFile;
const readAndParseTask = test_utils.readAndParseTask;
const validateTask = test_utils.validateTask;
const expectStdoutContains = test_utils.expectStdoutContains;
const extractTaskId = test_utils.extractTaskIdFromStdout;

test "basic task creation" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    var tags_storage: [3][]const u8 = undefined;
    tags_storage[0] = "feature";
    tags_storage[1] = "urgent";
    tags_storage[2] = "backend";

    const cmd: Todo = .{
        .priority = .high,
        .priority_value = 75,
        .description = "This is a detailed description\nWith multiple lines",
        .tags = .{ .tags = &tags_storage },
        .waiting_on = null,
        .blocks = null,
        .verbose = false,
        .edit = false,
        .positional = .{ .title = "Test Task Title" },
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

    try expectStdoutContains(fs, "New task created:");

    const task_id = extractTaskId(fs.getStdout()) orelse return error.TaskIdNotFound;

    const task = try readAndParseTask(fs, task_id, .todo);
    try validateTask(&task);

    try testing.expectEqualStrings("Test Task Title", task.title);
    try testing.expectEqual(gila.Status.todo, task.status);
    try testing.expectEqual(gila.Priority.high, task.priority);
    try testing.expectEqual(@as(u8, 75), task.priority_value);

    try testing.expect(task.completed == null);
    try testing.expect(task.waiting_on == null);

    const tags = task.tags orelse return error.ExpectedTags;
    try testing.expectEqual(@as(usize, 3), tags.len);
    try testing.expect(std.mem.indexOf(u8, tags[0], "feature") != null);
    try testing.expect(std.mem.indexOf(u8, tags[1], "urgent") != null);
    try testing.expect(std.mem.indexOf(u8, tags[2], "backend") != null);

    try testing.expectEqualStrings("This is a detailed description\nWith multiple lines", task.description);
}

test "with waiting_on creates waiting task" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    try createTaskFile(fs, "todo", "base_task_abc", "Base Task", "medium", "", "Base task description\n");
    try createTaskFile(fs, "todo", "base_tasktwo_abc", "Base Task Two", "medium", "", "Base task two description\n");
    try createTaskFile(fs, "done", "base_taskthree_abc", "Base Task Three should fail", "medium", "", "Base task two description\n");

    var waiting_on_storage: [5][]const u8 = undefined;
    waiting_on_storage[0] = "\"[[base_task_abc]]\"";
    waiting_on_storage[1] = "\"[[base_tasktwo_abc]]\"";
    waiting_on_storage[2] = "\"[[base_taskthree_abc]]\"";
    waiting_on_storage[3] = "\"[[base_taskthree_abc]]\"";
    waiting_on_storage[4] = "\"[[nonexistent_task_abc]]\"";

    const cmd: Todo = .{
        .priority = .medium,
        .priority_value = 50,
        .description = null,
        .tags = null,
        .waiting_on = .{ .tasks = &waiting_on_storage },
        .blocks = null,
        .verbose = false,
        .edit = false,
        .positional = .{ .title = "Waiting Task" },
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

    const task_id = extractTaskId(fs.getStdout()) orelse return error.TaskIdNotFound;

    const task = try readAndParseTask(fs, task_id, .waiting);

    try testing.expectEqual(gila.Status.waiting, task.status);
    const waiting_on = task.waiting_on orelse return error.ExpectedWaitingOn;
    try testing.expectEqual(@as(usize, 2), waiting_on.len);
    try testing.expectEqualStrings("\"[[base_task_abc]]\"", waiting_on[0]);
    try testing.expectEqualStrings("\"[[base_tasktwo_abc]]\"", waiting_on[1]);
}

test "with blocks transitions blocked task" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    try createTaskFile(fs, "todo", "will_block_abc", "Task To Block", "medium", "", "This task will be blocked\n");
    try createTaskFile(fs, "todo", "will_blocktwo_abc", "Task To Block Two", "medium", "", "This task will be blocked\n");

    var blocks_storage: [2][]const u8 = undefined;
    blocks_storage[0] = "\"[[will_block_abc]]\"";
    blocks_storage[1] = "\"[[will_blocktwo_abc]]\"";

    const cmd: Todo = .{
        .priority = .medium,
        .priority_value = 50,
        .description = null,
        .tags = null,
        .waiting_on = null,
        .blocks = .{ .tasks = &blocks_storage },
        .verbose = false,
        .edit = false,
        .positional = .{ .title = "Blocking Task" },
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

    try expectStdoutContains(fs, "New task created:");
    const task_id = extractTaskId(fs.getStdout()) orelse return error.TaskIdNotFound;
    var buffer: [64]u8 = undefined;
    const task_name = std.fmt.bufPrint(&buffer, "\"[[{s}]]\"", .{task_id}) catch unreachable;

    try testing.expect(fs.dirExists(".gila/waiting/will_block_abc"));
    try testing.expect(!fs.dirExists(".gila/todo/will_block_abc"));

    const blocked_task = try readAndParseTask(fs, "will_block_abc", .waiting);
    try testing.expectEqual(gila.Status.waiting, blocked_task.status);
    const waiting_on = blocked_task.waiting_on orelse return error.ExpectedWaitingOn;
    try testing.expectEqual(1, waiting_on.len);
    try testing.expectEqualStrings(task_name, waiting_on[0]);

    const blocked_task_two = try readAndParseTask(fs, "will_blocktwo_abc", .waiting);
    try testing.expectEqual(gila.Status.waiting, blocked_task_two.status);
    const waiting_on_two = blocked_task_two.waiting_on orelse return error.ExpectedWaitingOn;
    try testing.expectEqual(1, waiting_on_two.len);
    try testing.expectEqualStrings(task_name, waiting_on_two[0]);
}

test "no gila directory" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    const cmd: Todo = .{
        .priority = .medium,
        .priority_value = 50,
        .description = null,
        .tags = null,
        .waiting_on = null,
        .blocks = null,
        .verbose = false,
        .edit = false,
        .positional = .{ .title = "Test Task" },
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
