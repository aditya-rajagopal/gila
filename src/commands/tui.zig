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
const e = @import("event.zig");
const Code = e.KeyEvent.Code;

const Tui = @This();

pub const FrameBuffer = struct {
    width: u16,
    height: u16,
    capacity: u32,
    data: []Cell,

    pub const Cell = struct {
        codepoint: Code,
        fg: Color,
        bg: Color,
        style_flags: Style,

        pub const Style = packed struct {
            bold: bool = false,
            italic: bool = false,
            underline: bool = false,
            blink: bool = false,
            strikethrough: bool = false,
            reverse: bool = false,
        };
    };

    pub const Color = union(enum(u8)) {
        default,
        rgb: u24,
        ansi: u8,
    };
};

pub const Scissor = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    buffer: *FrameBuffer,
};

// The palan
// 1. Have 2 buffers. Screen buffer and render buffer.
// The render buffer is where the application draws to. And you submit the render.
// The screen buffer is a reflection of what is on the screen. This is a readonly buffer for the user.
// We only render the diff between the render buffer and the screen buffer.
// The actual application is immediate mode when writing to the render buffer.
// It is given the screen buffer and a render buffer to write to.
// Should we be command based or should we do things immediately?

pub fn execute(_: Tui, ctx: common.CommandContext) void {
    const io = ctx.io;

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

    var screen_buffer: []u8 = undefined;
    var render_buffer: []u8 = undefined;

    // @INCOMPLETE This is just to avoid dealing wiht the memory allocation
    const max_cells = 640 * 480;
    const sbuffer = std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(128), max_cells) catch unreachable;
    const rbuffer = std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(128), max_cells) catch unreachable;

    screen_buffer = sbuffer[0 .. terminal.size.width * terminal.size.height];
    render_buffer = rbuffer[0 .. terminal.size.width * terminal.size.height];

    terminal.clearScreen() catch {};
    var redraw: bool = true;

    while (!quit) {
        const events = terminal.pollEvents(100) catch {
            log.err("Failed to poll events", .{});
            return;
        };

        { // Begin frame
            for (events) |event| {
                switch (event) {
                    .resize => |resize| {
                        const new_cells = resize.width * resize.height;
                        if (new_cells > max_cells) {
                            log.err("Resized to too large a size", .{});
                            return;
                        }
                        screen_buffer = sbuffer[0..new_cells];
                        render_buffer = rbuffer[0..new_cells];
                        redraw = true;
                        terminal.clearScreen() catch {};
                    },
                    else => {},
                }
            }
            @memset(render_buffer, ' ');
        }

        { // Application
            {
                for (events) |event| {
                    { // @TODO this can be from some scratch buffer that is reused before blitting to the render buffer
                        var buf: [128]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "Event: {f}", .{event}) catch unreachable;
                        @memcpy(render_buffer[0..str.len], str);
                    }
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
                            current_x = @intFromFloat(@round(stdx.divIntToFloat(f32, (resize.width - 1) * current_x, resize.old_width - 1)));
                            current_y = @intFromFloat(@round(stdx.divIntToFloat(f32, (resize.height - 1) * current_y, resize.old_height - 1)));
                        },
                        else => {},
                    }
                }
            }

            {
                {
                    var buf: [128]u8 = undefined;
                    const str = std.fmt.bufPrint(&buf, "Position: {d}, {d}[{d} x {d}]", .{ current_x, current_y, terminal.size.width, terminal.size.height }) catch unreachable;
                    terminal.setCursorPosition(0, 1) catch {};
                    terminal.write(str) catch {};
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
                render_buffer[current_y * terminal.size.width + current_x] = 'X';
            }
        }

        { // End frame?
            if (redraw) {
                for (0..terminal.size.height) |row| {
                    terminal.setCursorPosition(0, @truncate(row)) catch {};
                    terminal.write(render_buffer[row * terminal.size.width ..][0..terminal.size.width]) catch {};
                    @memcpy(screen_buffer[row * terminal.size.width ..][0..terminal.size.width], render_buffer[row * terminal.size.width ..][0..terminal.size.width]);
                }
                redraw = false;
            } else {
                @branchHint(.likely);
                for (0..terminal.size.height) |row| {
                    const row_start: u32 = @intCast(row * terminal.size.width);
                    const row_end: u32 = row_start + terminal.size.width;
                    var col: u16 = 0;
                    while (col < terminal.size.width) {
                        var start: u32 = row_start + col;
                        while (start < row_end and screen_buffer[start] == render_buffer[start]) : (start += 1) {}
                        var end: u32 = start;
                        while (end < row_end and screen_buffer[end] != render_buffer[end]) : (end += 1) {}
                        terminal.setCursorPosition(@truncate(start - row_start), @truncate(row)) catch {};
                        terminal.write(render_buffer[start..end]) catch {};
                        @memcpy(screen_buffer[start..end], render_buffer[start..end]);
                        col = @intCast(end - row_start);
                    }
                }
            }
            terminal.flush() catch {};
        }
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
