//! Minimal Wayland client: unix-socket connect, message marshal/unmarshal,
//! object-id allocation, SCM_RIGHTS fd passing, event dispatch, and registry
//! bind. Only the subset needed by the layer OSD is implemented. Native
//! endian. Wire format differs from D-Bus: header is 8 bytes
//! (object id, then size<<16|opcode where size INCLUDES the header), and
//! string lengths INCLUDE the terminating NUL.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

comptime {
    if (builtin.os.tag != .linux) @compileError("wayland.zig is Linux-only");
}

// ---------------------------------------------------------------------------
// Wire format.
// ---------------------------------------------------------------------------

pub const Header = struct { object: u32, opcode: u16, size: u16 };

/// Wayland uses the native byte order. The Linux targets we support are
/// little-endian, so spell it out for Zig's integer helpers.
pub fn putHeader(buf: []u8, object: u32, opcode: u16, size: u16) void {
    std.debug.assert(buf.len >= 8);
    std.mem.writeInt(u32, buf[0..4], object, .little);
    std.mem.writeInt(u32, buf[4..8], (@as(u32, size) << 16) | opcode, .little);
}

/// Fixed-capacity request builder. The largest request we send is
/// wl_registry.bind with an interface name — far under 256 bytes.
pub const Writer = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn init(object: u32, opcode: u16) Writer {
        var w = Writer{};
        putHeader(w.buf[0..8], object, opcode, 0); // size patched in finish()
        w.len = 8;
        return w;
    }

    pub fn uint(w: *Writer, v: u32) void {
        std.debug.assert(w.len + 4 <= w.buf.len);
        std.mem.writeInt(u32, w.buf[w.len..][0..4], v, .little);
        w.len += 4;
    }

    pub fn int(w: *Writer, v: i32) void {
        w.uint(@bitCast(v));
    }

    pub fn string(w: *Writer, s: []const u8) void {
        std.debug.assert(w.len + 4 + s.len + 4 <= w.buf.len);
        w.uint(@intCast(s.len + 1)); // length INCLUDES the NUL
        @memcpy(w.buf[w.len..][0..s.len], s);
        w.len += s.len;
        w.buf[w.len] = 0;
        w.len += 1;
        while (w.len % 4 != 0) : (w.len += 1) w.buf[w.len] = 0;
    }

    pub fn finish(w: *Writer) []const u8 {
        const word1 = (@as(u32, @intCast(w.len)) << 16) |
            (std.mem.readInt(u32, w.buf[4..8], .little) & 0xffff);
        std.mem.writeInt(u32, w.buf[4..8], word1, .little);
        return w.buf[0..w.len];
    }
};

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,
    valid: bool = true,

    pub fn uint(r: *Reader) u32 {
        if (r.pos > r.data.len or r.data.len - r.pos < 4) {
            r.valid = false;
            r.pos = r.data.len;
            return 0;
        }
        const v = std.mem.readInt(u32, r.data[r.pos..][0..4], .little);
        r.pos += 4;
        return v;
    }

    pub fn int(r: *Reader) i32 {
        return @bitCast(r.uint());
    }

    pub fn string(r: *Reader) []const u8 {
        const n = r.uint(); // includes NUL
        if (!r.valid or n == 0 or n > r.data.len - r.pos) {
            r.valid = false;
            r.pos = r.data.len;
            return r.data[0..0];
        }
        const s = r.data[r.pos .. r.pos + n - 1];
        r.pos += n;
        const padding = (4 - r.pos % 4) % 4;
        if (padding > r.data.len - r.pos) {
            r.valid = false;
            r.pos = r.data.len;
            return r.data[0..0];
        }
        r.pos += padding;
        return s;
    }
};

pub fn peelMessage(buf: []const u8) ?struct { header: Header, body: []const u8, consumed: usize } {
    if (buf.len < 8) return null;
    const word1 = std.mem.readInt(u32, buf[4..8], .little);
    const size: u16 = @intCast(word1 >> 16);
    if (size < 8 or buf.len < size) return null;
    return .{
        .header = .{
            .object = std.mem.readInt(u32, buf[0..4], .little),
            .opcode = @intCast(word1 & 0xffff),
            .size = size,
        },
        .body = buf[8..size],
        .consumed = size,
    };
}

// ---------------------------------------------------------------------------
// Protocol constants.
// ---------------------------------------------------------------------------

pub const op = struct {
    // wl_display (object id 1): requests
    pub const display_sync: u16 = 0;
    pub const display_get_registry: u16 = 1;
    // wl_display: events
    pub const display_ev_error: u16 = 0;
    pub const display_ev_delete_id: u16 = 1;
    // wl_registry: requests / events
    pub const registry_bind: u16 = 0;
    pub const registry_ev_global: u16 = 0;
    // wl_callback: events
    pub const callback_ev_done: u16 = 0;
    // wl_compositor: requests
    pub const compositor_create_surface: u16 = 0;
    pub const compositor_create_region: u16 = 1;
    // wl_region: requests
    pub const region_destroy: u16 = 0;
    // wl_surface: requests
    pub const surface_destroy: u16 = 0;
    pub const surface_attach: u16 = 1;
    pub const surface_damage: u16 = 2;
    pub const surface_set_input_region: u16 = 5;
    pub const surface_commit: u16 = 6;
    // wl_shm: requests
    pub const shm_create_pool: u16 = 0;
    // wl_shm_pool: requests
    pub const shm_pool_create_buffer: u16 = 0;
    pub const shm_pool_destroy: u16 = 1;
    // wl_buffer: requests / events
    pub const buffer_destroy: u16 = 0;
    pub const buffer_ev_release: u16 = 0;
    // zwlr_layer_shell_v1: requests
    pub const layer_shell_get_layer_surface: u16 = 0;
    // zwlr_layer_surface_v1: requests
    pub const layer_surface_set_size: u16 = 0;
    pub const layer_surface_set_anchor: u16 = 1;
    pub const layer_surface_set_exclusive_zone: u16 = 2;
    pub const layer_surface_set_margin: u16 = 3;
    pub const layer_surface_ack_configure: u16 = 6;
    pub const layer_surface_destroy: u16 = 7;
    // zwlr_layer_surface_v1: events
    pub const layer_surface_ev_configure: u16 = 0;
    pub const layer_surface_ev_closed: u16 = 1;
};

pub const layer_overlay: u32 = 3; // zwlr_layer_shell_v1.layer.overlay
pub const anchor_bottom: u32 = 2; // zwlr_layer_surface_v1.anchor.bottom
pub const argb8888: u32 = 0; // wl_shm.format.argb8888

// ---------------------------------------------------------------------------
// Connection and dispatch.
// ---------------------------------------------------------------------------

pub const Error = error{
    NoWaylandSocket,
    NoLayerShell,
    ProtocolError,
    ConnectionClosed,
} || std.mem.Allocator.Error;

pub const Event = struct { object: u32, opcode: u16, body: []const u8 };

pub const Connection = struct {
    gpa: std.mem.Allocator,
    sock: i32,
    next_id: u32 = 2, // wl_display is 1
    free_ids: std.ArrayList(u32) = .empty,
    // Accumulator for partial reads: events can split across recv() calls.
    read_buf: [4096]u8 = undefined,
    read_len: usize = 0,

    /// Connect to $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY (absolute $WAYLAND_DISPLAY
    /// is used as-is; the default display is "wayland-0").
    pub fn connect(gpa: std.mem.Allocator, environ: *std.process.Environ.Map) Error!*Connection {
        const display = environ.get("WAYLAND_DISPLAY") orelse "wayland-0";
        var path_buf: [108]u8 = undefined;
        const path = if (display.len > 0 and display[0] == '/')
            display
        else blk: {
            const dir = environ.get("XDG_RUNTIME_DIR") orelse return error.NoWaylandSocket;
            break :blk std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, display }) catch
                return error.NoWaylandSocket;
        };

        const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (@as(isize, @bitCast(rc)) < 0) return error.NoWaylandSocket;
        const sock: i32 = @intCast(rc);
        errdefer _ = linux.close(sock);

        var addr = linux.sockaddr.un{ .family = linux.AF.UNIX, .path = undefined };
        if (path.len >= addr.path.len) return error.NoWaylandSocket;
        @memset(addr.path[0..], 0);
        @memcpy(addr.path[0..path.len], path);
        const crc = linux.connect(sock, @ptrCast(&addr), @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1));
        if (@as(isize, @bitCast(crc)) < 0) return error.NoWaylandSocket;

        const self = try gpa.create(Connection);
        self.* = .{ .gpa = gpa, .sock = sock };
        return self;
    }

    pub fn deinit(self: *Connection) void {
        self.close();
        self.free_ids.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn close(self: *Connection) void {
        if (self.sock >= 0) _ = linux.close(self.sock);
        self.sock = -1;
    }

    pub fn fd(self: *const Connection) i32 {
        return self.sock;
    }

    pub fn newId(self: *Connection) u32 {
        if (self.free_ids.pop()) |id| return id;
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn releaseId(self: *Connection, id: u32) void {
        self.free_ids.append(self.gpa, id) catch {};
    }

    pub fn send(self: *Connection, msg: []const u8) Error!void {
        if (self.sock < 0) return error.ConnectionClosed;
        var off: usize = 0;
        while (off < msg.len) {
            const n = linux.write(self.sock, msg.ptr + off, msg.len - off);
            if (@as(isize, @bitCast(n)) <= 0) return error.ConnectionClosed;
            off += n;
        }
    }

    /// send() + one fd as SCM_RIGHTS ancillary data. Only wl_shm.create_pool
    /// needs this. cmsg layout is built by hand because the standard socket
    /// wrappers do not expose fd passing for this raw protocol client.
    pub fn sendWithFd(self: *Connection, msg: []const u8, pass_fd: i32) Error!void {
        if (self.sock < 0) return error.ConnectionClosed;
        const Cmsg = extern struct {
            len: usize,
            level: i32,
            type: i32,
            fd: i32,
            _pad: [4]u8 = @splat(0), // CMSG_SPACE aligns to usize
        };
        var cmsg = Cmsg{
            .len = @offsetOf(Cmsg, "fd") + @sizeOf(i32), // CMSG_LEN(4)
            .level = linux.SOL.SOCKET,
            .type = linux.SCM.RIGHTS,
            .fd = pass_fd,
        };
        var iov = [_]std.posix.iovec_const{.{ .base = msg.ptr, .len = msg.len }};
        const mh = linux.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = @ptrCast(&cmsg),
            .controllen = @sizeOf(Cmsg),
            .flags = 0,
        };
        const n = linux.sendmsg(self.sock, &mh, 0);
        if (@as(isize, @bitCast(n)) < 0 or n != msg.len) return error.ConnectionClosed;
    }

    /// Drain everything readable without blocking; call handler per event.
    /// wl_display.error => error.ProtocolError; delete_id recycles object ids.
    pub fn dispatch(self: *Connection, ctx: anytype, comptime handler: fn (@TypeOf(ctx), Event) void) Error!void {
        if (self.sock < 0) return error.ConnectionClosed;
        while (true) {
            if (self.read_len == self.read_buf.len) return error.ProtocolError;
            const n = linux.recvfrom(
                self.sock,
                self.read_buf[self.read_len..].ptr,
                self.read_buf.len - self.read_len,
                linux.MSG.DONTWAIT,
                null,
                null,
            );
            const sn: isize = @bitCast(n);
            if (sn < 0) {
                if (linux.errno(n) == .AGAIN) break;
                return error.ConnectionClosed;
            }
            if (sn == 0) return error.ConnectionClosed;
            self.read_len += n;

            var off: usize = 0;
            while (peelMessage(self.read_buf[off..self.read_len])) |m| {
                off += m.consumed;
                if (m.header.object == 1 and m.header.opcode == op.display_ev_error) {
                    return error.ProtocolError;
                }
                if (m.header.object == 1 and m.header.opcode == op.display_ev_delete_id) {
                    var r = Reader{ .data = m.body };
                    const id = r.uint();
                    if (!r.valid) return error.ProtocolError;
                    self.releaseId(id);
                    continue;
                }
                handler(ctx, .{ .object = m.header.object, .opcode = m.header.opcode, .body = m.body });
            }
            // Keep the partial tail for the next read.
            std.mem.copyForwards(u8, self.read_buf[0 .. self.read_len - off], self.read_buf[off..self.read_len]);
            self.read_len -= off;
        }
    }

    /// wl_display.sync + blocking-dispatch until the callback fires. Init-time
    /// only (registry, first configure) — the main loop never blocks here.
    pub fn roundtrip(self: *Connection, ctx: anytype, comptime handler: fn (@TypeOf(ctx), Event) void) Error!void {
        const cb = self.newId();
        var w = Writer.init(1, op.display_sync);
        w.uint(cb);
        try self.send(w.finish());

        var done = false;
        const wrap = struct {
            cb_id: u32,
            done_flag: *bool,
            inner_ctx: @TypeOf(ctx),

            fn on(s: @This(), ev: Event) void {
                if (ev.object == s.cb_id and ev.opcode == op.callback_ev_done) {
                    s.done_flag.* = true;
                    return;
                }
                handler(s.inner_ctx, ev);
            }
        }{ .cb_id = cb, .done_flag = &done, .inner_ctx = ctx };

        while (!done) {
            var pfd = [_]std.posix.pollfd{.{ .fd = self.sock, .events = std.posix.POLL.IN, .revents = 0 }};
            _ = std.posix.poll(&pfd, 1000) catch return error.ConnectionClosed;
            if (pfd[0].revents == 0) return error.ConnectionClosed; // compositor unresponsive
            try self.dispatch(wrap, @TypeOf(wrap).on);
        }
        // The server destroys the callback and sends delete_id, which recycles
        // `cb` via dispatch. Releasing it here too would hand the id out twice.
    }
};

// ---------------------------------------------------------------------------
// Registry binding.
// ---------------------------------------------------------------------------

/// wl_registry.bind's untyped new_id expands to interface + version + id.
pub fn bindMessage(registry: u32, name: u32, interface: []const u8, version: u32, id: u32) Writer {
    var w = Writer.init(registry, op.registry_bind);
    w.uint(name);
    w.string(interface);
    w.uint(version);
    w.uint(id);
    return w;
}

pub const Globals = struct { compositor: u32 = 0, shm: u32 = 0, layer_shell: u32 = 0 };

pub fn bindGlobals(conn: *Connection) Error!Globals {
    const registry = conn.newId();
    var w = Writer.init(1, op.display_get_registry);
    w.uint(registry);
    try conn.send(w.finish());

    var ctx = struct {
        conn: *Connection,
        registry: u32,
        globals: Globals = .{},
        send_failed: bool = false,
        bad_message: bool = false,

        fn bindOne(s: *@This(), name: u32, interface: []const u8) u32 {
            const id = s.conn.newId();
            var msg = bindMessage(s.registry, name, interface, 1, id);
            s.conn.send(msg.finish()) catch {
                s.send_failed = true;
            };
            return id;
        }

        fn on(s: *@This(), ev: Event) void {
            if (ev.object != s.registry or ev.opcode != op.registry_ev_global) return;
            var r = Reader{ .data = ev.body };
            const name = r.uint();
            const interface = r.string();
            _ = r.uint(); // advertised version; we bind version 1.
            if (!r.valid) {
                s.bad_message = true;
                return;
            }
            if (std.mem.eql(u8, interface, "wl_compositor")) {
                s.globals.compositor = s.bindOne(name, "wl_compositor");
            } else if (std.mem.eql(u8, interface, "wl_shm")) {
                s.globals.shm = s.bindOne(name, "wl_shm");
            } else if (std.mem.eql(u8, interface, "zwlr_layer_shell_v1")) {
                s.globals.layer_shell = s.bindOne(name, "zwlr_layer_shell_v1");
            }
        }
    }{ .conn = conn, .registry = registry };

    try conn.roundtrip(&ctx, @TypeOf(ctx).on);
    if (ctx.send_failed) return error.ConnectionClosed;
    if (ctx.bad_message) return error.ProtocolError;
    if (ctx.globals.layer_shell == 0) return error.NoLayerShell;
    if (ctx.globals.compositor == 0 or ctx.globals.shm == 0) return error.ProtocolError;
    return ctx.globals;
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

test "putHeader packs object id and size|opcode" {
    var buf: [8]u8 = undefined;
    putHeader(&buf, 3, 6, 12);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, buf[0..4], .little));
    try std.testing.expectEqual(@as(u32, (12 << 16) | 6), std.mem.readInt(u32, buf[4..8], .little));
}

test "Writer.string length includes NUL and pads to 4" {
    var w = Writer.init(2, 0);
    w.string("abc"); // len 4 (incl NUL), bytes "abc\x00" -> already 4-aligned
    const msg = w.finish();
    try std.testing.expectEqual(@as(usize, 8 + 4 + 4), msg.len);
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, msg[8..12], .little));
    try std.testing.expectEqualStrings("abc", msg[12..15]);
    try std.testing.expectEqual(@as(u8, 0), msg[15]);

    var w2 = Writer.init(2, 0);
    w2.string("wl_shm"); // len 7 incl NUL -> padded to 8
    const msg2 = w2.finish();
    try std.testing.expectEqual(@as(usize, 8 + 4 + 8), msg2.len);
    try std.testing.expectEqual(@as(u16, @intCast(msg2.len)), peelMessage(msg2).?.header.size);
}

test "peelMessage returns null on a partial message and consumes exactly one" {
    var w = Writer.init(1, 0);
    w.uint(42);
    const one = w.finish();
    try std.testing.expect(peelMessage(one[0..7]) == null);

    var two: [24]u8 = undefined;
    @memcpy(two[0..12], one);
    @memcpy(two[12..24], one);
    const p = peelMessage(two[0..20]).?; // second message incomplete
    try std.testing.expectEqual(@as(usize, 12), p.consumed);
    try std.testing.expectEqual(@as(u32, 1), p.header.object);
    var r = Reader{ .data = p.body };
    try std.testing.expectEqual(@as(u32, 42), r.uint());
}

test "Reader.string strips NUL and skips padding" {
    var w = Writer.init(2, 0);
    w.uint(1);
    w.string("wl_shm");
    w.uint(7);
    const msg = w.finish();
    var r = Reader{ .data = msg[8..] };
    try std.testing.expectEqual(@as(u32, 1), r.uint());
    try std.testing.expectEqualStrings("wl_shm", r.string());
    try std.testing.expectEqual(@as(u32, 7), r.uint());
}

test "roundtrip recycles the sync callback id exactly once" {
    const gpa = std.testing.allocator;
    var pair: [2]i32 = undefined;
    try std.testing.expect(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &pair) == 0);
    defer _ = linux.close(pair[1]);

    const conn = try gpa.create(Connection);
    conn.* = .{ .gpa = gpa, .sock = pair[0] };
    defer conn.deinit();

    // Fake server: the sync callback will be id 2 (first newId). Send
    // wl_callback.done followed by wl_display.delete_id(2), the order a real
    // compositor uses when it destroys the callback.
    var done = Writer.init(2, op.callback_ev_done);
    done.uint(0);
    try conn.send(done.finish()); // reuse send() to write into the pair
    var del = Writer.init(1, op.display_ev_delete_id);
    del.uint(2);
    try conn.send(del.finish());
    // Swap ends so the pre-written events are on conn's read side.
    conn.sock = pair[1];
    pair[1] = pair[0];

    var dummy: u8 = 0;
    const noop = struct {
        fn on(_: *u8, _: Event) void {}
    }.on;
    try conn.roundtrip(&dummy, noop);

    // Id 2 must come back exactly once; the next id must be fresh.
    try std.testing.expectEqual(@as(u32, 2), conn.newId());
    try std.testing.expectEqual(@as(u32, 3), conn.newId());
}

test "bindMessage expands untyped new_id to string+version+id" {
    var w = bindMessage(2, 14, "wl_shm", 1, 3);
    const msg = w.finish();
    var r = Reader{ .data = msg[8..] };
    try std.testing.expectEqual(@as(u32, 14), r.uint());
    try std.testing.expectEqualStrings("wl_shm", r.string());
    try std.testing.expectEqual(@as(u32, 1), r.uint());
    try std.testing.expectEqual(@as(u32, 3), r.uint());
    const h = peelMessage(msg).?.header;
    try std.testing.expectEqual(@as(u32, 2), h.object);
    try std.testing.expectEqual(op.registry_bind, h.opcode);
}
