const std = @import("std");
const assert = std.debug.assert;

pub const dir_name = ".gila";

pub const description_file_name = "description.md";
pub const comments_file_name = "comments.md";

pub const Status = union(enum(u8)) {
    todo,
    in_progress,
    done,
    cancelled,
    waiting: ?[]const TaskId,
};

pub const TaskId = struct {
    date_time: DateTimeUTC,
    user_name: []const u8,
};

// https://github.com/tigerbeetle/tigerbeetle/blob/16d62f0ce7d4ef3db58714c9b7a0c46480c19bc3/src/stdx.zig#L985
pub const DateTimeUTC = packed struct(u64) {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u6,
    millisecond: u10,

    pub fn now() DateTimeUTC {
        const timestamp_ms = std.time.milliTimestamp();
        assert(timestamp_ms > 0);
        return DateTimeUTC.from_timestamp_ms(@intCast(timestamp_ms));
    }

    pub fn from_timestamp_ms(timestamp_ms: u64) DateTimeUTC {
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @divTrunc(timestamp_ms, 1000) };
        const year_day = epoch_seconds.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const time = epoch_seconds.getDaySeconds();

        return DateTimeUTC{
            .year = year_day.year,
            .month = month_day.month.numeric(),
            .day = month_day.day_index + 1,
            .hour = time.getHoursIntoDay(),
            .minute = time.getMinutesIntoHour(),
            .second = time.getSecondsIntoMinute(),
            .millisecond = @intCast(@mod(timestamp_ms, 1000)),
        };
    }

    pub fn format(
        datetime: DateTimeUTC,
        comptime fmt: []const u8,
        options: std.fmt.Options,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
            datetime.year,
            datetime.month,
            datetime.day,
            datetime.hour,
            datetime.minute,
            datetime.second,
            datetime.millisecond,
        });
    }

    pub fn dateAsNumber(self: DateTimeUTC) u32 {
        return @as(u32, self.year) * 10000 + @as(u32, self.month) * 100 + @as(u32, self.day);
    }

    pub fn timeAsNumber(self: DateTimeUTC) u32 {
        return @as(u32, self.hour) * 10000 + @as(u32, self.minute) * 100 + @as(u32, self.second);
    }
};

pub const Priority = union(enum) {
    low: u8,
    medium: u8,
    high: u8,
    urgent: u8,
};

pub const Tag = []const u8;

pub const logo =
    \\⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣰⠏⣀⡤⠀⠀⠀⠀⠀
    \\⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀ ⠀⠊⠀⠐⡪⠴⠃⠀⠀⠀⠀
    \\⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠠⠊⠀⠀⣀⣠⠤⢴⣊⠉⠁⠀⠀⠀⠀
    \\⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣀⣀⣀⡀⣀⣀⣾⣷⣶⠋⠉⠀⠀⠀⠈⠁⠀⠀⠀⠀⠀
    \\⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣤⣶⠿⣋⡉⠿⠿⠇⢰⣶⣦⣭⡍⠙⢶⣦⡤⣤⣴⣦⣤⡀⠀⠀⠀⠀
    \\⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣤⣊⠈⢫⣵⣾⣿⣧⢰⣶⣿⢸⣿⣿⣿⡇⣼⣿⡶⣠⣿⣯⣟⣿⣿⣮⣄⠀⠀
    \\⠀⠀⠀⠀⠀⠀⠀⠀⢀⣐⠋⠻⠟⢀⣄⢻⣿⣿⣿⣧⠉⠉⠘⣛⣛⡛⠃⢠⣬⡌⠿⠟⠿⠿⠿⢿⡿⠿⠈⠂
    \\⠀⠀⠀⠀⠀⠀⠀⢠⣾⡿⣡⣶⣦⡻⠿⠃⠙⢛⣩⣴⣆⠀⠚⠿⢿⡿⣛⣼⣛⡳⣤⣄⡀⠀⢀⣀⣀⣀⡴⣣
    \\⠀⠀⠀⠀⠀⠀⢀⠟⠛⢱⣿⣿⣿⣿⢗⡀⠀⠀⢻⡿⢛⠁⠀⠀⠈⠁⠠⡙⠶⡄⠀⠀⠉⠉⠉⠉⠁⠀⠀⠀
    \\⢀⡀⡄⢀⡀⠀⠸⣼⣿⡇⣨⣽⡻⠏⣾⣿⣦⡠⠊⠀⠀⠑⠒⠋⠀⠑⣧⠘⠇⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
    \\⡈⠣⡁⢜⡡⠆⢺⣦⢰⣶⣭⣭⠁⠀⠀⠉⡻⠁⠀⠀⠀⠀⠀⠀⠀⠀⠈⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
    \\⠙⢖⠀⠀⠘⠲⢸⣿⢸⣿⣿⣿⠀⣿⣿⡶⠁⠀⠀⠀⠀⠀⠀    ╭██████╮ ╭██╮╭██╮      ╭█████╮ 
    \\⠀⠀⠙⠒⠐⢦⢠⣯⣈⡉⠉⢩⣤⣤⣭⠥⠤⣄⣄⠠⡄⠀⠀⠀⠀⠀⠀██╭════╯  ██║ ██║     ██╭═══██╮
    \\⠀⠀⠀⠀⠀⠀⠙⢿⣿⣧⣤⣼⣿⣿⣿⢀⡀⠈⠋⠌⡥⡚⠀⠀⠀⠀⠀██║ ╭███╮ ██║ ██║     ███████║
    \\⠀⠀⠀⠀⠀⠀⠀⠀⢻⠿⠿⠛⠛⢫⠉⠉⠘⢆⡀⢀⠒⠶⠆⠀⠀⠀⠀██║   ██║ ██║ ██║     ██╭═══██║
    \\⠀⠀⠀⠀⠀⠀⠀⠀⠈⣄⣠⣴⣶⣿⣧⡀⠀⠀⠉⠀⠀⠀⠀⠀⠀⠀ ╰██████╯ ╭██║ ███████╮██║   ██║
    \\⠀⠀⠀⠀⠀⠀⠀⠀⠀⠸⣿⣿⣿⡿⠋⢙⣦⣄⣀⠀⠀⠀⠀⠀⠀⠀⠀ ╰═════╯ ╰══╯╰═══════╯╰═╯   ╰═╯
    \\⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠘⢟⡁⠀⢠⣾⣿⣿⠏⠉⣿⣿⣿⠛⢻⣿⡝⠂⠀⠀> local plain-text task tracking
    \\⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠙⢶⢿⣿⣿⡟⠀⢸⣿⣿⣿⡆⠴⠋⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
    \\⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⠚⠚⠚⠚⠘⠛⠉⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
    \\
;
