const std = @import("std");
const root = @import("root");

const gila = @import("gila");
const stdx = @import("stdx");

const log = std.log.scoped(.init);

bare: bool = false,
verbose: bool = false,
positional: struct {
    directory: ?[]const u8 = null,
},

pub const help =
    \\Usage: 
    \\
    \\    gila init [--bare] [--verbose] [<directory>]
    \\
    \\Initializes a new GILA project in the current directory or the specified directory.
    \\
    \\Options:
    \\    --bare
    \\        Creates a bare project without subfolders and tracking files.
    \\
    \\    --verbose 
    \\        Run verbosely.
    \\
    \\    <directory>
    \\        The directory to initialize the project in. Defaults to the current directory.
    \\
    \\Examples:
    \\    gila init
    \\    gila init --verbose some/directory/path
    \\
;

pub fn execute(self: @This(), io: std.Io, arena: *stdx.Arena) void {
    _ = io;
    if (!self.verbose) {
        root.log_level = .warn;
    }
    const allocator = arena.allocator();
    const buffer: []u8 = allocator.alloc(u8, std.fs.max_path_bytes) catch unreachable;

    var current_dir: []const u8 = std.process.getCwd(buffer) catch |err| {
        log.err("Failed to get current directory: {s}", .{@errorName(err)});
        return;
    };

    if (self.positional.directory) |directory| {
        if (std.fs.path.isAbsolute(directory)) {
            current_dir = directory;
        } else {
            current_dir = std.fs.path.join(allocator, &.{ current_dir, directory }) catch unreachable;
        }
    }

    var dir = std.fs.openDirAbsolute(current_dir, .{ .iterate = true }) catch |err| {
        log.err("Failed to open current directory {s}: {s}", .{ current_dir, @errorName(err) });
        return;
    };
    defer dir.close();

    std.log.info("Opened directory {s}", .{current_dir});

    dir.makeDir(gila.dir_name) catch |err| {
        switch (err) {
            error.PathAlreadyExists => {
                log.err("Reinitializing existing GILA project: {s}/{s}", .{ current_dir, gila.dir_name });
                return;
            },
            else => |e| {
                log.err("Failed to initialize GILA project: {s}", .{@errorName(e)});
                return;
            },
        }
    };
    defer {
        var stdout = std.fs.File.stdout().writer(&.{});
        stdout.interface.print("Initialized GILA project: {s}/{s}\n", .{ current_dir, gila.dir_name }) catch unreachable;
    }

    if (self.bare) {
        return;
    }
    const gila_dir_name = std.fs.path.join(allocator, &.{ current_dir, gila.dir_name }) catch unreachable;
    var gila_dir = std.fs.openDirAbsolute(gila_dir_name, .{ .iterate = true }) catch |err| {
        log.err("Failed to open .gila directory {s}/{s}: {s}", .{ current_dir, gila.dir_name, @errorName(err) });
        return;
    };
    defer gila_dir.close();

    gila_dir.makeDir("todo") catch |err| {
        log.err("Unexpected error while creating todo folder: {s}", .{@errorName(err)});
        unreachable;
    };
    std.log.info("Successfully created todo folder", .{});

    return;
}
