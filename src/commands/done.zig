const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const root = @import("root");

const log = std.log.scoped(.gila);

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

pub fn execute(self: Done, arena: *stdx.Arena) void {
    const allocator = arena.allocator();
    if (!self.verbose) {
        root.log_level = .warn;
    }
    if (!gila.TaskId.isValidFormat(self.positional.task)) {
        log.err("Invalid task_id `{s}` a task is of the form YYYYMMDD_HHMMSS_username", .{self.positional.task});
        return;
    }

    const pwd: []const u8 = std.process.getCwdAlloc(allocator) catch |err| {
        log.err("Failed to get current directory: {s}", .{@errorName(err)});
        return;
    };
    const gila_path = std.fs.path.join(allocator, &.{ common.searchForGilaDir(pwd) orelse return, gila.dir_name }) catch unreachable;

    var gila_dir = std.fs.openDirAbsolute(gila_path, .{}) catch |err| {
        log.err("Failed to open .gila directory {s}: {s}", .{ gila_path, @errorName(err) });
        return;
    };
    defer gila_dir.close();
    log.info("Opened gila directory {s}", .{gila_path});

    const result = gila.Task.find(allocator, self.positional.task, gila_dir) catch return;

    var file = result.file orelse {
        log.err("Task {s} does not exist in gila directory {s}", .{ self.positional.task, gila_path });
        return;
    };

    if (result.status == .done) {
        log.err("Task {s} found in the done directory.", .{self.positional.task});
        log.debug("TODO: Check if the task status in the file is actually done. Since that is the source of truth", .{});
        return;
    }
    if (result.status == .cancelled) {
        log.debug("TODO: What to do when a task is cancelled?", .{});
        return;
    }
    if (result.status == .waiting) {
        log.debug("TODO: Check if all the tasks that this task are waiting on are done.", .{});
        return;
    }

    const buffer = read_all: {
        const size = file.getEndPos() catch |err| {
            log.err("Failed to get file size: {s}", .{@errorName(err)});
            return;
        };
        log.debug("File size: {any}", .{size});

        const buffer = arena.pushArray(u8, size);

        file.seekTo(0) catch |err| {
            log.err("Failed to seek to start of file: {s}", .{@errorName(err)});
            return;
        };
        const read_size = file.preadAll(buffer, 0) catch |err| {
            log.err("Failed to read file: {s}", .{@errorName(err)});
            return;
        };
        assert(read_size == size);
        break :read_all buffer;
    };
    log.info("Read description file contents: {d} bytes", .{buffer.len});
    file.close();

    var task: gila.Task = undefined;
    var error_out: ?[]const u8 = null;
    task.parse(allocator, buffer, &error_out) catch {
        log.err("Failed to parse task description file {s}: {s}", .{ self.positional.task, error_out.? });
        return;
    };

    if (task.status.capacity == 0) {
        log.err("Malformed task description: status property is empty in the task file {s}", .{self.positional.task});
        return;
    }
    if (task.completed != null) {
        log.err("Unexpected completed property in a task that is not completed in task file {s}/{s}", .{
            gila_path,
            self.positional.task,
        });
        return;
    }
    log.info("Successfully parsed task description file contents", .{});

    const done_text = "done";
    if (task.status.capacity >= done_text.len) {
        @memcpy(task.status.data[0..done_text.len], done_text);
        task.status.data = task.status.data[0..done_text.len];
    } else {
        task.status.data = arena.pushArray(u8, done_text.len);
        @memcpy(task.status.data, done_text);
    }

    var completed_buffer: [32]u8 = undefined;
    task.completed = .{
        .data = std.fmt.bufPrint(&completed_buffer, "{f}", .{stdx.DateTimeUTC.now().as(.@"YYYY-MM-DDTHH:MM:SSZ")}) catch unreachable,
        .capacity = 32,
    };

    common.moveTaskData(allocator, gila_dir, self.positional.task, result.status, gila.Status.done) catch return;

    var task_file_buffer: [32]u8 = undefined;
    const task_file_name = std.fmt.bufPrint(&task_file_buffer, "{s}.md", .{self.positional.task}) catch unreachable;

    const done_file_name = std.fs.path.join(allocator, &.{ "done", self.positional.task, task_file_name }) catch |err| {
        log.err("Unexpected error while joining done/{s}: {s}", .{ self.positional.task, @errorName(err) });
        return;
    };

    const done_file = gila_dir.openFile(done_file_name, .{ .mode = .write_only }) catch |err| {
        log.err("Failed to open done file {s}: {s}", .{ done_file_name, @errorName(err) });
        return;
    };
    defer done_file.close();

    var write_buffer: [4096]u8 align(16) = undefined;
    var file_writer = done_file.writer(&write_buffer);
    const writer = &file_writer.interface;

    writer.print("{f}", .{task}) catch |err| {
        log.err("Failed to write to {s}.md: {s}", .{ self.positional.task, @errorName(err) });
        return;
    };

    // @IMPORTANT I never forget to flush
    writer.flush() catch |err| {
        log.err("Failed to flush {s}.md: {s}", .{ self.positional.task, @errorName(err) });
        return;
    };
    done_file.sync() catch |err| {
        log.err("Failed to sync {s}.md: {s}", .{ self.positional.task, @errorName(err) });
        return;
    };

    var stdout = std.fs.File.stdout().writer(&.{});
    stdout.interface.print("Successfully completed task {s}. Good job buddy!\n", .{self.positional.task}) catch unreachable;

    if (self.edit) {
        const file_name = std.fs.path.join(allocator, &.{ gila_path, done_file_name }) catch |err| {
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
