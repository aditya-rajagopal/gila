const std = @import("std");
const root = @import("root");

const gila = @import("gila");
const stdx = @import("stdx");

const log = std.log.scoped(.init);

const common = @import("common.zig");

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

pub fn execute(self: @This(), ctx: common.CommandContext) void {
    const io = ctx.io;
    const arena = ctx.arena;
    if (!self.verbose) {
        root.log_level = .warn;
    }
    const allocator = arena.allocator();
    const buffer: []u8 = allocator.alloc(u8, std.fs.max_path_bytes) catch unreachable;

    const cwd = std.Io.Dir.cwd().openDir(io, ".", .{}) catch |err| {
        log.err("Failed to open current directory: {s}", .{@errorName(err)});
        return;
    };
    defer cwd.close(io);
    const len = cwd.realPath(io, buffer) catch |err| {
        log.err("Failed to get current directory: {s}", .{@errorName(err)});
        return;
    };
    var current_dir: []const u8 = buffer[0..len];

    if (self.positional.directory) |directory| {
        if (std.fs.path.isAbsolute(directory)) {
            current_dir = directory;
        } else {
            current_dir = std.fs.path.join(allocator, &.{ current_dir, directory }) catch unreachable;
        }
    }

    var dir = std.Io.Dir.openDirAbsolute(io, current_dir, .{ .iterate = true }) catch |err| {
        log.err("Failed to open current directory {s}: {s}", .{ current_dir, @errorName(err) });
        return;
    };
    defer dir.close(io);

    std.log.info("Opened directory {s}", .{current_dir});

    dir.createDir(io, gila.dir_name, .default_dir) catch |err| {
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
        var stdout = std.Io.File.stdout().writer(io, &.{});
        stdout.interface.print("Initialized GILA project: {s}/{s}\n", .{ current_dir, gila.dir_name }) catch unreachable;
    }

    if (self.bare) {
        return;
    }
    const gila_dir_name = std.fs.path.join(allocator, &.{ current_dir, gila.dir_name }) catch unreachable;
    var gila_dir = std.Io.Dir.openDirAbsolute(io, gila_dir_name, .{ .iterate = true }) catch |err| {
        log.err("Failed to open .gila directory {s}/{s}: {s}", .{ current_dir, gila.dir_name, @errorName(err) });
        return;
    };
    defer gila_dir.close(io);

    gila_dir.createDir(io, "todo", .default_dir) catch |err| {
        log.err("Unexpected error while creating todo folder: {s}", .{@errorName(err)});
        unreachable;
    };
    std.log.info("Successfully created todo folder", .{});

    return;
}

const testing = std.testing;
const TestFs = @import("../testfs/root.zig").TestFs;

const Init = @This();

test "creates gila directory" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    const cmd: Init = .{
        .bare = false,
        .verbose = false,
        .positional = .{ .directory = null },
    };

    var arena_buffer: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buffer);

    const context = common.CommandContext{
        .io = fs.io(),
        .arena = &arena,
        .username = "testuser",
        .editor = "vim",
    };
    cmd.execute(context);

    try testing.expect(fs.dirExists(".gila"));
    try testing.expect(fs.dirExists(".gila/todo"));
    try std.testing.expectEqualStrings("Initialized GILA project: /home/test/.gila\n", fs.getStdout());
}

test "bare mode" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    const cmd: Init = .{
        .bare = true,
        .verbose = false,
        .positional = .{ .directory = null },
    };

    var arena_buffer: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buffer);

    const context = common.CommandContext{
        .io = fs.io(),
        .arena = &arena,
        .username = "testuser",
        .editor = "vim",
    };
    cmd.execute(context);

    try testing.expect(fs.dirExists(".gila"));
    try testing.expect(!fs.dirExists(".gila/todo"));
    try std.testing.expectEqualStrings("Initialized GILA project: /home/test/.gila\n", fs.getStdout());
}

test "already exists" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    try fs.createDir(".gila");

    const cmd: Init = .{
        .bare = false,
        .verbose = false,
        .positional = .{ .directory = null },
    };

    var arena_buffer: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buffer);

    const context = common.CommandContext{
        .io = fs.io(),
        .arena = &arena,
        .username = "testuser",
        .editor = "vim",
    };
    cmd.execute(context);

    const stdout = fs.getStdout();
    try std.testing.expectEqual(0, stdout.len);
}

test "directory" {
    const fs = try TestFs.setup(testing.allocator);
    defer fs.deinit();

    const cmd: Init = .{
        .bare = false,
        .verbose = false,
        .positional = .{ .directory = "/home" },
    };
    var arena_buffer: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&arena_buffer);

    const context = common.CommandContext{
        .io = fs.io(),
        .arena = &arena,
        .username = "testuser",
        .editor = "vim",
    };
    cmd.execute(context);

    try testing.expect(fs.dirExists("/home/.gila"));
    try testing.expect(fs.dirExists("/home/.gila/todo"));

    try std.testing.expectEqualStrings("Initialized GILA project: /home/.gila\n", fs.getStdout());
}
