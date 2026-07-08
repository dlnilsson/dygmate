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
