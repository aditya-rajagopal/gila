const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const root = @import("root");

const log = std.log.scoped(.tui);

const gila = @import("gila");
const stdx = @import("stdx");

const common = @import("common.zig");
const e = @import("event.zig");
const Event = e.Event;

const Tui = @This();

verbose: bool = false,

pub const Terminal = struct {
    fd: std.Io.File.Handle,
    stdin: std.Io.File.Handle,
    original_state: std.posix.termios,
    writer: std.Io.File.Writer,
    buffer: [1024]u8,
    alt_screen: bool = false,
    size: Size,
    event_queue: [32]Event = undefined,
    mouse_enabled: ?MouseOptions = null,
    kitty_keyboard_flags: ?KittyConfig = null,

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
        try self.flush();
    }

    pub fn setCursorVisible(self: *Terminal, visible: bool) error{WriteFailed}!void {
        if (visible) {
            try self.write("\x1b[?25h");
        } else {
            try self.write("\x1b[?25l");
        }
        try self.flush();
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
        try self.flush();
        self.mouse_enabled = options;
    }

    pub fn disableMouse(self: *Terminal) void {
        if (self.mouse_enabled) |options| {
            self.write(options.level.disableString()) catch unreachable;
            if (options.sgr) {
                self.write("\x1b[?1006l") catch unreachable;
            }
            self.flush() catch unreachable;
            self.mouse_enabled = null;
        }
    }

    pub const KittyConfig = packed struct(u8) {
        disambiguate_escape_codes: bool = false,
        report_event_types: bool = false,
        report_alternate_keys: bool = false,
        report_all_keys_as_escape_codes: bool = false,
        report_associated_text: bool = false,
        _: u3 = 0,
    };

    pub fn pushKittyKeyboardFlags(self: *Terminal, config: KittyConfig) error{WriteFailed}!void {
        try self.print("\x1b[>{d}u", .{@as(u8, @bitCast(config))});
        try self.flush();
    }

    pub fn popKittyKeyboardFlags(self: *Terminal) error{WriteFailed}!void {
        try self.write("\x1b[<u");
        try self.flush();
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

        var buf: [1024]u8 = undefined;
        var write_head: usize = 0;
        reading_stdin: while (true) {
            const poll_result = std.posix.poll(&fds, timeout_ms) catch return error.PollFailed;

            if (poll_result == 0) {
                // Timeout
                return events.items;
            }

            if (fds[0].revents & std.posix.POLL.IN == 0) {
                return events.items;
            }

            const n = std.posix.read(self.fd, buf[write_head..]) catch return error.PollFailed;
            if (n == 0) break;

            // self.write("Read from stdin: { ") catch {};
            // for (buf[0..n]) |c| {
            //     if (c == '\x1b') {
            //         self.write("\\x1b, ") catch {};
            //         continue;
            //     }
            //     self.print("{c}, ", .{c}) catch return error.PollFailed;
            // }
            // self.write(" }\n") catch {};
            // self.flush() catch {};

            var data: []const u8 = buf[0..n];
            while (data.len > 0) {
                var consumed_bytes: usize = 0;
                const event = e.parseEvent(data, &consumed_bytes);
                if (consumed_bytes == 0) {
                    for (0..data.len) |i| {
                        buf[i] = data[i];
                    }
                    write_head = data.len;
                    continue :reading_stdin;
                }
                write_head = 0;
                data = data[consumed_bytes..];

                // if (consumed_bytes > 0) self.print("consumed_bytes: {d}\r\n", .{consumed_bytes}) catch {};
                self.flush() catch {};
                if (event != .none) events.appendBounded(event) catch break :reading_stdin;

                if (data.len == 0 and n != buf.len) break :reading_stdin;
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

    pub fn kittyKeyboardAvailable(self: *Terminal, timeout_ms: i32) bool {
        self.write("\x1b[?u") catch {};
        self.write("\x1b[c") catch {};
        self.flush() catch {};

        var fds = [_]std.posix.pollfd{
            .{
                .fd = self.stdin,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };

        const poll_result = std.posix.poll(&fds, timeout_ms) catch return false;
        if (poll_result == 0) return false;
        var buf: [32]u8 = undefined;
        const n = std.posix.read(self.stdin, &buf) catch return false;
        if (n != 5) return false;
        if (!std.mem.eql(u8, buf[0..3], "\x1b[?")) return false;
        if (buf[4] != 'u') return false;
        return true;
    }
};

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

    const kitty_available = terminal.kittyKeyboardAvailable(100);
    if (kitty_available) terminal.pushKittyKeyboardFlags(.{
        .disambiguate_escape_codes = true,
        // .report_event_types = true,
        // .report_all_keys_as_escape_codes = true,
        .report_alternate_keys = true,
        .report_associated_text = true,
    }) catch |err| {
        log.err("Failed to push kitty keyboard flags: {s}", .{@errorName(err)});
        return;
    };
    defer if (kitty_available) terminal.popKittyKeyboardFlags() catch {};

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
            terminal.print("{f}\n", .{event}) catch return;
            switch (event) {
                .key_pressed => |key| {
                    if (key.physical_key == .enter) {
                        quit = true;
                        break :event;
                    }
                },
                .mouse_left_pressed => |mouse| {
                    current_x = mouse.x;
                    current_y = mouse.y;
                },
                .resize => |resize| {
                    current_x = (resize.width * current_x) / resize.old_width;
                    current_y = (resize.height * current_y) / resize.old_height;
                },
                else => {},
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
