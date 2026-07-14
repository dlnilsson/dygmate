//! Platform-agnostic tray state, polling loop, formatting, and color palette.
//! Shared by tray_windows.zig and tray_linux.zig so the discover -> connect ->
//! poll logic and the display formatting live in exactly one place.

const std = @import("std");
const focus = @import("focus.zig");
const battery = @import("battery.zig");
const device = @import("device.zig");
const layer = @import("layer.zig");

// ---------------------------------------------------------------------------
// Tunables (shared with both platforms).
// ---------------------------------------------------------------------------
pub const low_threshold: u8 = 20;
// Poll cadence. The wireless halves sleep and the neuron only serves a cached
// value once a side has reported, so a plain read right after connect is often
// empty. Poll fast until a side reports a real level (populates the tray within
// a few seconds of connect), then back off to battery.suggestedPollIntervalSeconds
// (30s–2min). Once a side has reported, a later empty read keeps the current
// cadence — last-known-good covers the display. Plain reads hit the
// USB-powered neuron only; they never wake the sides or wear flash.
pub const initial_poll_interval_ms: u64 = 5 * 1000;
pub const layer_poll_interval_ms: u64 = 250;

// ---------------------------------------------------------------------------
// Color palette. Platform-neutral RGB; each platform converts to its own
// pixel format (Windows: COLORREF 0x00BBGGRR; Linux: ARGB32).
// ---------------------------------------------------------------------------
pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const palette = struct {
    pub const green = Rgb{ .r = 46, .g = 160, .b = 67 };
    pub const amber = Rgb{ .r = 200, .g = 140, .b = 0 };
    pub const red = Rgb{ .r = 220, .g = 50, .b = 47 };
    pub const blue = Rgb{ .r = 41, .g = 128, .b = 185 };
    pub const gray = Rgb{ .r = 110, .g = 110, .b = 110 };
    pub const text = Rgb{ .r = 255, .g = 255, .b = 255 };
};

/// Icon background color for a display level. `live` is false when offline or
/// paused (dim to gray). Mirrors the Windows tray's original color ladder.
pub fn iconColor(live: bool, level: u8, status: battery.Status) Rgb {
    if (!live) return palette.gray;
    if (status == .charging) return palette.blue;
    if (level >= 50) return palette.green;
    if (level >= low_threshold) return palette.amber;
    return palette.red;
}

// ---------------------------------------------------------------------------
// Shared state between the UI thread and the polling thread.
// ---------------------------------------------------------------------------
pub const State = struct {
    mutex: std.Io.Mutex = .init,
    reading: ?battery.Reading = null,
    status: DeviceStatus = .missing,
    /// Detected keyboard model; null while absent. Written by the poll
    /// thread on every discovery pass (mutex-protected, like `reading`).
    model: ?device.Model = null,
    announce_connection: bool = false,
    stop: std.atomic.Value(bool) = .init(false),
    refresh: std.atomic.Value(bool) = .init(false),
    /// User asked us to release the port (so Bazecor can use it). The poll
    /// thread closes the connection and idles until this clears.
    paused: std.atomic.Value(bool) = .init(false),
    layer_change: std.atomic.Value(i32) = .init(-1),
    /// When false, the poll thread skips the layer read. Toggled from the tray
    /// menu on both platforms; Linux disables it at runtime without a usable
    /// Wayland layer-shell OSD.
    osd_enabled: std.atomic.Value(bool) = .init(true),
    /// UI-thread-only: latched per side (0=left, 1=right) so a low-battery
    /// notification fires once per crossing, not every poll.
    notified_low: [2]bool = .{ false, false },
};

pub const DeviceStatus = enum {
    missing,
    available,
    connected,
};

pub fn offlineStatus(present: bool) DeviceStatus {
    return if (present) .available else .missing;
}

pub fn isLive(status: DeviceStatus, paused: bool) bool {
    return status == .connected and !paused;
}

pub fn menuHeader(status: DeviceStatus, paused: bool) []const u8 {
    if (paused) return "Paused (port free for Bazecor)";
    return switch (status) {
        .missing => "No keyboard discovered",
        .available => "Keyboard discovered, not connected",
        .connected => "Connected",
    };
}

pub fn tooltipHeader(status: DeviceStatus, paused: bool) []const u8 {
    if (paused) return "Paused (port free for Bazecor):\n";
    return switch (status) {
        .missing => "No keyboard discovered - last known:\n",
        .available => "Keyboard discovered, not connected - last known:\n",
        .connected => "",
    };
}

// ---------------------------------------------------------------------------
// Last-known-good per-side snapshot (UI thread only).
// ---------------------------------------------------------------------------
/// The wireless halves sleep and report a null level and/or empty status
/// between polls; rather than show "?%", we keep the last real value for each
/// field independently. `level == null` / `status == .unknown` means that
/// field has never reported yet.
pub const LastKnown = struct {
    left: battery.SideReading = .{ .level = null, .status = .unknown },
    right: battery.SideReading = .{ .level = null, .status = .unknown },

    /// Merge a live reading, keeping each field's last real value: a sleeping
    /// half often answers one field (e.g. level=100) while the other comes
    /// back empty/unknown; clobbering a real "charging" with that "?" is the
    /// stale-status bug we avoid here.
    pub fn merge(self: *LastKnown, r: battery.Reading) void {
        if (r.left.level != null) self.left.level = r.left.level;
        if (r.left.status != .unknown) self.left.status = r.left.status;
        if (r.right.level != null) self.right.level = r.right.level;
        if (r.right.status != .unknown) self.right.status = r.right.status;
    }

    /// Lower of the two last-known side levels, with its status. `level` is
    /// null before either side has ever reported.
    pub fn display(self: LastKnown) battery.SideReading {
        var out: battery.SideReading = .{ .level = null, .status = .unknown };
        if (self.left.level) |l| {
            out.level = l;
            out.status = self.left.status;
        }
        if (self.right.level) |rl| {
            if (out.level == null or rl < out.level.?) {
                out.level = rl;
                out.status = self.right.status;
            }
        }
        return out;
    }
};

// ---------------------------------------------------------------------------
// Formatting helpers (no platform dependency).
// ---------------------------------------------------------------------------
/// Menu form of a last-known side snapshot: "{d}% (Status)" with a capitalized
/// status word to match the menu styling; "no reading yet" if never reported.
pub fn fmtMenuSide(buf: []u8, s: battery.SideReading) []const u8 {
    const lvl = s.level orelse return "no reading yet";
    const word = s.status.label();
    var cap: [16]u8 = undefined;
    const w = if (word.len > 0 and word.len <= cap.len) blk: {
        std.mem.copyForwards(u8, cap[0..word.len], word);
        cap[0] = std.ascii.toUpper(word[0]);
        break :blk cap[0..word.len];
    } else word;
    return std.fmt.bufPrint(buf, "{d}% ({s})", .{ lvl, w }) catch buf[0..0];
}

/// Tooltip/CLI form: "{d}% (status)" with a lowercase status word; "?%" if the
/// side has no level yet.
pub fn fmtSide(buf: []u8, s: battery.SideReading) []const u8 {
    if (s.level) |lvl| {
        return std.fmt.bufPrint(buf, "{d}% ({s})", .{ lvl, s.status.label() }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "?% ({s})", .{s.status.label()}) catch buf[0..0];
}

/// Tooltip form of a last-known side snapshot: the real value if the side has
/// ever reported, else a plain "no reading yet".
pub fn fmtKnownSide(buf: []u8, s: battery.SideReading) []const u8 {
    if (s.level) |lvl| {
        return std.fmt.bufPrint(buf, "{d}% ({s})", .{ lvl, s.status.label() }) catch buf[0..0];
    }
    return "no reading yet";
}

// ---------------------------------------------------------------------------
// Notifications: shared trigger/latch logic + text. Both platforms feed a
// merged snapshot to planNotifications and render the returned events with
// their own toolkit (Windows balloons, freedesktop Notifications on Linux).
// ---------------------------------------------------------------------------
/// Title of the connect-status notification, named after the detected
/// keyboard. Null model (e.g. --port override) falls back to the generic name.
pub fn notificationTitleStatus(model: ?device.Model) []const u8 {
    const m = model orelse return "Dygma battery level";
    return switch (m) {
        .defy_wireless => "Dygma Defy battery level",
        .raise2 => "Dygma Raise 2 battery level",
        .sonsei => "Dygma Sonsei battery level",
    };
}

/// Title of the low-battery notification; same shape as
/// `notificationTitleStatus`.
pub fn notificationTitleLow(model: ?device.Model) []const u8 {
    const m = model orelse return "Dygma battery low";
    return switch (m) {
        .defy_wireless => "Dygma Defy battery low",
        .raise2 => "Dygma Raise 2 battery low",
        .sonsei => "Dygma Sonsei battery low",
    };
}

/// A single notification to render. `connect_status` carries both-sides detail
/// (rendered from the snapshot); `low_battery` carries the offending side and
/// its level. `warning` selects the warning urgency/icon.
pub const NotifyEvent = struct {
    kind: enum { connect_status, low_battery },
    side: ?u1 = null, // low_battery only: 0 = left, 1 = right
    level: ?u8 = null, // low_battery only
    warning: bool = false,
};

pub const NotifyPlan = struct {
    /// At most one connect_status, or up to two low_battery events.
    events: [3]?NotifyEvent = .{ null, null, null },
    /// True when a connect announcement was emitted; the caller then clears
    /// its `announce_connection` flag under the state mutex.
    consumed_announce: bool = false,
};

/// All battery-reporting sides have a level — gates the connect announcement
/// and the poll backoff. Null model (e.g. --port override) assumes 2 sides.
pub fn levelsKnown(model: ?device.Model, r: battery.Reading) bool {
    if (r.left.level == null) return false;
    const m = model orelse return r.right.level != null;
    return m.sides() < 2 or r.right.level != null;
}

/// Any non-charging side below the low threshold — drives warning urgency on
/// the connect announcement.
pub fn hasLowBattery(r: battery.Reading) bool {
    const sides = [_]battery.SideReading{ r.left, r.right };
    for (sides) |s| {
        if (s.status == .charging) continue;
        const lvl = s.level orelse continue;
        if (lvl < low_threshold) return true;
    }
    return false;
}

/// Body of the connect-status notification: "Left: {s}\nRight: {s}" for a
/// 2-sided (or unknown) model; a 1-sided model renders just its single
/// battery, which reports on the left channel.
pub fn fmtStatusBody(buf: []u8, model: ?device.Model, r: battery.Reading) []const u8 {
    var lb: [32]u8 = undefined;
    if (model) |m| {
        if (m.sides() < 2) {
            return std.fmt.bufPrint(buf, "Battery: {s}", .{fmtSide(&lb, r.left)}) catch buf[0..0];
        }
    }
    var rb: [32]u8 = undefined;
    return std.fmt.bufPrint(buf, "Left: {s}\nRight: {s}", .{
        fmtSide(&lb, r.left),
        fmtSide(&rb, r.right),
    }) catch buf[0..0];
}

/// Body of a low-battery notification: "{Left|Right} side at {d}%"; a 1-sided
/// model has no side to name.
pub fn fmtLowBody(buf: []u8, model: ?device.Model, side: u1, level: u8) []const u8 {
    if (model) |m| {
        if (m.sides() < 2) {
            return std.fmt.bufPrint(buf, "Battery at {d}%", .{level}) catch buf[0..0];
        }
    }
    const name: []const u8 = if (side == 0) "Left" else "Right";
    return std.fmt.bufPrint(buf, "{s} side at {d}%", .{ name, level }) catch buf[0..0];
}

/// Decide which notifications to fire and mutate the per-side latch. Pure: no
/// platform calls. Mirrors the Windows updateTray decision flow exactly.
///
/// `announce_pending` is the pending connect-announcement flag.
/// `announce_ready` gates the announcement — it must be computed from the *raw*
/// reading (both raw levels present), not the merged snapshot, so a stale
/// last-known value can't fire the announcement early after a reconnect. The
/// announcement body and latch still render from the merged `snapshot`.
///
/// - pending + ready: emit connect_status, latch the lows, report consumed.
/// - pending + not ready: emit nothing, keep announce pending.
/// - not pending: per-side low check against the latch (fires once per crossing).
pub fn planNotifications(
    latch: *[2]bool,
    announce_pending: bool,
    announce_ready: bool,
    snapshot: battery.Reading,
) NotifyPlan {
    var plan = NotifyPlan{};
    const sides = [_]battery.SideReading{ snapshot.left, snapshot.right };

    if (announce_pending) {
        // A side hasn't reported a fresh level yet: stay pending, fire nothing.
        if (!announce_ready) return plan;

        plan.events[0] = .{ .kind = .connect_status, .warning = hasLowBattery(snapshot) };
        // Latch every side to its current low state so the announcement doesn't
        // double as a fresh low crossing on the next poll.
        for (sides, 0..) |s, i| {
            if (s.status == .charging) {
                latch[i] = false;
                continue;
            }
            const lvl = s.level orelse {
                latch[i] = false;
                continue;
            };
            latch[i] = lvl < low_threshold;
        }
        plan.consumed_announce = true;
        return plan;
    }

    // Per-side low crossing: fire once when a non-charging side drops below the
    // threshold; reset the latch when it charges or recovers.
    var idx: usize = 0;
    for (sides, 0..) |s, i| {
        if (s.status == .charging) {
            latch[i] = false;
            continue;
        }
        const lvl = s.level orelse continue;
        if (lvl < low_threshold) {
            if (!latch[i]) {
                latch[i] = true;
                plan.events[idx] = .{ .kind = .low_battery, .side = @intCast(i), .level = lvl, .warning = true };
                idx += 1;
            }
        } else {
            latch[i] = false;
        }
    }
    return plan;
}

// ---------------------------------------------------------------------------
// Background polling thread: owns the serial connection.
// ---------------------------------------------------------------------------
/// Run the discover -> connect -> poll loop. `wake(ctx)` notifies the UI that
/// a new reading (or connection-state change) is available: Windows posts a
/// window message; Linux writes an eventfd. When `osd_enabled` is false the
/// layer read is skipped.
pub fn runPollLoop(
    comptime Ctx: type,
    ctx: *Ctx,
    io: std.Io,
    gpa: std.mem.Allocator,
    st: *State,
    comptime wake: fn (*Ctx) void,
    comptime osd_enabled: bool,
) void {
    // Plausibility gate for battery levels. Deliberately OUTSIDE the
    // discover/connect loop: a reconnect after the machine (or the halves)
    // slept is exactly when the neuron's cache reports a bogus 100%, so the
    // baseline must survive reconnects. A genuinely different keyboard with a
    // higher battery just confirms over a few fast polls.
    var acceptor: battery.Acceptor = .{};
    // Set after a user-requested forceRead: the next reading is ground truth
    // and bypasses the gate.
    var next_read_authoritative = false;
    while (!st.stop.load(.acquire)) {
        // PAUSED: hold no port so Bazecor can use it; idle until resumed.
        if (st.paused.load(.acquire)) {
            const present = device.isDygmaPresent(io) catch false;
            resetLayerState(st);
            setStatus(Ctx, ctx, io, st, wake, offlineStatus(present));
            sleepMs(io, st, 300);
            continue;
        }

        // DISCOVER. One pass yields both presence and port: Windows scans the
        // serial layer once; Linux draws presence from sysfs and the port from
        // the serial layer (a plugged-in keyboard with no serial node yet is
        // present-without-port).
        const found = device.discoverDygma(io, gpa) catch device.Discovery{ .present = false };
        // Publish the detected model every pass: it names notifications and
        // picks 1- vs 2-sided rendering, and clearing it on absence keeps a
        // swapped keyboard from rendering under the old model's layout.
        st.mutex.lockUncancelable(io);
        st.model = found.model;
        st.mutex.unlock(io);
        if (!found.present) {
            if (found.port) |p| gpa.free(p);
            resetLayerState(st);
            setStatus(Ctx, ctx, io, st, wake, .missing);
            sleepMs(io, st, 3000);
            continue;
        }
        const path = found.port orelse {
            resetLayerState(st);
            setStatus(Ctx, ctx, io, st, wake, .available);
            sleepMs(io, st, 3000);
            continue;
        };
        defer gpa.free(path);

        // CONNECT
        var dev = focus.Focus.open(io, path) catch {
            const still_present = device.isDygmaPresent(io) catch true;
            resetLayerState(st);
            setStatus(Ctx, ctx, io, st, wake, offlineStatus(still_present));
            sleepMs(io, st, 3000);
            continue;
        };
        defer dev.close();
        var last_layer: ?u8 = null;
        // Per-connection last-known merge. On a plain read the neuron answers one
        // side at a time, so a single raw read almost never carries both levels;
        // merge across this connection so st.reading (and thus the connect
        // announcement and the backoff) see a complete picture. Fresh per connect
        // — nothing carries across a reconnect, so the announcement can't fire off
        // a stale value.
        var known: LastKnown = .{};
        // Start fast (immediate first read); back off once both sides report.
        var battery_interval_ms: u64 = initial_poll_interval_ms;
        var battery_elapsed_ms: u64 = battery_interval_ms;

        // POLL. No forceRead on connect: the neuron serves cached values on a
        // plain read, and forcing a re-poll every cycle blanks them mid-refresh.
        // forceRead runs only when the user asks to refresh (below).
        while (!st.stop.load(.acquire)) {
            if (st.paused.load(.acquire)) {
                const still_present = device.isDygmaPresent(io) catch true;
                resetLayerState(st);
                setStatus(Ctx, ctx, io, st, wake, offlineStatus(still_present));
                break;
            }
            var should_post = false;
            if (battery_elapsed_ms >= battery_interval_ms) {
                const raw = battery.read(&dev) catch {
                    const still_present = device.isDygmaPresent(io) catch false;
                    resetLayerState(st);
                    setStatus(Ctx, ctx, io, st, wake, offlineStatus(still_present));
                    break;
                };
                const res = if (next_read_authoritative)
                    acceptor.feedAuthoritative(raw)
                else
                    acceptor.feed(raw);
                next_read_authoritative = false;
                known.merge(res.reading);
                const merged: battery.Reading = .{ .left = known.left, .right = known.right };
                st.mutex.lockUncancelable(io);
                const announce_connection = st.status != .connected;
                st.reading = merged;
                st.status = .connected;
                if (announce_connection) st.announce_connection = true;
                st.mutex.unlock(io);
                // Back off only once every battery-reporting side has reported
                // this connection — the same gate as the connect announcement,
                // so slowing down can't leave the announcement pending for a
                // whole slow interval. Until then stay fast. `res.suspect`
                // comes from the FRESH read (not the merged snapshot), so an
                // unresolved suspect value always forces the fast interval
                // until it's confirmed or refuted.
                if (levelsKnown(found.model, merged)) {
                    battery_interval_ms = battery.suggestedPollIntervalSeconds(merged, res.suspect) * std.time.ms_per_s;
                }
                battery_elapsed_ms = 0;
                should_post = true;
            }

            if (osd_enabled and st.osd_enabled.load(.acquire)) {
                const active_layer = layer.readActive(&dev) catch {
                    const still_present = device.isDygmaPresent(io) catch false;
                    resetLayerState(st);
                    setStatus(Ctx, ctx, io, st, wake, offlineStatus(still_present));
                    break;
                };
                if (active_layer) |idx| {
                    if (last_layer) |prev| {
                        if (idx != prev) {
                            st.layer_change.store(idx, .release);
                            should_post = true;
                        }
                    }
                    last_layer = idx;
                }
            } else {
                last_layer = null;
            }

            if (should_post) wake(ctx);

            // Wait out the interval, staying responsive to stop/refresh/pause.
            const refreshed = waitForNextPoll(io, st, layer_poll_interval_ms);
            if (refreshed) {
                // A failed forceRead means the stream state is unknown (its
                // late response would answer the next command) — reconnect
                // rather than keep polling a desynced port.
                battery.forceRead(&dev) catch {
                    const still_present = device.isDygmaPresent(io) catch false;
                    resetLayerState(st);
                    setStatus(Ctx, ctx, io, st, wake, offlineStatus(still_present));
                    break;
                };
                sleepMs(io, st, battery.force_read_settle_s * 1000);
                next_read_authoritative = true;
                battery_elapsed_ms = battery_interval_ms; // force a read next cycle
            } else {
                battery_elapsed_ms += layer_poll_interval_ms;
            }
        }
    }
}

fn setStatus(
    comptime Ctx: type,
    ctx: *Ctx,
    io: std.Io,
    st: *State,
    comptime wake: fn (*Ctx) void,
    status: DeviceStatus,
) void {
    st.mutex.lockUncancelable(io);
    const changed = st.status != status;
    st.status = status;
    if (status != .connected) {
        st.reading = null;
        st.announce_connection = false;
    }
    st.mutex.unlock(io);
    if (changed) wake(ctx);
}

fn resetLayerState(st: *State) void {
    st.layer_change.store(-1, .release);
}

pub fn sleepMs(io: std.Io, st: *State, ms: u64) void {
    if (st.stop.load(.acquire)) return;
    const dur: std.Io.Clock.Duration = .{
        .clock = .awake,
        .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)),
    };
    dur.sleep(io) catch {};
}

/// Sleep out the poll interval, waking early on stop/pause/refresh. Returns
/// true only when a user refresh triggered the early wake, so the caller can
/// forceRead before the next read (stop/pause return false).
fn waitForNextPoll(io: std.Io, st: *State, interval_ms: u64) bool {
    var waited: u64 = 0;
    const quantum_ms: u64 = 1000;
    while (waited < interval_ms) {
        if (st.stop.load(.acquire)) return false;
        if (st.paused.load(.acquire)) return false;
        if (st.refresh.swap(false, .acq_rel)) return true;
        const remaining = interval_ms - waited;
        const sleep_ms = @min(remaining, quantum_ms);
        sleepMs(io, st, sleep_ms);
        waited += sleep_ms;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
fn reading(ll: ?u8, ls: battery.Status, rl: ?u8, rs: battery.Status) battery.Reading {
    return .{ .left = .{ .level = ll, .status = ls }, .right = .{ .level = rl, .status = rs } };
}

fn countEvents(plan: NotifyPlan) usize {
    var n: usize = 0;
    for (plan.events) |e| {
        if (e != null) n += 1;
    }
    return n;
}

test "planNotifications: low crossing fires once, latched afterwards" {
    var latch = [2]bool{ false, false };
    const snap = reading(15, .discharging, 80, .discharging);

    const first = planNotifications(&latch, false, false, snap);
    try std.testing.expectEqual(@as(usize, 1), countEvents(first));
    try std.testing.expectEqual(NotifyEvent{ .kind = .low_battery, .side = 0, .level = 15, .warning = true }, first.events[0].?);
    try std.testing.expect(latch[0]);

    // Same low reading again: latched, no re-fire.
    const second = planNotifications(&latch, false, false, snap);
    try std.testing.expectEqual(@as(usize, 0), countEvents(second));
}

test "planNotifications: recovery above threshold resets the latch" {
    var latch = [2]bool{ true, false };
    const plan = planNotifications(&latch, false, false, reading(50, .discharging, 90, .discharging));
    try std.testing.expectEqual(@as(usize, 0), countEvents(plan));
    try std.testing.expect(!latch[0]); // latch cleared, so a later drop fires again

    const again = planNotifications(&latch, false, false, reading(10, .discharging, 90, .discharging));
    try std.testing.expectEqual(@as(usize, 1), countEvents(again));
}

test "planNotifications: charging side never warns and resets the latch" {
    var latch = [2]bool{ true, true };
    const plan = planNotifications(&latch, false, false, reading(5, .charging, 8, .charging));
    try std.testing.expectEqual(@as(usize, 0), countEvents(plan));
    try std.testing.expect(!latch[0]);
    try std.testing.expect(!latch[1]);
}

test "planNotifications: both low sides fire two events" {
    var latch = [2]bool{ false, false };
    const plan = planNotifications(&latch, false, false, reading(10, .discharging, 19, .discharging));
    try std.testing.expectEqual(@as(usize, 2), countEvents(plan));
    try std.testing.expectEqual(@as(u1, 0), plan.events[0].?.side.?);
    try std.testing.expectEqual(@as(u1, 1), plan.events[1].?.side.?);
}

test "planNotifications: announce with both sides known emits status and latches lows" {
    var latch = [2]bool{ false, false };
    const plan = planNotifications(&latch, true, true, reading(15, .discharging, 90, .discharging));
    try std.testing.expectEqual(@as(usize, 1), countEvents(plan));
    try std.testing.expect(plan.events[0].?.kind == .connect_status);
    try std.testing.expect(plan.events[0].?.warning); // a side is low
    try std.testing.expect(plan.consumed_announce);
    try std.testing.expect(latch[0]); // low side latched by the announcement
    try std.testing.expect(!latch[1]);
}

test "planNotifications: announce with a healthy pair is not a warning" {
    var latch = [2]bool{ false, false };
    const plan = planNotifications(&latch, true, true, reading(80, .discharging, 90, .charging));
    try std.testing.expect(plan.events[0].?.kind == .connect_status);
    try std.testing.expect(!plan.events[0].?.warning);
    try std.testing.expect(plan.consumed_announce);
}

test "planNotifications: announce with a side unknown emits nothing and stays pending" {
    var latch = [2]bool{ false, false };
    const plan = planNotifications(&latch, true, false, reading(null, .unknown, 90, .discharging));
    try std.testing.expectEqual(@as(usize, 0), countEvents(plan));
    try std.testing.expect(!plan.consumed_announce);
}

test "planNotifications: announce gates on raw readiness, not the merged snapshot" {
    // Merged snapshot has both levels (a stale side survived a reconnect), but
    // the raw reading isn't ready yet: the announcement must stay pending.
    var latch = [2]bool{ false, false };
    const merged = reading(50, .discharging, 80, .discharging);
    const plan = planNotifications(&latch, true, false, merged);
    try std.testing.expectEqual(@as(usize, 0), countEvents(plan));
    try std.testing.expect(!plan.consumed_announce);
}

test "levelsKnown: 2-sided and null models need both sides, 1-sided needs left only" {
    const left_only = reading(80, .discharging, null, .unknown);
    const both = reading(80, .discharging, 90, .discharging);
    const none = reading(null, .unknown, null, .unknown);

    try std.testing.expect(!levelsKnown(.defy_wireless, left_only));
    try std.testing.expect(levelsKnown(.defy_wireless, both));
    try std.testing.expect(!levelsKnown(.raise2, left_only));
    try std.testing.expect(levelsKnown(.raise2, both));
    try std.testing.expect(levelsKnown(.sonsei, left_only));
    try std.testing.expect(!levelsKnown(.sonsei, none));
    try std.testing.expect(!levelsKnown(null, left_only));
    try std.testing.expect(levelsKnown(null, both));
}

test "fmtStatusBody: 1-sided model renders a single battery line" {
    var buf: [96]u8 = undefined;
    const r = reading(42, .discharging, null, .unknown);
    try std.testing.expectEqualStrings("Battery: 42% (discharging)", fmtStatusBody(&buf, .sonsei, r));
    try std.testing.expectEqualStrings(
        "Left: 42% (discharging)\nRight: ?% (?)",
        fmtStatusBody(&buf, .defy_wireless, r),
    );
    try std.testing.expectEqualStrings(
        "Left: 42% (discharging)\nRight: ?% (?)",
        fmtStatusBody(&buf, null, r),
    );
}

test "fmtLowBody: 1-sided model drops the side name" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Battery at 15%", fmtLowBody(&buf, .sonsei, 0, 15));
    try std.testing.expectEqualStrings("Left side at 15%", fmtLowBody(&buf, .raise2, 0, 15));
    try std.testing.expectEqualStrings("Right side at 15%", fmtLowBody(&buf, null, 1, 15));
}

test "notification titles name the detected keyboard" {
    try std.testing.expectEqualStrings("Dygma Defy battery level", notificationTitleStatus(.defy_wireless));
    try std.testing.expectEqualStrings("Dygma Raise 2 battery level", notificationTitleStatus(.raise2));
    try std.testing.expectEqualStrings("Dygma Sonsei battery low", notificationTitleLow(.sonsei));
    try std.testing.expectEqualStrings("Dygma battery level", notificationTitleStatus(null));
    try std.testing.expectEqualStrings("Dygma battery low", notificationTitleLow(null));
}

test "offlineStatus maps USB absence to missing" {
    try std.testing.expectEqual(DeviceStatus.missing, offlineStatus(false));
}

test "offlineStatus maps USB presence without port to available" {
    try std.testing.expectEqual(DeviceStatus.available, offlineStatus(true));
}

test "menuHeader distinguishes missing and available" {
    try std.testing.expectEqualStrings("No keyboard discovered", menuHeader(.missing, false));
    try std.testing.expectEqualStrings("Keyboard discovered, not connected", menuHeader(.available, false));
    try std.testing.expectEqualStrings("Connected", menuHeader(.connected, false));
}

test "tooltipHeader keeps paused wording and missing wording distinct" {
    try std.testing.expectEqualStrings("Paused (port free for Bazecor):\n", tooltipHeader(.missing, true));
    try std.testing.expectEqualStrings("No keyboard discovered - last known:\n", tooltipHeader(.missing, false));
    try std.testing.expectEqualStrings("Keyboard discovered, not connected - last known:\n", tooltipHeader(.available, false));
}
