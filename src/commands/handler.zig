const std = @import("std");
const gila = @import("gila");
const stdx = @import("stdx");

const common = @import("common.zig");
const rpc = @import("rpc.zig");

const log = std.log.scoped(.handlers);

pub const Handler = @This();

pub const Method = enum {
    @"task/create",
    @"task/get",
    @"task/update",
    @"task/find",
    @"task/sync",
    shutdown,
};

io: std.Io,
gila_dir: std.Io.Dir,
gila_path: []const u8,
arena: *std.heap.ArenaAllocator,
id: rpc.RequestId,
resp: *rpc.ResponseWriter,
params: ?std.json.Value,

pub fn fail(self: Handler, code: rpc.ErrorCode, msg: []const u8) void {
    @branchHint(.unlikely);
    rpc.sendError(self.io, self.id, code, msg);
}

pub fn failInternal(self: Handler, msg: []const u8) void {
    @branchHint(.unlikely);
    rpc.sendError(self.io, self.id, .internal_error, msg);
}

pub fn failResponseWrite(self: Handler) void {
    @branchHint(.unlikely);
    rpc.sendError(self.io, self.id, .internal_error, "Failed to write response");
}

pub fn dispatch(self: Handler, method: Method) bool {
    var result: bool = true;
    switch (method) {
        .@"task/create" => self.handleTaskCreate(),
        .@"task/get" => self.handleTaskGet(),
        .@"task/update" => self.handleTaskUpdate(),
        .@"task/find" => self.handleTaskFind(),
        .@"task/sync" => self.handleTaskSync(),
        .shutdown => {
            self.handleShutdown();
            result = false;
        },
    }
    return result;
}

fn handleTaskCreate(self: Handler) void {
    const allocator = self.arena.allocator();

    const p = self.params orelse return self.fail(.invalid_params, "Missing params");
    if (p != .object) return self.fail(.invalid_params, "Params must be an object");

    const title = rpc.getString(p.object, "title") orelse return self.fail(.invalid_params, "Missing required field: title");
    if (title.len == 0) return self.fail(.invalid_params, "Title cannot be empty");

    const username = rpc.getString(p.object, "username") orelse return self.fail(.invalid_params, "Missing required field: username");
    if (username.len == 0) return self.fail(.invalid_params, "Username cannot be empty");

    const description = rpc.getString(p.object, "description") orelse "";
    const priority = rpc.getPriority(p.object, "priority") orelse .medium;
    const priority_value = rpc.getU8(p.object, "priority_value") orelse 50;
    const tags = rpc.getStringArray(p.object, "tags", allocator);

    var waiting_on: ?[]const []const u8 = null;
    if (rpc.getStringArray(p.object, "waiting_on", allocator)) |task_ids| {
        const formatted = allocator.alloc([]const u8, task_ids.len) catch return self.failInternal("Failed to allocate waiting_on");
        for (task_ids, 0..) |tid, i| {
            if (!gila.id.isValid(tid)) return self.fail(.invalid_task_id, "Invalid task ID in waiting_on");
            const ref = allocator.alloc(u8, tid.len + 6) catch return self.failInternal("Failed to allocate task ref");
            @memcpy(ref[0..3], "\"[[");
            @memcpy(ref[3..][0..tid.len], tid);
            @memcpy(ref[3 + tid.len ..], "]]\"");
            formatted[i] = ref;
        }
        waiting_on = formatted;
    }

    var blocks: ?[]const []const u8 = null;
    if (rpc.getStringArray(p.object, "blocks", allocator)) |b| {
        const formatted = allocator.alloc([]const u8, b.len) catch return self.failInternal("Failed to allocate task ref");
        for (b, 0..) |tid, i| {
            if (!gila.id.isValid(tid)) return self.fail(.invalid_task_id, "Invalid task ID in waiting_on");
            const ref = allocator.alloc(u8, tid.len + 6) catch return self.failInternal("Failed to allocate task ref");
            @memcpy(ref[0..3], "\"[[");
            @memcpy(ref[3..][0..tid.len], tid);
            @memcpy(ref[3 + tid.len ..], "]]\"");
            formatted[i] = ref;
        }
        blocks = formatted;
    }

    const Todo = @import("todo.zig");
    const todo = Todo{
        .description = description,
        .priority = priority,
        .priority_value = priority_value,
        .tags = if (tags) |t| .{ .tags = t } else null,
        .waiting_on = if (waiting_on) |w| .{ .tasks = w } else null,
        .blocks = if (blocks) |b| .{ .tasks = b } else null,
        .positional = .{ .title = title },
        .verbose = false,
        .edit = false,
    };
    var find_arena = stdx.Arena.init(allocator, 256 * 1024, null) catch return self.failInternal("Failed to allocate find buffer");
    const context = common.CommandContext{ .io = self.io, .arena = &find_arena, .username = username, .editor = "" };

    const result = todo.run(context) catch |err| switch (err) {
        error.GilaNotFound => return self.fail(.gila_dir_not_found, "GILA directory not found. Run 'gila init' first."),
        error.OutOfMemory => return self.fail(.internal_error, "Failed to allocate memory"),
        error.FailedToGenerateTaskId => return self.fail(.internal_error, "Failed to generate task id"),
        error.InvalidTask => return self.fail(.invalid_params, "Invalid task"),
        error.FailedToWriteTaskDescriptionFile => return self.fail(.internal_error, "Failed to write task description file"),
        error.FailedToOpenEditor => return self.fail(.internal_error, "Failed to open editor"),
    };

    const abs_path = std.fs.path.join(allocator, &.{ self.gila_path, result.description_file }) catch return self.failInternal("Failed to build path");

    self.resp.begin() catch return self.failResponseWrite();
    const jw = self.resp.writer();
    jw.beginObject() catch return self.failResponseWrite();
    jw.objectField("task_id") catch return self.failResponseWrite();
    jw.write(result.task_id) catch return self.failResponseWrite();
    jw.objectField("file_path") catch return self.failResponseWrite();
    jw.write(abs_path) catch return self.failResponseWrite();
    jw.objectField("status") catch return self.failResponseWrite();
    jw.write(@tagName(result.status)) catch return self.failResponseWrite();
    jw.endObject() catch return self.failResponseWrite();
    self.resp.end() catch return self.failResponseWrite();
}

fn handleTaskGet(self: Handler) void {
    const allocator = self.arena.allocator();

    const p = self.params orelse return self.fail(.invalid_params, "Missing params");
    if (p != .object) return self.fail(.invalid_params, "Params must be an object");

    const task_id = rpc.getString(p.object, "task_id") orelse return self.fail(.invalid_params, "Missing required field: task_id");
    if (!gila.id.isValid(task_id)) return self.fail(.invalid_task_id, "Invalid task ID format");
    const path_only = rpc.getBool(p.object, "path_only") orelse false;

    var find_arena = stdx.Arena.init(allocator, 256 * 1024, null) catch return self.failInternal("Failed to allocate find buffer");
    const task_file = find_arena.pushArray(u8, task_id.len + 3);
    @memcpy(task_file[0..task_id.len], task_id);
    @memcpy(task_file[task_id.len..][0..3], ".md");
    if (path_only) {
        const result = gila.Task.getTaskFileById(self.io, task_id, &find_arena, self.gila_dir) catch return self.fail(.task_not_found, "Task not found");
        const abs_path = std.fs.path.join(allocator, &.{ self.gila_path, @tagName(result.folder), task_id, task_file }) catch return self.failInternal("Failed to build path");
        self.resp.begin() catch return self.failResponseWrite();
        const jw = self.resp.writer();
        jw.beginObject() catch return self.failResponseWrite();
        jw.objectField("file_path") catch return self.failResponseWrite();
        jw.write(abs_path) catch return self.failResponseWrite();
        jw.endObject() catch return self.failResponseWrite();
        self.resp.end() catch return self.failResponseWrite();
    } else {
        const result = gila.Task.findTaskAndRead(task_id, self.io, &find_arena, self.gila_dir) catch return self.fail(.task_not_found, "Task not found");
        const abs_path = std.fs.path.join(allocator, &.{ self.gila_path, @tagName(result.status), task_id, task_file }) catch return self.failInternal("Failed to build path");
        self.resp.begin() catch return self.failResponseWrite();
        rpc.writeTask(self.resp.writer(), result.task, abs_path) catch return self.failResponseWrite();
        self.resp.end() catch return self.failResponseWrite();
    }
}

// @TODO missing waiting_on
fn handleTaskUpdate(self: Handler) void {
    const allocator = self.arena.allocator();

    const p = self.params orelse return self.fail(.invalid_params, "Missing params");
    if (p != .object) return self.fail(.invalid_params, "Params must be an object");

    const task_id = rpc.getString(p.object, "task_id") orelse return self.fail(.invalid_params, "Missing required field: task_id");
    if (!gila.id.isValid(task_id)) return self.fail(.invalid_task_id, "Invalid task ID format");

    var find_arena = stdx.Arena.init(allocator, 256 * 1024, null) catch return self.failInternal("Failed to allocate find buffer");
    var result = gila.Task.findTaskAndRead(task_id, self.io, &find_arena, self.gila_dir) catch return self.fail(.task_not_found, "Task not found");
    var task = &result.task;
    const old_status = result.status;

    if (rpc.getString(p.object, "title")) |new_title| task.title = new_title;

    if (rpc.getString(p.object, "description")) |new_desc| task.description = new_desc;
    if (rpc.getPriority(p.object, "priority")) |new_priority| task.priority = new_priority;
    if (rpc.getU8(p.object, "priority_value")) |new_pv| task.priority_value = new_pv;

    if (rpc.getStringArray(p.object, "tags", allocator)) |new_tags| {
        if (task.tags) |tags| {
            var combined_tags = std.ArrayList([]const u8).initCapacity(allocator, tags.len + new_tags.len) catch return self.failInternal("Failed to allocate tags");
            combined_tags.appendSliceAssumeCapacity(tags);
            for (new_tags) |tag| {
                if (!common.findString(tags, tag)) {
                    combined_tags.appendAssumeCapacity(tag);
                }
            }
            task.tags = combined_tags.items;
        } else {
            task.tags = new_tags;
        }
    }

    if (rpc.getStatus(p.object, "status")) |new_status| {
        if (new_status != task.status) {
            task.transition(new_status) catch |err| {
                const msg = switch (err) {
                    error.ShouldBeWaiting => "Task has waiting_on dependencies",
                    error.ShouldBeDone => "Task is already done",
                    error.ShouldBeCancelled => "Task is already cancelled",
                };
                return self.fail(.transition_error, msg);
            };
            if (old_status != task.status) {
                common.moveTaskData(self.io, allocator, self.gila_dir, task_id, old_status, task.status) catch return self.failInternal("Failed to move task folder");
            }
        }
    }

    var error_out: ?[]const u8 = null;
    task.validate(&error_out) catch return self.fail(.validation_failed, error_out orelse "Validation failed");
    _ = task.toTaskFile(self.io, false, &find_arena, self.gila_dir) catch return self.failInternal("Failed to write task file");

    const task_file = find_arena.pushArray(u8, task_id.len + 3);
    @memcpy(task_file[0..task_id.len], task_id);
    @memcpy(task_file[task_id.len..][0..3], ".md");
    const abs_path = std.fs.path.join(allocator, &.{ self.gila_path, @tagName(task.status), task_id, task_file }) catch return self.failInternal("Failed to build path");

    self.resp.begin() catch return self.failResponseWrite();
    const jw = self.resp.writer();
    jw.beginObject() catch return self.failResponseWrite();
    jw.objectField("task_id") catch return self.failResponseWrite();
    jw.write(task_id) catch return self.failResponseWrite();
    jw.objectField("status") catch return self.failResponseWrite();
    jw.write(@tagName(task.status)) catch return self.failResponseWrite();
    jw.objectField("file_path") catch return self.failResponseWrite();
    jw.write(abs_path) catch return self.failResponseWrite();
    jw.objectField("completed") catch return self.failResponseWrite();
    if (task.completed) |completed| {
        var buf: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{f}", .{completed.as(.@"YYYY-MM-DDTHH:MM:SSZ")}) catch return self.failResponseWrite();
        jw.write(str) catch return self.failResponseWrite();
    } else {
        jw.write(null) catch return self.failResponseWrite();
    }
    jw.endObject() catch return self.failResponseWrite();
    self.resp.end() catch return self.failResponseWrite();
}

fn handleShutdown(self: Handler) void {
    self.resp.begin() catch return self.failResponseWrite();
    const jw = self.resp.writer();
    jw.beginObject() catch return self.failResponseWrite();
    jw.objectField("message") catch return self.failResponseWrite();
    jw.write("Server shutting down") catch return self.failResponseWrite();
    jw.endObject() catch return self.failResponseWrite();
    self.resp.end() catch return self.failResponseWrite();
}

fn handleTaskFind(self: Handler) void {
    const allocator = self.arena.allocator();

    const p = self.params orelse return self.fail(.invalid_params, "Missing params");
    if (p != .object) return self.fail(.invalid_params, "Params must be an object");

    const filter_priority = rpc.getPriority(p.object, "priority");
    const filter_status = rpc.getStatus(p.object, "status");
    const filter_tags = rpc.getStringArray(p.object, "tags", allocator);
    const tags_op = rpc.getOp(p.object, "tags_op");
    const filter_waiting_on = rpc.getStringArray(p.object, "waiting_on", allocator);
    const waiting_on_op = rpc.getOp(p.object, "waiting_on_op");
    const limit = rpc.getPositiveI64(p.object, "limit") orelse std.math.maxInt(i64);
    const offset = rpc.getPositiveI64(p.object, "offset") orelse 0;
    const fields = rpc.getFields(p.object, allocator);

    var find_arena = stdx.Arena.init(allocator, 512 * 1024, null) catch return self.failInternal("Failed to allocate find buffer");
    const Find = @import("find.zig");
    const find = Find{
        .priority = filter_priority,
        .tags = if (filter_tags) |t| .{
            .op = tags_op,
            .tag_list = .{ .tags = t },
        } else null,
        .waiting_on = if (filter_waiting_on) |w| .{
            .op = waiting_on_op,
            .task_list = .{ .tasks = w },
        } else null,
        .verbose = false,
    };
    const context = common.CommandContext{ .io = self.io, .arena = &find_arena, .username = "", .editor = "" };
    const res = find.run(context) catch |err| switch (err) {
        error.GilaNotFound => return self.fail(.gila_dir_not_found, "GILA directory not found. Run 'gila init' first."),
        error.OutOfMemory => return self.fail(.internal_error, "Failed to allocate memory"),
        error.DirIterationFailed => return self.fail(.internal_error, "Failed to iterate over gila directory"),
        error.FailedToGenerateTaskId => return self.fail(.internal_error, "Failed to generate task id"),
        error.InvalidTask => return self.fail(.invalid_params, "Invalid task"),
        error.FailedToWriteTaskDescriptionFile => return self.fail(.internal_error, "Failed to write task description file"),
        error.FailedToOpenEditor => return self.fail(.internal_error, "Failed to open editor"),
        error.SyncFailed => return self.fail(.internal_error, "Failed to synchronize tasks"),
    };

    var found_tasks: std.ArrayList(FoundTask) = .{};

    const task_buffer: []u8 = allocator.alloc(u8, 1 * 1024 * 1024) catch return self.failInternal("Failed to allocate task buffer");
    var local_arena = stdx.Arena.initBuffer(task_buffer);
    var count: usize = 0;
    var skipped: u64 = 0;
    for (res.tasks) |entry| {
        if (skipped < offset) {
            skipped += 1;
            continue;
        }
        if (filter_status) |s| if (entry.status != s) continue;
        _ = local_arena.reset(false);
        const task_file = self.gila_dir.openFile(self.io, entry.path, .{ .mode = .read_only }) catch continue;
        defer task_file.close(self.io);
        const last_slash = std.mem.lastIndexOfScalar(u8, entry.path, '/') orelse continue;
        var task: gila.Task = gila.Task.init(entry.path[last_slash + 1 .. entry.path.len - 3]) catch unreachable;
        task.fromFile(task_file, self.io, &local_arena) catch continue;

        const task_copy = copyTask(allocator, task) catch continue;
        found_tasks.append(allocator, .{ .task = task_copy, .file_path = entry.path }) catch continue;
        count += 1;
        if (limit <= count) break;
    }

    self.resp.begin() catch return self.failResponseWrite();
    const jw = self.resp.writer();
    jw.beginObject() catch return self.failResponseWrite();
    jw.objectField("tasks") catch return self.failResponseWrite();
    jw.beginArray() catch return self.failResponseWrite();
    for (found_tasks.items) |found| {
        rpc.writeTaskFields(jw, found.task, found.file_path, fields) catch return self.failResponseWrite();
    }
    jw.endArray() catch return self.failResponseWrite();
    jw.objectField("available") catch return self.failResponseWrite();
    jw.write(res.tasks.len) catch return self.failResponseWrite();
    jw.objectField("count") catch return self.failResponseWrite();
    jw.write(count) catch return self.failResponseWrite();
    jw.objectField("limit") catch return self.failResponseWrite();
    jw.write(limit) catch return self.failResponseWrite();
    jw.objectField("offset") catch return self.failResponseWrite();
    jw.write(offset) catch return self.failResponseWrite();
    jw.endObject() catch return self.failResponseWrite();
    self.resp.end() catch return self.failResponseWrite();
}

const Sync = @import("sync.zig");
fn handleTaskSync(self: Handler) void {
    const allocator = self.arena.allocator();

    var sync_arena = stdx.Arena.init(allocator, 256 * 1024, null) catch return self.failInternal("Failed to allocate find buffer");

    const sync = Sync{};
    const context = common.CommandContext{ .io = self.io, .arena = &sync_arena, .username = "", .editor = "" };

    const transitions, const updates = sync.run(context) catch |err| switch (err) {
        error.GilaNotFound => return self.fail(.gila_dir_not_found, "GILA directory not found. Run 'gila init' first."),
        error.DirIterationFailed => return self.fail(.internal_error, "Failed to iterate over gila directory"),
        error.DirOpenFailed => return self.fail(.internal_error, "Failed to open gila directory"),
        error.OutOfMemory => return self.fail(.internal_error, "Failed to allocate memory"),
    };

    self.resp.begin() catch return self.failResponseWrite();
    const jw = self.resp.writer();
    jw.beginObject() catch return self.failResponseWrite();

    jw.objectField("transitions") catch return self.failResponseWrite();
    jw.beginArray() catch return self.failResponseWrite();
    for (transitions) |t| {
        jw.beginObject() catch return self.failResponseWrite();
        jw.objectField("task_id") catch return self.failResponseWrite();
        jw.write(t.task_id) catch return self.failResponseWrite();
        jw.objectField("from") catch return self.failResponseWrite();
        jw.write(@tagName(t.from)) catch return self.failResponseWrite();
        jw.objectField("to") catch return self.failResponseWrite();
        jw.write(@tagName(t.to)) catch return self.failResponseWrite();
        jw.endObject() catch return self.failResponseWrite();
    }
    jw.endArray() catch return self.failResponseWrite();

    jw.objectField("updates") catch return self.failResponseWrite();
    jw.beginArray() catch return self.failResponseWrite();
    for (updates) |u| {
        jw.beginObject() catch return self.failResponseWrite();
        jw.objectField("task_id") catch return self.failResponseWrite();
        jw.write(u.task_id) catch return self.failResponseWrite();
        jw.objectField("change") catch return self.failResponseWrite();
        jw.write(u.change) catch return self.failResponseWrite();
        jw.objectField("dependency") catch return self.failResponseWrite();
        jw.write(u.dependency) catch return self.failResponseWrite();
        jw.endObject() catch return self.failResponseWrite();
    }
    jw.endArray() catch return self.failResponseWrite();

    jw.objectField("count") catch return self.failResponseWrite();
    jw.write(transitions.len + updates.len) catch return self.failResponseWrite();

    jw.endObject() catch return self.failResponseWrite();
    self.resp.end() catch return self.failResponseWrite();
}

const FoundTask = struct {
    task: gila.Task,
    file_path: []const u8,
};

fn matchesFilters(
    task: gila.Task,
    filter_priority: ?gila.Priority,
    filter_tags: ?[]const []const u8,
    tags_op: rpc.Op,
    filter_waiting_on: ?[]const []const u8,
    waiting_on_op: rpc.Op,
) bool {
    if (filter_priority) |p| {
        if (task.priority != p) return false;
    }

    if (filter_tags) |tags| {
        const task_tags = task.tags orelse return false;
        var matched: usize = 0;
        for (tags) |tag| {
            if (common.findString(task_tags, tag)) matched += 1;
        }
        switch (tags_op) {
            .@"or" => if (matched == 0) return false,
            .@"and" => if (matched != tags.len) return false,
        }
    }

    if (filter_waiting_on) |waiting_ids| {
        const task_waiting = task.waiting_on orelse return false;
        var matched: usize = 0;
        for (waiting_ids) |wait_id| {
            for (task_waiting) |task_ref| {
                const extracted = extractTaskId(task_ref) orelse continue;
                if (std.mem.eql(u8, extracted, wait_id)) {
                    matched += 1;
                    break;
                }
            }
        }
        switch (waiting_on_op) {
            .@"or" => if (matched == 0) return false,
            .@"and" => if (matched != waiting_ids.len) return false,
        }
    }

    return true;
}

fn extractTaskId(ref: []const u8) ?[]const u8 {
    if (ref.len < 6) return null;
    if (!std.mem.startsWith(u8, ref, "\"[[")) return null;
    if (!std.mem.endsWith(u8, ref, "]]\"")) return null;
    return ref[3 .. ref.len - 3];
}

fn copyTask(allocator: std.mem.Allocator, task: gila.Task) !gila.Task {
    var copy = task;
    copy.id = try allocator.dupe(u8, task.id);
    copy.title = try allocator.dupe(u8, task.title);
    if (task.description.len > 0) {
        copy.description = try allocator.dupe(u8, task.description);
    }
    if (task.owner.len > 0) {
        copy.owner = try allocator.dupe(u8, task.owner);
    }
    if (task.tags) |tags| {
        const new_tags = try allocator.alloc([]const u8, tags.len);
        for (tags, 0..) |tag, i| {
            new_tags[i] = try allocator.dupe(u8, tag);
        }
        copy.tags = new_tags;
    }
    if (task.waiting_on) |waiting| {
        const new_waiting = try allocator.alloc([]const u8, waiting.len);
        for (waiting, 0..) |w, i| {
            new_waiting[i] = try allocator.dupe(u8, w);
        }
        copy.waiting_on = new_waiting;
    }
    return copy;
}
