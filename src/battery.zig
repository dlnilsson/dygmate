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
/// Fuel gauges jitter a point or two with load/temperature; any move beyond
/// this in either direction between polls is implausible.
pub const level_jump_tolerance: u8 = 3;
/// Consecutive sightings before an implausible jump is accepted.
pub const suspect_confirm_polls: u8 = 3;
/// Consecutive sightings before an initial 100 (no baseline yet) is trusted —
/// 100 is exactly what the post-wake bogus cache reports.
pub const first_reading_confirm_polls: u8 = 2;
pub const force_read_settle_s: u64 = 4;
/// Automatic forceRead verification retry schedule; first attempt fires
/// immediately, each further attempt waits the next entry (last repeats).
pub const verify_backoff_s = [_]u64{ 5, 15, 45, 120 };

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
    // A transport error mid-retry poisons the stream: the abandoned command's
    // response arrives later and answers the NEXT command, shifting every
    // response after it by one (a status "2" then parses as a 2% level).
    // Propagate so the caller reconnects — reopening flushes the port.
    return readAll(f);
}

/// Ask the neuron to re-poll both sides over RF (Bazecor's "Force read"
/// button). Argument-less, so it writes no EEPROM, but it generates RF traffic
/// and briefly blanks the cached values — call it only on an explicit user
/// refresh, never in the poll loop. Mirrors battery.ForceRead in the Go tray.
/// Errors must propagate: an abandoned forceRead leaves its late response in
/// the RX queue, desyncing every later exchange on this connection.
pub fn forceRead(f: *focus.Focus) focus.Error!void {
    var buf: [64]u8 = undefined;
    _ = try f.request("wireless.battery.forceRead", &buf);
}

fn sleepMs(io: std.Io, ms: u64) void {
    const dur: std.Io.Clock.Duration = .{
        .clock = .awake,
        .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)),
    };
    dur.sleep(io) catch {};
}

/// Plausibility gate for battery levels. While a half is asleep or out of RF
/// contact the neuron persistently serves a bogus cached 100% with status
/// "disconnected" on every plain read — not transiently, but until the half
/// actually wakes — so a disconnected side's level is never evidence of
/// anything and is ignored outright. Around sleep/wake transitions the
/// neuron also transiently serves 0 (its unpopulated cache value; Bazecor
/// refuses to render 0% for the same reason) and FOCUS_API documents status
/// fault as "faulty or has some reading error", i.e. the level may be
/// garbage — so fault levels and a 0 while not charging are ignored the
/// same way. A level cannot genuinely rise while discharging, and between
/// polls it cannot genuinely move more than a point or two in either
/// direction, so any move beyond the jump tolerance must repeat on
/// consecutive polls before it is accepted. A first-ever reading below the
/// low threshold is never accepted off plain reads at all: post-wake the
/// neuron persistently serves a bogus cached level with a clean status, and
/// repetition of a cache adds no information, so a value that would newly
/// cross below the low threshold (or any out-of-tolerance value while a
/// side is wake-guarded) is held until an authoritative post-forceRead read
/// settles it. Charging/charged sides are trusted outright (the sides
/// really do charge over cable while the user is away). Pure state machine:
/// no Io, no allocator, unit-testable without hardware.
pub const Acceptor = struct {
    left: SideState = .{},
    right: SideState = .{},

    pub const SideState = struct {
        /// Last accepted level; null until a side first passes the gate.
        accepted: ?u8 = null,
        /// Suspect value awaiting confirmation.
        pending: ?u8 = null,
        pending_count: u8 = 0,
        /// Set by `noteWake` after the machine slept: the neuron's cache is
        /// untrustworthy, so any out-of-tolerance value needs authoritative
        /// verification. Cleared by any accepted level.
        wake_guard: bool = false,
    };

    /// Invariant: `reading` only carries accepted levels, so an unverified
    /// low can never reach display or notifications — the callers' gating on
    /// `needs_verification` is defense-in-depth.
    pub const Result = struct {
        /// Validated reading: rejected levels are replaced by the last
        /// accepted level (or null). Statuses pass through untouched.
        reading: Reading,
        /// True while any side holds an unconfirmed suspect value — callers
        /// should poll fast until it resolves.
        suspect: bool,
        /// Per side (0=left, 1=right): the pending value can only be settled
        /// by an authoritative post-forceRead read — callers should run the
        /// forceRead verification loop until it clears.
        needs_verification: [2]bool,

        pub fn anyVerification(self: Result) bool {
            return self.needs_verification[0] or self.needs_verification[1];
        }
    };

    pub fn feed(self: *Acceptor, raw: Reading) Result {
        return self.result(.{
            .left = feedSide(&self.left, raw.left),
            .right = feedSide(&self.right, raw.right),
        });
    }

    /// Post-forceRead: the neuron just re-polled the sides over RF, so a
    /// numeric level is ground truth — accept it outright and clear pending.
    /// Refusing it for several polls would make an explicit user refresh
    /// appear broken. Exceptions: a side that still answers "disconnected"
    /// or "fault" was NOT (reliably) reached by the re-poll, and a 0 is the
    /// blanked cache the forceRead itself just cleared — both are held like
    /// any other untrusted reading.
    pub fn feedAuthoritative(self: *Acceptor, raw: Reading) Result {
        return self.result(.{
            .left = acceptAuthoritativeSide(&self.left, raw.left),
            .right = acceptAuthoritativeSide(&self.right, raw.right),
        });
    }

    /// The machine just woke from sleep/hibernation: the neuron's cache may
    /// hold bogus values with clean statuses. Drop pre-sleep pending streaks
    /// (that evidence is stale) and guard both sides so any out-of-tolerance
    /// value needs authoritative verification. Baselines survive — the last
    /// accepted level is still the best guess (that's why the Acceptor lives
    /// outside the reconnect loop).
    pub fn noteWake(self: *Acceptor) void {
        for ([_]*SideState{ &self.left, &self.right }) |st| {
            st.pending = null;
            st.pending_count = 0;
            // Only a side that has ever reported gets guarded: with no
            // baseline there is nothing for a bogus cache to contradict (the
            // no-baseline rules already hold an initial low for verification
            // and confirm an initial 100 by repetition), and guarding it
            // would keep the forceRead retry loop alive forever on models
            // where that side never reports at all (Sonsei's right channel).
            st.wake_guard = st.accepted != null;
        }
    }

    fn result(self: *const Acceptor, reading: Reading) Result {
        return .{
            .reading = reading,
            .suspect = self.left.pending != null or self.right.pending != null,
            .needs_verification = .{
                sideNeedsVerification(self.left),
                sideNeedsVerification(self.right),
            },
        };
    }

    /// A side needs an authoritative read when its pending value would newly
    /// cross below the low threshold (never confirmable by cache repetition)
    /// or while it is wake-guarded (guard clears only on an accepted level,
    /// so a side that stays silent after a wake keeps the retry loop alive).
    fn sideNeedsVerification(st: SideState) bool {
        if (st.wake_guard) return true;
        const p = st.pending orelse return false;
        return p < low_level_fast_threshold;
    }

    fn feedSide(st: *SideState, raw: SideReading) SideReading {
        // A sleeping half answers with an empty payload; that's routine, not
        // evidence for or against a pending suspect — keep the streak.
        const lvl = raw.level orelse
            return .{ .level = st.accepted, .status = raw.status };
        // A disconnected side's level is the neuron's stale cache (the bogus
        // post-wake 100 is served persistently in this state, so repetition
        // would "confirm" it) — ignore it exactly like an empty payload: no
        // accept, no baseline, no streak advance. Fault means "faulty or has
        // some reading error" (FOCUS_API), so its level gets the same
        // treatment.
        if (raw.status == .disconnected or raw.status == .fault)
            return .{ .level = st.accepted, .status = raw.status };
        if (raw.status == .charging or raw.status == .charged)
            return acceptSide(st, raw);
        // 0 is the neuron's unpopulated-cache value around sleep/wake, served
        // persistently while a half sleeps — repetition would "confirm" it, so
        // ignore it like disconnected/fault (Bazecor never renders 0% either).
        // A genuinely dying half shows its last real reading until it goes
        // disconnected; a dead-but-charging half is accepted above.
        if (lvl == 0) return .{ .level = st.accepted, .status = raw.status };
        if (st.accepted) |acc| {
            const diff = if (lvl > acc) lvl - acc else acc - lvl;
            if (diff <= level_jump_tolerance) return acceptSide(st, raw);
            // A jump below the low threshold would fire a low-battery
            // notification, and a wake-guarded side may be serving a bogus
            // post-wake cache on every read — repetition of a cache adds no
            // information, so neither is ever confirmable by plain-read
            // repetition; hold until an authoritative read settles it.
            if (lvl < low_level_fast_threshold or st.wake_guard)
                return suspectSide(st, raw, null);
            return suspectSide(st, raw, suspect_confirm_polls);
        }
        // No baseline to jump-gate against; an initial 100 matches the known
        // bogus post-wake value (confirm by repetition), and an initial low
        // may be a stale pre-sleep cache after an app restart following a
        // wake — it must never fire a low-battery notification off plain
        // reads, so hold it for authoritative verification. Take the rest at
        // face value.
        if (lvl >= low_level_fast_threshold and lvl < 100) return acceptSide(st, raw);
        if (lvl >= 100) return suspectSide(st, raw, first_reading_confirm_polls);
        return suspectSide(st, raw, null);
    }

    fn acceptAuthoritativeSide(st: *SideState, raw: SideReading) SideReading {
        if (raw.status == .disconnected or raw.status == .fault)
            return .{ .level = st.accepted, .status = raw.status };
        // forceRead briefly blanks the neuron's cache, so even a post-refresh
        // 0 is "no data yet" rather than ground truth — unless the side says
        // charging, which a genuinely dead-but-plugged-in half really reports.
        if (raw.level) |lvl| {
            if (lvl == 0 and raw.status != .charging and raw.status != .charged)
                return .{ .level = st.accepted, .status = raw.status };
        }
        return acceptSide(st, raw);
    }

    fn acceptSide(st: *SideState, raw: SideReading) SideReading {
        if (raw.level) |lvl| {
            st.accepted = lvl;
            st.pending = null;
            st.pending_count = 0;
            st.wake_guard = false;
        }
        return .{ .level = st.accepted, .status = raw.status };
    }

    /// `confirm == null`: never accept by repetition — track the pending
    /// value (so `suspect`/`needs_verification` stay true) but only an
    /// authoritative read can settle it. The count is not advanced in that
    /// mode: a persistent bogus cache would overflow it, and it decides
    /// nothing.
    fn suspectSide(st: *SideState, raw: SideReading, confirm: ?u8) SideReading {
        const lvl = raw.level.?;
        if (st.pending) |p| {
            const diff = if (lvl > p) lvl - p else p - lvl;
            if (diff <= level_jump_tolerance) {
                if (confirm) |c| {
                    st.pending_count += 1;
                    if (st.pending_count >= c) return acceptSide(st, raw);
                }
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

test "Acceptor: small drift in either direction accepted immediately" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 45, .discharging);
    var res = feedLeft(&a, 43, .discharging); // within jump tolerance
    try std.testing.expectEqual(@as(?u8, 43), res.reading.left.level);
    try std.testing.expect(!res.suspect);
    res = feedLeft(&a, 45, .discharging);
    try std.testing.expectEqual(@as(?u8, 45), res.reading.left.level);
    try std.testing.expect(!res.suspect);
}

test "Acceptor: large drop held until confirmed on consecutive polls" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 90, .discharging);
    var res = feedLeft(&a, 60, .discharging);
    try std.testing.expectEqual(@as(?u8, 90), res.reading.left.level);
    try std.testing.expect(res.suspect);
    res = feedLeft(&a, 60, .discharging);
    try std.testing.expectEqual(@as(?u8, 90), res.reading.left.level);
    try std.testing.expect(res.suspect);
    res = feedLeft(&a, 60, .discharging); // third consecutive sighting
    try std.testing.expectEqual(@as(?u8, 60), res.reading.left.level);
    try std.testing.expect(!res.suspect);
}

test "Acceptor: transient bogus low never displays" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 90, .discharging);
    var res = feedLeft(&a, 4, .discharging);
    try std.testing.expectEqual(@as(?u8, 90), res.reading.left.level);
    try std.testing.expect(res.suspect);
    // The real level returns: pending cleared, the 4 never showed.
    res = feedLeft(&a, 90, .discharging);
    try std.testing.expectEqual(@as(?u8, 90), res.reading.left.level);
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

test "Acceptor: disconnected 100 is never accepted, however often it repeats" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 62, .discharging);
    var res: Acceptor.Result = undefined;
    for (0..5) |_| {
        res = feedLeft(&a, 100, .disconnected);
        try std.testing.expectEqual(@as(?u8, 62), res.reading.left.level);
        try std.testing.expectEqual(Status.disconnected, res.reading.left.status);
        try std.testing.expect(!res.suspect);
    }
}

test "Acceptor: disconnected reading establishes no baseline" {
    var a: Acceptor = .{};
    var res = feedLeft(&a, 100, .disconnected);
    try std.testing.expectEqual(@as(?u8, null), res.reading.left.level);
    try std.testing.expect(!res.suspect);
    // First live reading still goes through the first-reading path untainted.
    res = feedLeft(&a, 87, .discharging);
    try std.testing.expectEqual(@as(?u8, 87), res.reading.left.level);
    try std.testing.expect(!res.suspect);
}

test "Acceptor: disconnected polls keep the pending streak alive" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 45, .discharging);
    _ = feedLeft(&a, 100, .discharging);
    var res = feedLeft(&a, 100, .disconnected);
    try std.testing.expectEqual(@as(?u8, 45), res.reading.left.level);
    try std.testing.expect(res.suspect);
    _ = feedLeft(&a, 100, .discharging);
    res = feedLeft(&a, 100, .discharging);
    try std.testing.expectEqual(@as(?u8, 100), res.reading.left.level);
    try std.testing.expect(!res.suspect);
}

test "Acceptor: feedAuthoritative holds a disconnected side's cached level" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 62, .discharging);
    const res = a.feedAuthoritative(.{
        .left = side(100, .disconnected),
        .right = side(null, .unknown),
    });
    try std.testing.expectEqual(@as(?u8, 62), res.reading.left.level);
    try std.testing.expectEqual(Status.disconnected, res.reading.left.status);
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
        .right = side(58, .discharging),
    });
    try std.testing.expectEqual(@as(?u8, 45), res.reading.left.level);
    try std.testing.expectEqual(@as(?u8, 58), res.reading.right.level);
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

test "Acceptor: fault level is ignored however often it repeats" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 45, .discharging);
    for (0..5) |_| {
        const res = feedLeft(&a, 2, .fault);
        try std.testing.expectEqual(@as(?u8, 45), res.reading.left.level);
        try std.testing.expect(!res.suspect);
    }
}

test "Acceptor: fault polls keep a pending streak alive" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 45, .discharging);
    _ = feedLeft(&a, 100, .discharging);
    var res = feedLeft(&a, 100, .fault);
    try std.testing.expectEqual(@as(?u8, 45), res.reading.left.level);
    try std.testing.expect(res.suspect);
    _ = feedLeft(&a, 100, .discharging);
    res = feedLeft(&a, 100, .discharging);
    try std.testing.expectEqual(@as(?u8, 100), res.reading.left.level);
}

test "Acceptor: 0 while discharging is never accepted, however often it repeats" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 45, .discharging);
    for (0..5) |_| {
        const res = feedLeft(&a, 0, .discharging);
        try std.testing.expectEqual(@as(?u8, 45), res.reading.left.level);
        try std.testing.expect(!res.suspect);
    }
}

test "Acceptor: first reading of 0 establishes no baseline" {
    var a: Acceptor = .{};
    var res = feedLeft(&a, 0, .discharging);
    try std.testing.expectEqual(@as(?u8, null), res.reading.left.level);
    try std.testing.expect(!res.suspect);
    // First live reading still goes through the first-reading path untainted.
    res = feedLeft(&a, 87, .discharging);
    try std.testing.expectEqual(@as(?u8, 87), res.reading.left.level);
    try std.testing.expect(!res.suspect);
}

test "Acceptor: zero polls keep the pending streak alive" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 45, .discharging);
    _ = feedLeft(&a, 100, .discharging);
    var res = feedLeft(&a, 0, .discharging);
    try std.testing.expectEqual(@as(?u8, 45), res.reading.left.level);
    try std.testing.expect(res.suspect);
    _ = feedLeft(&a, 100, .discharging);
    res = feedLeft(&a, 100, .discharging);
    try std.testing.expectEqual(@as(?u8, 100), res.reading.left.level);
    try std.testing.expect(!res.suspect);
}

test "Acceptor: 0 while charging is accepted outright" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 45, .discharging);
    const res = feedLeft(&a, 0, .charging);
    try std.testing.expectEqual(@as(?u8, 0), res.reading.left.level);
    try std.testing.expect(!res.suspect);
}

test "Acceptor: first reading below the low threshold needs authoritative verification" {
    var a: Acceptor = .{};
    // Plain-read repetition never confirms it, however often it repeats.
    for (0..5) |_| {
        const res = feedLeft(&a, 15, .discharging);
        try std.testing.expectEqual(@as(?u8, null), res.reading.left.level);
        try std.testing.expect(res.suspect);
        try std.testing.expect(res.needs_verification[0]);
        try std.testing.expect(!res.needs_verification[1]);
    }
    // A genuine low confirms in one authoritative read.
    const res = a.feedAuthoritative(.{
        .left = side(15, .discharging),
        .right = side(null, .unknown),
    });
    try std.testing.expectEqual(@as(?u8, 15), res.reading.left.level);
    try std.testing.expect(!res.suspect);
    try std.testing.expect(!res.anyVerification());
}

test "Acceptor: feedAuthoritative holds a 0 unless the side is charging" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 62, .discharging);
    var res = a.feedAuthoritative(.{
        .left = side(0, .discharging),
        .right = side(null, .unknown),
    });
    try std.testing.expectEqual(@as(?u8, 62), res.reading.left.level);
    res = a.feedAuthoritative(.{
        .left = side(0, .charging),
        .right = side(null, .unknown),
    });
    try std.testing.expectEqual(@as(?u8, 0), res.reading.left.level);
}

test "Acceptor: feedAuthoritative holds a fault side's level" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 62, .discharging);
    const res = a.feedAuthoritative(.{
        .left = side(3, .fault),
        .right = side(null, .unknown),
    });
    try std.testing.expectEqual(@as(?u8, 62), res.reading.left.level);
    try std.testing.expectEqual(Status.fault, res.reading.left.status);
}

test "Acceptor: low jump is never confirmed by plain repetition" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 90, .discharging);
    for (0..5) |_| {
        const res = feedLeft(&a, 15, .discharging);
        try std.testing.expectEqual(@as(?u8, 90), res.reading.left.level);
        try std.testing.expect(res.suspect);
        try std.testing.expect(res.needs_verification[0]);
    }
}

test "Acceptor: feedAuthoritative settles a pending low either way" {
    // Confirms a genuine low in one read.
    var a: Acceptor = .{};
    _ = feedLeft(&a, 90, .discharging);
    _ = feedLeft(&a, 15, .discharging);
    var res = a.feedAuthoritative(.{
        .left = side(15, .discharging),
        .right = side(null, .unknown),
    });
    try std.testing.expectEqual(@as(?u8, 15), res.reading.left.level);
    try std.testing.expect(!res.anyVerification());

    // Refutes a bogus low: the authoritative value clears the pending streak.
    var b: Acceptor = .{};
    _ = b.feed(.{ .left = side(90, .discharging), .right = side(null, .unknown) });
    _ = b.feed(.{ .left = side(15, .discharging), .right = side(null, .unknown) });
    res = b.feedAuthoritative(.{
        .left = side(89, .discharging),
        .right = side(null, .unknown),
    });
    try std.testing.expectEqual(@as(?u8, 89), res.reading.left.level);
    try std.testing.expect(!res.suspect);
    try std.testing.expect(!res.anyVerification());
}

test "Acceptor: held authoritative answers keep verification pending" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 90, .discharging);
    _ = feedLeft(&a, 15, .discharging);
    const held = [_]SideReading{
        side(null, .unknown),
        side(100, .disconnected),
        side(3, .fault),
        side(0, .discharging),
    };
    for (held) |h| {
        const res = a.feedAuthoritative(.{ .left = h, .right = side(null, .unknown) });
        try std.testing.expectEqual(@as(?u8, 90), res.reading.left.level);
        try std.testing.expect(res.needs_verification[0]);
    }
}

test "Acceptor: noteWake clears the pending streak and guards the sides" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 90, .discharging);
    // Two sightings of a pre-sleep suspect that must not carry across a wake.
    _ = feedLeft(&a, 60, .discharging);
    _ = feedLeft(&a, 60, .discharging);
    a.noteWake();
    try std.testing.expectEqual(@as(?u8, null), a.left.pending);
    try std.testing.expectEqual(@as(?u8, 90), a.left.accepted); // baseline survives
    // Post-wake the streak restarts and repetition no longer confirms.
    for (0..5) |_| {
        const res = feedLeft(&a, 60, .discharging);
        try std.testing.expectEqual(@as(?u8, 90), res.reading.left.level);
        try std.testing.expect(res.needs_verification[0]);
    }
}

test "Acceptor: wake guard makes any out-of-tolerance value need verification" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 50, .discharging);
    a.noteWake();
    // A high jump — not a low — still needs verification while guarded.
    for (0..5) |_| {
        const res = feedLeft(&a, 100, .discharging);
        try std.testing.expectEqual(@as(?u8, 50), res.reading.left.level);
        try std.testing.expect(res.needs_verification[0]);
    }
}

test "Acceptor: within-tolerance reading clears the wake guard" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 50, .discharging);
    a.noteWake();
    var res = feedLeft(&a, 49, .discharging);
    try std.testing.expectEqual(@as(?u8, 49), res.reading.left.level);
    try std.testing.expect(!res.needs_verification[0]);
    // Repetition rules are back to normal after the guard clears.
    _ = feedLeft(&a, 90, .discharging);
    _ = feedLeft(&a, 90, .discharging);
    res = feedLeft(&a, 90, .discharging);
    try std.testing.expectEqual(@as(?u8, 90), res.reading.left.level);
    try std.testing.expect(!res.anyVerification());
}

test "Acceptor: charging reading clears the wake guard" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 50, .discharging);
    a.noteWake();
    const res = feedLeft(&a, 80, .charging);
    try std.testing.expectEqual(@as(?u8, 80), res.reading.left.level);
    try std.testing.expect(!res.needs_verification[0]);
}

test "Acceptor: authoritative accept clears the wake guard" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 50, .discharging);
    a.noteWake();
    _ = feedLeft(&a, 100, .discharging);
    const res = a.feedAuthoritative(.{
        .left = side(97, .discharging),
        .right = side(null, .unknown),
    });
    try std.testing.expectEqual(@as(?u8, 97), res.reading.left.level);
    try std.testing.expect(!res.anyVerification());
}

test "Acceptor: noteWake without a baseline guards nothing" {
    // A side that has never reported (Sonsei's right channel, app started
    // post-wake) must not keep the forceRead retry loop alive forever.
    var a: Acceptor = .{};
    a.noteWake();
    try std.testing.expect(!a.left.wake_guard);
    try std.testing.expect(!a.right.wake_guard);
    // First readings still follow the no-baseline rules untainted.
    const res = feedLeft(&a, 87, .discharging);
    try std.testing.expectEqual(@as(?u8, 87), res.reading.left.level);
    try std.testing.expect(!res.anyVerification());
}

test "Acceptor: a never-reporting side does not hold verification open" {
    // One-sided model: only the left channel ever reports. After a wake the
    // guarded left resolves and verification must fully clear even though
    // the right side stays silent forever.
    var a: Acceptor = .{};
    _ = feedLeft(&a, 50, .discharging);
    a.noteWake();
    try std.testing.expect(!a.right.wake_guard);
    const res = feedLeft(&a, 50, .discharging);
    try std.testing.expect(!res.anyVerification());
}

test "Acceptor: needs_verification is per-side" {
    var a: Acceptor = .{};
    _ = a.feed(.{
        .left = side(90, .discharging),
        .right = side(80, .discharging),
    });
    const res = a.feed(.{
        .left = side(15, .discharging),
        .right = side(79, .discharging),
    });
    try std.testing.expect(res.needs_verification[0]);
    try std.testing.expect(!res.needs_verification[1]);
}
