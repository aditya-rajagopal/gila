const std = @import("std");
const gila = @import("gila");

pub fn main() !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("{s}", .{gila.logo});
    try stdout.flush(); // Don't forget to flush!
}
