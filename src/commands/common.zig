const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.gila);

const gila = @import("gila");
const stdx = @import("stdx");

pub fn searchForGilaDir(pwd: []const u8) ?[]const u8 {
    var current_dir: []const u8 = pwd;

    outter_loop: for (0..128) |_| {
        var dir = std.fs.openDirAbsolute(current_dir, .{ .iterate = true }) catch |err| {
            log.err("Failed to open current directory: {s}", .{@errorName(err)});
            return null;
        };
        defer dir.close();

        var dir_walker = dir.iterateAssumeFirstIteration();
        while (dir_walker.next() catch |err| {
            log.err("Failed to iterate directory {s}: {s}", .{ current_dir, @errorName(err) });
            return null;
        }) |entry| {
            if (entry.kind == .directory) {
                if (std.mem.eql(u8, entry.name, gila.dir_name)) {
                    log.info("Found .gila directory at {s}/{s}", .{ current_dir, gila.dir_name });
                    break :outter_loop;
                }
            }
        }
        current_dir = std.fs.path.dirname(current_dir) orelse {
            log.err("Failed to find a valid .gila directory in '{s}' and its parents. Please use `gila init`", .{pwd});
            return null;
        };
    }

    return current_dir;
}

pub const Task = struct {
    pub const FindResult = struct {
        file: ?std.fs.File,
        status: gila.Status,
    };
    const FindError = error{
        FailedToOpenGilaDirectory,
        TaskNotFound,
    } || std.fs.File.OpenError;
    pub fn find(gpa: std.mem.Allocator, task_name: []const u8, gila_dir: std.fs.Dir) FindError!FindResult {
        var buffer: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        writer.print("{s}.md", .{task_name}) catch unreachable;
        const task_file_name = writer.buffered();

        const fixed_buffer: []u8 = gpa.alloc(u8, std.fs.max_path_bytes) catch |err| {
            log.err("Failed to allocate path buffer: {s}", .{@errorName(err)});
            return error.FailedToOpenGilaDirectory;
        };
        defer gpa.free(fixed_buffer);
        var path_arena = std.heap.FixedBufferAllocator.init(fixed_buffer);

        var result: FindResult = .{ .file = null, .status = .todo };
        inline for (std.meta.fields(gila.Status)) |field| {
            path_arena.reset();
            if (result.file == null) {
                const name = std.fs.path.join(path_arena.allocator(), &.{ field.name, task_name, task_file_name }) catch |err| {
                    log.err("Unexpected error when constructing path to task: {s}", .{@errorName(err)});
                    return error.FailedToOpenGilaDirectory;
                };
                result.file = gila_dir.openFile(name, .{ .mode = .read_only }) catch |err| switch (err) {
                    error.FileNotFound => blk: {
                        log.debug("Task {s} does not exist in {s} directory", .{ task_name, name });
                        break :blk null;
                    },
                    else => |e| {
                        log.err("Failed to open task {s}: {s}", .{ task_name, @errorName(e) });
                        return e;
                    },
                };
                result.status = comptime std.meta.stringToEnum(gila.Status, field.name).?;
                if (result.file) |_| {
                    log.debug("Found task {s} at {s}", .{ task_name, name });
                }
            }
        }

        return result;
    }
};
