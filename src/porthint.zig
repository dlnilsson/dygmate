//! Human-readable hint for a serial-port open failure. The right advice
//! differs by platform: on Windows an access-denied usually means another app
//! (Bazecor) holds the COM port; on Linux/POSIX it almost always means the
//! user lacks permission on the device node (group membership or a udev rule),
//! which is a different fix entirely.

const std = @import("std");
const builtin = @import("builtin");

/// A parenthesized hint (with a leading space) to append after an open error,
/// or "" when no specific advice applies. `err` is the error returned by
/// opening the port.
pub fn forOpenError(err: anyerror) []const u8 {
    const permission = err == error.AccessDenied or err == error.PermissionDenied;
    if (builtin.os.tag == .windows) {
        return if (permission)
            " (port busy: close Bazecor or another dygmate instance)"
        else
            "";
    }
    // Linux / other POSIX. EACCES/EPERM here is a device-node permission
    // problem, not a busy port; a truly busy port surfaces as a different
    // error (e.g. the device already opened exclusively).
    return if (permission)
        " (permission denied: add your user to the 'uucp' group (Arch) or " ++
            "'dialout' group (Debian/Ubuntu) and log out/in, or install a udev " ++
            "rule granting access to the Dygma; the port is not busy)"
    else
        "";
}

test "windows treats access-denied as a busy port" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expect(std.mem.indexOf(u8, forOpenError(error.AccessDenied), "Bazecor") != null);
}

test "linux treats access-denied as a permission problem" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const hint = forOpenError(error.AccessDenied);
    try std.testing.expect(std.mem.indexOf(u8, hint, "uucp") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "Bazecor") == null);
}

test "unrelated errors get no hint" {
    try std.testing.expectEqualStrings("", forOpenError(error.FileNotFound));
}
