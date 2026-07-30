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

    /// True while the cable is connected (charging or just-charged). FOCUS_API
    /// marks the fuel-gauge level inaccurate in these states, so low readings
    /// and low-battery alerts are gated on this rather than on `.charging`
    /// alone.
    pub fn onCable(self: Status) bool {
        return self == .charging or self == .charged;
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
pub const force_read_settle_s: u64 = 4;
/// Automatic forceRead verification retry schedule; first attempt fires
/// immediately, each further attempt waits the next entry (last repeats).
pub const verify_backoff_s = [_]u64{ 5, 15, 45, 120 };

/// Issue the four battery read commands. Empty level/status payloads are
/// routine "no cached value yet" answers and degrade to null/unknown, but
/// command-shaped mismatches are fatal: if a status, layer, or forceRead reply
/// answers a later battery command, the serial stream is desynced and the
/// caller must reconnect. Status is still read AFTER both levels so it never
/// sits between the two required level reads in a successful cycle. Reads the
/// neuron's cached values — callers should use `read` for the disconnected-side
/// retry.
pub fn readAll(f: *focus.Focus) focus.Error!Reading {
    var buf: [256]u8 = undefined;
    // Both levels first (required, order matters — a status read is best-effort
    // and must not sit between the two level reads).
    const left_level = try parseLevelStrict(try f.request("wireless.battery.left.level", &buf));
    const right_level = try parseLevelStrict(try f.request("wireless.battery.right.level", &buf));
    return .{
        .left = .{ .level = left_level, .status = try readStatus(f, "wireless.battery.left.status", &buf) },
        .right = .{ .level = right_level, .status = try readStatus(f, "wireless.battery.right.status", &buf) },
    };
}

/// Read one side's status. The status value is optional, but the exchange is
/// not: a timeout, port error, or response-shape mismatch means the abandoned
/// reply can answer a later command (e.g. status "4" as a 4% level), so the
/// caller reconnects instead of continuing on this stream. A clean empty
/// payload still parses to `.unknown`.
fn readStatus(f: *focus.Focus, cmd: []const u8, buf: []u8) focus.Error!Status {
    return parseStatusStrict(try f.request(cmd, buf));
}

/// One poll of both halves, with Bazecor's single retry: if either side comes
/// back "disconnected" (status 4) the RF link to that half briefly dropped, so
/// wait 500ms and read once more. Deliberately NO forceRead here — the neuron
/// serves cached values on a plain read, and forcing a re-poll every cycle
/// blanks those values mid-refresh (empty responses) and hammers the sleeping
/// sides' RF link. Mirrors battery.Read in the Go tray; forceRead is a manual,
/// user-triggered action only (see forceRead below).
pub fn read(f: *focus.Focus) focus.Error!Reading {
    const first = try readAll(f);
    if (first.left.status != .disconnected and first.right.status != .disconnected) return first;
    sleepMs(f.io, 500);
    // A transport error mid-retry poisons the stream: the abandoned command's
    // response arrives later and answers the NEXT command, shifting every
    // response after it by one (a status "2" then parses as a 2% level).
    // Propagate so the caller reconnects — reopening flushes the port.
    const second = try readAll(f);
    return .{
        .left = mergeRetrySide(first.left, second.left),
        .right = mergeRetrySide(first.right, second.right),
    };
}

/// Merge one side across the disconnect-retry pair. The retry exists to catch
/// a momentary RF drop that recovered (its fresh fields win), but its answers
/// are often empty — an empty retry field must not erase the first read's
/// explicit "4", or the Acceptor never learns the side is disconnected and
/// accepts the stale cached level that "4" just exposed.
fn mergeRetrySide(first: SideReading, second: SideReading) SideReading {
    return .{
        .level = second.level orelse first.level,
        .status = if (second.status == .unknown) first.status else second.status,
    };
}

/// Ask the neuron to re-poll both sides over RF (Bazecor's "Force read"
/// button). Argument-less, so it writes no EEPROM, but it generates RF traffic
/// and briefly blanks the cached values — call it only on an explicit user
/// refresh, never in the poll loop. Mirrors battery.ForceRead in the Go tray.
/// Errors must propagate: an abandoned forceRead leaves its late response in
/// the RX queue, desyncing every later exchange on this connection.
pub fn forceRead(f: *focus.Focus) focus.Error!void {
    var buf: [64]u8 = undefined;
    const resp = try f.request("wireless.battery.forceRead", &buf);
    if (std.mem.trim(u8, resp, " \t\r\n").len != 0) return error.InvalidResponse;
}

fn sleepMs(io: std.Io, ms: u64) void {
    const dur: std.Io.Clock.Duration = .{
        .clock = .awake,
        .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)),
    };
    dur.sleep(io) catch {};
}

/// Plausibility gate for battery levels. While a half is asleep or out of RF
/// contact the neuron persistently serves a bogus cached 100% on every plain
/// read — not transiently, but until the half actually wakes — so a
/// disconnected side's level is never evidence of anything and is ignored
/// outright. The "disconnected" status itself only peeks through on some of
/// those reads (most carry an empty status), so an explicit "4" also latches
/// the side (`SideState.disconnected`), drops its pending streak (any level
/// repetition around a disconnect is cache repetition), and keeps
/// unknown-status levels distrusted until an explicit live status returns. Around sleep/wake transitions the
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
/// settles it. Charging/charged sides are trusted outright only at/above the
/// low threshold (the sides really do charge over cable while the user is
/// away); a sub-threshold charging level is the gauge's documented-inaccurate
/// range and is held for verification like any low so it can't bake a false low
/// into the baseline. Pure state machine:
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
        /// Set by an explicit "disconnected" status (4): the side is out of
        /// RF contact and the neuron serves a stale cached level for it on
        /// every read — usually with an EMPTY status, so the disconnect is
        /// only visible on the occasional read where the "4" peeks through.
        /// While set, a level arriving with an unknown status is the same
        /// stale cache and is ignored like a disconnected one. Cleared by
        /// any explicit live status (discharging/charging/charged).
        disconnected: bool = false,
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
            // no-baseline rules already hold an initial 100 or an initial low
            // for authoritative verification), and guarding it would keep the
            // forceRead retry loop alive forever on models where that side
            // never reports at all (Sonsei's right channel).
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
    /// cross below the low threshold (never confirmable by cache repetition),
    /// while it is wake-guarded (guard clears only on an accepted level, so a
    /// side that stays silent after a wake keeps the retry loop alive), or
    /// whenever it holds a pending value with no accepted baseline yet: there
    /// is nothing to fall back to and plain-read repetition of that value is
    /// just the same neuron cache re-served, so only a forceRead can settle it
    /// (an initial 100 — the bogus asleep-cache value — or an initial low both
    /// land here). A side that never reports a level never builds a pending
    /// value, so this can't keep the retry loop alive on a silent channel.
    fn sideNeedsVerification(st: SideState) bool {
        if (st.wake_guard) return true;
        const p = st.pending orelse return false;
        if (st.accepted == null) return true;
        return p < low_level_fast_threshold;
    }

    fn feedSide(st: *SideState, raw: SideReading) SideReading {
        switch (raw.status) {
            // An explicit "4": the side is out of RF contact, so its level is
            // the neuron's stale cache — and so were any recent levels that
            // arrived with an empty status. Drop the pending streak (cache
            // repetition must never confirm) and latch the side disconnected
            // until an explicit live status proves it back.
            .disconnected => {
                st.disconnected = true;
                st.pending = null;
                st.pending_count = 0;
                return .{ .level = st.accepted, .status = raw.status };
            },
            // Any explicit live status is proof the side answers again.
            .discharging, .charging, .charged => st.disconnected = false,
            .fault, .unknown => {},
        }
        // A sleeping half answers with an empty payload; that's routine, not
        // evidence for or against a pending suspect — keep the streak.
        const lvl = raw.level orelse
            return .{ .level = st.accepted, .status = raw.status };
        // Fault means "faulty or has some reading error" (FOCUS_API), so its
        // level may be garbage — ignore it exactly like an empty payload: no
        // accept, no baseline, no streak advance.
        if (raw.status == .fault)
            return .{ .level = st.accepted, .status = raw.status };
        // While disconnect-latched, a level with an empty status is usually the
        // stale cache the explicit "4" just exposed (the neuron serves it
        // persistently, mostly WITHOUT the status). A value that MATCHES the
        // accepted baseline (within tolerance) is that cache — hold it silently.
        // A value that DIFFERS is not the cache the "4" exposed: the side may be
        // back and peeking a real reading through a stale latch, so flag it
        // suspect (fast-poll) rather than confidently showing the baseline as if
        // it were still confirmed. It is never accepted by plain repetition
        // (confirm=null) and, with a baseline present, never arms forceRead for
        // a possibly-absent latched side — only an explicit live status resolves
        // the latch. With no baseline there is nothing to differ from, so the
        // read stays ignored like any other disconnect cache.
        if (raw.status == .unknown and st.disconnected) {
            const acc = st.accepted orelse
                return .{ .level = st.accepted, .status = raw.status };
            const diff = if (lvl > acc) lvl - acc else acc - lvl;
            if (diff <= level_jump_tolerance)
                return .{ .level = st.accepted, .status = raw.status };
            return suspectSide(st, raw, null);
        }
        if (raw.status.onCable()) {
            // A level at/above the low threshold (and any upward charging
            // progress) is trusted outright — the side really does gain charge
            // over the cable.
            if (lvl >= low_level_fast_threshold) return acceptSide(st, raw);
            // Below the low threshold the gauge is in its documented-inaccurate
            // range (FOCUS_API): its misreads skew low. Accepting one would bake
            // a false low into the baseline and fire a low-battery alert once
            // the status reads back non-charging. A value within tolerance of an
            // already-accepted low is that same stable low re-reported — keep it
            // (never re-verify). Otherwise hold it for an authoritative
            // post-forceRead read, exactly like a low discharging reading;
            // plain-read repetition of a bad gauge value can never confirm it.
            if (st.accepted) |acc| {
                const diff = if (lvl > acc) lvl - acc else acc - lvl;
                if (diff <= level_jump_tolerance) return acceptSide(st, raw);
            }
            return suspectSide(st, raw, null);
        }
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
        // No baseline to jump-gate against. A mid-range reading is taken at
        // face value — like Bazecor, which shows the neuron's live plain read
        // directly. The two suspicious ends are held for an authoritative
        // forceRead read rather than trusted off plain reads: an initial 100 is
        // exactly the bogus value the neuron serves for an asleep/absent side,
        // and an initial low may be a stale pre-sleep cache after an app restart
        // (it must never fire a low-battery notification off plain reads).
        // Plain-read repetition of either is the same cache re-served and can
        // never confirm it — sideNeedsVerification arms the forceRead loop for
        // any pending value with no baseline, and a genuinely-awake keyboard
        // settles in a single authoritative read.
        if (lvl >= low_level_fast_threshold and lvl < 100) return acceptSide(st, raw);
        return suspectSide(st, raw, null);
    }

    fn acceptAuthoritativeSide(st: *SideState, raw: SideReading) SideReading {
        switch (raw.status) {
            // The re-poll did NOT reach this side: same as the plain-read
            // path — its level is stale cache, and the pending streak that
            // asked for this verification was built on that cache too.
            .disconnected => {
                st.disconnected = true;
                st.pending = null;
                st.pending_count = 0;
                return .{ .level = st.accepted, .status = raw.status };
            },
            .discharging, .charging, .charged => st.disconnected = false,
            .fault, .unknown => {},
        }
        if (raw.status == .fault)
            return .{ .level = st.accepted, .status = raw.status };
        // Latched with no status: the re-poll gave no proof the side is back,
        // so its level is not ground truth — hold like the plain-read path.
        if (raw.status == .unknown and st.disconnected)
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
    return parseLevelStrict(payload) catch null;
}

fn parseLevelStrict(payload: []const u8) focus.Error!?u8 {
    const t = std.mem.trim(u8, payload, " \t\r\n");
    if (t.len == 0) return null;
    var it = std.mem.tokenizeAny(u8, t, " \t\r\n");
    const tok = it.next() orelse return null;
    if (it.next() != null) return error.InvalidResponse;
    // The firmware reports raw hex ("0x...") while a reading is invalid;
    // Bazecor treats those as no-value too.
    if (std.mem.indexOf(u8, tok, "0x") != null) return null;
    const v = std.fmt.parseInt(u8, tok, 10) catch return error.InvalidResponse;
    return if (v <= 100) v else null;
}

pub fn parseStatus(payload: []const u8) Status {
    return parseStatusStrict(payload) catch .unknown;
}

fn parseStatusStrict(payload: []const u8) focus.Error!Status {
    const t = std.mem.trim(u8, payload, " \t\r\n");
    // An empty status response is `.unknown`, not a disconnect: the neuron
    // intermittently returns nothing for a read even while both halves are
    // connected and in use (a transient false negative / RF lag). `.unknown`
    // is skipped by the last-known merges, so such a read holds the last real
    // value instead of flipping the tray to "?". A genuine disconnect reports
    // the explicit code "4".
    if (t.len == 0) return .unknown;
    var it = std.mem.tokenizeAny(u8, t, " \t\r\n");
    const tok = it.next() orelse return .unknown;
    // A second token is the same command-shape mismatch parseLevelStrict
    // guards against (e.g. a bled-through layer.state line) — fatal.
    if (it.next() != null) return error.InvalidResponse;
    const v = std.fmt.parseInt(u8, tok, 10) catch return error.InvalidResponse;
    return switch (v) {
        0 => .discharging,
        1 => .charging,
        2 => .charged,
        3 => .fault,
        4 => .disconnected,
        // An in-range but undefined code is a single well-shaped value, just
        // like a level >100 — mirror parseLevelStrict and treat it as no
        // information rather than fatal; there's no way to tell an unused
        // firmware code from a genuine future one.
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

test "parseLevelStrict rejects cross-command payloads" {
    try std.testing.expectEqual(@as(?u8, null), try parseLevelStrict(""));
    try std.testing.expectEqual(@as(?u8, 4), try parseLevelStrict("4"));
    try std.testing.expectEqual(@as(?u8, 100), try parseLevelStrict("100"));
    try std.testing.expectError(error.InvalidResponse, parseLevelStrict("0 0 0 0"));
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

test "parseStatus trims surrounding whitespace" {
    // The firmware pads some responses ("4 "); the trim keeps them mapping.
    try std.testing.expectEqual(Status.disconnected, parseStatus("4 "));
    try std.testing.expectEqual(Status.charging, parseStatus(" 1\r\n"));
}

test "parseStatus treats an empty/unparseable response as unknown" {
    // Empty is a transient neuron false negative, not a disconnect — `.unknown`
    // is skipped by the last-known merges, so it holds the last real value.
    try std.testing.expectEqual(Status.unknown, parseStatus(""));
    try std.testing.expectEqual(Status.unknown, parseStatus("   "));
    try std.testing.expectEqual(Status.unknown, parseStatus("\r\n"));
}

test "parseStatusStrict rejects cross-command shape but tolerates undefined codes" {
    try std.testing.expectEqual(Status.unknown, try parseStatusStrict(""));
    try std.testing.expectEqual(Status.discharging, try parseStatusStrict("0"));
    try std.testing.expectEqual(Status.disconnected, try parseStatusStrict("4"));
    // In-range and well-shaped, just an undefined code — same treatment as
    // an out-of-range level, not a fatal shape mismatch.
    try std.testing.expectEqual(Status.unknown, try parseStatusStrict("100"));
    try std.testing.expectError(error.InvalidResponse, parseStatusStrict("0 0 0"));
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

test "Acceptor: an initial 100 is held for authoritative verification, never confirmed by repetition" {
    var a: Acceptor = .{};
    // Plain-read repetition of the bogus asleep-cache 100 never confirms it —
    // repetition of a cache adds no information, so it stays held and pending.
    for (0..5) |_| {
        const res = feedLeft(&a, 100, .discharging);
        try std.testing.expectEqual(@as(?u8, null), res.reading.left.level);
        try std.testing.expect(res.suspect);
        try std.testing.expect(res.needs_verification[0]);
    }
    // A forceRead read settles it — a genuinely-charged awake keyboard really
    // reads 100 — so the tray shows the value only once it's authoritative.
    const res = a.feedAuthoritative(.{ .left = side(100, .discharging), .right = side(null, .unknown) });
    try std.testing.expectEqual(@as(?u8, 100), res.reading.left.level);
    try std.testing.expect(!res.anyVerification());

    // Charging is trusted outright at/above the low threshold; the cable path
    // is unchanged.
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

test "Acceptor: an explicit disconnect resets the pending streak" {
    var a: Acceptor = .{};
    _ = feedLeft(&a, 45, .discharging);
    _ = feedLeft(&a, 100, .discharging); // pending 100, count 1
    _ = feedLeft(&a, 100, .discharging); // count 2 — one short of confirming
    // A "4" reveals those 100s as disconnect cache: the streak is dropped,
    // so the next sighting cannot be the confirming third.
    var res = feedLeft(&a, 100, .disconnected);
    try std.testing.expectEqual(@as(?u8, 45), res.reading.left.level);
    try std.testing.expect(!res.suspect);
    // Live-status sightings restart the streak from scratch.
    _ = feedLeft(&a, 100, .discharging);
    res = feedLeft(&a, 100, .discharging);
    try std.testing.expectEqual(@as(?u8, 45), res.reading.left.level);
    try std.testing.expect(res.suspect);
    res = feedLeft(&a, 100, .discharging); // third consecutive live sighting
    try std.testing.expectEqual(@as(?u8, 100), res.reading.left.level);
    try std.testing.expect(!res.suspect);
}

test "Acceptor: after a disconnect, a matching cached level stays quiet but a differing one is flagged" {
    // The tail-log failure mode: the neuron reports "4" once, then keeps
    // serving a cached level with an EMPTY status on later polls. A value that
    // DIFFERS from the baseline is not the cache the "4" exposed (a stale cache
    // repeats the accepted value) — it may be the side peeking a real reading
    // through the latch, so it is flagged suspect while the last accepted value
    // is still held for display. It is never accepted by plain repetition and
    // never arms forceRead for a latched (possibly-absent) side.
    var a: Acceptor = .{};
    _ = feedLeft(&a, 40, .discharging);
    _ = feedLeft(&a, 100, .disconnected);
    for (0..5) |_| {
        const res = feedLeft(&a, 100, .unknown);
        try std.testing.expectEqual(@as(?u8, 40), res.reading.left.level);
        try std.testing.expect(res.suspect);
        try std.testing.expect(!res.needs_verification[0]);
    }
    // An explicit live status clears the latch; normal gating resumes.
    const res = feedLeft(&a, 39, .discharging);
    try std.testing.expectEqual(@as(?u8, 39), res.reading.left.level);
    try std.testing.expect(!res.suspect);
}

test "Acceptor: a latched level matching the baseline stays quiet" {
    // The ordinary disconnect case: a half drops RF and the neuron keeps
    // serving its last real level. That matches the baseline, so it is the
    // stale cache and must stay silent (no perpetual suspect on an off half).
    var a: Acceptor = .{};
    _ = feedLeft(&a, 90, .discharging);
    _ = feedLeft(&a, 90, .disconnected); // latch on the true baseline
    for (0..5) |_| {
        const res = feedLeft(&a, 90, .unknown);
        try std.testing.expectEqual(@as(?u8, 90), res.reading.left.level);
        try std.testing.expect(!res.suspect);
        try std.testing.expect(!res.needs_verification[0]);
    }
    // A differing value peeking through the latch: held, but flagged suspect.
    const res = feedLeft(&a, 50, .unknown);
    try std.testing.expectEqual(@as(?u8, 90), res.reading.left.level);
    try std.testing.expect(res.suspect);
    try std.testing.expect(!res.needs_verification[0]);
}

test "Acceptor: read-retry merge keeps the first read's disconnect evidence" {
    // The 500ms retry often answers with all-empty fields; the merged reading
    // must still carry the first attempt's "4" (and its level for context).
    const merged = mergeRetrySide(
        side(100, .disconnected),
        side(null, .unknown),
    );
    try std.testing.expectEqual(@as(?u8, 100), merged.level);
    try std.testing.expectEqual(Status.disconnected, merged.status);
    // A retry that recovered wins with its fresh fields.
    const recovered = mergeRetrySide(
        side(100, .disconnected),
        side(42, .discharging),
    );
    try std.testing.expectEqual(@as(?u8, 42), recovered.level);
    try std.testing.expectEqual(Status.discharging, recovered.status);
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

test "Acceptor: a sub-threshold charging level is held, not trusted outright" {
    // FOCUS_API marks the gauge inaccurate on the cable; a below-low-threshold
    // charging reading is that bogus range and must never bake a false low into
    // the baseline (that's what later fires a spurious low-battery alert).
    var a: Acceptor = .{};
    _ = feedLeft(&a, 45, .discharging);
    for ([_]Status{ .charging, .charged }) |cable| {
        for ([_]?u8{ 0, 1, 5 }) |lvl| {
            const res = feedLeft(&a, lvl, cable);
            try std.testing.expectEqual(@as(?u8, 45), res.reading.left.level);
            try std.testing.expect(res.suspect);
            try std.testing.expect(res.needs_verification[0]);
        }
    }
}

test "Acceptor: a first-ever sub-threshold charging reading needs verification" {
    // No baseline yet: an initial charging low is held for an authoritative
    // read rather than accepted (a bogus post-connect cache reads low too).
    var a: Acceptor = .{};
    var res = feedLeft(&a, 3, .charging);
    try std.testing.expectEqual(@as(?u8, null), res.reading.left.level);
    try std.testing.expect(res.needs_verification[0]);
    // An authoritative read settles it (charging genuinely reads that low), so
    // the forceRead retry loop can end.
    res = a.feedAuthoritative(.{ .left = side(3, .charging), .right = side(null, .unknown) });
    try std.testing.expectEqual(@as(?u8, 3), res.reading.left.level);
    try std.testing.expect(!res.anyVerification());
}

test "Acceptor: an already-accepted charging low keeps showing without re-verifying" {
    // A genuinely low-and-charging side (settled authoritatively) must keep
    // rendering and must not re-arm forceRead on every stable/near poll.
    var a: Acceptor = .{};
    _ = feedLeft(&a, 90, .discharging);
    _ = feedLeft(&a, 5, .discharging); // held low
    _ = a.feedAuthoritative(.{ .left = side(5, .discharging), .right = side(null, .unknown) });
    for ([_]u8{ 5, 6, 4 }) |lvl| { // stable + a point of charge either way
        const res = feedLeft(&a, lvl, .charging);
        try std.testing.expectEqual(@as(?u8, lvl), res.reading.left.level);
        try std.testing.expect(!res.suspect);
        try std.testing.expect(!res.needs_verification[0]);
    }
}

test "Acceptor: a charging level at/above the low threshold still accepts outright" {
    // Regression guard: the charging fast-path for plausible/upward levels is
    // untouched — only the sub-threshold case is gated.
    var a: Acceptor = .{};
    _ = feedLeft(&a, 45, .discharging);
    var res = feedLeft(&a, 80, .charging);
    try std.testing.expectEqual(@as(?u8, 80), res.reading.left.level);
    try std.testing.expect(!res.suspect);
    res = feedLeft(&a, 90, .charged);
    try std.testing.expectEqual(@as(?u8, 90), res.reading.left.level);
    try std.testing.expect(!res.suspect);
}

test "Status.onCable is true only for charging and charged" {
    try std.testing.expect(Status.charging.onCable());
    try std.testing.expect(Status.charged.onCable());
    try std.testing.expect(!Status.discharging.onCable());
    try std.testing.expect(!Status.fault.onCable());
    try std.testing.expect(!Status.disconnected.onCable());
    try std.testing.expect(!Status.unknown.onCable());
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
        side(3, .fault),
        side(0, .discharging),
    };
    for (held) |h| {
        const res = a.feedAuthoritative(.{ .left = h, .right = side(null, .unknown) });
        try std.testing.expectEqual(@as(?u8, 90), res.reading.left.level);
        try std.testing.expect(res.needs_verification[0]);
    }
}

test "Acceptor: an authoritative disconnect settles verification by dropping the pending value" {
    // The re-poll proved the side unreachable: the pending low was disconnect
    // cache, not evidence — verification must stop (retrying forceRead at an
    // absent half only hammers RF) and the held value must never display.
    var a: Acceptor = .{};
    _ = feedLeft(&a, 90, .discharging);
    _ = feedLeft(&a, 15, .discharging);
    const res = a.feedAuthoritative(.{
        .left = side(100, .disconnected),
        .right = side(null, .unknown),
    });
    try std.testing.expectEqual(@as(?u8, 90), res.reading.left.level);
    try std.testing.expectEqual(Status.disconnected, res.reading.left.status);
    try std.testing.expect(!res.anyVerification());
    // Latched: the post-refresh cache echo with an empty status stays held.
    const echo = a.feedAuthoritative(.{
        .left = side(100, .unknown),
        .right = side(null, .unknown),
    });
    try std.testing.expectEqual(@as(?u8, 90), echo.reading.left.level);
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
