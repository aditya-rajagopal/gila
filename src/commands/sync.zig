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

const TaskSet = std.StringArrayHashMapUnmanaged(void);
const Transitions = std.StringArrayHashMapUnmanaged([2]gila.Status);

const TaskSets = struct {
    todo: ?TaskSet,
    started: ?TaskSet,
    waiting: ?TaskSet,
    done: ?TaskSet,
    cancelled: ?TaskSet,

    pub const empty = TaskSets{
        .todo = null,
        .started = null,
        .waiting = null,
        .done = null,
        .cancelled = null,
    };
};

pub fn execute(self: Sync, io: std.Io, arena: *stdx.Arena) void {
    // @TODO [[massive_raid_664]]
    const allocator = arena.allocator();
    if (!self.verbose) {
        root.log_level = .warn;
    }

    _, var gila_dir = common.getGilaDir(allocator) orelse return;
    defer gila_dir.close();

    const fixed_buffer: []u8 = allocator.alloc(u8, 128 * 1024) catch unreachable;
    var local_arena = stdx.Arena.initBuffer(fixed_buffer);

    var maps: TaskSets = .empty;
    var transitions: Transitions = .empty;

    inline for (@typeInfo(TaskSets).@"struct".fields) |field| {
        var dir_n: ?std.fs.Dir = gila_dir.openDir(field.name, .{ .iterate = true }) catch null;
        if (dir_n) |*dir| {
            var map = TaskSet.init(allocator, &.{}, &.{}) catch unreachable;
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
        parseFolder(io, gila_dir, gila.Status.done, &local_arena, &maps, done_map, arena, &transitions) catch return;
    }

    if (maps.todo) |*todo_map| {
        parseFolder(io, gila_dir, gila.Status.todo, &local_arena, &maps, todo_map, arena, &transitions) catch return;
    }

    if (maps.started) |*started_map| {
        parseFolder(io, gila_dir, gila.Status.started, &local_arena, &maps, started_map, arena, &transitions) catch return;
    }

    if (maps.cancelled) |*cancelled_map| {
        parseFolder(io, gila_dir, gila.Status.cancelled, &local_arena, &maps, cancelled_map, arena, &transitions) catch return;
    }

    if (maps.waiting) |*waiting_map| {
        var dir: std.fs.Dir = gila_dir.openDir("waiting", .{}) catch {
            @branchHint(.cold);
            log.err("Unexpected error while opening 'waiting' directory", .{});
            return;
        };
        defer dir.close();
        var index: usize = 0;
        while (index < waiting_map.keys().len) {
            defer local_arena.reset(false);
            const task_name = waiting_map.keys()[index];

            var buffer: [128]u8 = undefined;
            const file_name = std.fmt.bufPrint(&buffer, "{s}.md", .{task_name}) catch unreachable;
            const path = std.fs.path.join(local_arena.allocator(), &.{ task_name, file_name }) catch unreachable;
            const file = dir.openFile(path, .{ .mode = .read_write }) catch |err| {
                log.err("Unexpected error while opening todo file {s}: {s}", .{ task_name, @errorName(err) });
                index += 1;
                continue;
            };

            var task = gila.Task.init(task_name) catch unreachable;
            task.fromFile(file, io, &local_arena) catch {
                index += 1;
                continue;
            };

            var error_out: ?[]const u8 = null;
            task.validate(&error_out) catch |err| switch (err) {
                error.Invalid => {
                    log.err("Failed to validate task description file {s}: {s}", .{ task_name, error_out.? });
                    index += 1;
                    continue;
                },
                error.WaitingFoundButAllValid => {
                    task.transition(.waiting) catch unreachable;
                    log.info("Task '{s}' found in '{s}' folder and marked as '{s}' status had a waiting_on list. Transitioning back to 'waiting' status", .{ task_name, @tagName(.waiting), @tagName(task.status) });
                },
                else => {},
            };

            if (task.waiting_on) |waiting_on| {
                var new_array = std.ArrayList([]const u8).initCapacity(local_arena.allocator(), waiting_on.len) catch unreachable;
                for (waiting_on) |name| {
                    assert(name.len > 3);
                    const waiting_task = name[3 .. name.len - 3];
                    var found: bool = false;
                    var done: bool = false;
                    inline for (@typeInfo(TaskSets).@"struct".fields) |field| {
                        if (comptime std.mem.eql(u8, field.name, "waiting")) {
                            continue;
                        }

                        if (@field(maps, field.name)) |map| {
                            const exists = if (map.get(waiting_task)) |_| true else false;
                            found = found or exists;
                            if (comptime std.mem.eql(u8, field.name, "done") or std.mem.eql(u8, field.name, "cancelled")) {
                                done = done or exists;
                            }
                        }
                    }
                    if (!found) {
                        log.warn("Task '{s}' is waiting on '{s}' but it does not exist in the gila project", .{ task_name, waiting_task });
                    } else {
                        if (done) {
                            log.info("Task '{s}' is waiting on '{s}' but it is done or cancelled. Removing from waiting list", .{ task_name, waiting_task });
                        } else {
                            new_array.appendAssumeCapacity(name);
                        }
                    }
                }

                if (new_array.items.len == 0) {
                    task.waiting_on = null;
                } else if (new_array.items.len != waiting_on.len) {
                    task.waiting_on = new_array.toOwnedSlice(local_arena.allocator()) catch unreachable;
                    task.flushToFile(file, file_name) catch {};
                    index += 1;
                    continue;
                } else {
                    // NOTE All waiting tasks are still undone
                    index += 1;
                    continue;
                }
            }

            log.info("Task {s} is not waiting on anything", .{task_name});
            const target_status = switch (task.status) {
                .todo, .started => |s| if (task.completed) |_| .done else s,
                .done, .cancelled => |s| if (task.completed) |_| s else .todo,
                .waiting => .todo,
            };
            const result = moveTask(&local_arena, file_name, &task, .waiting, target_status, gila_dir);
            switch (result) {
                .err => {
                    index += 1;
                    continue;
                },
                .moved => |to_state| switch (to_state) {
                    inline else => |s| {
                        if (task.status != .waiting) {
                            if (@field(maps, @tagName(s))) |*m| {
                                m.put(arena.allocator(), task_name, {}) catch unreachable;
                            } else {
                                var m = TaskSet.init(arena.allocator(), &.{}, &.{}) catch unreachable;
                                m.put(arena.allocator(), task_name, {}) catch unreachable;
                                @field(maps, @tagName(s)) = m;
                            }
                            _ = waiting_map.swapRemove(task_name);
                        } else {
                            index += 1;
                        }
                        transitions.put(arena.allocator(), task_name, [_]gila.Status{ .waiting, s }) catch unreachable;
                    },
                },
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

fn parseFolder(
    io: std.Io,
    gila_dir: std.fs.Dir,
    folder: gila.Status,
    local_arena: *stdx.Arena,
    sets: *TaskSets,
    set: *TaskSet,
    arena: *stdx.Arena,
    transitions: *Transitions,
) !void {
    var dir: std.fs.Dir = gila_dir.openDir(@tagName(folder), .{}) catch {
        @branchHint(.cold);
        log.err("Unexpected error while opening '{s}' directory", .{@tagName(folder)});
        return;
    };
    defer dir.close();
    var index: usize = 0;
    while (index < set.keys().len) {
        const task_name = set.keys()[index];
        defer local_arena.reset(false);
        const file_name = local_arena.pushArray(u8, task_name.len + 3);
        @memcpy(file_name[0..task_name.len], task_name);
        @memcpy(file_name[task_name.len..][0..3], ".md");
        const path = std.fs.path.join(local_arena.allocator(), &.{ task_name, file_name }) catch unreachable;

        const file = dir.openFile(path, .{}) catch |err| {
            log.err("Unexpected error while opening task file {s}: {s}", .{ task_name, @errorName(err) });
            index += 1;
            continue;
        };

        var task = gila.Task.init(task_name) catch unreachable;
        task.fromFile(file, io, local_arena) catch {
            index += 1;
            continue;
        };

        var error_out: ?[]const u8 = null;
        var changed: bool = false;
        task.validate(&error_out) catch |err| switch (err) {
            error.Invalid => {
                log.err("Failed to validate task description file {s}: {s}", .{ task_name, error_out.? });
                index += 1;
                continue;
            },
            error.WaitingFoundButAllValid => {
                task.transition(.waiting) catch {
                    log.err("Invalid task '{s}' with 'waiting' status: Skipping", .{task_name});
                    index += 1;
                    continue;
                };
                log.info("Task '{s}' found in '{s}' folder and marked as '{s}' status had a waiting_on list. Transitioning to 'waiting' status", .{ task_name, @tagName(folder), @tagName(task.status) });
                changed = true;
            },
            error.WaitingNotFoundWhenWaitingStatus => {
                log.err("Invalid task '{s}' had 'waiting' status but no waiting_on list: Reverting to '{s}' status", .{ task_name, @tagName(folder) });
                task.transition(folder) catch {
                    log.err("Failed to revert task '{s}' to '{s}' status", .{ task_name, @tagName(folder) });
                    index += 1;
                    continue;
                };
                changed = true;
            },
            else => {},
        };
        if (task.status == folder and !changed) {
            index += 1;
            log.info("Task '{s}' is in the same state as the folder. Skipping", .{task_name});
        } else {
            const result = moveTask(local_arena, file_name, &task, folder, task.status, gila_dir);
            switch (result) {
                .err => {
                    index += 1;
                },
                .moved => |to_state| switch (to_state) {
                    inline else => |s| {
                        if (@field(sets, @tagName(s))) |*m| {
                            m.put(arena.allocator(), task_name, {}) catch unreachable;
                        } else {
                            var m = TaskSet.init(arena.allocator(), &.{}, &.{}) catch unreachable;
                            m.put(arena.allocator(), task_name, {}) catch unreachable;
                            @field(sets, @tagName(s)) = m;
                        }
                        _ = set.swapRemove(task_name);
                        transitions.put(arena.allocator(), task_name, [_]gila.Status{ folder, s }) catch unreachable;
                    },
                },
            }
        }
    }
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
        task.status = from;
        task.transition(task.status) catch {
            log.err("Failed to transition task '{s}' to '{s}'", .{ task_name, @tagName(task.status) });
            return .err;
        };
    };

    common.moveTaskData(arena.allocator(), gila_dir, task_name, from, task.status) catch return .err;

    _ = task.toTaskFile(false, arena, gila_dir) catch return .err;

    log.info("Successfully moved task {s} to {s}", .{ task_name, @tagName(task.status) });
    return .{ .moved = task.status };
}
