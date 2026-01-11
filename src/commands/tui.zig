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

var global_tty: ?*Terminal = null;

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    if (global_tty) |tty| {
        tty.deinit();
    }
    std.debug.defaultPanic(msg, ret_addr);
}

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
    global_tty = &terminal;

    terminal.setCursorVisible(false) catch {};
    defer terminal.setCursorVisible(true) catch {};

    var quit = false;

    var screen_position: usize = 0;
    var task_start: usize = 0;
    var task_end: usize = 0;
    var lines: usize = terminal.size.height - 1;

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

    const Find = @import("find.zig");
    const find = Find{};
    const result = find.run(ctx) catch {
        log.err("Failed to run find", .{});
        return;
    };
    task_end = std.math.clamp(result.tasks.len, 0, lines);

    while (!quit) {
        const events = terminal.pollEvents(5) catch {
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
            var direction: i8 = 0;
            {
                for (events) |event| {
                    switch (event) {
                        .key_pressed, .key_repeat => |key| {
                            switch (key.physical_key) {
                                .q => quit = true,
                                .j, .down => direction = 1,
                                .k, .up => direction = -1,
                                else => {},
                            }
                        },
                        .mouse_scroll_up => {
                            direction = 1;
                        },
                        .mouse_scroll_down => {
                            direction = -1;
                        },
                        .resize => |resize| {
                            const lines_before = lines;
                            lines = resize.height - 1;
                            if (lines_before > lines) {
                                if (result.tasks.len < lines_before) {
                                    const lines_empty_before = lines_before - result.tasks.len;
                                    const lines_reduced = lines_before - lines;
                                    if (lines_empty_before > lines_reduced) {} else {
                                        task_end -= (lines_reduced - lines_empty_before);
                                    }
                                } else {
                                    if (screen_position >= lines) {
                                        task_end -= lines_before - 1 - screen_position;
                                        task_start = task_end - lines;
                                        screen_position = lines - 1;
                                    } else {
                                        task_end -= (lines_before - lines);
                                    }
                                }
                            } else {
                                if (result.tasks.len <= lines) {
                                    task_start = 0;
                                    task_end = result.tasks.len;
                                } else {
                                    const tasks_remaining = result.tasks.len - task_end;
                                    const lines_added = lines - lines_before;
                                    if (tasks_remaining < lines_added) {
                                        task_end += tasks_remaining;
                                        task_start -= lines_added - tasks_remaining;
                                        screen_position += lines_added - tasks_remaining;
                                    } else {
                                        task_end += lines_added;
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                }
            }

            {
                if (direction == -1) {
                    if (screen_position == 0) {
                        if (task_start == 0) {
                            if (result.tasks.len > lines) {
                                task_end = result.tasks.len;
                                task_start = result.tasks.len - lines;
                                screen_position = lines - 1;
                            } else {
                                screen_position = result.tasks.len;
                            }
                        } else {
                            task_start -= 1;
                            task_end -= 1;
                        }
                    } else {
                        screen_position -= 1;
                    }
                }

                if (direction == 1) {
                    if (screen_position == lines - 1) {
                        if (task_end == result.tasks.len) {
                            task_end = lines;
                            task_start = 0;
                            screen_position = 0;
                        } else {
                            task_start += 1;
                            task_end += 1;
                        }
                    } else if (screen_position == result.tasks.len) {
                        screen_position = 0;
                    } else {
                        screen_position += 1;
                    }
                }

                const search_str = "Search: ";
                @memcpy(render_buffer[0..search_str.len], search_str);
                for (result.tasks[task_start..task_end], 0..) |task, index| {
                    var buf: [128]u8 = undefined;
                    const str = std.fmt.bufPrint(&buf, "{s}{s}", .{ if (screen_position == index) ">" else " ", task.path }) catch unreachable;
                    const dest = render_buffer[(index + 1) * terminal.size.width ..][0..str.len];
                    @memcpy(dest, str);
                }
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
