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

pub const InsertOnceGapBuffer = struct {
    buffer: [3][]u8,
    used: [3]u32,
    cursor: u32,

    pub fn init(data: []u8) InsertOnceGapBuffer {
        return .{
            .buffer = [_][]u8{ data, &.{}, &.{} },
            .used = [_]usize{ data.len, 0, 0 },
            .cursor = 0,
        };
    }

    pub fn setCursor(self: *InsertOnceGapBuffer, cursor: usize) void {
        const total_length = @reduce(.Add, self.used);
        assert(cursor <= total_length);
        self.cursor = cursor;
    }

    pub fn insert(self: *InsertOnceGapBuffer, data: []u8) void {
        _ = self; // autofix
        _ = data; // autofix
    }

    pub fn deleteForward(self: *InsertOnceGapBuffer, length: usize) void {
        _ = self; // autofix
        _ = length; // autofix
    }
};

pub const Task = struct {
    title: []u8,
    description: []u8,
    status: gila.Status,
    priority: gila.Priority,
    owner: []u8,
    created: stdx.DateTimeUTC,
    completed: ?stdx.DateTimeUTC,
    tags: ?[][]u8,

    pub fn init(gpa: std.mem.Allocator, id: gila.TaskId, gila_dir_absolute_path: []const u8) !Task {
        _ = gpa; // autofix
        _ = id; // autofix
        var gila_dir = std.fs.openDirAbsolute(gila_dir_absolute_path, .{ .iterate = true }) catch |err| {
            log.err("Failed to open gila directory: {s}", .{@errorName(err)});
            return error.FailedToOpenGilaDirectory;
        };
        defer gila_dir.close();
    }
};
