const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const builtin = @import("builtin");

const gila = @import("gila");
const stdx = @import("stdx");
const root = @import("root");

const common = @import("common.zig");

const log = std.log.scoped(.sync);

const Sync = @This();

verbose: bool = false,

pub const help =
    \\Usage:
    \\
    \\    gila sync [-h | --help] [--verbose]
    \\
    \\Synchronizes the tasks in the gila directory by analyzing the tasks and moving them to their appropriate folders
    \\and modifying the necessary properties.
    \\
    \\Options:
    \\    -h, --help
    \\        Prints this help message.
    \\
    \\    --verbose
    \\        Run verbosely.
    \\
;

pub fn execute(self: Sync, arena: *stdx.Arena) void {
    const allocator = arena.allocator();
    if (!self.verbose) {
        root.log_level = .warn;
    }

    _, var gila_dir = common.getGilaDir(allocator) orelse return;
    defer gila_dir.close();

    const fixed_buffer: []u8 = allocator.alloc(u8, 128 * 1024) catch unreachable;
    var local_arena = stdx.Arena.initBuffer(fixed_buffer);

    var done_map = std.StringArrayHashMap(void).init(allocator);

    var dir_n: ?std.fs.Dir = gila_dir.openDir(@tagName(gila.Status.done), .{ .iterate = true }) catch null;
    if (dir_n) |*dir| {
        defer dir.close();

        var dir_walker = dir.iterateAssumeFirstIteration();
        while (dir_walker.next() catch |err| {
            log.err("Failed to iterate over done directory: {s}", .{@errorName(err)});
            return;
        }) |entry| {
            if (entry.kind == .directory) {
                if (gila.id.isValid(entry.name)) {
                    const name = arena.pushString(entry.name);
                    const result = getTaskAndFix(&local_arena, name, gila_dir, gila.Status.done);
                    switch (result) {
                        .err, .moved => {},
                        .ok => done_map.put(name, {}) catch unreachable,
                    }
                    local_arena.reset(false);
                }
            }
        }
    } else {
        std.log.info("Failed to open {s} directory.", .{@tagName(gila.Status.done)});
    }

    dir_n = gila_dir.openDir(@tagName(gila.Status.todo), .{ .iterate = true }) catch null;
    if (dir_n) |*dir| {
        defer dir.close();

        var dir_walker = dir.iterateAssumeFirstIteration();
        while (dir_walker.next() catch |err| {
            log.err("Failed to iterate over done directory: {s}", .{@errorName(err)});
            return;
        }) |entry| {
            if (entry.kind == .directory) {
                if (gila.id.isValid(entry.name)) {
                    const result = getTaskAndFix(&local_arena, entry.name, gila_dir, gila.Status.todo);
                    switch (result) {
                        .err, .ok => {},
                        .moved => |to_state| {
                            switch (to_state) {
                                .done => done_map.put(arena.pushString(entry.name), {}) catch unreachable,
                                else => {},
                            }
                        },
                    }
                    local_arena.reset(false);
                }
            }
        }
    } else {
        std.log.info("Failed to open {s} directory.", .{@tagName(gila.Status.done)});
    }
}

const Result = union(enum) {
    err,
    ok,
    moved: gila.Status,
};

fn getTaskAndFix(arena: *stdx.Arena, task_name: []const u8, gila_dir: std.fs.Dir, folder_state: gila.Status) Result {
    var file_buffer: [64]u8 = undefined;
    const file_name = std.fmt.bufPrint(&file_buffer, "{s}.md", .{task_name}) catch unreachable;
    const file_path = std.fs.path.join(arena.allocator(), &.{ @tagName(folder_state), task_name, file_name }) catch |err| {
        log.err("Unexpected error while joining done/{s}: {s}", .{ task_name, @errorName(err) });
        return .err;
    };

    const file = gila_dir.openFile(file_path, .{}) catch |err| {
        log.err("Failed to open task {s}: {s}", .{ task_name, @errorName(err) });
        return .err;
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        log.err("Failed to stat task {s}: {s}", .{ task_name, @errorName(err) });
        return .err;
    };

    const buffer: []u8 = arena.pushArray(u8, stat.size);
    _ = file.readAll(buffer) catch |err| {
        log.err("Failed to read task {s}: {s}", .{ task_name, @errorName(err) });
        return .err;
    };
    var task: gila.Task = undefined;
    var error_out: ?[]const u8 = null;
    task.parse(arena.allocator(), buffer, &error_out) catch {
        log.err("Failed to parse task description file {s}: {s}", .{ task_name, error_out.? });
        return .err;
    };
    task.validate(&error_out) catch {
        log.err("Failed to validate task description file {s}: {s}", .{ task_name, error_out.? });
        return .err;
    };

    if (!std.mem.eql(u8, task.status.data, @tagName(folder_state))) {
        log.info(
            "Task '{s}' is in the wrong state. Expected '{s}' based on the folder but found '{s}' in the description. The file is taken as the truth.",
            .{ task_name, @tagName(folder_state), task.status.data },
        );
        const to_state = std.meta.stringToEnum(gila.Status, task.status.data) orelse {
            log.err("Invalid status '{s}' in the description file", .{task.status.data});
            return .err;
        };
        task.transition(arena.allocator(), to_state, &error_out) catch {
            log.err("Failed to transition task '{s}' to '{s}': {s}", .{ task_name, @tagName(to_state), error_out.? });
            return .err;
        };

        common.moveTaskData(arena.allocator(), gila_dir, task_name, folder_state, to_state) catch return .err;

        const new_file_name = std.fs.path.join(arena.allocator(), &.{ task.status.data, task_name, file_name }) catch |err| {
            log.err("Unexpected error while joining done/{s}: {s}", .{ task_name, @errorName(err) });
            return .err;
        };

        const new_file = gila_dir.openFile(new_file_name, .{ .mode = .write_only }) catch |err| {
            log.err("Failed to open done file {s}: {s}", .{ new_file_name, @errorName(err) });
            return .err;
        };
        defer new_file.close();
        new_file.setEndPos(0) catch |err| {
            log.err("Failed to set end position of done file {s}: {s}", .{ new_file_name, @errorName(err) });
            return .err;
        };

        var write_buffer: [4096]u8 align(16) = undefined;
        var file_writer = new_file.writer(&write_buffer);
        const writer = &file_writer.interface;

        writer.print("{f}", .{task}) catch |err| {
            log.err("Failed to write to {s}.md: {s}", .{ task_name, @errorName(err) });
            return .err;
        };
        // @IMPORTANT I never forget to flush
        writer.flush() catch |err| {
            log.err("Failed to flush {s}.md: {s}", .{ task_name, @errorName(err) });
            return .err;
        };
        new_file.sync() catch |err| {
            log.err("Failed to sync {s}.md: {s}", .{ task_name, @errorName(err) });
            return .err;
        };
        log.info("Successfully moved task {s} to {s}", .{ task_name, @tagName(to_state) });
        return .{ .moved = to_state };
    }
    log.debug("Task '{s}' is good to go", .{task_name});
    return .ok;
}
