//! Focus protocol transport for Dygma keyboards.
//!
//! The Focus API is line-oriented ASCII over a CDC-ACM serial port at
//! 115200 baud 8N1. A request is `<command>\n`; the response is one or
//! more `\r\n`-delimited lines terminated by a line that is exactly `.`.

const std = @import("std");
const builtin = @import("builtin");
const serial = @import("serial");
const windows = std.os.windows;
const Io = std.Io;

pub const Error = error{ Timeout, ResponseTooLong, PortError, InvalidCommand };

/// When true, every exchange is dumped to stderr (--debug).
pub var debug = false;

/// Per-read driver timeout: silence for this long means the device is gone.
const read_timeout_ms = 2000;
/// Overall deadline per request, guards against trickle input.
const overall_deadline_ns = 5 * std.time.ns_per_s;

pub const Focus = struct {
    io: Io,
    port: Io.File,
    scanner: LineScanner = .{},

    pub fn open(io: Io, path: []const u8) !Focus {
        const port = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        errdefer port.close(io);
        try serial.configureSerialPort(port, .{
            .baud_rate = 115200,
            .parity = .none,
            .stop_bits = .one,
            .word_size = .eight,
            .handshake = .none,
        });
        try setReadTimeout(port, read_timeout_ms);
        serial.flushSerialPort(port, .both) catch {};
        return .{ .io = io, .port = port };
    }

    pub fn close(self: *Focus) void {
        self.port.close(self.io);
    }

    /// Send a bare Focus command and return its payload (lines joined by
    /// '\n', written into `out`). Only argument-less commands are allowed:
    /// `<command> <data>` is a setter that writes the keyboard's flash and
    /// wears out the chip — this client is read-only by design.
    pub fn request(self: *Focus, cmd: []const u8, out: []u8) Error![]const u8 {
        if (!isReadOnlyCommand(cmd)) return error.InvalidCommand;
        self.scanner.reset();
        self.writeAllPort(cmd) catch return error.PortError;
        self.writeAllPort("\n") catch return error.PortError;

        var out_len: usize = 0;
        const start = Io.Clock.Timestamp.now(self.io, .awake);

        while (true) {
            while (self.scanner.nextLine()) |line| {
                if (std.mem.eql(u8, line, ".")) {
                    if (debug) std.debug.print("focus: '{s}' -> '{s}' (hex: {x})\n", .{ cmd, out[0..out_len], out[0..out_len] });
                    return out[0..out_len];
                }
                if (out_len + line.len + 1 > out.len) return error.ResponseTooLong;
                if (out_len != 0) {
                    out[out_len] = '\n';
                    out_len += 1;
                }
                @memcpy(out[out_len..][0..line.len], line);
                out_len += line.len;
            }
            self.scanner.compact();
            if (self.scanner.freeSpace().len == 0) return error.ResponseTooLong;
            const elapsed = start.durationTo(Io.Clock.Timestamp.now(self.io, .awake));
            if (elapsed.raw.nanoseconds > overall_deadline_ns) return error.Timeout;
            const n = self.readPort(self.scanner.freeSpace()) catch return error.PortError;
            if (n == 0) return error.Timeout; // COM ports have no EOF: 0 == COMMTIMEOUTS expiry
            self.scanner.commit(n);
        }
    }

    /// Raw write to the port. On Windows this is a direct WriteFile on the
    /// handle; the buffered std.Io writer assumes seekable files and
    /// misbehaves on character devices.
    fn writeAllPort(self: *Focus, bytes: []const u8) !void {
        if (comptime builtin.os.tag == .windows) {
            var idx: usize = 0;
            while (idx < bytes.len) {
                var written: windows.DWORD = 0;
                if (WriteFile(self.port.handle, bytes.ptr + idx, @intCast(bytes.len - idx), &written, null) == .FALSE)
                    return error.PortError;
                idx += written;
            }
        } else {
            self.port.writeStreamingAll(self.io, bytes) catch return error.PortError;
        }
    }

    /// Raw read from the port; returns 0 on read-timeout expiry (a COM port
    /// has no EOF). Direct ReadFile on Windows for the same reason as above.
    fn readPort(self: *Focus, buf: []u8) !usize {
        if (comptime builtin.os.tag == .windows) {
            var read_n: windows.DWORD = 0;
            if (ReadFile(self.port.handle, buf.ptr, @intCast(buf.len), &read_n, null) == .FALSE)
                return error.PortError;
            return read_n;
        } else {
            return self.port.readStreaming(self.io, &.{buf}) catch |e| switch (e) {
                error.EndOfStream => 0,
                else => error.PortError,
            };
        }
    }
};

pub fn isReadOnlyCommand(cmd: []const u8) bool {
    return std.mem.eql(u8, cmd, "wireless.battery.left.level") or
        std.mem.eql(u8, cmd, "wireless.battery.left.status") or
        std.mem.eql(u8, cmd, "wireless.battery.right.level") or
        std.mem.eql(u8, cmd, "wireless.battery.right.status") or
        std.mem.eql(u8, cmd, "wireless.battery.forceRead");
}

/// Incremental splitter for the response byte stream. Read into
/// `freeSpace()`, `commit()` the byte count, then drain `nextLine()`;
/// `compact()` reclaims consumed space between reads.
pub const LineScanner = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,
    scan: usize = 0,

    /// Next complete line, without its '\n' and with any trailing '\r'
    /// trimmed (tolerates both "\r\n" and bare "\n"). Null = need more data.
    pub fn nextLine(self: *LineScanner) ?[]const u8 {
        const nl = std.mem.indexOfScalarPos(u8, self.buf[0..self.len], self.scan, '\n') orelse return null;
        const line = std.mem.trimEnd(u8, self.buf[self.scan..nl], "\r");
        self.scan = nl + 1;
        return line;
    }

    pub fn compact(self: *LineScanner) void {
        if (self.scan == 0) return;
        std.mem.copyForwards(u8, self.buf[0 .. self.len - self.scan], self.buf[self.scan..self.len]);
        self.len -= self.scan;
        self.scan = 0;
    }

    pub fn freeSpace(self: *LineScanner) []u8 {
        return self.buf[self.len..];
    }

    pub fn commit(self: *LineScanner, n: usize) void {
        self.len += n;
    }

    pub fn reset(self: *LineScanner) void {
        self.len = 0;
        self.scan = 0;
    }
};

const COMMTIMEOUTS = extern struct {
    ReadIntervalTimeout: windows.DWORD,
    ReadTotalTimeoutMultiplier: windows.DWORD,
    ReadTotalTimeoutConstant: windows.DWORD,
    WriteTotalTimeoutMultiplier: windows.DWORD,
    WriteTotalTimeoutConstant: windows.DWORD,
};

extern "kernel32" fn SetCommTimeouts(
    hFile: windows.HANDLE,
    lpCommTimeouts: *const COMMTIMEOUTS,
) callconv(.winapi) windows.BOOL;

// Raw byte I/O on the port handle. std.Io moved file reads/writes behind an
// interface that assumes seekable files; talking to ReadFile/WriteFile
// directly keeps the char-device semantics (0-byte read == timeout expiry).
extern "kernel32" fn ReadFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: windows.DWORD,
    lpNumberOfBytesRead: *windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn WriteFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: windows.DWORD,
    lpNumberOfBytesWritten: *windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

/// The serial lib leaves COMMTIMEOUTS at whatever the driver last had,
/// which can mean "block forever" or "return instantly". MAXDWORD /
/// MAXDWORD / constant is the documented mode for: return queued bytes
/// immediately, else return on first byte, else 0 bytes after `ms`.
fn setReadTimeout(port: Io.File, ms: u32) !void {
    if (comptime builtin.os.tag == .windows) {
        const timeouts: COMMTIMEOUTS = .{
            .ReadIntervalTimeout = std.math.maxInt(windows.DWORD),
            .ReadTotalTimeoutMultiplier = std.math.maxInt(windows.DWORD),
            .ReadTotalTimeoutConstant = ms,
            .WriteTotalTimeoutMultiplier = 0,
            .WriteTotalTimeoutConstant = ms,
        };
        if (SetCommTimeouts(port.handle, &timeouts) == .FALSE) return error.SetTimeoutsFailed;
    }
    // POSIX: blocking reads are acceptable for v1; VTIME support is a follow-up.
}

fn push(s: *LineScanner, bytes: []const u8) void {
    @memcpy(s.freeSpace()[0..bytes.len], bytes);
    s.commit(bytes.len);
}

test "scanner: single-line payload with terminator" {
    var s = LineScanner{};
    push(&s, "87\r\n.\r\n");
    try std.testing.expectEqualStrings("87", s.nextLine().?);
    try std.testing.expectEqualStrings(".", s.nextLine().?);
    try std.testing.expectEqual(null, s.nextLine());
}

test "scanner: data split across reads" {
    var s = LineScanner{};
    push(&s, "8");
    try std.testing.expectEqual(null, s.nextLine());
    push(&s, "7\r");
    try std.testing.expectEqual(null, s.nextLine());
    push(&s, "\n.\r\n");
    try std.testing.expectEqualStrings("87", s.nextLine().?);
    try std.testing.expectEqualStrings(".", s.nextLine().?);
}

test "scanner: bare newlines and empty payload" {
    var s = LineScanner{};
    push(&s, "\n.\n");
    try std.testing.expectEqualStrings("", s.nextLine().?);
    try std.testing.expectEqualStrings(".", s.nextLine().?);
}

test "scanner: compact reclaims consumed space" {
    var s = LineScanner{};
    push(&s, "hello\r\n");
    try std.testing.expectEqualStrings("hello", s.nextLine().?);
    s.compact();
    try std.testing.expectEqual(s.buf.len, s.freeSpace().len);
}

test "isReadOnlyCommand only allows battery read commands" {
    try std.testing.expect(isReadOnlyCommand("wireless.battery.left.level"));
    try std.testing.expect(isReadOnlyCommand("wireless.battery.left.status"));
    try std.testing.expect(isReadOnlyCommand("wireless.battery.right.level"));
    try std.testing.expect(isReadOnlyCommand("wireless.battery.right.status"));
    try std.testing.expect(isReadOnlyCommand("wireless.battery.forceRead"));

    try std.testing.expect(!isReadOnlyCommand("wireless.battery.savingMode"));
    try std.testing.expect(!isReadOnlyCommand("wireless.battery.savingMode 1"));
    try std.testing.expect(!isReadOnlyCommand("wireless.battery.left.level "));
    try std.testing.expect(!isReadOnlyCommand("wireless.battery.left.level\t1"));
    try std.testing.expect(!isReadOnlyCommand("wireless.battery.left.level\nwireless.battery.savingMode 1"));
    try std.testing.expect(!isReadOnlyCommand("keymap.custom"));
}
