const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const gila = @import("gila");
const stdx = @import("stdx");
const flags = stdx.flags;
const zon = @import("zon");

const Todo = @import("commands/todo.zig");
const Init = @import("commands/init.zig");
const Done = @import("commands/done.zig");
const Sync = @import("commands/sync.zig");

pub const std_options: std.Options = .{
    .logFn = logFn,
};

pub var log_level: std.log.Level = switch (builtin.mode) {
    .Debug => std.log.Level.debug,
    else => std.log.Level.info,
};

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(log_level)) return;
    const level_text = comptime blk: {
        const text: []const u8 = level.asText();
        var result: []const u8 = &.{};
        for (text) |*c| {
            result = result ++ &[_]u8{std.ascii.toUpper(c.*)};
        }
        break :blk result;
    };
    const scope_prefix = "(" ++ @tagName(scope) ++ "): ";
    // const date_time = DateTimeUTC.now();

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
        // date_time.format("", .{}, writer) catch return;
        // " " ++
        writer.print(level_text ++ scope_prefix ++ format ++ "\n", args) catch return;
    }
    if (level == .err) {
        std.debug.unlockStdErr();
    }
}

const CLIArgs = union(enum) {
    init: Init,
    todo: Todo,
    done: Done,
    sync: Sync,
    version,

    pub const help =
        \\Usage:
        \\
        \\    gila [-h | --help]
        \\
        \\    gila version
        \\
        \\    gila init [-h | --help] [--bare] [<directory>]
        \\
        \\    gila todo [--priority=low|medium|high|urgent] [--priority-value=<integer value>] 
        \\              [--description=<description>] [--tags="<tag1>,<tag2>,..."] 
        \\              [--waiting-on="<task1>,<task2>,..."] [--verbose]
        \\              [--edit] <title>
        \\
        \\    gila done [-h | --help] [--verbose] [--edit] <task_id>
        \\
        \\    gila sync [-h | --help] [--verbose]
        \\
        \\Commands:
        \\    version   Prints the version of the GILA CLI.
        \\    init      Initializes a new GILA project in the current directory or the specified directory.
        \\    todo      Create a new task to the current project.
        \\    done      Moves a task to the done directory along with all artifacts in the task folder and marks status as done.
        \\    tag       Add tags to a task.
        \\    sync      Synchronizes the tasks in the gila directory by analyzing the tasks and moving them to their appropriate folders
        \\              and modifies necessary properties.
        \\
        \\Options:
        \\    -h, --help
        \\        Prints this help message.
        \\
        \\Examples Lifecycle:
        \\    gila init
        \\    gila todo --priority=low --priority-value=50 --description="This is a description" 'Title of the task'
        \\    gila done lonely_mamba_6kr
        \\    gila sync
        \\
    ;
};

pub fn main() void {
    var stack_space: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&stack_space);

    var args = std.process.argsWithAllocator(arena.allocator()) catch |err| {
        var stderr = std.fs.File.stderr().writer(&.{});
        stderr.interface.print("Failed to get args: {s}\n", .{@errorName(err)}) catch unreachable;
        return;
    };

    const cli = flags.parseArgs(arena.allocator(), &args, CLIArgs);

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.ioBasic();

    switch (cli) {
        .init => |init| init.execute(io, &arena),
        .todo => |todo| todo.execute(io, &arena),
        .done => |done| done.execute(io, &arena),
        .sync => |sync| sync.execute(io, &arena),
        .version => {
            var stdout = std.fs.File.stdout().writer(&.{});
            stdout.interface.print("v{s}\n", .{zon.version}) catch |err| {
                var stderr = std.fs.File.stderr().writer(&.{});
                stderr.interface.print("Failed to write to stdout: {s}", .{@errorName(err)}) catch unreachable;
            };
        },
    }
}

test "All" {
    std.testing.refAllDecls(@This());
}
