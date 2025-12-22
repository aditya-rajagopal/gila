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
waiting_on: ?common.WaitingOn = null,
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
    \\              [--waiting-on="<task1>,<task2>,..."] [--verbose]
    \\              [--edit] <title>
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

pub fn execute(self: Todo, io: std.Io, arena: *stdx.Arena) void {
    _ = io;
    const allocator = arena.allocator();
    if (!self.verbose) {
        root.log_level = .warn;
    }

    const gila_path, var gila_dir = common.getGilaDir(allocator) orelse return;
    defer gila_dir.close();

    const task_name = gila.id.new(allocator) catch |err| {
        log.err("Failed to get create task id: {s}", .{@errorName(err)});
        return;
    };
    log.debug("Generated task_id: {s}", .{task_name});

    const user_name = common.getUserName(allocator) catch |err| {
        log.err("Failed to get user name: {s}", .{@errorName(err)});
        return;
    };
    const creation_dt = stdx.DateTimeUTC.now();

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
        .waiting_on = if (self.waiting_on) |waiting_on| waiting_on.tasks else null,
        .completed = null,
        .extra_lines = null,
    };

    var error_out: ?[]const u8 = null;
    task.validate(&error_out) catch {
        log.err("Failed to validate task description file {s}: {s}", .{ task_name, error_out.? });
        return;
    };

    const description_file = task.toTaskFile(true, arena, gila_dir) catch return;

    // @TODO make the default editor configurable
    if (self.edit) {
        const editor_name = std.process.getEnvVarOwned(allocator, "EDITOR") catch "vim";

        const file_name = std.fs.path.join(allocator, &.{ gila_path, description_file }) catch |err| {
            log.err("Unexpected error while joining path: {s}", .{@errorName(err)});
            return;
        };
        var editor = std.process.Child.init(&.{ editor_name, "+", file_name }, std.heap.page_allocator);
        editor.spawn() catch |err| {
            log.err("Failed to spawn editor {s}: {s}", .{ editor_name, @errorName(err) });
            return;
        };
        log.debug("Opened editor {s} at {f}", .{ editor_name, stdx.DateTimeUTC.now() });
        const exit_code = editor.wait() catch |err| {
            log.err("Failed to open editor: {s}", .{@errorName(err)});
            return;
        };
        log.debug("Editor exited with code {any} at {f}", .{ exit_code, stdx.DateTimeUTC.now() });
    }

    var stdout = std.fs.File.stdout().writer(&.{});
    stdout.interface.print("New task created: {s}\n", .{task_name}) catch unreachable;
    return;
}
