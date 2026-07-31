//! Platform-agnostic tray state, polling loop, formatting, and color palette.
//! Shared by tray_windows.zig and tray_linux.zig so the discover -> connect ->
//! poll logic and the display formatting live in exactly one place.

const std = @import("std");
const builtin = @import("builtin");
const focus = @import("focus.zig");
const battery = @import("battery.zig");
const device = @import("device.zig");
const layer = @import("layer.zig");
const statusserver = @import("statusserver.zig");

// ---------------------------------------------------------------------------
// Tunables (shared with both platforms).
// ---------------------------------------------------------------------------
pub const low_threshold = statusserver.low_threshold;
// Poll cadence. The wireless halves sleep and the neuron only serves a cached
// value once a side has reported, so a plain read right after connect is often
// empty. Poll fast until a side reports a real level (populates the tray within
// a few seconds of connect), then back off to battery.suggestedPollIntervalSeconds
// (30s–2min). Once a side has reported, a later empty read keeps the current
// cadence — last-known-good covers the display. Plain reads hit the
// USB-powered neuron only; they never wake the sides or wear flash.
pub const initial_poll_interval_ms: u64 = 5 * 1000;
pub const layer_poll_interval_ms: u64 = 250;
/// A suspend gap (sleep/hibernation) longer than this arms the acceptor's
/// wake guard: the neuron's cache may hold bogus values after such a gap.
pub const wake_gap_threshold_ms: u64 = 10_000;

// ---------------------------------------------------------------------------
// Wake detection.
// ---------------------------------------------------------------------------
/// Detects that the machine slept by comparing a suspend-inclusive with a
/// suspend-exclusive monotonic clock: their difference grows only while the
/// machine is suspended, so a jump in that difference between two checks is
/// exactly the time spent asleep in between. Robust against slow polling —
/// awake time cancels out.
pub const WakeDetector = struct {
    prev_suspended_ms: ?u64 = null,

    pub const Samples = struct {
        /// Monotonic milliseconds including suspended time.
        incl_ms: u64,
        /// Monotonic milliseconds excluding suspended time.
        excl_ms: u64,
    };

    /// Pure core: true when the suspended time accumulated since the previous
    /// feed exceeds the gap threshold. The first feed never fires — there is
    /// no previous sample to compare against.
    pub fn feed(self: *WakeDetector, s: Samples) bool {
        const suspended = s.incl_ms -| s.excl_ms;
        defer self.prev_suspended_ms = suspended;
        const prev = self.prev_suspended_ms orelse return false;
        return suspended -| prev > wake_gap_threshold_ms;
    }

    pub fn check(self: *WakeDetector, io: std.Io) bool {
        return self.feed(sampleSuspendClocks(io));
    }
};

/// One sample of the suspend-inclusive/-exclusive clock pair.
///
/// Windows cannot use the Io clocks for this: in std.Io.Threaded both
/// `.awake` and `.boot` read the same QPC source, so their difference is
/// always ~0 there. GetTickCount64 includes suspend + hibernation;
/// QueryUnbiasedInterruptTime (100ns units) excludes both.
fn sampleSuspendClocks(io: std.Io) WakeDetector.Samples {
    if (comptime builtin.os.tag == .windows) {
        var unbiased_100ns: u64 = 0;
        _ = QueryUnbiasedInterruptTime(&unbiased_100ns);
        return .{
            .incl_ms = GetTickCount64(),
            .excl_ms = unbiased_100ns / 10_000,
        };
    }
    // Elsewhere the Io clocks are distinct sources: `.boot` (CLOCK_BOOTTIME
    // on Linux) includes suspend, `.awake` (CLOCK_MONOTONIC) excludes it.
    const boot = std.Io.Clock.Timestamp.now(io, .boot);
    const awake = std.Io.Clock.Timestamp.now(io, .awake);
    return .{
        .incl_ms = @intCast(@divTrunc(boot.raw.nanoseconds, std.time.ns_per_ms)),
        .excl_ms = @intCast(@divTrunc(awake.raw.nanoseconds, std.time.ns_per_ms)),
    };
}

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn QueryUnbiasedInterruptTime(unbiased_time: *u64) callconv(.winapi) std.os.windows.BOOL;

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
    // On the cable (charging or full) the icon is blue — the gauge level is
    // unreliable there (FOCUS_API), so the red/amber "low" rungs would be
    // misleading while the keyboard is plugged in.
    if (status.onCable()) return palette.blue;
    if (level >= 50) return palette.green;
    if (level >= low_threshold) return palette.amber;
    return palette.red;
}

/// Source resolution of the embedded battery glyphs (see tools/gen_battery.zig).
pub const battery_src_px: usize = 32;

/// Anti-aliased white battery glyphs, [R,G,B,A] per pixel (RGB white, A =
/// coverage), 32×32, generated by `zig run tools/gen_battery.zig` and embedded
/// so the tray needs no PNG decoder at runtime. The literal 🔋 emoji can't be
/// used (Linux has no font engine, Windows GDI can't render color emoji), so we
/// composite these assets over the icon background instead. `full` (a solid
/// battery, 🔋) is drawn when both sides read 100%; `charging` (the same body
/// with a lightning-bolt knockout) is drawn while a side charges.
pub const battery_full_rgba = @embedFile("assets/battery.rgba");
pub const battery_charging_rgba = @embedFile("assets/battery_charging.rgba");

comptime {
    const expect = battery_src_px * battery_src_px * 4;
    if (battery_full_rgba.len != expect or battery_charging_rgba.len != expect)
        @compileError("battery*.rgba size mismatch — re-run tools/gen_battery.zig");
}

/// Coverage alpha (0..255) of the glyph `src` at output pixel (x, y) on an n×n
/// icon, area-averaged down from the 32×32 source (n ≤ 32). Pure, so both trays
/// render an identical glyph at their own size (Windows 16px, Linux 22px).
pub fn glyphAlpha(src: []const u8, n: usize, x: usize, y: usize) u8 {
    const s = battery_src_px;
    const sx0 = x * s / n;
    const sx1 = @max(sx0 + 1, (x + 1) * s / n);
    const sy0 = y * s / n;
    const sy1 = @max(sy0 + 1, (y + 1) * s / n);
    var sum: usize = 0;
    var cnt: usize = 0;
    var sy = sy0;
    while (sy < sy1) : (sy += 1) {
        var sx = sx0;
        while (sx < sx1) : (sx += 1) {
            sum += src[(sy * s + sx) * 4 + 3];
            cnt += 1;
        }
    }
    return @intCast(sum / cnt);
}

/// A glyph pixel at (x, y) on an n×n icon: the white glyph `src`
/// alpha-composited over `bg`. A transparent source pixel returns `bg` unchanged.
pub fn batteryPixel(src: []const u8, n: usize, x: usize, y: usize, bg: Rgb) Rgb {
    return blend(bg, palette.text, glyphAlpha(src, n, x, y));
}

/// Straight-alpha composite of `fg` over `bg` with coverage `a` (0..255).
fn blend(bg: Rgb, fg: Rgb, a: u8) Rgb {
    const ai: u32 = a;
    const inv: u32 = 255 - @as(u32, a);
    return .{
        .r = @intCast((@as(u32, fg.r) * ai + @as(u32, bg.r) * inv + 127) / 255),
        .g = @intCast((@as(u32, fg.g) * ai + @as(u32, bg.g) * inv + 127) / 255),
        .b = @intCast((@as(u32, fg.b) * ai + @as(u32, bg.b) * inv + 127) / 255),
    };
}

// ---------------------------------------------------------------------------
// Shared state between the UI thread and the polling thread.
// ---------------------------------------------------------------------------
pub const State = struct {
    mutex: std.Io.Mutex = .init,
    reading: ?battery.Reading = null,
    /// Per side (0=left, 1=right): the side's value awaits authoritative
    /// forceRead verification (post-wake guard or pending low). Written with
    /// `reading` under the mutex; marks the last accepted value as uncertain
    /// and mutes low-battery notifications for that side.
    unverified: [2]bool = .{ false, false },
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
    /// UI-thread-only: wall-clock ms of the last notification actually fired,
    /// backing the `notify_cooldown_ms` sanity check in `planNotifications`.
    last_notified_ms: ?i64 = null,
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
/// The wireless halves sleep and report a null level between polls, and the
/// neuron intermittently returns an empty payload for a field even while
/// connected; rather than show "?%", we keep the last real value for each
/// field independently. `level == null` / `status == .unknown` means that field
/// has no fresh value (never reported yet, or a transient empty read).
pub const LastKnown = struct {
    left: battery.SideReading = .{ .level = null, .status = .unknown },
    right: battery.SideReading = .{ .level = null, .status = .unknown },
    /// Status as of the most recent merge, refreshed every call regardless of
    /// value — unlike `left`/`right.status` above, an empty read drops this
    /// straight to `.unknown`. Backs `leftText`/`rightText` only: the tray
    /// menu and tooltip should never show a stale status word (e.g.
    /// "Disconnected") sitting next to a level that's otherwise reading fine
    /// again, the way `left`/`right.status` would (see their doc comment).
    left_now: battery.Status = .unknown,
    right_now: battery.Status = .unknown,

    /// Merge a live reading, keeping each field's last real value: a sleeping
    /// half often answers one field (e.g. level=100) while the other's status
    /// reads back `.unknown` (empty/unparseable/never-reported); skipping
    /// `.unknown` avoids clobbering a real "charging" with "?". Only an explicit
    /// `.disconnected` status (firmware code "4") merges — that's what drives
    /// the "?" icon once both sides are down, and what notifications key off
    /// of to avoid a false low-battery alert on a momentarily-empty status.
    pub fn merge(self: *LastKnown, r: battery.Reading) void {
        if (r.left.level != null) self.left.level = r.left.level;
        if (r.left.status != .unknown) self.left.status = r.left.status;
        self.left_now = r.left.status;
        if (r.right.level != null) self.right.level = r.right.level;
        if (r.right.status != .unknown) self.right.status = r.right.status;
        self.right_now = r.right.status;
    }

    /// Text-display snapshot for a side: the sticky last-known level paired
    /// with the CURRENT read's status rather than the sticky one, so
    /// `fmtMenuSide`/`fmtKnownSide` drop the "(word)" suffix the moment a
    /// poll's status comes back empty instead of leaving an old one behind.
    pub fn leftText(self: LastKnown) battery.SideReading {
        return .{ .level = self.left.level, .status = self.left_now };
    }
    pub fn rightText(self: LastKnown) battery.SideReading {
        return .{ .level = self.right.level, .status = self.right_now };
    }

    /// Lower of the two last-known side levels, with its status. `level` is
    /// null before either side has ever reported. A hidden side (unverified,
    /// `.na` display mode) is skipped; both hidden yields a null level and
    /// the existing "--"/gray rendering.
    pub fn display(self: LastKnown, hide: [2]bool) battery.SideReading {
        var out: battery.SideReading = .{ .level = null, .status = .unknown };
        if (!hide[0]) {
            if (self.left.level) |l| {
                out.level = l;
                out.status = self.left.status;
            }
        }
        if (!hide[1]) {
            if (self.right.level) |rl| {
                if (out.level == null or rl < out.level.?) {
                    out.level = rl;
                    out.status = self.right.status;
                }
            }
        }
        return out;
    }

    /// True when every battery-reporting side's last-known level is 100% —
    /// the trigger for the full 🔋 icon, independent of `wireless.status` (the
    /// keyboard is topped off whether or not it's still on the cable). Mirrors
    /// `allSidesDisconnected`'s model handling: a 1-sided model (Sonsei)
    /// consults only the left channel; a null model (--port) assumes two sides.
    /// A side that has never reported (null level) is not full.
    pub fn allSidesFull(self: LastKnown, model: ?device.Model) bool {
        if (self.left.level != 100) return false;
        const m = model orelse return self.right.level == 100;
        if (m.sides() < 2) return true;
        return self.right.level == 100;
    }
};

/// How to render a side whose value awaits authoritative verification:
/// `.na` hides it entirely ("?", like Bazecor's N/A); `.last_known` keeps
/// showing the last accepted level with a "?" suffix. Hiding an unverified
/// side can make a healthy opposite half turn the icon green, so the tray
/// always retains the accepted baseline until verification completes.
pub const UnverifiedDisplay = enum { na, last_known };
pub const unverified_display: UnverifiedDisplay = .last_known;

/// Sides the icon's min-of-sides pick must skip for the configured mode.
pub fn hiddenSides(unverified: [2]bool) [2]bool {
    return hiddenSidesMode(unverified, unverified_display);
}

fn hiddenSidesMode(unverified: [2]bool, mode: UnverifiedDisplay) [2]bool {
    return switch (mode) {
        .na => unverified,
        .last_known => .{ false, false },
    };
}

// ---------------------------------------------------------------------------
// Formatting helpers (no platform dependency).
// ---------------------------------------------------------------------------
/// Whether a side's status is surfaced as a "(word)" suffix next to the level.
/// `wireless.battery.*.status` is best-effort and unreliable (FOCUS_API): only
/// the live `discharging`/`charging` states are shown. `.unknown` (empty read),
/// `.disconnected` (a false "4" fires even while the keyboard is actively in
/// use) and `.fault` (reading error) are treated as no status at all — the bare
/// last-known level is shown instead of a misleading word. `.charged` is handled
/// separately by each formatter ("full").
fn statusHasWord(st: battery.Status) bool {
    return st == .discharging or st == .charging;
}

/// Menu form of a last-known side snapshot: "{d}% (Status)" with a capitalized
/// status word to match the menu styling; "no reading yet" if never reported;
/// an unverified side renders per `unverified_display`. When the level is known
/// but the status isn't (the neuron often answers the level and leaves the
/// status empty), the status suffix is dropped entirely — "{d}%" — rather than
/// showing a meaningless "(?)".
pub fn fmtMenuSide(buf: []u8, s: battery.SideReading, unverified: bool) []const u8 {
    return fmtMenuSideMode(buf, s, unverified, unverified_display);
}

fn fmtMenuSideMode(buf: []u8, s: battery.SideReading, unverified: bool, mode: UnverifiedDisplay) []const u8 {
    // A full (charged) side shows just "Full" — the percentage is unreliable on
    // the cable (FOCUS_API) and "{d}% (Full)" is self-contradictory.
    if (s.status == .charged) return "Full";
    if (unverified and mode == .na) return "verifying…";
    const lvl = s.level orelse return "no reading yet";
    const marker: []const u8 = if (unverified) "?" else "";
    if (!statusHasWord(s.status))
        return std.fmt.bufPrint(buf, "{d}%{s}", .{ lvl, marker }) catch buf[0..0];
    const word = s.status.label();
    var cap: [16]u8 = undefined;
    const w = if (word.len > 0 and word.len <= cap.len) blk: {
        std.mem.copyForwards(u8, cap[0..word.len], word);
        cap[0] = std.ascii.toUpper(word[0]);
        break :blk cap[0..word.len];
    } else word;
    return std.fmt.bufPrint(buf, "{d}%{s} ({s})", .{ lvl, marker, w }) catch buf[0..0];
}

/// Tooltip/CLI form: "{d}% (status)" with a lowercase status word; "?%" if the
/// side has no level yet. A known level with an unknown status drops the suffix
/// ("{d}%") — the neuron frequently returns a level with an empty status. A full
/// (charged) side renders just "full": its percentage is unreliable on the cable
/// (FOCUS_API) and "{d}% (full)" reads as a contradiction.
pub fn fmtSide(buf: []u8, s: battery.SideReading) []const u8 {
    if (s.status == .charged) return s.status.label();
    if (s.level) |lvl| {
        if (!statusHasWord(s.status))
            return std.fmt.bufPrint(buf, "{d}%", .{lvl}) catch buf[0..0];
        return std.fmt.bufPrint(buf, "{d}% ({s})", .{ lvl, s.status.label() }) catch buf[0..0];
    }
    // No level at all: the "no data" path. An unreliable status (disconnected/
    // fault/empty) renders as "?" rather than a misleading word.
    const word: []const u8 = if (statusHasWord(s.status)) s.status.label() else "?";
    return std.fmt.bufPrint(buf, "?% ({s})", .{word}) catch buf[0..0];
}

/// Tooltip form of a last-known side snapshot: the real value if the side has
/// ever reported, else a plain "no reading yet"; an unverified side renders
/// per `unverified_display`.
pub fn fmtKnownSide(buf: []u8, s: battery.SideReading, unverified: bool) []const u8 {
    return fmtKnownSideMode(buf, s, unverified, unverified_display);
}

fn fmtKnownSideMode(buf: []u8, s: battery.SideReading, unverified: bool, mode: UnverifiedDisplay) []const u8 {
    if (s.status == .charged) return s.status.label(); // "full", no percentage
    if (unverified and mode == .na) {
        const word: []const u8 = if (statusHasWord(s.status)) s.status.label() else "?";
        return std.fmt.bufPrint(buf, "?% ({s})", .{word}) catch buf[0..0];
    }
    if (s.level) |lvl| {
        const marker: []const u8 = if (unverified) "?" else "";
        // An unreliable/empty status (unknown/disconnected/fault) drops the suffix.
        if (!statusHasWord(s.status))
            return std.fmt.bufPrint(buf, "{d}%{s}", .{ lvl, marker }) catch buf[0..0];
        return std.fmt.bufPrint(buf, "{d}%{s} ({s})", .{ lvl, marker, s.status.label() }) catch buf[0..0];
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

/// Any off-cable side below the low threshold — drives warning urgency on
/// the connect announcement. Charging/charged sides are skipped: FOCUS_API
/// marks the gauge inaccurate on the cable.
pub fn hasLowBattery(r: battery.Reading) bool {
    const sides = [_]battery.SideReading{ r.left, r.right };
    for (sides) |s| {
        if (s.status.onCable()) continue;
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

/// Wall-clock milliseconds, for spacing `planNotifications` calls against
/// `notify_cooldown_ms`.
pub fn nowMs(io: std.Io) i64 {
    const ts = std.Io.Clock.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.raw.nanoseconds, std.time.ns_per_ms));
}

/// Sanity backstop: desktop notifications never fire more often than this,
/// regardless of how many latch crossings or reconnect announcements pile up
/// (e.g. a flapping connection re-announcing every poll). An event suppressed
/// by the cooldown is dropped outright, not queued: the latch/announce state
/// still advances as if it had fired, so it does not retry once the cooldown
/// clears.
pub const notify_cooldown_ms: i64 = 10_000;

/// Decide which notifications to fire and mutate the per-side latch. Pure: no
/// platform calls. Mirrors the Windows updateTray decision flow exactly.
///
/// `announce_pending` is the pending connect-announcement flag.
/// `announce_ready` gates the announcement — it must be computed from the *raw*
/// reading (both raw levels present), not the merged snapshot, so a stale
/// last-known value can't fire the announcement early after a reconnect. The
/// announcement body and latch still render from the merged `snapshot`.
///
/// `unverified` mutes a side that awaits authoritative verification. This is
/// an invariant backstop: the acceptor never puts an unverified low into the
/// snapshot in the first place.
///
/// `now_ms`/`last_notified_ms` back the `notify_cooldown_ms` sanity check: no
/// event fires within `notify_cooldown_ms` of the last one that did — a
/// crossing/announcement inside the window is dropped, not queued. Both
/// events in the same call (e.g. two sides crossing low together) still fire
/// together — the cooldown is evaluated once per call, not per event.
///
/// - pending + ready: emit connect_status, latch the lows, report consumed.
/// - pending + not ready: emit nothing, keep announce pending.
/// - not pending: per-side low check against the latch (fires once per crossing).
pub fn planNotifications(
    latch: *[2]bool,
    announce_pending: bool,
    announce_ready: bool,
    snapshot: battery.Reading,
    unverified: [2]bool,
    now_ms: i64,
    last_notified_ms: *?i64,
) NotifyPlan {
    var plan = NotifyPlan{};
    const sides = [_]battery.SideReading{ snapshot.left, snapshot.right };
    const cooled_down = if (last_notified_ms.*) |last| now_ms - last >= notify_cooldown_ms else true;

    if (announce_pending) {
        // A side hasn't reported a fresh level yet: stay pending, fire nothing.
        if (!announce_ready) return plan;

        // Cooldown backstop: the latch still advances as though the
        // announcement fired, so a suppressed announcement is dropped
        // outright rather than retried on the next poll.
        if (cooled_down) plan.events[0] = .{ .kind = .connect_status, .warning = hasLowBattery(snapshot) };
        // Latch every side to its current low state so the announcement doesn't
        // double as a fresh low crossing on the next poll. An unverified side
        // latches like a null level: its value isn't evidence yet.
        for (sides, 0..) |s, i| {
            if (s.status.onCable()) {
                latch[i] = false;
                continue;
            }
            if (unverified[i]) {
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
        if (cooled_down) last_notified_ms.* = now_ms;
        return plan;
    }

    // Per-side low crossing: fire once when a side that's off the cable drops
    // below the threshold; reset the latch when it's on the cable or recovers.
    var idx: usize = 0;
    for (sides, 0..) |s, i| {
        if (s.status.onCable()) {
            latch[i] = false;
            continue;
        }
        // Unverified: fire nothing and leave the latch untouched, so a later
        // verified genuine low still fires exactly once.
        if (unverified[i]) continue;
        const lvl = s.level orelse continue;
        if (lvl < low_threshold) {
            if (!latch[i]) {
                // Latch regardless of the cooldown: a suppressed crossing is
                // dropped, not retried once the cooldown clears.
                latch[i] = true;
                if (cooled_down) {
                    plan.events[idx] = .{ .kind = .low_battery, .side = @intCast(i), .level = lvl, .warning = true };
                    idx += 1;
                }
            }
        } else {
            latch[i] = false;
        }
    }
    if (idx > 0) last_notified_ms.* = now_ms;
    return plan;
}

const LayerTracker = struct {
    last: ?u8 = null,
    announce_on_next: bool = false,

    fn feed(self: *LayerTracker, idx: u8) ?u8 {
        defer self.last = idx;
        if (self.announce_on_next) {
            self.announce_on_next = false;
            return idx;
        }
        const prev = self.last orelse return null;
        return if (idx != prev) idx else null;
    }

    fn noteDisconnected(self: *LayerTracker) void {
        if (self.last != null) self.announce_on_next = true;
    }

    fn noteDisabled(self: *LayerTracker) void {
        self.last = null;
        self.announce_on_next = false;
    }
};

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
    // Set after a forceRead: the next reading is ground truth and bypasses
    // the gate.
    var next_read_authoritative = false;
    // Wake detection + forceRead verification state. Outside the connect
    // loop like `acceptor`: a forceRead failure breaks to reconnect, and the
    // retry backoff must survive that so reconnect loops never hammer RF.
    var wake_detector: WakeDetector = .{};
    var verify_active = false;
    var verify_backoff_idx: usize = 0;
    var verify_wait_ms: u64 = 0;
    var layer_tracker: LayerTracker = .{};
    while (!st.stop.load(.acquire)) {
        // A wake can land while disconnected or paused too: guard the sides
        // so the next connection's first reads need verification.
        if (wake_detector.check(io)) {
            acceptor.noteWake();
            statusserver.emitWake();
        }
        // PAUSED: hold no port so Bazecor can use it; idle until resumed.
        if (st.paused.load(.acquire)) {
            const present = device.isDygmaPresent(io) catch false;
            layer_tracker.noteDisconnected();
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
            layer_tracker.noteDisconnected();
            resetLayerState(st);
            setStatus(Ctx, ctx, io, st, wake, .missing);
            sleepMs(io, st, 3000);
            continue;
        }
        const path = found.port orelse {
            layer_tracker.noteDisconnected();
            resetLayerState(st);
            setStatus(Ctx, ctx, io, st, wake, .available);
            sleepMs(io, st, 3000);
            continue;
        };
        defer gpa.free(path);

        // CONNECT
        var dev = focus.Focus.open(io, path) catch {
            const still_present = device.isDygmaPresent(io) catch true;
            layer_tracker.noteDisconnected();
            resetLayerState(st);
            setStatus(Ctx, ctx, io, st, wake, offlineStatus(still_present));
            sleepMs(io, st, 3000);
            continue;
        };
        defer dev.close();
        // A reconnect between a forceRead and its authoritative read must not
        // promote the new connection's first plain cache read to ground truth.
        next_read_authoritative = false;
        // Per-connection last-known merge. On a plain read the neuron answers one
        // side at a time, so a single raw read almost never carries both levels;
        // merge across this connection so st.reading (and thus the connect
        // announcement and the backoff) see a complete picture. Fresh per connect
        // — nothing carries across a reconnect, so the announcement can't fire off
        // a stale value.
        var known: LastKnown = .{};
        // A user refresh re-arms the connect announcement, but only once the
        // fresh authoritative reading is published — arming at click time would
        // let the UI announce stale pre-refresh values during the settle window.
        var announce_next_read = false;
        // Start fast (immediate first read); back off once both sides report.
        var battery_interval_ms: u64 = initial_poll_interval_ms;
        var battery_elapsed_ms: u64 = battery_interval_ms;

        // POLL. No forceRead on connect: the neuron serves cached values on a
        // plain read, and forcing a re-poll every cycle blanks them mid-refresh.
        // forceRead runs only when the user asks to refresh (below).
        while (!st.stop.load(.acquire)) {
            if (st.paused.load(.acquire)) {
                const still_present = device.isDygmaPresent(io) catch true;
                layer_tracker.noteDisconnected();
                resetLayerState(st);
                setStatus(Ctx, ctx, io, st, wake, offlineStatus(still_present));
                break;
            }
            // ~250ms cadence → one-tick wake detection latency. Re-arm fast
            // polling so the post-wake state is read and verified promptly
            // rather than after a slow interval.
            if (wake_detector.check(io)) {
                acceptor.noteWake();
                statusserver.emitWake();
                battery_interval_ms = initial_poll_interval_ms;
                battery_elapsed_ms = battery_interval_ms;
            }
            var should_post = false;
            if (battery_elapsed_ms >= battery_interval_ms) {
                const raw = battery.read(&dev) catch {
                    const still_present = device.isDygmaPresent(io) catch false;
                    layer_tracker.noteDisconnected();
                    resetLayerState(st);
                    setStatus(Ctx, ctx, io, st, wake, offlineStatus(still_present));
                    break;
                };
                const authoritative_read = next_read_authoritative;
                const res = if (next_read_authoritative)
                    acceptor.feedAuthoritative(raw)
                else
                    acceptor.feed(raw);
                next_read_authoritative = false;
                // Expose the raw wire reading, the gated result, and the
                // verdict on the debug events channel.
                statusserver.emitReading(.{
                    .raw = raw,
                    .accepted = res.reading,
                    .suspect = res.suspect,
                    .needs_verification = res.needs_verification,
                    .authoritative = authoritative_read,
                });
                known.merge(res.reading);
                const merged: battery.Reading = .{ .left = known.left, .right = known.right };
                st.mutex.lockUncancelable(io);
                const announce_connection = st.status != .connected;
                st.reading = merged;
                st.unverified = res.needs_verification;
                st.status = .connected;
                if (announce_connection or announce_next_read) st.announce_connection = true;
                announce_next_read = false;
                st.mutex.unlock(io);
                // Feed the external status IPC (yasb/waybar) the same
                // accepted snapshot the UI renders: the sticky merged levels
                // plus the fresh per-poll status (known.merge just set
                // left_now/right_now), so the feed drops a stale disconnected
                // suffix exactly like the menu/tooltip.
                statusserver.publishReading(io, found.model, merged.left, merged.right, known.left_now, known.right_now, hiddenSides(res.needs_verification));
                // Arm the forceRead verification loop on the transition into
                // needing it (re-arming every poll would reset the backoff
                // and hammer RF); clear it once nothing needs verifying.
                if (res.anyVerification()) {
                    if (!verify_active) {
                        verify_active = true;
                        verify_backoff_idx = 0;
                        verify_wait_ms = 0; // first attempt fires immediately
                    }
                } else {
                    verify_active = false;
                }
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
                    layer_tracker.noteDisconnected();
                    resetLayerState(st);
                    setStatus(Ctx, ctx, io, st, wake, offlineStatus(still_present));
                    break;
                };
                if (active_layer) |idx| {
                    if (layer_tracker.feed(idx)) |changed| {
                        st.layer_change.store(changed, .release);
                        should_post = true;
                    }
                }
            } else {
                layer_tracker.noteDisabled();
            }

            if (should_post) wake(ctx);

            // Wait out the interval, staying responsive to stop/refresh/pause.
            const refreshed = waitForNextPoll(io, st, layer_poll_interval_ms);
            // Only a user refresh re-announces; the automatic verify path must
            // not fire notifications.
            if (refreshed) announce_next_read = true;
            if (refreshed or (verify_active and verify_wait_ms == 0)) {
                if (verify_active) {
                    // Arm the next delay BEFORE attempting: a transport
                    // failure breaks to reconnect and must still back off.
                    // A user refresh counts as an attempt and advances the
                    // backoff too — one forceRead either way, no double RF.
                    verify_wait_ms = battery.verify_backoff_s[verify_backoff_idx] * std.time.ms_per_s;
                    if (verify_backoff_idx + 1 < battery.verify_backoff_s.len) verify_backoff_idx += 1;
                }
                // A failed forceRead means the stream state is unknown (its
                // late response would answer the next command) — reconnect
                // rather than keep polling a desynced port.
                statusserver.emitForceRead("issued", null);
                battery.forceRead(&dev) catch |e| {
                    statusserver.emitForceRead("failed", @errorName(e));
                    const still_present = device.isDygmaPresent(io) catch false;
                    layer_tracker.noteDisconnected();
                    resetLayerState(st);
                    setStatus(Ctx, ctx, io, st, wake, offlineStatus(still_present));
                    break;
                };
                sleepMs(io, st, battery.force_read_settle_s * 1000);
                statusserver.emitForceRead("settled", null);
                next_read_authoritative = true;
                // Re-arm fast polling: if the sides were asleep the refresh
                // read comes back empty, and staying on the slow interval
                // would make the refresh look dead for up to 2 minutes after
                // the halves wake. levelsKnown restores the adaptive interval
                // once real data arrives.
                battery_interval_ms = initial_poll_interval_ms;
                battery_elapsed_ms = battery_interval_ms; // force a read next cycle
            } else {
                battery_elapsed_ms += layer_poll_interval_ms;
                verify_wait_ms -|= layer_poll_interval_ms;
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
        st.unverified = .{ false, false };
        st.announce_connection = false;
    }
    st.mutex.unlock(io);
    // Unconditional (unlike wake): paused flips without a status change, and
    // the re-render also keeps the snapshot's `updated` field fresh.
    statusserver.publishConnState(io, if (st.paused.load(.acquire)) .paused else switch (status) {
        .missing => .missing,
        .available => .available,
        .connected => .connected,
    });
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

test "LayerTracker: startup baselines, changes announce, reconnect re-announces current layer" {
    var tracker = LayerTracker{};

    try std.testing.expectEqual(@as(?u8, null), tracker.feed(0));
    try std.testing.expectEqual(@as(?u8, null), tracker.feed(0));
    try std.testing.expectEqual(@as(?u8, 2), tracker.feed(2));

    tracker.noteDisconnected();
    try std.testing.expectEqual(@as(?u8, 2), tracker.feed(2));
    try std.testing.expectEqual(@as(?u8, null), tracker.feed(2));
    try std.testing.expectEqual(@as(?u8, 3), tracker.feed(3));
}

test "LayerTracker: disconnect before any layer does not announce initial connect" {
    var tracker = LayerTracker{};

    tracker.noteDisconnected();
    try std.testing.expectEqual(@as(?u8, null), tracker.feed(1));
}

test "LayerTracker: disabling overlay clears reconnect announcement state" {
    var tracker = LayerTracker{};

    try std.testing.expectEqual(@as(?u8, null), tracker.feed(1));
    tracker.noteDisconnected();
    tracker.noteDisabled();
    try std.testing.expectEqual(@as(?u8, null), tracker.feed(1));
    try std.testing.expectEqual(@as(?u8, 2), tracker.feed(2));
}

test "planNotifications: low crossing fires once, latched afterwards" {
    var latch = [2]bool{ false, false };
    var last_notified_ms: ?i64 = null;
    const snap = reading(15, .discharging, 80, .discharging);

    const first = planNotifications(&latch, false, false, snap, .{ false, false }, 0, &last_notified_ms);
    try std.testing.expectEqual(@as(usize, 1), countEvents(first));
    try std.testing.expectEqual(NotifyEvent{ .kind = .low_battery, .side = 0, .level = 15, .warning = true }, first.events[0].?);
    try std.testing.expect(latch[0]);

    // Same low reading again: latched, no re-fire.
    const second = planNotifications(&latch, false, false, snap, .{ false, false }, 0, &last_notified_ms);
    try std.testing.expectEqual(@as(usize, 0), countEvents(second));
}

test "planNotifications: recovery above threshold resets the latch" {
    var latch = [2]bool{ true, false };
    var last_notified_ms: ?i64 = null;
    const plan = planNotifications(&latch, false, false, reading(50, .discharging, 90, .discharging), .{ false, false }, 0, &last_notified_ms);
    try std.testing.expectEqual(@as(usize, 0), countEvents(plan));
    try std.testing.expect(!latch[0]); // latch cleared, so a later drop fires again

    const again = planNotifications(&latch, false, false, reading(10, .discharging, 90, .discharging), .{ false, false }, 0, &last_notified_ms);
    try std.testing.expectEqual(@as(usize, 1), countEvents(again));
}

test "planNotifications: charging side never warns and resets the latch" {
    var latch = [2]bool{ true, true };
    var last_notified_ms: ?i64 = null;
    const plan = planNotifications(&latch, false, false, reading(5, .charging, 8, .charging), .{ false, false }, 0, &last_notified_ms);
    try std.testing.expectEqual(@as(usize, 0), countEvents(plan));
    try std.testing.expect(!latch[0]);
    try std.testing.expect(!latch[1]);
}

test "planNotifications: charged (full) side never warns either" {
    // `.charged` (firmware code 2) means the cable is still connected, so a low
    // reading paired with it is the same inaccurate-on-cable case as charging.
    var latch = [2]bool{ true, true };
    var last_notified_ms: ?i64 = null;
    const plan = planNotifications(&latch, false, false, reading(5, .charged, 8, .charged), .{ false, false }, 0, &last_notified_ms);
    try std.testing.expectEqual(@as(usize, 0), countEvents(plan));
    try std.testing.expect(!latch[0]);
    try std.testing.expect(!latch[1]);
}

test "planNotifications: a low charged side does not warn the connect announcement" {
    var latch = [2]bool{ false, false };
    var last_notified_ms: ?i64 = null;
    const plan = planNotifications(&latch, true, true, reading(5, .charged, 90, .discharging), .{ false, false }, 0, &last_notified_ms);
    try std.testing.expect(plan.events[0].?.kind == .connect_status);
    try std.testing.expect(!plan.events[0].?.warning); // charged side skipped by hasLowBattery
    try std.testing.expect(!latch[0]);
}

test "planNotifications: both low sides fire two events" {
    var latch = [2]bool{ false, false };
    var last_notified_ms: ?i64 = null;
    const plan = planNotifications(&latch, false, false, reading(10, .discharging, 19, .discharging), .{ false, false }, 0, &last_notified_ms);
    try std.testing.expectEqual(@as(usize, 2), countEvents(plan));
    try std.testing.expectEqual(@as(u1, 0), plan.events[0].?.side.?);
    try std.testing.expectEqual(@as(u1, 1), plan.events[1].?.side.?);
}

test "planNotifications: announce with both sides known emits status and latches lows" {
    var latch = [2]bool{ false, false };
    var last_notified_ms: ?i64 = null;
    const plan = planNotifications(&latch, true, true, reading(15, .discharging, 90, .discharging), .{ false, false }, 0, &last_notified_ms);
    try std.testing.expectEqual(@as(usize, 1), countEvents(plan));
    try std.testing.expect(plan.events[0].?.kind == .connect_status);
    try std.testing.expect(plan.events[0].?.warning); // a side is low
    try std.testing.expect(plan.consumed_announce);
    try std.testing.expect(latch[0]); // low side latched by the announcement
    try std.testing.expect(!latch[1]);
}

test "planNotifications: announce with a healthy pair is not a warning" {
    var latch = [2]bool{ false, false };
    var last_notified_ms: ?i64 = null;
    const plan = planNotifications(&latch, true, true, reading(80, .discharging, 90, .charging), .{ false, false }, 0, &last_notified_ms);
    try std.testing.expect(plan.events[0].?.kind == .connect_status);
    try std.testing.expect(!plan.events[0].?.warning);
    try std.testing.expect(plan.consumed_announce);
}

test "planNotifications: announce with a side unknown emits nothing and stays pending" {
    var latch = [2]bool{ false, false };
    var last_notified_ms: ?i64 = null;
    const plan = planNotifications(&latch, true, false, reading(null, .unknown, 90, .discharging), .{ false, false }, 0, &last_notified_ms);
    try std.testing.expectEqual(@as(usize, 0), countEvents(plan));
    try std.testing.expect(!plan.consumed_announce);
}

test "planNotifications: announce gates on raw readiness, not the merged snapshot" {
    // Merged snapshot has both levels (a stale side survived a reconnect), but
    // the raw reading isn't ready yet: the announcement must stay pending.
    var latch = [2]bool{ false, false };
    var last_notified_ms: ?i64 = null;
    const merged = reading(50, .discharging, 80, .discharging);
    const plan = planNotifications(&latch, true, false, merged, .{ false, false }, 0, &last_notified_ms);
    try std.testing.expectEqual(@as(usize, 0), countEvents(plan));
    try std.testing.expect(!plan.consumed_announce);
}

test "planNotifications: cooldown drops a second crossing fired too soon" {
    // Left crosses low at t=0 and fires. Right crosses low at t=1s (within the
    // 10s cooldown): it must latch (so it never re-fires later either) but the
    // event itself is dropped, not queued.
    var latch = [2]bool{ false, false };
    var last_notified_ms: ?i64 = null;
    const first = planNotifications(&latch, false, false, reading(15, .discharging, 90, .discharging), .{ false, false }, 0, &last_notified_ms);
    try std.testing.expectEqual(@as(usize, 1), countEvents(first));
    try std.testing.expect(latch[0]);

    const dropped = planNotifications(&latch, false, false, reading(15, .discharging, 15, .discharging), .{ false, false }, 1_000, &last_notified_ms);
    try std.testing.expectEqual(@as(usize, 0), countEvents(dropped));
    try std.testing.expect(latch[1]); // latched immediately — dropped, not deferred

    // Well past the cooldown window: the crossing already latched, so it does
    // not resurface even though nothing was ever shown for it.
    const still_silent = planNotifications(&latch, false, false, reading(15, .discharging, 15, .discharging), .{ false, false }, 60_000, &last_notified_ms);
    try std.testing.expectEqual(@as(usize, 0), countEvents(still_silent));
}

test "planNotifications: cooldown drops a connect announcement fired too soon" {
    var latch = [2]bool{ false, false };
    var last_notified_ms: ?i64 = 0; // a notification "just" fired at t=0
    const dropped = planNotifications(&latch, true, true, reading(80, .discharging, 90, .discharging), .{ false, false }, 5_000, &last_notified_ms);
    try std.testing.expectEqual(@as(usize, 0), countEvents(dropped));
    // Consumed anyway: the caller clears announce_pending, so a dropped
    // announcement is not retried on the next poll either.
    try std.testing.expect(dropped.consumed_announce);
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

test "WakeDetector: suspend gap beyond threshold fires once" {
    var d = WakeDetector{};
    try std.testing.expect(!d.feed(.{ .incl_ms = 1000, .excl_ms = 1000 })); // first sample
    try std.testing.expect(!d.feed(.{ .incl_ms = 2000, .excl_ms = 2000 })); // normal tick
    // 60s asleep: the inclusive clock advanced, the exclusive one didn't.
    try std.testing.expect(d.feed(.{ .incl_ms = 62_000, .excl_ms = 2_000 }));
    // Next tick after the wake: no new suspend time, no re-fire.
    try std.testing.expect(!d.feed(.{ .incl_ms = 62_250, .excl_ms = 2_250 }));
}

test "WakeDetector: normal ticking never fires" {
    var d = WakeDetector{};
    var t: u64 = 0;
    _ = d.feed(.{ .incl_ms = t, .excl_ms = t });
    for (0..100) |_| {
        t += 250;
        try std.testing.expect(!d.feed(.{ .incl_ms = t, .excl_ms = t }));
    }
}

test "WakeDetector: first sample never fires even with a huge suspend delta" {
    var d = WakeDetector{};
    // The process may start hours after boot with prior sleeps already in
    // the counters — that history is not a fresh wake.
    try std.testing.expect(!d.feed(.{ .incl_ms = 100_000_000, .excl_ms = 50_000_000 }));
}

test "WakeDetector: suspend gap at the threshold does not fire" {
    var d = WakeDetector{};
    _ = d.feed(.{ .incl_ms = 1000, .excl_ms = 1000 });
    try std.testing.expect(!d.feed(.{ .incl_ms = 11_250, .excl_ms = 1_250 }));
}

test "planNotifications: unverified side fires nothing and leaves the latch untouched" {
    var latch = [2]bool{ false, false };
    var last_notified_ms: ?i64 = null;
    const snap = reading(15, .discharging, 80, .discharging);
    const muted = planNotifications(&latch, false, false, snap, .{ true, false }, 0, &last_notified_ms);
    try std.testing.expectEqual(@as(usize, 0), countEvents(muted));
    try std.testing.expect(!latch[0]);

    // Verification clears and the low is genuine: fires exactly once.
    const fired = planNotifications(&latch, false, false, snap, .{ false, false }, 0, &last_notified_ms);
    try std.testing.expectEqual(@as(usize, 1), countEvents(fired));
    try std.testing.expect(latch[0]);
    const again = planNotifications(&latch, false, false, snap, .{ false, false }, 0, &last_notified_ms);
    try std.testing.expectEqual(@as(usize, 0), countEvents(again));
}

test "planNotifications: announce latches an unverified side like a null level" {
    var latch = [2]bool{ false, false };
    var last_notified_ms: ?i64 = null;
    const plan = planNotifications(&latch, true, true, reading(15, .discharging, 90, .discharging), .{ true, false }, 0, &last_notified_ms);
    try std.testing.expect(plan.consumed_announce);
    try std.testing.expect(!latch[0]);
}

test "LastKnown.display hides unverified sides" {
    var known = LastKnown{};
    known.merge(reading(90, .discharging, 30, .discharging));
    // The minimum side (right) hidden: the other side shows.
    var disp = known.display(.{ false, true });
    try std.testing.expectEqual(@as(?u8, 90), disp.level);
    // Both hidden: null level, the existing "--"/gray path.
    disp = known.display(.{ true, true });
    try std.testing.expectEqual(@as(?u8, null), disp.level);
    // Nothing hidden: min of sides as before.
    disp = known.display(.{ false, false });
    try std.testing.expectEqual(@as(?u8, 30), disp.level);
}

test "fmtSide never surfaces an unreliable status (disconnected/fault)" {
    // wireless.battery.*.status is best-effort (FOCUS_API): a false "4" fires
    // even while the keyboard is in use, so the disconnect must not reach the
    // UI. A disconnected/fault side renders as just its last-known level.
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("70%", fmtSide(&buf, .{ .level = 70, .status = .disconnected }));
    try std.testing.expectEqualStrings("42%", fmtSide(&buf, .{ .level = 42, .status = .fault }));
    // A live discharging/charging status still shows its word.
    try std.testing.expectEqualStrings("55% (discharging)", fmtSide(&buf, .{ .level = 55, .status = .discharging }));
    try std.testing.expectEqualStrings("80% (charging)", fmtSide(&buf, .{ .level = 80, .status = .charging }));
    // No level + unreliable status stays "?% (?)", never "?% (disconnected)".
    try std.testing.expectEqualStrings("?% (?)", fmtSide(&buf, .{ .level = null, .status = .disconnected }));
}

test "LastKnown.leftText/rightText carry the level, never a disconnected word" {
    var known = LastKnown{};
    known.merge(reading(70, .disconnected, 100, .disconnected));
    var buf: [24]u8 = undefined;
    // Disconnected is unreliable → the tray shows the last-known level only.
    try std.testing.expectEqualStrings("70%", fmtSide(&buf, known.leftText()));
    try std.testing.expectEqualStrings("100%", fmtSide(&buf, known.rightText()));
    // A later empty-status poll keeps showing the level too.
    known.merge(reading(70, .unknown, 100, .unknown));
    try std.testing.expectEqualStrings("70%", fmtSide(&buf, known.leftText()));
    try std.testing.expectEqualStrings("100%", fmtSide(&buf, known.rightText()));
}

test "hiddenSides: only .na mode hides unverified sides" {
    try std.testing.expectEqual([2]bool{ true, false }, hiddenSidesMode(.{ true, false }, .na));
    try std.testing.expectEqual([2]bool{ false, false }, hiddenSidesMode(.{ true, false }, .last_known));
}

test "unverified display retains the accepted minimum for the tray icon" {
    var known = LastKnown{};
    known.merge(reading(45, .discharging, 100, .discharging));

    // A pending left-side value must not hide the last accepted 45% and let
    // the right-side 100% value produce a green icon.
    const disp = known.display(hiddenSides(.{ true, false }));
    try std.testing.expectEqual(@as(?u8, 45), disp.level);

    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("45%? (discharging)", fmtKnownSide(&buf, known.leftText(), true));
}

test "fmt helpers render unverified sides per display mode" {
    var buf: [48]u8 = undefined;
    const s: battery.SideReading = .{ .level = 87, .status = .discharging };
    try std.testing.expectEqualStrings("?% (discharging)", fmtKnownSideMode(&buf, s, true, .na));
    try std.testing.expectEqualStrings("87%? (discharging)", fmtKnownSideMode(&buf, s, true, .last_known));
    try std.testing.expectEqualStrings("87% (discharging)", fmtKnownSideMode(&buf, s, false, .na));
    try std.testing.expectEqualStrings("verifying…", fmtMenuSideMode(&buf, s, true, .na));
    try std.testing.expectEqualStrings("87%? (Discharging)", fmtMenuSideMode(&buf, s, true, .last_known));
    try std.testing.expectEqualStrings("87% (Discharging)", fmtMenuSideMode(&buf, s, false, .na));
}

test "fmt helpers drop the status suffix when the level is known but status isn't" {
    var buf: [48]u8 = undefined;
    // The neuron often answers the level and leaves the status empty
    // (parsed as .unknown): show just "{d}%", never "{d}% (?)".
    const s: battery.SideReading = .{ .level = 40, .status = .unknown };
    try std.testing.expectEqualStrings("40%", fmtSide(&buf, s));
    try std.testing.expectEqualStrings("40%", fmtKnownSideMode(&buf, s, false, .na));
    try std.testing.expectEqualStrings("40%", fmtMenuSideMode(&buf, s, false, .na));
    // Unverified still carries its "?" marker, just without the status suffix.
    try std.testing.expectEqualStrings("40%?", fmtKnownSideMode(&buf, s, true, .last_known));
    try std.testing.expectEqualStrings("40%?", fmtMenuSideMode(&buf, s, true, .last_known));
    // A known status is unaffected.
    const known: battery.SideReading = .{ .level = 40, .status = .discharging };
    try std.testing.expectEqualStrings("40% (discharging)", fmtSide(&buf, known));
    // No level at all keeps the "?% (status)" no-data form.
    try std.testing.expectEqualStrings("?% (?)", fmtSide(&buf, .{ .level = null, .status = .unknown }));
}

test "batteryPixel: full glyph composites over the background at both icon sizes" {
    const bg = palette.blue;
    for ([_]usize{ 16, 22 }) |n| {
        // The body center is fully covered → solid white glyph color.
        try std.testing.expectEqual(@as(u8, 255), glyphAlpha(battery_full_rgba, n, n / 2, n / 2));
        try std.testing.expectEqual(palette.text, batteryPixel(battery_full_rgba, n, n / 2, n / 2, bg));
        // The canvas corners are transparent → background shows through exactly.
        try std.testing.expectEqual(@as(u8, 0), glyphAlpha(battery_full_rgba, n, 0, 0));
        try std.testing.expectEqual(bg, batteryPixel(battery_full_rgba, n, 0, 0, bg));
        try std.testing.expectEqual(bg, batteryPixel(battery_full_rgba, n, n - 1, n - 1, bg));
    }
}

test "charging glyph is the full battery with a bolt knocked out" {
    // The charging glyph never adds coverage over the full one, and the bolt
    // carves at least one interior pixel that the full glyph fills solid.
    var found_bolt = false;
    var y: usize = 0;
    while (y < battery_src_px) : (y += 1) {
        var x: usize = 0;
        while (x < battery_src_px) : (x += 1) {
            const i = (y * battery_src_px + x) * 4 + 3;
            const full = battery_full_rgba[i];
            const chg = battery_charging_rgba[i];
            try std.testing.expect(chg <= full);
            if (full == 255 and chg == 0) found_bolt = true;
        }
    }
    try std.testing.expect(found_bolt);
}

test "LastKnown.allSidesFull: every reporting side at 100%, ignoring status" {
    var known = LastKnown{};
    // One side short of 100 → not full.
    known.merge(reading(100, .discharging, 95, .discharging));
    try std.testing.expect(!known.allSidesFull(.defy_wireless));
    try std.testing.expect(!known.allSidesFull(null));
    // Both at 100 → full regardless of status (here plain discharging).
    known.merge(reading(100, .discharging, 100, .discharging));
    try std.testing.expect(known.allSidesFull(.defy_wireless));
    try std.testing.expect(known.allSidesFull(null));
    // A 1-sided model consults only the left channel.
    var one = LastKnown{};
    one.merge(reading(100, .charging, null, .unknown));
    try std.testing.expect(one.allSidesFull(.sonsei));
    try std.testing.expect(!one.allSidesFull(null)); // null model assumes two sides
    // A never-reported side is not full.
    try std.testing.expect(!(LastKnown{}).allSidesFull(.defy_wireless));
}

test "blend: endpoints are exact, midpoint mixes" {
    const bg = Rgb{ .r = 0, .g = 0, .b = 200 };
    const fg = Rgb{ .r = 255, .g = 255, .b = 255 };
    try std.testing.expectEqual(bg, blend(bg, fg, 0));
    try std.testing.expectEqual(fg, blend(bg, fg, 255));
    const mid = blend(bg, fg, 128);
    try std.testing.expectEqual(@as(u8, 128), mid.r); // ~50% toward white
}

test "iconColor: on the cable is always blue, off-cable follows the level ladder" {
    // Plugged in (charging or full): blue regardless of the unreliable level,
    // so a low gauge read never paints the icon red while on the cable.
    try std.testing.expectEqual(palette.blue, iconColor(true, 1, .charging));
    try std.testing.expectEqual(palette.blue, iconColor(true, 1, .charged));
    try std.testing.expectEqual(palette.blue, iconColor(true, 95, .charged));
    // Off the cable: the usual green/amber/red ladder.
    try std.testing.expectEqual(palette.green, iconColor(true, 80, .discharging));
    try std.testing.expectEqual(palette.amber, iconColor(true, 30, .discharging));
    try std.testing.expectEqual(palette.red, iconColor(true, 5, .discharging));
    // Offline/paused dims to gray whatever the status.
    try std.testing.expectEqual(palette.gray, iconColor(false, 80, .charging));
}

test "fmt helpers omit the percentage for a full (charged) side" {
    var buf: [48]u8 = undefined;
    // "1% (full)" is self-contradictory — a full side shows just the word.
    const full: battery.SideReading = .{ .level = 1, .status = .charged };
    try std.testing.expectEqualStrings("full", fmtSide(&buf, full));
    try std.testing.expectEqualStrings("full", fmtKnownSideMode(&buf, full, false, .na));
    try std.testing.expectEqualStrings("Full", fmtMenuSideMode(&buf, full, false, .na));
    // The word wins over the unverified marker and a null level alike.
    try std.testing.expectEqualStrings("full", fmtKnownSideMode(&buf, full, true, .last_known));
    const full_null: battery.SideReading = .{ .level = null, .status = .charged };
    try std.testing.expectEqualStrings("full", fmtSide(&buf, full_null));
    try std.testing.expectEqualStrings("Full", fmtMenuSideMode(&buf, full_null, false, .na));
}

test "tooltipHeader keeps paused wording and missing wording distinct" {
    try std.testing.expectEqualStrings("Paused (port free for Bazecor):\n", tooltipHeader(.missing, true));
    try std.testing.expectEqualStrings("No keyboard discovered - last known:\n", tooltipHeader(.missing, false));
    try std.testing.expectEqualStrings("Keyboard discovered, not connected - last known:\n", tooltipHeader(.available, false));
}
