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
verbose: bool = false,
edit: bool = false,
positional: struct {
    title: []const u8,
},

pub const help =
    \\Usage:
    \\
    \\    gila todo [--priority=low|medium|high|urgent] [--priority-value=<integer value>] 
    \\              [--description=<description>] [--tags="<tag1>,<tag2>,..."] [--verbose] 
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
    \\
    \\        The description of the task.
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

pub fn execute(self: Todo, arena: *stdx.Arena) void {
    const allocator = arena.allocator();
    if (!self.verbose) {
        root.log_level = .warn;
    }
    if (!validateTitle(self.positional.title)) {
        return;
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
    const date_time = stdx.DateTimeUTC.now();

    const description_file = createNewDescription(allocator, task_name, gila_dir) orelse return;
    defer description_file.close();

    var buffer: [4096]u8 = undefined;
    var writer = description_file.writer(&buffer);
    const interface: *std.Io.Writer = &writer.interface;

    interface.print(gila.description_header_template, .{
        self.positional.title,
        @tagName(.todo),
        @tagName(self.priority),
        self.priority_value,
        user_name,
        date_time.as(.@"YYYY-MM-DDTHH:MM:SSZ"),
    }) catch |err| {
        log.err("Failed to write to {s}.md: {s}", .{ task_name, @errorName(err) });
        return;
    };

    if (self.tags) |tags| {
        interface.writeAll(gila.description_tags_template) catch |err| {
            log.err("Failed to write to {s}.md: {s}", .{ task_name, @errorName(err) });
            return;
        };
        for (tags.tags) |tag| {
            interface.print("- {s}\n", .{tag}) catch |err| {
                log.err("Failed to write to {s}.md: {s}", .{ task_name, @errorName(err) });
                return;
            };
        }
    }

    interface.print(gila.seperator ++ "\n", .{}) catch |err| {
        log.err("Failed to write to {s}.md: {s}", .{ task_name, @errorName(err) });
        return;
    };

    if (self.description) |description| {
        interface.print(gila.description_body_template, .{description}) catch |err| {
            log.err("Failed to write to {s}.md: {s}", .{ task_name, @errorName(err) });
            return;
        };
    } else {
        interface.print(gila.description_body_template, .{""}) catch |err| {
            log.err("Failed to write to {s}.md: {s}", .{ task_name, @errorName(err) });
            return;
        };
    }

    // @IMPORTANT I never forget to flush
    interface.flush() catch |err| {
        log.err("Failed to flush {s}.md: {s}", .{ task_name, @errorName(err) });
        return;
    };

    description_file.sync() catch |err| {
        log.err("Failed to sync {s}.md: {s}", .{ task_name, @errorName(err) });
        return;
    };
    log.info("Successfully written template to {s}.md", .{task_name});

    // @TODO make the default editor configurable
    if (self.edit) {
        const editor_name = std.process.getEnvVarOwned(allocator, "EDITOR") catch "vim";
        var md_file_writer = std.Io.Writer.fixed(&buffer);
        md_file_writer.print("{s}.md", .{task_name}) catch unreachable;
        const task_file_name = md_file_writer.buffered();
        const file_name = std.fs.path.join(allocator, &.{ gila_path, "todo", task_name, task_file_name }) catch |err| {
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

// @TODO this is probably a common functionality
fn createNewDescription(allocator: std.mem.Allocator, task_name: []const u8, gila_dir: std.fs.Dir) ?std.fs.File {
    const task_dir_name = std.fs.path.join(allocator, &.{ @tagName(gila.Status.todo), task_name }) catch |err| {
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
    log.info("Successfully created task directory todo/{s}", .{task_name});

    var task_dir = gila_dir.openDir(task_dir_name, .{}) catch |err| {
        log.err("Failed to open task {s}: {s}", .{ task_dir_name, @errorName(err) });
        return null;
    };
    defer task_dir.close();
    log.debug("Opened task directory {s}", .{task_dir_name});

    var buffer: [32]u8 = undefined;
    const file_name = std.fmt.bufPrint(&buffer, "{s}.md", .{task_name}) catch unreachable;

    const description_file = task_dir.createFile(file_name, .{}) catch |err| {
        log.err("Failed to create {s}.md file: {s}", .{ task_name, @errorName(err) });
        return null;
    };
    log.info("Successfully created description file {s}", .{file_name});
    return description_file;
}

fn validateTitle(title: []const u8) bool {
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
