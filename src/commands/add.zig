const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const root = @import("root");

const log = std.log.scoped(.gila);

const gila = @import("gila");
const stdx = @import("stdx");

priority: gila.Priority = .medium,
priority_value: u8 = 50,
description: ?[]const u8 = null,
verbose: bool = false,
positional: struct {
    title: []const u8,
},

pub const help =
    \\Usage:
    \\
    \\    gila add [--priority=low|medium|high|urgent] [--priority-value=<value>] 
    \\              [--description=<description>] [--verbose] <title>
    \\
    \\Adds a new task to the current project.
    \\
    \\Options:
    \\    -h, --help
    \\        Prints this help message.
    \\
    \\    --priority=<priority>  
    \\        The priority of the task. Can be one of low, medium, high, or urgent.
    \\
    \\    --priority-value=<value>  
    \\        The priority value of the task. Can be an integer between 0 to 255. Defaults to 50.
    \\
    \\    --description=<description>
    \\
    \\        The description of the task.
    \\
    \\    --verbose 
    \\        Run verbosely. Prints the contents of the task description file to stdout.
    \\
    \\    <title>
    \\        The title of the task.
    \\
    \\Examples:
    \\    gila add --priority=low --priority-value=50 --description="This is a description" 'Title of the task'
    \\    gila add --priority-value=200 'Title of the task'
    \\
;

pub fn execute(self: @This(), arena: *stdx.Arena) void {
    const allocator = arena.allocator();
    if (!self.verbose) {
        root.log_level = .warn;
    }
    var current_dir: []const u8 = std.process.getCwdAlloc(allocator) catch |err| {
        log.err("Failed to get current directory: {s}", .{@errorName(err)});
        return;
    };

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
                    log.info("Found .gila directory at {s}/{s}", .{ current_dir, gila.dir_name });
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
    log.info("Opened directory {s}", .{current_dir});

    var gila_dir = base_dir.openDir(gila.dir_name, .{}) catch |err| {
        log.err("Failed to open .gila directory {s}/{s}: {s}", .{ current_dir, gila.dir_name, @errorName(err) });
        return;
    };
    log.info("Opened .gila directory {s}/{s}", .{ current_dir, gila.dir_name });

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
    log.info("Successfully opened or created TODO folder", .{});

    const task_id: gila.TaskId = gila.TaskId.new(allocator) catch |err| {
        log.err("Failed to get user environment variable: {s}", .{@errorName(err)});
        return;
    };

    const task_name = std.fmt.allocPrint(allocator, "{f}", .{
        task_id,
    }) catch |err| {
        log.err("Failed to allocate task name: {s}", .{@errorName(err)});
        return;
    };

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
    log.info("Successfully created task directory {s}", .{task_name});

    var task_dir = todo_dir.openDir(task_name, .{}) catch |err| {
        log.err("Failed to open task {s}: {s}", .{ task_name, @errorName(err) });
        return;
    };
    defer task_dir.close();

    var description_file = task_dir.createFile("description.md", .{ .read = self.verbose }) catch |err| {
        log.err("Failed to create description.md file: {s}", .{@errorName(err)});
        return;
    };
    defer description_file.close();
    log.info("Successfully created description.md file", .{});

    var buffer: [4096]u8 = undefined;
    var writer = description_file.writer(&buffer);
    const interface: *std.Io.Writer = &writer.interface;

    interface.print(gila.description_header_template, .{
        self.positional.title,
        @tagName(.todo),
        @tagName(self.priority),
        self.priority_value,
        task_id.user_name,
        task_id.date_time,
    }) catch |err| {
        log.err("Failed to write to description.md: {s}", .{@errorName(err)});
        return;
    };

    if (self.description) |description| {
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
    log.info("Successfully written template to description.md", .{});

    // Print the file contents to stdout
    var stdout = std.fs.File.stdout().writer(&buffer);
    if (self.verbose) {
        var file_reader = description_file.reader(&.{});

        description_file.seekTo(0) catch |err| {
            log.err("Failed to seek to start of {s}/TODO/{s}/description.md: {s}", .{ current_dir, task_name, @errorName(err) });
            return;
        };
        const stat = description_file.stat() catch |err| {
            log.err("Failed to get stat for  {s}/TODO/{s}/description.md: {s}", .{ current_dir, task_name, @errorName(err) });
            return;
        };
        assert(stat.size <= arena.remainingCapacity());

        const file_contents = file_reader.interface.readAlloc(allocator, stat.size) catch |err| {
            log.err("Failed to read {s}/TODO/{s}/description.md: {s}", .{ current_dir, task_name, @errorName(err) });
            return;
        };
        stdout.interface.writeAll(file_contents) catch unreachable;

        // @IMPORTANT I never forget to flush
        stdout.interface.flush() catch |err| {
            log.err("Failed to flush stdout: {s}", .{@errorName(err)});
            return;
        };
    }
    stdout.interface.print("New task created at: {s}/TODO/{s}/description.md\n", .{ current_dir, task_name }) catch unreachable;
    // @IMPORTANT I never forget to flush
    stdout.interface.flush() catch unreachable;
    return;
}
