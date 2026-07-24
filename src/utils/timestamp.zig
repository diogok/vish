//! UTC timestamp formatting for Common Log Format date strings.

pub const Timestamp = struct {
    epoch: i64,
    day: u5,
    month: u4,
    year: u16,
    hour: u5,
    minute: u6,
    second: u6,

    pub fn now(io: std.Io) @This() {
        const ts = std.Io.Clock.now(.real, io);
        return Timestamp.init(ts.toSeconds());
    }

    pub fn init(epoch: i64) @This() {
        const timestamp = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(epoch)) };
        const day = timestamp.getEpochDay();
        const year_day = day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const hours = timestamp.getDaySeconds();

        return .{
            .epoch = epoch,
            .day = month_day.day_index + 1,
            .month = month_day.month.numeric(),
            .year = year_day.year,
            .hour = hours.getHoursIntoDay(),
            .minute = hours.getMinutesIntoHour(),
            .second = hours.getSecondsIntoMinute(),
        };
    }

    pub fn getDay(self: @This()) [2]u8 {
        return pad2(self.day);
    }

    pub fn getMonth(self: @This()) [2]u8 {
        return pad2(self.month);
    }

    /// Three-letter month abbreviation as used by Common Log Format.
    pub fn getMonthName(self: @This()) [3]u8 {
        const names = [12][3]u8{
            "Jan".*, "Feb".*, "Mar".*, "Apr".*, "May".*, "Jun".*,
            "Jul".*, "Aug".*, "Sep".*, "Oct".*, "Nov".*, "Dec".*,
        };
        return names[self.month - 1];
    }

    pub fn getYear(self: @This()) [4]u8 {
        var buffer: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&buffer, "{d:0>4}", .{self.year}) catch unreachable;
        return buffer;
    }

    pub fn getHour(self: @This()) [2]u8 {
        return pad2(self.hour);
    }

    pub fn getMinute(self: @This()) [2]u8 {
        return pad2(self.minute);
    }

    pub fn getSecond(self: @This()) [2]u8 {
        return pad2(self.second);
    }

    fn pad2(value: u8) [2]u8 {
        var buffer: [2]u8 = undefined;
        _ = std.fmt.bufPrint(&buffer, "{d:0>2}", .{value}) catch unreachable;
        return buffer;
    }
};

test "timestamp" {
    var ts = Timestamp.init(0);
    try testing.expectEqualStrings("01", &ts.getDay());
    try testing.expectEqualStrings("01", &ts.getMonth());
    try testing.expectEqualStrings("Jan", &ts.getMonthName());
    try testing.expectEqualStrings("1970", &ts.getYear());
    try testing.expectEqualStrings("00", &ts.getHour());
    try testing.expectEqualStrings("00", &ts.getMinute());
    try testing.expectEqualStrings("00", &ts.getSecond());
}

test "timestamp pads fields equal to 10" {
    // 1970-10-10 10:10:10 UTC
    var ts = Timestamp.init(24_401_410);
    try testing.expectEqualStrings("10", &ts.getDay());
    try testing.expectEqualStrings("10", &ts.getMonth());
    try testing.expectEqualStrings("Oct", &ts.getMonthName());
    try testing.expectEqualStrings("10", &ts.getHour());
    try testing.expectEqualStrings("10", &ts.getMinute());
    try testing.expectEqualStrings("10", &ts.getSecond());
}

/// Current time formatted for Common Log Format: `10/Oct/2000:13:55:36 +0000`.
pub fn getCurrentDate(io: std.Io) [date_len]u8 {
    var date: [date_len]u8 = undefined;

    const timestamp = Timestamp.now(io);
    const fmt = "{s}/{s}/{s}:{s}:{s}:{s} +0000";
    const args = .{
        timestamp.getDay(),
        timestamp.getMonthName(),
        timestamp.getYear(),
        timestamp.getHour(),
        timestamp.getMinute(),
        timestamp.getSecond(),
    };
    _ = std.fmt.bufPrint(&date, fmt, args) catch unreachable;
    return date;
}

const date_len: usize = 26;

const std = @import("std");
const testing = std.testing;
