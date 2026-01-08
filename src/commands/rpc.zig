const std = @import("std");
const assert = std.debug.assert;

const gila = @import("gila");
const stdx = @import("stdx");

pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    task_not_found = -32001,
    invalid_task_id = -32002,
    validation_failed = -32003,
    transition_error = -32004,
    gila_dir_not_found = -32005,
};

pub const RequestId = union(enum) {
    integer: i64,
    string: []const u8,
    null,

    pub fn fromValue(value: std.json.Value) ?RequestId {
        return switch (value) {
            .integer => |i| .{ .integer = i },
            .string => |s| .{ .string = s },
            .null => .null,
            else => null,
        };
    }

    pub fn write(self: RequestId, jw: *std.json.Stringify) !void {
        switch (self) {
            .integer => |i| try jw.write(i),
            .string => |s| try jw.write(s),
            .null => try jw.write(null),
        }
    }
};

pub fn sendError(
    io: std.Io,
    id: ?RequestId,
    code: ErrorCode,
    message: []const u8,
) void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    var jw: std.json.Stringify = .{ .writer = &stdout.interface, .options = .{} };

    jw.beginObject() catch return;
    jw.objectField("jsonrpc") catch return;
    jw.write("2.0") catch return;
    jw.objectField("error") catch return;
    jw.beginObject() catch return;
    jw.objectField("code") catch return;
    jw.write(@intFromEnum(code)) catch return;
    jw.objectField("message") catch return;
    jw.write(message) catch return;
    jw.endObject() catch return;
    jw.objectField("id") catch return;
    if (id) |req_id| {
        req_id.write(&jw) catch return;
    } else {
        jw.write(null) catch return;
    }
    jw.endObject() catch return;
    stdout.interface.writeByte('\n') catch return;
    stdout.interface.flush() catch return;
}

pub fn sendStartupError(io: std.Io, code: ErrorCode, message: []const u8) void {
    sendError(io, null, code, message);
}

pub const ResponseWriter = struct {
    id: RequestId,
    stdout: std.Io.File.Writer = undefined,
    jw: std.json.Stringify = undefined,
    started: bool = false,

    pub fn init(self: *ResponseWriter, io: std.Io, id: RequestId, buffer: []u8) void {
        assert(buffer.len > 0);
        self.id = id;
        self.started = false;
        self.stdout = std.Io.File.stdout().writer(io, buffer);
        self.jw = .{ .writer = &self.stdout.interface, .options = .{} };
    }

    pub fn begin(self: *ResponseWriter) !void {
        assert(!self.started);
        try self.jw.beginObject();
        try self.jw.objectField("jsonrpc");
        try self.jw.write("2.0");
        try self.jw.objectField("result");
        self.started = true;
    }

    pub fn end(self: *ResponseWriter) !void {
        assert(self.started);
        try self.jw.objectField("id");
        try self.id.write(&self.jw);
        try self.jw.endObject();
        try self.stdout.interface.writeByte('\n');
        try self.stdout.interface.flush();
        self.started = false;
    }

    pub fn writer(self: *ResponseWriter) *std.json.Stringify {
        return &self.jw;
    }
};

pub fn writeTask(jw: *std.json.Stringify, task: gila.Task, file_path: []const u8) !void {
    try jw.beginObject();

    try jw.objectField("id");
    try jw.write(task.id);

    try jw.objectField("title");
    try jw.write(task.title);

    try jw.objectField("status");
    try jw.write(@tagName(task.status));

    try jw.objectField("priority");
    try jw.write(@tagName(task.priority));

    try jw.objectField("priority_value");
    try jw.write(task.priority_value);

    try jw.objectField("owner");
    try jw.write(task.owner);

    try jw.objectField("created");
    var created_buf: [32]u8 = undefined;
    const created_str = try std.fmt.bufPrint(&created_buf, "{f}", .{task.created.as(.@"YYYY-MM-DDTHH:MM:SSZ")});

    try jw.write(created_str);

    try jw.objectField("completed");
    if (task.completed) |completed| {
        var completed_buf: [32]u8 = undefined;
        const completed_str = try std.fmt.bufPrint(&completed_buf, "{f}", .{completed.as(.@"YYYY-MM-DDTHH:MM:SSZ")});
        try jw.write(completed_str);
    } else {
        try jw.write(null);
    }

    try jw.objectField("tags");
    if (task.tags) |tags| {
        try jw.beginArray();
        for (tags) |tag| {
            try jw.write(tag);
        }
        try jw.endArray();
    } else {
        try jw.write(null);
    }

    try jw.objectField("waiting_on");
    if (task.waiting_on) |waiting_on| {
        try jw.beginArray();
        for (waiting_on) |item| {
            try jw.write(item);
        }
        try jw.endArray();
    } else {
        try jw.write(null);
    }

    try jw.objectField("description");
    try jw.write(task.description);

    try jw.objectField("file_path");
    try jw.write(file_path);

    try jw.endObject();
}

pub fn getString(params: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = params.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

pub fn getStringArray(params: std.json.ObjectMap, key: []const u8, allocator: std.mem.Allocator) ?[]const []const u8 {
    const val = params.get(key) orelse return null;
    return switch (val) {
        .array => |arr| {
            var result = allocator.alloc([]const u8, arr.items.len) catch return null;
            for (arr.items, 0..) |item, i| {
                switch (item) {
                    .string => |s| result[i] = s,
                    else => return null,
                }
            }
            return result;
        },
        else => null,
    };
}

pub fn getPriority(params: std.json.ObjectMap, key: []const u8) ?gila.Priority {
    const val = params.get(key) orelse return null;
    return switch (val) {
        .string => |s| std.meta.stringToEnum(gila.Priority, s),
        else => null,
    };
}

pub fn getStatus(params: std.json.ObjectMap, key: []const u8) ?gila.Status {
    const val = params.get(key) orelse return null;
    return switch (val) {
        .string => |s| std.meta.stringToEnum(gila.Status, s),
        else => null,
    };
}

pub fn getU8(params: std.json.ObjectMap, key: []const u8) ?u8 {
    const val = params.get(key) orelse return null;
    return switch (val) {
        .integer => |i| if (i >= 0 and i <= 255) @intCast(i) else null,
        else => null,
    };
}

pub fn getU64(params: std.json.ObjectMap, key: []const u8) ?u64 {
    const val = params.get(key) orelse return null;
    return switch (val) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

pub const Op = @import("find.zig").Op;

pub fn getOp(params: std.json.ObjectMap, key: []const u8) Op {
    const val = params.get(key) orelse return .@"or";
    return switch (val) {
        .string => |s| std.meta.stringToEnum(Op, s) orelse .@"or",
        else => .@"or",
    };
}

pub const Field = enum {
    id,
    status,
    title,
    priority,
    priority_value,
    owner,
    created,
    completed,
    description,
    tags,
    waiting_on,
    file_path,
};

pub const default_fields: []const Field = &.{ .id, .status, .title };

pub fn getFields(params: std.json.ObjectMap, allocator: std.mem.Allocator) []const Field {
    const val = params.get("fields") orelse return default_fields;
    return switch (val) {
        .array => |arr| {
            var result = allocator.alloc(Field, arr.items.len) catch return default_fields;
            var count: usize = 0;
            for (arr.items) |item| {
                switch (item) {
                    .string => |s| {
                        if (std.meta.stringToEnum(Field, s)) |f| {
                            result[count] = f;
                            count += 1;
                        }
                    },
                    else => {},
                }
            }
            if (count == 0) return default_fields;
            return result[0..count];
        },
        else => default_fields,
    };
}

pub fn hasField(fields: []const Field, field: Field) bool {
    for (fields) |f| {
        if (f == field) return true;
    }
    return false;
}

pub fn writeTaskFields(jw: *std.json.Stringify, task: gila.Task, file_path: []const u8, fields: []const Field) !void {
    try jw.beginObject();

    if (hasField(fields, .id)) {
        try jw.objectField("id");
        try jw.write(task.id);
    }

    if (hasField(fields, .title)) {
        try jw.objectField("title");
        try jw.write(task.title);
    }

    if (hasField(fields, .status)) {
        try jw.objectField("status");
        try jw.write(@tagName(task.status));
    }

    if (hasField(fields, .priority)) {
        try jw.objectField("priority");
        try jw.write(@tagName(task.priority));
    }

    if (hasField(fields, .priority_value)) {
        try jw.objectField("priority_value");
        try jw.write(task.priority_value);
    }

    if (hasField(fields, .owner)) {
        try jw.objectField("owner");
        try jw.write(task.owner);
    }

    if (hasField(fields, .created)) {
        try jw.objectField("created");
        var created_buf: [32]u8 = undefined;
        const created_str = try std.fmt.bufPrint(&created_buf, "{f}", .{task.created.as(.@"YYYY-MM-DDTHH:MM:SSZ")});
        try jw.write(created_str);
    }

    if (hasField(fields, .completed)) {
        try jw.objectField("completed");
        if (task.completed) |completed| {
            var completed_buf: [32]u8 = undefined;
            const completed_str = try std.fmt.bufPrint(&completed_buf, "{f}", .{completed.as(.@"YYYY-MM-DDTHH:MM:SSZ")});
            try jw.write(completed_str);
        } else {
            try jw.write(null);
        }
    }

    if (hasField(fields, .tags)) {
        try jw.objectField("tags");
        if (task.tags) |tags| {
            try jw.beginArray();
            for (tags) |tag| {
                try jw.write(tag);
            }
            try jw.endArray();
        } else {
            try jw.write(null);
        }
    }

    if (hasField(fields, .waiting_on)) {
        try jw.objectField("waiting_on");
        if (task.waiting_on) |waiting_on| {
            try jw.beginArray();
            for (waiting_on) |item| {
                try jw.write(item);
            }
            try jw.endArray();
        } else {
            try jw.write(null);
        }
    }

    if (hasField(fields, .description)) {
        try jw.objectField("description");
        try jw.write(task.description);
    }

    if (hasField(fields, .file_path)) {
        try jw.objectField("file_path");
        try jw.write(file_path);
    }

    try jw.endObject();
}
