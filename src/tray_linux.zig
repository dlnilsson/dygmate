//! Linux system-tray battery indicator (StatusNotifierItem over D-Bus).
//! Wayland-oriented (waybar is the primary target). Mirrors the Windows tray's
//! menu, icon, notification behavior, and layer OSD. Linux only.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const linux = std.os.linux;
const tray_common = @import("tray_common.zig");
const battery = @import("battery.zig");
const device = @import("device.zig");
const dbus = @import("dbus.zig");
const layer = @import("layer.zig");
const osd_linux = @import("osd_linux.zig");
const config = @import("config.zig");
const update = @import("update.zig");
const statusserver = @import("statusserver.zig");

comptime {
    if (builtin.os.tag != .linux) @compileError("tray_linux.zig is Linux-only");
}

// D-Bus well-known names and paths.
const watcher_name = "org.kde.StatusNotifierWatcher";
const watcher_path = "/StatusNotifierWatcher";
const item_iface = "org.kde.StatusNotifierItem";
const item_path = "/StatusNotifierItem";
const menu_iface = "com.canonical.dbusmenu";
const menu_path = "/MenuBar";
const props_iface = "org.freedesktop.DBus.Properties";
const dbus_service = "org.freedesktop.DBus";
const dbus_path = "/org/freedesktop/DBus";
const notifications_service = "org.freedesktop.Notifications";
const notifications_path = "/org/freedesktop/Notifications";

// ---------------------------------------------------------------------------
// Icon rendering: a battery percentage drawn as an ARGB32 pixmap. SNI's
// IconPixmap is 32-bit ARGB in network (big-endian) byte order, so each pixel
// is stored [A, R, G, B].
// ---------------------------------------------------------------------------
pub const icon_px: usize = 22;
const glyph_w: usize = 3;
const glyph_h: usize = 5;

/// 3x5 bitmap glyphs for '0'..'9' and '-'. Each row uses the low 3 bits, bit 2
/// (0b100) leftmost. Chosen small so it scales up cleanly inside 22x22: one
/// digit renders at 4x, two at 3x, three ("100") at 2x.
fn glyph(c: u8) [glyph_h]u8 {
    return switch (c) {
        '0' => .{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        '1' => .{ 0b010, 0b110, 0b010, 0b010, 0b111 },
        '2' => .{ 0b111, 0b001, 0b111, 0b100, 0b111 },
        '3' => .{ 0b111, 0b001, 0b111, 0b001, 0b111 },
        '4' => .{ 0b101, 0b101, 0b111, 0b001, 0b001 },
        '5' => .{ 0b111, 0b100, 0b111, 0b001, 0b111 },
        '6' => .{ 0b111, 0b100, 0b111, 0b101, 0b111 },
        '7' => .{ 0b111, 0b001, 0b010, 0b010, 0b010 },
        '8' => .{ 0b111, 0b101, 0b111, 0b101, 0b111 },
        '9' => .{ 0b111, 0b101, 0b111, 0b001, 0b111 },
        '-' => .{ 0b000, 0b000, 0b111, 0b000, 0b000 },
        '?' => .{ 0b111, 0b001, 0b011, 0b000, 0b010 },
        else => .{ 0, 0, 0, 0, 0 },
    };
}

const IconBuf = [icon_px * icon_px * 4]u8;

fn putPixel(out: *IconBuf, x: usize, y: usize, c: tray_common.Rgb) void {
    const i = (y * icon_px + x) * 4;
    out[i] = 0xFF; // A
    out[i + 1] = c.r;
    out[i + 2] = c.g;
    out[i + 3] = c.b;
}

/// Fill `out` with `color`, then draw up to 3 glyphs of `text` centered in
/// white, at the largest integer scale that fits. Fully opaque.
pub fn renderIcon(out: *IconBuf, text: []const u8, color: tray_common.Rgb) void {
    var y: usize = 0;
    while (y < icon_px) : (y += 1) {
        var x: usize = 0;
        while (x < icon_px) : (x += 1) putPixel(out, x, y, color);
    }

    const n = @min(text.len, 3);
    if (n == 0) return;

    // Largest scale s such that s*(glyph_w*n + (n-1)) <= icon_px and
    // s*glyph_h <= icon_px.
    var scale: usize = 4;
    const unscaled_w = glyph_w * n + (n - 1);
    while (scale > 1) : (scale -= 1) {
        if (unscaled_w * scale <= icon_px and glyph_h * scale <= icon_px) break;
    }

    const total_w = unscaled_w * scale;
    const total_h = glyph_h * scale;
    const left = (icon_px - total_w) / 2;
    const top = (icon_px - total_h) / 2;

    var gi: usize = 0;
    while (gi < n) : (gi += 1) {
        const rows = glyph(text[gi]);
        const gx = left + gi * (glyph_w + 1) * scale;
        var ry: usize = 0;
        while (ry < glyph_h) : (ry += 1) {
            var rx: usize = 0;
            while (rx < glyph_w) : (rx += 1) {
                const bit = @as(u8, 0b100) >> @intCast(rx);
                if (rows[ry] & bit == 0) continue;
                // Fill a scale x scale block.
                var by: usize = 0;
                while (by < scale) : (by += 1) {
                    var bx: usize = 0;
                    while (bx < scale) : (bx += 1) {
                        putPixel(out, gx + rx * scale + bx, top + ry * scale + by, tray_common.palette.text);
                    }
                }
            }
        }
    }
}

/// Fill `out` with `color`, then draw the shared filled battery glyph in white.
/// Used in place of the number while the keyboard is on the cable (blue icon):
/// the gauge level is unreliable there, so a battery symbol is clearer than a
/// misleading percentage.
pub fn renderBattery(out: *IconBuf, glyph_src: []const u8, color: tray_common.Rgb) void {
    var y: usize = 0;
    while (y < icon_px) : (y += 1) {
        var x: usize = 0;
        while (x < icon_px) : (x += 1) {
            putPixel(out, x, y, tray_common.batteryPixel(glyph_src, icon_px, x, y, color));
        }
    }
}

// ---------------------------------------------------------------------------
// Application state.
// ---------------------------------------------------------------------------
const App = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    conn: *dbus.Connection,
    environ: *std.process.Environ.Map,
    state: *tray_common.State,
    event_fd: i32,
    item_name: []const u8, // owned: "org.kde.StatusNotifierItem-<pid>-1"
    item_registered: bool = false,
    // The main loop retries registration every poll tick while the watcher is
    // down; log only the first failure of each streak to avoid 1/s spam.
    register_fail_logged: bool = false,
    menu_revision: u32 = 1,

    // Notification popup slot. The daemon assigns an id on the first Notify
    // reply; reusing it as replaces_id updates one popup instead of stacking.
    // Both are daemon/connection-scoped, so reconnect resets them.
    notify_id: u32 = 0,
    pending_notify_serial: ?u32 = null,

    // Layer OSD. Null when Wayland/layer-shell is unavailable, in which case
    // the menu item is disabled and the poll thread skips layer reads.
    osd: ?osd_linux.Osd = null,
    osd_hide_at: ?i64 = null, // monotonic deadline; replaces Win32 SetTimer
    osd_show_at: ?i64 = null, // monotonic deadline for a delayed show, or null
    osd_pending_layer: u8 = 0, // layer to show when osd_show_at fires
    // Persisted settings, loaded once at startup. Kept whole so toggling one
    // field and saving does not clobber the user's other hand-edited values.
    cfg: config.Config = .{},

    // Current display snapshot (UI thread only).
    last: tray_common.LastKnown = .{},
    /// Per side: awaiting authoritative forceRead verification (snapshotted
    /// from State by rebuildAndNotify, read by the menu builder).
    unverified: [2]bool = .{ false, false },
    status: tray_common.DeviceStatus = .missing,
    model: ?device.Model = null,
    paused: bool = false,
    icon_buf: IconBuf = undefined,
    tip_body: [128]u8 = undefined,
    tip_body_len: usize = 0,

    // Populated by the one-shot GitHub update check ~60s after startup.
    update: update.State = .{},

    fn tipBody(self: *const App) []const u8 {
        return self.tip_body[0..self.tip_body_len];
    }
};

var g_state: tray_common.State = .{};

/// Set by --debug. Informational progress goes to stdout (dlog), failures to
/// stderr (dlogErr), so a terminal run can split them:
///   dygmate-tray --debug > info.log 2> errors.log
var debug_log = false;

fn dlog(comptime fmt: []const u8, args: anytype) void {
    if (!debug_log) return;
    // Big enough for two 255-byte D-Bus names (iface.member) plus the prefix.
    var buf: [640]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "dygmate-tray: " ++ fmt ++ "\n", args) catch return;
    _ = linux.write(1, line.ptr, line.len);
}

fn dlogErr(comptime fmt: []const u8, args: anytype) void {
    if (debug_log) std.debug.print("dygmate-tray: " ++ fmt ++ "\n", args);
}

pub fn main(init: std.process.Init) void {
    run(init) catch |e| {
        std.debug.print("dygmate-tray: {s}\n", .{@errorName(e)});
    };
}

fn run(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--debug")) {
            debug_log = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("dygmate-tray {s}\n", .{build_options.version});
            return;
        }
    }

    // Single instance: hold an exclusive flock on a lock file in the runtime
    // dir. A second copy could never open the exclusive serial port anyway.
    const runtime_dir = init.environ_map.get("XDG_RUNTIME_DIR") orelse "/tmp";
    if (acquireSingleton(runtime_dir) == null) {
        dlog("another instance holds the lock, exiting", .{});
        return; // already running
    }

    const uid = linux.getuid();
    const conn = try dbus.Connection.connectSession(io, gpa, init.environ_map, uid);
    dlog("connected to session bus as {s}", .{conn.unique_name});

    const pid = linux.getpid();
    const item_name = try std.fmt.allocPrint(gpa, "{s}-{d}-1", .{ item_iface, pid });
    defer gpa.free(item_name);

    var app = App{
        .io = io,
        .gpa = gpa,
        .conn = conn,
        .environ = init.environ_map,
        .state = &g_state,
        .event_fd = @intCast(linux.eventfd(0, 0)),
        .item_name = item_name,
    };
    // deinit the *current* connection (reconnect swaps app.conn).
    defer app.conn.deinit();
    renderIcon(&app.icon_buf, "?", tray_common.palette.gray);
    const start_tip = std.fmt.bufPrint(&app.tip_body, "{s}Left: {s}\nRight: {s}", .{
        tray_common.tooltipHeader(.missing, false),
        "no reading yet",
        "no reading yet",
    }) catch app.tip_body[0..0];
    app.tip_body_len = start_tip.len;
    // Do not poll layers until the UI thread has completed Wayland setup.
    app.state.osd_enabled.store(false, .release);

    // Watch the watcher: re-register if waybar (etc.) restarts.
    try addWatcherMatch(conn);
    try requestName(&app);
    dlog("acquired bus name {s}", .{app.item_name});

    // Battery status IPC for external status bars (waybar etc.):
    // {runtime_dir}/dygmate/{status,events}.sock. Started before the poll
    // thread so the Focus wire-tap and emit io are visible to it via the spawn
    // happens-before barrier; stopped after it joins (defers run LIFO).
    statusserver.start(io, gpa, .{ .runtime_dir = runtime_dir });
    defer statusserver.stop();

    // Background serial poll thread. It only touches State + the eventfd, never
    // the D-Bus socket, so all bus I/O stays on this (the main) thread.
    const thread = try std.Thread.spawn(.{}, pollThread, .{&app});
    defer {
        app.state.stop.store(true, .release);
        thread.join();
    }

    // Register with the watcher (retries in the loop if it isn't up yet).
    tryRegister(&app);

    // One-shot GitHub update check on its own thread + isolated io.
    update.spawnCheck(gpa, build_options.version, &app.update);

    // Layer OSD (Wayland layer-shell). No socket, missing layer-shell, or any
    // setup failure leaves the tray fully functional with the OSD disabled.
    app.osd = osd_linux.Osd.init(gpa, init.environ_map) catch |e| blk: {
        dlogErr("layer OSD unavailable: {s}", .{@errorName(e)});
        break :blk null;
    };
    if (app.osd != null) dlog("layer OSD initialized", .{});
    defer if (app.osd) |*o| o.deinit();
    // Restore the saved "Show layer overlay" preference, but an unavailable OSD
    // still forces it off.
    app.cfg = config.loadOrInit(io, gpa, init.environ_map);
    app.state.osd_enabled.store(app.osd != null and app.cfg.show_layer_overlay, .release);

    var fds = [_]std.posix.pollfd{
        // Always read app.conn.fd() fresh — reconnect() swaps the connection.
        .{ .fd = app.conn.fd(), .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = app.event_fd, .events = std.posix.POLL.IN, .revents = 0 },
        // Wayland socket; -1 is ignored by poll when the OSD is unavailable.
        .{ .fd = -1, .events = std.posix.POLL.IN, .revents = 0 },
    };
    while (!app.state.stop.load(.acquire)) {
        fds[0].fd = app.conn.fd();
        fds[2].fd = if (app.osd) |*o| o.fd() else -1;

        // Wake early when an OSD show or hide deadline is pending.
        var timeout: i32 = 1000;
        if (app.osd_show_at) |at| {
            const left = at - nowMs();
            if (left <= 0) {
                showOsdNow(&app);
            } else {
                timeout = @intCast(@min(left, 1000));
            }
        }
        if (app.osd_hide_at) |at| {
            const left = at - nowMs();
            if (left <= 0) {
                if (app.osd) |*o| o.hide();
                app.osd_hide_at = null;
            } else {
                timeout = @min(timeout, @as(i32, @intCast(@min(left, 1000))));
            }
        }
        _ = std.posix.poll(&fds, timeout) catch break;

        if (fds[1].revents & std.posix.POLL.IN != 0) {
            var drain: u64 = 0;
            _ = linux.read(app.event_fd, std.mem.asBytes(&drain), 8);
            rebuildAndNotify(&app);
            drainLayerChanges(&app);
        }
        if (fds[0].revents & std.posix.POLL.IN != 0) {
            const msg = app.conn.readMessage() catch |e| {
                dlogErr("bus read failed ({s}), reconnecting", .{@errorName(e)});
                reconnect(&app);
                continue;
            };
            dispatch(&app, msg) catch |e| dlogErr("dispatch error: {s}", .{@errorName(e)});
        }
        if (fds[2].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
            if (app.osd) |*o| {
                o.handleReadable();
                if (!o.alive()) {
                    app.state.osd_enabled.store(false, .release);
                    app.osd_hide_at = null;
                    app.osd_show_at = null;
                    app.menu_revision += 1;
                    emitLayoutUpdated(&app) catch {};
                }
            }
        }
        // Retry registration only when the watcher is (re)available; the
        // NameOwnerChanged handler drives re-registration, so a bounded retry
        // here just covers the very first startup before waybar is up.
        if (!app.item_registered and fds[0].revents == 0 and fds[1].revents == 0) {
            tryRegister(&app);
        }
    }
}

fn pollThread(app: *App) void {
    tray_common.runPollLoop(App, app, app.io, app.gpa, app.state, wake, true);
}

fn wake(app: *App) void {
    var v: u64 = 1;
    _ = linux.write(app.event_fd, std.mem.asBytes(&v), 8);
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 +
        @as(i64, @divTrunc(ts.nsec, @as(isize, std.time.ns_per_ms)));
}

/// Consume the poll thread's pending layer change and (re)arm the OSD. With no
/// configured delay the overlay shows immediately; otherwise the show is
/// deferred by `overlay_delay_ms`, re-arming with the latest layer each change.
fn drainLayerChanges(app: *App) void {
    const layer_idx = app.state.layer_change.swap(-1, .acq_rel);
    if (layer_idx < 0) return;
    if (!app.state.osd_enabled.load(.acquire)) return;
    if (app.osd == null) return;
    app.osd_pending_layer = @intCast(layer_idx);
    if (app.cfg.overlay_delay_ms == 0) {
        showOsdNow(app);
    } else {
        app.osd_show_at = nowMs() + @as(i64, app.cfg.overlay_delay_ms);
    }
}

/// Show the pending layer overlay now and arm its hide deadline.
fn showOsdNow(app: *App) void {
    app.osd_show_at = null;
    if (app.osd) |*o| {
        o.show(layer.displayNumber(app.osd_pending_layer));
        app.osd_hide_at = nowMs() + @as(i64, app.cfg.overlay_duration_ms);
    }
}

// ---------------------------------------------------------------------------
// Single instance.
// ---------------------------------------------------------------------------
fn acquireSingleton(runtime_dir: []const u8) ?i32 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/dygmate-tray.lock", .{runtime_dir}) catch return null;
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o600);
    if (@as(isize, @bitCast(rc)) < 0) return null;
    const fd: i32 = @intCast(rc);
    const frc = linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB);
    if (@as(isize, @bitCast(frc)) < 0) {
        _ = linux.close(fd);
        return null;
    }
    return fd; // intentionally leaked; released when the process exits
}

// ---------------------------------------------------------------------------
// Registration + watcher resilience.
// ---------------------------------------------------------------------------
fn requestName(app: *App) !void {
    var body = std.ArrayList(u8).empty;
    defer body.deinit(app.gpa);
    var w = dbus.Writer.init(&body, app.gpa);
    try w.string(app.item_name);
    try w.uint32(0); // flags
    _ = try app.conn.callAndWait(dbus_service, dbus_path, dbus_service, "RequestName", "su", body.items);
}

fn addWatcherMatch(conn: *dbus.Connection) !void {
    const rule = "type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='" ++ watcher_name ++ "'";
    var body = std.ArrayList(u8).empty;
    defer body.deinit(conn.gpa);
    var w = dbus.Writer.init(&body, conn.gpa);
    try w.string(rule);
    _ = try conn.callAndWait(dbus_service, dbus_path, dbus_service, "AddMatch", "s", body.items);
}

/// Attempt to register with the watcher; on success set item_registered. On
/// failure (watcher not up yet) leave it false so the main loop retries.
fn tryRegister(app: *App) void {
    registerItem(app) catch |e| {
        if (!app.register_fail_logged) {
            dlogErr("watcher registration failed: {s} (retrying until it appears)", .{@errorName(e)});
            app.register_fail_logged = true;
        }
        app.item_registered = false;
        return;
    };
    app.item_registered = true;
    app.register_fail_logged = false;
    dlog("registered with StatusNotifierWatcher", .{});
}

fn registerItem(app: *App) !void {
    var body = std.ArrayList(u8).empty;
    defer body.deinit(app.gpa);
    var w = dbus.Writer.init(&body, app.gpa);
    try w.string(app.item_name);
    _ = try app.conn.callAndWait(watcher_name, watcher_path, watcher_iface, "RegisterStatusNotifierItem", "s", body.items);
}

const watcher_iface = "org.kde.StatusNotifierWatcher";

fn reconnect(app: *App) void {
    dlogErr("session bus connection lost, reconnecting", .{});
    app.conn.deinit();
    app.item_registered = false;
    // Notification ids are daemon/connection-scoped; a new bus means a new slot.
    app.notify_id = 0;
    app.pending_notify_serial = null;
    while (!app.state.stop.load(.acquire)) {
        const conn = dbus.Connection.connectSession(app.io, app.gpa, app.environ, linux.getuid()) catch {
            tray_common.sleepMs(app.io, app.state, 1000);
            continue;
        };
        app.conn = conn;
        dlog("reconnected to session bus as {s}", .{conn.unique_name});
        addWatcherMatch(conn) catch |e| dlogErr("re-adding watcher match failed: {s}", .{@errorName(e)});
        requestName(app) catch |e| dlogErr("re-requesting bus name failed: {s}", .{@errorName(e)});
        tryRegister(app);
        return;
    }
}

// ---------------------------------------------------------------------------
// Rebuild display + emit change signals.
// ---------------------------------------------------------------------------
fn rebuildAndNotify(app: *App) void {
    app.state.mutex.lockUncancelable(app.io);
    const reading = app.state.reading;
    const unverified = app.state.unverified;
    const status = app.state.status;
    const model = app.state.model;
    const announce_pending = app.state.announce_connection and status == .connected and reading != null;
    app.state.mutex.unlock(app.io);
    const paused = app.state.paused.load(.acquire);
    // Snapshot the model before the notification block: notifyInner reads it
    // for titles/bodies, and the menu/tooltip pick 1- vs 2-sided rendering.
    app.model = model;
    app.unverified = unverified;

    if (tray_common.isLive(status, paused) and reading != null) {
        const r = reading.?;
        app.last.merge(r);

        // Notification LOGIC runs off the sticky-status snapshot (last real
        // per-side status), not the raw reading, so a momentarily-empty charging
        // status can't fire a false low-battery warning. Mirrors the Windows tray.
        const snapshot: battery.Reading = .{ .left = app.last.left, .right = app.last.right };
        // Render the notification BODY from the fresh-status view (leftText/
        // rightText), exactly like the menu and tooltip: the sticky status
        // clings to an old "disconnected" long after the level reads fine again,
        // so the body must drop that stale suffix once a poll's status comes back
        // empty ("40%", not "40% (disconnected)").
        const display: battery.Reading = .{ .left = app.last.leftText(), .right = app.last.rightText() };
        // Gate the announcement on the raw reading (fresh levels present for
        // every battery-reporting side), but latch from the sticky snapshot — a
        // stale last-known value surviving a reconnect must not fire the
        // announcement early.
        const announce_ready = tray_common.levelsKnown(model, r);
        const plan = tray_common.planNotificationsTracked(&app.state.notified_low, &app.state.notified_empty, announce_pending, announce_ready, snapshot, unverified, tray_common.nowMs(app.io), &app.state.last_notified_ms);
        for (plan.events) |ev_opt| {
            if (ev_opt) |ev| sendNotification(app, ev, display);
        }
        if (plan.consumed_announce) {
            app.state.mutex.lockUncancelable(app.io);
            app.state.announce_connection = false;
            app.state.mutex.unlock(app.io);
        }
    } else {
        app.state.notified_low = .{ false, false };
        app.state.notified_empty = .{ false, false };
    }
    app.status = status;
    app.paused = paused;
    dlog("update: status={s} paused={} left={?d}% right={?d}%", .{
        @tagName(status), paused, app.last.left.level, app.last.right.level,
    });

    // Icon: show '?' only for true USB absence. Available/paused keep the
    // gray last-known display, with '--' reserved for "no reading yet".
    const live = tray_common.isLive(status, paused);
    const disp = app.last.display(tray_common.hiddenSides(unverified));
    if (!paused and status == .missing) {
        renderIcon(&app.icon_buf, "?", tray_common.palette.gray);
    } else if (live and app.last.allSidesFull(model)) {
        // Both sides topped off → the full 🔋 glyph, regardless of status.
        renderBattery(&app.icon_buf, tray_common.battery_full_rgba, tray_common.iconColor(live, 100, disp.status));
    } else if (disp.level) |lvl| {
        const color = tray_common.iconColor(live, lvl, disp.status);
        if (live and disp.status == .charging) {
            // Charging (and not yet full): the battery-with-bolt glyph.
            renderBattery(&app.icon_buf, tray_common.battery_charging_rgba, color);
        } else {
            var num_buf: [4]u8 = undefined;
            const txt = std.fmt.bufPrint(&num_buf, "{d}", .{lvl}) catch "--";
            renderIcon(&app.icon_buf, txt, color);
        }
    } else {
        renderIcon(&app.icon_buf, "--", tray_common.palette.gray);
    }

    // Tooltip body: last-known values per battery-reporting side.
    var lb: [40]u8 = undefined;
    var rb: [40]u8 = undefined;
    const one_sided = if (model) |m| m.sides() < 2 else false;
    const tip = if (one_sided)
        std.fmt.bufPrint(&app.tip_body, "Battery: {s}", .{
            tray_common.fmtKnownSide(&lb, app.last.leftText(), unverified[0]),
        }) catch app.tip_body[0..0]
    else
        std.fmt.bufPrint(&app.tip_body, "Left: {s}\nRight: {s}", .{
            tray_common.fmtKnownSide(&lb, app.last.leftText(), unverified[0]),
            tray_common.fmtKnownSide(&rb, app.last.rightText(), unverified[1]),
        }) catch app.tip_body[0..0];
    app.tip_body_len = tip.len;

    app.menu_revision += 1;

    // Push updates. The host pulls the fresh property values in response.
    app.conn.emitSignal(item_path, item_iface, "NewIcon", null, &.{}) catch {};
    app.conn.emitSignal(item_path, item_iface, "NewToolTip", null, &.{}) catch {};
    emitLayoutUpdated(app) catch {};
}

fn emitLayoutUpdated(app: *App) !void {
    var body = std.ArrayList(u8).empty;
    defer body.deinit(app.gpa);
    var w = dbus.Writer.init(&body, app.gpa);
    try w.uint32(app.menu_revision);
    try w.int32(0); // parent id
    try app.conn.emitSignal(menu_path, menu_iface, "LayoutUpdated", "ui", body.items);
}

// ---------------------------------------------------------------------------
// Desktop notifications (org.freedesktop.Notifications).
// ---------------------------------------------------------------------------
/// Fire-and-forget: a missing/broken daemon must never break the tray, so any
/// failure is swallowed. The reply (the assigned id) is picked up async in
/// dispatch; callAndWait would drop concurrent incoming menu calls (dbus.zig).
fn sendNotification(app: *App, ev: tray_common.NotifyEvent, snapshot: battery.Reading) void {
    notifyInner(app, ev, snapshot) catch |e| {
        dlogErr("notification failed: {s}", .{@errorName(e)});
        return;
    };
    dlog("notification sent: {s}", .{@tagName(ev.kind)});
}

fn notifyInner(app: *App, ev: tray_common.NotifyEvent, snapshot: battery.Reading) !void {
    var body_buf: [128]u8 = undefined;
    var title: []const u8 = undefined;
    var text: []const u8 = undefined;
    switch (ev.kind) {
        .connect_status => {
            title = tray_common.notificationTitleStatus(app.model);
            text = tray_common.fmtStatusBody(&body_buf, app.model, snapshot);
        },
        .low_battery => {
            title = tray_common.notificationTitleLow(app.model);
            text = tray_common.fmtLowBody(&body_buf, app.model, ev.side.?, ev.level.?);
        },
        .empty_battery => {
            title = tray_common.notificationTitleEmpty(app.model);
            text = tray_common.fmtEmptyBody(&body_buf, app.model, ev.side_mask);
        },
    }
    const app_icon: []const u8 = if (ev.warning) "battery-caution" else "battery";
    const urgency: u8 = if (ev.warning) 2 else 1; // 2 = critical, 1 = normal

    var body = std.ArrayList(u8).empty;
    defer body.deinit(app.gpa);
    var w = dbus.Writer.init(&body, app.gpa);
    // Notify(app_name s, replaces_id u, app_icon s, summary s, body s,
    //        actions as, hints a{sv}, expire_timeout i)  ->  id u
    try w.string("dygmate");
    try w.uint32(app.notify_id);
    try w.string(app_icon);
    try w.string(title);
    try w.string(text);
    const actions = try w.beginArray(4); // as: no action buttons
    w.endArray(actions);
    const hints = try w.beginArray(8); // a{sv}
    try w.beginStruct(); // dict entry, 8-aligned
    try w.string("urgency");
    try w.signature("y");
    try w.byte(urgency);
    w.endArray(hints);
    try w.int32(-1); // expire_timeout: daemon default

    const serial = try app.conn.call(
        notifications_service,
        notifications_path,
        notifications_service, // interface == destination
        "Notify",
        "susssasa{sv}i",
        body.items,
    );
    app.pending_notify_serial = serial;
}

// ---------------------------------------------------------------------------
// Incoming message dispatch.
// ---------------------------------------------------------------------------
fn dispatch(app: *App, msg: dbus.Message) !void {
    if (msg.type == .signal) {
        if (eql(msg.member, "NameOwnerChanged")) handleNameOwnerChanged(app, msg);
        return;
    }
    // The only fire-and-forget call is Notify (all others use callAndWait, which
    // consumes their reply inline). So a method_return here is a Notify reply:
    // capture the daemon-assigned id for the next replaces_id.
    if (msg.type == .method_return or msg.type == .error_reply) {
        if (app.pending_notify_serial) |serial| {
            if (msg.reply_serial == serial) {
                if (msg.type == .method_return) {
                    var r = dbus.Reader{ .data = msg.body };
                    if (r.uint32()) |id| app.notify_id = id else |_| {}
                }
                app.pending_notify_serial = null;
            }
        }
        return;
    }
    if (msg.type != .method_call) return;

    const iface = msg.interface orelse "";
    const member = msg.member orelse "";
    dlog("method call {s}.{s}", .{ iface, member });

    if (std.mem.eql(u8, iface, props_iface)) {
        if (std.mem.eql(u8, member, "Get")) return handlePropGet(app, msg);
        if (std.mem.eql(u8, member, "GetAll")) return handlePropGetAll(app, msg);
    } else if (std.mem.eql(u8, iface, item_iface)) {
        if (std.mem.eql(u8, member, "Activate") or std.mem.eql(u8, member, "SecondaryActivate")) {
            app.state.refresh.store(true, .release);
            return app.conn.reply(msg, null, &.{});
        }
        if (std.mem.eql(u8, member, "Scroll")) return app.conn.reply(msg, null, &.{});
    } else if (std.mem.eql(u8, iface, menu_iface)) {
        return dispatchMenu(app, msg, member);
    }

    try app.conn.replyError(msg, "org.freedesktop.DBus.Error.UnknownMethod", "unhandled");
}

fn handleNameOwnerChanged(app: *App, msg: dbus.Message) void {
    var r = dbus.Reader{ .data = msg.body };
    const name = r.string() catch return;
    _ = r.string() catch return; // old owner
    const new_owner = r.string() catch return;
    if (std.mem.eql(u8, name, watcher_name) and new_owner.len > 0) {
        dlog("watcher owner changed to '{s}', re-registering", .{new_owner});
        app.item_registered = false;
        tryRegister(app);
    }
}

fn eql(opt: ?[]const u8, s: []const u8) bool {
    return opt != null and std.mem.eql(u8, opt.?, s);
}

// ---------------------------------------------------------------------------
// org.freedesktop.DBus.Properties.
// ---------------------------------------------------------------------------
fn handlePropGet(app: *App, msg: dbus.Message) !void {
    var r = dbus.Reader{ .data = msg.body };
    const iface = try r.string();
    const prop = try r.string();

    var body = std.ArrayList(u8).empty;
    defer body.deinit(app.gpa);
    var w = dbus.Writer.init(&body, app.gpa);

    const ok = if (std.mem.eql(u8, iface, item_iface))
        try writeItemProp(app, &w, prop)
    else if (std.mem.eql(u8, iface, menu_iface))
        try writeMenuProp(&w, prop)
    else
        false;

    if (!ok) return app.conn.replyError(msg, "org.freedesktop.DBus.Error.InvalidArgs", "no such property");
    try app.conn.reply(msg, "v", body.items);
}

fn handlePropGetAll(app: *App, msg: dbus.Message) !void {
    var r = dbus.Reader{ .data = msg.body };
    const iface = try r.string();

    var body = std.ArrayList(u8).empty;
    defer body.deinit(app.gpa);
    var w = dbus.Writer.init(&body, app.gpa);

    const tok = try w.beginArray(8); // a{sv}
    if (std.mem.eql(u8, iface, item_iface)) {
        for (item_props) |name| {
            try w.beginStruct();
            try w.string(name);
            _ = try writeItemProp(app, &w, name);
        }
    } else if (std.mem.eql(u8, iface, menu_iface)) {
        for (menu_props) |name| {
            try w.beginStruct();
            try w.string(name);
            _ = try writeMenuProp(&w, name);
        }
    }
    w.endArray(tok);
    try app.conn.reply(msg, "a{sv}", body.items);
}

const item_props = [_][]const u8{
    "Category", "Id", "Title", "Status", "IconName", "IconPixmap", "ToolTip", "ItemIsMenu", "Menu", "WindowId",
};

fn writeItemProp(app: *App, w: *dbus.Writer, name: []const u8) !bool {
    if (std.mem.eql(u8, name, "Category")) {
        try vStr(w, "Hardware");
    } else if (std.mem.eql(u8, name, "Id")) {
        try vStr(w, "dygmate");
    } else if (std.mem.eql(u8, name, "Title")) {
        try vStr(w, "dygmate");
    } else if (std.mem.eql(u8, name, "Status")) {
        try vStr(w, "Active");
    } else if (std.mem.eql(u8, name, "IconName")) {
        try vStr(w, "");
    } else if (std.mem.eql(u8, name, "IconPixmap")) {
        try vPixmap(w, app.icon_buf[0..]);
    } else if (std.mem.eql(u8, name, "ToolTip")) {
        try vToolTip(w, "dygmate", app.tipBody());
    } else if (std.mem.eql(u8, name, "ItemIsMenu")) {
        try vBool(w, false);
    } else if (std.mem.eql(u8, name, "Menu")) {
        try vObjPath(w, menu_path);
    } else if (std.mem.eql(u8, name, "WindowId")) {
        try vU32(w, 0);
    } else return false;
    return true;
}

// ---------------------------------------------------------------------------
// Variant writers.
// ---------------------------------------------------------------------------
fn vStr(w: *dbus.Writer, s: []const u8) !void {
    try w.signature("s");
    try w.string(s);
}
fn vBool(w: *dbus.Writer, b: bool) !void {
    try w.signature("b");
    try w.boolean(b);
}
fn vU32(w: *dbus.Writer, v: u32) !void {
    try w.signature("u");
    try w.uint32(v);
}
fn vI32(w: *dbus.Writer, v: i32) !void {
    try w.signature("i");
    try w.int32(v);
}
fn vObjPath(w: *dbus.Writer, s: []const u8) !void {
    try w.signature("o");
    try w.objectPath(s);
}
fn vPixmap(w: *dbus.Writer, buf: []const u8) !void {
    try w.signature("a(iiay)");
    const outer = try w.beginArray(8);
    try w.beginStruct();
    try w.int32(@intCast(icon_px));
    try w.int32(@intCast(icon_px));
    const inner = try w.beginArray(1);
    try w.bytes(buf);
    w.endArray(inner);
    w.endArray(outer);
}
fn vToolTip(w: *dbus.Writer, title: []const u8, body: []const u8) !void {
    try w.signature("(sa(iiay)ss)");
    try w.beginStruct();
    try w.string(""); // icon name
    const px = try w.beginArray(8); // empty pixmap array
    w.endArray(px);
    try w.string(title);
    try w.string(body);
}

// ---------------------------------------------------------------------------
// com.canonical.dbusmenu server.
// ---------------------------------------------------------------------------
const MenuId = enum(i32) {
    root = 0,
    status = 1,
    left = 2,
    right = 3,
    sep = 4,
    refresh = 5,
    toggle = 6,
    osd = 7,
    quit = 8,
    update = 9,
    sep2 = 10,
    version = 11,
};

const menu_props = [_][]const u8{ "Version", "Status", "TextDirection" };

fn writeMenuProp(w: *dbus.Writer, name: []const u8) !bool {
    if (std.mem.eql(u8, name, "Version")) {
        try vU32(w, 3);
    } else if (std.mem.eql(u8, name, "Status")) {
        try vStr(w, "normal");
    } else if (std.mem.eql(u8, name, "TextDirection")) {
        try vStr(w, "ltr");
    } else return false;
    return true;
}

fn dispatchMenu(app: *App, msg: dbus.Message, member: []const u8) !void {
    if (std.mem.eql(u8, member, "GetLayout")) return menuGetLayout(app, msg);
    if (std.mem.eql(u8, member, "GetGroupProperties")) return menuGetGroupProperties(app, msg);
    if (std.mem.eql(u8, member, "Event")) return menuEvent(app, msg);
    if (std.mem.eql(u8, member, "EventGroup")) return menuEventGroup(app, msg);
    if (std.mem.eql(u8, member, "AboutToShow")) {
        // Reply false: no layout change needed simply to show. Signature "b".
        var body = std.ArrayList(u8).empty;
        defer body.deinit(app.gpa);
        var w = dbus.Writer.init(&body, app.gpa);
        try w.boolean(false);
        return app.conn.reply(msg, "b", body.items);
    }
    if (std.mem.eql(u8, member, "AboutToShowGroup")) {
        // (updatesNeeded ai, idErrors ai): both empty, nothing needs updating.
        var body = std.ArrayList(u8).empty;
        defer body.deinit(app.gpa);
        var w = dbus.Writer.init(&body, app.gpa);
        const updates = try w.beginArray(4);
        w.endArray(updates);
        const errors = try w.beginArray(4);
        w.endArray(errors);
        return app.conn.reply(msg, "aiai", body.items);
    }
    try app.conn.replyError(msg, "org.freedesktop.DBus.Error.UnknownMethod", "unhandled menu method");
}

/// The menu items, in display order, with their current labels.
const MenuItem = struct {
    id: MenuId,
    label: []const u8,
    enabled: bool,
    separator: bool = false,
    /// Non-null renders a dbusmenu checkmark.
    checked: ?bool = null,
};

/// Fill `out` with the current menu, returning the populated prefix. The update
/// item is present only after the background check has found a newer release.
fn buildMenuItems(app: *App, buf: *[3][48]u8, out: *[11]MenuItem) []const MenuItem {
    const header = tray_common.menuHeader(app.status, app.paused);

    var sb: [24]u8 = undefined;
    const one_sided = if (app.model) |m| m.sides() < 2 else false;
    const toggle_label: []const u8 = if (app.paused) "Reconnect" else "Disconnect (release port for Bazecor)";

    var n: usize = 0;
    out[n] = .{ .id = .status, .label = header, .enabled = false };
    n += 1;
    if (one_sided) {
        const battery_label: []const u8 = std.fmt.bufPrint(&buf[0], "Battery: {s}", .{tray_common.fmtMenuSide(&sb, app.last.leftText(), app.unverified[0])}) catch "Battery: ?";
        out[n] = .{ .id = .left, .label = battery_label, .enabled = false };
        n += 1;
    } else {
        const left_label: []const u8 = std.fmt.bufPrint(&buf[0], "Left: {s}", .{tray_common.fmtMenuSide(&sb, app.last.leftText(), app.unverified[0])}) catch "Left: ?";
        const right_label: []const u8 = std.fmt.bufPrint(&buf[1], "Right: {s}", .{tray_common.fmtMenuSide(&sb, app.last.rightText(), app.unverified[1])}) catch "Right: ?";
        out[n] = .{ .id = .left, .label = left_label, .enabled = false };
        n += 1;
        out[n] = .{ .id = .right, .label = right_label, .enabled = false };
        n += 1;
    }
    out[n] = .{ .id = .sep, .label = "", .enabled = false, .separator = true };
    n += 1;
    out[n] = .{ .id = .refresh, .label = "Refresh battery now", .enabled = true };
    n += 1;
    out[n] = .{ .id = .toggle, .label = toggle_label, .enabled = true };
    n += 1;
    out[n] = .{
        .id = .osd,
        .label = "Show layer overlay",
        .enabled = if (app.osd) |*o| o.alive() else false,
        .checked = app.state.osd_enabled.load(.acquire),
    };
    n += 1;
    if (app.update.isAvailable()) {
        out[n] = .{ .id = .update, .label = app.update.label(), .enabled = true };
        n += 1;
    }
    out[n] = .{ .id = .sep2, .label = "", .enabled = false, .separator = true };
    n += 1;
    out[n] = .{ .id = .version, .label = "Version: dygmate " ++ build_options.version, .enabled = false };
    n += 1;
    out[n] = .{ .id = .quit, .label = "Quit", .enabled = true };
    n += 1;
    return out[0..n];
}

/// GetLayout(parentId i, recursionDepth i, propertyNames as) ->
///   (revision u, layout (ia{sv}av)).
fn menuGetLayout(app: *App, msg: dbus.Message) !void {
    var line: [3][48]u8 = undefined;
    var item_buf: [11]MenuItem = undefined;
    const items = buildMenuItems(app, &line, &item_buf);

    var body = std.ArrayList(u8).empty;
    defer body.deinit(app.gpa);
    var w = dbus.Writer.init(&body, app.gpa);

    try w.uint32(app.menu_revision);

    // Root item (id 0): empty props, children = the menu items as variants.
    try w.beginStruct(); // (ia{sv}av)
    try w.int32(0);
    try writeEmptyProps(&w);
    const children = try w.beginArray(1); // av: element is a variant (align 1)
    for (items) |it| {
        // Each child is a variant whose value is (ia{sv}av).
        try w.signature("(ia{sv}av)");
        try writeMenuNode(&w, it);
    }
    w.endArray(children);

    try app.conn.reply(msg, "u(ia{sv}av)", body.items);
}

/// Write one leaf menu node: (id a{sv} children[]). Leaf → no children.
fn writeMenuNode(w: *dbus.Writer, it: MenuItem) !void {
    try w.beginStruct(); // (ia{sv}av)
    try w.int32(@intFromEnum(it.id));

    // a{sv} props
    const props = try w.beginArray(8);
    if (it.separator) {
        try w.beginStruct();
        try w.string("type");
        try vStr(w, "separator");
    } else {
        try w.beginStruct();
        try w.string("label");
        try vStr(w, it.label);
        try w.beginStruct();
        try w.string("enabled");
        try vBool(w, it.enabled);
        try w.beginStruct();
        try w.string("visible");
        try vBool(w, true);
        if (it.checked) |on| {
            try w.beginStruct();
            try w.string("toggle-type");
            try vStr(w, "checkmark");
            try w.beginStruct();
            try w.string("toggle-state");
            try vI32(w, if (on) 1 else 0);
        }
    }
    w.endArray(props);

    // av children (none for leaves): element is a variant (align 1).
    const kids = try w.beginArray(1);
    w.endArray(kids);
}

fn writeEmptyProps(w: *dbus.Writer) !void {
    const tok = try w.beginArray(8); // a{sv}
    w.endArray(tok);
}

/// GetGroupProperties(ids ai, propertyNames as) -> a(ia{sv}).
fn menuGetGroupProperties(app: *App, msg: dbus.Message) !void {
    var line: [3][48]u8 = undefined;
    var item_buf: [11]MenuItem = undefined;
    const items = buildMenuItems(app, &line, &item_buf);

    var r = dbus.Reader{ .data = msg.body };
    const ids_end = try r.arrayEnd(4);
    var requested: [16]i32 = undefined;
    var n_req: usize = 0;
    while (r.pos < ids_end and n_req < requested.len) : (n_req += 1) {
        requested[n_req] = @bitCast(try r.uint32());
    }

    var body = std.ArrayList(u8).empty;
    defer body.deinit(app.gpa);
    var w = dbus.Writer.init(&body, app.gpa);

    const outer = try w.beginArray(8); // a(ia{sv})
    for (items) |it| {
        const id = @intFromEnum(it.id);
        if (n_req > 0 and !containsId(requested[0..n_req], id)) continue;
        try w.beginStruct(); // (ia{sv})
        try w.int32(id);
        const props = try w.beginArray(8);
        if (it.separator) {
            try w.beginStruct();
            try w.string("type");
            try vStr(&w, "separator");
        } else {
            try w.beginStruct();
            try w.string("label");
            try vStr(&w, it.label);
            try w.beginStruct();
            try w.string("enabled");
            try vBool(&w, it.enabled);
            try w.beginStruct();
            try w.string("visible");
            try vBool(&w, true);
            if (it.checked) |on| {
                try w.beginStruct();
                try w.string("toggle-type");
                try vStr(&w, "checkmark");
                try w.beginStruct();
                try w.string("toggle-state");
                try vI32(&w, if (on) 1 else 0);
            }
        }
        w.endArray(props);
    }
    w.endArray(outer);

    try app.conn.reply(msg, "a(ia{sv})", body.items);
}

fn containsId(ids: []const i32, id: i32) bool {
    for (ids) |x| if (x == id) return true;
    return false;
}

/// Event(id i, eventId s, data v, timestamp u).
fn menuEvent(app: *App, msg: dbus.Message) !void {
    var r = dbus.Reader{ .data = msg.body };
    const id = @as(i32, @bitCast(try r.uint32()));
    const event_id = try r.string();

    if (std.mem.eql(u8, event_id, "clicked")) applyClicked(app, id);
    try app.conn.reply(msg, null, &.{});
}

/// EventGroup(events a(isvu)) -> (idErrors ai). Waybar's libdbusmenu client
/// delivers menu clicks through this batched form, never plain Event.
fn menuEventGroup(app: *App, msg: dbus.Message) !void {
    applyEventGroup(app, msg.body) catch {
        // Reply something: a swallowed parse error would leave the caller
        // waiting for its timeout.
        return app.conn.replyError(msg, "org.freedesktop.DBus.Error.InvalidArgs", "malformed event group");
    };
    var body = std.ArrayList(u8).empty;
    defer body.deinit(app.gpa);
    var w = dbus.Writer.init(&body, app.gpa);
    const tok = try w.beginArray(4); // ai: no unknown ids
    w.endArray(tok);
    try app.conn.reply(msg, "ai", body.items);
}

/// Walk an a(isvu) event batch and apply every "clicked" entry.
fn applyEventGroup(app: *App, body: []const u8) !void {
    var r = dbus.Reader{ .data = body };
    const end = try r.arrayEnd(8);
    if (end > body.len) return error.Malformed;
    while (r.pos < end) {
        r.readAlign(8); // struct boundary
        const id = @as(i32, @bitCast(try r.uint32()));
        const event_id = try r.string();
        try skipVariant(&r);
        _ = try r.uint32(); // timestamp
        if (std.mem.eql(u8, event_id, "clicked")) applyClicked(app, id);
    }
}

/// Skip a variant's signature and value. Only the fixed/simple types a
/// dbusmenu event's data slot carries in practice are supported.
fn skipVariant(r: *dbus.Reader) !void {
    const sig = try r.signature();
    if (sig.len != 1) return error.Malformed;
    switch (sig[0]) {
        'y' => _ = try r.byte(),
        'n', 'q' => _ = try r.uint16(),
        'b', 'i', 'u' => _ = try r.uint32(),
        's', 'o' => _ = try r.string(),
        'g' => _ = try r.signature(),
        else => return error.Malformed,
    }
}

fn applyClicked(app: *App, id: i32) void {
    // A host is free to send any id; an out-of-range @enumFromInt would be
    // safety-checked illegal behavior, so reject unknown ids explicitly.
    const menu_id = std.enums.fromInt(MenuId, id) orelse {
        dlog("menu click on unknown id {d}, ignored", .{id});
        return;
    };
    dlog("menu click: {s}", .{@tagName(menu_id)});
    switch (menu_id) {
        .refresh => app.state.refresh.store(true, .release),
        .toggle => {
            const now_paused = !app.state.paused.load(.acquire);
            app.state.paused.store(now_paused, .release);
            if (!now_paused) app.state.refresh.store(true, .release);
            wake(app); // reflect the new state in the icon/menu promptly
        },
        .osd => {
            const o = if (app.osd) |*value| value else {
                app.state.osd_enabled.store(false, .release);
                return;
            };
            if (!o.alive()) {
                app.state.osd_enabled.store(false, .release);
                return;
            }
            const enabled = !app.state.osd_enabled.load(.acquire);
            app.state.osd_enabled.store(enabled, .release);
            app.cfg.show_layer_overlay = enabled;
            config.save(app.io, app.gpa, app.environ, app.cfg);
            app.state.layer_change.store(-1, .release);
            if (!enabled) {
                o.hide();
                app.osd_hide_at = null;
                app.osd_show_at = null;
            }
            // The menu dispatch owns the Wayland socket, so hide() is safe here.
            app.menu_revision += 1;
            emitLayoutUpdated(app) catch {};
        },
        .update => openReleasePage(app),
        .quit => {
            app.state.stop.store(true, .release);
            wake(app);
        },
        else => {},
    }
}

/// Open the release page in the user's browser. Runs on a detached thread with
/// its own io so a slow-launching browser never stalls the D-Bus dispatch loop.
fn openReleasePage(app: *App) void {
    const t = std.Thread.spawn(.{}, openUrlWorker, .{app}) catch |e| {
        dlogErr("open release page: {s}", .{@errorName(e)});
        return;
    };
    t.detach();
}

fn openUrlWorker(app: *App) void {
    var threaded = std.Io.Threaded.init(app.gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var child = std.process.spawn(io, .{
        .argv = &.{ "xdg-open", app.update.url() },
        // Inherit the real session env so xdg-open sees DISPLAY / DBUS / HOME.
        .environ_map = app.environ,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |e| {
        dlogErr("xdg-open spawn failed: {s}", .{@errorName(e)});
        return;
    };
    _ = child.wait(io) catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
test {
    // Pull in D-Bus, shared planner, Wayland, OSD, and status IPC unit tests.
    _ = @import("dbus.zig");
    _ = @import("tray_common.zig");
    _ = @import("wayland.zig");
    _ = @import("osd_linux.zig");
    _ = @import("update.zig");
    _ = @import("statusserver.zig");
}

test "renderIcon fills background color at a corner pixel" {
    var buf: IconBuf = undefined;
    const c = tray_common.Rgb{ .r = 46, .g = 160, .b = 67 };
    renderIcon(&buf, "50", c);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[0]); // A
    try std.testing.expectEqual(@as(u8, 46), buf[1]); // R
    try std.testing.expectEqual(@as(u8, 160), buf[2]); // G
    try std.testing.expectEqual(@as(u8, 67), buf[3]); // B
}

test "renderIcon draws at least one white text pixel for a digit" {
    var buf: IconBuf = undefined;
    renderIcon(&buf, "8", tray_common.Rgb{ .r = 46, .g = 160, .b = 67 });
    var found_white = false;
    var i: usize = 0;
    while (i < buf.len) : (i += 4) {
        if (buf[i + 1] == 255 and buf[i + 2] == 255 and buf[i + 3] == 255) found_white = true;
    }
    try std.testing.expect(found_white);
}

test "renderIcon draws at least one white text pixel for question mark" {
    var buf: IconBuf = undefined;
    renderIcon(&buf, "?", tray_common.Rgb{ .r = 110, .g = 110, .b = 110 });
    var found_white = false;
    var i: usize = 0;
    while (i < buf.len) : (i += 4) {
        if (buf[i + 1] == 255 and buf[i + 2] == 255 and buf[i + 3] == 255) found_white = true;
    }
    try std.testing.expect(found_white);
}

test "EventGroup clicked event toggles pause state" {
    var state: tray_common.State = .{};
    var app = App{
        .io = undefined,
        .gpa = undefined,
        .conn = undefined,
        .environ = undefined,
        .state = &state,
        .event_fd = -1,
        .item_name = "",
    };

    // Marshal a(isvu) with one clicked event on the pause/resume item, the
    // exact shape waybar's libdbusmenu client sends.
    var body = std.ArrayList(u8).empty;
    defer body.deinit(std.testing.allocator);
    var w = dbus.Writer.init(&body, std.testing.allocator);
    const tok = try w.beginArray(8);
    try w.beginStruct();
    try w.int32(@intFromEnum(MenuId.toggle));
    try w.string("clicked");
    try w.signature("i");
    try w.int32(0);
    try w.uint32(14559246);
    w.endArray(tok);

    try applyEventGroup(&app, body.items);
    try std.testing.expect(state.paused.load(.acquire));
}

test "EventGroup clicked event on OSD item without an OSD disables it" {
    var state: tray_common.State = .{};
    var app = App{
        .io = undefined,
        .gpa = undefined,
        .conn = undefined,
        .environ = undefined,
        .state = &state,
        .event_fd = -1,
        .item_name = "",
    };
    try std.testing.expect(state.osd_enabled.load(.acquire));

    var body = std.ArrayList(u8).empty;
    defer body.deinit(std.testing.allocator);
    var w = dbus.Writer.init(&body, std.testing.allocator);
    const tok = try w.beginArray(8);
    try w.beginStruct();
    try w.int32(@intFromEnum(MenuId.osd));
    try w.string("clicked");
    try w.signature("i");
    try w.int32(0);
    try w.uint32(14559246);
    w.endArray(tok);

    try applyEventGroup(&app, body.items);
    try std.testing.expect(!state.osd_enabled.load(.acquire));
}

test "EventGroup with two events applies both" {
    var state: tray_common.State = .{};
    var app = App{
        .io = undefined,
        .gpa = undefined,
        .conn = undefined,
        .environ = undefined,
        .state = &state,
        .event_fd = -1,
        .item_name = "",
    };

    var body = std.ArrayList(u8).empty;
    defer body.deinit(std.testing.allocator);
    var w = dbus.Writer.init(&body, std.testing.allocator);
    const tok = try w.beginArray(8);
    try w.beginStruct();
    try w.int32(@intFromEnum(MenuId.refresh));
    try w.string("clicked");
    try w.signature("i");
    try w.int32(0);
    try w.uint32(1);
    try w.beginStruct();
    try w.int32(@intFromEnum(MenuId.toggle));
    try w.string("clicked");
    try w.signature("i");
    try w.int32(0);
    try w.uint32(2);
    w.endArray(tok);

    try applyEventGroup(&app, body.items);
    try std.testing.expect(state.refresh.load(.acquire));
    try std.testing.expect(state.paused.load(.acquire));
}

test "EventGroup with a truncated body errors instead of misreading" {
    var state: tray_common.State = .{};
    var app = App{
        .io = undefined,
        .gpa = undefined,
        .conn = undefined,
        .environ = undefined,
        .state = &state,
        .event_fd = -1,
        .item_name = "",
    };

    var body = std.ArrayList(u8).empty;
    defer body.deinit(std.testing.allocator);
    var w = dbus.Writer.init(&body, std.testing.allocator);
    const tok = try w.beginArray(8);
    try w.beginStruct();
    try w.int32(@intFromEnum(MenuId.toggle));
    try w.string("clicked");
    try w.signature("i");
    try w.int32(0);
    try w.uint32(1);
    w.endArray(tok);

    // Cut the marshalled batch short: the declared array length now points
    // past the available bytes.
    const truncated = body.items[0 .. body.items.len - 6];
    try std.testing.expectError(error.Malformed, applyEventGroup(&app, truncated));
    try std.testing.expect(!state.paused.load(.acquire));
}

test "EventGroup with an unknown menu id is ignored without crashing" {
    var state: tray_common.State = .{};
    var app = App{
        .io = undefined,
        .gpa = undefined,
        .conn = undefined,
        .environ = undefined,
        .state = &state,
        .event_fd = -1,
        .item_name = "",
    };

    var body = std.ArrayList(u8).empty;
    defer body.deinit(std.testing.allocator);
    var w = dbus.Writer.init(&body, std.testing.allocator);
    const tok = try w.beginArray(8);
    try w.beginStruct();
    try w.int32(99);
    try w.string("clicked");
    try w.signature("i");
    try w.int32(0);
    try w.uint32(1);
    w.endArray(tok);

    try applyEventGroup(&app, body.items);
    try std.testing.expect(!state.paused.load(.acquire));
    try std.testing.expect(!state.refresh.load(.acquire));
    try std.testing.expect(!state.stop.load(.acquire));
}

test "missing menu header is exact" {
    var state: tray_common.State = .{};
    var app = App{
        .io = undefined,
        .gpa = undefined,
        .conn = undefined,
        .environ = undefined,
        .state = &state,
        .event_fd = -1,
        .item_name = "",
    };
    app.status = .missing;
    app.paused = false;
    var buf: [3][48]u8 = undefined;
    var item_buf: [11]MenuItem = undefined;
    const items = buildMenuItems(&app, &buf, &item_buf);
    try std.testing.expectEqualStrings("No keyboard discovered", items[0].label);
}
