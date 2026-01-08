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

    const task_id = gila.id.new(allocator) catch return self.failInternal("Failed to generate task ID");
    const owner = common.getUserName(allocator) catch "unknown";
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

    const task: gila.Task = .{
        .id = task_id,
        .title = title,
        .status = if (waiting_on != null) .waiting else .todo,
        .priority = priority,
        .priority_value = priority_value,
        .owner = owner,
        .created = stdx.DateTimeUTC.now(),
        .description = description,
        .tags = tags,
        .waiting_on = waiting_on,
        .completed = null,
        .extra_lines = null,
    };

    var error_out: ?[]const u8 = null;
    task.validate(&error_out) catch return self.fail(.validation_failed, error_out orelse "Validation failed");

    var find_arena = stdx.Arena.init(allocator, 256 * 1024, null) catch return self.failInternal("Failed to allocate find buffer");
    const rel_path = task.toTaskFile(self.io, true, &find_arena, self.gila_dir) catch return self.failInternal("Failed to write task file");
    const abs_path = std.fs.path.join(allocator, &.{ self.gila_path, rel_path }) catch return self.failInternal("Failed to build path");

    self.resp.begin() catch return self.failResponseWrite();
    const jw = self.resp.writer();
    jw.beginObject() catch return self.failResponseWrite();
    jw.objectField("task_id") catch return self.failResponseWrite();
    jw.write(task_id) catch return self.failResponseWrite();
    jw.objectField("file_path") catch return self.failResponseWrite();
    jw.write(abs_path) catch return self.failResponseWrite();
    jw.objectField("status") catch return self.failResponseWrite();
    jw.write(@tagName(task.status)) catch return self.failResponseWrite();
    jw.endObject() catch return self.failResponseWrite();
    self.resp.end() catch return self.failResponseWrite();
}

fn handleTaskGet(self: Handler) void {
    const allocator = self.arena.allocator();

    const p = self.params orelse return self.fail(.invalid_params, "Missing params");
    if (p != .object) return self.fail(.invalid_params, "Params must be an object");

    const task_id = rpc.getString(p.object, "task_id") orelse return self.fail(.invalid_params, "Missing required field: task_id");
    if (!gila.id.isValid(task_id)) return self.fail(.invalid_task_id, "Invalid task ID format");

    var find_arena = stdx.Arena.init(allocator, 256 * 1024, null) catch return self.failInternal("Failed to allocate find buffer");
    const result = gila.Task.findTaskAndRead(task_id, self.io, &find_arena, self.gila_dir) catch return self.fail(.task_not_found, "Task not found");

    const task_file = find_arena.pushArray(u8, task_id.len + 3);
    @memcpy(task_file[0..task_id.len], task_id);
    @memcpy(task_file[task_id.len..][0..3], ".md");
    const rel_path = std.fs.path.join(allocator, &.{ @tagName(result.status), task_id, task_file }) catch return self.failInternal("Failed to build path");
    const abs_path = std.fs.path.join(allocator, &.{ self.gila_path, rel_path }) catch return self.failInternal("Failed to build path");

    self.resp.begin() catch return self.failResponseWrite();
    rpc.writeTask(self.resp.writer(), result.task, abs_path) catch return self.failResponseWrite();
    self.resp.end() catch return self.failResponseWrite();
}

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
    if (rpc.getStringArray(p.object, "tags", allocator)) |new_tags| task.tags = new_tags;

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
    const rel_path = std.fs.path.join(allocator, &.{ @tagName(task.status), task_id, task_file }) catch return self.failInternal("Failed to build path");
    const abs_path = std.fs.path.join(allocator, &.{ self.gila_path, rel_path }) catch return self.failInternal("Failed to build path");

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
