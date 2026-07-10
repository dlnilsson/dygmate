//! Dygma device discovery: detect the keyboard on USB and locate its serial
//! port by USB VID/PID.
//!
//! Shared by the CLI (`main.zig`) and the tray app (`tray.zig`) so both agree
//! on how a Defy wireless is found and how a port name is made openable.

const std = @import("std");
const builtin = @import("builtin");
const serial = @import("serial");

pub const dygma_vid = 0x35EF;
pub const defy_wireless_pid = 0x0012;

/// One discovery pass: is the Defy on USB, and (if so) its openable port.
pub const Discovery = struct {
    /// Saw the Defy VID/PID on USB this pass.
    present: bool,
    /// Owned; free with the same allocator. Null when no usable port yet.
    port: ?[]u8 = null,
};

/// Discover the Defy in a single pass and return both presence and (when
/// available) an owned, openable serial port path.
///
/// Linux draws the two facts from two sources — sysfs for presence, the serial
/// layer for the port — so a keyboard that is plugged in but has no serial node
/// yet reads as present-without-port. Windows derives both from one serial
/// enumeration, so it never scans twice. macOS has no enumeration: use --port.
pub fn discoverDygma(io: std.Io, alloc: std.mem.Allocator) !Discovery {
    return switch (builtin.os.tag) {
        .linux => blk: {
            const port = findDygmaPort(io, alloc) catch null;
            break :blk .{
                .present = port != null or (isDygmaPresentLinux(io) catch false),
                .port = port,
            };
        },
        .windows => scanPortInfo(io, alloc),
        else => .{ .present = false },
    };
}

/// Best-effort USB presence check for the Dygma Defy wireless.
/// Linux reads sysfs directly so tray startup can distinguish "not on USB"
/// from "present, but no usable serial port yet" without shelling out.
pub fn isDygmaPresent(io: std.Io) !bool {
    return switch (builtin.os.tag) {
        .linux => isDygmaPresentLinux(io),
        .windows => (try scanPortInfo(io, null)).present,
        .macos => false,
        else => false,
    };
}

/// Scan serial ports for the Defy wireless by USB VID/PID. Returns an
/// owned, openable port path, or null if not found (or not supported:
/// the serial lib has no port info enumeration on macOS — use --port there).
pub fn findDygmaPort(io: std.Io, alloc: std.mem.Allocator) !?[]u8 {
    if (comptime builtin.os.tag == .macos) return null;
    return (try scanPortInfo(io, alloc)).port;
}

/// The single serial enumeration behind `findDygmaPort`, `isDygmaPresent`
/// (Windows) and `discoverDygma` (Windows). Pass `alloc` to also normalize and
/// return the matched port path; pass null for a presence-only check that never
/// allocates. Works on any platform whose serial lib enumerates port info
/// (Linux + Windows); macOS callers short-circuit before reaching here.
fn scanPortInfo(io: std.Io, alloc: ?std.mem.Allocator) !Discovery {
    var it = serial.list_info(io) catch return .{ .present = false };
    defer it.deinit();
    while (true) {
        // Iteration can fail on unrelated devices (e.g. non-USB sysfs
        // entries on Linux); both platform iterators still advance, so
        // skipping and continuing is safe.
        const info = it.next() catch continue;
        const port = info orelse return .{ .present = false };
        if (port.vid == dygma_vid and port.pid == defy_wireless_pid) {
            const a = alloc orelse return .{ .present = true };
            // port_name points into iterator-owned buffers and, on
            // Windows, may carry the registry string's trailing NUL.
            const name = std.mem.trimEnd(u8, port.port_name, "\x00\r\n ");
            return .{ .present = true, .port = try normalizePortPath(a, name) };
        }
    }
}

fn isDygmaPresentLinux(io: std.Io) !bool {
    var dir = std.Io.Dir.openDirAbsolute(io, "/sys/bus/usb/devices", .{ .iterate = true }) catch return false;
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        var dev_dir = dir.openDir(io, entry.name, .{}) catch continue;
        defer dev_dir.close(io);

        var vendor_buf: [8]u8 = undefined;
        var product_buf: [8]u8 = undefined;
        const vendor = dev_dir.readFile(io, "idVendor", &vendor_buf) catch continue;
        const product = dev_dir.readFile(io, "idProduct", &product_buf) catch continue;
        const vid = std.fmt.parseInt(u16, std.mem.trimEnd(u8, vendor, "\r\n"), 16) catch continue;
        const pid = std.fmt.parseInt(u16, std.mem.trimEnd(u8, product, "\r\n"), 16) catch continue;
        if (vid == dygma_vid and pid == defy_wireless_pid) return true;
    }
    return false;
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
