const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const root = @import("root");

const log = std.log.scoped(.tui);

const gila = @import("gila");
const stdx = @import("stdx");

const common = @import("common.zig");

const Tui = @This();

verbose: bool = false,

pub const Event = union(enum) {
    key: KeyEvent,
    resize: ResizeEvent,
    mouse: MouseEvent,
    none,

    pub const ResizeEvent = struct {
        old_width: u16,
        old_height: u16,
        width: u16,
        height: u16,
    };

    pub const MouseEvent = union(enum(u8)) {
        move: Info,
        drag_left: Info,
        drag_middle: Info,
        drag_right: Info,
        scroll_up: Info,
        scroll_down: Info,
        left_pressed: Info,
        middle_pressed: Info,
        right_pressed: Info,
        left_released: Info,
        middle_released: Info,
        right_released: Info,

        pub const Info = struct {
            modifiers: Mods,
            x: u16,
            y: u16,
        };

        pub const Button = enum(u8) {
            left = 0,
            middle = 1,
            right = 2,
            move = 3,
        };

        const shift_bit = 4;
        const alt_bit = 8;
        const ctrl_bit = 16;
        const move_mask = 32;
        const mouse_scroll_mask = 64;

        pub fn parse(data: []const u8) error{Invalid}!MouseEvent {
            assert(data[0] == '\x1b');
            assert(data[1] == '[');

            const m = std.mem.findAnyPos(u8, data, 3, "mM") orelse return error.Invalid;

            const mouse_event_type, const coordinates = cutScalar(u8, data[3..m], ';') orelse return error.Invalid;
            const string_x, const string_y = cutScalar(u8, coordinates, ';') orelse return error.Invalid;
            const x = std.fmt.parseInt(u16, string_x, 10) catch return error.Invalid;
            const y = std.fmt.parseInt(u16, string_y, 10) catch return error.Invalid;

            const number = std.fmt.parseInt(u8, mouse_event_type, 10) catch return error.Invalid;
            const button: Button = @enumFromInt(number & 0b11);
            const ctrl: bool = (number & ctrl_bit) != 0;
            const alt: bool = (number & alt_bit) != 0;
            const shift: bool = (number & shift_bit) != 0;
            const mouse_scroll = (number & mouse_scroll_mask) == mouse_scroll_mask;
            const mouse_move = (number & move_mask) == move_mask;

            if (mouse_move and mouse_scroll) return error.Invalid;

            const info: Info = .{
                .modifiers = .{ .ctrl = ctrl, .alt = alt, .shift = shift },
                .x = x,
                .y = y,
            };

            if (mouse_scroll) switch (button) {
                .left => return .{ .scroll_up = info },
                .middle => return .{ .scroll_down = info },
                else => return error.Invalid,
            } else if (mouse_move) switch (button) {
                .left => return .{ .drag_left = info },
                .middle => return .{ .drag_middle = info },
                .right => return .{ .drag_right = info },
                .move => return .{ .move = info },
            } else switch (button) {
                .left => if (data[m] == 'm') return .{ .left_released = info } else return .{ .left_pressed = info },
                .middle => if (data[m] == 'm') return .{ .middle_released = info } else return .{ .middle_pressed = info },
                .right => if (data[m] == 'm') return .{ .right_released = info } else return .{ .right_pressed = info },
                else => return error.Invalid,
            }
            unreachable;
        }

        pub fn format(self: MouseEvent, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (self) {
                .move => |info| try writer.print("{f}mouse_move@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
                .drag_left => |info| try writer.print("{f}mouse_drag+left_button@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
                .drag_middle => |info| try writer.print("{f}mouse_drag+middle_button@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
                .drag_right => |info| try writer.print("{f}mouse_drag+right_button@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
                .scroll_up => |info| try writer.print("{f}mouse_scroll_up@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
                .scroll_down => |info| try writer.print("{f}mouse_scroll_down@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
                .left_pressed => |info| try writer.print("{f}mouse_left_button_pressed@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
                .middle_pressed => |info| try writer.print("{f}mouse_middle_button_pressed@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
                .right_pressed => |info| try writer.print("{f}mouse_right_button_pressed@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
                .left_released => |info| try writer.print("{f}mouse_left_button_released@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
                .middle_released => |info| try writer.print("{f}mouse_middle_button_released@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
                .right_released => |info| try writer.print("{f}mouse_right_button_released@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
            }
        }
    };

    const Mods = packed struct(u8) {
        shift: bool = false,
        ctrl: bool = false,
        alt: bool = false,
        meta: bool = false,
        super: bool = false,
        hyper: bool = false,
        _: u2 = 0,

        pub fn format(self: Mods, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            if (self.shift) try writer.writeAll("shift+");
            if (self.ctrl) try writer.writeAll("ctrl+");
            if (self.alt) try writer.writeAll("alt+");
            if (self.meta) try writer.writeAll("meta+");
            if (self.super) try writer.writeAll("super+");
            if (self.hyper) try writer.writeAll("hyper+");
        }
    };

    pub const KeyEvent = struct {
        code: Code,
        physical_key: Code,
        mods: Mods,

        pub fn format(self: KeyEvent, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("{f}", .{self.mods});
            switch (self.code) {
                .tab => try writer.writeAll("tab"),
                .enter => try writer.writeAll("enter"),
                .backspace => try writer.writeAll("backspace"),
                .escape => try writer.writeAll("escape"),
                .space => try writer.writeAll("space"),
                else => |value| {
                    const c: u21 = @intFromEnum(value);
                    switch (c) {
                        32...126 => |code| {
                            try writer.writeByte(@truncate(code));
                        },
                        else => |code| try writer.print("{d}", .{code}),
                    }
                },
            }
        }

        pub fn parseAscii(c: u8) KeyEvent {
            // @TODO [[infamous_goose_483]]
            switch (c) {
                9 => return .{ .code = .tab, .mods = .{}, .physical_key = .tab },
                127 => return .{ .code = .backspace, .mods = .{}, .physical_key = .backspace },
                27 => return .{ .code = .escape, .mods = .{}, .physical_key = .escape },
                1...8, 11, 12, 14...26 => |ctrl| {
                    return .{ .code = @enumFromInt(ctrl - 1 + 'a'), .mods = .{ .ctrl = true }, .physical_key = @enumFromInt(ctrl - 1 + 'a') };
                },
                10 => return .{ .code = @enumFromInt('j'), .mods = .{ .ctrl = true }, .physical_key = @enumFromInt('j') },
                13 => return .{ .code = .enter, .mods = .{}, .physical_key = .enter },
                0 => return .{ .code = @enumFromInt('@'), .mods = .{ .ctrl = true }, .physical_key = @enumFromInt('@') },
                'a'...'z' => {
                    return .{ .code = @enumFromInt(c), .mods = .{}, .physical_key = @enumFromInt(c - 'a' + 'A') };
                },
                'A'...'Z' => {
                    return .{ .code = @enumFromInt(c), .mods = .{ .shift = true }, .physical_key = @enumFromInt(c) };
                },
                else => return .{ .code = @enumFromInt(c), .mods = .{}, .physical_key = @enumFromInt(c) },
            }
        }

        pub const Code = enum(u21) {
            tab = 0x09,
            enter = 0x0d,
            backspace = 0x7f,
            escape = 0x1b,
            space = 0x20,
            _,
        };
    };
};

pub const Terminal = struct {
    fd: std.Io.File.Handle,
    stdin: std.Io.File.Handle,
    original_state: std.posix.termios,
    writer: std.Io.File.Writer,
    buffer: [1024]u8,
    alt_screen: bool = false,
    size: Size,
    event_queue: [4]Event = undefined,
    mouse_enabled: ?MouseOptions = null,

    pub const Size = struct { width: u16, height: u16 };

    pub fn init(io: std.Io) error{Failed}!Terminal {
        var terminal: Terminal = undefined;
        terminal.fd = std.posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch return error.Failed;
        terminal.stdin = std.Io.File.stdin().handle;
        terminal.original_state = std.posix.tcgetattr(terminal.fd) catch return error.Failed;
        terminal.writer = std.Io.File.Writer.initStreaming(std.Io.File{ .handle = terminal.fd }, io, &terminal.buffer);
        terminal.alt_screen = false;
        terminal.size = terminal.getSize();
        terminal.mouse_enabled = null;
        @memset(&terminal.event_queue, .none);

        return terminal;
    }

    pub fn makeRaw(self: *Terminal) error{Failed}!void {
        var raw = self.original_state;
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;

        raw.oflag.OPOST = false;

        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;

        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        std.posix.tcsetattr(self.fd, .FLUSH, raw) catch {
            return error.Failed;
        };
    }

    pub fn unmakeRaw(self: *Terminal) void {
        std.posix.tcsetattr(self.fd, .FLUSH, self.original_state) catch {};
    }

    pub fn write(self: *Terminal, bytes: []const u8) error{WriteFailed}!void {
        self.writer.interface.writeAll(bytes) catch return error.WriteFailed;
    }

    pub fn print(self: *Terminal, comptime fmt: []const u8, args: anytype) error{WriteFailed}!void {
        self.writer.interface.print(fmt, args) catch return error.WriteFailed;
    }

    pub fn setAlternateScreen(self: *Terminal) error{WriteFailed}!void {
        if (self.alt_screen) return;
        try self.write("\x1b[?1049h");
        try self.write("\x1b[2J");
        try self.write("\x1b[H");
        try self.flush();
        self.alt_screen = true;
    }

    pub fn unsetAlternateScreen(self: *Terminal) void {
        if (!self.alt_screen) return;
        self.write("\x1b[?1049l") catch {};
        self.flush() catch {};
        self.alt_screen = false;
    }

    pub fn flush(self: *Terminal) error{WriteFailed}!void {
        self.writer.interface.flush() catch return error.WriteFailed;
    }

    pub fn clearScreen(self: *Terminal) error{WriteFailed}!void {
        self.write("\x1b[2J\x1b[H") catch return error.WriteFailed;
    }

    pub fn getSize(self: *const Terminal) Size {
        var size: std.posix.winsize = undefined;
        const r = std.posix.system.ioctl(self.fd, std.posix.T.IOCGWINSZ, @intFromPtr(&size));
        if (r != 0) {
            return .{ .width = 80, .height = 24 };
        }
        if (size.col == 0 or size.row == 0) {
            return .{ .width = 80, .height = 24 };
        }
        return .{ .width = size.col, .height = size.row };
    }

    pub fn setCursorPosition(self: *Terminal, x: u16, y: u16) error{WriteFailed}!void {
        try self.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
    }

    pub fn setCursorVisible(self: *Terminal, visible: bool) error{WriteFailed}!void {
        if (visible) {
            try self.write("\x1b[?25h");
        } else {
            try self.write("\x1b[?25l");
        }
    }

    pub fn getCursorPosition(self: *const Terminal) struct { x: u16, y: u16 } {
        var buf: [32]u8 = undefined;
        const n = std.posix.write(self.fd, "\x1b[6n") catch return .{ .x = 0, .y = 0 };
        if (n != 4) return .{ .x = 0, .y = 0 };
        const n2 = std.posix.read(self.fd, &buf) catch return .{ .x = 0, .y = 0 };
        if (n2 < 6) return .{ .x = 0, .y = 0 };
        assert(buf[0] == '\x1b');
        assert(buf[1] == '[');
        const seperator = std.mem.findScalar(u8, buf[0..n2], ';') orelse return .{ .x = 0, .y = 0 };
        return .{
            .x = std.fmt.parseInt(u16, buf[2..seperator], 10) catch return .{ .x = 0, .y = 0 },
            .y = std.fmt.parseInt(u16, buf[seperator + 1 .. n2 - 1], 10) catch return .{ .x = 0, .y = 0 },
        };
    }

    pub const MouseOptions = struct {
        /// Enable SGR(Select Graphic Rendition) mouse tracking mode.
        /// Extension to traditional x10 mouse protocol that allows more infomration about which specific button is released,
        /// and allows terminal sizes more than 222.
        /// It is **RECOMMENDED** to enable this unless the target terminal does not support the xterm standard
        sgr: bool = true,
        /// The level of reporting mouse events
        level: Level,

        pub const default: MouseOptions = .{
            .sgr = true,
            .level = .all_motion,
        };

        pub const Level = enum {
            /// Terminal reports mouse coordinates when
            /// - a mouse button is pressed or released
            /// - the mouse scrolls up or down
            presses_only,
            /// Terminal reports mouse coordinates when
            /// - a mouse button is pressed or released
            /// - the mouse scrolls up or down
            /// - when the mouse moves to a new cell position **AND** a mouse button is held down
            cell_motion,
            /// Terminal reports mouse coordinates
            /// - when a mouse button is pressed or released
            /// - when the mouse moves to a new cell position
            /// - when the mouse scrolls up or down
            all_motion,

            pub fn enableString(self: Level) []const u8 {
                return switch (self) {
                    .presses_only => "\x1b[?1000h",
                    .cell_motion => "\x1b[?1002h",
                    .all_motion => "\x1b[?1003h",
                };
            }

            pub fn disableString(self: Level) []const u8 {
                return switch (self) {
                    .presses_only => "\x1b[?1000l",
                    .cell_motion => "\x1b[?1002l",
                    .all_motion => "\x1b[?1003l",
                };
            }
        };
    };

    pub fn enableMouse(self: *Terminal, options: MouseOptions) error{WriteFailed}!void {
        try self.write(options.level.enableString());
        errdefer self.write(options.level.disableString()) catch {};
        if (options.sgr) {
            try self.write("\x1b[?1006h");
        }
        self.mouse_enabled = options;
    }

    pub fn disableMouse(self: *Terminal) void {
        if (self.mouse_enabled) |options| {
            self.write(options.level.disableString()) catch unreachable;
            if (options.sgr) {
                self.write("\x1b[?1006l") catch unreachable;
            }
            self.mouse_enabled = null;
        }
    }

    pub fn moveCursorLines(self: *Terminal, dx: i16, dy: i16) error{WriteFailed}!void {
        if (dx == 0 and dy == 0) return;
        if (dx > 0) try self.write("\x1b[{d}C", .{dx}) else try self.write("\x1b[{d}D", .{-dx});
        if (dy > 0) try self.write("\x1b[{d}B", .{dy}) else try self.write("\x1b[{d}A", .{-dy});
    }

    pub fn pollEvents(self: *Terminal, timeout_ms: i32) error{PollFailed}![]Event {
        var events = std.ArrayList(Event).initBuffer(&self.event_queue);

        const size = self.getSize();
        if (size.width != self.size.width or size.height != self.size.height) {
            events.appendAssumeCapacity(.{ .resize = .{
                .old_width = self.size.width,
                .old_height = self.size.height,
                .width = size.width,
                .height = size.height,
            } });
            self.size = size;
        }

        var fds = [_]std.posix.pollfd{
            .{
                .fd = self.stdin,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };

        const poll_result = std.posix.poll(&fds, timeout_ms) catch return error.PollFailed;

        if (poll_result == 0) {
            // Timeout
            return events.items;
        }

        if (fds[0].revents & std.posix.POLL.IN == 0) {
            return events.items;
        }

        var buf: [32]u8 = undefined;
        const n = std.posix.read(self.fd, &buf) catch return error.PollFailed;

        // @TODO [[minty_core_jw2]]
        if (n == 0) {
            return events.items;
        }

        if (n == 1) {
            events.appendAssumeCapacity(.{ .key = Event.KeyEvent.parseAscii(buf[0]) });
        } else if (buf[0] == 27) {
            if (n == 2) {
                var key_event = Event.KeyEvent.parseAscii(buf[1]);
                key_event.mods.alt = true;
                events.appendAssumeCapacity(.{ .key = key_event });
            }
            if (n > 3) blk: {
                if (self.tryParseMouseEvent(buf[0..n], &events) catch return events.items) break :blk;
            }
        }

        return events.items;
    }

    fn tryParseMouseEvent(self: *Terminal, data: []const u8, events: *std.ArrayList(Event)) error{Invalid}!bool {
        if (self.mouse_enabled) |options| {
            if (options.sgr) {
                if (data[1] != '[') return false;
                if (data[2] != '<') return false;
                events.appendAssumeCapacity(.{ .mouse = Event.MouseEvent.parse(data) catch return error.Invalid });
                return true;
            } else {
                assert(false and "TODO: Implement mouse events without SGR");
            }
        }
        return false;
    }
};

pub fn cut(comptime T: type, haystack: []const T, needle: []const T) ?struct { []const T, []const T } {
    const index = std.mem.find(T, haystack, needle) orelse return null;
    return .{ haystack[0..index], haystack[index + needle.len ..] };
}

pub fn cutScalar(comptime T: type, haystack: []const T, needle: T) ?struct { []const T, []const T } {
    const index = std.mem.findScalar(T, haystack, needle) orelse return null;
    return .{ haystack[0..index], haystack[index + 1 ..] };
}

pub fn execute(self: Tui, io: std.Io, arena: *stdx.Arena) void {
    _ = self;
    _ = arena;

    var terminal = Terminal.init(io) catch |err| {
        log.err("Failed to initialize terminal: {s}", .{@errorName(err)});
        return;
    };

    terminal.makeRaw() catch |err| {
        log.err("Failed to set terminal to raw: {s}", .{@errorName(err)});
        return;
    };
    defer terminal.unmakeRaw();

    terminal.setAlternateScreen() catch |err| {
        log.err("Failed to set terminal to alternate screen: {s}", .{@errorName(err)});
        return;
    };
    defer terminal.unsetAlternateScreen();

    terminal.enableMouse(.default) catch |err| {
        log.err("Failed to enable mouse: {s}", .{@errorName(err)});
        return;
    };
    defer terminal.disableMouse();

    var i: usize = 0;
    var quit = false;
    var current_x: u16 = terminal.size.width / 3;
    var current_y: u16 = terminal.size.height / 2;

    event: while (!quit) {
        terminal.clearScreen() catch {};
        const events = terminal.pollEvents(100) catch {
            log.err("Failed to poll events", .{});
            return;
        };
        i += 1;
        terminal.setCursorPosition(current_x, current_y) catch {};
        terminal.print("Events : {any}\n", .{events}) catch return;

        const cursor = terminal.getCursorPosition();
        terminal.setCursorPosition(current_x, current_y + 1) catch {};
        terminal.print("Cursor position: {d}x{d}\n", .{ cursor.x, cursor.y }) catch return;
        terminal.setCursorPosition(current_x, current_y + 2) catch {};
        terminal.print("Window size: {d}x{d}\n", .{ terminal.size.width, terminal.size.height }) catch return;
        terminal.setCursorPosition(current_x, current_y + 3) catch {};
        terminal.print("Hello World! : {d}\n", .{i}) catch return;

        for (events, 0..) |event, index| {
            terminal.setCursorPosition(current_x, current_y + 4 + @as(u16, @truncate(index))) catch {};
            switch (event) {
                .key => |key| {
                    terminal.print("{f}\n", .{key}) catch return;
                    if (key.physical_key == @as(Event.KeyEvent.Code, @enumFromInt('Q'))) {
                        quit = true;
                        break :event;
                    }
                },
                .mouse => |mouse| {
                    terminal.print("{f}\n", .{mouse}) catch return;
                    if (mouse == .left_pressed) {
                        current_x = mouse.left_pressed.x;
                        current_y = mouse.left_pressed.y;
                    }
                },
                .resize => |resize| {
                    terminal.print("Starting at {d}x{d}", .{ current_x, current_y }) catch return;
                    current_x = (resize.width * current_x) / resize.old_width;
                    current_y = (resize.height * current_y) / resize.old_height;
                    terminal.print("Ending at {d}x{d}\n", .{ current_x, current_y }) catch return;
                },
                else => unreachable,
            }
        }

        terminal.flush() catch return;
    }
}

pub fn divIntToFloat(comptime Float: type, numerator: anytype, denominator: anytype) Float {
    const NType = @TypeOf(numerator);
    const DType = @TypeOf(denominator);
    comptime assert(@typeInfo(NType) == .int or @typeInfo(NType) == .float);
    comptime assert(@typeInfo(DType) == .int or @typeInfo(DType) == .float);
    comptime assert(@typeInfo(Float) == .float);
    const n: Float = if (comptime @typeInfo(NType) == .int) @floatFromInt(numerator) else @floatCast(numerator);
    const d: Float = if (comptime @typeInfo(DType) == .int) @floatFromInt(denominator) else @floatCast(denominator);
    return n / d;
}
