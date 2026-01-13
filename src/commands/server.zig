const std = @import("std");
const root = @import("root");

const gila = @import("gila");
const stdx = @import("stdx");

const common = @import("common.zig");
const rpc = @import("server_rpc.zig");
const Handler = @import("server_handler.zig");

const log = std.log.scoped(.server);

const Server = @This();

run_once: bool = false,

pub const help = gila.logo ++
    \\Usage:
    \\    gila server [-h | --help] [--run-once]
    \\
    \\Starts a JSON-RPC 2.0 server for external tool integration (e.g., Neovim plugin).
    \\Communicates via stdin/stdout with line-delimited JSON.
    \\See SERVER.md for more information.
    \\
    \\Methods:
    \\    task/create   Create a new task
    \\                  Params: title (required), username (required), description?, priority?, priority_value?, tags?, waiting_on?, blocks?
    \\                  Returns: task_id, file_path, status
    \\
    \\    task/get      Get task details by ID
    \\                  Params: task_id (required)
    \\                  Returns: Full task object (id, title, status, priority, priority_value, owner, created, completed, tags, waiting_on, description, file_path)
    \\
    \\    task/update   Update task status or fields
    \\                  Params: task_id (required), status?, title?, description?, priority?, priority_value?, tags?
    \\                  Returns: task_id, status, file_path, completed
    \\
    \\    task/find     Find tasks by filters
    \\                  Params: priority?, status?, tags?, tags_op?, waiting_on?, waiting_on_op?, limit?, offset?, fields?
    \\                  Returns: tasks (array), available, count, limit, offset
    \\
    \\    task/sync     Reconcile task state with filesystem
    \\                  Params: none
    \\                  Returns: transitions (array with task_id, from, to), updates (array with task_id, change, dependency), count
    \\
    \\    shutdown      Stop the server gracefully
    \\                  Params: none
    \\                  Returns: message
    \\
    \\JSON-RPC 2.0 Format:
    \\    Request:  {"jsonrpc":"2.0","method":<string>,"params":{...},"id":<number|string|null>}
    \\    Response: {"jsonrpc":"2.0","result":{...},"id":<same as request>}
    \\    Error:    {"jsonrpc":"2.0","error":{"code":<number>,"message":<string>},"id":<same as request>}
    \\
    \\Error Codes:
    \\    -32700  Parse error
    \\    -32600  Invalid request
    \\    -32601  Method not found
    \\    -32602  Invalid params
    \\    -32603  Internal error
    \\    -32001  Task not found
    \\    -32002  Invalid task ID
    \\    -32003  Validation failed
    \\    -32004  Transition error
    \\    -32005  GILA directory not found
    \\
    \\Examples:
    \\    echo '{"jsonrpc":"2.0","method":"task/create","params":{"title":"Test task","username":"user"},"id":1}' | gila server
    \\    echo '{"jsonrpc":"2.0","method":"task/get","params":{"task_id":"abc_123"},"id":2}' | gila server
    \\    echo '{"jsonrpc":"2.0","method":"shutdown","id":3}' | gila server
    \\
;

// @LEFTOFF make the configuration for arena size, line buffer size, etc configurable
pub fn execute(self: Server, ctx: common.CommandContext) void {
    const io = ctx.io;
    const arena = ctx.arena;
    root.log_level = .err;

    const gila_path, var gila_dir = common.getGilaDir(io, arena.allocator()) orelse {
        rpc.sendStartupError(io, rpc.ErrorCode.gila_dir_not_found, "GILA directory not found. Run 'gila init' first.");
        return;
    };
    defer gila_dir.close(io);

    const smp = std.heap.smp_allocator;
    var request_arena = std.heap.ArenaAllocator.init(smp);
    const allocator = request_arena.allocator();
    _ = allocator.alignedAlloc(u8, .fromByteUnits(4096), 8 * 1024 * 1024) catch {
        rpc.sendStartupError(io, rpc.ErrorCode.internal_error, "Failed to allocate request buffer");
        return;
    };
    _ = request_arena.reset(.retain_capacity);

    const stdin_buffer = arena.pushArrayAligned(u8, .fromByteUnits(4096), 4096);
    var stdin = std.Io.File.stdin().reader(io, stdin_buffer);

    var running = true;
    if (self.run_once) {
        const line_buffer = allocator.alloc(u8, 1 * 1024 * 1024) catch unreachable;
        var line_writer = std.Io.Writer.fixed(line_buffer);

        const line = stdin.interface.streamDelimiterLimit(&line_writer, '\n', .limited(1 * 1024 * 1024)) catch |err| switch (err) {
            error.ReadFailed, error.WriteFailed => {
                rpc.sendError(io, null, .internal_error, "Failed to read from stdin");
                return;
            },
            error.StreamTooLong => {
                _ = stdin.interface.discardDelimiterInclusive('\n') catch |e| switch (e) {
                    error.ReadFailed => rpc.sendError(io, null, .internal_error, "Reader failed"),
                    error.EndOfStream => {
                        rpc.sendError(io, null, .internal_error, "STDIN closed");
                        return;
                    },
                };
                rpc.sendError(io, null, .invalid_request, "Request too long");
                return;
            },
        };
        if (stdin.interface.end == stdin.interface.seek) {
            rpc.sendError(io, null, .internal_error, "STDIN closed");
            return;
        }
        if (line == 0) {
            rpc.sendError(io, null, .invalid_request, "Empty request");
            return;
        }
        stdin.interface.toss(1);
        const data = line_writer.buffered();

        running = handleRequest(io, gila_dir, gila_path, &request_arena, data);
    } else {
        while (running) {
            _ = request_arena.reset(.retain_capacity);

            const line_buffer = allocator.alloc(u8, 1 * 1024 * 1024) catch unreachable;
            var line_writer = std.Io.Writer.fixed(line_buffer);

            const line = stdin.interface.streamDelimiterLimit(&line_writer, '\n', .limited(1 * 1024 * 1024)) catch |err| switch (err) {
                error.ReadFailed, error.WriteFailed => continue,
                error.StreamTooLong => {
                    _ = stdin.interface.discardDelimiterInclusive('\n') catch |e| switch (e) {
                        error.ReadFailed => rpc.sendError(io, null, .internal_error, "Reader failed"),
                        error.EndOfStream => {
                            rpc.sendError(io, null, .internal_error, "STDIN closed");
                            break;
                        },
                    };
                    rpc.sendError(io, null, .invalid_request, "Request too long");
                    continue;
                },
            };
            if (stdin.interface.end == stdin.interface.seek) {
                rpc.sendError(io, null, .internal_error, "STDIN closed");
                break;
            }
            if (line == 0) {
                rpc.sendError(io, null, .invalid_request, "Empty request");
                continue;
            }
            stdin.interface.toss(1);
            const data = line_writer.buffered();

            running = handleRequest(io, gila_dir, gila_path, &request_arena, data);
        }
    }
}

// @LEFTOFF make error messages have a print function to append payloads to the message for better error reporting
fn handleRequest(
    io: std.Io,
    gila_dir: std.Io.Dir,
    gila_path: []const u8,
    arena: *std.heap.ArenaAllocator,
    line: []const u8,
) bool {
    const allocator = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        rpc.sendError(io, null, rpc.ErrorCode.parse_error, "Parse error: invalid JSON");
        return true;
    };

    const root_value = parsed.value;
    if (root_value != .object) {
        rpc.sendError(io, null, rpc.ErrorCode.invalid_request, "Request must be a JSON object");
        return true;
    }

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse {
        rpc.sendError(io, null, rpc.ErrorCode.invalid_request, "Missing 'jsonrpc' field");
        return true;
    };
    if (jsonrpc_val != .string or !std.mem.eql(u8, jsonrpc_val.string, "2.0")) {
        rpc.sendError(io, null, rpc.ErrorCode.invalid_request, "Invalid jsonrpc version, expected '2.0'");
        return true;
    }

    const id_val = root_value.object.get("id") orelse {
        rpc.sendError(io, null, rpc.ErrorCode.invalid_request, "Missing 'id' field");
        return true;
    };
    const id = rpc.RequestId.fromValue(id_val) orelse {
        rpc.sendError(io, null, rpc.ErrorCode.invalid_request, "Invalid 'id' field type");
        return true;
    };

    const method_val = root_value.object.get("method") orelse {
        rpc.sendError(io, id, rpc.ErrorCode.invalid_request, "Missing 'method' field");
        return true;
    };
    if (method_val != .string) {
        rpc.sendError(io, id, rpc.ErrorCode.invalid_request, "'method' must be a string");
        return true;
    }
    const method: Handler.Method = std.meta.stringToEnum(Handler.Method, method_val.string) orelse {
        rpc.sendError(io, id, rpc.ErrorCode.invalid_request, "Invalid method");
        return true;
    };

    const params = root_value.object.get("params");

    const stdout_buffer = arena.allocator().alloc(u8, 4096) catch {
        rpc.sendError(io, id, .internal_error, "Failed to allocate response buffer");
        return true;
    };
    const resp = arena.allocator().create(rpc.ResponseWriter) catch {
        rpc.sendError(io, id, .internal_error, "Failed to allocate response writer");
        return true;
    };
    resp.init(io, id, stdout_buffer);

    const handler: Handler = .{
        .io = io,
        .gila_dir = gila_dir,
        .gila_path = gila_path,
        .arena = arena,
        .id = id,
        .resp = resp,
        .params = params,
    };
    return handler.dispatch(method);
}

const testing = std.testing;
const builtin = @import("builtin");
const TestFs = if (builtin.is_test) @import("test_fs").TestFs else void;
const test_utils = @import("test_utils.zig");

const initGilaProject = test_utils.initGilaProject;
const createTaskFile = test_utils.createTaskFileSimple;
const expectResponseContains = test_utils.expectContains;
const expectResponseNotContains = test_utils.expectNotContains;
const expectErrorCode = test_utils.expectErrorCode;
const extractTaskIdFromResponse = test_utils.extractTaskIdFromJsonResponse;
const readAndParseTask = test_utils.readAndParseTask;
const validateTask = test_utils.validateTask;

fn runServer(fs: *TestFs, arena: *stdx.Arena) void {
    const server: Server = .{ .run_once = true };
    const context = common.CommandContext{ .io = fs.io(), .arena = arena, .username = "testuser", .editor = "nvim" };
    server.execute(context);
}

test "task/create: basic task creation" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try fs.createDir(".gila");

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{"title":"Test task", "username":"testuser"},"id":1}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});

    const root_value = parsed.value;
    try std.testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try std.testing.expect(jsonrpc_val == .string);
    try std.testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try std.testing.expect(id_val == .integer);
    try std.testing.expectEqual(@as(i64, 1), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try std.testing.expect(result_val == .object);
    {
        const status_val = result_val.object.get("status") orelse return error.NoStatus;
        try testing.expect(status_val == .string);
        try testing.expectEqualStrings("todo", status_val.string);

        const task_id_val = result_val.object.get("task_id") orelse return error.NoTaskId;
        try std.testing.expect(task_id_val == .string);
        try std.testing.expect(gila.id.isValid(task_id_val.string));

        const task_id: []const u8 = task_id_val.string;
        var dir_path_buf: [256]u8 = undefined;

        const dir_path = std.fmt.bufPrint(&dir_path_buf, ".gila/todo/{s}", .{task_id}) catch unreachable;
        try testing.expect(fs.dirExists(dir_path));

        var file_path_buf: [256]u8 = undefined;
        const file_path = std.fmt.bufPrint(&file_path_buf, ".gila/todo/{s}/{s}.md", .{ task_id, task_id }) catch unreachable;
        try testing.expect(fs.fileExists(file_path));

        const task = try readAndParseTask(fs, task_id, .todo);
        try validateTask(&task);
        try testing.expectEqual(gila.Status.todo, task.status);
        try testing.expectEqualStrings("Test task", task.title);
        try testing.expectEqual(gila.Priority.medium, task.priority);
        try testing.expectEqual(@as(u8, 50), task.priority_value);
        try testing.expectEqualStrings("testuser", task.owner);

        const file_path_val = result_val.object.get("file_path") orelse return error.NoFilePath;
        try testing.expect(file_path_val == .string);
        var full_path_buf: [255]u8 = undefined;
        const full_path = std.fmt.bufPrint(&full_path_buf, "/home/test/{s}", .{file_path}) catch unreachable;
        try testing.expectEqualStrings(full_path, file_path_val.string);
    }
}

test "task/create: with all optional params" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{"title":"Full task", "username":"testuser","description":"Task description","priority":"high","priority_value":75,"tags":["feature","backend"]},"id":2}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 2), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);
    {
        const status_val = result_val.object.get("status") orelse return error.NoStatus;
        try testing.expect(status_val == .string);
        try testing.expectEqualStrings("todo", status_val.string);

        const task_id_val = result_val.object.get("task_id") orelse return error.NoTaskId;
        try std.testing.expect(task_id_val == .string);
        try std.testing.expect(gila.id.isValid(task_id_val.string));

        const task_id: []const u8 = task_id_val.string;
        var dir_path_buf: [256]u8 = undefined;

        const dir_path = std.fmt.bufPrint(&dir_path_buf, ".gila/todo/{s}", .{task_id}) catch unreachable;
        try testing.expect(fs.dirExists(dir_path));

        var file_path_buf: [256]u8 = undefined;
        const file_path = std.fmt.bufPrint(&file_path_buf, ".gila/todo/{s}/{s}.md", .{ task_id, task_id }) catch unreachable;
        try testing.expect(fs.fileExists(file_path));

        const task = try readAndParseTask(fs, task_id, .todo);
        try validateTask(&task);
        try testing.expectEqual(gila.Status.todo, task.status);
        try testing.expectEqualStrings("Full task", task.title);
        try testing.expectEqual(gila.Priority.high, task.priority);
        try testing.expectEqual(@as(u8, 75), task.priority_value);
        try testing.expectEqualStrings("testuser", task.owner);
        try testing.expectEqualStrings("Task description", task.description);
        try testing.expect(task.tags != null);
        try testing.expectEqual(2, task.tags.?.len);
        try testing.expectEqualStrings("feature", task.tags.?[0]);
        try testing.expectEqualStrings("backend", task.tags.?[1]);

        const file_path_val = result_val.object.get("file_path") orelse return error.NoFilePath;
        try testing.expect(file_path_val == .string);
        var full_path_buf: [255]u8 = undefined;
        const full_path = std.fmt.bufPrint(&full_path_buf, "/home/test/{s}", .{file_path}) catch unreachable;
        try testing.expectEqualStrings(full_path, file_path_val.string);
    }
}

test "task/create: with waiting_on sets status to waiting" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);
    try createTaskFile(fs, "todo", "test_task_abc", "Blocking task", "");

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{"title":"Waiting task", "username":"testuser","waiting_on":["test_task_abc"]},"id":3}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 3), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);
    {
        const status_val = result_val.object.get("status") orelse return error.nostatus;
        try testing.expect(status_val == .string);
        try testing.expectEqualStrings("waiting", status_val.string);

        const task_id_val = result_val.object.get("task_id") orelse return error.NoTaskId;
        try std.testing.expect(task_id_val == .string);
        try std.testing.expect(gila.id.isValid(task_id_val.string));

        const task_id: []const u8 = task_id_val.string;
        var dir_path_buf: [256]u8 = undefined;

        const dir_path = std.fmt.bufPrint(&dir_path_buf, ".gila/todo/{s}", .{task_id}) catch unreachable;
        try testing.expect(!fs.dirExists(dir_path));

        var file_path_buf: [256]u8 = undefined;
        const file_path = std.fmt.bufPrint(&file_path_buf, ".gila/waiting/{s}/{s}.md", .{ task_id, task_id }) catch unreachable;
        try testing.expect(fs.fileExists(file_path));

        const task = try readAndParseTask(fs, task_id, .waiting);
        try validateTask(&task);
        try testing.expectEqual(gila.Status.waiting, task.status);
        try testing.expectEqualStrings("Waiting task", task.title);
        try testing.expectEqual(gila.Priority.medium, task.priority);
        try testing.expectEqual(@as(u8, 50), task.priority_value);
        try testing.expectEqualStrings("testuser", task.owner);
        try testing.expect(task.tags == null);
        try testing.expect(task.waiting_on != null);
        try testing.expectEqual(1, task.waiting_on.?.len);
        try testing.expectEqualStrings("\"[[test_task_abc]]\"", task.waiting_on.?[0]);

        const file_path_val = result_val.object.get("file_path") orelse return error.NoFilePath;
        try testing.expect(file_path_val == .string);
        var full_path_buf: [255]u8 = undefined;
        const full_path = std.fmt.bufPrint(&full_path_buf, "/home/test/{s}", .{file_path}) catch unreachable;
        try testing.expectEqualStrings(full_path, file_path_val.string);
    }
}

test "task/create: missing title returns error" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{},"id":4}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 4), id_val.integer);

    const error_val = root_value.object.get("error") orelse return error.NoError;
    try testing.expect(error_val == .object);
    {
        const code_val = error_val.object.get("code") orelse return error.NoCode;
        try testing.expect(code_val == .integer);
        try testing.expectEqual(@as(i64, -32602), code_val.integer);

        const message_val = error_val.object.get("message") orelse return error.NoMessage;
        try testing.expect(message_val == .string);
        try testing.expect(std.mem.indexOf(u8, message_val.string, "Missing required field: title") != null);
    }
}

test "task/create: empty title returns error" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{"title":""},"id":5}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 5), id_val.integer);

    const error_val = root_value.object.get("error") orelse return error.NoError;
    try testing.expect(error_val == .object);
    {
        const code_val = error_val.object.get("code") orelse return error.NoCode;
        try testing.expect(code_val == .integer);
        try testing.expectEqual(@as(i64, -32602), code_val.integer);

        const message_val = error_val.object.get("message") orelse return error.NoMessage;
        try testing.expect(message_val == .string);
        try testing.expect(std.mem.indexOf(u8, message_val.string, "Title cannot be empty") != null);
    }
}

test "task/create: invalid waiting_on task id returns error" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{"title":"Test","username":"testuser","waiting_on":["invalid-id"]},"id":6}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 6), id_val.integer);

    const error_val = root_value.object.get("error") orelse return error.NoError;
    try testing.expect(error_val == .object);
    {
        const code_val = error_val.object.get("code") orelse return error.NoCode;
        try testing.expect(code_val == .integer);
        try testing.expectEqual(@as(i64, -32002), code_val.integer);
    }
}

test "task/create: with string id" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{"title":"Test task", "username":"testuser"},"id":"string-id"}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .string);
    try testing.expectEqualStrings("string-id", id_val.string);
}

test "task/create: with null id" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{"title":"Test task", "username":"testuser"},"id":null}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .null);
}

test "task/get: existing task" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);
    try createTaskFile(fs, "todo", "test_task_xyz", "My test task", "");

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/get","params":{"task_id":"test_task_xyz"},"id":10}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const req_id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(req_id_val == .integer);
    try testing.expectEqual(@as(i64, 10), req_id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);
    {
        const id_val = result_val.object.get("task_id") orelse return error.NoTaskId;
        try testing.expect(id_val == .string);
        try testing.expectEqualStrings("test_task_xyz", id_val.string);

        const title_val = result_val.object.get("title") orelse return error.NoTitle;
        try testing.expect(title_val == .string);
        try testing.expectEqualStrings("My test task", title_val.string);

        const status_val = result_val.object.get("status") orelse return error.NoStatus;
        try testing.expect(status_val == .string);
        try testing.expectEqualStrings("todo", status_val.string);

        const priority_val = result_val.object.get("priority") orelse return error.NoPriority;
        try testing.expect(priority_val == .string);
        try testing.expectEqualStrings("medium", priority_val.string);

        const description_val = result_val.object.get("description") orelse return error.NoDescription;
        try testing.expect(description_val == .string);
        try testing.expectEqualStrings("Test task description", description_val.string);

        const file_path_val = result_val.object.get("file_path") orelse return error.NoFilePath;
        try testing.expect(file_path_val == .string);
        var path_buf: [256]u8 = undefined;
        const file_path = std.fmt.bufPrint(&path_buf, "/home/test/.gila/todo/{s}/{s}.md", .{ id_val.string, id_val.string }) catch unreachable;
        try testing.expectEqualStrings(file_path, file_path_val.string);
    }
}

test "task/get: path_only" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);
    try createTaskFile(fs, "todo", "test_task_xyz", "My test task", "");

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/get","params":{"task_id":"test_task_xyz", "path_only":true},"id":10}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const req_id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(req_id_val == .integer);
    try testing.expectEqual(@as(i64, 10), req_id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);
    {
        const file_path_val = result_val.object.get("file_path") orelse return error.NoFilePath;
        try testing.expect(file_path_val == .string);
        try testing.expect(std.mem.indexOf(u8, file_path_val.string, "test_task_xyz") != null);
    }

    try testing.expect(result_val.object.get("title") == null);
    try testing.expect(result_val.object.get("status") == null);
}

test "task/get: task not found" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/get","params":{"task_id":"nonexist_task_xyz"},"id":11}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 11), id_val.integer);

    const error_val = root_value.object.get("error") orelse return error.NoError;
    try testing.expect(error_val == .object);
    {
        const code_val = error_val.object.get("code") orelse return error.NoCode;
        try testing.expect(code_val == .integer);
        try testing.expectEqual(@as(i64, -32001), code_val.integer);

        const message_val = error_val.object.get("message") orelse return error.NoMessage;
        try testing.expect(message_val == .string);
        try testing.expect(std.mem.indexOf(u8, message_val.string, "Task not found") != null);
    }
}

test "task/get: invalid task id format" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/get","params":{"task_id":"invalid-format"},"id":12}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 12), id_val.integer);

    const error_val = root_value.object.get("error") orelse return error.NoError;
    try testing.expect(error_val == .object);
    {
        const code_val = error_val.object.get("code") orelse return error.NoCode;
        try testing.expect(code_val == .integer);
        try testing.expectEqual(@as(i64, -32002), code_val.integer);

        const message_val = error_val.object.get("message") orelse return error.NoMessage;
        try testing.expect(message_val == .string);
        try testing.expect(std.mem.indexOf(u8, message_val.string, "Invalid task ID format") != null);
    }
}

test "task/get: missing task_id param" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/get","params":{},"id":13}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 13), id_val.integer);

    const error_val = root_value.object.get("error") orelse return error.NoError;
    try testing.expect(error_val == .object);
    {
        const code_val = error_val.object.get("code") orelse return error.NoCode;
        try testing.expect(code_val == .integer);
        try testing.expectEqual(@as(i64, -32602), code_val.integer);

        const message_val = error_val.object.get("message") orelse return error.NoMessage;
        try testing.expect(message_val == .string);
        try testing.expect(std.mem.indexOf(u8, message_val.string, "Missing required field: task_id") != null);
    }
}

test "task/update: update title" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);
    try createTaskFile(fs, "todo", "update_task_aaa", "Original title", "");

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/update","params":{"task_id":"update_task_aaa","title":"Updated title"},"id":20}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 20), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);
    {
        const task_id_val = result_val.object.get("task_id") orelse return error.NoTaskId;
        try testing.expect(task_id_val == .string);
        try testing.expectEqualStrings("update_task_aaa", task_id_val.string);

        var file_path_buf: [256]u8 = undefined;
        const file_path = std.fmt.bufPrint(&file_path_buf, ".gila/todo/{s}/{s}.md", .{ task_id_val.string, task_id_val.string }) catch unreachable;
        try testing.expect(fs.fileExists(file_path));

        const task = try readAndParseTask(fs, task_id_val.string, .todo);
        try validateTask(&task);
        try testing.expectEqual(gila.Status.todo, task.status);
        try testing.expectEqualStrings("Updated title", task.title);

        const status_val = result_val.object.get("status") orelse return error.NoStatus;
        try testing.expect(status_val == .string);
        try testing.expectEqualStrings("todo", status_val.string);
    }
}

test "task/update: update status todo to started" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);
    try createTaskFile(fs, "todo", "status_task_bbb", "Task to start", "");

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/update","params":{"task_id":"status_task_bbb","status":"started"},"id":21}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 21), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);
    {
        try testing.expect(!fs.dirExists(".gila/todo/status_task_bbb"));
        try testing.expect(fs.dirExists(".gila/started/status_task_bbb"));
        try testing.expect(fs.fileExists(".gila/started/status_task_bbb/status_task_bbb.md"));

        const task = try readAndParseTask(fs, "status_task_bbb", .started);
        try validateTask(&task);

        try testing.expectEqual(gila.Status.started, task.status);
        try testing.expectEqual(gila.Priority.medium, task.priority);
        try testing.expectEqual(@as(u8, 50), task.priority_value);
        try testing.expectEqualStrings("testuser", task.owner);
        try testing.expectEqualStrings("Task to start", task.title);

        const status_val = result_val.object.get("status") orelse return error.NoStatus;
        try testing.expect(status_val == .string);
        try testing.expectEqualStrings("started", status_val.string);
    }
}

test "task/update: update status started to done" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);
    try createTaskFile(fs, "started", "done_task_ccc", "Task to complete", "");

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/update","params":{"task_id":"done_task_ccc","status":"done"},"id":22}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 22), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);
    {
        try testing.expect(!fs.dirExists(".gila/started/done_task_ccc"));
        try testing.expect(fs.dirExists(".gila/done/done_task_ccc"));

        const status_val = result_val.object.get("status") orelse return error.NoStatus;
        try testing.expect(status_val == .string);
        try testing.expectEqualStrings("done", status_val.string);

        const completed_val = result_val.object.get("completed") orelse return error.NoCompleted;
        try testing.expect(completed_val == .string);
        _ = try stdx.DateTimeUTC.fromString(completed_val.string, .@"YYYY-MM-DDTHH:MM:SSZ");
    }
}

test "task/update: update priority" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);
    try createTaskFile(fs, "todo", "priority_task_eee", "Priority task", "");

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/update","params":{"task_id":"priority_task_eee","priority":"urgent","priority_value":100},"id":23}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 23), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);
    {
        const task_id_val = result_val.object.get("task_id") orelse return error.NoTaskId;
        try testing.expect(task_id_val == .string);
        try testing.expectEqualStrings("priority_task_eee", task_id_val.string);

        const status_val = result_val.object.get("status") orelse return error.NoStatus;
        try testing.expect(status_val == .string);
        try testing.expectEqualStrings("todo", status_val.string);

        const task = try readAndParseTask(fs, "priority_task_eee", .todo);
        try validateTask(&task);

        try testing.expectEqual(gila.Status.todo, task.status);
        try testing.expectEqual(gila.Priority.urgent, task.priority);
        try testing.expectEqual(@as(u8, 100), task.priority_value);
        try testing.expectEqualStrings("testuser", task.owner);
        try testing.expectEqualStrings("Priority task", task.title);
    }
}

test "task/update: task not found" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/update","params":{"task_id":"nonexist_task_abc"},"id":24}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 24), id_val.integer);

    const error_val = root_value.object.get("error") orelse return error.NoError;
    try testing.expect(error_val == .object);
    {
        const code_val = error_val.object.get("code") orelse return error.NoCode;
        try testing.expect(code_val == .integer);
        try testing.expectEqual(@as(i64, -32001), code_val.integer);
    }
}

test "task/update: invalid task id" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/update","params":{"task_id":"bad-id","title":"New title"},"id":25}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 25), id_val.integer);

    const error_val = root_value.object.get("error") orelse return error.NoError;
    try testing.expect(error_val == .object);

    const code_val = error_val.object.get("code") orelse return error.NoCode;
    try testing.expect(code_val == .integer);
    try testing.expectEqual(@as(i64, -32002), code_val.integer);
}

test "task/update: update tags" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);
    try createTaskFile(fs, "todo", "tags_task_ddd", "Tags task", "");

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/update","params":{"task_id":"tags_task_ddd","tags":["new-tag","another"]},"id":26}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 26), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);
    {
        const task = try readAndParseTask(fs, "tags_task_ddd", .todo);
        try validateTask(&task);

        try testing.expectEqual(gila.Status.todo, task.status);
        try testing.expect(task.tags != null);
        try testing.expectEqual(2, task.tags.?.len);
        try testing.expectEqualStrings("new-tag", task.tags.?[0]);
        try testing.expectEqualStrings("another", task.tags.?[1]);
    }
}

test "shutdown: returns success message" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"shutdown","id":30}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 30), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);

    const message_val = result_val.object.get("message") orelse return error.NoMessage;
    try testing.expect(message_val == .string);
    try testing.expectEqualStrings("Server shutting down", message_val.string);
}

test "error: invalid JSON" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin("{not valid json\n");

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .null);

    const error_val = root_value.object.get("error") orelse return error.NoError;
    try testing.expect(error_val == .object);

    const code_val = error_val.object.get("code") orelse return error.NoCode;
    try testing.expect(code_val == .integer);
    try testing.expectEqual(@as(i64, -32700), code_val.integer);

    const message_val = error_val.object.get("message") orelse return error.NoMessage;
    try testing.expect(message_val == .string);
    try testing.expect(std.mem.indexOf(u8, message_val.string, "Parse error") != null);
}

test "error: request not an object" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin("[1,2,3]\n");

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .null);

    const error_val = root_value.object.get("error") orelse return error.NoError;
    try testing.expect(error_val == .object);

    const code_val = error_val.object.get("code") orelse return error.NoCode;
    try testing.expect(code_val == .integer);
    try testing.expectEqual(@as(i64, -32600), code_val.integer);

    const message_val = error_val.object.get("message") orelse return error.NoMessage;
    try testing.expect(message_val == .string);
    try testing.expect(std.mem.indexOf(u8, message_val.string, "Request must be a JSON object") != null);
}

test "error: missing jsonrpc field" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"method":"task/create","params":{"title":"Test"},"id":1}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .null);

    const error_val = root_value.object.get("error") orelse return error.NoError;
    try testing.expect(error_val == .object);

    const code_val = error_val.object.get("code") orelse return error.NoCode;
    try testing.expect(code_val == .integer);
    try testing.expectEqual(@as(i64, -32600), code_val.integer);

    const message_val = error_val.object.get("message") orelse return error.NoMessage;
    try testing.expect(message_val == .string);
    try testing.expect(std.mem.indexOf(u8, message_val.string, "Missing 'jsonrpc' field") != null);
}

test "error: invalid jsonrpc version" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"1.0","method":"task/create","params":{"title":"Test"},"id":1}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .null);

    const error_val = root_value.object.get("error") orelse return error.NoError;
    try testing.expect(error_val == .object);

    const code_val = error_val.object.get("code") orelse return error.NoCode;
    try testing.expect(code_val == .integer);
    try testing.expectEqual(@as(i64, -32600), code_val.integer);

    const message_val = error_val.object.get("message") orelse return error.NoMessage;
    try testing.expect(message_val == .string);
    try testing.expect(std.mem.indexOf(u8, message_val.string, "Invalid jsonrpc version") != null);
}

test "error: missing id field" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{"title":"Test"}}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .null);

    const error_val = root_value.object.get("error") orelse return error.NoError;
    try testing.expect(error_val == .object);

    const code_val = error_val.object.get("code") orelse return error.NoCode;
    try testing.expect(code_val == .integer);
    try testing.expectEqual(@as(i64, -32600), code_val.integer);

    const message_val = error_val.object.get("message") orelse return error.NoMessage;
    try testing.expect(message_val == .string);
    try testing.expect(std.mem.indexOf(u8, message_val.string, "Missing 'id' field") != null);
}

test "error: invalid id type" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{"title":"Test"},"id":[1,2]}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .null);

    const error_val = root_value.object.get("error") orelse return error.NoError;
    try testing.expect(error_val == .object);

    const code_val = error_val.object.get("code") orelse return error.NoCode;
    try testing.expect(code_val == .integer);
    try testing.expectEqual(@as(i64, -32600), code_val.integer);

    const message_val = error_val.object.get("message") orelse return error.NoMessage;
    try testing.expect(message_val == .string);
    try testing.expect(std.mem.indexOf(u8, message_val.string, "Invalid 'id' field type") != null);
}

test "error: missing method field" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","params":{"title":"Test"},"id":1}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 1), id_val.integer);

    const error_val = root_value.object.get("error") orelse return error.NoError;
    try testing.expect(error_val == .object);

    const code_val = error_val.object.get("code") orelse return error.NoCode;
    try testing.expect(code_val == .integer);
    try testing.expectEqual(@as(i64, -32600), code_val.integer);

    const message_val = error_val.object.get("message") orelse return error.NoMessage;
    try testing.expect(message_val == .string);
    try testing.expect(std.mem.indexOf(u8, message_val.string, "Missing 'method' field") != null);
}

test "error: method not a string" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":123,"params":{"title":"Test"},"id":1}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 1), id_val.integer);

    const error_val = root_value.object.get("error") orelse return error.NoError;
    try testing.expect(error_val == .object);

    const code_val = error_val.object.get("code") orelse return error.NoCode;
    try testing.expect(code_val == .integer);
    try testing.expectEqual(@as(i64, -32600), code_val.integer);

    const message_val = error_val.object.get("message") orelse return error.NoMessage;
    try testing.expect(message_val == .string);
    try testing.expect(std.mem.indexOf(u8, message_val.string, "'method' must be a string") != null);
}

test "error: unknown method" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"unknown/method","params":{},"id":1}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 1), id_val.integer);

    const error_val = root_value.object.get("error") orelse return error.NoError;
    try testing.expect(error_val == .object);

    const code_val = error_val.object.get("code") orelse return error.NoCode;
    try testing.expect(code_val == .integer);
    try testing.expectEqual(@as(i64, -32600), code_val.integer);

    const message_val = error_val.object.get("message") orelse return error.NoMessage;
    try testing.expect(message_val == .string);
    try testing.expect(std.mem.indexOf(u8, message_val.string, "Invalid method") != null);
}

test "error: params not an object" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":"not-an-object","id":1}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 1), id_val.integer);

    const error_val = root_value.object.get("error") orelse return error.NoError;
    try testing.expect(error_val == .object);

    const code_val = error_val.object.get("code") orelse return error.NoCode;
    try testing.expect(code_val == .integer);
    try testing.expectEqual(@as(i64, -32602), code_val.integer);

    const message_val = error_val.object.get("message") orelse return error.NoMessage;
    try testing.expect(message_val == .string);
    try testing.expect(std.mem.indexOf(u8, message_val.string, "Params must be an object") != null);
}

test "error: missing params for task/create" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","id":1}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 1), id_val.integer);

    const error_val = root_value.object.get("error") orelse return error.NoError;
    try testing.expect(error_val == .object);

    const code_val = error_val.object.get("code") orelse return error.NoCode;
    try testing.expect(code_val == .integer);
    try testing.expectEqual(@as(i64, -32602), code_val.integer);

    const message_val = error_val.object.get("message") orelse return error.NoMessage;
    try testing.expect(message_val == .string);
    try testing.expect(std.mem.indexOf(u8, message_val.string, "Missing params") != null);
}

test "error: no gila directory" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{"title":"Test"},"id":1}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .null);

    const error_val = root_value.object.get("error") orelse return error.NoError;
    try testing.expect(error_val == .object);

    const code_val = error_val.object.get("code") orelse return error.NoCode;
    try testing.expect(code_val == .integer);
    try testing.expectEqual(@as(i64, -32005), code_val.integer);

    const message_val = error_val.object.get("message") orelse return error.NoMessage;
    try testing.expect(message_val == .string);
    try testing.expect(std.mem.indexOf(u8, message_val.string, "GILA directory not found") != null);
}

test "workflow: create then get task" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{"title":"Workflow task","username":"testuser","description":"My description"},"id":100}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const create_response = fs.getStdout();
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, create_response, .{});
        const root_value = parsed.value;
        try testing.expect(root_value == .object);

        const result_val = root_value.object.get("result") orelse return error.NoResult;
        try testing.expect(result_val == .object);
    }

    const task_id = try extractTaskIdFromResponse(testing.allocator, create_response);

    fs.clearStdout();
    _ = arena.reset(false);

    var get_request_buf: [256]u8 = undefined;
    const get_request = std.fmt.bufPrint(&get_request_buf,
        \\{{"jsonrpc":"2.0","method":"task/get","params":{{"task_id":"{s}"}},"id":101}}
        \\
    , .{task_id}) catch unreachable;

    fs.setStdin(get_request);
    runServer(fs, &arena);

    const get_response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, get_response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 101), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);

    const title_val = result_val.object.get("title") orelse return error.NoTitle;
    try testing.expect(title_val == .string);
    try testing.expectEqualStrings("Workflow task", title_val.string);

    const desc_val = result_val.object.get("description") orelse return error.NoDescription;
    try testing.expect(desc_val == .string);
    try testing.expectEqualStrings("My description", desc_val.string);

    const status_val = result_val.object.get("status") orelse return error.NoStatus;
    try testing.expect(status_val == .string);
    try testing.expectEqualStrings("todo", status_val.string);
}

test "workflow: create then update title" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{"title":"Original name","username":"testuser"},"id":110}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const create_response = fs.getStdout();
    const task_id = try extractTaskIdFromResponse(testing.allocator, create_response);

    fs.clearStdout();
    _ = arena.reset(false);

    var update_request_buf: [256]u8 = undefined;
    const update_request = std.fmt.bufPrint(&update_request_buf,
        \\{{"jsonrpc":"2.0","method":"task/update","params":{{"task_id":"{s}","title":"Renamed task"}},"id":111}}
        \\
    , .{task_id}) catch unreachable;

    fs.setStdin(update_request);
    runServer(fs, &arena);

    const update_response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, update_response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);

    const task = try readAndParseTask(fs, task_id, .todo);
    try validateTask(&task);
    try testing.expectEqual(gila.Status.todo, task.status);
    try testing.expectEqualStrings("Renamed task", task.title);
}

test "workflow: full lifecycle todo->started->done" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{"title":"Lifecycle task","username":"testuser"},"id":120}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const create_response = fs.getStdout();
    const task_id = try extractTaskIdFromResponse(testing.allocator, create_response);

    var todo_path_buf: [256]u8 = undefined;
    const todo_path = std.fmt.bufPrint(&todo_path_buf, ".gila/todo/{s}", .{task_id}) catch unreachable;
    try testing.expect(fs.dirExists(todo_path));

    fs.clearStdout();
    _ = arena.reset(false);

    var start_request_buf: [256]u8 = undefined;
    const start_request = std.fmt.bufPrint(&start_request_buf,
        \\{{"jsonrpc":"2.0","method":"task/update","params":{{"task_id":"{s}","status":"started"}},"id":121}}
        \\
    , .{task_id}) catch unreachable;

    fs.setStdin(start_request);
    runServer(fs, &arena);

    {
        const start_response = fs.getStdout();
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, start_response, .{});
        const root_value = parsed.value;
        try testing.expect(root_value == .object);

        const result_val = root_value.object.get("result") orelse return error.NoResult;
        try testing.expect(result_val == .object);

        const status_val = result_val.object.get("status") orelse return error.NoStatus;
        try testing.expect(status_val == .string);
        try testing.expectEqualStrings("started", status_val.string);
    }
    try testing.expect(!fs.dirExists(todo_path));

    var started_path_buf: [256]u8 = undefined;
    const started_path = std.fmt.bufPrint(&started_path_buf, ".gila/started/{s}", .{task_id}) catch unreachable;
    try testing.expect(fs.dirExists(started_path));

    fs.clearStdout();
    _ = arena.reset(false);

    var done_request_buf: [256]u8 = undefined;
    const done_request = std.fmt.bufPrint(&done_request_buf,
        \\{{"jsonrpc":"2.0","method":"task/update","params":{{"task_id":"{s}","status":"done"}},"id":122}}
        \\
    , .{task_id}) catch unreachable;

    fs.setStdin(done_request);
    runServer(fs, &arena);

    const done_response = fs.getStdout();
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, done_response, .{});
        const root_value = parsed.value;
        try testing.expect(root_value == .object);

        const result_val = root_value.object.get("result") orelse return error.NoResult;
        try testing.expect(result_val == .object);

        const status_val = result_val.object.get("status") orelse return error.NoStatus;
        try testing.expect(status_val == .string);
        try testing.expectEqualStrings("done", status_val.string);

        const completed_val = result_val.object.get("completed") orelse return error.NoCompleted;
        try testing.expect(completed_val == .string);
    }

    try testing.expect(!fs.dirExists(started_path));

    var done_path_buf: [256]u8 = undefined;
    const done_path = std.fmt.bufPrint(&done_path_buf, ".gila/done/{s}", .{task_id}) catch unreachable;
    try testing.expect(fs.dirExists(done_path));

    var done_file_path_buf: [256]u8 = undefined;
    const done_file_path = std.fmt.bufPrint(&done_file_path_buf, ".gila/done/{s}/{s}.md", .{ task_id, task_id }) catch unreachable;
    const final_content = try fs.readFile(done_file_path);
    try testing.expect(std.mem.indexOf(u8, final_content, "status: done") != null);
    try testing.expect(std.mem.indexOf(u8, final_content, "completed:") != null);
}

test "workflow: create task cancelled" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{"title":"To be cancelled","username":"testuser"},"id":130}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const create_response = fs.getStdout();
    const task_id = try extractTaskIdFromResponse(testing.allocator, create_response);

    fs.clearStdout();
    _ = arena.reset(false);

    var cancel_request_buf: [256]u8 = undefined;
    const cancel_request = std.fmt.bufPrint(&cancel_request_buf,
        \\{{"jsonrpc":"2.0","method":"task/update","params":{{"task_id":"{s}","status":"cancelled","username":"testuser"}},"id":131}}
        \\
    , .{task_id}) catch unreachable;

    fs.setStdin(cancel_request);
    runServer(fs, &arena);

    const cancel_response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, cancel_response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);

    const status_val = result_val.object.get("status") orelse return error.NoStatus;
    try testing.expect(status_val == .string);
    try testing.expectEqualStrings("cancelled", status_val.string);

    const completed_val = result_val.object.get("completed") orelse return error.NoCompleted;
    try testing.expect(completed_val == .string);

    var cancelled_path_buf: [256]u8 = undefined;
    const cancelled_path = std.fmt.bufPrint(&cancelled_path_buf, ".gila/cancelled/{s}", .{task_id}) catch unreachable;
    try testing.expect(fs.dirExists(cancelled_path));
}

test "workflow: multiple tasks interaction" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{"title":"Task One","username":"testuser"},"id":140}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);
    const task1_id = try extractTaskIdFromResponse(testing.allocator, fs.getStdout());

    fs.clearStdout();
    _ = arena.reset(false);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{"title":"Task Two","username":"testuser"},"id":141}
        \\
    );
    runServer(fs, &arena);
    const task2_id = try extractTaskIdFromResponse(testing.allocator, fs.getStdout());

    fs.clearStdout();
    _ = arena.reset(false);

    var start1_buf: [256]u8 = undefined;
    const start1_request = std.fmt.bufPrint(&start1_buf,
        \\{{"jsonrpc":"2.0","method":"task/update","params":{{"task_id":"{s}","status":"started"}},"id":142}}
        \\ 
    , .{task1_id}) catch unreachable;
    fs.setStdin(start1_request);
    runServer(fs, &arena);

    fs.clearStdout();
    _ = arena.reset(false);

    var done1_buf: [256]u8 = undefined;
    const done1_request = std.fmt.bufPrint(&done1_buf,
        \\{{"jsonrpc":"2.0","method":"task/update","params":{{"task_id":"{s}","status":"done"}},"id":143}}
        \\ 
    , .{task1_id}) catch unreachable;
    fs.setStdin(done1_request);
    runServer(fs, &arena);

    var task1_done_buf: [256]u8 = undefined;
    const task1_done_path = std.fmt.bufPrint(&task1_done_buf, ".gila/done/{s}", .{task1_id}) catch unreachable;
    try testing.expect(fs.dirExists(task1_done_path));

    var task2_todo_buf: [256]u8 = undefined;
    const task2_todo_path = std.fmt.bufPrint(&task2_todo_buf, ".gila/todo/{s}", .{task2_id}) catch unreachable;
    try testing.expect(fs.dirExists(task2_todo_path));
}

test "task/find: filter by priority" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);
    try test_utils.createTaskFile(fs, "todo", "high_pri_abc", "High Priority Task", "high", "", "");
    try test_utils.createTaskFile(fs, "todo", "low_pri_abc", "Low Priority Task", "low", "", "");

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/find","params":{"priority":"high"},"id":200}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 200), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);

    const count_val = result_val.object.get("count") orelse return error.NoCount;
    try testing.expect(count_val == .integer);
    try testing.expectEqual(@as(i64, 1), count_val.integer);

    const tasks_val = result_val.object.get("tasks") orelse return error.NoTasks;
    try testing.expect(tasks_val == .array);
    try testing.expectEqual(1, tasks_val.array.items.len);
    const task = tasks_val.array.items[0];
    try testing.expect(task == .object);
    const task_id = task.object.get("task_id") orelse return error.NoTaskId;
    try testing.expect(task_id == .string);
    try testing.expectEqualStrings("high_pri_abc", task_id.string);
}

test "task/find: filter by status" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);
    try test_utils.createTaskFile(fs, "todo", "todo_task_abc", "Todo Task", "medium", "", "");
    try test_utils.createTaskFile(fs, "started", "started_tsk_xyz", "Started Task", "medium", "", "");

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/find","params":{"status":"started"},"id":201}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 201), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);

    const tasks_val = result_val.object.get("tasks") orelse return error.NoTasks;
    try testing.expect(tasks_val == .array);
    try testing.expectEqual(1, tasks_val.array.items.len);
    const task = tasks_val.array.items[0];
    try testing.expect(task == .object);
    const task_id = task.object.get("task_id") orelse return error.NoTaskId;
    try testing.expect(task_id == .string);
    try testing.expectEqualStrings("started_tsk_xyz", task_id.string);
}

test "task/find: filter by tags with or" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    const feature_content =
        \\---
        \\title: Feature Task
        \\status: todo
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\tags:
        \\- feature
        \\---
        \\
    ;
    try fs.createFile(".gila/todo/feature_tsk_abc/feature_tsk_abc.md", feature_content);

    const bugfix_content =
        \\---
        \\title: Bugfix Task
        \\status: todo
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\tags:
        \\- bugfix
        \\---
        \\
    ;
    try fs.createFile(".gila/todo/bugfix_tsk_abc/bugfix_tsk_abc.md", bugfix_content);

    const other_content =
        \\---
        \\title: Other Task
        \\status: todo
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\tags:
        \\- other
        \\---
        \\
    ;
    try fs.createFile(".gila/todo/other_tsk_abc/other_tsk_abc.md", other_content);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/find","params":{"tags":["feature","bugfix"],"tags_op":"or"},"id":202}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 202), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);

    const tasks_val = result_val.object.get("tasks") orelse return error.NoTasks;
    try testing.expect(tasks_val == .array);

    // Verify feature_tsk_abc and bugfix_tsk_abc are in results, other_tsk_abc is not
    var found_feature = false;
    var found_bugfix = false;
    for (tasks_val.array.items) |task| {
        try testing.expect(task == .object);
        const task_id = task.object.get("task_id") orelse continue;
        try testing.expect(task_id == .string);
        if (std.mem.eql(u8, task_id.string, "feature_tsk_abc")) {
            found_feature = true;
        }
        if (std.mem.eql(u8, task_id.string, "bugfix_tsk_abc")) {
            found_bugfix = true;
        }
        try testing.expect(!std.mem.eql(u8, task_id.string, "other_tsk_abc"));
    }
    try testing.expect(found_feature);
    try testing.expect(found_bugfix);
}

test "task/find: filter by tags with and" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    const both_content =
        \\---
        \\title: Both Tags Task
        \\status: todo
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\tags:
        \\- feature
        \\- urgent
        \\---
        \\
    ;
    try fs.createFile(".gila/todo/both_tags_abc/both_tags_abc.md", both_content);

    const one_content =
        \\---
        \\title: One Tag Task
        \\status: todo
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\tags:
        \\- feature
        \\---
        \\
    ;
    try fs.createFile(".gila/todo/one_tag_abc/one_tag_abc.md", one_content);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/find","params":{"tags":["feature","urgent"],"tags_op":"and"},"id":203}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 203), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);

    const tasks_val = result_val.object.get("tasks") orelse return error.NoTasks;
    try testing.expect(tasks_val == .array);
    try testing.expectEqual(1, tasks_val.array.items.len);
    const task = tasks_val.array.items[0];
    try testing.expect(task == .object);
    const task_id = task.object.get("task_id") orelse return error.NoTaskId;
    try testing.expect(task_id == .string);
    try testing.expectEqualStrings("both_tags_abc", task_id.string);
}

test "task/find: empty results" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);
    try test_utils.createTaskFile(fs, "todo", "low_only_abc", "Low Task", "low", "", "");

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/find","params":{"priority":"urgent"},"id":204}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 204), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);

    const tasks_val = result_val.object.get("tasks") orelse return error.NoTasks;
    try testing.expect(tasks_val == .array);
    try testing.expectEqual(@as(usize, 0), tasks_val.array.items.len);

    const count_val = result_val.object.get("count") orelse return error.NoCount;
    try testing.expect(count_val == .integer);
    try testing.expectEqual(@as(i64, 0), count_val.integer);
}

test "task/find: custom fields" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);
    try test_utils.createTaskFile(fs, "todo", "fields_tsk_abc", "Fields Test", "high", "", "");

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/find","params":{"priority":"high","fields":["id","title","priority","file_path"]},"id":205}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 205), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);

    const tasks_val = result_val.object.get("tasks") orelse return error.NoTasks;
    try testing.expect(tasks_val == .array);
    try testing.expectEqual(@as(usize, 1), tasks_val.array.items.len);

    const task = tasks_val.array.items[0];
    try testing.expect(task == .object);

    const task_id = task.object.get("task_id") orelse return error.NoTaskId;
    try testing.expect(task_id == .string);
    try testing.expectEqualStrings("fields_tsk_abc", task_id.string);

    const title_val = task.object.get("title") orelse return error.NoTitle;
    try testing.expect(title_val == .string);
    try testing.expectEqualStrings("Fields Test", title_val.string);

    const priority_val = task.object.get("priority") orelse return error.NoPriority;
    try testing.expect(priority_val == .string);
    try testing.expectEqualStrings("high", priority_val.string);

    const file_path_val = task.object.get("file_path");
    try testing.expect(file_path_val != null);

    try testing.expect(task.object.get("status") == null);
    try testing.expect(task.object.get("owner") == null);
}

test "task/find: default fields only id status title" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);
    try test_utils.createTaskFile(fs, "todo", "default_fl_abc", "Default Fields", "high", "", "");

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/find","params":{"priority":"high"},"id":206}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 206), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);

    const tasks_val = result_val.object.get("tasks") orelse return error.NoTasks;
    try testing.expect(tasks_val == .array);
    try testing.expectEqual(@as(usize, 1), tasks_val.array.items.len);

    const task = tasks_val.array.items[0];
    try testing.expect(task == .object);

    const task_id = task.object.get("task_id") orelse return error.NoTaskId;
    try testing.expect(task_id == .string);
    try testing.expectEqualStrings("default_fl_abc", task_id.string);

    const status_val = task.object.get("status") orelse return error.NoStatus;
    try testing.expect(status_val == .string);
    try testing.expectEqualStrings("todo", status_val.string);

    const title_val = task.object.get("title") orelse return error.NoTitle;
    try testing.expect(title_val == .string);
    try testing.expectEqualStrings("Default Fields", title_val.string);

    try testing.expect(task.object.get("priority") == null);
}

test "task/find: list all tasks" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);
    try test_utils.createTaskFile(fs, "todo", "list_one_abc", "List One", "medium", "", "");
    try test_utils.createTaskFile(fs, "todo", "list_two_abc", "List Two", "medium", "", "");
    try test_utils.createTaskFile(fs, "started", "list_thr_abc", "List Three", "medium", "", "");

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/find","params":{},"id":300}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 300), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);

    const tasks_val = result_val.object.get("tasks") orelse return error.NoTasks;
    try testing.expect(tasks_val == .array);

    const count_val = result_val.object.get("count") orelse return error.NoCount;
    try testing.expect(count_val == .integer);
    try testing.expectEqual(@as(i64, 3), count_val.integer);

    const limit_val = result_val.object.get("limit") orelse return error.NoLimit;
    try testing.expect(limit_val == .integer);
    try testing.expectEqual(std.math.maxInt(i64), limit_val.integer);

    const offset_val = result_val.object.get("offset") orelse return error.NoOffset;
    try testing.expect(offset_val == .integer);
    try testing.expectEqual(@as(i64, 0), offset_val.integer);
}

test "task/find: pagination with limit" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);
    try test_utils.createTaskFile(fs, "todo", "page_one_abc", "Page One", "medium", "", "");
    try test_utils.createTaskFile(fs, "todo", "page_two_abc", "Page Two", "medium", "", "");
    try test_utils.createTaskFile(fs, "todo", "page_thr_abc", "Page Three", "medium", "", "");

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/find","params":{"limit":2},"id":302}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 302), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);

    const available_val = result_val.object.get("available") orelse return error.NoAvailable;
    try testing.expect(available_val == .integer);
    try testing.expectEqual(@as(i64, 3), available_val.integer);

    const count_val = result_val.object.get("count") orelse return error.NoCount;
    try testing.expect(count_val == .integer);
    try testing.expectEqual(@as(i64, 2), count_val.integer);

    const limit_val = result_val.object.get("limit") orelse return error.NoLimit;
    try testing.expect(limit_val == .integer);
    try testing.expectEqual(@as(i64, 2), limit_val.integer);
}

test "task/find: pagination with offset" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);
    try test_utils.createTaskFile(fs, "todo", "off_one_abc", "Offset One", "medium", "", "");
    try test_utils.createTaskFile(fs, "todo", "off_two_abc", "Offset Two", "medium", "", "");
    try test_utils.createTaskFile(fs, "todo", "off_thr_abc", "Offset Three", "medium", "", "");

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/find","params":{"offset":1,"limit":2},"id":303}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 303), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);

    const available_val = result_val.object.get("available") orelse return error.NoAvailable;
    try testing.expect(available_val == .integer);
    try testing.expectEqual(@as(i64, 3), available_val.integer);

    const count_val = result_val.object.get("count") orelse return error.NoCount;
    try testing.expect(count_val == .integer);
    try testing.expectEqual(@as(i64, 2), count_val.integer);

    const offset_val = result_val.object.get("offset") orelse return error.NoOffset;
    try testing.expect(offset_val == .integer);
    try testing.expectEqual(@as(i64, 1), offset_val.integer);

    const limit_val = result_val.object.get("limit") orelse return error.NoLimit;
    try testing.expect(limit_val == .integer);
    try testing.expectEqual(@as(i64, 2), limit_val.integer);
}

test "task/find: empty list" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/find","params":{},"id":304}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 304), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);

    const tasks_val = result_val.object.get("tasks") orelse return error.NoTasks;
    try testing.expect(tasks_val == .array);
    try testing.expectEqual(@as(usize, 0), tasks_val.array.items.len);

    const available_val = result_val.object.get("available") orelse return error.NoAvailable;
    try testing.expect(available_val == .integer);
    try testing.expectEqual(@as(i64, 0), available_val.integer);

    const count_val = result_val.object.get("count") orelse return error.NoCount;
    try testing.expect(count_val == .integer);
    try testing.expectEqual(@as(i64, 0), count_val.integer);
}

test "task/sync: no changes needed" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);
    try test_utils.createTaskFile(fs, "todo", "sync_ok_abc", "Sync OK", "medium", "", "");

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/sync","params":{},"id":400}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 400), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);

    const transitions_val = result_val.object.get("transitions") orelse return error.NoTransitions;
    try testing.expect(transitions_val == .array);
    try testing.expectEqual(@as(usize, 0), transitions_val.array.items.len);

    const updates_val = result_val.object.get("updates") orelse return error.NoUpdates;
    try testing.expect(updates_val == .array);
    try testing.expectEqual(@as(usize, 0), updates_val.array.items.len);

    const count_val = result_val.object.get("count") orelse return error.NoCount;
    try testing.expect(count_val == .integer);
    try testing.expectEqual(@as(i64, 0), count_val.integer);
}

test "task/sync: moves misplaced task" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    const misplaced_content =
        \\---
        \\title: Misplaced Task
        \\status: started
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\---
        \\
    ;
    try fs.createFile(".gila/todo/misplace_task_abc/misplace_task_abc.md", misplaced_content);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/sync","params":{},"id":401}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 401), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);

    const transitions_val = result_val.object.get("transitions") orelse return error.NoTransitions;
    try testing.expect(transitions_val == .array);
    try testing.expectEqual(1, transitions_val.array.items.len);
    const transition = transitions_val.array.items[0];
    try testing.expect(transition == .object);
    const task_id = transition.object.get("task_id") orelse return error.NoTaskId;
    try testing.expect(task_id == .string);
    try testing.expectEqualStrings("misplace_task_abc", task_id.string);
    const from_val = transition.object.get("from") orelse return error.NoFrom;
    try testing.expect(from_val == .string);
    try testing.expectEqualStrings("todo", from_val.string);
    const to_val = transition.object.get("to") orelse return error.NoTo;
    try testing.expect(to_val == .string);
    try testing.expectEqualStrings("started", to_val.string);

    try testing.expect(!fs.dirExists(".gila/todo/misplace_task_abc"));
    try testing.expect(fs.dirExists(".gila/started/misplace_task_abc"));
}

test "task/sync: removes completed dependency" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    const done_content =
        \\---
        \\title: Done Task
        \\status: done
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\completed: 2025-01-07T13:00:00Z
        \\---
        \\
    ;
    try fs.createFile(".gila/done/done_dep_abc/done_dep_abc.md", done_content);

    const waiting_content =
        \\---
        \\title: Waiting Task
        \\status: waiting
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\waiting_on:
        \\- "[[done_dep_abc]]"
        \\---
        \\
    ;
    try fs.createFile(".gila/waiting/waiting_tsk_xyz/waiting_tsk_xyz.md", waiting_content);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/sync","params":{},"id":402}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 402), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);

    const updates_val = result_val.object.get("updates") orelse return error.NoUpdates;
    try testing.expect(updates_val == .array);
    try testing.expectEqual(1, updates_val.array.items.len);
    const update = updates_val.array.items[0];
    try testing.expect(update == .object);
    const task_id = update.object.get("task_id") orelse return error.NoTaskId;
    try testing.expect(task_id == .string);
    try testing.expectEqualStrings("waiting_tsk_xyz", task_id.string);
    const change = update.object.get("change") orelse return error.NoChange;
    try testing.expect(change == .string);
    try testing.expectEqualStrings("removed_completed_dependency", change.string);
    const dependency = update.object.get("dependency") orelse return error.NoDependency;
    try testing.expect(dependency == .string);
    try testing.expectEqualStrings("done_dep_abc", dependency.string);
}

test "task/sync: transitions waiting to todo when no dependencies" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    const done_content =
        \\---
        \\title: Done Task
        \\status: done
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\completed: 2025-01-07T13:00:00Z
        \\---
        \\
    ;
    try fs.createFile(".gila/done/only_dep_abc/only_dep_abc.md", done_content);

    const waiting_content =
        \\---
        \\title: Waiting Task
        \\status: waiting
        \\priority_value: 50
        \\priority: medium
        \\owner: testuser
        \\created: 2025-01-07T12:00:00Z
        \\waiting_on:
        \\- "[[only_dep_abc]]"
        \\---
        \\
    ;
    try fs.createFile(".gila/waiting/wait_trans_xyz/wait_trans_xyz.md", waiting_content);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/sync","params":{},"id":403}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 403), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);

    const transitions_val = result_val.object.get("transitions") orelse return error.NoTransitions;
    try testing.expect(transitions_val == .array);
    try testing.expectEqual(1, transitions_val.array.items.len);
    const transition = transitions_val.array.items[0];
    try testing.expect(transition == .object);
    const task_id = transition.object.get("task_id") orelse return error.NoTaskId;
    try testing.expect(task_id == .string);
    try testing.expectEqualStrings("wait_trans_xyz", task_id.string);
    const from_val = transition.object.get("from") orelse return error.NoFrom;
    try testing.expect(from_val == .string);
    try testing.expectEqualStrings("waiting", from_val.string);
    const to_val = transition.object.get("to") orelse return error.NoTo;
    try testing.expect(to_val == .string);
    try testing.expectEqualStrings("todo", to_val.string);

    try testing.expect(!fs.dirExists(".gila/waiting/wait_trans_xyz"));
    try testing.expect(fs.dirExists(".gila/todo/wait_trans_xyz"));
}

test "workflow: create multiple tasks then find by tag" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{"title":"Backend Feature", "username":"testuser","tags":["backend","feature"]},"id":500}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);
    const task1_id = try extractTaskIdFromResponse(testing.allocator, fs.getStdout());
    _ = task1_id;

    fs.clearStdout();
    _ = arena.reset(false);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{"title":"Frontend Feature","username":"testuser","tags":["frontend","feature"]},"id":501}
        \\
    );
    runServer(fs, &arena);

    fs.clearStdout();
    _ = arena.reset(false);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{"title":"Bug Fix","username":"testuser","tags":["bugfix"]},"id":502}
        \\
    );
    runServer(fs, &arena);

    fs.clearStdout();
    _ = arena.reset(false);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/find","params":{"tags":["feature"]},"id":503}
        \\
    );
    runServer(fs, &arena);

    const response = fs.getStdout();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();
    const root_value = parsed.value;
    try testing.expect(root_value == .object);

    const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
    try testing.expect(jsonrpc_val == .string);
    try testing.expectEqualStrings("2.0", jsonrpc_val.string);

    const id_val = root_value.object.get("id") orelse return error.NoId;
    try testing.expect(id_val == .integer);
    try testing.expectEqual(@as(i64, 503), id_val.integer);

    const result_val = root_value.object.get("result") orelse return error.NoResult;
    try testing.expect(result_val == .object);

    const tasks_val = result_val.object.get("tasks") orelse return error.NoTasks;
    try testing.expect(tasks_val == .array);

    const count_val = result_val.object.get("count") orelse return error.NoCount;
    try testing.expect(count_val == .integer);
    try testing.expectEqual(@as(i64, 2), count_val.integer);

    var found_backend = false;
    var found_frontend = false;
    for (tasks_val.array.items) |task| {
        try testing.expect(task == .object);
        const title_val = task.object.get("title") orelse continue;
        try testing.expect(title_val == .string);
        if (std.mem.eql(u8, title_val.string, "Backend Feature")) {
            found_backend = true;
        }
        if (std.mem.eql(u8, title_val.string, "Frontend Feature")) {
            found_frontend = true;
        }
        try testing.expect(!std.mem.eql(u8, title_val.string, "Bug Fix"));
    }
    try testing.expect(found_backend);
    try testing.expect(found_frontend);
}

test "workflow: create with waiting_on then mark dependency done then sync" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{"title":"First Task", "username":"testuser"},"id":510}
        \\
    );

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    runServer(fs, &arena);
    const first_id = try extractTaskIdFromResponse(testing.allocator, fs.getStdout());

    fs.clearStdout();
    _ = arena.reset(false);

    var create_waiting_buf: [512]u8 = undefined;
    const create_waiting = std.fmt.bufPrint(&create_waiting_buf,
        \\{{"jsonrpc":"2.0","method":"task/create","params":{{"title":"Waiting Task","username":"testuser","waiting_on":["{s}"]}},"id":511}}
        \\ 
    , .{first_id}) catch unreachable;
    fs.setStdin(create_waiting);
    runServer(fs, &arena);

    const waiting_response = fs.getStdout();
    const waiting_id = blk: {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, waiting_response, .{});
        defer parsed.deinit();
        const root_value = parsed.value;
        try testing.expect(root_value == .object);

        const result_val = root_value.object.get("result") orelse return error.NoResult;
        try testing.expect(result_val == .object);

        const status_val = result_val.object.get("status") orelse return error.NoStatus;
        try testing.expect(status_val == .string);
        try testing.expectEqualStrings("waiting", status_val.string);

        const task_id_val = result_val.object.get("task_id") orelse return error.NoTaskId;
        try testing.expect(task_id_val == .string);
        break :blk task_id_val.string;
    };

    var waiting_path_buf: [256]u8 = undefined;
    const waiting_path = std.fmt.bufPrint(&waiting_path_buf, ".gila/waiting/{s}", .{waiting_id}) catch unreachable;
    try testing.expect(fs.dirExists(waiting_path));

    fs.clearStdout();
    _ = arena.reset(false);

    var mark_done_buf: [256]u8 = undefined;
    const mark_done = std.fmt.bufPrint(&mark_done_buf,
        \\{{"jsonrpc":"2.0","method":"task/update","params":{{"task_id":"{s}","status":"done"}},"id":512}}
        \\ 
    , .{first_id}) catch unreachable;
    fs.setStdin(mark_done);
    runServer(fs, &arena);

    fs.clearStdout();
    _ = arena.reset(false);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/sync","params":{},"id":513}
        \\
    );
    runServer(fs, &arena);

    const sync_response = fs.getStdout();
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, sync_response, .{});
        defer parsed.deinit();
        const root_value = parsed.value;
        try testing.expect(root_value == .object);

        const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
        try testing.expect(jsonrpc_val == .string);
        try testing.expectEqualStrings("2.0", jsonrpc_val.string);

        const id_val = root_value.object.get("id") orelse return error.NoId;
        try testing.expect(id_val == .integer);
        try testing.expectEqual(@as(i64, 513), id_val.integer);

        const result_val = root_value.object.get("result") orelse return error.NoResult;
        try testing.expect(result_val == .object);

        const updates_val = result_val.object.get("updates") orelse return error.NoUpdates;
        try testing.expect(updates_val == .array);

        var found_update = false;
        for (updates_val.array.items) |update| {
            try testing.expect(update == .object);
            const task_id = update.object.get("task_id") orelse continue;
            try testing.expect(task_id == .string);
            if (std.mem.eql(u8, task_id.string, waiting_id)) {
                const update_change = update.object.get("change") orelse continue;
                try testing.expect(update_change == .string);
                if (std.mem.eql(u8, update_change.string, "removed_completed_dependency")) {
                    found_update = true;
                }
            }
        }
        try testing.expect(found_update);
    }

    try testing.expect(!fs.dirExists(waiting_path));
    var todo_path_buf: [256]u8 = undefined;
    const todo_path = std.fmt.bufPrint(&todo_path_buf, ".gila/todo/{s}", .{waiting_id}) catch unreachable;
    try testing.expect(fs.dirExists(todo_path));
}

test "workflow: create tasks then list with pagination" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var request_buf: [256]u8 = undefined;
        const request = std.fmt.bufPrint(&request_buf,
            \\{{"jsonrpc":"2.0","method":"task/create","params":{{"title":"Task {d}", "username":"testuser"}},"id":{d}}}
            \\ 
        , .{ i + 1, 520 + i }) catch unreachable;
        fs.setStdin(request);
        runServer(fs, &arena);
        fs.clearStdout();
        _ = arena.reset(false);
    }

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/find","params":{"limit":2,"offset":0},"id":525}
        \\
    );
    runServer(fs, &arena);

    const response1 = fs.getStdout();
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response1, .{});
        defer parsed.deinit();
        const root_value = parsed.value;
        try testing.expect(root_value == .object);

        const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
        try testing.expect(jsonrpc_val == .string);
        try testing.expectEqualStrings("2.0", jsonrpc_val.string);

        const id_val = root_value.object.get("id") orelse return error.NoId;
        try testing.expect(id_val == .integer);
        try testing.expectEqual(@as(i64, 525), id_val.integer);

        const result_val = root_value.object.get("result") orelse return error.NoResult;
        try testing.expect(result_val == .object);

        const available_val = result_val.object.get("available") orelse return error.NoAvailable;
        try testing.expect(available_val == .integer);
        try testing.expectEqual(@as(i64, 5), available_val.integer);

        const limit_val = result_val.object.get("limit") orelse return error.NoLimit;
        try testing.expect(limit_val == .integer);
        try testing.expectEqual(@as(i64, 2), limit_val.integer);

        const offset_val = result_val.object.get("offset") orelse return error.NoOffset;
        try testing.expect(offset_val == .integer);
        try testing.expectEqual(@as(i64, 0), offset_val.integer);
    }

    fs.clearStdout();
    _ = arena.reset(false);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/find","params":{"limit":2,"offset":2},"id":526}
        \\
    );
    runServer(fs, &arena);

    const response2 = fs.getStdout();
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response2, .{});
        defer parsed.deinit();
        const root_value = parsed.value;
        try testing.expect(root_value == .object);

        const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
        try testing.expect(jsonrpc_val == .string);
        try testing.expectEqualStrings("2.0", jsonrpc_val.string);

        const id_val = root_value.object.get("id") orelse return error.NoId;
        try testing.expect(id_val == .integer);
        try testing.expectEqual(@as(i64, 526), id_val.integer);

        const result_val = root_value.object.get("result") orelse return error.NoResult;
        try testing.expect(result_val == .object);

        const available_val = result_val.object.get("available") orelse return error.NoAvailable;
        try testing.expect(available_val == .integer);
        try testing.expectEqual(@as(i64, 5), available_val.integer);

        const limit_val = result_val.object.get("limit") orelse return error.NoLimit;
        try testing.expect(limit_val == .integer);
        try testing.expectEqual(@as(i64, 2), limit_val.integer);

        const offset_val = result_val.object.get("offset") orelse return error.NoOffset;
        try testing.expect(offset_val == .integer);
        try testing.expectEqual(@as(i64, 2), offset_val.integer);
    }
}

test "workflow: find by status after updates" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try initGilaProject(fs);

    var arena_buf: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buf);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{"title":"Will Start","username":"testuser"},"id":530}
        \\
    );
    runServer(fs, &arena);
    const task1_id = try extractTaskIdFromResponse(testing.allocator, fs.getStdout());

    fs.clearStdout();
    _ = arena.reset(false);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/create","params":{"title":"Will Stay Todo","username":"testuser"},"id":531}
        \\
    );
    runServer(fs, &arena);

    fs.clearStdout();
    _ = arena.reset(false);

    var start_buf: [256]u8 = undefined;
    const start_request = std.fmt.bufPrint(&start_buf,
        \\{{"jsonrpc":"2.0","method":"task/update","params":{{"task_id":"{s}","status":"started"}},"id":532}}
        \\
    , .{task1_id}) catch unreachable;
    fs.setStdin(start_request);
    runServer(fs, &arena);

    fs.clearStdout();
    _ = arena.reset(false);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/find","params":{"status":"todo"},"id":533}
        \\
    );
    runServer(fs, &arena);

    const find_todo = fs.getStdout();
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, find_todo, .{});
        defer parsed.deinit();
        const root_value = parsed.value;
        try testing.expect(root_value == .object);

        const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
        try testing.expect(jsonrpc_val == .string);
        try testing.expectEqualStrings("2.0", jsonrpc_val.string);

        const id_val = root_value.object.get("id") orelse return error.NoId;
        try testing.expect(id_val == .integer);
        try testing.expectEqual(@as(i64, 533), id_val.integer);

        const result_val = root_value.object.get("result") orelse return error.NoResult;
        try testing.expect(result_val == .object);

        const tasks_val = result_val.object.get("tasks") orelse return error.NoTasks;
        try testing.expect(tasks_val == .array);

        const count_val = result_val.object.get("count") orelse return error.NoCount;
        try testing.expect(count_val == .integer);
        try testing.expectEqual(@as(i64, 1), count_val.integer);

        // Verify "Will Stay Todo" is in results, "Will Start" is not
        var found_stay = false;
        for (tasks_val.array.items) |task| {
            try testing.expect(task == .object);
            const title_val = task.object.get("title") orelse continue;
            try testing.expect(title_val == .string);
            if (std.mem.eql(u8, title_val.string, "Will Stay Todo")) {
                found_stay = true;
            }
            try testing.expect(!std.mem.eql(u8, title_val.string, "Will Start"));
        }
        try testing.expect(found_stay);
    }

    fs.clearStdout();
    _ = arena.reset(false);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/find","params":{"status":"started"},"id":534}
        \\
    );
    runServer(fs, &arena);

    const find_started = fs.getStdout();
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, find_started, .{});
        defer parsed.deinit();
        const root_value = parsed.value;
        try testing.expect(root_value == .object);

        const jsonrpc_val = root_value.object.get("jsonrpc") orelse return error.NoJsonRpc;
        try testing.expect(jsonrpc_val == .string);
        try testing.expectEqualStrings("2.0", jsonrpc_val.string);

        const id_val = root_value.object.get("id") orelse return error.NoId;
        try testing.expect(id_val == .integer);
        try testing.expectEqual(@as(i64, 534), id_val.integer);

        const result_val = root_value.object.get("result") orelse return error.NoResult;
        try testing.expect(result_val == .object);

        const tasks_val = result_val.object.get("tasks") orelse return error.NoTasks;
        try testing.expect(tasks_val == .array);

        const count_val = result_val.object.get("count") orelse return error.NoCount;
        try testing.expect(count_val == .integer);
        try testing.expectEqual(@as(i64, 1), count_val.integer);

        // Verify "Will Start" is in results, "Will Stay Todo" is not
        var found_start = false;
        for (tasks_val.array.items) |task| {
            try testing.expect(task == .object);
            const title_val = task.object.get("title") orelse continue;
            try testing.expect(title_val == .string);
            if (std.mem.eql(u8, title_val.string, "Will Start")) {
                found_start = true;
            }
            try testing.expect(!std.mem.eql(u8, title_val.string, "Will Stay Todo"));
        }
        try testing.expect(found_start);
    }
}
