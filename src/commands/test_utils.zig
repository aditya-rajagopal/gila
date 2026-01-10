const std = @import("std");
const testing = std.testing;
const gila = @import("gila");
const stdx = @import("stdx");
const builtin = @import("builtin");
const TestFs = if (builtin.is_test) @import("test_fs").TestFs else void;

const Task = gila.Task;

/// Initialize a gila project with all status directories
pub fn initGilaProject(fs: *TestFs) !void {
    try fs.createDir(".gila");
    try fs.createDir(".gila/todo");
    try fs.createDir(".gila/started");
    try fs.createDir(".gila/done");
    try fs.createDir(".gila/cancelled");
    try fs.createDir(".gila/waiting");
}

/// Initialize a minimal gila project with only todo directory
pub fn initGilaProjectMinimal(fs: *TestFs) !void {
    try fs.createDir(".gila");
    try fs.createDir(".gila/todo");
}

/// Create a task file with the given parameters
pub fn createTaskFile(
    fs: *TestFs,
    status: []const u8,
    task_id: []const u8,
    title: []const u8,
    priority: []const u8,
    extra_fields: []const u8,
    description: []const u8,
) !void {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, ".gila/{s}/{s}/{s}.md", .{ status, task_id, task_id }) catch unreachable;

    var content_buf: [4096]u8 = undefined;
    const content = std.fmt.bufPrint(&content_buf,
        \\---
        \\title: {s}
        \\status: {s}
        \\priority_value: 50
        \\priority: {s}
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\{s}---
        \\{s}
    , .{ title, status, priority, extra_fields, description }) catch unreachable;

    try fs.createFile(path, content);
}

/// Create a task file with default priority and description
pub fn createTaskFileSimple(
    fs: *TestFs,
    status: []const u8,
    task_id: []const u8,
    title: []const u8,
    extra_fields: []const u8,
) !void {
    try createTaskFile(fs, status, task_id, title, "medium", extra_fields, "Test task description");
}

/// Read and parse a task file from the filesystem
pub fn readAndParseTask(fs: *TestFs, task_id: []const u8, status: gila.Status) !Task {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, ".gila/{s}/{s}/{s}.md", .{
        @tagName(status),
        task_id,
        task_id,
    }) catch unreachable;

    var arena_buf: [8192]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    const content = try fs.readFile(path);
    var reader = std.Io.Reader.fixed(content);

    var task = Task.init(task_id) catch return error.InvalidTaskId;
    var diagnostic: ?Task.Diagnostic = null;
    task.fromReader(&reader, &arena, &diagnostic) catch {
        std.debug.print("Task parse error: {s}\n", .{diagnostic.?.message});
        return error.TaskParseError;
    };

    return task;
}

/// Validate a task
pub fn validateTask(task: *const Task) !void {
    var error_out: ?[]const u8 = null;
    task.validate(&error_out) catch {
        std.debug.print("Task validation error: {s}\n", .{error_out orelse "unknown"});
        return error.TaskValidationFailed;
    };
}

/// Expect that a string contains a substring
pub fn expectContains(haystack: []const u8, expected: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, expected) == null) {
        std.debug.print("\nExpected to contain: '{s}'\nActual: '{s}'\n", .{ expected, haystack });
        return error.TestExpectationFailed;
    }
}

/// Expect that a string does not contain a substring
pub fn expectNotContains(haystack: []const u8, unexpected: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, unexpected) != null) {
        std.debug.print("\nExpected NOT to contain: '{s}'\nActual: '{s}'\n", .{ unexpected, haystack });
        return error.TestExpectationFailed;
    }
}

/// Expect stdout contains a substring
pub fn expectStdoutContains(fs: *TestFs, expected: []const u8) !void {
    try expectContains(fs.getStdout(), expected);
}

/// Expect stdout does not contain a substring
pub fn expectStdoutNotContains(fs: *TestFs, unexpected: []const u8) !void {
    try expectNotContains(fs.getStdout(), unexpected);
}

/// Expect JSON response contains an error code
pub fn expectErrorCode(response: []const u8, code: i32) !void {
    var code_buf: [32]u8 = undefined;
    const code_str = std.fmt.bufPrint(&code_buf, "\"code\":{d}", .{code}) catch unreachable;
    try expectContains(response, code_str);
}

/// Extract task ID from CLI stdout (format: "New task created: <task_id>")
pub fn extractTaskIdFromStdout(stdout: []const u8) ?[]const u8 {
    const prefix = "New task created: ";
    const start = std.mem.indexOf(u8, stdout, prefix) orelse return null;
    const id_start = start + prefix.len;
    const end = std.mem.indexOfPos(u8, stdout, id_start, "\n") orelse return null;
    return stdout[id_start..end];
}

/// Extract task_id from JSON-RPC response
pub fn extractTaskIdFromJsonResponse(allocator: std.mem.Allocator, response: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    const result = parsed.value.object.get("result") orelse return error.NoResult;
    const task_id = result.object.get("task_id") orelse return error.NoTaskId;
    return task_id.string;
}
