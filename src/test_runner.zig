const std = @import("std");
const builtin = @import("builtin");

pub var log_level: std.log.Level = .err;
pub const std_options: std.Options = .{
    .log_level = .err,
};

pub fn main() anyerror!void {
    var passed: u64 = 0;
    var skipped: u64 = 0;
    var failed: u64 = 0;

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.ioBasic();

    var writer = std.Io.File.stdout().writer(io, &.{});
    const stdout = &writer.interface;

    for (builtin.test_functions) |test_fn| {
        stdout.writeAll(test_fn.name) catch {};
        stdout.writeAll("... ") catch {};
        if (test_fn.func()) |_| {
            stdout.writeAll("PASS\n") catch {};
        } else |err| {
            if (err != error.SkipZigTest) {
                stdout.writeAll("FAIL\n") catch {};
                failed += 1;
                return err;
            }
            stdout.writeAll("SKIP\n") catch {};
            skipped += 1;
            continue;
        }
        passed += 1;
    }
    stdout.print("{} passed, {} skipped, {} failed\n", .{ passed, skipped, failed }) catch {};
    if (failed != 0) std.process.exit(1);
}
