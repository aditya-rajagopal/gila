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

const Maps = struct {
    todo: ?std.StringArrayHashMapUnmanaged(void),
    started: ?std.StringArrayHashMapUnmanaged(void),
    waiting: ?std.StringArrayHashMapUnmanaged(void),
    done: ?std.StringArrayHashMapUnmanaged(void),
    cancelled: ?std.StringArrayHashMapUnmanaged(void),

    pub const empty = Maps{
        .todo = null,
        .started = null,
        .waiting = null,
        .done = null,
        .cancelled = null,
    };
};

pub fn execute(self: Sync, arena: *stdx.Arena) void {
    const allocator = arena.allocator();
    if (!self.verbose) {
        root.log_level = .warn;
    }

    _, var gila_dir = common.getGilaDir(allocator) orelse return;
    defer gila_dir.close();

    const fixed_buffer: []u8 = allocator.alloc(u8, 128 * 1024) catch unreachable;
    var local_arena = stdx.Arena.initBuffer(fixed_buffer);

    var maps: Maps = .empty;
    var transitions = std.StringArrayHashMapUnmanaged([2]gila.Status).empty;

    inline for (@typeInfo(Maps).@"struct".fields) |field| {
        var dir_n: ?std.fs.Dir = gila_dir.openDir(field.name, .{ .iterate = true }) catch null;
        if (dir_n) |*dir| {
            var map = std.StringArrayHashMapUnmanaged(void).init(allocator, &.{}, &.{}) catch unreachable;
            defer dir.close();
            var dir_walker = dir.iterateAssumeFirstIteration();
            while (dir_walker.next() catch |err| {
                log.err("Failed to iterate over done directory: {s}", .{@errorName(err)});
                return;
            }) |entry| {
                defer local_arena.reset(false);
                if (entry.kind == .directory) {
                    if (gila.id.isValid(entry.name)) {
                        var buffer: [1024]u8 = undefined;
                        const file_name = std.fmt.bufPrint(&buffer, "{s}.md", .{entry.name}) catch unreachable;
                        const path = std.fs.path.join(local_arena.allocator(), &.{ entry.name, file_name }) catch unreachable;
                        dir.access(path, .{}) catch continue;
                        const name = arena.pushString(entry.name);
                        map.put(arena.allocator(), name, {}) catch unreachable;
                    }
                }
            }
            @field(maps, field.name) = map;
        }
    }

    if (maps.done) |*done_map| {
        var dir: std.fs.Dir = gila_dir.openDir("done", .{}) catch {
            @branchHint(.cold);
            log.err("Unexpected error while opening done directory", .{});
            return;
        };
        defer dir.close();
        var index: usize = 0;
        while (index < done_map.keys().len) {
            const task_name = done_map.keys()[index];
            defer local_arena.reset(false);
            var buffer: [128]u8 = undefined;
            const file_name = std.fmt.bufPrint(&buffer, "{s}.md", .{task_name}) catch unreachable;
            const path = std.fs.path.join(local_arena.allocator(), &.{ task_name, file_name }) catch unreachable;
            const file = dir.openFile(path, .{}) catch |err| {
                log.err("Unexpected error while opening done file {s}: {s}", .{ task_name, @errorName(err) });
                index += 1;
                continue;
            };
            var reader_buffer: [4096]u8 = undefined;
            defer file.close();
            var reader = file.reader(&reader_buffer);
            reader.interface.fillMore() catch {
                log.err("Failed to read task description file {s}", .{task_name});
                index += 1;
                continue;
            };
            var diagnostic: ?gila.Task.Diagnostic = null;
            var task: gila.Task = .default;
            task.parse(&reader.interface, &local_arena, &diagnostic) catch {
                log.err("Failed to parse task description file {s}: {s}", .{ task_name, diagnostic.?.message });
                index += 1;
                continue;
            };
            var error_out: ?[]const u8 = null;
            task.validate(&error_out) catch {
                log.err("Failed to validate task description file {s}: {s}", .{ task_name, error_out.? });
                index += 1;
                continue;
            };
            if (task.status == .done) {
                index += 1;
            } else {
                const result = moveTask(&local_arena, file_name, &task, gila.Status.done, task.status, gila_dir);
                switch (result) {
                    .err => {
                        index += 1;
                    },
                    .moved => |to_state| {
                        switch (to_state) {
                            .done => unreachable,
                            inline else => |s| {
                                if (@field(maps, @tagName(s))) |*map| {
                                    map.put(arena.allocator(), task_name, {}) catch unreachable;
                                } else {
                                    var map = std.StringArrayHashMapUnmanaged(void).init(arena.allocator(), &.{}, &.{}) catch unreachable;
                                    map.put(arena.allocator(), task_name, {}) catch unreachable;
                                    @field(maps, @tagName(s)) = map;
                                }
                                _ = done_map.swapRemove(task_name);
                                transitions.put(arena.allocator(), task_name, [_]gila.Status{ .done, s }) catch unreachable;
                            },
                        }
                    },
                }
            }
        }
    }

    if (maps.todo) |*todo_map| {
        var dir: std.fs.Dir = gila_dir.openDir("todo", .{}) catch {
            @branchHint(.cold);
            log.err("Unexpected error while opening done directory", .{});
            return;
        };
        defer dir.close();
        var index: usize = 0;
        while (index < todo_map.keys().len) {
            const task_name = todo_map.keys()[index];
            defer local_arena.reset(false);
            var buffer: [128]u8 = undefined;
            const file_name = std.fmt.bufPrint(&buffer, "{s}.md", .{task_name}) catch unreachable;
            const path = std.fs.path.join(local_arena.allocator(), &.{ task_name, file_name }) catch unreachable;
            const file = dir.openFile(path, .{}) catch |err| {
                log.err("Unexpected error while opening todo file {s}: {s}", .{ task_name, @errorName(err) });
                index += 1;
                continue;
            };
            var reader_buffer: [4096]u8 = undefined;
            defer file.close();
            var reader = file.reader(&reader_buffer);
            reader.interface.fillMore() catch {
                log.err("Failed to read task description file {s}", .{task_name});
                index += 1;
                continue;
            };
            var diagnostic: ?gila.Task.Diagnostic = null;
            var task: gila.Task = .default;
            task.parse(&reader.interface, &local_arena, &diagnostic) catch {
                log.err("Failed to parse task description file {s}: {s}", .{ task_name, diagnostic.?.message });
                index += 1;
                continue;
            };
            var error_out: ?[]const u8 = null;
            task.validate(&error_out) catch {
                log.err("Failed to validate task description file {s}: {s}", .{ task_name, error_out.? });
                index += 1;
                continue;
            };
            if (task.status == .todo) {
                index += 1;
            } else {
                const result = moveTask(&local_arena, file_name, &task, gila.Status.todo, task.status, gila_dir);
                switch (result) {
                    .err => {
                        index += 1;
                    },
                    .moved => |to_state| switch (to_state) {
                        .todo => unreachable,
                        inline else => |s| {
                            if (@field(maps, @tagName(s))) |*map| {
                                map.put(arena.allocator(), task_name, {}) catch unreachable;
                            } else {
                                var map = std.StringArrayHashMapUnmanaged(void).init(arena.allocator(), &.{}, &.{}) catch unreachable;
                                map.put(arena.allocator(), task_name, {}) catch unreachable;
                                @field(maps, @tagName(s)) = map;
                            }
                            _ = todo_map.swapRemove(task_name);
                            transitions.put(arena.allocator(), task_name, [_]gila.Status{ .todo, s }) catch unreachable;
                        },
                    },
                }
            }
        }
    }

    var buffer: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    var iter = transitions.iterator();
    while (iter.next()) |entry| {
        writer.interface.print("Moved {s}: {t} -> {t}\n", .{ entry.key_ptr.*, entry.value_ptr[0], entry.value_ptr[1] }) catch unreachable;
    }
    writer.interface.flush() catch unreachable;
}

const Result = union(enum) {
    err,
    moved: gila.Status,
};

fn moveTask(
    arena: *stdx.Arena,
    file_name: []const u8,
    task: *gila.Task,
    from: gila.Status,
    to: gila.Status,
    gila_dir: std.fs.Dir,
) Result {
    const task_name = file_name[0 .. file_name.len - 3];
    log.info(
        "Task '{s}' is in the wrong state. Expected '{s}' based on the folder but found '{s}' in the description. The file is taken as the truth.",
        .{ task_name, @tagName(from), @tagName(to) },
    );
    task.transition(to) catch {
        log.err("Failed to transition task '{s}' to '{s}'", .{ task_name, @tagName(to) });
        return .err;
    };

    common.moveTaskData(arena.allocator(), gila_dir, task_name, from, to) catch return .err;

    const new_file_name = std.fs.path.join(arena.allocator(), &.{ @tagName(to), task_name, file_name }) catch |err| {
        log.err("Unexpected error while joining {s}/{s}: {s}", .{ @tagName(to), task_name, @errorName(err) });
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
    log.info("Successfully moved task {s} to {s}", .{ task_name, @tagName(task.status) });
    return .{ .moved = task.status };
}
