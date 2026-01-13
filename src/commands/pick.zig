const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const builtin = @import("builtin");

const gila = @import("gila");
const stdx = @import("stdx");
const root = @import("root");

const common = @import("common.zig");

const log = std.log.scoped(.pick);

const Pick = @This();

verbose: bool = false,
owner: ?common.StringList = null,
priority: ?common.PriorityFilter = null,
priority_value: ?common.PriorityValueFilter = null,
tags: ?common.TagsFilter = null,
waiting_on: ?common.WaitingOnFilter = null,
fields: ?common.StringList = null,

pub fn execute(self: Pick, ctx: common.CommandContext) void {
    self.run(ctx) catch |err| switch (err) {
        error.GilaNotFound => log.err("GILA directory not found. Run 'gila init' first.", .{}),
        error.OutOfMemory => log.err("Failed to allocate memory", .{}),
        error.DirIterationFailed => log.err("Failed to iterate over gila directory", .{}),
        error.FailedToGenerateTaskId => log.err("Failed to generate task id", .{}),
        error.InvalidTask => log.err("Invalid task", .{}),
        error.FailedToWriteTaskDescriptionFile => log.err("Failed to write task description file", .{}),
        error.FailedToOpenEditor => log.err("Failed to open editor", .{}),
        error.SyncFailed => log.err("Failed to synchronize tasks", .{}),
    };
}

pub const Error = error{
    GilaNotFound,
    OutOfMemory,
    DirIterationFailed,
    FailedToGenerateTaskId,
    InvalidTask,
    FailedToWriteTaskDescriptionFile,
    FailedToOpenEditor,
    SyncFailed,
};

pub fn run(self: Pick, ctx: common.CommandContext) !void {
    const io = ctx.io;
    const arena = ctx.arena;
    const allocator = arena.allocator();
    if (!self.verbose) {
        root.log_level = .warn;
    }
    _, var gila_dir = common.getGilaDir(io, allocator) orelse return Error.GilaNotFound;
    defer gila_dir.close(io);

    const Find = @import("find.zig");
    // @TODO GILA(aweful_pyro_5y7)
    const todo = Find{
        .status = .todo,
        .priority = self.priority,
        .priority_value = self.priority_value,
        .tags = self.tags,
        .waiting_on = self.waiting_on,
        .verbose = self.verbose,
    };
    const results = try todo.run(ctx);
    const FoundTask = struct {
        task: gila.Task,
        file: []const u8,
    };
    var found_tasks = try std.ArrayList(FoundTask).initCapacity(allocator, results.tasks.len);
    const task_buffer: []u8 = try allocator.alloc(u8, 64 * 1024);
    var local_arena = stdx.Arena.initBuffer(task_buffer);
    var count: usize = 0;
    for (results.tasks) |entry| {
        _ = local_arena.reset(false);
        const task_file = gila_dir.openFile(io, entry.path, .{ .mode = .read_only }) catch continue;
        defer task_file.close(io);
        const last_slash = std.mem.lastIndexOfScalar(u8, entry.path, '/') orelse continue;
        var task: gila.Task = gila.Task.init(entry.path[last_slash + 1 .. entry.path.len - 3]) catch unreachable;
        task.fromFile(task_file, io, &local_arena) catch continue;

        const task_copy = task.dupe(allocator, .{ .owner = true, .id = true, .tags = true, .title = true }) catch continue;
        found_tasks.append(allocator, .{ .task = task_copy, .file = entry.path }) catch continue;
        count += 1;
    }

    const lessThan = struct {
        pub fn lessThan(_: void, a: FoundTask, b: FoundTask) bool {
            if (@intFromEnum(a.task.priority) < @intFromEnum(b.task.priority)) return false else if (@intFromEnum(a.task.priority) > @intFromEnum(b.task.priority)) return true;
            if (a.task.priority_value < b.task.priority_value) return false;
            return false;
        }
    }.lessThan;
    std.sort.heap(FoundTask, found_tasks.items, {}, lessThan);
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(ctx.io, &buffer);

    writer.interface.writeAll("Tasks found:\n") catch unreachable;
    writer.interface.print("|{s:^20}|{s:^8}|{s:^14}|{s}\n", .{ "ID", "Priority", "Priority Value", "Title" }) catch unreachable;
    for (found_tasks.items) |entry| {
        writer.interface.print("|{s:^20}|{t:^8}|{d:^14}|{s}\n", .{ entry.task.id, entry.task.priority, entry.task.priority_value, entry.task.title }) catch unreachable;
    }

    writer.interface.flush() catch unreachable;
}

