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
    \\
    \\    gila server [-h | --help] [--run-once]
    \\
    \\Starts a JSON-RPC 2.0 server for external tool integration (e.g., Neovim plugin).
    \\Communicates via stdin/stdout with line-delimited JSON.
    \\
    \\Methods:
    \\    task/create   Create a new task
    \\                  Params: {title, description?, priority?, priority_value?, tags?, waiting_on?}
    \\                  Returns: {task_id, file_path, status}
    \\
    \\    task/get      Get task details by ID
    \\                  Params: {task_id}
    \\                  Returns: Full task object with file_path
    \\
    \\    task/update   Update task status or fields
    \\                  Params: {task_id, status?, title?, description?, priority?, priority_value?, tags?}
    \\                  Returns: {task_id, status, file_path, completed}
    \\
    \\    shutdown      Stop the server gracefully
    \\                  Params: none
    \\                  Returns: {message}
    \\
    \\JSON-RPC 2.0 Format:
    \\    Request:  {"jsonrpc": "2.0", "method": "task/create", "params": {...}, "id": 1}
    \\    Response: {"jsonrpc": "2.0", "result": {...}, "id": 1}
    \\    Error:    {"jsonrpc": "2.0", "error": {"code": -32001, "message": "..."}, "id": 1}
    \\
    \\Examples:
    \\    echo '{"jsonrpc":"2.0","method":"task/create","params":{"title":"Test task"},"id":1}' | gila server
    \\
;

// @LEFTOFF make the configuration for arena size, line buffer size, etc configurable
pub fn execute(self: Server, io: std.Io, arena: *stdx.Arena) void {
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
        const line_buffer = allocator.alloc(u8, 32) catch unreachable;
        var line_writer = std.Io.Writer.fixed(line_buffer);

        const line = stdin.interface.streamDelimiterLimit(&line_writer, '\n', .limited(32)) catch |err| switch (err) {
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
