//! Generates `src/assets/battery.rgba` — the anti-aliased 32x32 RGBA source for
//! the tray's on-cable battery glyph. The tray embeds that blob (@embedFile),
//! area-downscales it to 16/22px and alpha-composites it over the icon
//! background, so Zig needs no PNG decoder at runtime. Re-run after changing the
//! shape below:
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

pub fn main() !void {
    var pixels: [N * N * 4]u8 = undefined;
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
                    if (inside(px, py)) hits += 1;
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

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = std.Io.Dir.cwd();
    dir.createDirPath(io, "src/assets") catch {};
    var file = try dir.createFile(io, "src/assets/battery.rgba", .{});
    defer file.close(io);
    try file.writePositionalAll(io, &pixels, 0);
    std.debug.print("wrote src/assets/battery.rgba ({d} bytes)\n", .{pixels.len});
}
