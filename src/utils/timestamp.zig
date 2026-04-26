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
        const yearDay = day.calculateYearDay();
        const monthDay = yearDay.calculateMonthDay();
        const hours = timestamp.getDaySeconds();

        return .{
            .epoch = epoch,
            .day = monthDay.day_index + 1,
            .month = monthDay.month.numeric(),
            .year = yearDay.year,
            .hour = hours.getHoursIntoDay(),
            .minute = hours.getMinutesIntoHour(),
            .second = hours.getSecondsIntoMinute(),
        };
    }

    pub fn getDay(self: @This()) [2]u8 {
        var buffer: [2]u8 = undefined;
        if (self.day > 10) {
            _ = std.fmt.bufPrint(&buffer, "{d}", .{self.day}) catch "00";
        } else {
            _ = std.fmt.bufPrint(&buffer, "0{d}", .{self.day}) catch "00";
        }
        return buffer;
    }

    pub fn getMonth(self: @This()) [2]u8 {
        var buffer: [2]u8 = undefined;
        if (self.month > 10) {
            _ = std.fmt.bufPrint(&buffer, "{d}", .{self.month}) catch "00";
        } else {
            _ = std.fmt.bufPrint(&buffer, "0{d}", .{self.month}) catch "00";
        }
        return buffer;
    }

    pub fn getYear(self: @This()) [4]u8 {
        var buffer: [4]u8 = undefined;
        _ = std.fmt.bufPrint(&buffer, "{d}", .{self.year}) catch "0000";
        return buffer;
    }

    pub fn getHour(self: @This()) [2]u8 {
        var buffer: [2]u8 = undefined;
        if (self.hour > 10) {
            _ = std.fmt.bufPrint(&buffer, "{d}", .{self.hour}) catch "00";
        } else {
            _ = std.fmt.bufPrint(&buffer, "0{d}", .{self.hour}) catch "00";
        }
        return buffer;
    }

    pub fn getMinute(self: @This()) [2]u8 {
        var buffer: [2]u8 = undefined;
        if (self.minute > 10) {
            _ = std.fmt.bufPrint(&buffer, "{d}", .{self.minute}) catch "00";
        } else {
            _ = std.fmt.bufPrint(&buffer, "0{d}", .{self.minute}) catch "00";
        }
        return buffer;
    }

    pub fn getSecond(self: @This()) [2]u8 {
        var buffer: [2]u8 = undefined;
        if (self.second > 10) {
            _ = std.fmt.bufPrint(&buffer, "{d}", .{self.second}) catch "00";
        } else {
            _ = std.fmt.bufPrint(&buffer, "0{d}", .{self.second}) catch "00";
        }
        return buffer;
    }
};

test "timestamp" {
    var ts = Timestamp.init(0);
    try testing.expectEqualStrings("01", &ts.getDay());
    try testing.expectEqualStrings("01", &ts.getMonth());
    try testing.expectEqualStrings("1970", &ts.getYear());
    try testing.expectEqualStrings("00", &ts.getHour());
    try testing.expectEqualStrings("00", &ts.getMinute());
    try testing.expectEqualStrings("00", &ts.getSecond());
}

pub fn get_current_date(io: std.Io) [date_len]u8 {
    var date: [date_len]u8 = undefined;

    const timestamp = Timestamp.now(io);
    const fmt = "{s}/{s}/{s}:{s}:{s}:{s} +0000";
    const args = .{
        timestamp.getDay(),
        timestamp.getMonth(),
        timestamp.getYear(),
        timestamp.getHour(),
        timestamp.getMinute(),
        timestamp.getSecond(),
    };
    _ = std.fmt.bufPrint(&date, fmt, args) catch unreachable;
    return date;
}

const date_len: usize = 25;

const std = @import("std");
const testing = std.testing;
