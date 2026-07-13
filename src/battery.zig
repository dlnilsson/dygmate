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

// Poll cadence. Plain reads hit the USB-powered neuron only — no flash wear,
// no RF traffic to the sides (Bazecor polls at 5s forever) — so short
// intervals are free. Short intervals also bound how long a bogus reading can
// stay on screen: after the halves wake from deep sleep the neuron's cache can
// transiently report 100% before real data arrives.
pub const fast_poll_interval_s: u64 = 30;
pub const slow_poll_interval_s: u64 = 120;
/// Below this level always poll fast (matches the tray's low_threshold).
pub const low_level_fast_threshold: u8 = 20;
/// Fuel gauges jitter a point or two with load/temperature; anything above
/// this while discharging is an implausible upward jump.
pub const level_jump_tolerance: u8 = 3;
/// Consecutive sightings before an implausible upward jump is accepted.
pub const suspect_confirm_polls: u8 = 3;
/// Consecutive sightings before an initial 100 (no baseline yet) is trusted —
/// 100 is exactly what the post-wake bogus cache reports.
pub const first_reading_confirm_polls: u8 = 2;
pub const force_read_settle_s: u64 = 2;

/// Issue the four battery read commands. Parse failures degrade to
/// null/.unknown; only transport errors propagate (they mean the
/// connection is gone and the caller should reconnect). Reads the neuron's
/// cached values — callers should use `read` for the disconnected-side retry.
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

/// One poll of both halves, with Bazecor's single retry: if either side comes
/// back "disconnected" (status 4) the RF link to that half briefly dropped, so
/// wait 500ms and read once more. Deliberately NO forceRead here — the neuron
/// serves cached values on a plain read, and forcing a re-poll every cycle
/// blanks those values mid-refresh (empty responses) and hammers the sleeping
/// sides' RF link. Mirrors battery.Read in the Go tray; forceRead is a manual,
/// user-triggered action only (see forceRead below).
pub fn read(f: *focus.Focus) focus.Error!Reading {
    const r = try readAll(f);
    if (r.left.status != .disconnected and r.right.status != .disconnected) return r;
    sleepMs(f.io, 500);
    // Keep the first reading if the retry itself errors out.
    return readAll(f) catch r;
}

/// Ask the neuron to re-poll both sides over RF (Bazecor's "Force read"
/// button). Argument-less, so it writes no EEPROM, but it generates RF traffic
/// and briefly blanks the cached values — call it only on an explicit user
/// refresh, never in the poll loop. Mirrors battery.ForceRead in the Go tray.
pub fn forceRead(f: *focus.Focus) void {
    var buf: [64]u8 = undefined;
    _ = f.request("wireless.battery.forceRead", &buf) catch {};
}

fn sleepMs(io: std.Io, ms: u64) void {
    const dur: std.Io.Clock.Duration = .{
        .clock = .awake,
        .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)),
    };
    dur.sleep(io) catch {};
}

/// Plausibility gate for battery levels. After the halves wake from deep
/// sleep the neuron's cache can transiently report a bogus 100%, and a level
/// cannot genuinely rise while discharging — so an upward jump must repeat on
/// consecutive polls before it is accepted. Drops are always plausible and
/// accepted immediately; charging/charged sides are trusted outright (the
/// sides really do charge over cable while the user is away). Pure state
/// machine: no Io, no allocator, unit-testable without hardware.
pub const Acceptor = struct {
    left: SideState = .{},
    right: SideState = .{},

    pub const SideState = struct {
        /// Last accepted level; null until a side first passes the gate.
        accepted: ?u8 = null,
        /// Suspect value awaiting confirmation.
        pending: ?u8 = null,
        pending_count: u8 = 0,
    };

    pub const Result = struct {
        /// Validated reading: rejected levels are replaced by the last
        /// accepted level (or null). Statuses pass through untouched.
        reading: Reading,
        /// True while any side holds an unconfirmed suspect value — callers
        /// should poll fast until it resolves.
        suspect: bool,
    };

    pub fn feed(self: *Acceptor, raw: Reading) Result {
        return self.result(.{
            .left = feedSide(&self.left, raw.left),
            .right = feedSide(&self.right, raw.right),
        });
    }

    /// Post-forceRead: the neuron just re-polled the sides over RF, so any
    /// numeric level is ground truth — accept it outright and clear pending.
    /// Refusing it for several polls would make an explicit user refresh
    /// appear broken.
    pub fn feedAuthoritative(self: *Acceptor, raw: Reading) Result {
        return self.result(.{
            .left = acceptSide(&self.left, raw.left),
            .right = acceptSide(&self.right, raw.right),
        });
    }

    fn result(self: *const Acceptor, reading: Reading) Result {
        return .{
            .reading = reading,
            .suspect = self.left.pending != null or self.right.pending != null,
        };
    }

    fn feedSide(st: *SideState, raw: SideReading) SideReading {
        // A sleeping half answers with an empty payload; that's routine, not
        // evidence for or against a pending suspect — keep the streak.
        const lvl = raw.level orelse
            return .{ .level = st.accepted, .status = raw.status };
        if (raw.status == .charging or raw.status == .charged)
            return acceptSide(st, raw);
        if (st.accepted) |acc| {
            if (lvl <= acc +| level_jump_tolerance) return acceptSide(st, raw);
            return suspectSide(st, raw, suspect_confirm_polls);
        }
        // No baseline to jump-gate against; only an initial 100 matches the
        // known bogus post-wake value, everything else is taken at face value.
        if (lvl < 100) return acceptSide(st, raw);
        return suspectSide(st, raw, first_reading_confirm_polls);
    }

    fn acceptSide(st: *SideState, raw: SideReading) SideReading {
        if (raw.level) |lvl| {
            st.accepted = lvl;
            st.pending = null;
            st.pending_count = 0;
        }
        return .{ .level = st.accepted, .status = raw.status };
    }

    fn suspectSide(st: *SideState, raw: SideReading, confirm: u8) SideReading {
        const lvl = raw.level.?;
        if (st.pending) |p| {
            const diff = if (lvl > p) lvl - p else p - lvl;
            if (diff <= level_jump_tolerance) {
                st.pending_count += 1;
                if (st.pending_count >= confirm) return acceptSide(st, raw);
                return .{ .level = st.accepted, .status = raw.status };
            }
        }
        st.pending = lvl;
        st.pending_count = 1;
        return .{ .level = st.accepted, .status = raw.status };
    }
};

pub fn suggestedPollIntervalSeconds(r: Reading, suspect: bool) u64 {
    if (suspect) return fast_poll_interval_s;
    const lvl = lowestLevel(r) orelse return fast_poll_interval_s;
    if (lvl < low_level_fast_threshold) return fast_poll_interval_s;
    return slow_poll_interval_s;
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

test "suggestedPollIntervalSeconds: fast when suspect, unknown, or low" {
    const healthy: Reading = .{
        .left = .{ .level = 100, .status = .charged },
        .right = .{ .level = 98, .status = .discharging },
    };
    try std.testing.expectEqual(slow_poll_interval_s, suggestedPollIntervalSeconds(healthy, false));
    try std.testing.expectEqual(fast_poll_interval_s, suggestedPollIntervalSeconds(healthy, true));
    try std.testing.expectEqual(
        fast_poll_interval_s,
        suggestedPollIntervalSeconds(.{
            .left = .{ .level = null, .status = .unknown },
            .right = .{ .level = null, .status = .unknown },
        }, false),
    );
    try std.testing.expectEqual(
        fast_poll_interval_s,
        suggestedPollIntervalSeconds(.{
            .left = .{ .level = 19, .status = .discharging },
            .right = .{ .level = 100, .status = .charged },
        }, false),
    );
}

// -- Acceptor ---------------------------------------------------------------

fn side(level: ?u8, status: Status) SideReading {
    return .{ .level = level, .status = status };
}

/// Feed a reading where only the left side varies; the right side stays quiet.
fn feedLeft(a: *Acceptor, level: ?u8, status: Status) Acceptor.Result {
    return a.feed(.{
        .left = side(level, status),
        .right = side(null, .unknown),
    });
}

test "Acceptor: first reading below 100 accepted immediately" {
    var a: Acceptor = .{};
    const res = feedLeft(&a, 87, .discharging);
    try std.testing.expectEqual(@as(?u8, 87), res.reading.left.level);
    try std.testing.expect(!res.suspect);
}

test "Acceptor: first reading of 100 needs confirmation unless charging" {
    var a: Acceptor = .{};
    var res = feedLeft(&a, 100, .discharging);
    try std.testing.expectEqual(@as(?u8, null), res.reading.left.level);
    try std.testing.expect(res.suspect);
    res = feedLeft(&a, 100, .discharging);
    try std.testing.expectEqual(@as(?u8, 100), res.reading.left.level);
    try std.testing.expect(!res.suspect);

    var b: Acceptor = .{};
    const charged = feedLeft(&b, 100, .charged);
    try std.testing.expectEqual(@as(?u8, 100), charged.reading.left.level);
    try std.testing.expect(!charged.suspect);
}

test "Acceptor: drops and small drift accepted immediately" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 45, .discharging);
    var res = feedLeft(&a, 30, .discharging);
    try std.testing.expectEqual(@as(?u8, 30), res.reading.left.level);
    try std.testing.expect(!res.suspect);
    res = feedLeft(&a, 32, .discharging); // within jump tolerance
    try std.testing.expectEqual(@as(?u8, 32), res.reading.left.level);
    try std.testing.expect(!res.suspect);
}

test "Acceptor: upward jump held until confirmed on consecutive polls" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 45, .discharging);
    var res = feedLeft(&a, 100, .discharging);
    try std.testing.expectEqual(@as(?u8, 45), res.reading.left.level);
    try std.testing.expect(res.suspect);
    res = feedLeft(&a, 100, .discharging);
    try std.testing.expectEqual(@as(?u8, 45), res.reading.left.level);
    try std.testing.expect(res.suspect);
    res = feedLeft(&a, 100, .discharging); // third consecutive sighting
    try std.testing.expectEqual(@as(?u8, 100), res.reading.left.level);
    try std.testing.expect(!res.suspect);
}

test "Acceptor: plausible reading cancels a pending jump" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 45, .discharging);
    _ = feedLeft(&a, 100, .discharging);
    const res = feedLeft(&a, 44, .discharging);
    try std.testing.expectEqual(@as(?u8, 44), res.reading.left.level);
    try std.testing.expect(!res.suspect);
}

test "Acceptor: charging status accepts an upward jump outright" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 45, .discharging);
    const res = feedLeft(&a, 80, .charging);
    try std.testing.expectEqual(@as(?u8, 80), res.reading.left.level);
    try std.testing.expect(!res.suspect);
}

test "Acceptor: null polls keep the pending streak alive" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 45, .discharging);
    _ = feedLeft(&a, 100, .discharging);
    var res = feedLeft(&a, null, .unknown);
    try std.testing.expectEqual(@as(?u8, 45), res.reading.left.level);
    try std.testing.expect(res.suspect);
    _ = feedLeft(&a, 100, .discharging);
    res = feedLeft(&a, 100, .discharging);
    try std.testing.expectEqual(@as(?u8, 100), res.reading.left.level);
    try std.testing.expect(!res.suspect);
}

test "Acceptor: a different high value restarts the streak" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 45, .discharging);
    _ = feedLeft(&a, 100, .discharging);
    _ = feedLeft(&a, 90, .discharging); // pending restarts at 90, count 1
    var res = feedLeft(&a, 90, .discharging); // count 2: still held
    try std.testing.expectEqual(@as(?u8, 45), res.reading.left.level);
    res = feedLeft(&a, 90, .discharging); // count 3: accepted
    try std.testing.expectEqual(@as(?u8, 90), res.reading.left.level);
}

test "Acceptor: sides gate independently" {
    var a: Acceptor = .{};
    _ = a.feed(.{
        .left = side(45, .discharging),
        .right = side(60, .discharging),
    });
    const res = a.feed(.{
        .left = side(100, .discharging),
        .right = side(55, .discharging),
    });
    try std.testing.expectEqual(@as(?u8, 45), res.reading.left.level);
    try std.testing.expectEqual(@as(?u8, 55), res.reading.right.level);
    try std.testing.expect(res.suspect);
}

test "Acceptor: feedAuthoritative accepts a jump in one shot" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 45, .discharging);
    _ = feedLeft(&a, 100, .discharging);
    const res = a.feedAuthoritative(.{
        .left = side(97, .discharging),
        .right = side(null, .unknown),
    });
    try std.testing.expectEqual(@as(?u8, 97), res.reading.left.level);
    try std.testing.expect(!res.suspect);
}

test "Acceptor: status passes through even when the level is rejected" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 45, .discharging);
    const res = feedLeft(&a, 100, .fault);
    try std.testing.expectEqual(@as(?u8, 45), res.reading.left.level);
    try std.testing.expectEqual(Status.fault, res.reading.left.status);
}
