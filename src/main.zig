const std = @import("std");
const assert = std.debug.assert;

const gila = @import("gila");
const DateTimeUTC = gila.DateTimeUTC;

const flags = @import("flags.zig");
const log = std.log.scoped(.gila);

pub const std_options: std.Options = .{
    .logFn = logFn,
};

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_text = comptime level.asText();
    const scope_prefix = if (scope == .gila) ": " else "(" ++ @tagName(scope) ++ "): ";
    const date_time = DateTimeUTC.now();

    const writer = if (level != .err) blk: {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        break :blk stdout;
    } else blk: {
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        std.debug.lockStdErr();
        break :blk stderr;
    };

    nosuspend {
        date_time.format("", .{}, writer) catch return;
        writer.print(" " ++ level_text ++ scope_prefix ++ format ++ "\n", args) catch return;
    }
    if (level == .err) {
        std.debug.unlockStdErr();
    }
}

const EnumTest = enum(u8) { a, b, c };

const CLIArgs = union(enum) {
    init: Init,

    const Init = struct {
        bare: bool = false,
        positional: struct {
            directory: ?[]const u8 = null,
        },

        pub const help =
            \\Usage: gila init [--bare] [<directory>]
            \\
            \\Initializes a new GILA project in the current directory or the specified directory.
            \\
            \\Options:
            \\  --bare  Creates a bare project without subfolders and tracking files.
            \\  <directory>  The directory to initialize the project in. Defaults to the current directory.
            \\
        ;
    };

    pub const help =
        \\Usage:
        \\
        \\    gila [-h | --help]
        \\
        \\    gila init [-h | --help] [--bare] [<directory>]
        \\
        \\Commands:
        \\    init  Initializes a new GILA project in the current directory or the specified directory.
        \\
        \\Options:
        \\    -h, --help
        \\        Prints this help message.
        \\
    ;
};

pub fn main() !void {
    var stack_space: [1024 * 1024]u8 = undefined;
    var permanent_storage = std.heap.FixedBufferAllocator.init(stack_space[0 .. 1024 * 1024]);

    const permanent_allocator = permanent_storage.allocator();
    var args = try std.process.argsWithAllocator(permanent_allocator);

    // var writer = std.fs.File.stdout().writer(&.{}).interface;
    // writer.print("{s}", .{gila.logo}) catch unreachable;
    // writer.print("GILA SPEC v0.0.1\n", .{}) catch unreachable;
    const cli = flags.parseArgs(&args, CLIArgs);

    switch (cli) {
        .init => |init| {
            const buffer: []u8 = permanent_allocator.alloc(u8, std.fs.max_path_bytes) catch unreachable;

            const current_dir: []const u8 = try std.process.getCwd(buffer);
            var dir = try std.fs.openDirAbsolute(current_dir, .{ .iterate = true });
            defer dir.close();

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
            log.info("Initialized GILA project: {s}/{s}", .{ current_dir, gila.dir_name });
            if (init.bare) {
                return;
            }
            log.info("TODO: init sub folders and tracking files", .{});
            return;
        },
    }

    const buffer: []u8 = permanent_allocator.alloc(u8, std.fs.max_path_bytes) catch unreachable;
    var current_dir: []const u8 = try std.process.getCwd(buffer);

    outter_loop: for (0..128) |_| {
        var dir = try std.fs.openDirAbsolute(current_dir, .{ .iterate = true });
        defer dir.close();

        var dir_walker = dir.iterateAssumeFirstIteration();
        while (try dir_walker.next()) |entry| {
            if (entry.kind == .directory) {
                if (std.mem.eql(u8, entry.name, gila.dir_name)) {
                    log.info("Found .gila directory: {s}/{s}\n", .{ current_dir, entry.name });
                    break :outter_loop;
                }
            }
        }
        current_dir = std.fs.path.dirname(current_dir) orelse break;
    }
}
