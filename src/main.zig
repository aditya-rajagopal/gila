const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const gila = @import("gila");
const DateTimeUTC = gila.DateTimeUTC;

const flags = @import("flags.zig");
const log = std.log.scoped(.gila);

pub const std_options: std.Options = .{
    .logFn = logFn,
};

var log_level: std.log.Level = std.log.Level.info;

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(log_level)) return;
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

const CLIArgs = union(enum) {
    init: Init,
    add: Add,

    const Add = struct {
        priority: gila.Priority = .medium,
        priority_value: u8 = 50,
        description: ?[]const u8 = null,
        positional: struct {
            title: []const u8,
        },

        pub const help =
            \\Usage:
            \\
            \\    gila add [--priority=low|medium|high|urgent] [--priority-value=<value>] 
            \\              [--description=<description>] <title>
            \\
            \\Adds a new task to the current project.
            \\
            \\Options:
            \\    -h, --help  Prints this help message.
            \\    --priority=<priority>  The priority of the task. Can be one of low, medium, high, or urgent.
            \\    --priority-value=<value>  The priority value of the task. Can be an integer between 0 to 255. Defaults to 50.
            \\    --description=<description>  The description of the task.
            \\    <title>  The title of the task.
            \\
            \\Examples:
            \\    gila add --priority=low --priority-value=50 --description="This is a description" 'Title of the task'
            \\    gila add --priority-value=200 'Title of the task'
            \\
        ;
    };

    const Init = struct {
        bare: bool = false,
        positional: struct {
            directory: ?[]const u8 = null,
        },

        pub const help =
            \\Usage: 
            \\
            \\    gila init [--bare] [<directory>]
            \\
            \\Initializes a new GILA project in the current directory or the specified directory.
            \\
            \\Options:
            \\  --bare  Creates a bare project without subfolders and tracking files.
            \\  <directory>  The directory to initialize the project in. Defaults to the current directory.
            \\
            \\Examples:
            \\    gila init
            \\    gila init some/directory/path
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
        \\    gila add [-h | --help] [--priority=<priority>] [--priority-value=<value>] [--description=<description>] <title>
        \\
        \\Commands:
        \\    init  Initializes a new GILA project in the current directory or the specified directory.
        \\    add   Adds a new task to the current project.
        \\
        \\Options:
        \\    -h, --help
        \\        Prints this help message.
        \\
        \\Examples:
        \\    gila init
        \\    gila init some/directory/path
        \\    gila add --priority=low --priority-value=50 --description="This is a description" 'Title of the task'
        \\
    ;
};

pub fn main() !void {
    var stack_space: [1024 * 1024]u8 = undefined;
    var permanent_storage = std.heap.FixedBufferAllocator.init(stack_space[0 .. 1024 * 1024]);

    const permanent_allocator = permanent_storage.allocator();
    var args = try std.process.argsWithAllocator(permanent_allocator);

    const cli = flags.parseArgs(&args, CLIArgs);

    switch (cli) {
        .init => |init| {
            const buffer: []u8 = permanent_allocator.alloc(u8, std.fs.max_path_bytes) catch unreachable;

            var current_dir: []const u8 = try std.process.getCwd(buffer);

            if (init.positional.directory) |directory| {
                if (std.fs.path.isAbsolute(directory)) {
                    current_dir = directory;
                } else {
                    current_dir = std.fs.path.join(permanent_allocator, &.{ current_dir, directory }) catch unreachable;
                }
            }

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
            const gila_dir_name = std.fs.path.join(permanent_allocator, &.{ current_dir, gila.dir_name }) catch unreachable;
            var gila_dir = try std.fs.openDirAbsolute(gila_dir_name, .{ .iterate = true });
            defer gila_dir.close();

            gila_dir.makeDir("TODO") catch |err| {
                log.err("Unexpected error while creating TODO folder: {s}", .{@errorName(err)});
                unreachable;
            };

            return;
        },
        .add => |add| {
            var current_dir: []const u8 = try std.process.getCwdAlloc(permanent_allocator);

            outter_loop: for (0..128) |_| {
                var dir = std.fs.openDirAbsolute(current_dir, .{ .iterate = true }) catch |err| {
                    log.err("Failed to open current directory: {s}", .{@errorName(err)});
                    return;
                };
                defer dir.close();

                var dir_walker = dir.iterateAssumeFirstIteration();
                while (dir_walker.next() catch |err| {
                    log.err("Failed to iterate directory {s}: {s}", .{ current_dir, @errorName(err) });
                    return;
                }) |entry| {
                    if (entry.kind == .directory) {
                        if (std.mem.eql(u8, entry.name, gila.dir_name)) {
                            break :outter_loop;
                        }
                    }
                }
                current_dir = std.fs.path.dirname(current_dir) orelse break;
            }
            var base_dir = std.fs.openDirAbsolute(current_dir, .{}) catch |err| {
                log.err("Failed to open directory {s}: {s}", .{ current_dir, @errorName(err) });
                return;
            };
            defer base_dir.close();

            var gila_dir = base_dir.openDir(gila.dir_name, .{}) catch |err| {
                log.err("Failed to open .gila directory {s}/{s}: {s}", .{ current_dir, gila.dir_name, @errorName(err) });
                return;
            };

            defer gila_dir.close();

            gila_dir.makeDir("TODO") catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => |e| {
                    log.err("Failed to create TODO folder: {s}", .{@errorName(e)});
                    return;
                },
            };
            var todo_dir = gila_dir.openDir("TODO", .{}) catch |err| {
                log.err("Failed to open TODO folder: {s}", .{@errorName(err)});
                return;
            };
            defer todo_dir.close();
            const date_time = gila.DateTimeUTC.now();
            const user_name = switch (builtin.os.tag) {
                .windows => std.process.getEnvVarOwned(permanent_allocator, "USERNAME") catch |err| {
                    log.err("Failed to get USERNAME environment variable: {s}", .{@errorName(err)});
                    return;
                },
                else => std.process.getEnvVarOwned(permanent_allocator, "USER") catch |err| {
                    log.err("Failed to get USER environment variable: {s}", .{@errorName(err)});
                    return;
                },
            };

            const task_name = try std.fmt.allocPrint(permanent_allocator, "{d}_{d}_{s}", .{
                date_time.dateAsNumber(),
                date_time.timeAsNumber(),
                user_name,
            });

            todo_dir.makeDir(task_name) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    @branchHint(.unlikely);
                    log.err("Task {s} already exists. If you want to create a new task you can wait for 1 second and try again.", .{task_name});
                    return;
                },
                else => |e| {
                    log.err("Failed to create task {s}: {s}", .{ task_name, @errorName(e) });
                    return;
                },
            };

            var task_dir = todo_dir.openDir(task_name, .{}) catch |err| {
                log.err("Failed to open task {s}: {s}", .{ task_name, @errorName(err) });
                return;
            };
            defer task_dir.close();

            var description_file = task_dir.createFile("description.md", .{}) catch |err| {
                log.err("Failed to create description.md file: {s}", .{@errorName(err)});
                return;
            };
            defer description_file.close();

            var buffer: [4096]u8 = undefined;
            var writer = description_file.writer(&buffer);
            const interface: *std.Io.Writer = &writer.interface;

            interface.print(gila.description_header_template, .{
                add.positional.title,
                @tagName(.todo),
                @tagName(add.priority),
                add.priority_value,
                user_name,
            }) catch |err| {
                log.err("Failed to write to description.md: {s}", .{@errorName(err)});
                return;
            };
            date_time.format("", .{}, interface) catch |err| {
                log.err("Failed to write to description.md: {s}", .{@errorName(err)});
                return;
            };
            if (add.description) |description| {
                interface.print(gila.description_body_template, .{description}) catch |err| {
                    log.err("Failed to write to description.md: {s}", .{@errorName(err)});
                    return;
                };
            } else {
                interface.print(gila.description_body_template, .{""}) catch |err| {
                    log.err("Failed to write to description.md: {s}", .{@errorName(err)});
                    return;
                };
            }

            // @IMPORTANT I never forget to flush
            interface.flush() catch |err| {
                log.err("Failed to flush description.md: {s}", .{@errorName(err)});
                return;
            };

            description_file.sync() catch |err| {
                log.err("Failed to sync description.md: {s}", .{@errorName(err)});
                return;
            };

            log.info("New task created at: {s}/TODO/{s}/description.md", .{ current_dir, task_name });

            return;
        },
    }
}
