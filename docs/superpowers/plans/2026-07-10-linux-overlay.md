# Linux Wayland Layer Overlay (OSD) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the Windows-style "Layer N" on-screen popup on Linux/Wayland when the Defy switches layers, with exact behavior parity: 156x56 rounded rect, 124px above the bottom edge, centered horizontally, 900ms auto-hide, 250ms layer poll, tray-menu toggle.

**Architecture:** A hand-rolled Wayland wire-protocol client (`src/wayland.zig`, mirrors `src/dbus.zig`'s structure) plus an OSD module (`src/osd_linux.zig`) that owns a `zwlr_layer_shell_v1` overlay surface, a `wl_shm` double-buffered pixel pool, and a pure software renderer (rounded rect + hand-authored bitmap font). `tray_linux.zig` gains a third pollfd (the Wayland socket), a poll-timeout-based hide deadline, and a "Show layer overlay" dbusmenu checkmark item. The layer read in the shared poll loop is switched on (`osd_enabled=true` comptime).

**Tech Stack:** Zig 0.16.0, raw `std.os.linux` syscalls for the Wayland socket (`socket`/`connect`/`sendmsg` with SCM_RIGHTS/`recvfrom`/`memfd_create`/`mmap`) — `std.Io.net` cannot pass fds, and the tray already uses raw syscalls (eventfd, flock). Protocols: core Wayland (`wl_display`, `wl_registry`, `wl_compositor`, `wl_surface`, `wl_shm`, `wl_region`, `wl_buffer`, `wl_callback`) + `zwlr_layer_shell_v1`.

## Global Constraints

- Zig 0.16.0 exactly. No C libraries, no libwayland, no wayland-scanner: opcodes and message layouts are hand-written consts, same as `dbus.zig` hand-writes the D-Bus wire protocol.
- Wayland only. No X11. Compositor must advertise `zwlr_layer_shell_v1` (Hyprland/wlroots, KDE). If it doesn't (GNOME) — or there is no Wayland socket at all — the tray must run exactly as today with the OSD disabled and its menu item grayed out. Never crash the tray on any Wayland failure.
- Exact Windows parity (`src/tray_windows.zig:263-268,278-281`): 156x56 px, corner diameter 26 (1px inset), bg rgb(18,20,24), border rgb(92,101,116) 2px, white text "Layer N", alpha 250, bottom margin 124, duration 900ms. Toggle default-on, NOT persisted.
- All Wayland I/O on the main (UI) thread only, same discipline as D-Bus (`tray_linux.zig:197-198`). The serial poll thread touches only `State` + the eventfd.
- Windows build must remain untouched: `zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSmall` green after every task.
- Go coding preferences in CLAUDE.md do NOT apply — this is Zig. Follow repo style: `//!` file doc comments, `//` item comments, section banners `// ---`.
- `build.zig` needs NO changes (nothing links; raw syscalls only).

---

## File Structure

- `src/wayland.zig` (new) — generic Wayland client: socket connect, message marshal/peel, object-id allocator, fd-passing sendmsg, event dispatch, init-time roundtrip, registry bind. No OSD knowledge.
- `src/osd_linux.zig` (new) — OSD domain: constants, ARGB renderer (rounded rect + glyph font), `Osd` struct (shm pool, surface lifecycle state machine, layer-shell protocol dance).
- `src/tray_linux.zig` (modify) — poll-loop integration (3rd fd, hide deadline, drain `layer_change`), menu toggle item, enable layer polling, register new test files.
- `src/tray_common.zig` (modify) — two stale doc comments only.
- `README.md` (modify) — Linux overlay documented, Hyprland `layerrule` namespace note.

---

## Task 1: `src/wayland.zig` — wire format + message peeling

**Files:**
- Create: `src/wayland.zig`

**Interfaces (produced, consumed by Tasks 2-5):**
- `pub const Header = struct { object: u32, opcode: u16, size: u16 };`
- `pub fn putHeader(buf: []u8, object: u32, opcode: u16, size: u16) void` — native endian; word1 = `(@as(u32, size) << 16) | opcode`.
- `pub const Writer = struct { buf: [256]u8, len: usize, pub fn init(object: u32, opcode: u16) Writer, pub fn uint(w: *Writer, v: u32) void, pub fn int(w: *Writer, v: i32) void, pub fn string(w: *Writer, s: []const u8) void, pub fn finish(w: *Writer) []const u8 }` — fixed buffer (largest message we send is `bind` with an interface name, well under 256), `finish` back-patches the size into the header.
- `pub const Reader = struct { data: []const u8, pos: usize = 0, pub fn uint(...) u32, pub fn int(...) i32, pub fn string(...) []const u8 }` — string returns the bytes without the NUL, advances past padding.
- `pub fn peelMessage(buf: []const u8) ?struct { header: Header, body: []const u8, consumed: usize }` — null when `buf` holds less than a complete message.

Wayland wire rules (differ from D-Bus — document in the file header):
- Native endian (D-Bus repo code is forced-LE 'l').
- Header 8 bytes: word0 = sender object id; word1 = size (upper 16 bits, includes the 8-byte header) | opcode (lower 16).
- Strings: u32 length **including** the terminating NUL, then bytes + NUL, padded to 4 (D-Bus length excludes the NUL).
- All args 4-byte aligned; no alignment padding beyond string/array pad-to-4.

- [ ] **Step 1: Write failing tests**

Create `src/wayland.zig` with the file header and tests only (no implementation yet):

```zig
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

test "putHeader packs object id and size|opcode" {
    var buf: [8]u8 = undefined;
    putHeader(&buf, 3, 6, 12);
    try std.testing.expectEqual(@as(u32, 3), std.mem.bytesToValue(u32, buf[0..4]));
    try std.testing.expectEqual(@as(u32, (12 << 16) | 6), std.mem.bytesToValue(u32, buf[4..8]));
}

test "Writer.string length includes NUL and pads to 4" {
    var w = Writer.init(2, 0);
    w.string("abc"); // len 4 (incl NUL), bytes "abc\x00" -> already 4-aligned
    const msg = w.finish();
    try std.testing.expectEqual(@as(usize, 8 + 4 + 4), msg.len);
    try std.testing.expectEqual(@as(u32, 4), std.mem.bytesToValue(u32, msg[8..12]));
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
```

- [ ] **Step 2: Run tests, verify they fail to compile**

Run: `zig build test-tray 2>&1 | head -20`
Expected: compile errors — `putHeader`/`Writer`/`Reader`/`peelMessage` not defined. (New file isn't referenced yet; run `zig test src/wayland.zig` directly for this task.)

Run: `zig test src/wayland.zig`
Expected: FAIL to compile, undefined identifiers.

- [ ] **Step 3: Implement**

```zig
pub const Header = struct { object: u32, opcode: u16, size: u16 };

pub fn putHeader(buf: []u8, object: u32, opcode: u16, size: u16) void {
    std.mem.writeInt(u32, buf[0..4], object, .little);
    std.mem.writeInt(u32, buf[4..8], (@as(u32, size) << 16) | opcode, .little);
}
```

(Native endian on all our targets is little; using `.little` explicitly keeps `writeInt` happy and is correct on x86_64/aarch64. Add a comment noting Wayland is native-endian.)

```zig
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
        std.mem.writeInt(u32, w.buf[w.len..][0..4], v, .little);
        w.len += 4;
    }

    pub fn int(w: *Writer, v: i32) void {
        w.uint(@bitCast(v));
    }

    pub fn string(w: *Writer, s: []const u8) void {
        w.uint(@intCast(s.len + 1)); // length INCLUDES the NUL
        @memcpy(w.buf[w.len..][0..s.len], s);
        w.len += s.len;
        w.buf[w.len] = 0;
        w.len += 1;
        while (w.len % 4 != 0) : (w.len += 1) w.buf[w.len] = 0;
    }

    pub fn finish(w: *Writer) []const u8 {
        const word1 = (@as(u32, @intCast(w.len)) << 16) |
            (std.mem.bytesToValue(u32, w.buf[4..8]) & 0xffff);
        std.mem.writeInt(u32, w.buf[4..8], word1, .little);
        return w.buf[0..w.len];
    }
};

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn uint(r: *Reader) u32 {
        const v = std.mem.bytesToValue(u32, r.data[r.pos..][0..4]);
        r.pos += 4;
        return v;
    }

    pub fn int(r: *Reader) i32 {
        return @bitCast(r.uint());
    }

    pub fn string(r: *Reader) []const u8 {
        const n = r.uint(); // includes NUL
        const s = r.data[r.pos .. r.pos + n - 1];
        r.pos += n;
        while (r.pos % 4 != 0) r.pos += 1;
        return s;
    }
};

pub fn peelMessage(buf: []const u8) ?struct { header: Header, body: []const u8, consumed: usize } {
    if (buf.len < 8) return null;
    const word1 = std.mem.bytesToValue(u32, buf[4..8]);
    const size: u16 = @intCast(word1 >> 16);
    if (size < 8 or buf.len < size) return null;
    return .{
        .header = .{
            .object = std.mem.bytesToValue(u32, buf[0..4]),
            .opcode = @intCast(word1 & 0xffff),
            .size = size,
        },
        .body = buf[8..size],
        .consumed = size,
    };
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `zig test src/wayland.zig`
Expected: `All 4 tests passed.`

- [ ] **Step 5: Commit**

```bash
git add src/wayland.zig
git commit -m "Add Wayland wire-format marshalling"
```

---

## Task 2: `src/wayland.zig` — Connection: socket, fd passing, dispatch, roundtrip

**Files:**
- Modify: `src/wayland.zig`

**Interfaces (produced):**
- `pub const Error = error{ NoWaylandSocket, NoLayerShell, ProtocolError, ConnectionClosed } || std.mem.Allocator.Error;`
- `pub const Event = struct { object: u32, opcode: u16, body: []const u8 };`
- `pub const Connection = struct { ... }` with:
  - `pub fn connect(gpa: std.mem.Allocator, environ: *std.process.Environ.Map) Error!*Connection`
  - `pub fn deinit(self: *Connection) void`
  - `pub fn fd(self: *const Connection) i32`
  - `pub fn newId(self: *Connection) u32` / `fn releaseId(self: *Connection, id: u32) void`
  - `pub fn send(self: *Connection, msg: []const u8) Error!void`
  - `pub fn sendWithFd(self: *Connection, msg: []const u8, pass_fd: i32) Error!void`
  - `pub fn dispatch(self: *Connection, ctx: anytype, comptime handler: fn (@TypeOf(ctx), Event) void) Error!void` — non-blocking drain; handles `wl_display.error`/`delete_id` internally.
  - `pub fn roundtrip(self: *Connection, ctx: anytype, comptime handler: fn (@TypeOf(ctx), Event) void) Error!void` — `wl_display.sync`, then blocking-dispatch until the callback's `done`.

Opcode consts (add as a `pub const op = struct { ... }` block; values from the core + wlr-layer-shell XML, hand-checked):

```zig
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
```

- [ ] **Step 1: Implement Connection**

```zig
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
    /// used as-is; default "wayland-0").
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
        _ = linux.close(self.sock);
        self.free_ids.deinit(self.gpa);
        self.gpa.destroy(self);
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
        var off: usize = 0;
        while (off < msg.len) {
            const n = linux.write(self.sock, msg.ptr + off, msg.len - off);
            if (@as(isize, @bitCast(n)) < 0) return error.ConnectionClosed;
            off += n;
        }
    }

    /// send() + one fd as SCM_RIGHTS ancillary data. Only wl_shm.create_pool
    /// needs this. cmsg layout built by hand (no std wrapper for sendmsg).
    pub fn sendWithFd(self: *Connection, msg: []const u8, pass_fd: i32) Error!void {
        const Cmsg = extern struct {
            len: usize,
            level: i32,
            @"type": i32,
            fd: i32,
            _pad: [4]u8 = @splat(0), // CMSG_SPACE aligns to usize
        };
        var cmsg = Cmsg{
            .len = @offsetOf(Cmsg, "fd") + @sizeOf(i32), // CMSG_LEN(4)
            .level = linux.SOL.SOCKET,
            .@"type" = 0x01, // SCM_RIGHTS
            .fd = pass_fd,
        };
        var iov = [_]std.posix.iovec_const{.{ .base = msg.ptr, .len = msg.len }};
        const mh = linux.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &cmsg,
            .controllen = @sizeOf(Cmsg),
            .flags = 0,
        };
        const n = linux.sendmsg(self.sock, &mh, 0);
        if (@as(isize, @bitCast(n)) < 0) return error.ConnectionClosed;
        if (n != msg.len) return error.ConnectionClosed; // one small message; no partial handling
    }

    /// Drain everything readable without blocking; call `handler` per event.
    /// wl_display.error => error.ProtocolError; delete_id recycles object ids.
    pub fn dispatch(self: *Connection, ctx: anytype, comptime handler: fn (@TypeOf(ctx), Event) void) Error!void {
        while (true) {
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
                const err = linux.E.init(n);
                if (err == .AGAIN) break;
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
                    self.releaseId(r.uint());
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
        var wrap = struct {
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
        self.releaseId(cb);
    }
};
```

Note for the implementer: exact field names of `linux.msghdr_const` / `linux.sockaddr.un` / `linux.E.init` may differ slightly in Zig 0.16 — check `lib/std/os/linux.zig` and adjust; the semantics above are the contract. If `@TypeOf(ctx)`-generic dispatch fights the compiler, fall back to `ctx: *anyopaque` + function pointer; keep the public shape.

- [ ] **Step 2: Compile check + run existing tests**

Run: `zig test src/wayland.zig`
Expected: `All 4 tests passed.` (Connection has no unit tests — it's exercised live in Task 5; the pure parts stay covered.)

- [ ] **Step 3: Commit**

```bash
git add src/wayland.zig
git commit -m "Add Wayland connection, fd passing, and event dispatch"
```

---

## Task 3: `src/wayland.zig` — registry bind

**Files:**
- Modify: `src/wayland.zig`

**Interfaces (produced, consumed by Task 5):**
- `pub const Globals = struct { compositor: u32 = 0, shm: u32 = 0, layer_shell: u32 = 0 };`
- `pub fn bindGlobals(conn: *Connection) Error!Globals` — returns `error.NoLayerShell` when the compositor lacks `zwlr_layer_shell_v1`.
- `pub fn bindMessage(registry: u32, name: u32, interface: []const u8, version: u32, id: u32) Writer` — pulled out pure so it's unit-testable.

**The trap this task exists for:** `wl_registry.bind`'s `new_id` argument is untyped, so it marshals as THREE values — interface string + version uint + id uint — not one. This is the classic hand-rolled-client bug.

- [ ] **Step 1: Write failing test**

```zig
test "bindMessage expands untyped new_id to string+version+id" {
    var w = bindMessage(2, 14, "wl_shm", 1, 3);
    const msg = w.finish();
    var r = Reader{ .data = msg[8..] };
    try std.testing.expectEqual(@as(u32, 14), r.uint()); // global name
    try std.testing.expectEqualStrings("wl_shm", r.string()); // interface
    try std.testing.expectEqual(@as(u32, 1), r.uint()); // version
    try std.testing.expectEqual(@as(u32, 3), r.uint()); // new object id
    const h = peelMessage(msg).?.header;
    try std.testing.expectEqual(@as(u32, 2), h.object);
    try std.testing.expectEqual(op.registry_bind, h.opcode);
}
```

- [ ] **Step 2: Run test, verify failure**

Run: `zig test src/wayland.zig`
Expected: compile error, `bindMessage` not defined.

- [ ] **Step 3: Implement**

```zig
pub fn bindMessage(registry: u32, name: u32, interface: []const u8, version: u32, id: u32) Writer {
    var w = Writer.init(registry, op.registry_bind);
    w.uint(name);
    // Untyped new_id: marshals as (interface, version, id), NOT a bare id.
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

        fn bindOne(s: *@This(), name: u32, interface: []const u8, version: u32) u32 {
            const id = s.conn.newId();
            var msg = bindMessage(s.registry, name, interface, version, id);
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
            const version = r.uint();
            _ = version;
            if (std.mem.eql(u8, interface, "wl_compositor")) {
                s.globals.compositor = s.bindOne(name, "wl_compositor", 1);
            } else if (std.mem.eql(u8, interface, "wl_shm")) {
                s.globals.shm = s.bindOne(name, "wl_shm", 1);
            } else if (std.mem.eql(u8, interface, "zwlr_layer_shell_v1")) {
                s.globals.layer_shell = s.bindOne(name, "zwlr_layer_shell_v1", 1);
            }
        }
    }{ .conn = conn, .registry = registry };

    try conn.roundtrip(&ctx, @TypeOf(ctx).on);
    if (ctx.send_failed) return error.ConnectionClosed;
    if (ctx.globals.layer_shell == 0) return error.NoLayerShell;
    if (ctx.globals.compositor == 0 or ctx.globals.shm == 0) return error.ProtocolError;
    return ctx.globals;
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `zig test src/wayland.zig`
Expected: `All 5 tests passed.`

- [ ] **Step 5: Commit**

```bash
git add src/wayland.zig
git commit -m "Add Wayland registry bind with untyped new_id expansion"
```

---

## Task 4: `src/osd_linux.zig` — software renderer (rounded rect + glyph font)

**Files:**
- Create: `src/osd_linux.zig`

**Interfaces (produced, consumed by Tasks 5-6):**
- `pub const osd_width: u32 = 156;` `pub const osd_height: u32 = 56;` `pub const osd_stride: u32 = osd_width * 4;` `pub const osd_duration_ms: i64 = 900;` `pub const osd_bottom_margin: u32 = 124;`
- `pub fn render(pixels: []u8, layer_display_num: u8) void` — fills a 156x56 ARGB8888 **premultiplied** little-endian pixel buffer ("Layer N", N in 1..10).

Visual spec (parity with `tray_windows.zig` `paintOsd`): rounded rect inset 1px, corner radius 13 (diameter 26), fill rgb(18,20,24), 2px border rgb(92,101,116), overall alpha 250/255, corners genuinely transparent (real alpha replaces Windows' magenta colorkey), white bold-ish text centered.

Font: hand-authored 5x12 bitmap glyphs (precedent: 3x5 glyphs, `tray_linux.zig:41-57`), drawn at integer scale 2 → 10x24px per glyph, 1 blank column in the advance → advance 12px. "Layer 10" (8 chars) = 94px wide, fits the 120px usable width (Windows insets text 18px per side).

- [ ] **Step 1: Write failing tests**

Create `src/osd_linux.zig`:

```zig
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
    const i = (2 * osd_width + osd_width / 2) * 4; // y=2 inside the 2px border
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
```

- [ ] **Step 2: Run tests, verify failure**

Run: `zig test src/osd_linux.zig`
Expected: compile error, `render`/constants not defined.

- [ ] **Step 3: Implement constants, glyphs, and render**

```zig
pub const osd_width: u32 = 156;
pub const osd_height: u32 = 56;
pub const osd_stride: u32 = osd_width * 4;
pub const osd_duration_ms: i64 = 900;
pub const osd_bottom_margin: u32 = 124;

const bg = [3]u8{ 18, 20, 24 }; // R,G,B — parity with col_osd_bg
const border = [3]u8{ 92, 101, 116 }; // col_osd_border
const osd_alpha: u16 = 250;
const corner_radius: f32 = 13.0; // diameter 26
const glyph_w: usize = 5;
const glyph_h: usize = 12;
const glyph_scale: usize = 2;
const advance = (glyph_w + 1) * glyph_scale; // 12 px

/// 5x12 glyphs for "Layer 0-9 ". Row bit 0b10000 is leftmost. Cap height /
/// digits use rows 0-9; lowercase x-height rows 3-9; 'y' descends to row 11.
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
/// radius 13). Negative = inside.
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
    const i = (y * osd_width + x) * 4;
    pixels[i] = @intCast(@as(u16, b) * a / 255);
    pixels[i + 1] = @intCast(@as(u16, g) * a / 255);
    pixels[i + 2] = @intCast(@as(u16, r) * a / 255);
    pixels[i + 3] = a;
}

pub fn render(pixels: []u8, layer_display_num: u8) void {
    // Background: rounded rect with a 1px antialiased outer edge, 2px border
    // ring, bg fill. Outside: fully transparent (real alpha, no colorkey).
    var y: usize = 0;
    while (y < osd_height) : (y += 1) {
        var x: usize = 0;
        while (x < osd_width) : (x += 1) {
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

    // Text "Layer N", centered.
    var text_buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "Layer {d}", .{layer_display_num}) catch return;
    const total_w = text.len * advance - glyph_scale; // drop trailing gap
    const total_h = glyph_h * glyph_scale;
    const left = (osd_width - total_w) / 2;
    const top = (osd_height - total_h) / 2;

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
```

- [ ] **Step 4: Run tests, verify pass**

Run: `zig test src/osd_linux.zig`
Expected: `All 4 tests passed.` (If the border test's y=2 lands on the AA ramp rather than full-coverage border, assert at y=3 instead — the intent is "a fully-covered border pixel".)

- [ ] **Step 5: Commit**

```bash
git add src/osd_linux.zig
git commit -m "Add OSD software renderer with bitmap glyph font"
```

---

## Task 5: `src/osd_linux.zig` — surface lifecycle state machine

**Files:**
- Modify: `src/osd_linux.zig`

**Interfaces (produced, consumed by Task 6):**
```zig
pub const Osd = struct {
    pub fn init(gpa: std.mem.Allocator, environ: *std.process.Environ.Map) wayland.Error!Osd
    pub fn deinit(self: *Osd) void
    pub fn fd(self: *const Osd) i32              // for the poll set
    pub fn alive(self: *const Osd) bool          // false after protocol error/EOF
    pub fn show(self: *Osd, layer_display_num: u8) void  // errors flip dead, never throw
    pub fn hide(self: *Osd) void
    pub fn handleReadable(self: *Osd) void       // dispatch pending events
};
```

**Protocol dance (the order matters):**
1. show from `.idle`: `create_surface` → empty-input-region (`create_region`, `set_input_region`, `region_destroy`) for click-through → `get_layer_surface(surface, output=0, layer=overlay(3), "dygmate-osd")` → `set_size(156,56)` → `set_anchor(bottom=2)` (bottom-only anchor = compositor centers horizontally) → `set_margin(0,0,124,0)` (top,right,bottom,left) → `set_exclusive_zone(0)` → **commit with no buffer** → `.waiting_configure`.
2. `configure(serial,w,h)` event: `ack_configure(serial)` **BEFORE attaching** (attaching first is a fatal protocol error), then render `pending_layer` into a free buffer, `attach` + `damage(0,0,156,56)` + `commit` → `.mapped`.
3. show while `.waiting_configure`: just update `pending_layer`. Show while `.mapped`: render into a non-busy buffer, attach/damage/commit; if both buffers busy, drop the frame (next change catches up).
4. `hide`: `layer_surface_destroy` then `surface_destroy` (that order), back to `.idle`. Destroy-per-show is deliberate: attaching a NULL buffer unmaps a layer surface and remapping needs a fresh configure anyway. Pool + buffers persist across shows.
5. `closed` event: compositor removed the surface (output unplugged) → drop ids, `.idle`.
6. `wl_buffer.release` event: clear that buffer's busy flag.
7. Any `error.ProtocolError`/`ConnectionClosed` anywhere: `dead = true`, close socket. No reconnect; tray unaffected.

- [ ] **Step 1: Implement**

```zig
const buffer_count = 2;
const buffer_size: usize = osd_stride * osd_height; // 34944
const pool_size: usize = buffer_size * buffer_count;

pub const Osd = struct {
    conn: *wayland.Connection,
    globals: wayland.Globals,
    pool_map: []align(std.heap.page_size_min) u8,
    buffers: [buffer_count]struct { id: u32, busy: bool = false },
    surface: u32 = 0,
    layer_surface: u32 = 0,
    state: enum { idle, waiting_configure, mapped } = .idle,
    pending_layer: u8 = 1,
    dead: bool = false,

    pub fn init(gpa: std.mem.Allocator, environ: *std.process.Environ.Map) wayland.Error!Osd {
        const conn = try wayland.Connection.connect(gpa, environ);
        errdefer conn.deinit();
        const globals = try wayland.bindGlobals(conn);

        // Shared-memory pool: memfd -> ftruncate -> mmap -> wl_shm.create_pool
        // (fd passed via SCM_RIGHTS) -> two wl_buffers side by side.
        const mfd_rc = linux.memfd_create("dygmate-osd", linux.MFD.CLOEXEC);
        if (@as(isize, @bitCast(mfd_rc)) < 0) return error.NoWaylandSocket;
        const mfd: i32 = @intCast(mfd_rc);
        defer _ = linux.close(mfd); // pool holds its own reference after create_pool
        if (@as(isize, @bitCast(linux.ftruncate(mfd, pool_size))) < 0) return error.NoWaylandSocket;
        const map_rc = linux.mmap(null, pool_size, linux.PROT.READ | linux.PROT.WRITE, .{ .TYPE = .SHARED }, mfd, 0);
        if (@as(isize, @bitCast(map_rc)) < 0) return error.NoWaylandSocket;
        const pool_map = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(map_rc))[0..pool_size];

        const pool = conn.newId();
        var w = wayland.Writer.init(globals.shm, wayland.op.shm_create_pool);
        w.uint(pool);
        w.int(@intCast(pool_size));
        try conn.sendWithFd(w.finish(), mfd);

        var buffers: [buffer_count]struct { id: u32, busy: bool = false } = undefined;
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
        // Buffers keep the pool alive server-side; destroy our handle.
        var pw = wayland.Writer.init(pool, wayland.op.shm_pool_destroy);
        try conn.send(pw.finish());

        return .{ .conn = conn, .globals = globals, .pool_map = pool_map, .buffers = buffers };
    }

    pub fn deinit(self: *Osd) void {
        _ = linux.munmap(self.pool_map.ptr, self.pool_map.len);
        self.conn.deinit();
    }

    pub fn fd(self: *const Osd) i32 {
        return if (self.dead) -1 else self.conn.fd();
    }

    pub fn alive(self: *const Osd) bool {
        return !self.dead;
    }

    fn fail(self: *Osd) void {
        self.dead = true;
        self.state = .idle;
    }

    fn req(self: *Osd, w: *wayland.Writer) void {
        self.conn.send(w.finish()) catch self.fail();
    }

    pub fn show(self: *Osd, layer_display_num: u8) void {
        if (self.dead) return;
        self.pending_layer = layer_display_num;
        switch (self.state) {
            .waiting_configure => {}, // configure handler will draw pending_layer
            .mapped => self.attachFrame(),
            .idle => {
                self.surface = self.conn.newId();
                var w = wayland.Writer.init(self.globals.compositor, wayland.op.compositor_create_surface);
                w.uint(self.surface);
                self.req(&w);

                // Empty input region: clicks pass through (WS_EX_TRANSPARENT).
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
                aw.uint(wayland.anchor_bottom); // bottom-only: centered horizontally
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

                // First commit MUST carry no buffer; attach happens after the
                // configure/ack handshake.
                var cw = wayland.Writer.init(self.surface, wayland.op.surface_commit);
                self.req(&cw);
                self.state = .waiting_configure;
            },
        }
    }

    fn attachFrame(self: *Osd) void {
        const bi = for (&self.buffers, 0..) |*b, i| {
            if (!b.busy) break i;
        } else return; // both busy: drop the frame
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
        self.buffers[bi].busy = true;
    }

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
            // ack BEFORE the first attach — the reverse is a protocol error.
            var w = wayland.Writer.init(self.layer_surface, wayland.op.layer_surface_ack_configure);
            w.uint(serial);
            self.req(&w);
            if (self.state == .waiting_configure) {
                self.state = .mapped;
                self.attachFrame();
            }
            return;
        }
        if (ev.object == self.layer_surface and ev.opcode == wayland.op.layer_surface_ev_closed) {
            // Compositor unmapped us (e.g. output unplugged). Objects are
            // ours to destroy; next show() recreates from .idle.
            self.hide();
            return;
        }
        for (&self.buffers) |*b| {
            if (ev.object == b.id and ev.opcode == wayland.op.buffer_ev_release) b.busy = false;
        }
    }
};
```

- [ ] **Step 2: Compile + tests still green**

Run: `zig test src/osd_linux.zig`
Expected: `All 4 tests passed.` (Lifecycle is verified live in Task 8; there is no Wayland server to unit-test against.)

- [ ] **Step 3: Commit**

```bash
git add src/osd_linux.zig
git commit -m "Add layer-shell OSD surface lifecycle"
```

---

## Task 6: `tray_linux.zig` — event-loop integration + enable layer polling

**Files:**
- Modify: `src/tray_linux.zig` (imports, `App`, `run` loop at :208-235, `pollThread` at :238-240, test block at :847-851)
- Modify: `src/tray_common.zig:64-67` and `:307-310` (stale comments only)

**Interfaces:**
- Consumes: `osd_linux.Osd` (Task 5), `osd_linux.osd_duration_ms`, `layer.displayNumber` (`src/layer.zig:39`), `State.layer_change`/`State.osd_enabled` (`src/tray_common.zig:63-67`).
- Produces: `App.osd: ?osd_linux.Osd`, `App.osd_hide_at: ?i64`, `fn nowMs() i64` — consumed by Task 7's menu handler.

- [ ] **Step 1: Imports, App fields, monotonic clock**

Top of `tray_linux.zig` (after the `dbus` import at :10):

```zig
const layer = @import("layer.zig");
const osd_linux = @import("osd_linux.zig");
```

Update the file doc comment (`:1-3`): drop "No layer overlay and no notifications this step."

`App` struct (after `pending_notify_serial` at :135):

```zig
    // Layer OSD. Null when Wayland/layer-shell is unavailable (then the menu
    // item renders disabled and the poll thread's layer read is skipped via
    // state.osd_enabled=false).
    osd: ?osd_linux.Osd = null,
    osd_hide_at: ?i64 = null, // monotonic ms deadline; replaces Win32 SetTimer
```

Add near `wake` (:242):

```zig
fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, std.time.ns_per_ms);
}
```

- [ ] **Step 2: Init the OSD in `run`**

After `tryRegister(&app);` (:206):

```zig
    // Layer OSD (Wayland layer-shell). Any failure — no Wayland socket, no
    // zwlr_layer_shell_v1 (GNOME) — leaves osd null: tray runs as before.
    app.osd = osd_linux.Osd.init(gpa, init.environ_map) catch null;
    defer if (app.osd) |*o| o.deinit();
    if (app.osd == null) app.state.osd_enabled.store(false, .release);
```

- [ ] **Step 3: Extend the poll loop**

Replace the loop body at :208-235 with (changes marked):

```zig
    var fds = [_]std.posix.pollfd{
        // Always read app.conn.fd() fresh — reconnect() swaps the connection.
        .{ .fd = app.conn.fd(), .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = app.event_fd, .events = std.posix.POLL.IN, .revents = 0 },
        // Wayland socket; -1 (ignored by poll) when the OSD is unavailable.
        .{ .fd = -1, .events = std.posix.POLL.IN, .revents = 0 },
    };
    while (!app.state.stop.load(.acquire)) {
        fds[0].fd = app.conn.fd();
        fds[2].fd = if (app.osd) |*o| o.fd() else -1;

        // Wake early when an OSD hide deadline is pending.
        var timeout: i32 = 1000;
        if (app.osd_hide_at) |at| {
            const left = at - nowMs();
            if (left <= 0) {
                if (app.osd) |*o| o.hide();
                app.osd_hide_at = null;
            } else {
                timeout = @intCast(@min(left, 1000));
            }
        }
        _ = std.posix.poll(&fds, timeout) catch break;

        if (fds[1].revents & std.posix.POLL.IN != 0) {
            var drain: u64 = 0;
            _ = linux.read(app.event_fd, std.mem.asBytes(&drain), 8);
            rebuildAndNotify(&app);
            drainLayerChanges(&app);
        }
        if (fds[0].revents & std.posix.POLL.IN != 0) {
            const msg = app.conn.readMessage() catch {
                reconnect(&app);
                continue;
            };
            dispatch(&app, msg) catch {};
        }
        if (fds[2].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
            if (app.osd) |*o| o.handleReadable();
        }
        // Retry registration only when the watcher is (re)available; the
        // NameOwnerChanged handler drives re-registration, so a bounded retry
        // here just covers the very first startup before waybar is up.
        if (!app.item_registered and fds[0].revents == 0 and fds[1].revents == 0) {
            tryRegister(&app);
        }
    }
```

Add below `wake` — a direct port of the Windows `drainLayerChanges` (`tray_windows.zig:633-638`) plus the deadline re-arm that Windows does with KillTimer+SetTimer:

```zig
/// Port of the Windows drainLayerChanges: consume the poll thread's pending
/// layer change and (re)show the OSD, re-arming the hide deadline.
fn drainLayerChanges(app: *App) void {
    const layer_idx = app.state.layer_change.swap(-1, .acq_rel);
    if (layer_idx < 0) return;
    if (!app.state.osd_enabled.load(.acquire)) return;
    if (app.osd) |*o| {
        o.show(layer.displayNumber(@intCast(layer_idx)));
        app.osd_hide_at = nowMs() + osd_linux.osd_duration_ms;
    }
}
```

- [ ] **Step 4: Enable the layer read in the poll thread**

`pollThread` (:238-240): change the final comptime arg `false` → `true`:

```zig
fn pollThread(app: *App) void {
    tray_common.runPollLoop(App, app, app.io, app.gpa, app.state, wake, true);
}
```

Fix the two stale comments: `tray_common.zig:64-67` (`osd_enabled` doc — now toggled from the tray menu on both platforms; skipped at runtime when Wayland/layer-shell is unavailable) and `tray_common.zig:307-310` (drop "the layer read is compiled out entirely (Linux, step 1)").

- [ ] **Step 5: Register new test files**

Test block (:847-851):

```zig
test {
    // Pull in the D-Bus + shared planner + Wayland/OSD unit tests for
    // `zig build test-tray`.
    _ = @import("dbus.zig");
    _ = @import("tray_common.zig");
    _ = @import("wayland.zig");
    _ = @import("osd_linux.zig");
}
```

- [ ] **Step 6: Build + test both platforms**

Run: `zig build test-tray`
Expected: all tests pass (previous suites + 5 wayland + 4 osd).

Run: `zig build && zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSmall`
Expected: both build clean (Windows untouched — new files are imported only from `tray_linux.zig`).

- [ ] **Step 7: Commit**

```bash
git add src/tray_linux.zig src/tray_common.zig
git commit -m "Wire layer OSD into the Linux tray event loop"
```

---

## Task 7: "Show layer overlay" menu toggle

**Files:**
- Modify: `src/tray_linux.zig` (`MenuId` :640-649, `MenuItem` :681-686, `buildMenuItems` :688-705, `writeMenuNode` :735-761, `menuGetGroupProperties` :769-812, `menuEvent` :820-842, variant writers :600-615)

**Interfaces:**
- Consumes: `App.osd`, `App.osd_hide_at`, `State.osd_enabled`, `drainLayerChanges` deadline logic (Task 6).
- Produces: dbusmenu checkmark item behavior-matching Windows `ID_OSD_TOGGLE` (`tray_windows.zig:484-496`).

- [ ] **Step 1: Menu model**

`MenuId` — insert before `quit`, renumber:

```zig
const MenuId = enum(i32) {
    root = 0,
    status = 1,
    left = 2,
    right = 3,
    sep = 4,
    refresh = 5,
    toggle = 6,
    osd = 7,
    quit = 8,
};
```

`MenuItem` — add a checkmark field:

```zig
const MenuItem = struct {
    id: MenuId,
    label: []const u8,
    enabled: bool,
    separator: bool = false,
    /// Non-null renders a dbusmenu checkmark ("toggle-type"/"toggle-state").
    checked: ?bool = null,
};
```

`buildMenuItems` — return `[8]MenuItem`; insert between toggle and quit:

```zig
        .{ .id = .osd, .label = "Show layer overlay", .enabled = app.osd != null, .checked = app.state.osd_enabled.load(.acquire) },
```

(Also update the return type in the signature and the doc comment.)

- [ ] **Step 2: Emit checkmark properties**

Add an `i32` variant writer next to `vU32` (:608-611):

```zig
fn vI32(w: *dbus.Writer, v: i32) !void {
    try w.signature("i");
    try w.int32(v);
}
```

In `writeMenuNode` (:741-755), after the `visible` prop inside the non-separator branch:

```zig
        if (it.checked) |on| {
            try w.beginStruct();
            try w.string("toggle-type");
            try vStr(w, "checkmark");
            try w.beginStruct();
            try w.string("toggle-state");
            try vI32(w, if (on) 1 else 0);
        }
```

Apply the identical block in `menuGetGroupProperties` (:796-806, same prop-writing shape, `&w` receiver).

- [ ] **Step 3: Handle the click — port of `tray_windows.zig:484-496`**

In `menuEvent`'s switch (:826-839), add before `else`:

```zig
            .osd => {
                const enabled = !app.state.osd_enabled.load(.acquire);
                app.state.osd_enabled.store(enabled, .release);
                if (!enabled) {
                    app.state.layer_change.store(-1, .release);
                    if (app.osd) |*o| o.hide();
                    app.osd_hide_at = null;
                }
                // Refresh the checkmark. menuEvent runs on the main thread,
                // which owns the Wayland socket — hide() here is safe.
                app.menu_revision += 1;
                emitLayoutUpdated(app) catch {};
            },
```

- [ ] **Step 4: Fix the header-test expectation if needed, run tests**

The `[7]MenuItem` → `[8]MenuItem` change touches `buildMenuItems` callers and the test at :885-900 (it indexes `items[0]` only — should pass unchanged, but the `App` in that test now needs nothing extra since `osd` defaults to null).

Run: `zig build test-tray`
Expected: all pass.

Run: `zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSmall`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add src/tray_linux.zig
git commit -m "Add layer-overlay menu toggle with dbusmenu checkmark"
```

---

## Task 8: README + live verification on Hyprland

**Files:**
- Modify: `README.md` (lines ~13-14 say the Linux port lacks the overlay — update; mention the `dygmate-osd` layer-shell namespace for Hyprland `layerrule`)

**Interfaces:** none (docs + manual QA).

- [ ] **Step 1: Update README**

Replace the "no overlay on Linux" caveat with: Linux (Wayland) shows the same "Layer N" overlay via `zwlr_layer_shell_v1`; requires a compositor supporting wlr-layer-shell (Hyprland, Sway, KDE — not GNOME); the surface uses layer-shell namespace `dygmate-osd`, so Hyprland users can style it with e.g. `layerrule = noanim, dygmate-osd`; toggled from the tray menu ("Show layer overlay").

- [ ] **Step 2: Live verification (Hyprland, keyboard connected)**

Run: `zig build && ./zig-out/bin/dygmate-tray` (or the `run-tray` step if defined)

Checklist — each must pass:
1. Hold/press a layer key → "Layer N" appears bottom-center, ~124px above the bottom edge; disappears ~900ms after the last change.
2. Cycle layers rapidly → text updates in place, no flicker; no protocol errors (`hyprctl` logs / `journalctl --user -f` show nothing from dygmate; optionally compare with `WAYLAND_DEBUG=1` on a scratch run).
3. While the OSD is visible, click where it sits → the click lands on the window underneath (input region empty).
4. `hyprctl layers` while visible → shows namespace `dygmate-osd` on the overlay layer.
5. Tray menu → "Show layer overlay" shows a checkmark; toggling off hides a visible OSD immediately and stops popups; toggling on restores; checkmark tracks state.
6. Battery tray behavior unchanged throughout (icon, tooltip, refresh, disconnect/reconnect, quit).
7. `env -u WAYLAND_DISPLAY ./zig-out/bin/dygmate-tray` → tray runs, battery works, "Show layer overlay" is disabled/grayed; no crash. (SNI still works because D-Bus is separate.)
8. With waybar docked at the bottom → the OSD sits 124px above waybar's exclusive zone, not overlapping it.

- [ ] **Step 3: Full test + cross-build sweep**

Run: `zig build test-tray && zig build release`
Expected: tests pass; `zig-out/windows/` and `zig-out/linux/` binaries produced.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "Document the Linux layer overlay"
```

---

## Risks / gotchas (ranked — keep in mind while executing)

1. **ack_configure before first attach** — fatal protocol error if reversed; the `.waiting_configure` state exists for this (Task 5 step-machine).
2. **`wl_registry.bind` untyped new_id** — string+version+id, unit-tested in Task 3.
3. **SCM_RIGHTS cmsg layout by hand** — a wrong `controllen`/alignment silently yields EBADF at `create_pool`; verify live early (Task 8 item 1 exercises it; if the OSD never appears, strace the `sendmsg`).
4. **Premultiplied alpha** — forgetting it produces a washed-out halo; Task 4's center-pixel test pins the premultiplied values.
5. **Buffer reuse while busy** — tearing; double buffering + `release` tracking (Task 5).
6. **size-includes-header / string-includes-NUL** — off-by-4 desyncs the stream; Task 1's peel/string tests pin both.
7. **Partial recv** — events split across reads; the accumulator in `dispatch` handles it (unlike dbus.zig's blocking readExact, the Wayland fd is non-blocking).
8. **Zig 0.16 raw-syscall signatures** (`msghdr_const`, `sockaddr.un`, `memfd_create`, `clock_gettime`) — the plan's code is the contract, not gospel; adjust field names against `lib/std/os/linux.zig` as needed.
