//! Dygma device discovery: detect the keyboard on USB and locate its serial
//! port by USB VID/PID.
//!
//! Shared by the CLI (`main.zig`) and the tray app (`tray.zig`) so both agree
//! on how a supported keyboard is found and how a port name is made openable.

const std = @import("std");
const builtin = @import("builtin");
const serial = @import("serial");

pub const dygma_vid = 0x35EF;

/// Supported keyboards in normal (non-bootloader) mode. All use the same
/// Focus battery commands (wireless.battery.left/right.*); they differ in
/// PID, display name, and side count. Bootloader PIDs (Defy 0x0013,
/// Raise 2 0x0020/0x0022, Sonsei 0x0030) expose no battery interface and
/// are deliberately absent.
pub const Model = enum {
    defy_wireless,
    raise2,
    sonsei,

    pub fn displayName(m: Model) []const u8 {
        return switch (m) {
            .defy_wireless => "Dygma Defy",
            .raise2 => "Dygma Raise 2",
            .sonsei => "Dygma Sonsei",
        };
    }

    /// Battery-reporting sides. The Sonsei is a single-piece board; its one
    /// battery is assumed to report on the `left` channel (Bazecor issues the
    /// same left/right reads to every device and hides the right side in its
    /// UI) — adjust here if real firmware behaves differently.
    pub fn sides(m: Model) u8 {
        return switch (m) {
            .defy_wireless, .raise2 => 2,
            .sonsei => 1,
        };
    }
};

/// Model for a VID/PID pair, or null when unsupported (wrong vendor,
/// bootloader mode, or the wired gen-1 Raise).
pub fn modelForIds(vid: u16, pid: u16) ?Model {
    if (vid != dygma_vid) return null;
    return switch (pid) {
        0x0012 => .defy_wireless,
        0x0021 => .raise2, // ANSI and ISO share this PID
        0x0031 => .sonsei,
        else => null,
    };
}

/// One discovery pass: is a supported keyboard on USB, and (if so) its
/// openable port.
pub const Discovery = struct {
    /// Saw a supported VID/PID on USB this pass.
    present: bool,
    /// Owned; free with the same allocator. Null when no usable port yet.
    port: ?[]u8 = null,
    /// Which keyboard matched; null when not present.
    model: ?Model = null,
};

/// Discover a supported keyboard in a single pass and return presence, model,
/// and (when available) an owned, openable serial port path.
///
/// Linux draws the facts from two sources — sysfs for presence, the serial
/// layer for the port — so a keyboard that is plugged in but has no serial node
/// yet reads as present-without-port. Windows derives both from one serial
/// enumeration, so it never scans twice. macOS has no enumeration: use --port.
pub fn discoverDygma(io: std.Io, alloc: std.mem.Allocator) !Discovery {
    return switch (builtin.os.tag) {
        .linux => blk: {
            const scanned = scanPortInfo(io, alloc) catch Discovery{ .present = false };
            if (scanned.port != null) break :blk scanned;
            // Plugged in but no serial node yet: presence and model come
            // from sysfs.
            const model = sysfsModelLinux(io) catch null;
            break :blk .{ .present = model != null, .model = model };
        },
        .windows => scanPortInfo(io, alloc),
        else => .{ .present = false },
    };
}

/// Best-effort USB presence check for a supported Dygma keyboard.
/// Linux reads sysfs directly so tray startup can distinguish "not on USB"
/// from "present, but no usable serial port yet" without shelling out.
pub fn isDygmaPresent(io: std.Io) !bool {
    return switch (builtin.os.tag) {
        .linux => (try sysfsModelLinux(io)) != null,
        .windows => (try scanPortInfo(io, null)).present,
        .macos => false,
        else => false,
    };
}

/// Scan serial ports for a supported keyboard by USB VID/PID. Returns an
/// owned, openable port path, or null if not found (or not supported:
/// the serial lib has no port info enumeration on macOS — use --port there).
pub fn findDygmaPort(io: std.Io, alloc: std.mem.Allocator) !?[]u8 {
    if (comptime builtin.os.tag == .macos) return null;
    return (try scanPortInfo(io, alloc)).port;
}

/// The single serial enumeration behind `findDygmaPort`, `isDygmaPresent`
/// (Windows) and `discoverDygma`. Pass `alloc` to also normalize and return
/// the matched port path; pass null for a presence-only check that never
/// allocates. Works on any platform whose serial lib enumerates port info
/// (Linux + Windows); macOS callers short-circuit before reaching here.
/// With multiple supported keyboards attached, the first one in enumeration
/// order wins (unchanged from the single-model behavior).
fn scanPortInfo(io: std.Io, alloc: ?std.mem.Allocator) !Discovery {
    var it = serial.list_info(io) catch return .{ .present = false };
    defer it.deinit();
    while (true) {
        // Iteration can fail on unrelated devices (e.g. non-USB sysfs
        // entries on Linux); both platform iterators still advance, so
        // skipping and continuing is safe.
        const info = it.next() catch continue;
        const port = info orelse return .{ .present = false };
        if (modelForIds(port.vid, port.pid)) |model| {
            const a = alloc orelse return .{ .present = true, .model = model };
            // port_name points into iterator-owned buffers and, on
            // Windows, may carry the registry string's trailing NUL.
            const name = std.mem.trimEnd(u8, port.port_name, "\x00\r\n ");
            return .{ .present = true, .port = try normalizePortPath(a, name), .model = model };
        }
    }
}

fn sysfsModelLinux(io: std.Io) !?Model {
    var dir = std.Io.Dir.openDirAbsolute(io, "/sys/bus/usb/devices", .{ .iterate = true }) catch return null;
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
        if (modelForIds(vid, pid)) |m| return m;
    }
    return null;
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

test "modelForIds maps supported keyboards and rejects bootloaders" {
    try std.testing.expectEqual(.defy_wireless, modelForIds(0x35EF, 0x0012));
    try std.testing.expectEqual(.raise2, modelForIds(0x35EF, 0x0021));
    try std.testing.expectEqual(.sonsei, modelForIds(0x35EF, 0x0031));
    try std.testing.expectEqual(null, modelForIds(0x35EF, 0x0013)); // Defy bootloader
    try std.testing.expectEqual(null, modelForIds(0x35EF, 0x0020)); // Raise 2 ANSI bootloader
    try std.testing.expectEqual(null, modelForIds(0x35EF, 0x0022)); // Raise 2 ISO bootloader
    try std.testing.expectEqual(null, modelForIds(0x35EF, 0x0030)); // Sonsei bootloader
    try std.testing.expectEqual(null, modelForIds(0x1209, 0x2201)); // gen-1 Raise, wired
    try std.testing.expectEqual(null, modelForIds(0x1209, 0x0012)); // wrong VID
}

test "Model exposes display names and side counts" {
    try std.testing.expectEqualStrings("Dygma Defy", Model.defy_wireless.displayName());
    try std.testing.expectEqualStrings("Dygma Raise 2", Model.raise2.displayName());
    try std.testing.expectEqualStrings("Dygma Sonsei", Model.sonsei.displayName());
    try std.testing.expectEqual(@as(u8, 2), Model.defy_wireless.sides());
    try std.testing.expectEqual(@as(u8, 2), Model.raise2.sides());
    try std.testing.expectEqual(@as(u8, 1), Model.sonsei.sides());
}
