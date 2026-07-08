//! Battery domain: wireless.battery.* commands and response parsing.
//!
//! Every command sent here is a bare read. Focus commands with an argument
//! are setters that write the keyboard's flash — never issue those from a
//! polling loop, flash write cycles are finite.

const std = @import("std");
const focus = @import("focus.zig");

pub const Status = enum {
    discharging,
    charging,
    charged,
    fault,
    disconnected,
    unknown,

    pub fn label(self: Status) []const u8 {
        return switch (self) {
            .discharging => "discharging",
            .charging => "charging",
            .charged => "full",
            .fault => "fault",
            .disconnected => "disconnected",
            .unknown => "?",
        };
    }
};

pub const SideReading = struct {
    level: ?u8,
    status: Status,
};

pub const Reading = struct {
    left: SideReading,
    right: SideReading,
};

pub const min_poll_interval_s: u64 = 15 * 60;
pub const poll_interval_50_s: u64 = 30 * 60;
pub const poll_interval_80_s: u64 = 45 * 60;
pub const max_poll_interval_s: u64 = 60 * 60;
pub const force_read_settle_s: u64 = 2;

/// Issue the four battery read commands. Parse failures degrade to
/// null/.unknown; only transport errors propagate (they mean the
/// connection is gone and the caller should reconnect).
///
/// TODO: Bazecor retries transient status 4 (side disconnected) a few
/// times after wake; the poll cadence self-heals so v1 just reports it.
pub fn readAll(f: *focus.Focus) focus.Error!Reading {
    var buf: [256]u8 = undefined;
    return .{
        .left = .{
            .level = parseLevel(try f.request("wireless.battery.left.level", &buf)),
            .status = parseStatus(try f.request("wireless.battery.left.status", &buf)),
        },
        .right = .{
            .level = parseLevel(try f.request("wireless.battery.right.level", &buf)),
            .status = parseStatus(try f.request("wireless.battery.right.status", &buf)),
        },
    };
}

pub fn suggestedPollIntervalSeconds(r: Reading) u64 {
    const lvl = lowestLevel(r) orelse return min_poll_interval_s;
    if (lvl >= 95) return max_poll_interval_s;
    if (lvl >= 80) return poll_interval_80_s;
    if (lvl >= 50) return poll_interval_50_s;
    return min_poll_interval_s;
}

fn lowestLevel(r: Reading) ?u8 {
    var lvl: ?u8 = null;
    if (r.left.level) |left| lvl = left;
    if (r.right.level) |right| {
        if (lvl == null or right < lvl.?) lvl = right;
    }
    return lvl;
}

pub fn parseLevel(payload: []const u8) ?u8 {
    const t = std.mem.trim(u8, payload, " \t\r\n");
    // The firmware reports raw hex ("0x...") while a reading is invalid;
    // Bazecor treats those as no-value too.
    if (std.mem.indexOf(u8, t, "0x") != null) return null;
    const v = std.fmt.parseInt(u8, t, 10) catch return null;
    return if (v <= 100) v else null;
}

pub fn parseStatus(payload: []const u8) Status {
    const t = std.mem.trim(u8, payload, " \t\r\n");
    const v = std.fmt.parseInt(u8, t, 10) catch return .unknown;
    return switch (v) {
        0 => .discharging,
        1 => .charging,
        2 => .charged,
        3 => .fault,
        4 => .disconnected,
        else => .unknown,
    };
}

test "parseLevel accepts 0-100" {
    try std.testing.expectEqual(@as(?u8, 87), parseLevel("87"));
    try std.testing.expectEqual(@as(?u8, 0), parseLevel("0"));
    try std.testing.expectEqual(@as(?u8, 100), parseLevel("100"));
    try std.testing.expectEqual(@as(?u8, 87), parseLevel(" 87\r"));
}

test "parseLevel rejects invalid values" {
    try std.testing.expectEqual(@as(?u8, null), parseLevel("0x37"));
    try std.testing.expectEqual(@as(?u8, null), parseLevel("255"));
    try std.testing.expectEqual(@as(?u8, null), parseLevel("101"));
    try std.testing.expectEqual(@as(?u8, null), parseLevel("abc"));
    try std.testing.expectEqual(@as(?u8, null), parseLevel(""));
}

test "parseStatus maps firmware codes" {
    try std.testing.expectEqual(Status.discharging, parseStatus("0"));
    try std.testing.expectEqual(Status.charging, parseStatus("1"));
    try std.testing.expectEqual(Status.charged, parseStatus("2"));
    try std.testing.expectEqual(Status.fault, parseStatus("3"));
    try std.testing.expectEqual(Status.disconnected, parseStatus("4"));
    try std.testing.expectEqual(Status.unknown, parseStatus("9"));
    try std.testing.expectEqual(Status.unknown, parseStatus("x"));
}

test "suggestedPollIntervalSeconds uses the lower valid side level" {
    try std.testing.expectEqual(
        min_poll_interval_s,
        suggestedPollIntervalSeconds(.{
            .left = .{ .level = null, .status = .unknown },
            .right = .{ .level = null, .status = .unknown },
        }),
    );
    try std.testing.expectEqual(
        max_poll_interval_s,
        suggestedPollIntervalSeconds(.{
            .left = .{ .level = 100, .status = .charged },
            .right = .{ .level = 98, .status = .charged },
        }),
    );
    try std.testing.expectEqual(
        poll_interval_50_s,
        suggestedPollIntervalSeconds(.{
            .left = .{ .level = 100, .status = .charged },
            .right = .{ .level = 55, .status = .discharging },
        }),
    );
    try std.testing.expectEqual(
        min_poll_interval_s,
        suggestedPollIntervalSeconds(.{
            .left = .{ .level = 49, .status = .discharging },
            .right = .{ .level = 100, .status = .charged },
        }),
    );
}
