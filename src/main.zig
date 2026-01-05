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
const Tui = @import("commands/tui.zig");
const Find = @import("commands/find.zig");

pub const std_options: std.Options = .{
    .log_level = default_log_level,
    .logFn = logFn,
};

const default_log_level: std.log.Level = switch (builtin.mode) {
    .Debug => std.log.Level.debug,
    else => std.log.Level.info,
};

pub var log_level: std.log.Level = default_log_level;

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
        for (text) |c| {
            result = result ++ &[_]u8{std.ascii.toUpper(c)};
        }
        break :blk result;
    };
    const scope_prefix = "(" ++ @tagName(scope) ++ "): ";

    var buffer: [128]u8 = undefined;
    const stderr_lock = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    const ttyconf = stderr_lock.terminal();
    var stderr = &stderr_lock.file_writer.interface;
    ttyconf.setColor(switch (level) {
        .err => .red,
        .warn => .yellow,
        .info => .green,
        .debug => .magenta,
    }) catch {};
    ttyconf.setColor(.bold) catch {};
    ttyconf.setColor(.bold) catch {};
    stderr.writeAll(level_text) catch return;
    ttyconf.setColor(.reset) catch {};
    ttyconf.setColor(.dim) catch {};
    ttyconf.setColor(.bold) catch {};
    if (scope != .default) {
        stderr.writeAll(scope_prefix) catch return;
    }
    ttyconf.setColor(.reset) catch {};
    stderr.print(format ++ "\n", args) catch return;
}

const CLIArgs = union(enum) {
    init: Init,
    todo: Todo,
    done: Done,
    sync: Sync,
    tui: Tui,
    find: Find,
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
        \\    gila find [--priority=low|medium|high|urgent] [--tags="<[or|and]:><tag1>,<tag2>,..."]
        \\              [--waiting-on="<[or|and]:><task1>,<task2>,..."] [--verbose]
        \\
        \\Commands:
        \\    version   Prints the version of the GILA CLI.
        \\    init      Initializes a new GILA project in the current directory or the specified directory.
        \\    todo      Create a new task to the current project.
        \\    done      Moves a task to the done directory along with all artifacts in the task folder and marks status as done.
        \\    tag       Add tags to a task.
        \\    sync      Synchronizes the tasks in the gila directory by analyzing the tasks and moving them to their appropriate folders
        \\              and modifies necessary properties.
        \\    find      Find tasks that match the given priority, tags and/or waiting_on list.
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
        \\    gila find --priority=low --tags="or:tag1,tag2" --waiting-on="or:task1,task2"
        \\
    ;
};

pub fn main() void {
    var stack_space: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&stack_space);

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.ioBasic();

    var args = std.process.argsWithAllocator(arena.allocator()) catch |err| {
        var stderr = std.fs.File.stderr().writer(&.{});
        stderr.interface.print("Failed to get args: {s}\n", .{@errorName(err)}) catch unreachable;
        return;
    };

    const cli = flags.parseArgs(io, arena.allocator(), &args, CLIArgs);

    switch (cli) {
        .init => |init| init.execute(io, &arena),
        .todo => |todo| todo.execute(io, &arena),
        .done => |done| done.execute(io, &arena),
        .sync => |sync| sync.execute(io, &arena),
        .tui => |tui| tui.execute(io, &arena),
        .find => |find| find.execute(io, &arena),
        .version => {
            var stdout = std.Io.File.stdout().writer(io, &.{});
            stdout.interface.print("v{s}\n", .{zon.version}) catch |err| {
                var stderr = std.Io.File.stderr().writer(io, &.{});
                stderr.interface.print("Failed to write to stdout: {s}", .{@errorName(err)}) catch unreachable;
            };
        },
    }
}

test "All" {
    std.testing.refAllDecls(@This());
}
