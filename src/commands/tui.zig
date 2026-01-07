const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const root = @import("root");

const log = std.log.scoped(.tui);

const gila = @import("gila");
const stdx = @import("stdx");

const common = @import("common.zig");
const t = @import("terminal.zig");
const Terminal = t.Terminal;
const TerminalConfig = t.TerminalConfig;

const Tui = @This();

verbose: bool = false,

pub fn execute(self: Tui, io: std.Io, arena: *stdx.Arena) void {
    _ = self;
    _ = arena;

    var write_buffer: [4096]u8 align(4096) = undefined;
    var config: TerminalConfig = .tui_default;
    config.mouse.?.sgr = false;
    var terminal = Terminal.init(io, config, &write_buffer) catch |err| {
        log.err("Failed to initialize terminal: {s}", .{@errorName(err)});
        return;
    };
    defer terminal.deinit();

    terminal.setCursorVisible(false) catch {};
    defer terminal.setCursorVisible(true) catch {};

    var quit = false;
    var current_x: u16 = terminal.size.width / 2;
    var current_y: u16 = terminal.size.height / 2;
    var player_direction_x: i8 = 0;
    var player_direction_y: i8 = 0;

    while (!quit) {
        terminal.clearScreen() catch {};

        const events = terminal.pollEvents(100) catch {
            log.err("Failed to poll events", .{});
            return;
        };

        for (events) |event| {
            terminal.print("Event: {f}\n", .{event}) catch {};
            terminal.flush() catch {};
            switch (event) {
                .key_pressed => |key| {
                    switch (key.physical_key) {
                        .enter => {
                            quit = true;
                        },
                        .w, .up => player_direction_y -= 1,
                        .s, .down => player_direction_y += 1,
                        .a, .left => player_direction_x -= 1,
                        .d, .right => player_direction_x += 1,
                        else => {},
                    }
                },
                .key_released => |key| {
                    switch (key.physical_key) {
                        .w, .up => player_direction_y += 1,
                        .s, .down => player_direction_y -= 1,
                        .a, .left => player_direction_x += 1,
                        .d, .right => player_direction_x -= 1,
                        else => {},
                    }
                },
                .resize => |resize| {
                    current_x = (resize.width * current_x) / resize.old_width;
                    current_y = (resize.height * current_y) / resize.old_height;
                },
                else => {},
            }
        }

        if (player_direction_x > 0) {
            if (current_x < terminal.size.width - 1) current_x += 1 else current_x = 0;
        } else if (player_direction_x < 0) {
            if (current_x > 0) current_x -= 1 else current_x = terminal.size.width - 1;
        }

        if (player_direction_y > 0) {
            if (current_y < terminal.size.height - 1) current_y += 1 else current_y = 0;
        } else if (player_direction_y < 0) {
            if (current_y > 0) current_y -= 1 else current_y = terminal.size.height - 1;
        }

        terminal.setCursorPosition(current_x, current_y) catch {};
        terminal.write("X") catch {};

        terminal.flush() catch return;
    }
}

fn queryMode(terminal: *Terminal) void {
    terminal.write("\x1b[?1016$p") catch {};
    terminal.flush() catch {};

    var buf: [32]u8 = undefined;
    var fds = [_]std.posix.pollfd{
        .{
            .fd = terminal.stdin,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    const poll_result = std.posix.poll(&fds, 100) catch return;

    if (poll_result == 0) return;

    if (fds[0].revents & std.posix.POLL.IN == 0) return;

    const n = std.posix.read(terminal.fd, &buf) catch return;
    terminal.write("Respose: ") catch {};
    for (buf[0..n]) |c| {
        if (c == '\x1b') terminal.write("\\x1b") catch {} else terminal.print("{c}", .{c}) catch {};
    }
    terminal.write("\r\n") catch {};
    terminal.flush() catch {};
}
