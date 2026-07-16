//! Local IPC status feed for external status bars (yasb, waybar, ...).
//!
//! Serves the tray's latest battery snapshot as one JSON line per client
//! connection: a named pipe (`\\.\pipe\dygmate`) on Windows, a unix socket
//! (`$XDG_RUNTIME_DIR/dygmate/status.sock`) on Linux. One-shot protocol:
//! connect -> read the line -> EOF, so `cmd /c type \\.\pipe\dygmate` and
//! `socat -u UNIX-CONNECT:... -` both work as poll commands. Windows uses
//! raw named-pipe externs rather than std.Io.net: the 0.16 AFD socket layer
//! offers nothing a shell-spawning status bar could read anyway.
//!
//! Best-effort by design, like config.zig: a failed spawn, bind, or write
//! never blocks or crashes the tray. The poll thread publishes pre-rendered
//! snapshots; the server thread only copies bytes.

const std = @import("std");
const builtin = @import("builtin");
const battery = @import("battery.zig");
const device = @import("device.zig");

/// A non-charging side below this level renders `"low": true`. Single source
/// for the tray's threshold; tray_common re-exports it.
pub const low_threshold: u8 = 20;

pub const ConnState = enum { missing, available, connected, paused };

pub const StartOptions = struct {
    /// Linux: directory holding `dygmate/status.sock` (XDG_RUNTIME_DIR or
    /// /tmp). Ignored on Windows.
    runtime_dir: []const u8 = "/tmp",
};

/// Generous bound for one rendered snapshot (worst case is < 400 bytes).
const json_cap = 768;

// Snapshot + rendered JSON, shared between the publisher (poll thread) and
// the server thread. Io.Mutex is safe across distinct Threaded io instances:
// its futex ops act on the raw atomic address process-wide.
var mu: std.Io.Mutex = .init;
var snap: Snapshot = .{};
var json_buf: [json_cap]u8 = undefined;
var json_len: usize = 0;

var server_thread: ?std.Thread = null;
var stop_flag: std.atomic.Value(bool) = .init(false);
var srv_gpa: std.mem.Allocator = undefined;
var sock_path: ?[]u8 = null; // Linux only

const Snapshot = struct {
    state: ConnState = .missing,
    model: ?device.Model = null,
    left: battery.SideReading = .{ .level = null, .status = .unknown },
    right: battery.SideReading = .{ .level = null, .status = .unknown },
    /// Per side (0=left, 1=right): the value awaits authoritative
    /// verification and renders hidden, mirroring the tray's "?" display.
    hide: [2]bool = .{ false, false },
    updated: i64 = 0,
};

// ---------------------------------------------------------------------------
// Publishing (called from the tray poll thread).
// ---------------------------------------------------------------------------
/// Publish an accepted (plausibility-gated) reading. Merges per field like
/// the tray's LastKnown: a half-asleep side keeps its last real value.
pub fn publishReading(
    io: std.Io,
    model: ?device.Model,
    left: battery.SideReading,
    right: battery.SideReading,
    hide: [2]bool,
) void {
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    snap.state = .connected;
    snap.model = model;
    mergeSide(&snap.left, left);
    mergeSide(&snap.right, right);
    snap.hide = hide;
    snap.updated = nowSeconds(io);
    json_len = render(&json_buf, snap).len;
}

/// Publish a connection-state change. Levels and model stay as last known so
/// the bar can keep showing them; `connected: false` marks them stale.
pub fn publishConnState(io: std.Io, state: ConnState) void {
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    snap.state = state;
    snap.updated = nowSeconds(io);
    json_len = render(&json_buf, snap).len;
}

fn mergeSide(dst: *battery.SideReading, src: battery.SideReading) void {
    if (src.level != null) dst.level = src.level;
    if (src.status != .unknown) dst.status = src.status;
}

fn nowSeconds(io: std.Io) i64 {
    const ts = std.Io.Clock.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.raw.nanoseconds, std.time.ns_per_s));
}

// ---------------------------------------------------------------------------
// Lifecycle.
// ---------------------------------------------------------------------------
/// Spawn the IPC server thread. Any failure leaves the tray fully functional
/// with no status feed (update.spawnCheck idiom).
pub fn start(gpa: std.mem.Allocator, opts: StartOptions) void {
    if (server_thread != null) return;
    srv_gpa = gpa;
    // Pre-spawn, still single-threaded: render the initial "missing" snapshot
    // without the mutex so an early client sees valid JSON.
    json_len = render(&json_buf, snap).len;
    if (comptime builtin.os.tag == .windows) {
        server_thread = std.Thread.spawn(.{}, serveWindows, .{gpa}) catch null;
    } else {
        const p = std.fmt.allocPrint(gpa, "{s}/dygmate/status.sock", .{opts.runtime_dir}) catch return;
        sock_path = p;
        server_thread = std.Thread.spawn(.{}, serveLinux, .{gpa}) catch {
            gpa.free(p);
            sock_path = null;
            return;
        };
    }
}

/// Stop and join the server thread. Windows unblocks the blocking
/// ConnectNamedPipe with a throwaway client connection; Linux wakes from its
/// bounded accept-poll within 500ms on its own.
pub fn stop() void {
    const t = server_thread orelse return;
    stop_flag.store(true, .release);
    if (comptime builtin.os.tag == .windows) unblockConnect();
    t.join();
    server_thread = null;
    if (sock_path) |p| {
        srv_gpa.free(p);
        sock_path = null;
    }
}

/// Copy the rendered line for serving; the lock is held only for the memcpy.
fn copyJson(io: std.Io, buf: *[json_cap]u8) usize {
    mu.lockUncancelable(io);
    defer mu.unlock(io);
    @memcpy(buf[0..json_len], json_buf[0..json_len]);
    return json_len;
}

fn sleepMs(io: std.Io, ms: u64) void {
    const dur: std.Io.Clock.Duration = .{
        .clock = .awake,
        .raw = std.Io.Duration.fromMilliseconds(@intCast(ms)),
    };
    dur.sleep(io) catch {};
}

// ---------------------------------------------------------------------------
// Windows server: named pipe \\.\pipe\dygmate.
// ---------------------------------------------------------------------------
const win = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const DWORD = windows.DWORD;
    const HANDLE = windows.HANDLE;
    const BOOL = windows.BOOL;

    const pipe_name = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\dygmate");

    const PIPE_ACCESS_OUTBOUND: DWORD = 0x00000002;
    // dwPipeMode: byte type/read mode and blocking waits are all 0.
    const PIPE_REJECT_REMOTE_CLIENTS: DWORD = 0x00000008;
    const PIPE_UNLIMITED_INSTANCES: DWORD = 255;
    const ERROR_PIPE_CONNECTED: DWORD = 535;
    const GENERIC_READ: DWORD = 0x80000000;
    const OPEN_EXISTING: DWORD = 3;

    extern "kernel32" fn CreateNamedPipeW(
        lpName: [*:0]const u16,
        dwOpenMode: DWORD,
        dwPipeMode: DWORD,
        nMaxInstances: DWORD,
        nOutBufferSize: DWORD,
        nInBufferSize: DWORD,
        nDefaultTimeOut: DWORD,
        lpSecurityAttributes: ?*anyopaque,
    ) callconv(.winapi) HANDLE;
    extern "kernel32" fn ConnectNamedPipe(hNamedPipe: HANDLE, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn FlushFileBuffers(hFile: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn CreateFileW(lpFileName: [*:0]const u16, dwDesiredAccess: DWORD, dwShareMode: DWORD, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: DWORD, dwFlagsAndAttributes: DWORD, hTemplateFile: ?HANDLE) callconv(.winapi) HANDLE;
    extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
    extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
} else struct {};

fn serveWindows(gpa: std.mem.Allocator) void {
    // Own io (update.zig idiom): only used for the error backoff sleep and
    // the snapshot mutex, never shared with the tray's main loop.
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Keep-a-listener pattern: the moment a client connects, arm a fresh
    // listening instance BEFORE serving the connected one. Shell clients
    // (`cmd /c type`) probe the path with a metadata open first — that probe
    // connects to and burns one instance without reading — and their real
    // open follows microseconds later; it must find a listener or the read
    // fails with "all pipe instances are busy". The default DACL (same
    // user/admins/SYSTEM) is fine for read-only battery data.
    var listener: ?win.HANDLE = null;
    defer if (listener) |h| std.os.windows.CloseHandle(h);
    while (!stop_flag.load(.acquire)) {
        const h = listener orelse blk: {
            const nh = win.CreateNamedPipeW(win.pipe_name, win.PIPE_ACCESS_OUTBOUND, win.PIPE_REJECT_REMOTE_CLIENTS, win.PIPE_UNLIMITED_INSTANCES, json_cap, 0, 0, null);
            if (nh == std.os.windows.INVALID_HANDLE_VALUE) {
                sleepMs(io, 1000);
                continue;
            }
            listener = nh;
            break :blk nh;
        };
        // A client that connected before this call reports
        // ERROR_PIPE_CONNECTED — that is success, not failure.
        const ok = win.ConnectNamedPipe(h, null).toBool() or win.GetLastError() == win.ERROR_PIPE_CONNECTED;
        // The defer above closes the connected instance on shutdown, which
        // also unblocks the throwaway client's read.
        if (stop_flag.load(.acquire)) break;
        // Re-arm before serving; a failed create self-heals next iteration.
        const nh = win.CreateNamedPipeW(win.pipe_name, win.PIPE_ACCESS_OUTBOUND, win.PIPE_REJECT_REMOTE_CLIENTS, win.PIPE_UNLIMITED_INSTANCES, json_cap, 0, 0, null);
        listener = if (nh == std.os.windows.INVALID_HANDLE_VALUE) null else nh;
        if (ok) {
            var buf: [json_cap]u8 = undefined;
            const n = copyJson(io, &buf);
            var written: win.DWORD = 0;
            // A burnt probe connection fails the write (ERROR_NO_DATA) —
            // harmless, the real read is already waiting on the new listener.
            _ = win.WriteFile(h, &buf, @intCast(n), &written, null);
            // Block until the client drained the line — DisconnectNamedPipe
            // discards unread data otherwise.
            _ = win.FlushFileBuffers(h);
            _ = win.DisconnectNamedPipe(h);
        }
        std.os.windows.CloseHandle(h);
    }
}

/// Unblock the server's ConnectNamedPipe by connecting as a throwaway client
/// and draining the served line. The bounded retry covers the window where
/// the server sits between CloseHandle and the next CreateNamedPipeW; if the
/// server is in its error backoff instead, it re-checks stop_flag within a
/// second on its own and join() returns then.
fn unblockConnect() void {
    var attempts: usize = 0;
    while (attempts < 20) : (attempts += 1) {
        const h = win.CreateFileW(win.pipe_name, win.GENERIC_READ, 0, null, win.OPEN_EXISTING, 0, null);
        if (h != std.os.windows.INVALID_HANDLE_VALUE) {
            var buf: [json_cap]u8 = undefined;
            var n: win.DWORD = 0;
            while (win.ReadFile(h, &buf, buf.len, &n, null).toBool() and n != 0) {}
            std.os.windows.CloseHandle(h);
            return;
        }
        win.Sleep(25);
    }
}

// ---------------------------------------------------------------------------
// Linux server: unix socket {runtime_dir}/dygmate/status.sock.
// ---------------------------------------------------------------------------
fn serveLinux(gpa: std.mem.Allocator) void {
    // Own io (update.zig idiom) so socket I/O never shares the tray's
    // main-loop io (which runs D-Bus).
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = sock_path orelse return;
    if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    // A stale socket from an unclean exit blocks bind; unlinking is safe
    // under the tray's singleton flock.
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const ua = std.Io.net.UnixAddress.init(path) catch return;
    var server = ua.listen(io, .{}) catch return;
    defer {
        server.deinit(io);
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    while (!stop_flag.load(.acquire)) {
        // Bounded poll keeps shutdown latency <= 500ms with no unblock trick.
        var fds = [_]std.posix.pollfd{
            .{ .fd = server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const n = std.posix.poll(&fds, 500) catch break;
        if (n == 0) continue;
        const stream = server.accept(io) catch continue;
        var buf: [json_cap]u8 = undefined;
        const len = copyJson(io, &buf);
        writeAll(io, stream, buf[0..len]) catch {};
        stream.close(io);
    }
}

/// dbus.zig's writeAll idiom.
fn writeAll(io: std.Io, stream: std.Io.net.Stream, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const empty: []const u8 = &.{};
        const n = try io.vtable.netWrite(io.userdata, stream.socket.handle, bytes[off..], (&empty)[0..1], 0);
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
}

// ---------------------------------------------------------------------------
// Rendering (pure).
// ---------------------------------------------------------------------------
const Side = struct {
    level: ?u8,
    status: []const u8,
    text: []const u8,
};

/// Field order is the wire order. `text` fields are preformatted so a JSON
/// consumer never renders a raw null; `level`/`low` stay typed for logic.
const Payload = struct {
    state: []const u8,
    connected: bool,
    model: ?[]const u8,
    sides: u8,
    left: Side,
    right: Side,
    level: ?u8,
    text: []const u8,
    low: bool,
    updated: i64,
};

/// Render one snapshot as a single JSON line (trailing '\n', UTF-8, no BOM)
/// into `out` and return the written slice. Overflow is unreachable with
/// json_cap sizing but degrades to an empty slice rather than partial JSON.
fn render(out: []u8, s: Snapshot) []const u8 {
    var lbuf: [24]u8 = undefined;
    var rbuf: [24]u8 = undefined;
    var tbuf: [8]u8 = undefined;

    const sides: u8 = if (s.model) |m| m.sides() else 2;
    const left = displaySide(&lbuf, s.left, s.hide[0]);
    const right = displaySide(&rbuf, s.right, s.hide[1]);

    // Min over visible, battery-reporting sides — the tray icon's number.
    // A hidden side already reads null out of displaySide.
    var level: ?u8 = left.level;
    if (sides > 1) {
        if (right.level) |rl| {
            if (level == null or rl < level.?) level = rl;
        }
    }
    const text: []const u8 = if (level) |l|
        std.fmt.bufPrint(&tbuf, "{d}%", .{l}) catch "--"
    else
        "--";

    const payload: Payload = .{
        .state = @tagName(s.state),
        .connected = s.state == .connected,
        .model = if (s.model) |m| m.displayName() else null,
        .sides = sides,
        .left = left,
        .right = right,
        .level = level,
        .text = text,
        .low = isLow(s, sides),
        .updated = s.updated,
    };
    var w = std.Io.Writer.fixed(out);
    std.json.Stringify.value(payload, .{}, &w) catch return out[0..0];
    w.writeByte('\n') catch return out[0..0];
    return w.buffered();
}

/// Per-side JSON view: "{d}% (status)" like tray_common.fmtSide (duplicated
/// here — importing tray_common would be an import cycle); a hidden
/// (unverified) side renders as if it had no level, mirroring the tray's
/// "?" display.
fn displaySide(buf: []u8, s: battery.SideReading, hidden: bool) Side {
    const word = s.status.label();
    if (!hidden) {
        if (s.level) |lvl| {
            return .{
                .level = lvl,
                .status = word,
                .text = std.fmt.bufPrint(buf, "{d}% ({s})", .{ lvl, word }) catch "?",
            };
        }
    }
    return .{
        .level = null,
        .status = word,
        .text = std.fmt.bufPrint(buf, "?% ({s})", .{word}) catch "?",
    };
}

/// Any visible, battery-reporting, non-charging side below the threshold —
/// mirrors tray_common.hasLowBattery plus the hidden/sides gating.
fn isLow(s: Snapshot, sides: u8) bool {
    const list = [_]struct { r: battery.SideReading, off: bool }{
        .{ .r = s.left, .off = s.hide[0] },
        .{ .r = s.right, .off = s.hide[1] or sides < 2 },
    };
    for (list) |e| {
        if (e.off) continue;
        if (e.r.status == .charging) continue;
        const lvl = e.r.level orelse continue;
        if (lvl < low_threshold) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
fn side(level: ?u8, status: battery.Status) battery.SideReading {
    return .{ .level = level, .status = status };
}

test "render: connected two-sided snapshot" {
    var buf: [json_cap]u8 = undefined;
    const out = render(&buf, .{
        .state = .connected,
        .model = .defy_wireless,
        .left = side(80, .discharging),
        .right = side(75, .charging),
        .updated = 1752669000,
    });
    try std.testing.expectEqualStrings(
        "{\"state\":\"connected\",\"connected\":true,\"model\":\"Dygma Defy\",\"sides\":2," ++
            "\"left\":{\"level\":80,\"status\":\"discharging\",\"text\":\"80% (discharging)\"}," ++
            "\"right\":{\"level\":75,\"status\":\"charging\",\"text\":\"75% (charging)\"}," ++
            "\"level\":75,\"text\":\"75%\",\"low\":false,\"updated\":1752669000}\n",
        out,
    );
}

test "render: never-reported sides render null levels and '--'" {
    var buf: [json_cap]u8 = undefined;
    const out = render(&buf, .{});
    try std.testing.expectEqualStrings(
        "{\"state\":\"missing\",\"connected\":false,\"model\":null,\"sides\":2," ++
            "\"left\":{\"level\":null,\"status\":\"?\",\"text\":\"?% (?)\"}," ++
            "\"right\":{\"level\":null,\"status\":\"?\",\"text\":\"?% (?)\"}," ++
            "\"level\":null,\"text\":\"--\",\"low\":false,\"updated\":0}\n",
        out,
    );
}

test "render: sonsei reports one side and takes its level" {
    var buf: [json_cap]u8 = undefined;
    const out = render(&buf, .{
        .state = .connected,
        .model = .sonsei,
        .left = side(64, .discharging),
    });
    try std.testing.expect(std.mem.indexOf(u8, out, "\"sides\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"level\":64") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"text\":\"64%\"") != null);
}

test "render: min of sides picks the lower level" {
    var buf: [json_cap]u8 = undefined;
    const out = render(&buf, .{
        .state = .connected,
        .model = .raise2,
        .left = side(30, .discharging),
        .right = side(90, .discharging),
    });
    try std.testing.expect(std.mem.indexOf(u8, out, "\"level\":30") != null);
}

test "render: hidden (unverified) side is excluded from the min and reads null" {
    var buf: [json_cap]u8 = undefined;
    const out = render(&buf, .{
        .state = .connected,
        .model = .defy_wireless,
        .left = side(90, .discharging),
        .right = side(15, .discharging),
        .hide = .{ false, true },
    });
    // The hidden low right side neither drives the min nor the low flag.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"level\":90") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"low\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"right\":{\"level\":null,\"status\":\"discharging\",\"text\":\"?% (discharging)\"}") != null);
}

test "render: low fires for a visible non-charging side under the threshold" {
    var buf: [json_cap]u8 = undefined;
    const discharging_low = render(&buf, .{
        .state = .connected,
        .model = .defy_wireless,
        .left = side(15, .discharging),
        .right = side(90, .discharging),
    });
    try std.testing.expect(std.mem.indexOf(u8, discharging_low, "\"low\":true") != null);

    const charging_low = render(&buf, .{
        .state = .connected,
        .model = .defy_wireless,
        .left = side(15, .charging),
        .right = side(90, .discharging),
    });
    try std.testing.expect(std.mem.indexOf(u8, charging_low, "\"low\":false") != null);
}

test "render: disconnect keeps last-known levels with connected:false" {
    var buf: [json_cap]u8 = undefined;
    var s: Snapshot = .{
        .state = .connected,
        .model = .defy_wireless,
        .left = side(80, .discharging),
        .right = side(75, .discharging),
    };
    s.state = .missing;
    const out = render(&buf, s);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"state\":\"missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"connected\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"level\":75") != null);
}

test "mergeSide keeps the last real value per field" {
    var dst = side(80, .discharging);
    // A sleeping half answers one field and leaves the other empty.
    mergeSide(&dst, side(null, .charging));
    try std.testing.expectEqual(@as(?u8, 80), dst.level);
    try std.testing.expectEqual(battery.Status.charging, dst.status);
    mergeSide(&dst, side(76, .unknown));
    try std.testing.expectEqual(@as(?u8, 76), dst.level);
    try std.testing.expectEqual(battery.Status.charging, dst.status);
}
