const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.common);
const builtin = @import("builtin");

const gila = @import("gila");
const stdx = @import("stdx");

pub fn getUserName(gpa: std.mem.Allocator) ![]const u8 {
    const user_env = if (builtin.os.tag == .windows) "USERNAME" else "USER";
    return std.process.getEnvVarOwned(gpa, user_env);
}

pub fn moveTaskData(allocator: std.mem.Allocator, gila_dir: std.fs.Dir, task_name: []const u8, from: gila.Status, to: gila.Status) !void {
    if (from == to) return;
    const from_folder = std.fs.path.join(allocator, &.{ @tagName(from), task_name }) catch |err| {
        log.err("Unexpected error while joining {s}/{s}: {s}", .{ @tagName(from), task_name, @errorName(err) });
        return;
    };
    const to_folder = std.fs.path.join(allocator, &.{ @tagName(to), task_name }) catch |err| {
        log.err("Unexpected error while joining {s}/{s}: {s}", .{ @tagName(to), task_name, @errorName(err) });
        return;
    };
    gila_dir.makePath(@tagName(to)) catch |err| {
        log.err("Failed to create directory {s}: {s}", .{ @tagName(to), @errorName(err) });
        return;
    };
    gila_dir.rename(from_folder, to_folder) catch |err| {
        log.err("Failed to move task {s} from {s} to {s}: {s}", .{ task_name, @tagName(from), @tagName(to), @errorName(err) });
    };
    log.info("Successfully moved task folder along with all artifacts {s} from {s} to {s}", .{ task_name, @tagName(from), @tagName(to) });
}

pub fn getGilaDir(gpa: std.mem.Allocator) ?struct { []const u8, std.fs.Dir } {
    const gila_path = std.fs.path.join(gpa, &.{ searchForGilaDir(gpa) orelse return null, gila.dir_name }) catch unreachable;

    const gila_dir = std.fs.openDirAbsolute(gila_path, .{}) catch |err| {
        log.err("Failed to open .gila directory {s}: {s}", .{ gila_path, @errorName(err) });
        return null;
    };
    log.info("Opened gila directory {s}", .{gila_path});
    return .{ gila_path, gila_dir };
}

pub fn searchForGilaDir(gpa: std.mem.Allocator) ?[]const u8 {
    const pwd: []const u8 = std.process.getCwdAlloc(gpa) catch |err| {
        log.err("Failed to get current directory: {s}", .{@errorName(err)});
        return null;
    };
    log.debug("Current directory: {s}", .{pwd});
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

pub const WaitingOn = struct {
    tasks: []const []const u8,

    pub fn parseFlagValue(gpa: std.mem.Allocator, flag_value: []const u8, error_out: *?[]const u8) error{Invalid}!@This() {
        if (flag_value.len == 0) {
            error_out.* = "Empty tag list";
            return error.Invalid;
        }
        const task_count: usize = std.mem.countScalar(u8, flag_value, ',');
        var tasks = std.mem.splitScalar(u8, flag_value, ',');
        const task_list = gpa.alloc([]const u8, task_count + 1) catch {
            error_out.* = "Failed to allocate tag list";
            return error.Invalid;
        };
        errdefer gpa.free(task_list);

        for (0..task_count + 1) |index| {
            const task = tasks.next().?;
            if (task.len == 0) {
                error_out.* = "Empty tag in list";
                return error.Invalid;
            }
            if (!gila.id.isValid(task)) {
                error_out.* = "Invalid task id in list";
                return error.Invalid;
            }
            const task_ref: []u8 = gpa.alloc(u8, task.len + 6) catch {
                error_out.* = "Failed to allocate task reference";
                return error.Invalid;
            };
            @memcpy(task_ref[0..3], "\"[[");
            @memcpy(task_ref[3..][0..task.len], task);
            @memcpy(task_ref[3 + task.len ..], "]]\"");
            task_list[index] = task_ref;
        }
        return .{
            .tasks = task_list,
        };
    }
};

pub const Blocks = struct {
    tasks: []const []const u8,

    pub fn parseFlagValue(gpa: std.mem.Allocator, flag_value: []const u8, error_out: *?[]const u8) error{Invalid}!@This() {
        if (flag_value.len == 0) {
            error_out.* = "Empty task list";
            return error.Invalid;
        }
        const task_count: usize = std.mem.countScalar(u8, flag_value, ',');
        var tasks = std.mem.splitScalar(u8, flag_value, ',');
        const task_list = gpa.alloc([]const u8, task_count + 1) catch {
            error_out.* = "Failed to allocate task list";
            return error.Invalid;
        };
        errdefer gpa.free(task_list);

        for (0..task_count + 1) |index| {
            const task = tasks.next().?;
            if (task.len == 0) {
                error_out.* = "Empty task id in list";
                return error.Invalid;
            }
            if (!gila.id.isValid(task)) {
                error_out.* = "Invalid task id in list";
                return error.Invalid;
            }
            task_list[index] = task;
        }
        return .{
            .tasks = task_list,
        };
    }
};

pub const Tags = struct {
    tags: []const []const u8,

    pub fn parseFlagValue(gpa: std.mem.Allocator, flag_value: []const u8, error_out: *?[]const u8) error{Invalid}!@This() {
        if (flag_value.len == 0) {
            error_out.* = "Empty tag list";
            return error.Invalid;
        }
        const illegal_characters = "\r\n\t";
        const illegal_char = std.mem.findAny(u8, flag_value, illegal_characters);
        if (illegal_char) |_| {
            error_out.* = "Tag list cannot contain any of '" ++ illegal_characters ++ "'";
            return error.Invalid;
        }
        const tag_count: usize = std.mem.countScalar(u8, flag_value, ',');
        var tags = std.mem.splitScalar(u8, flag_value, ',');
        const tag_list = gpa.alloc([]const u8, tag_count + 1) catch {
            error_out.* = "Failed to allocate tag list";
            return error.Invalid;
        };
        errdefer gpa.free(tag_list);

        for (0..tag_count + 1) |index| {
            const tag = tags.next().?;
            if (tag.len == 0) {
                error_out.* = "Empty tag in list";
                return error.Invalid;
            }
            tag_list[index] = tag;
        }
        return .{
            .tags = tag_list,
        };
    }
};
