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
const focus = @import("focus.zig");

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
    /// Fresh (current-poll) status per side, refreshed every publish and
    /// dropped to `.unknown` on an empty read — mirrors LastKnown.left_now/
    /// right_now. Backs the per-side display (status + text) so a stale
    /// "disconnected"/"charging" suffix never clings to a level reading fine
    /// again, while the sticky `left`/`right.status` above still drive the "?"
    /// aggregate and the low gate.
    left_now: battery.Status = .unknown,
    right_now: battery.Status = .unknown,
    /// Per side (0=left, 1=right): the value awaits authoritative
    /// verification and renders hidden, mirroring the tray's "?" display.
    hide: [2]bool = .{ false, false },
    updated: i64 = 0,
};

// ---------------------------------------------------------------------------
// Debug events channel (\\.\pipe\dygmate-events / events.sock).
//
// A separate streaming endpoint for observability: connect and receive one
// NDJSON event per line (Focus wire traffic, Acceptor verdicts, state
// transitions, wakes, force reads). Kept apart from the frozen one-shot
// snapshot endpoint above so status-bar consumers can never be broken by
// debug-stream evolution.
//
// emit() is fire-and-forget: it renders into a fixed drop-oldest ring under a
// dedicated mutex and returns — it never waits on a subscriber, so a slow or
// absent `dygmate tail` can never stall the poll thread. The one events server
// thread delivers the retained ring as backlog on connect, then streams live;
// one subscriber at a time (a second gets refused/queued — fine for a debug
// tool). All emits happen on the poll thread (tray_common hooks + the Focus
// tap, which also runs there), so `emit_io` is that single thread's io.
// ---------------------------------------------------------------------------
const ev_slot_cap = 512;
// ~1 min of backlog even under the 250ms layer poll (~8 events/s); 256KB
// static, delivered to a subscriber on connect.
const ev_ring_len = 512;

const EvSlot = struct {
    seq: u64 = 0,
    len: usize = 0,
    buf: [ev_slot_cap]u8 = undefined,
};

var ev_mu: std.Io.Mutex = .init;
var ev_ring = [_]EvSlot{.{}} ** ev_ring_len;
/// Next sequence number to assign; also the count of events ever emitted.
var ev_head: u64 = 0;
var events_enabled: std.atomic.Value(bool) = .init(false);
var emit_io: std.Io = undefined;
var ev_server_thread: ?std.Thread = null;
var ev_sock_path: ?[]u8 = null; // Linux only

/// One observable event. `@tagName` of the active field is the wire "t" value,
/// so adding a variant is all it takes to add an event type.
pub const Event = union(enum) {
    focus_tx: struct { cmd: []const u8 },
    focus_rx: struct { cmd: []const u8, resp: []const u8, ms: u64 },
    focus_err: struct { cmd: []const u8, err: []const u8, ms: u64 },
    reading: ReadingEvent,
    state: struct { from: ConnState, to: ConnState },
    force_read: struct { phase: []const u8, err: ?[]const u8 = null },
    wake: void,
    note: struct { msg: []const u8 },
};

/// A battery read through the Acceptor: the raw wire reading, the accepted
/// (gated) reading, and the verdict — the whole point of having this channel.
pub const ReadingEvent = struct {
    raw: battery.Reading,
    accepted: battery.Reading,
    suspect: bool,
    needs_verification: [2]bool,
    authoritative: bool,
};

/// Append one event to the ring. Fire-and-forget; safe to call before the
/// channel is enabled (no-op) and from the poll thread only.
pub fn emit(ev: Event) void {
    if (!events_enabled.load(.acquire)) return;
    const io = emit_io;
    const ts = nowMillis(io);
    ev_mu.lockUncancelable(io);
    defer ev_mu.unlock(io);
    const slot = &ev_ring[@intCast(ev_head % ev_ring_len)];
    slot.seq = ev_head;
    slot.len = renderEvent(&slot.buf, ev_head, ts, ev).len;
    ev_head += 1;
}

// Convenience wrappers so tray_common stays declarative and never constructs
// Event literals inline.
pub fn emitReading(r: ReadingEvent) void {
    emit(.{ .reading = r });
}
pub fn emitForceRead(phase: []const u8, err: ?[]const u8) void {
    emit(.{ .force_read = .{ .phase = phase, .err = err } });
}
pub fn emitWake() void {
    emit(.wake);
}

/// Focus wire-tap: installed as `focus.tap` in `start`, invoked on the poll
/// thread inside `focus.request`.
fn focusTap(t: focus.Tap) void {
    switch (t.kind) {
        .tx => emit(.{ .focus_tx = .{ .cmd = t.cmd } }),
        .rx => emit(.{ .focus_rx = .{ .cmd = t.cmd, .resp = t.resp, .ms = t.ms } }),
        .err => emit(.{ .focus_err = .{ .cmd = t.cmd, .err = t.err, .ms = t.ms } }),
    }
}

fn nowMillis(io: std.Io) i64 {
    const ts = std.Io.Clock.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.raw.nanoseconds, std.time.ns_per_ms));
}

// ---------------------------------------------------------------------------
// Publishing (called from the tray poll thread).
// ---------------------------------------------------------------------------
/// Publish an accepted (plausibility-gated) reading. Merges per field like
/// the tray's LastKnown: a half-asleep side keeps its last real value.
/// `left`/`right` carry the sticky last-known level+status (kept for the "?"
/// aggregate and the low gate); `left_now`/`right_now` are the fresh per-poll
/// status (dropped to `.unknown` on an empty read) that back the per-side
/// display, exactly like LastKnown.left_now/right_now.
pub fn publishReading(
    io: std.Io,
    model: ?device.Model,
    left: battery.SideReading,
    right: battery.SideReading,
    left_now: battery.Status,
    right_now: battery.Status,
    hide: [2]bool,
) void {
    mu.lockUncancelable(io);
    const prev = snap.state;
    snap.state = .connected;
    snap.model = model;
    mergeSide(&snap.left, left);
    mergeSide(&snap.right, right);
    snap.left_now = left_now;
    snap.right_now = right_now;
    snap.hide = hide;
    snap.updated = nowSeconds(io);
    json_len = render(&json_buf, snap).len;
    mu.unlock(io);
    if (prev != .connected) emit(.{ .state = .{ .from = prev, .to = .connected } });
}

/// Publish a connection-state change. Levels and model stay as last known so
/// the bar can keep showing them; `connected: false` marks them stale.
pub fn publishConnState(io: std.Io, state: ConnState) void {
    mu.lockUncancelable(io);
    const prev = snap.state;
    snap.state = state;
    snap.updated = nowSeconds(io);
    json_len = render(&json_buf, snap).len;
    mu.unlock(io);
    if (prev != state) emit(.{ .state = .{ .from = prev, .to = state } });
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
/// Spawn the IPC server threads (snapshot + debug events) and install the
/// Focus wire-tap. `io` is the tray's poll-thread io, used for emit
/// timestamps. Must be called before the poll thread is spawned so the tap and
/// `emit_io` are visible to it via the spawn happens-before barrier. Any
/// failure leaves the tray fully functional with no feeds (update.spawnCheck
/// idiom).
pub fn start(io: std.Io, gpa: std.mem.Allocator, opts: StartOptions) void {
    if (server_thread != null) return;
    srv_gpa = gpa;
    emit_io = io;
    // Pre-spawn, still single-threaded: render the initial "missing" snapshot
    // without the mutex so an early client sees valid JSON.
    json_len = render(&json_buf, snap).len;
    if (comptime builtin.os.tag == .windows) {
        server_thread = std.Thread.spawn(.{}, serveWindows, .{gpa}) catch null;
        ev_server_thread = std.Thread.spawn(.{}, serveEventsWindows, .{gpa}) catch null;
    } else {
        if (std.fmt.allocPrint(gpa, "{s}/dygmate/status.sock", .{opts.runtime_dir})) |p| {
            sock_path = p;
            if (std.Thread.spawn(.{}, serveLinux, .{gpa})) |t| {
                server_thread = t;
            } else |_| {
                gpa.free(p);
                sock_path = null;
            }
        } else |_| {}
        if (std.fmt.allocPrint(gpa, "{s}/dygmate/events.sock", .{opts.runtime_dir})) |p| {
            ev_sock_path = p;
            if (std.Thread.spawn(.{}, serveEventsLinux, .{gpa})) |t| {
                ev_server_thread = t;
            } else |_| {
                gpa.free(p);
                ev_sock_path = null;
            }
        } else |_| {}
    }
    // Install the tap and open the gate last, so no event can be emitted
    // before the machinery above is in place.
    focus.tap = &focusTap;
    events_enabled.store(true, .release);
}

/// Stop and join the server threads. Windows unblocks a blocking
/// ConnectNamedPipe with a throwaway client connection; Linux wakes from its
/// bounded accept/serve polls within 500ms on its own.
pub fn stop() void {
    events_enabled.store(false, .release);
    stop_flag.store(true, .release);
    if (comptime builtin.os.tag == .windows) {
        if (server_thread != null) unblockConnect(win.pipe_name);
        if (ev_server_thread != null) unblockConnect(win.events_pipe_name);
    }
    if (server_thread) |t| {
        t.join();
        server_thread = null;
    }
    if (ev_server_thread) |t| {
        t.join();
        ev_server_thread = null;
    }
    if (sock_path) |p| {
        srv_gpa.free(p);
        sock_path = null;
    }
    if (ev_sock_path) |p| {
        srv_gpa.free(p);
        ev_sock_path = null;
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
    const events_pipe_name = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\dygmate-events");

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

/// Unblock a server's ConnectNamedPipe by connecting as a throwaway client and
/// draining whatever it sends. The bounded retry covers the window where the
/// server sits between CloseHandle and the next CreateNamedPipeW; if the server
/// is in its error backoff instead, it re-checks stop_flag within a second on
/// its own and join() returns then. Works for both the one-shot snapshot pipe
/// and the streaming events pipe: once stop_flag is set the served loop returns
/// promptly, and reading here drains any bytes it wrote on the way out.
fn unblockConnect(pipe_name: [*:0]const u16) void {
    var attempts: usize = 0;
    while (attempts < 20) : (attempts += 1) {
        const h = win.CreateFileW(pipe_name, win.GENERIC_READ, 0, null, win.OPEN_EXISTING, 0, null);
        if (h != std.os.windows.INVALID_HANDLE_VALUE) {
            var buf: [ev_slot_cap]u8 = undefined;
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
// Events server: streams the ring to one subscriber at a time.
// ---------------------------------------------------------------------------
const Poll_ms = 100;

/// The subscriber's cursor: which ring events it still owes the client.
const NextEvent = union(enum) {
    none,
    event: usize, // rendered length copied into the caller's buffer
    dropped: u64, // events lost to ring overwrite since the last poll
};

/// Where a freshly connected subscriber starts: the oldest event still in the
/// ring, so it sees recent history as backlog before the live stream.
fn subStart(io: std.Io) u64 {
    ev_mu.lockUncancelable(io);
    defer ev_mu.unlock(io);
    return if (ev_head > ev_ring_len) ev_head - ev_ring_len else 0;
}

/// Advance the cursor by one event, copying its bytes into `out`. Returns
/// `.dropped` when the ring lapped the cursor (slow client), `.none` when
/// caught up.
fn nextEvent(io: std.Io, cur: *u64, out: *[ev_slot_cap]u8) NextEvent {
    ev_mu.lockUncancelable(io);
    defer ev_mu.unlock(io);
    if (cur.* >= ev_head) return .none;
    const oldest = if (ev_head > ev_ring_len) ev_head - ev_ring_len else 0;
    if (cur.* < oldest) {
        const n = oldest - cur.*;
        cur.* = oldest;
        return .{ .dropped = n };
    }
    const slot = &ev_ring[@intCast(cur.* % ev_ring_len)];
    @memcpy(out[0..slot.len], slot.buf[0..slot.len]);
    cur.* += 1;
    return .{ .event = slot.len };
}

fn droppedLine(buf: []u8, n: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"t\":\"dropped\",\"seq\":0,\"ts\":0,\"n\":{d}}}\n", .{n}) catch buf[0..0];
}

fn serveEventsWindows(gpa: std.mem.Allocator) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    while (!stop_flag.load(.acquire)) {
        // Single instance, one subscriber at a time; a second concurrent client
        // gets ERROR_PIPE_BUSY. No keep-a-listener probe race like the snapshot
        // pipe — `dygmate tail` opens once with CreateFile and streams.
        const h = win.CreateNamedPipeW(win.events_pipe_name, win.PIPE_ACCESS_OUTBOUND, win.PIPE_REJECT_REMOTE_CLIENTS, 1, ev_slot_cap, 0, 0, null);
        if (h == std.os.windows.INVALID_HANDLE_VALUE) {
            sleepMs(io, 1000);
            continue;
        }
        const ok = win.ConnectNamedPipe(h, null).toBool() or win.GetLastError() == win.ERROR_PIPE_CONNECTED;
        if (stop_flag.load(.acquire)) {
            std.os.windows.CloseHandle(h);
            break;
        }
        if (ok) streamEventsWindows(io, h);
        _ = win.DisconnectNamedPipe(h);
        std.os.windows.CloseHandle(h);
    }
}

fn streamEventsWindows(io: std.Io, h: win.HANDLE) void {
    var cur = subStart(io);
    while (!stop_flag.load(.acquire)) {
        var line: [ev_slot_cap]u8 = undefined;
        switch (nextEvent(io, &cur, &line)) {
            .none => sleepMs(io, Poll_ms),
            .event => |len| if (!writeAllWin(h, line[0..len])) return,
            .dropped => |n| {
                var buf: [64]u8 = undefined;
                if (!writeAllWin(h, droppedLine(&buf, n))) return;
            },
        }
    }
}

/// Write to the pipe; false on any failure (client gone -> re-accept).
fn writeAllWin(h: win.HANDLE, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        var written: win.DWORD = 0;
        if (!win.WriteFile(h, bytes.ptr + off, @intCast(bytes.len - off), &written, null).toBool()) return false;
        if (written == 0) return false;
        off += written;
    }
    return true;
}

fn serveEventsLinux(gpa: std.mem.Allocator) void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = ev_sock_path orelse return;
    if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const ua = std.Io.net.UnixAddress.init(path) catch return;
    var server = ua.listen(io, .{}) catch return;
    defer {
        server.deinit(io);
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    while (!stop_flag.load(.acquire)) {
        var fds = [_]std.posix.pollfd{
            .{ .fd = server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const n = std.posix.poll(&fds, 500) catch break;
        if (n == 0) continue;
        const stream = server.accept(io) catch continue;
        streamEventsLinux(io, stream);
        stream.close(io);
    }
}

fn streamEventsLinux(io: std.Io, stream: std.Io.net.Stream) void {
    var cur = subStart(io);
    while (!stop_flag.load(.acquire)) {
        var line: [ev_slot_cap]u8 = undefined;
        switch (nextEvent(io, &cur, &line)) {
            .none => sleepMs(io, Poll_ms),
            .event => |len| writeAll(io, stream, line[0..len]) catch return,
            .dropped => |n| {
                var buf: [64]u8 = undefined;
                writeAll(io, stream, droppedLine(&buf, n)) catch return;
            },
        }
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
    // Per-side display uses the FRESH status (sticky level + `*_now`), mirroring
    // LastKnown.leftText/rightText: a stale "disconnected"/"charging" suffix is
    // dropped the moment a poll's status comes back empty. The sticky
    // `s.left/right.status` still drive `all_disconnected` and `isLow` below.
    const left = displaySide(&lbuf, .{ .level = s.left.level, .status = s.left_now }, s.hide[0]);
    const right = displaySide(&rbuf, .{ .level = s.right.level, .status = s.right_now }, s.hide[1]);

    // Both battery-reporting halves explicitly disconnected (firmware code "4")
    // while connected: their last-known levels are stale cache, so the aggregate
    // reads "?" like the tray icon (each side still shows its own last-known
    // value below). Gated on `connected` so paused/available keep showing the
    // last-known number.
    const all_disconnected = s.state == .connected and
        s.left.status == .disconnected and
        (sides < 2 or s.right.status == .disconnected);

    // Min over visible, battery-reporting sides — the tray icon's number.
    // A hidden side already reads null out of displaySide.
    var level: ?u8 = if (all_disconnected) null else left.level;
    if (!all_disconnected and sides > 1) {
        if (right.level) |rl| {
            if (level == null or rl < level.?) level = rl;
        }
    }
    const text: []const u8 = if (all_disconnected)
        "?"
    else if (level) |l|
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
/// "?" display. A known level with an unknown status (the neuron often answers
/// the level and leaves the status empty) drops the suffix — "{d}%".
fn displaySide(buf: []u8, s: battery.SideReading, hidden: bool) Side {
    const word = s.status.label();
    if (!hidden) {
        if (s.level) |lvl| {
            const text = if (s.status == .unknown)
                std.fmt.bufPrint(buf, "{d}%", .{lvl}) catch "?"
            else
                std.fmt.bufPrint(buf, "{d}% ({s})", .{ lvl, word }) catch "?";
            return .{ .level = lvl, .status = word, .text = text };
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
// Event rendering (pure). One NDJSON line per event, envelope first:
//   {"t":<type>,"seq":N,"ts":<unix_ms>, <type-specific fields>}\n
// ---------------------------------------------------------------------------
fn renderEvent(out: []u8, seq: u64, ts: i64, ev: Event) []const u8 {
    var w = std.Io.Writer.fixed(out);
    writeEvent(&w, seq, ts, ev) catch return out[0..0];
    return w.buffered();
}

fn writeEvent(w: *std.Io.Writer, seq: u64, ts: i64, ev: Event) !void {
    try w.print("{{\"t\":\"{s}\",\"seq\":{d},\"ts\":{d}", .{ @tagName(ev), seq, ts });
    switch (ev) {
        .focus_tx => |e| {
            try w.writeAll(",\"cmd\":");
            try jsonStr(w, e.cmd);
        },
        .focus_rx => |e| {
            try w.writeAll(",\"cmd\":");
            try jsonStr(w, e.cmd);
            try w.writeAll(",\"resp\":");
            try jsonStr(w, e.resp);
            try w.print(",\"ms\":{d}", .{e.ms});
        },
        .focus_err => |e| {
            try w.writeAll(",\"cmd\":");
            try jsonStr(w, e.cmd);
            try w.writeAll(",\"err\":");
            try jsonStr(w, e.err);
            try w.print(",\"ms\":{d}", .{e.ms});
        },
        .reading => |e| {
            try w.writeAll(",\"raw\":");
            try writeReadingJson(w, e.raw);
            try w.writeAll(",\"accepted\":");
            try writeReadingJson(w, e.accepted);
            try w.print(
                ",\"suspect\":{s},\"authoritative\":{s},\"needs_verification\":[{s},{s}]",
                .{ boolStr(e.suspect), boolStr(e.authoritative), boolStr(e.needs_verification[0]), boolStr(e.needs_verification[1]) },
            );
        },
        .state => |e| {
            try w.print(",\"from\":\"{s}\",\"to\":\"{s}\"", .{ @tagName(e.from), @tagName(e.to) });
        },
        .force_read => |e| {
            try w.writeAll(",\"phase\":");
            try jsonStr(w, e.phase);
            if (e.err) |er| {
                try w.writeAll(",\"err\":");
                try jsonStr(w, er);
            }
        },
        .wake => {},
        .note => |e| {
            try w.writeAll(",\"msg\":");
            try jsonStr(w, e.msg);
        },
    }
    try w.writeAll("}\n");
}

/// Emit a properly quoted+escaped JSON string (neuron responses are arbitrary
/// bytes, so this must not be skipped for `resp`).
fn jsonStr(w: *std.Io.Writer, s: []const u8) !void {
    try std.json.Stringify.value(s, .{}, w);
}

fn writeReadingJson(w: *std.Io.Writer, r: battery.Reading) !void {
    try w.writeAll("{\"left\":");
    try writeSideJson(w, r.left);
    try w.writeAll(",\"right\":");
    try writeSideJson(w, r.right);
    try w.writeByte('}');
}

fn writeSideJson(w: *std.Io.Writer, s: battery.SideReading) !void {
    try w.writeAll("{\"level\":");
    if (s.level) |l| try w.print("{d}", .{l}) else try w.writeAll("null");
    // status.label() is a fixed safelist word — no escaping needed.
    try w.print(",\"status\":\"{s}\"}}", .{s.status.label()});
}

fn boolStr(b: bool) []const u8 {
    return if (b) "true" else "false";
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
        .left_now = .discharging,
        .right_now = .charging,
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
        .left_now = .discharging,
        .right_now = .discharging,
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

test "render: both sides disconnected while connected reads '?' aggregate" {
    var buf: [json_cap]u8 = undefined;
    const out = render(&buf, .{
        .state = .connected,
        .model = .defy_wireless,
        // Last-known levels survive per side; the aggregate goes to "?".
        .left = side(80, .disconnected),
        .right = side(75, .disconnected),
        // Both explicitly disconnected on THIS poll — the fresh status carries
        // the "4" too, so each side keeps its "(disconnected)" suffix.
        .left_now = .disconnected,
        .right_now = .disconnected,
    });
    try std.testing.expect(std.mem.indexOf(u8, out, "\"level\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"text\":\"?\"") != null);
    // Each side still carries its own last-known value.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"left\":{\"level\":80,\"status\":\"disconnected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"right\":{\"level\":75,\"status\":\"disconnected\"") != null);
}

test "render: a level with an empty status drops the '(?)' suffix" {
    var buf: [json_cap]u8 = undefined;
    const out = render(&buf, .{
        .state = .connected,
        .model = .defy_wireless,
        .left = side(40, .unknown), // level known, status empty
        .right = side(50, .discharging),
    });
    try std.testing.expect(std.mem.indexOf(u8, out, "\"left\":{\"level\":40,\"status\":\"?\",\"text\":\"40%\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"right\":{\"level\":50,\"status\":\"discharging\",\"text\":\"50% (discharging)\"}") != null);
}

test "render: one side disconnected keeps the other's level" {
    var buf: [json_cap]u8 = undefined;
    const out = render(&buf, .{
        .state = .connected,
        .model = .defy_wireless,
        .left = side(80, .disconnected),
        .right = side(75, .discharging),
    });
    try std.testing.expect(std.mem.indexOf(u8, out, "\"level\":75") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"text\":\"75%\"") != null);
}

test "render: a stale disconnect drops the per-side suffix" {
    // The reported bug: the right half went "disconnected" once (sticky status
    // still 4), but the latest poll read its level back with an EMPTY status
    // (right_now = unknown). The tray menu shows "50%", so the feed must too —
    // not "50% (disconnected)". The left half is live, so the aggregate stays a
    // real number rather than "?".
    var buf: [json_cap]u8 = undefined;
    const out = render(&buf, .{
        .state = .connected,
        .model = .defy_wireless,
        .left = side(40, .discharging),
        .right = side(50, .disconnected),
        .left_now = .discharging,
        .right_now = .unknown,
    });
    try std.testing.expect(std.mem.indexOf(u8, out, "\"right\":{\"level\":50,\"status\":\"?\",\"text\":\"50%\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"left\":{\"level\":40,\"status\":\"discharging\",\"text\":\"40% (discharging)\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"level\":40") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"text\":\"40%\"") != null);
}

test "render: both disconnected but not connected keeps last-known number" {
    var buf: [json_cap]u8 = undefined;
    const out = render(&buf, .{
        .state = .available,
        .model = .defy_wireless,
        .left = side(80, .disconnected),
        .right = side(75, .disconnected),
    });
    // Paused/available surfaces keep the last-known number (gray), not "?".
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

test "renderEvent: focus_rx carries cmd, resp, ms" {
    var buf: [ev_slot_cap]u8 = undefined;
    const out = renderEvent(&buf, 7, 1752669000123, .{
        .focus_rx = .{ .cmd = "wireless.battery.left.level", .resp = "87", .ms = 4 },
    });
    try std.testing.expectEqualStrings(
        "{\"t\":\"focus_rx\",\"seq\":7,\"ts\":1752669000123," ++
            "\"cmd\":\"wireless.battery.left.level\",\"resp\":\"87\",\"ms\":4}\n",
        out,
    );
}

test "renderEvent: reading nests raw/accepted with null levels and the verdict" {
    var buf: [ev_slot_cap]u8 = undefined;
    const out = renderEvent(&buf, 0, 0, .{ .reading = .{
        .raw = .{ .left = side(100, .disconnected), .right = side(null, .unknown) },
        .accepted = .{ .left = side(null, .disconnected), .right = side(null, .unknown) },
        .suspect = false,
        .needs_verification = .{ true, false },
        .authoritative = false,
    } });
    try std.testing.expectEqualStrings(
        "{\"t\":\"reading\",\"seq\":0,\"ts\":0," ++
            "\"raw\":{\"left\":{\"level\":100,\"status\":\"disconnected\"},\"right\":{\"level\":null,\"status\":\"?\"}}," ++
            "\"accepted\":{\"left\":{\"level\":null,\"status\":\"disconnected\"},\"right\":{\"level\":null,\"status\":\"?\"}}," ++
            "\"suspect\":false,\"authoritative\":false,\"needs_verification\":[true,false]}\n",
        out,
    );
}

test "renderEvent: state transition and bare wake" {
    var buf: [ev_slot_cap]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"t\":\"state\",\"seq\":1,\"ts\":2,\"from\":\"connected\",\"to\":\"missing\"}\n",
        renderEvent(&buf, 1, 2, .{ .state = .{ .from = .connected, .to = .missing } }),
    );
    try std.testing.expectEqualStrings(
        "{\"t\":\"wake\",\"seq\":3,\"ts\":4}\n",
        renderEvent(&buf, 3, 4, .wake),
    );
}

test "renderEvent: focus_err escapes arbitrary response bytes" {
    var buf: [ev_slot_cap]u8 = undefined;
    // A quote in the payload must be escaped so the line stays valid JSON.
    const out = renderEvent(&buf, 0, 0, .{
        .focus_rx = .{ .cmd = "layer.state", .resp = "a\"b", .ms = 1 },
    });
    try std.testing.expect(std.mem.indexOf(u8, out, "\"resp\":\"a\\\"b\"") != null);
}

test "droppedLine renders a valid marker" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"t\":\"dropped\",\"seq\":0,\"ts\":0,\"n\":5}\n",
        droppedLine(&buf, 5),
    );
}
