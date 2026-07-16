//! `dygmate tail` — stream the running tray's debug events channel to stdout.
//!
//! Connects to the events endpoint the tray serves (`\\.\pipe\dygmate-events`
//! on Windows, `$XDG_RUNTIME_DIR/dygmate/events.sock` on Linux) and prints one
//! event per line: Focus wire traffic, Acceptor verdicts, state transitions,
//! wakes, and force reads. Pretty-prints by default; `--raw` passes the NDJSON
//! straight through (pipe it to `jq`). A one-shot client, read-only — it never
//! touches the exclusive serial port, so it runs happily alongside the tray.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const EnvMap = std.process.Environ.Map;

pub const Options = struct {
    raw: bool = false,
    /// Show the 250ms `layer.state` poll traffic too (hidden by default so the
    /// battery/state events stand out). Implied irrelevant in `raw` mode.
    all: bool = false,
};

pub fn run(io: Io, gpa: std.mem.Allocator, environ: *EnvMap, opts: Options) u8 {
    var stdout_buf: [1024]u8 = undefined;
    var stdout_file = Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const out = &stdout_writer.interface;

    var lines = LineReader{ .out = out, .gpa = gpa, .raw = opts.raw, .all = opts.all };

    if (comptime builtin.os.tag == .windows) {
        return runWindows(&lines);
    } else {
        return runPosix(io, gpa, environ, &lines);
    }
}

fn notRunning() u8 {
    std.debug.print("dygmate: could not connect to dygmate-tray events feed (is the tray running?)\n", .{});
    return 1;
}

// ---------------------------------------------------------------------------
// Windows: read the named pipe.
// ---------------------------------------------------------------------------
const win = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const DWORD = windows.DWORD;
    const HANDLE = windows.HANDLE;
    const BOOL = windows.BOOL;

    const pipe_name = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\dygmate-events");
    const GENERIC_READ: DWORD = 0x80000000;
    const OPEN_EXISTING: DWORD = 3;

    extern "kernel32" fn CreateFileW(lpFileName: [*:0]const u16, dwDesiredAccess: DWORD, dwShareMode: DWORD, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: DWORD, dwFlagsAndAttributes: DWORD, hTemplateFile: ?HANDLE) callconv(.winapi) HANDLE;
    extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
} else struct {};

fn runWindows(lines: *LineReader) u8 {
    const h = win.CreateFileW(win.pipe_name, win.GENERIC_READ, 0, null, win.OPEN_EXISTING, 0, null);
    if (h == std.os.windows.INVALID_HANDLE_VALUE) return notRunning();
    defer std.os.windows.CloseHandle(h);

    var buf: [4096]u8 = undefined;
    while (true) {
        var n: win.DWORD = 0;
        if (!win.ReadFile(h, &buf, buf.len, &n, null).toBool()) break; // server closed
        if (n == 0) break;
        lines.feed(buf[0..n]);
    }
    lines.flush();
    return 0;
}

// ---------------------------------------------------------------------------
// POSIX: read the unix socket.
// ---------------------------------------------------------------------------
fn runPosix(io: Io, gpa: std.mem.Allocator, environ: *EnvMap, lines: *LineReader) u8 {
    const runtime = environ.get("XDG_RUNTIME_DIR") orelse "/tmp";
    const path = std.fmt.allocPrint(gpa, "{s}/dygmate/events.sock", .{runtime}) catch return 1;
    defer gpa.free(path);

    const ua = Io.net.UnixAddress.init(path) catch return notRunning();
    const stream = ua.connect(io) catch return notRunning();
    defer stream.close(io);

    var buf: [4096]u8 = undefined;
    while (true) {
        var vec = [_][]u8{&buf};
        const n = io.vtable.netRead(io.userdata, stream.socket.handle, &vec) catch break;
        if (n == 0) break; // server closed
        lines.feed(buf[0..n]);
    }
    lines.flush();
    return 0;
}

// ---------------------------------------------------------------------------
// Line reassembly + formatting.
// ---------------------------------------------------------------------------
const LineReader = struct {
    out: *Io.Writer,
    gpa: std.mem.Allocator,
    raw: bool,
    all: bool,
    buf: [1024]u8 = undefined,
    len: usize = 0,

    /// Split `chunk` on newlines, emitting each complete line; the trailing
    /// partial is retained across calls. An over-long line (shouldn't happen —
    /// events are bounded) is dropped rather than split mid-JSON.
    fn feed(self: *LineReader, chunk: []const u8) void {
        var rest = chunk;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            const line = rest[0..nl];
            rest = rest[nl + 1 ..];
            if (self.len == 0) {
                self.emit(line);
            } else if (self.len + line.len <= self.buf.len) {
                @memcpy(self.buf[self.len..][0..line.len], line);
                self.emit(self.buf[0 .. self.len + line.len]);
                self.len = 0;
            } else {
                self.len = 0; // overflow: discard the runt
            }
        }
        if (rest.len != 0 and self.len + rest.len <= self.buf.len) {
            @memcpy(self.buf[self.len..][0..rest.len], rest);
            self.len += rest.len;
        }
    }

    fn emit(self: *LineReader, line: []const u8) void {
        if (line.len == 0) return;
        if (self.raw) {
            self.out.writeAll(line) catch {};
            self.out.writeByte('\n') catch {};
        } else {
            prettyLine(self.out, self.gpa, line, self.all);
        }
        self.out.flush() catch {};
    }

    fn flush(self: *LineReader) void {
        self.out.flush() catch {};
    }
};

fn prettyLine(out: *Io.Writer, gpa: std.mem.Allocator, line: []const u8, all: bool) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), line, .{}) catch {
        rawFallback(out, line);
        return;
    };
    const t = strOf(get(parsed, "t")) orelse {
        rawFallback(out, line);
        return;
    };

    // The 250ms layer poll dominates the stream; hide it unless --all so the
    // battery/state/reading events are easy to follow.
    if (!all and isFocus(t)) {
        if (strOf(get(parsed, "cmd"))) |cmd| {
            if (std.mem.eql(u8, cmd, "layer.state")) return;
        }
    }

    writeClock(out, intOf(get(parsed, "ts")) orelse 0);
    out.print(" {s: <10} ", .{t}) catch {};

    if (std.mem.eql(u8, t, "focus_tx")) {
        out.print("-> {s}", .{strOf(get(parsed, "cmd")) orelse "?"}) catch {};
    } else if (std.mem.eql(u8, t, "focus_rx")) {
        out.print("<- {s} = \"{s}\" ({d}ms)", .{
            strOf(get(parsed, "cmd")) orelse "?",
            strOf(get(parsed, "resp")) orelse "",
            intOf(get(parsed, "ms")) orelse 0,
        }) catch {};
    } else if (std.mem.eql(u8, t, "focus_err")) {
        out.print("!! {s}: {s} ({d}ms)", .{
            strOf(get(parsed, "cmd")) orelse "?",
            strOf(get(parsed, "err")) orelse "?",
            intOf(get(parsed, "ms")) orelse 0,
        }) catch {};
    } else if (std.mem.eql(u8, t, "reading")) {
        writeReading(out, parsed);
    } else if (std.mem.eql(u8, t, "state")) {
        out.print("{s} -> {s}", .{
            strOf(get(parsed, "from")) orelse "?",
            strOf(get(parsed, "to")) orelse "?",
        }) catch {};
    } else if (std.mem.eql(u8, t, "force_read")) {
        out.print("forceRead {s}", .{strOf(get(parsed, "phase")) orelse "?"}) catch {};
        if (strOf(get(parsed, "err"))) |e| out.print(" ({s})", .{e}) catch {};
    } else if (std.mem.eql(u8, t, "wake")) {
        out.writeAll("machine woke — sides re-guarded") catch {};
    } else if (std.mem.eql(u8, t, "dropped")) {
        out.print("... {d} events dropped (client fell behind)", .{intOf(get(parsed, "n")) orelse 0}) catch {};
    } else if (std.mem.eql(u8, t, "note")) {
        out.print("{s}", .{strOf(get(parsed, "msg")) orelse ""}) catch {};
    }
    out.writeByte('\n') catch {};
}

fn writeReading(out: *Io.Writer, v: std.json.Value) void {
    const raw = get(v, "raw");
    const acc = get(v, "accepted");
    out.writeAll("raw L") catch {};
    writeLevel(out, getPath(raw, "left", "level"));
    out.writeAll("/R") catch {};
    writeLevel(out, getPath(raw, "right", "level"));
    out.writeAll("  ->  acc L") catch {};
    writeLevel(out, getPath(acc, "left", "level"));
    out.writeAll("/R") catch {};
    writeLevel(out, getPath(acc, "right", "level"));
    if (boolOf(get(v, "authoritative"))) out.writeAll("  [authoritative]") catch {};
    if (boolOf(get(v, "suspect"))) out.writeAll("  [suspect]") catch {};
    if (needsVerify(get(v, "needs_verification"))) out.writeAll("  [verifying]") catch {};
}

fn writeLevel(out: *Io.Writer, v: ?std.json.Value) void {
    const vv = v orelse {
        out.writeAll("?") catch {};
        return;
    };
    switch (vv) {
        .integer => |i| out.print("{d}", .{i}) catch {},
        else => out.writeAll("?") catch {},
    }
}

fn needsVerify(v: ?std.json.Value) bool {
    const arr = switch (v orelse return false) {
        .array => |a| a,
        else => return false,
    };
    for (arr.items) |item| {
        if (boolOf(item)) return true;
    }
    return false;
}

/// UTC wall clock from epoch milliseconds: `HH:MM:SS.mmm`. Components are cast
/// to unsigned — signed `{d:0>2}` reserves a slot for a sign and prints `+20`.
fn writeClock(out: *Io.Writer, ts_ms: i64) void {
    const day_ms: u64 = @intCast(@mod(ts_ms, std.time.ms_per_day));
    const ms = day_ms % 1000;
    const total_s = day_ms / 1000;
    const s = total_s % 60;
    const m = (total_s / 60) % 60;
    const h = total_s / 3600;
    out.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ h, m, s, ms }) catch {};
}

fn isFocus(t: []const u8) bool {
    return std.mem.eql(u8, t, "focus_tx") or std.mem.eql(u8, t, "focus_rx") or std.mem.eql(u8, t, "focus_err");
}

fn rawFallback(out: *Io.Writer, line: []const u8) void {
    out.writeAll(line) catch {};
    out.writeByte('\n') catch {};
}

// -- std.json.Value accessors ------------------------------------------------
fn get(v: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn getPath(v: ?std.json.Value, a: []const u8, b: []const u8) ?std.json.Value {
    const first = get(v orelse return null, a) orelse return null;
    return get(first, b);
}

fn strOf(v: ?std.json.Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn intOf(v: ?std.json.Value) ?i64 {
    return switch (v orelse return null) {
        .integer => |i| i,
        else => null,
    };
}

fn boolOf(v: ?std.json.Value) bool {
    return switch (v orelse return false) {
        .bool => |b| b,
        else => false,
    };
}
