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

pub fn execute(self: Done, io: std.Io, arena: *stdx.Arena) void {
    const allocator = arena.allocator();
    if (!self.verbose) {
        root.log_level = .warn;
    }
    if (!gila.id.isValid(self.positional.task)) {
        log.err("Invalid task_id `{s}` a task is of the form word_word_ccc", .{self.positional.task});
        return;
    }

    const gila_path, var gila_dir = common.getGilaDir(allocator) orelse return;
    defer gila_dir.close();

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

    common.moveTaskData(allocator, gila_dir, self.positional.task, result.status, task.status) catch return;

    const file_path = task.toTaskFile(false, arena, gila_dir) catch return;

    var stdout = std.fs.File.stdout().writer(&.{});
    stdout.interface.print("Successfully completed task {s}. Great success!\n", .{self.positional.task}) catch unreachable;

    if (self.edit) {
        const file_name = std.fs.path.join(allocator, &.{ gila_path, file_path }) catch |err| {
            log.err("Unexpected error while joining done/{s}: {s}", .{ self.positional.task, @errorName(err) });
            return;
        };

        log.debug("File path for editor: {s}", .{file_name});
        // @TODO make the default editor configurable
        const editor_name = std.process.getEnvVarOwned(allocator, "EDITOR") catch "vim";
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
}
