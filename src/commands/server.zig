const std = @import("std");
const root = @import("root");

const gila = @import("gila");
const stdx = @import("stdx");

const common = @import("common.zig");
const rpc = @import("rpc.zig");
const Handler = @import("handler.zig");

const log = std.log.scoped(.server);

const Server = @This();

run_once: bool = false,

pub const help =
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
const TestFs = @import("../testfs/root.zig").TestFs;
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

    try initGilaProject(fs);

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

        const status_val = result_val.object.get("status") orelse return error.NoStatus;
        try testing.expect(status_val == .string);
        try testing.expectEqualStrings("todo", status_val.string);
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
    try expectResponseContains(response, "\"result\":");
    try expectResponseContains(response, "\"status\":\"todo\"");
    try expectResponseContains(response, "\"id\":2");

    const task_id = try extractTaskIdFromResponse(testing.allocator, response);
    var file_path_buf: [256]u8 = undefined;
    const file_path = std.fmt.bufPrint(&file_path_buf, ".gila/todo/{s}/{s}.md", .{ task_id, task_id }) catch unreachable;

    const content = try fs.readFile(file_path);
    try testing.expect(std.mem.indexOf(u8, content, "title: Full task") != null);
    try testing.expect(std.mem.indexOf(u8, content, "priority: high") != null);
    try testing.expect(std.mem.indexOf(u8, content, "priority_value: 75") != null);
    try testing.expect(std.mem.indexOf(u8, content, "feature") != null);
    try testing.expect(std.mem.indexOf(u8, content, "backend") != null);
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
    try expectResponseContains(response, "\"status\":\"waiting\"");

    const task_id = try extractTaskIdFromResponse(testing.allocator, response);
    var file_path_buf: [256]u8 = undefined;
    const file_path = std.fmt.bufPrint(&file_path_buf, ".gila/waiting/{s}/{s}.md", .{ task_id, task_id }) catch unreachable;
    try testing.expect(fs.fileExists(file_path));

    const content = try fs.readFile(file_path);
    try testing.expect(std.mem.indexOf(u8, content, "status: waiting") != null);
    try testing.expect(std.mem.indexOf(u8, content, "test_task_abc") != null);
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
    try expectResponseContains(response, "\"error\":");
    try expectErrorCode(response, -32602);
    try expectResponseContains(response, "Missing required field: title");
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
    try expectResponseContains(response, "\"error\":");
    try expectErrorCode(response, -32602);
    try expectResponseContains(response, "Title cannot be empty");
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
    try expectResponseContains(response, "\"error\":");
    try expectErrorCode(response, -32002);
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
    try expectResponseContains(response, "\"result\":");
    try expectResponseContains(response, "\"id\":\"string-id\"");
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
    try expectResponseContains(response, "\"result\":");
    try expectResponseContains(response, "\"id\":null");
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
    try expectResponseContains(response, "\"result\":");
    try expectResponseContains(response, "\"id\":\"test_task_xyz\"");
    try expectResponseContains(response, "\"title\":\"My test task\"");
    try expectResponseContains(response, "\"status\":\"todo\"");
    try expectResponseContains(response, "\"priority\":\"medium\"");
    try expectResponseContains(response, "\"file_path\":");
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
    try expectResponseContains(response, "\"error\":");
    try expectErrorCode(response, -32001);
    try expectResponseContains(response, "Task not found");
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
    try expectResponseContains(response, "\"error\":");
    try expectErrorCode(response, -32002);
    try expectResponseContains(response, "Invalid task ID format");
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
    try expectResponseContains(response, "\"error\":");
    try expectErrorCode(response, -32602);
    try expectResponseContains(response, "Missing required field: task_id");
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
    try expectResponseContains(response, "\"result\":");
    try expectResponseContains(response, "\"task_id\":\"update_task_aaa\"");
    try expectResponseContains(response, "\"status\":\"todo\"");

    const content = try fs.readFile(".gila/todo/update_task_aaa/update_task_aaa.md");
    try testing.expect(std.mem.indexOf(u8, content, "title: Updated title") != null);
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
    try expectResponseContains(response, "\"status\":\"started\"");

    try testing.expect(!fs.dirExists(".gila/todo/status_task_bbb"));
    try testing.expect(fs.dirExists(".gila/started/status_task_bbb"));
    try testing.expect(fs.fileExists(".gila/started/status_task_bbb/status_task_bbb.md"));
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
    try expectResponseContains(response, "\"status\":\"done\"");
    try expectResponseContains(response, "\"completed\":");
    try expectResponseNotContains(response, "\"completed\":null");

    try testing.expect(!fs.dirExists(".gila/started/done_task_ccc"));
    try testing.expect(fs.dirExists(".gila/done/done_task_ccc"));
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
    try expectResponseContains(response, "\"result\":");

    const content = try fs.readFile(".gila/todo/priority_task_eee/priority_task_eee.md");
    try testing.expect(std.mem.indexOf(u8, content, "priority: urgent") != null);
    try testing.expect(std.mem.indexOf(u8, content, "priority_value: 100") != null);
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
    try expectResponseContains(response, "\"error\":");
    try expectErrorCode(response, -32001);
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
    try expectResponseContains(response, "\"error\":");
    try expectErrorCode(response, -32002);
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
    try expectResponseContains(response, "\"result\":");

    const content = try fs.readFile(".gila/todo/tags_task_ddd/tags_task_ddd.md");
    try testing.expect(std.mem.indexOf(u8, content, "new-tag") != null);
    try testing.expect(std.mem.indexOf(u8, content, "another") != null);
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
    try expectResponseContains(response, "\"result\":");
    try expectResponseContains(response, "\"message\":\"Server shutting down\"");
    try expectResponseContains(response, "\"id\":30");
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
    try expectResponseContains(response, "\"error\":");
    try expectErrorCode(response, -32700);
    try expectResponseContains(response, "Parse error");
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
    try expectResponseContains(response, "\"error\":");
    try expectErrorCode(response, -32600);
    try expectResponseContains(response, "Request must be a JSON object");
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
    try expectResponseContains(response, "\"error\":");
    try expectErrorCode(response, -32600);
    try expectResponseContains(response, "Missing 'jsonrpc' field");
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
    try expectResponseContains(response, "\"error\":");
    try expectErrorCode(response, -32600);
    try expectResponseContains(response, "Invalid jsonrpc version");
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
    try expectResponseContains(response, "\"error\":");
    try expectErrorCode(response, -32600);
    try expectResponseContains(response, "Missing 'id' field");
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
    try expectResponseContains(response, "\"error\":");
    try expectErrorCode(response, -32600);
    try expectResponseContains(response, "Invalid 'id' field type");
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
    try expectResponseContains(response, "\"error\":");
    try expectErrorCode(response, -32600);
    try expectResponseContains(response, "Missing 'method' field");
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
    try expectResponseContains(response, "\"error\":");
    try expectErrorCode(response, -32600);
    try expectResponseContains(response, "'method' must be a string");
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
    try expectResponseContains(response, "\"error\":");
    try expectErrorCode(response, -32600);
    try expectResponseContains(response, "Invalid method");
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
    try expectResponseContains(response, "\"error\":");
    try expectErrorCode(response, -32602);
    try expectResponseContains(response, "Params must be an object");
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
    try expectResponseContains(response, "\"error\":");
    try expectErrorCode(response, -32602);
    try expectResponseContains(response, "Missing params");
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
    try expectResponseContains(response, "\"error\":");
    try expectErrorCode(response, -32005);
    try expectResponseContains(response, "GILA directory not found");
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
    try expectResponseContains(create_response, "\"result\":");

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
    try expectResponseContains(get_response, "\"result\":");
    try expectResponseContains(get_response, "\"title\":\"Workflow task\"");
    try expectResponseContains(get_response, "\"description\":\"My description\"");
    try expectResponseContains(get_response, "\"status\":\"todo\"");
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
    try expectResponseContains(update_response, "\"result\":");

    var file_path_buf: [256]u8 = undefined;
    const file_path = std.fmt.bufPrint(&file_path_buf, ".gila/todo/{s}/{s}.md", .{ task_id, task_id }) catch unreachable;
    const content = try fs.readFile(file_path);
    try testing.expect(std.mem.indexOf(u8, content, "title: Renamed task") != null);
    try testing.expect(std.mem.indexOf(u8, content, "Original name") == null);
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

    try expectResponseContains(fs.getStdout(), "\"status\":\"started\"");
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
    try expectResponseContains(done_response, "\"status\":\"done\"");
    try expectResponseContains(done_response, "\"completed\":");
    try expectResponseNotContains(done_response, "\"completed\":null");

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
    try expectResponseContains(cancel_response, "\"status\":\"cancelled\"");
    try expectResponseContains(cancel_response, "\"completed\":");

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
    try expectResponseContains(response, "\"result\":");
    try expectResponseContains(response, "\"tasks\":");
    try expectResponseContains(response, "high_pri_abc");
    try expectResponseNotContains(response, "low_pri_abc");
    try expectResponseContains(response, "\"count\":1");
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
    try expectResponseContains(response, "started_tsk_xyz");
    try expectResponseNotContains(response, "todo_task_abc");
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
    try expectResponseContains(response, "feature_tsk_abc");
    try expectResponseContains(response, "bugfix_tsk_abc");
    try expectResponseNotContains(response, "other_tsk_abc");
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
    try expectResponseContains(response, "both_tags_abc");
    try expectResponseNotContains(response, "one_tag_abc");
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
    try expectResponseContains(response, "\"tasks\":[]");
    try expectResponseContains(response, "\"count\":0");
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
    try expectResponseContains(response, "\"id\":\"fields_tsk_abc\"");
    try expectResponseContains(response, "\"title\":\"Fields Test\"");
    try expectResponseContains(response, "\"priority\":\"high\"");
    try expectResponseContains(response, "\"file_path\":");
    try expectResponseNotContains(response, "\"status\":");
    try expectResponseNotContains(response, "\"owner\":");
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
    try expectResponseContains(response, "\"id\":\"default_fl_abc\"");
    try expectResponseContains(response, "\"status\":\"todo\"");
    try expectResponseContains(response, "\"title\":\"Default Fields\"");
    try expectResponseNotContains(response, "\"priority\":");
    try expectResponseNotContains(response, "\"file_path\":");
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
    try expectResponseContains(response, "\"tasks\":");
    try expectResponseContains(response, "\"count\":3");
    try expectResponseContains(response, "\"limit\":18446744073709551615");
    try expectResponseContains(response, "\"offset\":0");
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
    try expectResponseContains(response, "\"available\":3");
    try expectResponseContains(response, "\"count\":2");
    try expectResponseContains(response, "\"limit\":2");
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
    try expectResponseContains(response, "\"available\":3");
    try expectResponseContains(response, "\"count\":2");
    try expectResponseContains(response, "\"offset\":1");
    try expectResponseContains(response, "\"limit\":2");
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
    try expectResponseContains(response, "\"tasks\":[]");
    try expectResponseContains(response, "\"available\":0");
    try expectResponseContains(response, "\"count\":0");
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
    try expectResponseContains(response, "\"transitions\":[]");
    try expectResponseContains(response, "\"updates\":[]");
    try expectResponseContains(response, "\"count\":0");
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
    try expectResponseContains(response, "\"transitions\":");
    try expectResponseContains(response, "misplace_task_abc");
    try expectResponseContains(response, "\"from\":\"todo\"");
    try expectResponseContains(response, "\"to\":\"started\"");

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
    try expectResponseContains(response, "\"updates\":");
    try expectResponseContains(response, "waiting_tsk_xyz");
    try expectResponseContains(response, "removed_completed_dependency");
    try expectResponseContains(response, "done_dep_abc");
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
    try expectResponseContains(response, "\"transitions\":");
    try expectResponseContains(response, "wait_trans_xyz");
    try expectResponseContains(response, "\"from\":\"waiting\"");
    try expectResponseContains(response, "\"to\":\"todo\"");

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
    try expectResponseContains(response, "Backend Feature");
    try expectResponseContains(response, "Frontend Feature");
    try expectResponseNotContains(response, "Bug Fix");
    try expectResponseContains(response, "\"count\":2");
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
    try expectResponseContains(waiting_response, "\"status\":\"waiting\"");
    const waiting_id = try extractTaskIdFromResponse(testing.allocator, waiting_response);

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
    try expectResponseContains(sync_response, waiting_id);
    try expectResponseContains(sync_response, "removed_completed_dependency");

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
    try expectResponseContains(response1, "\"available\":5");
    try expectResponseContains(response1, "\"limit\":2");
    try expectResponseContains(response1, "\"offset\":0");

    fs.clearStdout();
    _ = arena.reset(false);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/find","params":{"limit":2,"offset":2},"id":526}
        \\
    );
    runServer(fs, &arena);

    const response2 = fs.getStdout();
    try expectResponseContains(response2, "\"available\":5");
    try expectResponseContains(response2, "\"limit\":2");
    try expectResponseContains(response2, "\"offset\":2");
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
    try expectResponseContains(find_todo, "Will Stay Todo");
    try expectResponseNotContains(find_todo, "Will Start");
    try expectResponseContains(find_todo, "\"count\":1");

    fs.clearStdout();
    _ = arena.reset(false);

    fs.setStdin(
        \\{"jsonrpc":"2.0","method":"task/find","params":{"status":"started"},"id":534}
        \\
    );
    runServer(fs, &arena);

    const find_started = fs.getStdout();
    try expectResponseContains(find_started, "Will Start");
    try expectResponseNotContains(find_started, "Will Stay Todo");
    try expectResponseContains(find_started, "\"count\":1");
}
