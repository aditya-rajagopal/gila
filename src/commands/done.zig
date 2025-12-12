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
positional: struct {
    task: []const u8,
},

pub const help =
    \\Usage:
    \\
    \\    gila done [-h | --help] <task_id>
    \\
    \\Marks a task as done copies it to the done directory and then deletes it from the todo directory.
    \\TODO: Move all the artifacts to the done directory.
    \\
    \\Options:
    \\    -h, --help
    \\        Prints this help message.
    \\
    \\Examples:
    \\    gila done 20225125_120000_username
    \\
;

pub fn execute(self: Done, arena: *stdx.Arena) void {
    const allocator = arena.allocator();
    if (!self.verbose) {
        root.log_level = .warn;
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

    const task_id = gila.TaskId.fromString(self.positional.task) catch |err| {
        log.err("Failed to parse task_id: {s}", .{@errorName(err)});
        return;
    };
    _ = task_id;

    const result = common.Task.find(allocator, self.positional.task, gila_dir) catch return;

    var file = result.file orelse {
        log.err("Task {s} does not exist in gila directory {s}", .{ self.positional.task, gila_path });
        return;
    };
    defer file.close();

    if (result.status == .done) {
        log.err("Task {s} found in the done directory.", .{self.positional.task});
        log.debug("TODO: Check if the task status in the file is actually done. Since that is the source of truth", .{});
        return;
    }
    if (result.status == .waiting) {
        log.debug("TODO: Check if all the tasks that this task are waiting on are done.", .{});
    }
    if (result.status == .cancelled) {
        log.debug("TODO: What to do when a task is cancelled?", .{});
    }

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
    log.debug("Read file contents: \n{s}", .{buffer});

    const needle = "status: ";
    const position = std.mem.find(u8, buffer, needle) orelse {
        log.err("Malformed task description: could not find the status property in the task file {s}", .{self.positional.task});
        return;
    };
    const prefix = buffer[0 .. position + needle.len];
    log.debug("Prefix: \n{s}", .{prefix});
    const suffix_start = std.mem.findScalar(u8, buffer[position + needle.len ..], '\n') orelse {
        log.err("Malformed task description: could not find the end of the status property in the task file {s}", .{self.positional.task});
        return;
    };
    if (suffix_start == 0) {
        log.err("Malformed task description: status property is empty in the task file {s}", .{self.positional.task});
        return;
    }
    var status = buffer[position + needle.len ..][0..suffix_start];
    log.debug("Status: '{s}'", .{status});
    const suffix = buffer[position + needle.len + status.len ..];

    const done_text = "done";
    if (status.len >= done_text.len) {
        @memcpy(status[0..done_text.len], done_text);
        status = status[0..done_text.len];
    } else {
        status = arena.pushArray(u8, done_text.len);
        @memcpy(status, done_text);
    }

    const done_file = createDoneDescrptionFile(allocator, self.positional.task, &gila_dir) orelse return;
    defer done_file.close();

    var write_buffer: [4096]u8 align(16) = undefined;
    var file_writer = done_file.writer(&write_buffer);
    const writer = &file_writer.interface;
    writer.writeAll(prefix) catch |err| {
        log.err("Failed to write to {s}.md: {s}", .{ self.positional.task, @errorName(err) });
        return;
    };
    writer.writeAll(status) catch |err| {
        log.err("Failed to write to {s}.md: {s}", .{ self.positional.task, @errorName(err) });
        return;
    };
    writer.writeAll(suffix) catch |err| {
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

    var md_file_writer = std.Io.Writer.fixed(buffer);
    md_file_writer.print("{s}.md", .{self.positional.task}) catch unreachable;
    const task_file_name = md_file_writer.buffered();
    const file_name = std.fs.path.join(allocator, &.{
        gila_path,
        "done",
        self.positional.task,
        task_file_name,
    }) catch |err| {
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

    const sub_path = std.fs.path.join(allocator, &.{ @tagName(result.status), self.positional.task }) catch |err| {
        log.err("Unexpected error while joining {s}/{s}: {s}", .{ @tagName(result.status), self.positional.task, @errorName(err) });
        return;
    };

    gila_dir.deleteTree(sub_path) catch |err| {
        log.err("Failed to delete task {s}: {s}", .{ self.positional.task, @errorName(err) });
        return;
    };
    log.info("successully deleted task {s}/{s}", .{ gila_path, sub_path });
}

// @TODO this is probably a common functionality
fn createDoneDescrptionFile(allocator: std.mem.Allocator, task_name: []const u8, gila_dir: *std.fs.Dir) ?std.fs.File {
    const task_dir_name = std.fs.path.join(allocator, &.{ "done", task_name }) catch |err| {
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
    log.info("Successfully created task directory done/{s}", .{task_name});

    var task_dir = gila_dir.openDir(task_dir_name, .{}) catch |err| {
        log.err("Failed to open task {s}: {s}", .{ task_dir_name, @errorName(err) });
        return null;
    };
    defer task_dir.close();
    log.debug("Opened task directory {s}", .{task_dir_name});

    var buffer: [1024]u8 = undefined;
    const file_name = std.fmt.bufPrint(&buffer, "{s}.md", .{task_name}) catch |err| {
        log.err("Unexpectedly failed to create name for task {s}: {s}", .{ task_name, @errorName(err) });
        return null;
    };

    const description_file = task_dir.createFile(file_name, .{}) catch |err| {
        log.err("Failed to create {s}.md file: {s}", .{ task_name, @errorName(err) });
        return null;
    };
    log.info("Successfully created description file {s}", .{file_name});
    return description_file;
}
