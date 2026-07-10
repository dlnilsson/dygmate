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
// empty. Polling frequently catches a real reading within a few seconds;
// last-known-good then keeps it across the empty reads that follow. Plain reads
// hit the USB-powered neuron only — they never wake the sides or wear flash.
pub const poll_interval_ms: u64 = 5 * 1000;
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
    announce_connection: bool = false,
    stop: std.atomic.Value(bool) = .init(false),
    refresh: std.atomic.Value(bool) = .init(false),
    /// User asked us to release the port (so Bazecor can use it). The poll
    /// thread closes the connection and idles until this clears.
    paused: std.atomic.Value(bool) = .init(false),
    layer_change: std.atomic.Value(i32) = .init(-1),
    /// When false, the poll thread skips the layer read. Toggled from the tray
    /// menu on Windows; always on there. Linux passes osd_enabled=false at
    /// comptime so the layer read is compiled out entirely.
    osd_enabled: std.atomic.Value(bool) = .init(true),
    /// UI-thread-only: latched per side (0=left, 1=right) so a low-battery
    /// notification fires once per crossing, not every poll. Windows only.
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
// Background polling thread: owns the serial connection.
// ---------------------------------------------------------------------------
/// Run the discover -> connect -> poll loop. `wake(ctx)` notifies the UI that
/// a new reading (or connection-state change) is available: Windows posts a
/// window message; Linux writes an eventfd. When `osd_enabled` is false the
/// layer read is compiled out entirely (Linux, step 1).
pub fn runPollLoop(
    comptime Ctx: type,
    ctx: *Ctx,
    io: std.Io,
    gpa: std.mem.Allocator,
    st: *State,
    comptime wake: fn (*Ctx) void,
    comptime osd_enabled: bool,
) void {
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
        var battery_elapsed_ms: u64 = poll_interval_ms;

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
            if (battery_elapsed_ms >= poll_interval_ms) {
                const r = battery.read(&dev) catch {
                    const still_present = device.isDygmaPresent(io) catch false;
                    resetLayerState(st);
                    setStatus(Ctx, ctx, io, st, wake, offlineStatus(still_present));
                    break;
                };
                st.mutex.lockUncancelable(io);
                const announce_connection = st.status != .connected;
                st.reading = r;
                st.status = .connected;
                if (announce_connection) st.announce_connection = true;
                st.mutex.unlock(io);
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
                battery.forceRead(&dev);
                sleepMs(io, st, battery.force_read_settle_s * 1000);
                battery_elapsed_ms = poll_interval_ms;
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
