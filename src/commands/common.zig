const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.gila);

const gila = @import("gila");
const stdx = @import("stdx");

pub fn moveTaskData(allocator: std.mem.Allocator, gila_dir: std.fs.Dir, task_name: []const u8, from: gila.Status, to: gila.Status) !void {
    const from_folder = std.fs.path.join(allocator, &.{ @tagName(from), task_name }) catch |err| {
        log.err("Unexpected error while joining {s}/{s}: {s}", .{ @tagName(from), task_name, @errorName(err) });
        return;
    };
    const to_folder = std.fs.path.join(allocator, &.{ @tagName(to), task_name }) catch |err| {
        log.err("Unexpected error while joining {s}/{s}: {s}", .{ @tagName(to), task_name, @errorName(err) });
        return;
    };
    gila_dir.rename(from_folder, to_folder) catch |err| {
        log.err("Failed to move task {s} from {s} to {s}: {s}", .{ task_name, @tagName(from), @tagName(to), @errorName(err) });
    };
    log.info("Successfully moved task folder along with all artifacts {s} from {s} to {s}", .{ task_name, @tagName(from), @tagName(to) });
}

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
