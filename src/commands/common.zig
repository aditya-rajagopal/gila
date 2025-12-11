const std = @import("std");
const log = std.log.scoped(.gila);

const gila = @import("gila");

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
