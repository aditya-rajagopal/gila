const std = @import("std");
const assert = std.debug.assert;

pub fn parseEvent(data: []const u8, consumed_bytes: *usize) Event {
    assert(data.len > 0);
    consumed_bytes.* = 0;

    if (data.len == 1) {
        consumed_bytes.* = 1;
        return .{ .key_pressed = Event.KeyEvent.parseAscii(data[0]) };
    }

    if (data[0] == '\x1b') switch (data[1]) {
        0x4f => return parseSs3(data, consumed_bytes),
        0x5b => return parseCsi(data, consumed_bytes),
        else => {
            var key_event = Event.KeyEvent.parseAscii(data[1]);
            key_event.mods.alt = true;
            consumed_bytes.* = 2;
            return .{ .key_pressed = key_event };
        },
    };
    return .none;
}

pub fn parseSs3(data: []const u8, consumed_bytes: *usize) Event {
    if (data.len < 3) return .none;
    assert(data[0] == '\x1b');
    assert(data[1] == 'O');

    const event: Event = switch (data[2]) {
        // TODO deal with multiple escape sequences
        0x1b => {
            consumed_bytes.* = 2;
            return .none;
        },
        'A' => .{ .key_pressed = .{ .code = .up, .physical_key = .up, .mods = .{} } },
        'B' => .{ .key_pressed = .{ .code = .down, .physical_key = .down, .mods = .{} } },
        'C' => .{ .key_pressed = .{ .code = .right, .physical_key = .right, .mods = .{} } },
        'D' => .{ .key_pressed = .{ .code = .left, .physical_key = .left, .mods = .{} } },
        'E' => .{ .key_pressed = .{ .code = .kp_begin, .physical_key = .kp_begin, .mods = .{} } },
        'F' => .{ .key_pressed = .{ .code = .end, .physical_key = .end, .mods = .{} } },
        'H' => .{ .key_pressed = .{ .code = .home, .physical_key = .home, .mods = .{} } },
        'P' => .{ .key_pressed = .{ .code = .f1, .physical_key = .f1, .mods = .{} } },
        'Q' => .{ .key_pressed = .{ .code = .f2, .physical_key = .f2, .mods = .{} } },
        'R' => .{ .key_pressed = .{ .code = .f3, .physical_key = .f3, .mods = .{} } },
        'S' => .{ .key_pressed = .{ .code = .f4, .physical_key = .f4, .mods = .{} } },
        else => {
            consumed_bytes.* = 2;
            return .none;
        },
    };
    consumed_bytes.* = 3;
    return event;
}

pub fn parseCsi(data: []const u8, consumed_bytes: *usize) Event {
    if (data.len < 3) return .none;
    assert(data[0] == '\x1b');
    assert(data[1] == '[');

    // @NOTE a CSI sequence terminates when a character greater than 0x40 is encountered.
    // This is to deal with the case we have multiple escape sequences in a row.
    const n = for (2..data.len) |i| {
        if (data[i] >= 0x40) break i + 1;
    } else return .none;

    const csi = data[0..n];
    consumed_bytes.* = n;
    return switch (csi[n - 1]) {
        'M', 'm' => Event.MouseEvent.parse(csi, data, consumed_bytes),
        'A', 'B', 'C', 'D', 'E', 'F', 'H', 'P', 'Q', 'S' => {
            // @NOTE There are two types of events that end in these letters https://sw.kovidgoyal.net/kitty/keyboard-protocol/#legacy-key-event-encoding
            //     CSI {A,B,C,D,E,F,H,P,Q,S} (legacy)
            //     CSI 1; modifier:type {A,B,C,D,E,F,H,P,Q,S}

            const payload = csi[2 .. n - 1];
            var key_event: Event.KeyEvent = undefined;
            key_event.code, key_event.physical_key = switch (csi[n - 1]) {
                'A' => .{ Event.KeyEvent.Code.up, Event.KeyEvent.Code.up },
                'B' => .{ Event.KeyEvent.Code.down, Event.KeyEvent.Code.down },
                'C' => .{ Event.KeyEvent.Code.right, Event.KeyEvent.Code.right },
                'D' => .{ Event.KeyEvent.Code.left, Event.KeyEvent.Code.left },
                'E' => .{ Event.KeyEvent.Code.kp_begin, Event.KeyEvent.Code.kp_begin },
                'F' => .{ Event.KeyEvent.Code.end, Event.KeyEvent.Code.end },
                'H' => .{ Event.KeyEvent.Code.home, Event.KeyEvent.Code.home },
                'P' => .{ Event.KeyEvent.Code.f1, Event.KeyEvent.Code.f1 },
                'Q' => .{ Event.KeyEvent.Code.f2, Event.KeyEvent.Code.f2 },
                'S' => .{ Event.KeyEvent.Code.f4, Event.KeyEvent.Code.f4 },
                else => unreachable,
            };
            key_event.mods = .{};
            if (payload.len == 0) return .{ .key_pressed = key_event };

            const left, const right = cutScalar(u8, payload, ';') orelse return .none;
            if (left.len != 1 or (left.len == 1 and left[0] != '1')) return .none;

            const modifier, const event_type = if (cutScalar(u8, right, ':')) |result| result else .{ right, &.{} };
            const mod_value = parseValue(u8, modifier, 1) orelse return .none;
            key_event.mods = @bitCast(mod_value -| 1);
            const key_state: KeyEventType = @enumFromInt(parseValue(u8, event_type, 1) orelse return .none);
            return switch (key_state) {
                .pressed => .{ .key_pressed = key_event },
                .repeat => .{ .key_repeat = key_event },
                .released => .{ .key_released = key_event },
            };
        },
        '~' => {
            // @NOTE There are three types of events that end in ~
            //     CSI number ~
            //     CSI number; modifier:type ~
            //     CSI number; modifier:type; text_as_codepoint ~
            // see: https://sw.kovidgoyal.net/kitty/keyboard-protocol/#an-overview
            const payload = csi[2 .. n - 1];
            const string_number, const remaining = if (cutScalar(u8, payload, ';')) |result| result else .{ payload, &.{} };
            const number = parseValue(u16, string_number, null) orelse return .none;

            var key_event: Event.KeyEvent = undefined;
            key_event.code, key_event.physical_key = switch (number) {
                2 => .{ Event.KeyEvent.Code.insert, Event.KeyEvent.Code.insert },
                3 => .{ Event.KeyEvent.Code.delete, Event.KeyEvent.Code.delete },
                5 => .{ Event.KeyEvent.Code.page_up, Event.KeyEvent.Code.page_up },
                6 => .{ Event.KeyEvent.Code.page_down, Event.KeyEvent.Code.page_down },
                7 => .{ Event.KeyEvent.Code.home, Event.KeyEvent.Code.home },
                8 => .{ Event.KeyEvent.Code.end, Event.KeyEvent.Code.end },
                11 => .{ Event.KeyEvent.Code.f1, Event.KeyEvent.Code.f1 },
                12 => .{ Event.KeyEvent.Code.f2, Event.KeyEvent.Code.f2 },
                13 => .{ Event.KeyEvent.Code.f3, Event.KeyEvent.Code.f3 },
                14 => .{ Event.KeyEvent.Code.f4, Event.KeyEvent.Code.f4 },
                15 => .{ Event.KeyEvent.Code.f5, Event.KeyEvent.Code.f5 },
                17 => .{ Event.KeyEvent.Code.f6, Event.KeyEvent.Code.f6 },
                18 => .{ Event.KeyEvent.Code.f7, Event.KeyEvent.Code.f7 },
                19 => .{ Event.KeyEvent.Code.f8, Event.KeyEvent.Code.f8 },
                20 => .{ Event.KeyEvent.Code.f9, Event.KeyEvent.Code.f9 },
                21 => .{ Event.KeyEvent.Code.f10, Event.KeyEvent.Code.f10 },
                23 => .{ Event.KeyEvent.Code.f11, Event.KeyEvent.Code.f11 },
                24 => .{ Event.KeyEvent.Code.f12, Event.KeyEvent.Code.f12 },
                29 => .{ Event.KeyEvent.Code.menu, Event.KeyEvent.Code.menu },
                57427 => .{ Event.KeyEvent.Code.kp_begin, Event.KeyEvent.Code.kp_begin },
                200 => return .none, // @TODO GILA(loyal_azure_qss)
                201 => return .none, // @TODO GILA(loyal_azure_qss)
                else => return .none,
            };
            key_event.mods = .{};
            if (remaining.len == 0) return .{ .key_pressed = key_event };

            const modifier_event_type, const text_as_codepoint = if (cutScalar(u8, remaining, ';')) |result| result else .{ remaining, &.{} };
            const modifier_string, const event_type = if (cutScalar(u8, modifier_event_type, ':')) |result| result else .{ modifier_event_type, &.{} };
            const modifier = parseValue(u8, modifier_string, 1) orelse return .none;
            key_event.mods = @bitCast(modifier -| 1);
            const key_state: KeyEventType = @enumFromInt(parseValue(u8, event_type, 1) orelse return .none);

            // @TODO GILA(fluffy_tail_yw4)
            _ = text_as_codepoint;
            return switch (key_state) {
                .pressed => .{ .key_pressed = key_event },
                .repeat => .{ .key_repeat = key_event },
                .released => .{ .key_released = key_event },
            };
        },

        'c' => .none, // @TODO GILA(indelible_magma_xhr)
        'n' => .none, // @TODO GILA(odd_flux_g9x)
        't' => .none, // @TODO GILA(wry_ray_32j)
        'y' => .none, // @TODO GILA(emotional_hash_6hm)
        'q' => .none, // @TODO GILA(rough_fang_bxy)
        'u' => {
            // @NOTE https://sw.kovidgoyal.net/kitty/keyboard-protocol/#an-overview
            //     CSI unicode-key-code:alternate-key-codes ; modifiers:event-type ; text-as-codepoints u
            // Only the unicode-key-code field is mandatory, everything else is optional.
            const payload = csi[2 .. n - 1];
            if (payload.len == 0) return .none;

            const first, const remaining = if (cutScalar(u8, payload, ';')) |result| result else .{ payload, &.{} };
            const key_code, const alt_key_code = if (cutScalar(u8, first, ':')) |result| result else .{ first, &.{} };

            var key_event: Event.KeyEvent = undefined;
            const code = parseValue(u21, key_code, null) orelse return .none;
            key_event.code = @enumFromInt(code);
            key_event.physical_key = key_event.code.mapUsLayout().physical_key;

            key_event.mods = .{};
            // @TODO GILA(fluffy_tail_yw4)
            _ = alt_key_code;
            if (remaining.len == 0) return .{ .key_pressed = key_event };

            const modifier_event_type, const text_as_codepoint = if (cutScalar(u8, remaining, ';')) |result| result else .{ remaining, &.{} };
            const modifier_string, const event_type = if (cutScalar(u8, modifier_event_type, ':')) |result| result else .{ modifier_event_type, &.{} };
            const modifier = parseValue(u8, modifier_string, 1) orelse return .none;
            key_event.mods = @bitCast(modifier -| 1);
            const key_state: KeyEventType = @enumFromInt(parseValue(u8, event_type, 1) orelse return .none);

            // @TODO GILA(fluffy_tail_yw4)
            _ = text_as_codepoint;

            return switch (key_state) {
                .pressed => .{ .key_pressed = key_event },
                .repeat => .{ .key_repeat = key_event },
                .released => .{ .key_released = key_event },
            };
        },
        else => .none,
    };
}

fn parseValue(comptime T: type, data: []const u8, default_value: ?T) ?T {
    if (data.len == 0) return default_value;
    return std.fmt.parseInt(T, data, 10) catch return null;
}

pub const KeyEventType = enum(u8) {
    pressed = 1,
    repeat = 2,
    released = 3,
};

pub const Event = union(enum(u8)) {
    key_pressed: KeyEvent,
    key_released: KeyEvent,
    key_repeat: KeyEvent,
    resize: ResizeEvent,
    mouse_move: MouseEvent,
    mouse_drag_left: MouseEvent,
    mouse_drag_middle: MouseEvent,
    mouse_drag_right: MouseEvent,
    mouse_scroll_up: MouseEvent,
    mouse_scroll_down: MouseEvent,
    mouse_left_pressed: MouseEvent,
    mouse_middle_pressed: MouseEvent,
    mouse_right_pressed: MouseEvent,
    mouse_left_released: MouseEvent,
    mouse_middle_released: MouseEvent,
    mouse_right_released: MouseEvent,
    none,

    pub fn format(self: Event, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .key_pressed => |key| try writer.print("key_pressed:{f}", .{key}),
            .key_released => |key| try writer.print("key_released:{f}", .{key}),
            .key_repeat => |key| try writer.print("key_repeat:{f}", .{key}),
            .resize => |resize| try writer.print("resize:{f}", .{resize}),
            .mouse_move => |info| try writer.print("{f}mouse_move@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
            .mouse_drag_left => |info| try writer.print("{f}mouse_drag+left_button@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
            .mouse_drag_middle => |info| try writer.print("{f}mouse_drag+middle_button@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
            .mouse_drag_right => |info| try writer.print("{f}mouse_drag+right_button@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
            .mouse_scroll_up => |info| try writer.print("{f}mouse_scroll_up@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
            .mouse_scroll_down => |info| try writer.print("{f}mouse_scroll_down@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
            .mouse_left_pressed => |info| try writer.print("{f}mouse_left_button_pressed@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
            .mouse_middle_pressed => |info| try writer.print("{f}mouse_middle_button_pressed@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
            .mouse_right_pressed => |info| try writer.print("{f}mouse_right_button_pressed@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
            .mouse_left_released => |info| try writer.print("{f}mouse_left_button_released@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
            .mouse_middle_released => |info| try writer.print("{f}mouse_middle_button_released@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
            .mouse_right_released => |info| try writer.print("{f}mouse_right_button_released@[{d}x{d}]", .{ info.modifiers, info.x, info.y }),
            .none => try writer.writeAll("none"),
        }
    }

    pub const ResizeEvent = struct {
        old_width: u16,
        old_height: u16,
        width: u16,
        height: u16,

        pub fn format(self: ResizeEvent, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("[{d}x{d}] -> [{d}x{d}]", .{ self.old_width, self.old_height, self.width, self.height });
        }
    };

    pub const MouseEvent = struct {
        modifiers: Mods,
        x: u16,
        y: u16,

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

        pub fn parse(csi: []const u8, data: []const u8, consumed_bytes: *usize) Event {
            assert(csi[0] == '\x1b');
            assert(csi[1] == '[');
            const m = csi.len - 1;
            assert(csi[m] == 'M' or csi[m] == 'm');

            const number, const x, const y = if (csi.len == 3 and csi[2] == 'M') blk: {
                // @NOTE SGR off
                const number: u16 = data[3] - 32;
                const x: u16 = data[4] - 32;
                const y: u16 = data[5] - 32;
                consumed_bytes.* = 6;
                break :blk .{ number, x, y };
            } else if (csi.len >= 4 and csi[2] == '<') blk: {
                // @NOTE SGR
                const mouse_event_type, const coordinates = cutScalar(u8, csi[3..m], ';') orelse return .none;
                const string_x, const string_y = cutScalar(u8, coordinates, ';') orelse return .none;
                const x = parseValue(u16, string_x, 1) orelse return .none;
                const y = parseValue(u16, string_y, 1) orelse return .none;
                const number = parseValue(u16, mouse_event_type, null) orelse return .none;
                consumed_bytes.* = csi.len;
                break :blk .{ number, x, y };
            } else return .none;

            const button: Button = @enumFromInt(number & 0b11);
            const ctrl: bool = (number & ctrl_bit) != 0;
            const alt: bool = (number & alt_bit) != 0;
            const shift: bool = (number & shift_bit) != 0;
            const mouse_scroll = (number & mouse_scroll_mask) == mouse_scroll_mask;
            const mouse_move = (number & move_mask) == move_mask;

            if (mouse_move and mouse_scroll) return .none;

            const info: MouseEvent = .{
                .modifiers = .{ .ctrl = ctrl, .alt = alt, .shift = shift },
                .x = x,
                .y = y,
            };

            if (mouse_scroll) switch (button) {
                .left => return .{ .mouse_scroll_up = info },
                .middle => return .{ .mouse_scroll_down = info },
                else => return .none,
            } else if (mouse_move) switch (button) {
                .left => return .{ .mouse_drag_left = info },
                .middle => return .{ .mouse_drag_middle = info },
                .right => return .{ .mouse_drag_right = info },
                .move => return .{ .mouse_move = info },
            } else switch (button) {
                .left => if (csi[m] == 'm') return .{ .mouse_left_released = info } else return .{ .mouse_left_pressed = info },
                .middle => if (csi[m] == 'm') return .{ .mouse_middle_released = info } else return .{ .mouse_middle_pressed = info },
                .right => if (csi[m] == 'm') return .{ .mouse_right_released = info } else return .{ .mouse_right_pressed = info },
                else => return .none,
            }
            unreachable;
        }
    };

    const Mods = packed struct(u8) {
        shift: bool = false,
        alt: bool = false,
        ctrl: bool = false,
        super: bool = false,
        hyper: bool = false,
        meta: bool = false,
        caps_lock: bool = false,
        num_lock: bool = false,

        pub fn format(self: Mods, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            if (self.shift) try writer.writeAll("shift+");
            if (self.ctrl) try writer.writeAll("ctrl+");
            if (self.alt) try writer.writeAll("alt+");
            if (self.meta) try writer.writeAll("meta+");
            if (self.super) try writer.writeAll("super+");
            if (self.hyper) try writer.writeAll("hyper+");
            if (self.caps_lock) try writer.writeAll("caps_lock+");
            if (self.num_lock) try writer.writeAll("num_lock+");
        }
    };

    pub const KeyEvent = struct {
        code: Code,
        physical_key: Code,
        mods: Mods,

        pub fn format(self: KeyEvent, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("{f}", .{self.mods});
            switch (self.code) {
                _ => |value| {
                    const c: u21 = @intFromEnum(value);
                    switch (c) {
                        32...126 => |code| {
                            try writer.writeByte(@truncate(code));
                        },
                        else => |code| try writer.print("{d}", .{code}),
                    }
                },
                else => |code| try writer.print("{s}", .{@tagName(code)}),
            }
        }

        pub fn parseAscii(c: u8) KeyEvent {
            switch (c) {
                0x00 => return .{ .code = @enumFromInt('@'), .mods = .{ .ctrl = true }, .physical_key = .@"2" },
                0x1b => return .{ .code = .escape, .mods = .{}, .physical_key = .escape },
                0x0D => return .{ .code = .enter, .mods = .{}, .physical_key = .enter },
                0x0A => return .{ .code = @enumFromInt('j'), .mods = .{ .ctrl = true }, .physical_key = .j },
                0x09 => return .{ .code = .tab, .mods = .{}, .physical_key = .tab },
                0x7F => return .{ .code = .backspace, .mods = .{}, .physical_key = .backspace },
                1...8, 11, 12, 14...26, 0x1C...0x1F => |ctrl| {
                    const code: Code = @enumFromInt(if (ctrl <= 0x1A) ctrl + 'a' - 1 else ctrl + 0x18);
                    const mapped_key = code.mapUsLayout();
                    return .{ .code = code, .mods = .{ .ctrl = true, .shift = mapped_key.shift }, .physical_key = mapped_key.physical_key };
                },
                else => {
                    const code: Code = @enumFromInt(c);
                    const mapped_key = code.mapUsLayout();
                    return .{ .code = @enumFromInt(c), .mods = .{ .shift = mapped_key.shift }, .physical_key = mapped_key.physical_key };
                },
            }
        }

        pub const Code = enum(u21) {
            unkown = std.math.maxInt(u21),
            tab = 0x09,
            enter = 0x0d,
            backspace = 0x7f,
            escape = 0x1b,
            space = 0x20,
            @"!" = 0x21,
            @"\"" = 0x22,
            @"#" = 0x23,
            @"$" = 0x24,
            @"%" = 0x25,
            @"&" = 0x26,
            @"'" = 0x27,
            @"(" = 0x28,
            @")" = 0x29,
            @"*" = 0x2a,
            @"+" = 0x2b,
            @"," = 0x2c,
            @"-" = 0x2d,
            @"." = 0x2e,
            @"/" = 0x2f,
            @"0" = 0x30,
            @"1" = 0x31,
            @"2" = 0x32,
            @"3" = 0x33,
            @"4" = 0x34,
            @"5" = 0x35,
            @"6" = 0x36,
            @"7" = 0x37,
            @"8" = 0x38,
            @"9" = 0x39,
            @":" = 0x3a,
            @";" = 0x3b,
            @"<" = 0x3c,
            @"=" = 0x3d,
            @">" = 0x3e,
            @"?" = 0x3f,
            @"@" = 0x40,
            A = 0x41,
            B = 0x42,
            C = 0x43,
            D = 0x44,
            E = 0x45,
            F = 0x46,
            G = 0x47,
            H = 0x48,
            I = 0x49,
            J = 0x4a,
            K = 0x4b,
            L = 0x4c,
            M = 0x4d,
            N = 0x4e,
            O = 0x4f,
            P = 0x50,
            Q = 0x51,
            R = 0x52,
            S = 0x53,
            T = 0x54,
            U = 0x55,
            V = 0x56,
            W = 0x57,
            X = 0x58,
            Y = 0x59,
            Z = 0x5a,
            @"[" = 0x5b,
            @"\\" = 0x5c,
            @"]" = 0x5d,
            @"^" = 0x5e,
            underscore = 0x5f,
            @"`" = 0x60,
            a = 0x61,
            b = 0x62,
            c = 0x63,
            d = 0x64,
            e = 0x65,
            f = 0x66,
            g = 0x67,
            h = 0x68,
            i = 0x69,
            j = 0x6A,
            k = 0x6B,
            l = 0x6C,
            m = 0x6D,
            n = 0x6E,
            o = 0x6F,
            p = 0x70,
            q = 0x71,
            r = 0x72,
            s = 0x73,
            t = 0x74,
            u = 0x75,
            v = 0x76,
            w = 0x77,
            x = 0x78,
            y = 0x79,
            z = 0x7A,
            @"{" = 0x7b,
            @"|" = 0x7c,
            @"}" = 0x7d,
            @"~" = 0x7e,
            insert = 0xe004,
            delete = 0xe003,
            left = 0xe006,
            right = 0xe007,
            up = 0xe008,
            down = 0xe009,
            page_up = 0xe00a,
            page_down = 0xe00b,
            home = 0xe00c,
            end = 0xe00d,
            caps_lock = 0xe00e,
            scroll_lock = 0xe00f,
            num_lock = 0xe010,
            print_screen = 0xe011,
            pause = 0xe012,
            menu = 0xe013,
            f1 = 0xe014,
            f2 = 0xe015,
            f3 = 0xe016,
            f4 = 0xe017,
            f5 = 0xe018,
            f6 = 0xe019,
            f7 = 0xe01a,
            f8 = 0xe01b,
            f9 = 0xe01c,
            f10 = 0xe01d,
            f11 = 0xe01e,
            f12 = 0xe01f,
            f13 = 0xe020,
            f14 = 0xe021,
            f15 = 0xe022,
            f16 = 0xe023,
            f17 = 0xe024,
            f18 = 0xe025,
            f19 = 0xe026,
            f20 = 0xe027,
            f21 = 0xe028,
            f22 = 0xe029,
            f23 = 0xe02a,
            f24 = 0xe02b,
            f25 = 0xe02c,
            f26 = 0xe02d,
            f27 = 0xe02e,
            f28 = 0xe02f,
            f29 = 0xe030,
            f30 = 0xe031,
            f31 = 0xe032,
            f32 = 0xe033,
            f33 = 0xe034,
            f34 = 0xe035,
            f35 = 0xe036,
            kp_0 = 0xe037,
            kp_1 = 0xe038,
            kp_2 = 0xe039,
            kp_3 = 0xe03a,
            kp_4 = 0xe03b,
            kp_5 = 0xe03c,
            kp_6 = 0xe03d,
            kp_7 = 0xe03e,
            kp_8 = 0xe03f,
            kp_9 = 0xe040,
            kp_decimal = 0xe041,
            kp_divide = 0xe042,
            kp_multiply = 0xe043,
            kp_subtract = 0xe044,
            kp_add = 0xe045,
            kp_enter = 0xe046,
            kp_equal = 0xe047,
            kp_separator = 0xe048,
            kp_left = 0xe049,
            kp_right = 0xe04a,
            kp_up = 0xe04b,
            kp_down = 0xe04c,
            kp_page_up = 0xe04d,
            kp_page_down = 0xe04e,
            kp_home = 0xe04f,
            kp_end = 0xe050,
            kp_insert = 0xe051,
            kp_delete = 0xe052,
            kp_begin = 0xe053,
            media_play = 0xe054,
            media_pause = 0xe055,
            media_play_pause = 0xe056,
            media_reverse = 0xe057,
            media_stop = 0xe058,
            media_fast_forward = 0xe059,
            media_rewind = 0xe05a,
            media_track_next = 0xe05b,
            media_track_previous = 0xe05c,
            media_record = 0xe05d,
            lower_volume = 0xe05e,
            raise_volume = 0xe05f,
            mute = 0xe060,
            left_shift = 0xe061,
            left_control = 0xe062,
            left_alt = 0xe063,
            left_super = 0xe064,
            left_hyper = 0xe065,
            left_meta = 0xe066,
            right_shift = 0xe067,
            right_control = 0xe068,
            right_alt = 0xe069,
            right_super = 0xe06a,
            right_hyper = 0xe06b,
            right_meta = 0xe06c,
            iso_level3_shift = 0xe06d,
            iso_level5_shift = 0xe06e,
            _,

            pub fn mapUsLayout(c: Code) struct { physical_key: Code, shift: bool } {
                return switch (c) {
                    .@"@" => .{ .physical_key = .@"2", .shift = true },
                    .@"#" => .{ .physical_key = .@"3", .shift = true },
                    .@"$" => .{ .physical_key = .@"4", .shift = true },
                    .@"%" => .{ .physical_key = .@"5", .shift = true },
                    .@"^" => .{ .physical_key = .@"6", .shift = true },
                    .@"&" => .{ .physical_key = .@"7", .shift = true },
                    .@"*" => .{ .physical_key = .@"8", .shift = true },
                    .@"(" => .{ .physical_key = .@"9", .shift = true },
                    .@")" => .{ .physical_key = .@"0", .shift = true },
                    .underscore => .{ .physical_key = .@"-", .shift = true },
                    .@"+" => .{ .physical_key = .@"=", .shift = true },
                    .@"{" => .{ .physical_key = .@"[", .shift = true },
                    .@"}" => .{ .physical_key = .@"]", .shift = true },
                    .@"|" => .{ .physical_key = .@"\\", .shift = true },
                    .@":" => .{ .physical_key = .@";", .shift = true },
                    .@"'" => .{ .physical_key = .@"'", .shift = true },
                    .@"<" => .{ .physical_key = .@",", .shift = true },
                    .@">" => .{ .physical_key = .@".", .shift = true },
                    .@"?" => .{ .physical_key = .@"/", .shift = true },
                    .@"~" => .{ .physical_key = .@"`", .shift = true },
                    .A => .{ .physical_key = .a, .shift = true },
                    .B => .{ .physical_key = .b, .shift = true },
                    .C => .{ .physical_key = .c, .shift = true },
                    .D => .{ .physical_key = .d, .shift = true },
                    .E => .{ .physical_key = .e, .shift = true },
                    .F => .{ .physical_key = .f, .shift = true },
                    .G => .{ .physical_key = .g, .shift = true },
                    .H => .{ .physical_key = .h, .shift = true },
                    .I => .{ .physical_key = .i, .shift = true },
                    .J => .{ .physical_key = .j, .shift = true },
                    .K => .{ .physical_key = .k, .shift = true },
                    .L => .{ .physical_key = .l, .shift = true },
                    .M => .{ .physical_key = .m, .shift = true },
                    .N => .{ .physical_key = .n, .shift = true },
                    .O => .{ .physical_key = .o, .shift = true },
                    .P => .{ .physical_key = .p, .shift = true },
                    .Q => .{ .physical_key = .q, .shift = true },
                    .R => .{ .physical_key = .r, .shift = true },
                    .S => .{ .physical_key = .s, .shift = true },
                    .T => .{ .physical_key = .t, .shift = true },
                    .U => .{ .physical_key = .u, .shift = true },
                    .V => .{ .physical_key = .v, .shift = true },
                    .W => .{ .physical_key = .w, .shift = true },
                    .X => .{ .physical_key = .x, .shift = true },
                    .Y => .{ .physical_key = .y, .shift = true },
                    .Z => .{ .physical_key = .z, .shift = true },
                    else => return .{ .physical_key = c, .shift = false },
                    _ => .{ .physical_key = .unkown, .shift = false },
                };
            }
        };
    };
};

test "keyboard events" {
    const test_cases = [_]struct {
        sequence: []const u8,
        expected: Event.KeyEvent,
    }{
        .{ .sequence = "a", .expected = .{ .code = .a, .physical_key = .a, .mods = .{} } },
        .{ .sequence = "A", .expected = .{ .code = .A, .physical_key = .a, .mods = .{ .shift = true } } },
        .{ .sequence = ";", .expected = .{ .code = .@";", .physical_key = .@";", .mods = .{} } },
        .{ .sequence = ":", .expected = .{ .code = .@":", .physical_key = .@";", .mods = .{ .shift = true } } },
        .{ .sequence = "\x1b", .expected = .{ .code = .escape, .physical_key = .escape, .mods = .{} } },
        .{ .sequence = "\x02", .expected = .{ .code = .b, .physical_key = .b, .mods = .{ .ctrl = true } } },
        .{ .sequence = "\x1d", .expected = .{ .code = .@"5", .physical_key = .@"5", .mods = .{ .ctrl = true } } },
        .{ .sequence = "\x1ba", .expected = .{ .code = .a, .physical_key = .a, .mods = .{ .alt = true } } },
        .{ .sequence = "\x1b\x1d", .expected = .{ .code = .@"5", .physical_key = .@"5", .mods = .{ .alt = true, .ctrl = true } } },
        .{ .sequence = "\x1bA", .expected = .{ .code = .A, .physical_key = .a, .mods = .{ .alt = true, .shift = true } } },
    };

    const printCase = struct {
        fn printCase(sequence: []const u8) void {
            var buffer: [256]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);

            writer.writeAll("Case '") catch unreachable;
            for (sequence) |c| {
                if (c == '\x1b') writer.writeAll("\\x1b") catch unreachable else writer.writeByte(c) catch unreachable;
            }
            writer.writeAll("' failed:") catch unreachable;
            std.log.err("{s}", .{writer.buffered()});
        }
    }.printCase;

    var error_out: ?anyerror = null;
    for (test_cases) |test_case| {
        var error_this_test: bool = false;
        var remaining_bytes: usize = test_case.sequence.len;
        const event = parseEvent(test_case.sequence, &remaining_bytes);

        if (event != .key_pressed) {
            if (!error_this_test) printCase(test_case.sequence);
            std.log.err("\tExpected Tag .key, found {any}", .{event});
            error_out = error.TestExpectedEqual;
            error_this_test = true;
            continue;
        }
        const key_event = event.key_pressed;
        const expected = test_case.expected;
        if (key_event.code != expected.code) {
            if (!error_this_test) printCase(test_case.sequence);
            std.log.err("\tExpected code {any}, found {any}", .{ expected.code, key_event.code });
            error_out = error.TestExpectedEqual;
            error_this_test = true;
        }
        if (key_event.physical_key != expected.physical_key) {
            if (!error_this_test) printCase(test_case.sequence);
            std.log.err("\tExpected physical_key {any}, found {any}", .{ expected.physical_key, key_event.physical_key });
            error_out = error.TestExpectedEqual;
            error_this_test = true;
        }
        if (key_event.mods != expected.mods) {
            if (!error_this_test) printCase(test_case.sequence);
            std.log.err("\tExpected mods {any}, found {any}", .{ expected.mods, key_event.mods });
            error_out = error.TestExpectedEqual;
            error_this_test = true;
        }
        if (error_this_test) std.log.err("---------------------------------------", .{});
    }

    if (error_out) |err| return err;
}

pub fn cut(comptime T: type, haystack: []const T, needle: []const T) ?struct { []const T, []const T } {
    const index = std.mem.find(T, haystack, needle) orelse return null;
    return .{ haystack[0..index], haystack[index + needle.len ..] };
}

pub fn cutScalar(comptime T: type, haystack: []const T, needle: T) ?struct { []const T, []const T } {
    const index = std.mem.findScalar(T, haystack, needle) orelse return null;
    return .{ haystack[0..index], haystack[index + 1 ..] };
}
