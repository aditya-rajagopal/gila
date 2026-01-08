const std = @import("std");
const testing = std.testing;
const gila = @import("gila");
const stdx = @import("stdx");
// @TODO make this a testfs module
const TestFs = @import("../testfs/root.zig").TestFs;

const Init = @import("init.zig");
const Todo = @import("todo.zig");
const Done = @import("done.zig");
const Sync = @import("sync.zig");
const Find = @import("find.zig");
const common = @import("common.zig");

const Task = gila.Task;

fn initGilaProject(fs: *TestFs) !void {
    try fs.createDir(".gila");
    try fs.createDir(".gila/todo");
}

fn readAndParseTask(fs: *TestFs, task_id: []const u8, status: gila.Status) !Task {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, ".gila/{s}/{s}/{s}.md", .{
        @tagName(status),
        task_id,
        task_id,
    }) catch unreachable;

    var arena_buf: [8192]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    const content = try fs.readFile(path);
    var reader = std.Io.Reader.fixed(content);

    var task = Task.init(task_id) catch return error.InvalidTaskId;
    var diagnostic: ?Task.Diagnostic = null;
    task.fromReader(&reader, &arena, &diagnostic) catch {
        std.debug.print("Task parse error: {s}\n", .{diagnostic.?.message});
        return error.TaskParseError;
    };

    return task;
}

fn validateTask(task: *const Task) !void {
    var error_out: ?[]const u8 = null;
    task.validate(&error_out) catch {
        std.debug.print("Task validation error: {s}\n", .{error_out orelse "unknown"});
        return error.TaskValidationFailed;
    };
}

fn createTaskFile(
    fs: *TestFs,
    status: []const u8,
    task_id: []const u8,
    title: []const u8,
    priority: []const u8,
    extra_fields: []const u8,
    description: []const u8,
) !void {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, ".gila/{s}/{s}/{s}.md", .{ status, task_id, task_id }) catch unreachable;

    var content_buf: [4096]u8 = undefined;
    const content = std.fmt.bufPrint(&content_buf,
        \\---
        \\title: {s}
        \\status: {s}
        \\priority_value: 50
        \\priority: {s}
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\{s}---
        \\{s}
    , .{ title, status, priority, extra_fields, description }) catch unreachable;

    try fs.createFile(path, content);
}

fn expectStdoutContains(fs: *TestFs, expected: []const u8) !void {
    const stdout = fs.getStdout();
    if (std.mem.indexOf(u8, stdout, expected) == null) {
        std.debug.print("\nExpected stdout to contain: '{s}'\nActual stdout: '{s}'\n", .{ expected, stdout });
        return error.TestExpectationFailed;
    }
}

fn extractTaskId(stdout: []const u8) ?[]const u8 {
    const prefix = "New task created: ";
    const start = std.mem.indexOf(u8, stdout, prefix) orelse return null;
    const id_start = start + prefix.len;
    const end = std.mem.indexOfPos(u8, stdout, id_start, "\n") orelse return null;
    return stdout[id_start..end];
}

test "init: creates gila directory" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    const cmd: Init = .{
        .bare = false,
        .verbose = false,
        .positional = .{ .directory = null },
    };

    var arena_buffer: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buffer);

    cmd.execute(fs.io(), &arena);

    try testing.expect(fs.dirExists(".gila"));
    try testing.expect(fs.dirExists(".gila/todo"));
    try std.testing.expectEqualStrings("Initialized GILA project: /home/test/.gila\n", fs.getStdout());
}

test "init: bare mode" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    const cmd: Init = .{
        .bare = true,
        .verbose = false,
        .positional = .{ .directory = null },
    };

    var arena_buffer: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buffer);

    cmd.execute(fs.io(), &arena);

    try testing.expect(fs.dirExists(".gila"));
    try testing.expect(!fs.dirExists(".gila/todo"));
    try std.testing.expectEqualStrings("Initialized GILA project: /home/test/.gila\n", fs.getStdout());
}

test "init: already exists" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try fs.createDir(".gila");

    const cmd: Init = .{
        .bare = false,
        .verbose = false,
        .positional = .{ .directory = null },
    };

    var arena_buffer: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buffer);

    cmd.execute(fs.io(), &arena);

    const stdout = fs.getStdout();
    try std.testing.expectEqual(0, stdout.len);
}

test "init: directory" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    const cmd: Init = .{
        .bare = false,
        .verbose = false,
        .positional = .{ .directory = "/home" },
    };
    var arena_buffer: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buffer);

    cmd.execute(fs.io(), &arena);

    try testing.expect(fs.dirExists("/home/.gila"));
    try testing.expect(fs.dirExists("/home/.gila/todo"));

    try std.testing.expectEqualStrings("Initialized GILA project: /home/.gila\n", fs.getStdout());
}

test "todo: basic task creation" {
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

    cmd.execute(fs.io(), &arena);

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

test "todo: with waiting_on creates waiting task" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    try createTaskFile(fs, "todo", "base_task_abc", "Base Task", "medium", "", "Base task description\n");
    try createTaskFile(fs, "todo", "base_tasktwo_abc", "Base Task Two", "medium", "", "Base task two description\n");

    var waiting_on_storage: [2][]const u8 = undefined;
    waiting_on_storage[0] = "\"[[base_task_abc]]\"";
    waiting_on_storage[1] = "\"[[base_tasktwo_abc]]\"";

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

    cmd.execute(fs.io(), &arena);

    const task_id = extractTaskId(fs.getStdout()) orelse return error.TaskIdNotFound;

    const task = try readAndParseTask(fs, task_id, .waiting);

    try testing.expectEqual(gila.Status.waiting, task.status);
    const waiting_on = task.waiting_on orelse return error.ExpectedWaitingOn;
    try testing.expectEqual(@as(usize, 2), waiting_on.len);
    try testing.expectEqualStrings("\"[[base_task_abc]]\"", waiting_on[0]);
    try testing.expectEqualStrings("\"[[base_tasktwo_abc]]\"", waiting_on[1]);
}

test "todo: with blocks transitions blocked task" {
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

    cmd.execute(fs.io(), &arena);

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

test "todo: no gila directory" {
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

    cmd.execute(fs.io(), &arena);

    const stdout = fs.getStdout();
    try testing.expectEqual(0, stdout.len);
    // @TODO figure out a way to intercept stderr for the log messages
}

test "done: marks todo task as done" {
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

    cmd.execute(fs.io(), &arena);

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

test "done: invalid task id" {
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

    cmd.execute(fs.io(), &arena);

    const stdout = fs.getStdout();
    try testing.expectEqual(0, stdout.len);
    // @TODO figure out a way to intercept stderr for the log messages
}

test "done: already done task" {
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

    cmd.execute(fs.io(), &arena);

    const stdout = fs.getStdout();
    try testing.expect(std.mem.indexOf(u8, stdout, "Successfully completed task") == null);
}

test "done: task with waiting_on" {
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

    cmd.execute(fs.io(), &arena);

    const stdout = fs.getStdout();
    try testing.expect(std.mem.indexOf(u8, stdout, "Successfully completed task") == null);
}

test "done: preserves custom frontmatter" {
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

    cmd.execute(fs.io(), &arena);

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

test "sync: file status overrides folder" {
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

    cmd.execute(fs.io(), &arena);

    try testing.expect(!fs.dirExists(".gila/todo/misplaced_tsk_abc"));
    try testing.expect(fs.dirExists(".gila/started/misplaced_tsk_abc"));

    const task = try readAndParseTask(fs, "misplaced_tsk_abc", .started);
    try validateTask(&task);
    try testing.expectEqual(gila.Status.started, task.status);

    try expectStdoutContains(fs, "Moved misplaced_tsk_abc:");
}

test "sync: waiting task with done deps" {
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

    cmd.execute(fs.io(), &arena);

    try testing.expect(!fs.dirExists(".gila/waiting/wait_task_abc"));
    try testing.expect(fs.dirExists(".gila/todo/wait_task_abc"));

    const task = try readAndParseTask(fs, "wait_task_abc", .todo);
    try validateTask(&task);
    try testing.expectEqual(gila.Status.todo, task.status);
    try testing.expect(task.waiting_on == null);
}

test "sync: multiple transitions" {
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

    cmd.execute(fs.io(), &arena);

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

test "sync: no changes needed" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    try createTaskFile(fs, "todo", "correct_tsk_abc", "Correct Task", "medium", "", "Properly placed\n");

    const cmd: Sync = .{
        .verbose = false,
    };

    var arena_buffer: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buffer);

    cmd.execute(fs.io(), &arena);

    const stdout = fs.getStdout();
    try testing.expect(std.mem.indexOf(u8, stdout, "Moved") == null);
}

test "sync: waiting task all deps done" {
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

    cmd.execute(fs.io(), &arena);

    try testing.expect(!fs.dirExists(".gila/waiting/multi_wait_abc"));
    try testing.expect(fs.dirExists(".gila/todo/multi_wait_abc"));
}

test "sync: preserves custom frontmatter" {
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

    cmd.execute(fs.io(), &arena);

    try testing.expect(fs.dirExists(".gila/started/custom_syn_abc"));

    const task = try readAndParseTask(fs, "custom_syn_abc", .started);
    try validateTask(&task);
    try testing.expectEqual(gila.Status.started, task.status);

    const extra_lines = task.extra_lines orelse return error.ExpectedExtraLines;
    try testing.expect(extra_lines.len > 0);

    const result = try fs.readFile(".gila/started/custom_syn_abc/custom_syn_abc.md");
    try testing.expect(std.mem.indexOf(u8, result, "my_custom_field: some value") != null);
    try testing.expect(std.mem.indexOf(u8, result, "another_field:") != null);
    try testing.expect(std.mem.indexOf(u8, result, "- item1") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Unstructured data line") != null);
}

test "find: by priority" {
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

test "find: by tags with or" {
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

test "find: by tags with and" {
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

test "find: no matches" {
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

test "workflow: init -> todo -> done" {
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

test "workflow: waiting dependency chain" {
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
