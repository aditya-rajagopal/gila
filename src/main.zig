const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const gila = @import("gila");
const DateTimeUTC = gila.DateTimeUTC;
const stdx = @import("stdx");
const flags = stdx.flags;
const zon = @import("zon");

const Create = @import("commands/create.zig");
const Init = @import("commands/init.zig");

const log = std.log.scoped(.gila);

pub const std_options: std.Options = .{
    .logFn = logFn,
};

pub var log_level: std.log.Level = std.log.Level.info;

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
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
    create: Create,
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
        \\    gila create [-h | --help] [--priority=<priority>] [--priority-value=<value>] [--description=<description>] <title>
        \\
        \\Commands:
        \\    version   Prints the version of the GILA CLI.
        \\    init      Initializes a new GILA project in the current directory or the specified directory.
        \\    create    Create a new task to the current project.
        \\
        \\Options:
        \\    -h, --help
        \\        Prints this help message.
        \\
        \\Examples:
        \\    gila init
        \\    gila init some/directory/path
        \\    gila create --priority=low --priority-value=50 --description="This is a description" 'Title of the task'
        \\
    ;
};

pub fn main() void {
    var stack_space: [1024 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(&stack_space);

    var args = std.process.argsWithAllocator(arena.allocator()) catch |err| {
        log.err("Failed to get args: {s}", .{@errorName(err)});
        return;
    };

    const cli = flags.parseArgs(&args, CLIArgs);

    switch (cli) {
        .init => |init| init.execute(&arena),
        .create => |create| create.execute(&arena),
        .version => {
            var stdout = std.fs.File.stdout().writer(&.{});
            stdout.interface.print("v{s}\n", .{zon.version}) catch |err| {
                log.err("Failed to write to stdout: {s}", .{@errorName(err)});
            };
        },
    }
}
