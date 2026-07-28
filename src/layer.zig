//! Layer domain: read active keyboard layer for the tray OSD.

const std = @import("std");

const focus = @import("focus.zig");

pub const max_layer_index: u8 = 9;

/// Read the currently active layer index. Polls `layer.state`, the only
/// argument-less layer read the firmware answers: bare `layer.isActive`
/// replies with an empty payload (its handler needs a layer argument).
/// The firmware reports layers as zero-based indexes; UI code should add
/// one for user-facing labels.
pub fn readActive(f: *focus.Focus) focus.Error!?u8 {
    // `layer.state` answers one line of 32 space-separated 0/1 flags
    // (~65 bytes); request() needs a byte of joining headroom on top.
    var buf: [128]u8 = undefined;
    return parseActiveStrict(try f.request("layer.state", &buf));
}

/// Parse a `layer.state` payload: one 0/1 flag per layer, whitespace
/// separated. The effective layer is the highest-indexed active flag —
/// shift/lock keys activate a layer on top of base, and key lookup goes
/// top-down.
pub fn parseActive(payload: []const u8) ?u8 {
    return parseActiveStrict(payload) catch null;
}

fn parseActiveStrict(payload: []const u8) focus.Error!?u8 {
    var top: ?u8 = null;
    var idx: usize = 0;
    var seen = false;
    var it = std.mem.tokenizeAny(u8, payload, " \t\r\n");
    while (it.next()) |tok| {
        seen = true;
        const v = std.fmt.parseInt(u8, tok, 10) catch return error.InvalidResponse;
        if (v > 1) return error.InvalidResponse;
        if (v == 1) {
            if (idx > max_layer_index) return null;
            top = @intCast(idx);
        }
        idx += 1;
    }
    if (!seen) return error.InvalidResponse;
    return top;
}

pub fn displayNumber(index: u8) u8 {
    return index + 1;
}

test "parseActive picks the topmost active layer flag" {
    // Base layer only.
    try std.testing.expectEqual(@as(?u8, 0), parseActive("1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"));
    // Base + layer 2 held (shift-to): topmost wins.
    try std.testing.expectEqual(@as(?u8, 2), parseActive("1 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"));
    // moveTo replaces the stack: base flag may be off.
    try std.testing.expectEqual(@as(?u8, 5), parseActive("0 0 0 0 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"));
    // Firmware sends a trailing separator; scanner may leave a '\r'.
    try std.testing.expectEqual(@as(?u8, 9), parseActive("1 0 0 0 0 0 0 0 0 1 \r"));
    // A short reply still parses.
    try std.testing.expectEqual(@as(?u8, 0), parseActive("1"));
}

test "parseActive rejects invalid payloads" {
    try std.testing.expectEqual(@as(?u8, null), parseActive(""));
    try std.testing.expectEqual(@as(?u8, null), parseActive("x"));
    try std.testing.expectEqual(@as(?u8, null), parseActive("1 0 x"));
    try std.testing.expectEqual(@as(?u8, null), parseActive("-1"));
    try std.testing.expectEqual(@as(?u8, null), parseActive("4"));
    try std.testing.expectEqual(@as(?u8, null), parseActive("100"));
    // No layer active at all.
    try std.testing.expectEqual(@as(?u8, null), parseActive("0 0 0 0 0 0 0 0 0 0"));
    // Active flag beyond the keyboard's 10 layers.
    try std.testing.expectEqual(@as(?u8, null), parseActive("1 0 0 0 0 0 0 0 0 0 1"));
}

test "parseActiveStrict rejects battery-shaped payloads" {
    try std.testing.expectEqual(@as(?u8, 0), try parseActiveStrict("1 0 0"));
    try std.testing.expectEqual(@as(?u8, null), try parseActiveStrict("0 0 0"));
    try std.testing.expectError(error.InvalidResponse, parseActiveStrict(""));
    try std.testing.expectError(error.InvalidResponse, parseActiveStrict("4"));
    try std.testing.expectError(error.InvalidResponse, parseActiveStrict("100"));
}

test "displayNumber converts to user-facing layer number" {
    try std.testing.expectEqual(@as(u8, 1), displayNumber(0));
    try std.testing.expectEqual(@as(u8, 10), displayNumber(9));
}
