const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const root = @import("root");

const log = std.log.scoped(.gila);

const gila = @import("gila");
const stdx = @import("stdx");

const common = @import("common.zig");

priority: gila.Priority = .medium,
priority_value: u8 = 50,
description: ?[]const u8 = null,
verbose: bool = false,
positional: struct {
    title: []const u8,
},

pub const help =
    \\Usage:
    \\
    \\    gila add [--priority=low|medium|high|urgent] [--priority-value=<value>] 
    \\              [--description=<description>] [--verbose] <title>
    \\
    \\Adds a new task to the current project.
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
    \\
    \\        The description of the task.
    \\
    \\    --verbose 
    \\        Run verbosely. Prints the contents of the task description file to stdout.
    \\
    \\    <title>
    \\        The title of the task.
    \\
    \\Examples:
    \\    gila add --priority=low --priority-value=50 --description="This is a description" 'Title of the task'
    \\    gila add --priority-value=200 'Title of the task'
    \\
;

pub fn execute(self: @This(), arena: *stdx.Arena) void {
    const allocator = arena.allocator();
    if (!self.verbose) {
        root.log_level = .warn;
    }

    const pwd: []const u8 = std.process.getCwdAlloc(allocator) catch |err| {
        log.err("Failed to get current directory: {s}", .{@errorName(err)});
        return;
    };
    const gila_dir_name = common.searchForGilaDir(pwd) orelse return;

    const task_id: gila.TaskId = gila.TaskId.new(allocator) catch |err| {
        log.err("Failed to get user environment variable: {s}", .{@errorName(err)});
        return;
    };
    const task_name = std.fmt.allocPrint(allocator, "{f}", .{
        task_id,
    }) catch |err| {
        log.err("Failed to allocate task name: {s}", .{@errorName(err)});
        return;
    };

    const description_file = self.createDescrptionFile(allocator, gila_dir_name, task_name) orelse return;
    defer description_file.close();
    log.info("Successfully created description.md file", .{});

    var buffer: [4096]u8 = undefined;
    var writer = description_file.writer(&buffer);
    const interface: *std.Io.Writer = &writer.interface;

    interface.print(gila.description_header_template, .{
        self.positional.title,
        @tagName(.todo),
        @tagName(self.priority),
        self.priority_value,
        task_id.user_name,
        task_id.date_time,
    }) catch |err| {
        log.err("Failed to write to description.md: {s}", .{@errorName(err)});
        return;
    };
    interface.print(gila.seperator ++ "\n", .{}) catch |err| {
        log.err("Failed to write to description.md: {s}", .{@errorName(err)});
        return;
    };

    if (self.description) |description| {
        interface.print(gila.description_body_template, .{description}) catch |err| {
            log.err("Failed to write to description.md: {s}", .{@errorName(err)});
            return;
        };
    } else {
        interface.print(gila.description_body_template, .{""}) catch |err| {
            log.err("Failed to write to description.md: {s}", .{@errorName(err)});
            return;
        };
    }

    // @IMPORTANT I never forget to flush
    interface.flush() catch |err| {
        log.err("Failed to flush description.md: {s}", .{@errorName(err)});
        return;
    };

    description_file.sync() catch |err| {
        log.err("Failed to sync description.md: {s}", .{@errorName(err)});
        return;
    };
    log.info("Successfully written template to description.md", .{});

    // @TODO make the default editor configurable
    const editor_name = std.process.getEnvVarOwned(allocator, "EDITOR") catch "vim";

    const file_name = std.fmt.allocPrint(allocator, "{s}/.gila/todo/{s}/description.md", .{ gila_dir_name, task_name }) catch unreachable;
    var editor = std.process.Child.init(&.{ editor_name, "+", file_name }, std.heap.page_allocator);

    editor.spawn() catch |err| {
        log.err("Failed to spawn editor {s}: {s}", .{ editor_name, @errorName(err) });
        return;
    };

    log.info("Opened editor {s} at {f}", .{ editor_name, stdx.DateTimeUTC.now() });
    _ = editor.wait() catch |err| {
        log.err("Failed to open editor: {s}", .{@errorName(err)});
        return;
    };

    var stdout = std.fs.File.stdout().writer(&.{});
    stdout.interface.print("New task created at: {s}/.gila/todo/{s}/description.md\n", .{ gila_dir_name, task_name }) catch unreachable;
    return;
}

fn createDescrptionFile(self: @This(), allocator: std.mem.Allocator, current_dir: []const u8, task_name: []const u8) ?std.fs.File {
    const base_name = std.fs.path.join(allocator, &.{ current_dir, gila.dir_name }) catch |err| {
        log.err("Unexpected error while joining {s}/{s}: {s}", .{ current_dir, gila.dir_name, @errorName(err) });
        return null;
    };

    var gila_dir = std.fs.openDirAbsolute(base_name, .{}) catch |err| {
        log.err("Failed to open .gila directory {s}: {s}", .{ base_name, @errorName(err) });
        return null;
    };

    defer gila_dir.close();

    const task_dir_name = std.fs.path.join(allocator, &.{ "todo", task_name }) catch |err| {
        log.err("Unexpected error while joining todo/{s}: {s}", .{ task_name, @errorName(err) });
        return null;
    };

    const result = gila_dir.makePathStatus(task_dir_name) catch |err| {
        log.err("Failed to create task directory {s}: {s}", .{ task_name, @errorName(err) });
        return null;
    };

    if (result == .existed) {
        log.err("Task {s} already exists. If you want to create a new task you can wait for 1 second and try again.", .{task_name});
        return null;
    }
    log.info("Successfully created task directory {s}", .{task_name});

    var task_dir = gila_dir.openDir(task_dir_name, .{}) catch |err| {
        log.err("Failed to open task {s}/{s}: {s}", .{ base_name, task_dir_name, @errorName(err) });
        return null;
    };
    defer task_dir.close();

    const description_file = task_dir.createFile("description.md", .{ .read = self.verbose }) catch |err| {
        log.err("Failed to create description.md file: {s}", .{@errorName(err)});
        return null;
    };
    return description_file;
}
