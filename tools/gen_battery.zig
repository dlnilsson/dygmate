//! Generates the tray's on-cable battery glyphs as anti-aliased 32x32 RGBA:
//!   * src/assets/battery.rgba          — solid battery (full/charged, 🔋)
//!   * src/assets/battery_charging.rgba — same battery with a lightning-bolt
//!                                         knockout (charging)
//! The tray embeds these (@embedFile), area-downscales to 16/22px and
//! alpha-composites over the icon background, so Zig needs no PNG decoder at
//! runtime. Re-run after changing a shape below:
//!
//!     zig run tools/gen_battery.zig
//!
//! Bytes are [R,G,B,A] per pixel; RGB is always white, A is edge coverage.

const std = @import("std");

const N: usize = 32; // source resolution
const SS: usize = 4; // supersampling per axis for anti-aliasing

/// Filled battery silhouette on the NxN grid: a rounded body plus a terminal
/// nub on the right. Coordinates are in source pixels.
fn inside(px: f64, py: f64) bool {
    // Terminal nub (sharp small rect abutting the body's right edge).
    if (px >= 23.0 and px < 27.5 and py >= 12.5 and py < 19.5) return true;
    // Rounded-rectangle body via the clamp-distance test.
    const bx0: f64 = 4.5;
    const bx1: f64 = 23.0;
    const by0: f64 = 9.5;
    const by1: f64 = 22.5;
    const r: f64 = 2.5;
    if (px < bx0 or px >= bx1 or py < by0 or py >= by1) return false;
    const qx = std.math.clamp(px, bx0 + r, bx1 - r);
    const qy = std.math.clamp(py, by0 + r, by1 - r);
    const dx = px - qx;
    const dy = py - qy;
    return dx * dx + dy * dy <= r * r;
}

/// Lightning-bolt polygon (source-pixel coords), knocked out of the body for
/// the charging glyph. Point-in-polygon via ray casting.
fn inBolt(px: f64, py: f64) bool {
    const v = [_][2]f64{
        .{ 14.35, 11.0 }, // top
        .{ 11.55, 16.8 }, // mid-left
        .{ 13.44, 16.8 },
        .{ 12.60, 21.0 }, // bottom tip
        .{ 16.45, 15.2 }, // upper-right
        .{ 14.56, 15.2 },
    };
    var in = false;
    var j: usize = v.len - 1;
    var i: usize = 0;
    while (i < v.len) : (i += 1) {
        const yi = v[i][1];
        const yj = v[j][1];
        if ((yi > py) != (yj > py)) {
            const xint = (v[j][0] - v[i][0]) * (py - yi) / (yj - yi) + v[i][0];
            if (px < xint) in = !in;
        }
        j = i;
    }
    return in;
}

/// Rasterize the battery into `pixels` (white RGB, alpha = supersampled edge
/// coverage). When `bolt`, the lightning polygon is knocked back out.
fn render(pixels: *[N * N * 4]u8, bolt: bool) void {
    var y: usize = 0;
    while (y < N) : (y += 1) {
        var x: usize = 0;
        while (x < N) : (x += 1) {
            var hits: usize = 0;
            var sy: usize = 0;
            while (sy < SS) : (sy += 1) {
                var sx: usize = 0;
                while (sx < SS) : (sx += 1) {
                    const px = @as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(sx)) + 0.5) / @as(f64, SS);
                    const py = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(sy)) + 0.5) / @as(f64, SS);
                    if (inside(px, py) and !(bolt and inBolt(px, py))) hits += 1;
                }
            }
            const a: u8 = @intCast(hits * 255 / (SS * SS));
            const i = (y * N + x) * 4;
            pixels[i + 0] = 255;
            pixels[i + 1] = 255;
            pixels[i + 2] = 255;
            pixels[i + 3] = a;
        }
    }
}

pub fn main() !void {
    var full: [N * N * 4]u8 = undefined;
    var charging: [N * N * 4]u8 = undefined;
    render(&full, false);
    render(&charging, true);

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = std.Io.Dir.cwd();
    dir.createDirPath(io, "src/assets") catch {};
    try write(io, dir, "src/assets/battery.rgba", &full);
    try write(io, dir, "src/assets/battery_charging.rgba", &charging);
}

fn write(io: std.Io, dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writePositionalAll(io, bytes, 0);
    std.debug.print("wrote {s} ({d} bytes)\n", .{ path, bytes.len });
}
