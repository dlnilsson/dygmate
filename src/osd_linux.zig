//! Linux layer OSD: a zwlr_layer_shell_v1 overlay surface showing "Layer N",
//! rendered in software into a wl_shm buffer. Visual parity with the Windows
//! OSD (tray_windows.zig paintOsd): 156x56, rounded corners d=26, dark bg,
//! 2px border, alpha 250, bottom-centered 124px up, 900ms auto-hide.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const wayland = @import("wayland.zig");

comptime {
    if (builtin.os.tag != .linux) @compileError("osd_linux.zig is Linux-only");
}

pub const osd_width: u32 = 156;
pub const osd_height: u32 = 56;
pub const osd_stride: u32 = osd_width * 4;
pub const osd_duration_ms: i64 = 900;
pub const osd_bottom_margin: u32 = 124;

const width: usize = osd_width;
const height: usize = osd_height;
const bg = [3]u8{ 18, 20, 24 }; // R,G,B — parity with col_osd_bg
const border = [3]u8{ 92, 101, 116 }; // col_osd_border
const osd_alpha: u16 = 250;
const corner_radius: f32 = 13.0; // diameter 26
const glyph_w: usize = 5;
const glyph_h: usize = 12;
const glyph_scale: usize = 2;
const advance = (glyph_w + 1) * glyph_scale; // 12 px

// ---------------------------------------------------------------------------
// Software renderer.
// ---------------------------------------------------------------------------

/// 5x12 glyphs for "Layer 0-9 ". Row bit 0b10000 is leftmost. Cap height and
/// digits use rows 0-9; lowercase x-height rows 3-9; y descends to row 11.
fn glyph(c: u8) [glyph_h]u8 {
    return switch (c) {
        'L' => .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111, 0, 0 },
        'a' => .{ 0, 0, 0, 0b01110, 0b00001, 0b01111, 0b10001, 0b10001, 0b10011, 0b01101, 0, 0 },
        'y' => .{ 0, 0, 0, 0b10001, 0b10001, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b10001, 0b01110 },
        'e' => .{ 0, 0, 0, 0b01110, 0b10001, 0b10001, 0b11111, 0b10000, 0b10001, 0b01110, 0, 0 },
        'r' => .{ 0, 0, 0, 0b10110, 0b11001, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0, 0 },
        '0' => .{ 0b01110, 0b10001, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b10001, 0b10001, 0b01110, 0, 0 },
        '1' => .{ 0b00100, 0b01100, 0b10100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b11111, 0, 0 },
        '2' => .{ 0b01110, 0b10001, 0b00001, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b10000, 0b11111, 0, 0 },
        '3' => .{ 0b01110, 0b10001, 0b00001, 0b00001, 0b00110, 0b00001, 0b00001, 0b00001, 0b10001, 0b01110, 0, 0 },
        '4' => .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b10010, 0b11111, 0b00010, 0b00010, 0b00010, 0b00010, 0, 0 },
        '5' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10001, 0b00001, 0b00001, 0b00001, 0b10001, 0b01110, 0, 0 },
        '6' => .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110, 0, 0 },
        '7' => .{ 0b11111, 0b00001, 0b00001, 0b00010, 0b00010, 0b00100, 0b00100, 0b01000, 0b01000, 0b01000, 0, 0 },
        '8' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110, 0, 0 },
        '9' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b00001, 0b10001, 0b01110, 0, 0 },
        else => @splat(0), // space: advance only
    };
}

/// Signed distance from point (x,y) to the rounded-rect outline (1px inset,
/// radius 13). Negative means inside.
fn rectDist(x: f32, y: f32) f32 {
    const x0 = 1.0 + corner_radius;
    const x1 = @as(f32, @floatFromInt(osd_width)) - 1.0 - corner_radius;
    const y0 = 1.0 + corner_radius;
    const y1 = @as(f32, @floatFromInt(osd_height)) - 1.0 - corner_radius;
    const dx = x - std.math.clamp(x, x0, x1);
    const dy = y - std.math.clamp(y, y0, y1);
    return @sqrt(dx * dx + dy * dy) - corner_radius;
}

fn putPixel(pixels: []u8, x: usize, y: usize, r: u8, g: u8, b: u8, a: u8) void {
    // ARGB8888 is a little-endian u32 0xAARRGGBB: bytes B,G,R,A. Premultiply.
    const i = (y * width + x) * 4;
    pixels[i] = @intCast(@as(u16, b) * a / 255);
    pixels[i + 1] = @intCast(@as(u16, g) * a / 255);
    pixels[i + 2] = @intCast(@as(u16, r) * a / 255);
    pixels[i + 3] = a;
}

/// Render a complete 156x56 premultiplied ARGB8888 frame for Layer 1 through
/// Layer 10. Corners are genuinely transparent so the compositor can blend
/// them instead of relying on the Windows colorkey.
pub fn render(pixels: []u8, layer_display_num: u8) void {
    std.debug.assert(pixels.len >= width * height * 4);

    // Rounded rect with a one-pixel antialiased edge, a 2px border ring, and
    // the dark background fill.
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const d = rectDist(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5);
            if (d >= 0.5) {
                putPixel(pixels, x, y, 0, 0, 0, 0);
                continue;
            }
            const cov = std.math.clamp(0.5 - d, 0.0, 1.0);
            const c = if (d <= -2.0) bg else border;
            const a: u8 = @intFromFloat(@as(f32, @floatFromInt(osd_alpha)) * cov);
            putPixel(pixels, x, y, c[0], c[1], c[2], a);
        }
    }

    // Center "Layer N". A ten-layer Defy stays inside the 120px usable width.
    var text_buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "Layer {d}", .{layer_display_num}) catch return;
    const total_w = text.len * advance - glyph_scale; // drop trailing gap
    const total_h = glyph_h * glyph_scale;
    const left = (width - total_w) / 2;
    const top = (height - total_h) / 2;

    for (text, 0..) |c, gi| {
        const rows = glyph(c);
        const gx = left + gi * advance;
        var ry: usize = 0;
        while (ry < glyph_h) : (ry += 1) {
            var rx: usize = 0;
            while (rx < glyph_w) : (rx += 1) {
                const bit = @as(u8, 0b10000) >> @intCast(rx);
                if (rows[ry] & bit == 0) continue;
                var by: usize = 0;
                while (by < glyph_scale) : (by += 1) {
                    var bx: usize = 0;
                    while (bx < glyph_scale) : (bx += 1) {
                        putPixel(pixels, gx + rx * glyph_scale + bx, top + ry * glyph_scale + by, 255, 255, 255, 255);
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Layer-shell lifecycle.
// ---------------------------------------------------------------------------

const buffer_count = 2;
const buffer_size: usize = @as(usize, osd_stride) * @as(usize, osd_height);
const pool_size: usize = buffer_size * buffer_count;
const Buffer = struct { id: u32, busy: bool = false };

pub const Osd = struct {
    conn: *wayland.Connection,
    globals: wayland.Globals,
    pool_map: []align(std.heap.page_size_min) u8,
    buffers: [buffer_count]Buffer,
    surface: u32 = 0,
    layer_surface: u32 = 0,
    state: enum { idle, waiting_configure, mapped } = .idle,
    pending_layer: u8 = 1,
    dead: bool = false,

    /// Establish Wayland globals, create a shared-memory pool, and pre-create
    /// two buffers. No surface is mapped until the first show().
    pub fn init(gpa: std.mem.Allocator, environ: *std.process.Environ.Map) wayland.Error!Osd {
        const conn = try wayland.Connection.connect(gpa, environ);
        errdefer conn.deinit();
        const globals = try wayland.bindGlobals(conn);

        const mfd_rc = linux.memfd_create("dygmate-osd", linux.MFD.CLOEXEC);
        if (@as(isize, @bitCast(mfd_rc)) < 0) return error.NoWaylandSocket;
        const mfd: i32 = @intCast(mfd_rc);
        defer _ = linux.close(mfd); // wl_shm.create_pool receives its own fd.
        if (@as(isize, @bitCast(linux.ftruncate(mfd, @intCast(pool_size)))) < 0) {
            return error.NoWaylandSocket;
        }
        const map_rc = linux.mmap(
            null,
            pool_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            mfd,
            0,
        );
        if (@as(isize, @bitCast(map_rc)) < 0) return error.NoWaylandSocket;
        const pool_map = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(map_rc))[0..pool_size];
        errdefer _ = linux.munmap(pool_map.ptr, pool_map.len);

        const pool = conn.newId();
        var w = wayland.Writer.init(globals.shm, wayland.op.shm_create_pool);
        w.uint(pool);
        w.int(@intCast(pool_size));
        try conn.sendWithFd(w.finish(), mfd);

        var buffers: [buffer_count]Buffer = undefined;
        for (&buffers, 0..) |*b, i| {
            b.* = .{ .id = conn.newId() };
            var bw = wayland.Writer.init(pool, wayland.op.shm_pool_create_buffer);
            bw.uint(b.id);
            bw.int(@intCast(i * buffer_size)); // offset
            bw.int(@intCast(osd_width));
            bw.int(@intCast(osd_height));
            bw.int(@intCast(osd_stride));
            bw.uint(wayland.argb8888);
            try conn.send(bw.finish());
        }
        // Buffers keep the pool alive server-side; destroy our pool handle.
        var pw = wayland.Writer.init(pool, wayland.op.shm_pool_destroy);
        try conn.send(pw.finish());

        return .{ .conn = conn, .globals = globals, .pool_map = pool_map, .buffers = buffers };
    }

    pub fn deinit(self: *Osd) void {
        if (!self.dead) {
            self.hide();
            for (self.buffers) |b| {
                var w = wayland.Writer.init(b.id, wayland.op.buffer_destroy);
                self.req(&w);
            }
        }
        _ = linux.munmap(self.pool_map.ptr, self.pool_map.len);
        self.conn.deinit();
    }

    /// The Wayland fd, or -1 for a dead client so poll ignores it.
    pub fn fd(self: *const Osd) i32 {
        return if (self.dead) -1 else self.conn.fd();
    }

    pub fn alive(self: *const Osd) bool {
        return !self.dead;
    }

    fn fail(self: *Osd) void {
        self.dead = true;
        self.state = .idle;
        self.conn.close();
    }

    fn req(self: *Osd, w: *wayland.Writer) void {
        self.conn.send(w.finish()) catch self.fail();
    }

    /// Map a fresh layer surface or update the visible frame. The only state
    /// transition that waits on the compositor is the first configure.
    pub fn show(self: *Osd, layer_display_num: u8) void {
        if (self.dead) return;
        self.pending_layer = layer_display_num;
        switch (self.state) {
            .waiting_configure => {}, // configure handler draws pending_layer
            .mapped => self.attachFrame(),
            .idle => {
                self.surface = self.conn.newId();
                var w = wayland.Writer.init(self.globals.compositor, wayland.op.compositor_create_surface);
                w.uint(self.surface);
                self.req(&w);

                // Empty input region: clicks pass through to the window below.
                const region = self.conn.newId();
                var rw = wayland.Writer.init(self.globals.compositor, wayland.op.compositor_create_region);
                rw.uint(region);
                self.req(&rw);
                var sw = wayland.Writer.init(self.surface, wayland.op.surface_set_input_region);
                sw.uint(region);
                self.req(&sw);
                var dw = wayland.Writer.init(region, wayland.op.region_destroy);
                self.req(&dw);

                self.layer_surface = self.conn.newId();
                var lw = wayland.Writer.init(self.globals.layer_shell, wayland.op.layer_shell_get_layer_surface);
                lw.uint(self.layer_surface);
                lw.uint(self.surface);
                lw.uint(0); // output: compositor chooses
                lw.uint(wayland.layer_overlay);
                lw.string("dygmate-osd");
                self.req(&lw);

                var zw = wayland.Writer.init(self.layer_surface, wayland.op.layer_surface_set_size);
                zw.uint(osd_width);
                zw.uint(osd_height);
                self.req(&zw);
                var aw = wayland.Writer.init(self.layer_surface, wayland.op.layer_surface_set_anchor);
                aw.uint(wayland.anchor_bottom); // bottom-only centers horizontally
                self.req(&aw);
                var mw = wayland.Writer.init(self.layer_surface, wayland.op.layer_surface_set_margin);
                mw.int(0); // top
                mw.int(0); // right
                mw.int(@intCast(osd_bottom_margin)); // bottom
                mw.int(0); // left
                self.req(&mw);
                var ew = wayland.Writer.init(self.layer_surface, wayland.op.layer_surface_set_exclusive_zone);
                ew.int(0);
                self.req(&ew);

                // First commit carries no buffer; attach follows configure/ack.
                var cw = wayland.Writer.init(self.surface, wayland.op.surface_commit);
                self.req(&cw);
                if (!self.dead) self.state = .waiting_configure;
            },
        }
    }

    fn attachFrame(self: *Osd) void {
        const bi = for (&self.buffers, 0..) |*b, i| {
            if (!b.busy) break i;
        } else return; // both buffers busy: drop this frame
        render(self.pool_map[bi * buffer_size ..][0..buffer_size], self.pending_layer);

        var aw = wayland.Writer.init(self.surface, wayland.op.surface_attach);
        aw.uint(self.buffers[bi].id);
        aw.int(0);
        aw.int(0);
        self.req(&aw);
        var dw = wayland.Writer.init(self.surface, wayland.op.surface_damage);
        dw.int(0);
        dw.int(0);
        dw.int(@intCast(osd_width));
        dw.int(@intCast(osd_height));
        self.req(&dw);
        var cw = wayland.Writer.init(self.surface, wayland.op.surface_commit);
        self.req(&cw);
        if (!self.dead) self.buffers[bi].busy = true;
    }

    /// Destroy surface objects instead of attaching a null buffer. A later
    /// show gets the fresh configure handshake required by layer-shell.
    pub fn hide(self: *Osd) void {
        if (self.dead or self.state == .idle) return;
        var lw = wayland.Writer.init(self.layer_surface, wayland.op.layer_surface_destroy);
        self.req(&lw);
        var sw = wayland.Writer.init(self.surface, wayland.op.surface_destroy);
        self.req(&sw);
        self.layer_surface = 0;
        self.surface = 0;
        self.state = .idle;
    }

    pub fn handleReadable(self: *Osd) void {
        if (self.dead) return;
        self.conn.dispatch(self, onEvent) catch self.fail();
    }

    fn onEvent(self: *Osd, ev: wayland.Event) void {
        if (ev.object == self.layer_surface and ev.opcode == wayland.op.layer_surface_ev_configure) {
            var r = wayland.Reader{ .data = ev.body };
            const serial = r.uint();
            if (!r.valid) {
                self.fail();
                return;
            }
            // Ack before first attach: reversing this is a fatal protocol error.
            var w = wayland.Writer.init(self.layer_surface, wayland.op.layer_surface_ack_configure);
            w.uint(serial);
            self.req(&w);
            if (self.state == .waiting_configure and !self.dead) {
                self.state = .mapped;
                self.attachFrame();
            }
            return;
        }
        if (ev.object == self.layer_surface and ev.opcode == wayland.op.layer_surface_ev_closed) {
            // Compositor unmapped us (for example after an output disappears).
            self.hide();
            return;
        }
        for (&self.buffers) |*b| {
            if (ev.object == b.id and ev.opcode == wayland.op.buffer_ev_release) b.busy = false;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

test "render: center pixel is premultiplied background" {
    var buf: [osd_width * osd_height * 4]u8 = undefined;
    render(&buf, 1);
    const i = ((osd_height / 2) * osd_width + 8) * 4; // left of text, inside rect
    // ARGB8888 little-endian: bytes are B,G,R,A. Premultiplied by 250/255:
    // B 24->23, G 20->19, R 18->17.
    try std.testing.expectEqual(@as(u8, 23), buf[i]);
    try std.testing.expectEqual(@as(u8, 19), buf[i + 1]);
    try std.testing.expectEqual(@as(u8, 17), buf[i + 2]);
    try std.testing.expectEqual(@as(u8, 250), buf[i + 3]);
}

test "render: corner pixel is fully transparent" {
    var buf: [osd_width * osd_height * 4]u8 = undefined;
    render(&buf, 1);
    try std.testing.expectEqual(@as(u8, 0), buf[3]); // A of pixel (0,0)
    const last = (osd_width * osd_height - 1) * 4;
    try std.testing.expectEqual(@as(u8, 0), buf[last + 3]); // A of (155,55)
}

test "render: top-edge midpoint is border color" {
    var buf: [osd_width * osd_height * 4]u8 = undefined;
    render(&buf, 1);
    const i = (2 * osd_width + osd_width / 2) * 4; // y=2 inside full border
    try std.testing.expectEqual(@as(u8, 113), buf[i]); // B 116 premult
    try std.testing.expectEqual(@as(u8, 99), buf[i + 1]); // G 101 premult
    try std.testing.expectEqual(@as(u8, 90), buf[i + 2]); // R 92 premult
}

test "render: white text pixels exist for Layer 1 and Layer 10" {
    inline for (.{ 1, 10 }) |n| {
        var buf: [osd_width * osd_height * 4]u8 = undefined;
        render(&buf, n);
        var found = false;
        var i: usize = 0;
        while (i < buf.len) : (i += 4) {
            if (buf[i] == 255 and buf[i + 1] == 255 and buf[i + 2] == 255) found = true;
        }
        try std.testing.expect(found);
    }
}
