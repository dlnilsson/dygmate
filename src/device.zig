//! Dygma device discovery: locate the keyboard's serial port by USB VID/PID.
//!
//! Shared by the CLI (`main.zig`) and the tray app (`tray.zig`) so both agree
//! on how a Defy wireless is found and how a port name is made openable.

const std = @import("std");
const builtin = @import("builtin");
const serial = @import("serial");

pub const dygma_vid = 0x35EF;
pub const defy_wireless_pid = 0x0012;

/// Scan serial ports for the Defy wireless by USB VID/PID. Returns an
/// owned, openable port path, or null if not found (or not supported:
/// the serial lib has no port info enumeration on macOS — use --port there).
pub fn findDygmaPort(io: std.Io, alloc: std.mem.Allocator) !?[]u8 {
    if (comptime builtin.os.tag == .macos) {
        return null;
    } else {
        var it = serial.list_info(io) catch return null;
        defer it.deinit();
        while (true) {
            // Iteration can fail on unrelated devices (e.g. non-USB sysfs
            // entries on Linux); both platform iterators still advance, so
            // skipping and continuing is safe.
            const info = it.next() catch continue;
            const port = info orelse return null;
            if (port.vid == dygma_vid and port.pid == defy_wireless_pid) {
                // port_name points into iterator-owned buffers and, on
                // Windows, may carry the registry string's trailing NUL.
                const name = std.mem.trimEnd(u8, port.port_name, "\x00\r\n ");
                return try normalizePortPath(alloc, name);
            }
        }
    }
}

/// "COM12" needs the "\\.\" device prefix (mandatory for COM10+); bare
/// Unix names get "/dev/" prepended. Already-qualified paths pass through.
pub fn normalizePortPath(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    if (builtin.os.tag == .windows) {
        if (!std.mem.startsWith(u8, name, "\\\\.\\")) {
            return std.fmt.allocPrint(alloc, "\\\\.\\{s}", .{name});
        }
    } else {
        if (!std.mem.startsWith(u8, name, "/")) {
            return std.fmt.allocPrint(alloc, "/dev/{s}", .{name});
        }
    }
    return alloc.dupe(u8, name);
}
