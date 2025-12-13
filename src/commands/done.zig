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

    const result = common.Task.find(allocator, self.positional.task, gila_dir) catch return;

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
    }
    if (result.status == .waiting) {
        log.debug("TODO: Check if all the tasks that this task are waiting on are done.", .{});
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

    const split_result = splitTaskDescription(buffer, gila_path, self.positional.task) orelse return;

    var completed_buffer: [1024]u8 = undefined;
    const parts = compute_parts: {
        const prefix = buffer[0..split_result.prefix_end];
        const before_completed = buffer[split_result.prefix_end + split_result.status_end ..][0..split_result.completed_location];
        const suffix = buffer[split_result.prefix_end + split_result.status_end + split_result.completed_location ..];

        var status = buffer[split_result.prefix_end..][0..split_result.status_end];
        const done_text = "done";
        if (status.len >= done_text.len) {
            @memcpy(status[0..done_text.len], done_text);
            status = status[0..done_text.len];
        } else {
            status = arena.pushArray(u8, done_text.len);
            @memcpy(status, done_text);
        }

        var completed_writer = std.Io.Writer.fixed(&completed_buffer);
        completed_writer.writeAll("completed: ") catch |err| {
            log.err("Unexpected error while building completed property: {s}", .{@errorName(err)});
            return;
        };
        completed_writer.print("{f}\n", .{stdx.DateTimeUTC.now().as(.@"YYYY-MM-DDTHH:MM:SSZ")}) catch |err| {
            log.err("Unexpected error while building completed property: {s}", .{@errorName(err)});
            return;
        };
        const completed = completed_writer.buffered();
        break :compute_parts [_][]const u8{ prefix, status, before_completed, completed, suffix };
    };
    log.info("Successfully parsed task description file contents", .{});

    moveTaskData(allocator, &gila_dir, self.positional.task, result.status, gila.Status.done) catch return;

    var task_file_buffer: [32]u8 = undefined;
    var md_file_writer = std.Io.Writer.fixed(&task_file_buffer);
    md_file_writer.print("{s}.md", .{self.positional.task}) catch unreachable;
    const task_file_name = md_file_writer.buffered();

    const done_file_name = std.fs.path.join(allocator, &.{ "done", self.positional.task, task_file_name }) catch |err| {
        log.err("Unexpected error while joining done/{s}: {s}", .{ self.positional.task, @errorName(err) });
        return;
    };

    {
        const done_file = gila_dir.openFile(done_file_name, .{ .mode = .write_only }) catch |err| {
            log.err("Failed to open done file {s}: {s}", .{ done_file_name, @errorName(err) });
            return;
        };
        defer done_file.close();

        var write_buffer: [4096]u8 align(16) = undefined;
        var file_writer = done_file.writer(&write_buffer);
        const writer = &file_writer.interface;
        // var writer = std.Io.Writer.fixed(&write_buffer);

        for (&parts) |part| {
            writer.writeAll(part) catch |err| {
                log.err("Failed to write to {s}.md: {s}", .{ self.positional.task, @errorName(err) });
                return;
            };
        }
        // @IMPORTANT I never forget to flush
        writer.flush() catch |err| {
            log.err("Failed to flush {s}.md: {s}", .{ self.positional.task, @errorName(err) });
            return;
        };
        done_file.sync() catch |err| {
            log.err("Failed to sync {s}.md: {s}", .{ self.positional.task, @errorName(err) });
            return;
        };
    }

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

pub fn moveTaskData(allocator: std.mem.Allocator, gila_dir: *std.fs.Dir, task_name: []const u8, from: gila.Status, to: gila.Status) !void {
    const from_folder = std.fs.path.join(allocator, &.{ @tagName(from), task_name }) catch |err| {
        log.err("Unexpected error while joining {s}/{s}: {s}", .{ @tagName(from), task_name, @errorName(err) });
        return;
    };
    const to_folder = std.fs.path.join(allocator, &.{ @tagName(to), task_name }) catch |err| {
        log.err("Unexpected error while joining {s}/{s}: {s}", .{ @tagName(to), task_name, @errorName(err) });
        return;
    };
    gila_dir.rename(from_folder, to_folder) catch |err| {
        log.err("Failed to move task {s} from {s} to {s}: {s}", .{ task_name, @tagName(from), @tagName(to), @errorName(err) });
    };
    log.info("Successfully moved task folder along with all artifacts {s} from {s} to {s}", .{ task_name, @tagName(from), @tagName(to) });
}

const SplitResult = struct {
    prefix_end: usize,
    status_end: usize,
    completed_location: usize,
};
fn splitTaskDescription(file_buffer: []const u8, gila_path: []const u8, task_name: []const u8) ?SplitResult {
    var result: SplitResult = undefined;
    const needle = "status: ";
    result.prefix_end = std.mem.find(u8, file_buffer, needle) orelse {
        log.err("Malformed task description: could not find the status property in the task file {s}", .{task_name});
        return null;
    };
    result.prefix_end += needle.len;

    result.status_end = std.mem.findScalar(u8, file_buffer[result.prefix_end..], '\n') orelse {
        log.err("Malformed task description: could not find the end of the status property in the task file {s}", .{task_name});
        return null;
    };
    if (result.status_end == 0) {
        log.err("Malformed task description: status property is empty in the task file {s}", .{task_name});
        return null;
    }
    const header_end = std.mem.find(u8, file_buffer[result.prefix_end + result.status_end ..], gila.seperator) orelse {
        log.err("Malformed task description: Cound not find header end separator {s} in the task file {s}", .{ gila.seperator, task_name });
        return null;
    };
    const remaining_header = file_buffer[result.prefix_end + result.status_end ..][0..header_end];

    const completed_start = std.mem.find(u8, remaining_header, "completed: ");
    if (completed_start) |pos| {
        log.err("Unexpected completed property in a task that is not completed in task file {s}/{s}:{d}", .{ gila_path, task_name, pos });
        return null;
    }
    result.completed_location = std.mem.find(u8, remaining_header, "tags: ") orelse header_end;
    return result;
}
