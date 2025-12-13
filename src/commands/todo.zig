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
tags: ?Tags = null,
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

const Tags = struct {
    tags: []const []const u8,

    pub fn parseFlagValue(gpa: std.mem.Allocator, flag_value: []const u8, error_out: *?[]const u8) error{Invalid}!@This() {
        if (flag_value.len == 0) {
            error_out.* = "Empty tag list";
            return error.Invalid;
        }
        const illegal_characters = "\r\n\t";
        const illegal_char = std.mem.findAny(u8, flag_value, illegal_characters);
        if (illegal_char) |_| {
            error_out.* = "Tag list cannot contain any of '" ++ illegal_characters ++ "'";
            return error.Invalid;
        }
        const tag_count: usize = std.mem.countScalar(u8, flag_value, ',');
        var tags = std.mem.splitScalar(u8, flag_value, ',');
        const tag_list = gpa.alloc([]const u8, tag_count + 1) catch {
            error_out.* = "Failed to allocate tag list";
            return error.Invalid;
        };
        errdefer gpa.free(tag_list);

        for (0..tag_count + 1) |index| {
            const tag = tags.next().?;
            if (tag.len == 0) {
                error_out.* = "Empty tag in list";
                return error.Invalid;
            }
            tag_list[index] = tag;
        }
        return .{
            .tags = tag_list,
        };
    }
};

pub fn execute(self: Todo, arena: *stdx.Arena) void {
    const allocator = arena.allocator();
    if (!self.verbose) {
        root.log_level = .warn;
    }
    if (!validateTitle(self.positional.title)) {
        return;
    }

    const pwd: []const u8 = std.process.getCwdAlloc(allocator) catch |err| {
        log.err("Failed to get current directory: {s}", .{@errorName(err)});
        return;
    };
    log.debug("Current directory: {s}", .{pwd});
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
    log.debug("Generated task_id: {s}", .{task_name});

    const description_file = self.createTodoDescrptionFile(allocator, gila_dir_name, task_name) orelse return;
    defer description_file.close();

    var buffer: [4096]u8 = undefined;
    var writer = description_file.writer(&buffer);
    const interface: *std.Io.Writer = &writer.interface;

    interface.print(gila.description_header_template, .{
        self.positional.title,
        @tagName(.todo),
        @tagName(self.priority),
        self.priority_value,
        task_id.user_name,
        task_id.date_time.as(.@"YYYY-MM-DDTHH:MM:SSZ"),
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
        const file_name = std.fs.path.join(allocator, &.{ gila_dir_name, ".gila", "todo", task_name, task_file_name }) catch |err| {
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
    stdout.interface.print("New task created at: {s}/.gila/todo/{s}/{s}.md\n", .{ gila_dir_name, task_name, task_name }) catch unreachable;
    return;
}

// @TODO this is probably a common functionality
fn createTodoDescrptionFile(self: Todo, allocator: std.mem.Allocator, current_dir: []const u8, task_name: []const u8) ?std.fs.File {
    const base_name = std.fs.path.join(allocator, &.{ current_dir, gila.dir_name }) catch |err| {
        log.err("Unexpected error while joining {s}/{s}: {s}", .{ current_dir, gila.dir_name, @errorName(err) });
        return null;
    };
    var gila_dir = std.fs.openDirAbsolute(base_name, .{}) catch |err| {
        log.err("Failed to open .gila directory {s}: {s}", .{ base_name, @errorName(err) });
        return null;
    };
    defer gila_dir.close();
    log.info("Opened gila directory {s}", .{base_name});

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
    log.info("Successfully created task directory todo/{s}", .{task_name});

    var task_dir = gila_dir.openDir(task_dir_name, .{}) catch |err| {
        log.err("Failed to open task {s}/{s}: {s}", .{ base_name, task_dir_name, @errorName(err) });
        return null;
    };
    defer task_dir.close();
    log.debug("Opened task directory {s}", .{task_dir_name});

    var buffer: [1024]u8 = undefined;
    const file_name = std.fmt.bufPrint(&buffer, "{s}.md", .{task_name}) catch |err| {
        log.err("Unexpectedly failed to create name for task {s}: {s}", .{ task_name, @errorName(err) });
        return null;
    };

    const description_file = task_dir.createFile(file_name, .{ .read = self.verbose }) catch |err| {
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
    const invalid_char = std.mem.findAny(u8, title, "\r\n");

    if (invalid_char) |index| {
        log.err("Title cannot contain {c} at index {d}", .{ title[index], index });
        return false;
    }
    return true;
}
