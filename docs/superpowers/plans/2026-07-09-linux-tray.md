# Linux Tray Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give dygmate a Linux system-tray battery indicator (StatusNotifierItem over D-Bus) matching the Windows tray's menu and icon, with one build tree producing both a Windows `.exe` and a Linux binary.

**Architecture:** Split the current Windows-only `src/tray.zig` into `tray_windows.zig` (unchanged behavior) plus a shared `tray_common.zig` (State, poll thread, formatting, palette, thresholds). Add a pure-Zig minimal D-Bus client (`src/dbus.zig`) and a Linux tray (`src/tray_linux.zig`) that speaks StatusNotifierItem + com.canonical.dbusmenu. `build.zig` picks the tray root module per target and gains a `release` step that cross-builds both platforms.

**Tech Stack:** Zig 0.16.0 (the new `std.Io` async std: `std.Io.net.UnixAddress`, `std.Io.File`, `std.process.Init`), raw D-Bus wire protocol over a unix stream socket, `std.posix.poll` + Linux `eventfd` for the UI event loop. No C libraries on Linux.

## Global Constraints

- Zig 0.16.0 exactly (`minimum_zig_version = "0.16.0"`). Uses the `std.Io`-based std: sockets via `std.Io.net`, not `std.net`; `std.posix.socket`/`connect` do NOT exist here.
- Zero C dependencies on Linux. No libdbus, no GTK, no libappindicator. Fully static binary. Raw D-Bus wire protocol hand-written in Zig (mirrors how `tray_windows.zig` hand-writes Win32 externs).
- Wayland only. No X11 / XEmbed fallback.
- Windows tray behavior must remain byte-for-byte identical in feature terms — this is a refactor-and-add, not a rewrite.
- No desktop notifications and no layer overlay on Linux this step (steps 2 and 3). The low-battery latch logic stays Windows-only.
- Go coding preferences in CLAUDE.md do NOT apply — this is Zig. Follow the existing Zig style in the repo (doc comments with `//!` for files, `//` for items; `const`/`var` blocks as the existing code uses them).
- Icon: 22×22 ARGB32, big-endian byte order (ARGB, network order) as SNI `IconPixmap` requires.
- Menu path is `/MenuBar`; SNI object path is `/StatusNotifierItem`.
- Status color palette (shared, identical to Windows): green `rgb(46,160,67)` when level >= 50; amber `rgb(200,140,0)` when 20 <= level < 50; red `rgb(220,50,47)` when level < 20; blue `rgb(41,128,185)` when charging; gray `rgb(110,110,110)` when offline/paused/no reading. Icon shows the LOWER of the two sides' last-known levels; `--` before either side has ever reported.

---

## File Structure

- `src/tray_common.zig` (new) — platform-agnostic: `State` struct, the poll-thread loop parameterized by a `wake` callback, formatting helpers (`fmtMenuSide`, `fmtKnownSide`, `fmtSide`), status→color mapping, last-known-good snapshot merge, thresholds/intervals, `LastKnown` helper.
- `src/tray_windows.zig` (new; was `tray.zig`) — all Win32 code. Imports `tray_common` for State/formatting/palette so the logic is not duplicated. OSD + balloon notifications stay here.
- `src/dbus.zig` (new) — minimal D-Bus client: address parse, EXTERNAL auth, message marshal/unmarshal, a `Connection` with method-call/reply/signal/incoming-dispatch.
- `src/dbus_types.zig` (new, optional split if `dbus.zig` grows past ~600 lines) — the type-code/alignment tables and `Signature` iterator. Start folded into `dbus.zig`; split only if it grows unwieldy.
- `src/tray_linux.zig` (new) — Linux tray: icon pixmap rendering (embedded glyphs), SNI item + properties, dbusmenu server, eventfd-driven main loop, watcher-resilience/reconnect, single-instance lock.
- `build.zig` (modify) — per-target tray root selection; `release` step.
- `README.md` (modify) — drop "Windows only", document the Linux binary and `zig build release`.

---

## Task 1: Extract `tray_common.zig`, rename `tray.zig` → `tray_windows.zig`, keep Windows building

**Files:**
- Create: `src/tray_common.zig`
- Create: `src/tray_windows.zig` (moved content of `src/tray.zig`)
- Delete: `src/tray.zig`
- Modify: `build.zig` (point the Windows tray at `src/tray_windows.zig`)

**Interfaces:**
- Produces (consumed by Tasks 6–7 and by `tray_windows.zig`):
  - `pub const Status` re-exported path: keep using `battery.Status` directly; do NOT re-declare.
  - `pub const State = struct { … }` — moved verbatim from `tray_windows.zig`, minus the Windows-only `notified_low` comment wording (keep the field; it's harmless on Linux and used only by Windows).
  - `pub const low_threshold: u8 = 20;`
  - `pub const poll_interval_ms: u64 = 5 * 1000;`
  - `pub const layer_poll_interval_ms: u64 = 250;`
  - `pub const col = struct { pub const green/amber/red/blue/gray/text: Rgb }` where `pub const Rgb = struct { r: u8, g: u8, b: u8 };`. (Windows converts to its `COLORREF` 0x00BBGGRR; Linux converts to ARGB. Keep the palette platform-neutral as `Rgb`.)
  - `pub fn iconColor(live: bool, level: u8, status: battery.Status) Rgb` — the exact branch ladder currently inline in `updateTray` (charging→blue, >=50→green, >=low→amber, else red; gray when `!live`).
  - `pub fn fmtMenuSide(buf: []u8, s: battery.SideReading) []const u8`
  - `pub fn fmtKnownSide(buf: []u8, s: battery.SideReading) []const u8`
  - `pub fn fmtSide(buf: []u8, s: battery.SideReading) []const u8`
  - `pub const LastKnown = struct { left: battery.SideReading = .{ .level = null, .status = .unknown }, right: battery.SideReading = .{ .level = null, .status = .unknown }, pub fn merge(self: *LastKnown, r: battery.Reading) void, pub fn display(self: LastKnown) struct { level: ?u8, status: battery.Status } };` — `merge` performs the per-field last-known update currently inline in `updateTray` (only overwrite `level` when non-null, only overwrite `status` when not `.unknown`); `display` returns the lower-of-two-sides level+status.
  - `pub fn runPollLoop(comptime Ctx: type, ctx: *Ctx, io: std.Io, gpa: std.mem.Allocator, state: *State, comptime wake: fn (*Ctx) void, comptime osd_enabled: bool) void` — the discover→connect→poll loop from `tray_windows.zig` `pollLoop`, with `PostMessageW(...)` replaced by `wake(ctx)`. Keep OSD/layer reads behind `if (osd_enabled)` so Windows keeps them and Linux (passing `false`) compiles the layer code out.

- [ ] **Step 1: Move the file**

```bash
git mv src/tray.zig src/tray_windows.zig
```

- [ ] **Step 2: Point build.zig at the new name and confirm Windows still cross-builds**

In `build.zig`, change the tray `root_source_file` from `b.path("src/tray.zig")` to `b.path("src/tray_windows.zig")`. Then:

Run: `zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSmall`
Expected: builds `dygmate.exe` and `dygmate-tray.exe` with no errors. (This confirms the rename alone didn't break anything before refactoring.)

- [ ] **Step 3: Create `tray_common.zig` with the shared surface**

Create `src/tray_common.zig`. Move `State`, `low_threshold`, `poll_interval_ms`, `layer_poll_interval_ms` out of `tray_windows.zig` into it. Add the `Rgb` palette, `iconColor`, `LastKnown`, and the three `fmt*` helpers (move `fmtMenuSide`/`fmtKnownSide`/`fmtSide` verbatim; they have no Win32 dependency). Add `runPollLoop` as described in Interfaces, lifting the body of `pollLoop`/`waitForNextPoll`/`sleepMs`/`setConnected`/`resetLayerState` (these are all Win32-free except the `PostMessageW` wake, which becomes the `wake` callback).

File header:

```zig
//! Platform-agnostic tray state, polling loop, formatting, and color palette.
//! Shared by tray_windows.zig and tray_linux.zig so the discover -> connect ->
//! poll logic and the display formatting live in exactly one place.

const std = @import("std");
const focus = @import("focus.zig");
const battery = @import("battery.zig");
const device = @import("device.zig");
const layer = @import("layer.zig");
```

`Rgb` and palette:

```zig
pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const palette = struct {
    pub const green = Rgb{ .r = 46, .g = 160, .b = 67 };
    pub const amber = Rgb{ .r = 200, .g = 140, .b = 0 };
    pub const red = Rgb{ .r = 220, .g = 50, .b = 47 };
    pub const blue = Rgb{ .r = 41, .g = 128, .b = 185 };
    pub const gray = Rgb{ .r = 110, .g = 110, .b = 110 };
    pub const text = Rgb{ .r = 255, .g = 255, .b = 255 };
};

pub const low_threshold: u8 = 20;

pub fn iconColor(live: bool, level: u8, status: battery.Status) Rgb {
    if (!live) return palette.gray;
    if (status == .charging) return palette.blue;
    if (level >= 50) return palette.green;
    if (level >= low_threshold) return palette.amber;
    return palette.red;
}
```

- [ ] **Step 4: Rewire `tray_windows.zig` to consume `tray_common.zig`**

In `tray_windows.zig`: `const common = @import("tray_common.zig");`. Delete the now-moved declarations. Replace `g_state: State` with `common.State`, `low_threshold` with `common.low_threshold`, the inline color ladder in `updateTray` with `common.iconColor(...)` (convert the returned `Rgb` to `COLORREF` via the existing `rgb()` helper), the per-side last-known merge with a `common.LastKnown` instance, and `fmtMenuSide`/`fmtKnownSide`/`fmtSide` calls with `common.fmtMenuSide` etc. Replace the body of `pollLoop` with a call to `common.runPollLoop(PollCtx, &ctx, io, gpa, &g_state, wakeUi, true)` where `fn wakeUi(ctx: *PollCtx) void { _ = PostMessageW(ctx.hwnd, WM_BATTERY_UPDATE, 0, 0); }`. Keep the `comptime { if (builtin.os.tag != .windows) @compileError(...) }` guard.

- [ ] **Step 5: Confirm Windows still cross-builds after the refactor**

Run: `zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSmall`
Expected: builds cleanly, no errors, no warnings.

- [ ] **Step 6: Confirm the CLI and tests still build/pass natively**

Run: `zig build test`
Expected: PASS (existing battery/device/focus/layer tests unchanged).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: split tray into tray_common + tray_windows"
```

---

## Task 2: `dbus.zig` — session bus address parse + EXTERNAL auth line

**Files:**
- Create: `src/dbus.zig`

**Interfaces:**
- Produces:
  - `pub fn parseUnixPath(addr: []const u8) ?[]const u8` — from a `DBUS_SESSION_BUS_ADDRESS` value, return the `path=` (or `abstract=`) value of the first `unix:` transport, else null. For `abstract=NAME`, return a slice whose first byte the caller must treat as NUL (return the raw name; the connect step prepends the NUL). Keep it simple: return the substring after `path=` up to `,` or end; a separate `pub fn parseUnixAbstract(addr) ?[]const u8` returns the `abstract=` value.
  - `pub fn authLine(buf: []u8, uid: u32) []const u8` — writes `AUTH EXTERNAL <hexuid>\r\n` into `buf` where `<hexuid>` is the ASCII-decimal uid, hex-encoded byte by byte (uid 1000 → decimal "1000" → hex of '1','0','0','0' → "31303030"). Returns the used slice.

- [ ] **Step 1: Write the failing tests**

```zig
const std = @import("std");
const dbus = @import("dbus.zig"); // when tested from a test root that imports it

test "parseUnixPath extracts the socket path" {
    try std.testing.expectEqualStrings(
        "/run/user/1000/bus",
        dbus.parseUnixPath("unix:path=/run/user/1000/bus").?,
    );
    try std.testing.expectEqualStrings(
        "/run/user/1000/bus",
        dbus.parseUnixPath("unix:path=/run/user/1000/bus,guid=abc123").?,
    );
    try std.testing.expect(dbus.parseUnixPath("tcp:host=localhost") == null);
}

test "authLine hex-encodes the decimal uid" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("AUTH EXTERNAL 31303030\r\n", dbus.authLine(&buf, 1000));
    try std.testing.expectEqualStrings("AUTH EXTERNAL 30\r\n", dbus.authLine(&buf, 0));
}
```

Put these `test` blocks at the bottom of `src/dbus.zig` itself (the repo tests each module via `test { _ = @import(...) }` in a root; add `_ = @import("dbus.zig");` to that root in Task-8 wiring, but the tests can already run via `zig test src/dbus.zig`).

- [ ] **Step 2: Run to verify they fail**

Run: `zig test src/dbus.zig`
Expected: FAIL — `parseUnixPath`/`authLine` not defined.

- [ ] **Step 3: Implement**

```zig
//! Minimal D-Bus client: session-bus connect, EXTERNAL auth, message
//! marshal/unmarshal, and a Connection for method calls, signals, and
//! serving incoming calls. Only the subset needed by StatusNotifierItem +
//! com.canonical.dbusmenu is implemented. Little-endian wire only ('l').

const std = @import("std");

pub fn parseUnixPath(addr: []const u8) ?[]const u8 {
    return fieldOf(addr, "unix:", "path=");
}

pub fn parseUnixAbstract(addr: []const u8) ?[]const u8 {
    return fieldOf(addr, "unix:", "abstract=");
}

fn fieldOf(addr: []const u8, transport: []const u8, key: []const u8) ?[]const u8 {
    // Address may list several transports separated by ';'. Take the first
    // 'unix:' one and pull the requested key out of its comma-separated params.
    var it = std.mem.splitScalar(u8, addr, ';');
    while (it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry, transport)) continue;
        const params = entry[transport.len..];
        var pit = std.mem.splitScalar(u8, params, ',');
        while (pit.next()) |p| {
            if (std.mem.startsWith(u8, p, key)) return p[key.len..];
        }
    }
    return null;
}

pub fn authLine(buf: []u8, uid: u32) []const u8 {
    var dec: [10]u8 = undefined;
    const d = std.fmt.bufPrint(&dec, "{d}", .{uid}) catch unreachable;
    var w = std.Io.Writer.fixed(buf);
    w.writeAll("AUTH EXTERNAL ") catch unreachable;
    for (d) |c| w.print("{x:0>2}", .{c}) catch unreachable;
    w.writeAll("\r\n") catch unreachable;
    return w.buffered();
}
```

(If `std.Io.Writer.fixed`/`.buffered()` differ in this std revision, fall back to manual index writes; the test pins the exact output so any equivalent implementation is acceptable.)

- [ ] **Step 4: Run to verify pass**

Run: `zig test src/dbus.zig`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/dbus.zig
git commit -m "feat(dbus): session bus address parse and EXTERNAL auth line"
```

---

## Task 3: `dbus.zig` — type-aware marshaller and unmarshaller

**Files:**
- Modify: `src/dbus.zig`

**Interfaces:**
- Produces:
  - `pub const Writer = struct { buf: *std.ArrayList(u8), … }` with alignment-aware appends:
    - `pub fn init(list: *std.ArrayList(u8)) Writer`
    - `pub fn byte(w: *Writer, v: u8) !void` (align 1)
    - `pub fn boolean(w: *Writer, v: bool) !void` (align 4, u32 0/1)
    - `pub fn uint16(w, v: u16) !void` / `int16` (align 2)
    - `pub fn uint32(w, v: u32) !void` / `int32` (align 4)
    - `pub fn string(w, s: []const u8) !void` (align 4; u32 length, bytes, NUL)
    - `pub fn objectPath(w, s: []const u8) !void` (same wire form as string)
    - `pub fn signature(w, s: []const u8) !void` (align 1; u8 length, bytes, NUL)
    - `pub fn pad(w, alignment: usize) !void`
    - `pub fn beginArray(w) !usize` / `pub fn endArray(w, len_pos: usize) !void` — writes a u32 length placeholder aligned to 4, records position, then after elements are written, back-patches the byte length of the array content. Caller must `w.pad(elem_align)` for the first element per spec (array length is followed by padding to the element's alignment, and that padding is NOT counted in the length).
    - `pub fn beginStruct(w) !void` (pad to 8) — dict-entry uses the same 8-alignment.
  - `pub const Reader = struct { data: []const u8, pos: usize, … }` with matching readers: `byte`, `boolean`, `uint32`, `string`, `objectPath`, `signature`, `readAlign(alignment)`, `arrayLen()` (reads u32, returns end position), and a `variant()` that reads a signature then dispatches. Reader must respect alignment identically.
  - `pub fn alignOf(type_code: u8) usize` — y/g/v→1, n/q→2, b/i/u/s/o→4, x/t/d/struct/dict→8.

**Testing note:** these are pure functions; test them by round-trip and by pinning known byte layouts. The canonical D-Bus alignment cases below are the spec — they catch the classic bugs (array length padding, struct 8-alignment).

- [ ] **Step 1: Write the failing tests**

```zig
test "marshal string is len32 + bytes + NUL" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    var w = dbus.Writer.init(&list, std.testing.allocator);
    try w.string("foo");
    // 03 00 00 00  'f' 'o' 'o'  00
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 0, 0, 'f', 'o', 'o', 0 }, list.items);
}

test "byte then uint32 inserts 3 pad bytes for 4-alignment" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    var w = dbus.Writer.init(&list, std.testing.allocator);
    try w.byte(0x11);
    try w.uint32(0x22334455);
    // 11  00 00 00  55 44 33 22
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0, 0, 0, 0x55, 0x44, 0x33, 0x22 }, list.items);
}

test "round-trip string through Reader" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    var w = dbus.Writer.init(&list, std.testing.allocator);
    try w.byte(0x11);
    try w.string("hello");
    var r = dbus.Reader{ .data = list.items, .pos = 0 };
    try std.testing.expectEqual(@as(u8, 0x11), try r.byte());
    try std.testing.expectEqualStrings("hello", try r.string());
}

test "array of bytes: length excludes trailing, content follows length" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    var w = dbus.Writer.init(&list, std.testing.allocator);
    const ap = try w.beginArray(1); // element alignment 1 (bytes)
    try w.byte(0xAA);
    try w.byte(0xBB);
    try w.endArray(ap);
    // len=2: 02 00 00 00 AA BB
    try std.testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0, 0xAA, 0xBB }, list.items);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `zig test src/dbus.zig`
Expected: FAIL — `Writer`/`Reader` not defined.

- [ ] **Step 3: Implement the marshaller/unmarshaller**

Implement `Writer` and `Reader`. Key rules (D-Bus spec §Marshaling): all integers little-endian (we always emit `'l'`); each type is preceded by padding to its alignment measured from the start of the message body (here, from the start of `list`); string/object-path = `u32` byte-length + bytes + trailing NUL (NUL not counted in length); signature = `u8` length + bytes + NUL; array = `u32` byte-length of the content (NOT counting the length field or the pad between length and first element) + pad to element alignment + elements; struct and dict-entry = pad to 8 then fields. `beginArray(elem_align)` writes an aligned `u32` zero placeholder, pads to `elem_align`, returns the placeholder position; `endArray` computes `list.items.len - (placeholder_pos + 4 + pad_after_len)` and back-patches. Use `std.mem.writeInt(u32, buf[pos..][0..4], v, .little)` for back-patching.

Signature of `Writer.init`: `pub fn init(list: *std.ArrayList(u8), gpa: std.mem.Allocator) Writer` (the list needs the allocator for `append`; store it).

- [ ] **Step 4: Run to verify pass**

Run: `zig test src/dbus.zig`
Expected: PASS (all four).

- [ ] **Step 5: Commit**

```bash
git add src/dbus.zig
git commit -m "feat(dbus): alignment-aware marshaller and unmarshaller"
```

---

## Task 4: `dbus.zig` — message framing, Connection, calls/replies/signals/dispatch

**Files:**
- Modify: `src/dbus.zig`

**Interfaces:**
- Produces:
  - `pub const MessageType = enum(u8) { method_call = 1, method_return = 2, error_reply = 3, signal = 4 };`
  - `pub const HeaderField = enum(u8) { path = 1, interface = 2, member = 3, error_name = 4, reply_serial = 5, destination = 6, sender = 7, signature = 8, unix_fds = 9 };`
  - `pub const Message = struct { type: MessageType, flags: u8, serial: u32, reply_serial: ?u32, path: ?[]const u8, interface: ?[]const u8, member: ?[]const u8, error_name: ?[]const u8, destination: ?[]const u8, sender: ?[]const u8, signature: ?[]const u8, body: []const u8 };` — `body` is a slice into a Connection-owned read buffer; valid until the next read.
  - `pub const Connection = struct { … }` with:
    - `pub fn connectSession(io: std.Io, gpa: std.mem.Allocator, environ: *std.process.Environ.Map, uid: u32) !Connection` — reads `DBUS_SESSION_BUS_ADDRESS`, parses path, `UnixAddress.connect`, does the NUL byte + `authLine` + read `OK` + `BEGIN` handshake, then calls `Hello` and stores the assigned unique name.
    - `pub fn fd(c: *Connection) std.posix.fd_t` — returns `c.stream.socket.handle` for `poll`.
    - `pub fn call(c: *Connection, gpa, dest, path, iface, member, sig: ?[]const u8, body: []const u8) !u32` — sends a method_call, returns the serial. Marshals the fixed header (`'l'`, type, flags=0, version=1, body_len, serial) + the `a(yv)` header-field array (path, destination, interface, member, and signature if `sig != null`), pads to 8, appends body. Increments and returns the serial.
    - `pub fn emitSignal(c, gpa, path, iface, member, sig: ?[]const u8, body: []const u8) !void` — like `call` but type=signal, no destination required.
    - `pub fn reply(c, gpa, to: Message, sig: ?[]const u8, body: []const u8) !void` — method_return with `reply_serial = to.serial`, `destination = to.sender`.
    - `pub fn replyError(c, gpa, to: Message, name: []const u8, msg: []const u8) !void`
    - `pub fn readMessage(c: *Connection) !Message` — blocking read of one full message into `c.read_buf`, parse fixed header + header fields, return `Message`. Reads exactly the 16-byte fixed prefix, then the header-fields array length, then the rest, honoring 8-byte body alignment.
    - `pub fn nextSerial(c) u32`

- [ ] **Step 1: Write the failing test (header round-trip through the framing)**

```zig
test "frame then parse a method_call round-trips the header fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try dbus.buildMethodCall(a, 7, "org.example", "/foo", "org.example.Iface", "Ping", null, &.{});
    var msg = try dbus.parseMessage(bytes);
    try std.testing.expectEqual(dbus.MessageType.method_call, msg.type);
    try std.testing.expectEqual(@as(u32, 7), msg.serial);
    try std.testing.expectEqualStrings("/foo", msg.path.?);
    try std.testing.expectEqualStrings("org.example.Iface", msg.interface.?);
    try std.testing.expectEqualStrings("Ping", msg.member.?);
    try std.testing.expectEqualStrings("org.example", msg.destination.?);
}
```

Expose two pure helpers used by `call`/`readMessage` so framing is testable without a socket: `pub fn buildMethodCall(gpa, serial, dest, path, iface, member, sig: ?[]const u8, body: []const u8) ![]u8` and `pub fn parseMessage(bytes: []const u8) !Message`. `Connection.call` calls `buildMethodCall` then writes; `readMessage` reads bytes then calls `parseMessage`.

- [ ] **Step 2: Run to verify it fails**

Run: `zig test src/dbus.zig`
Expected: FAIL — `buildMethodCall`/`parseMessage` not defined.

- [ ] **Step 3: Implement framing + Connection**

Fixed header layout (12 bytes then the header-field array): `endianness: u8 = 'l'`, `type: u8`, `flags: u8`, `version: u8 = 1`, `body_length: u32`, `serial: u32`, then `a(yv)` header fields. The whole header (fixed + fields array) is padded to an 8-byte boundary; the body follows. Each header field is a struct `(yv)`: a `y` code then a variant `v` (signature `g` then value). Emit fields in a stable order: PATH(o), then for method_call DESTINATION(s), INTERFACE(s), MEMBER(s); for signals INTERFACE+MEMBER+PATH; for method_return REPLY_SERIAL(u)+DESTINATION(s); include SIGNATURE(g) last when `sig != null`. For `readMessage`: read the 16-byte prefix with a fixed read, extract `body_length` and the header-array length (the u32 at offset 12), compute total = align8(16 + header_array_len) + body_length, read the remainder, then `parseMessage`.

For the socket write use `stream.writer(io, &c.write_buf)` and `w.interface.writeAll(bytes)` then flush; for reads use `stream.reader(io, &c.read_buf)` and `r.interface.readSliceAll(dst)` (adjust to the exact `Io.Reader` method names in this std — `readSliceAll`/`readAll`; pin by compiling). The auth handshake writes/reads raw ASCII lines on the same stream before any D-Bus message.

- [ ] **Step 4: Run to verify pass**

Run: `zig test src/dbus.zig`
Expected: PASS.

- [ ] **Step 5: Integration smoke test against the real bus (manual, gated on a session bus)**

Add a throwaway `src/dbus_smoke.zig` with a `main` that `connectSession`s, calls `org.freedesktop.DBus.ListNames`, and prints the reply body length. Build and run only if `$DBUS_SESSION_BUS_ADDRESS` is set:

Run: `zig build-exe src/dbus_smoke.zig --dep … 2>/dev/null; ./dbus_smoke` (or a temporary build step)
Expected: connects, prints a non-zero reply. Then delete `src/dbus_smoke.zig` — do NOT commit it.

- [ ] **Step 6: Commit**

```bash
git add src/dbus.zig
git commit -m "feat(dbus): message framing and Connection (calls, signals, dispatch)"
```

---

## Task 5: `tray_linux.zig` — battery-percentage icon as ARGB32 pixmap

**Files:**
- Create: `src/tray_linux.zig` (start it here; later tasks extend it)

**Interfaces:**
- Produces:
  - `const icon_px: usize = 22;`
  - `fn glyph5x7(c: u8) [7]u8` — returns 7 rows of a 5-wide bitmap (bit 4 = leftmost) for `'0'..'9'` and `'-'`; unknown chars return blank rows.
  - `fn renderIcon(out: *[icon_px * icon_px * 4]u8, text: []const u8, color: tray_common.Rgb) void` — fills the buffer with `color` (opaque), then draws up to 3 glyphs centered, in white, ARGB32 big-endian byte order per pixel (`out[i]=A, out[i+1]=R, out[i+2]=G, out[i+3]=B`). Fully opaque: A=0xFF everywhere.

- [ ] **Step 1: Write the failing tests**

```zig
test "renderIcon fills background color at a corner pixel" {
    var buf: [22 * 22 * 4]u8 = undefined;
    const c = tray_common.Rgb{ .r = 46, .g = 160, .b = 67 };
    renderIcon(&buf, "50", c);
    // top-left pixel is background (glyphs are centered, never at 0,0)
    try std.testing.expectEqual(@as(u8, 0xFF), buf[0]); // A
    try std.testing.expectEqual(@as(u8, 46), buf[1]); // R
    try std.testing.expectEqual(@as(u8, 160), buf[2]); // G
    try std.testing.expectEqual(@as(u8, 67), buf[3]); // B
}

test "renderIcon draws at least one white (text) pixel for a digit" {
    var buf: [22 * 22 * 4]u8 = undefined;
    renderIcon(&buf, "8", tray_common.Rgb{ .r = 46, .g = 160, .b = 67 });
    var found_white = false;
    var i: usize = 0;
    while (i < buf.len) : (i += 4) {
        if (buf[i + 1] == 255 and buf[i + 2] == 255 and buf[i + 3] == 255) found_white = true;
    }
    try std.testing.expect(found_white);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `zig test src/tray_linux.zig`
Expected: FAIL — `renderIcon` not defined.

- [ ] **Step 3: Implement glyphs + renderIcon**

Header:

```zig
//! Linux system-tray battery indicator (StatusNotifierItem over D-Bus).
//! Wayland-oriented. Mirrors the Windows tray's menu and icon. No overlay
//! and no notifications this step. Linux only.

const std = @import("std");
const builtin = @import("builtin");
const tray_common = @import("tray_common.zig");
const battery = @import("battery.zig");
const dbus = @import("dbus.zig");

comptime {
    if (builtin.os.tag != .linux) @compileError("tray_linux.zig is Linux-only");
}
```

Embed an 11-entry 5×7 font (`0`–`9`, `-`). Each glyph is `[7]u8`, low 5 bits used. `renderIcon`: write background to every pixel (A,R,G,B), compute total glyph width = `n*5 + (n-1)*1` spacing (n = min(text.len,3)), left = `(22 - width)/2`, top = `(22 - 7)/2`, scale 1× (5×7 inside 22×22 reads fine; if too small, scale 2× and recenter — pick 2× so digits are legible: 2 glyphs at 2× = `2*10 + 2 = 22`, fits exactly). Choose 2× scaling; each set bit fills a 2×2 block in white.

- [ ] **Step 4: Run to verify pass**

Run: `zig test src/tray_linux.zig`
Expected: PASS (both).

- [ ] **Step 5: Eyeball the glyphs (manual, optional)**

Add a temporary test that writes the buffer as a PPM to `/tmp/icon.ppm` for "50"/"8"/"--"; open it to confirm the digits are readable. Delete the temp test before committing.

- [ ] **Step 6: Commit**

```bash
git add src/tray_linux.zig
git commit -m "feat(tray-linux): ARGB battery-percentage icon from embedded glyphs"
```

---

## Task 6: `tray_linux.zig` — SNI item, poll loop wiring, eventfd loop, watcher resilience, singleton

**Files:**
- Modify: `src/tray_linux.zig`
- Modify: `build.zig` (add the Linux tray executable — see Task 8 for the full build; a minimal add here lets this task build/run)

**Interfaces:**
- Consumes: `dbus.Connection` (Task 4), `tray_common.State`/`runPollLoop`/`LastKnown`/`iconColor` (Task 1), `renderIcon` (Task 5).
- Produces:
  - `pub fn main(init: std.process.Init) void`
  - `const App = struct { io, gpa, conn: dbus.Connection, state: *tray_common.State, event_fd: i32, last: tray_common.LastKnown, menu_revision: u32, item_registered: bool, … };`
  - `fn registerItem(app: *App) !void` — `RequestName` `org.kde.StatusNotifierItem-<pid>-1`, then call `org.kde.StatusNotifierWatcher.RegisterStatusNotifierItem` with our well-known/unique name.
  - `fn wake(app: *App) void` — writes 8 bytes to `event_fd` (called from the poll thread).
  - `fn rebuildAndNotify(app: *App) void` — merge reading into `last`, emit `NewIcon`, `NewToolTip` (and dbusmenu `LayoutUpdated` in Task 7).
  - property replies for `org.kde.StatusNotifierItem` `Get`/`GetAll` (Category, Id, Title, Status, IconPixmap, ToolTip, Menu, ItemIsMenu) and the `Activate` method.

- [ ] **Step 1: Single instance via flock**

```zig
fn acquireSingleton(runtime_dir: []const u8, gpa: std.mem.Allocator) ?i32 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/dygmate-tray.lock", .{runtime_dir}) catch return null;
    const fd = std.os.linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o600);
    const ifd: i32 = @intCast(fd);
    if (ifd < 0) return null;
    const rc = std.os.linux.flock(ifd, std.posix.LOCK.EX | std.posix.LOCK.NB);
    if (rc != 0) {
        _ = std.os.linux.close(ifd);
        return null;
    }
    return ifd;
}
```

`main`: resolve `XDG_RUNTIME_DIR` from `init.environ_map.get(...)` (fallback `/tmp`); if `acquireSingleton` returns null, `return` silently (another instance holds it). Leak the fd intentionally (freed on exit). Verify it compiles: `zig build-exe src/tray_linux.zig …` deferred to Step 6.

- [ ] **Step 2: eventfd + poll loop skeleton**

Create the eventfd: `const efd: i32 = @intCast(std.os.linux.eventfd(0, 0));`. Store in `App`. Spawn the poll thread: `std.Thread.spawn(.{}, pollThread, .{app})` where `pollThread` calls `tray_common.runPollLoop(App, app, app.io, app.gpa, app.state, wake, false)` (osd disabled on Linux). `wake` does `var v: u64 = 1; _ = std.os.linux.write(app.event_fd, std.mem.asBytes(&v), 8);`.

Main loop:

```zig
var fds = [_]std.posix.pollfd{
    .{ .fd = app.conn.fd(), .events = std.posix.POLL.IN, .revents = 0 },
    .{ .fd = app.event_fd, .events = std.posix.POLL.IN, .revents = 0 },
};
while (!app.state.stop.load(.acquire)) {
    _ = std.posix.poll(&fds, 1000) catch break;
    if (fds[1].revents & std.posix.POLL.IN != 0) {
        var drain: u64 = 0;
        _ = std.os.linux.read(app.event_fd, std.mem.asBytes(&drain), 8);
        rebuildAndNotify(app);
    }
    if (fds[0].revents & std.posix.POLL.IN != 0) {
        const msg = app.conn.readMessage() catch { reconnect(app); continue; };
        dispatch(app, msg);
    }
}
```

- [ ] **Step 3: SNI registration + properties**

Implement `registerItem`. Implement `dispatch` to handle incoming method calls on `org.freedesktop.DBus.Properties` (`Get`, `GetAll`) for interface `org.kde.StatusNotifierItem`, and the item's `Activate`/`SecondaryActivate`/`Scroll` methods. Property values:
  - `Category` (s) = "Hardware"
  - `Id` (s) = "dygmate"
  - `Title` (s) = "dygmate"
  - `Status` (s) = "Active"
  - `IconName` (s) = "" (we supply pixmap)
  - `IconPixmap` (a(iiay)) = one entry `(22, 22, <1936 bytes ARGB>)` from `renderIcon`
  - `ToolTip` ((sa(iiay)ss)) = ("", [], "<title line>", "<Left/Right detail>")
  - `Menu` (o) = "/MenuBar"
  - `ItemIsMenu` (b) = false
  `Activate` sets `app.state.refresh.store(true, .release)` and replies empty.

- [ ] **Step 4: rebuildAndNotify + NewIcon/NewToolTip signals**

`rebuildAndNotify`: lock `state.mutex`, snapshot `reading`/`connected`, unlock; read `paused` atomic; `app.last.merge(reading)` when live; recompute display level/status and tooltip strings (reuse `tray_common.fmtKnownSide`); then `emitSignal("/StatusNotifierItem", "org.kde.StatusNotifierItem", "NewIcon", null, &.{})` and `"NewToolTip"`. The next `Get IconPixmap`/`ToolTip` from the host returns the fresh values (store current display state on `App`).

- [ ] **Step 5: Watcher resilience + reconnect**

At startup, if `RegisterStatusNotifierItem` fails or the watcher name has no owner, retry with backoff (1s, capped) while the poll thread keeps running. `AddMatch` for `NameOwnerChanged` on `org.kde.StatusNotifierWatcher`; when a `NameOwnerChanged` signal arrives with a non-empty new owner for that name, call `registerItem` again. `reconnect(app)`: close the stream, `connectSession` again, re-`registerItem`; on failure sleep and retry.

- [ ] **Step 6: Build and run under a real bus (manual verification)**

Run: `zig build run-tray-linux` (build step added in Task 8; for now `zig build-exe` with the serial dep)
Expected: `busctl --user list | rg StatusNotifierItem` shows our name; the tray icon appears in waybar showing `--` then the battery number once the keyboard is polled; left-click triggers a refresh.

- [ ] **Step 7: Commit**

```bash
git add src/tray_linux.zig build.zig
git commit -m "feat(tray-linux): SNI item, eventfd loop, watcher resilience, singleton"
```

---

## Task 7: `tray_linux.zig` — com.canonical.dbusmenu server

**Files:**
- Modify: `src/tray_linux.zig`

**Interfaces:**
- Consumes: `App`, `dbus` framing, `tray_common.fmtMenuSide`.
- Produces:
  - `const MenuId = enum(i32) { root = 0, status = 1, left = 2, right = 3, sep = 4, refresh = 5, toggle = 6, quit = 7 };`
  - `fn menuGetLayout(app, msg) void` — serve `GetLayout(parentId, depth, props) -> (u32 revision, (ia{sv}av) layout)`.
  - `fn menuGetGroupProperties(app, msg) void`
  - `fn menuEvent(app, msg) void` — handle `Event(id, eventId, data, timestamp)`; on `clicked` for `refresh`→set refresh; `toggle`→flip `state.paused` (and set refresh on resume); `quit`→set `state.stop`, wake, and after the reply, tear down and exit the main loop.
  - `fn menuAboutToShow(app, msg) void` — reply `false` (no layout change needed just to show), then a fresh `GetLayout` will pull current labels; we bump revision on every battery update so hosts re-read.

- [ ] **Step 1: Build the layout item structure**

dbusmenu `GetLayout` returns `(u32 revision, item)` where `item` is `(i id, a{sv} props, av children)`. Root (id 0) has `children-display=submenu` implied; each leaf carries `label` (s), `enabled` (b), `visible` (b), and separators carry `type=separator` (s). Disabled items (status header, Left, Right) set `enabled=false`. Build the tree in this order: status header, left, right, separator, refresh, toggle (label swaps on `state.paused`), quit. Labels for status/left/right come from the current display snapshot on `App` (compute strings with `tray_common.fmtMenuSide` and the connection/paused state), matching the Windows menu wording exactly:
  - header: "Paused (port free for Bazecor)" / "Connected" / "Not connected"
  - "Left: {fmtMenuSide}" / "Right: {fmtMenuSide}"
  - "Refresh battery now"
  - "Disconnect (release port for Bazecor)" / "Reconnect"
  - "Quit"

- [ ] **Step 2: Serve the four methods in `dispatch`**

Extend `dispatch` (Task 6) so incoming calls to interface `com.canonical.dbusmenu` on path `/MenuBar` route to `menuGetLayout`/`menuGetGroupProperties`/`menuEvent`/`menuAboutToShow`. Also serve `org.freedesktop.DBus.Properties.GetAll` for `com.canonical.dbusmenu` (return `Version`=3 (u), `Status`="normal" (s), `TextDirection`="ltr" (s)).

- [ ] **Step 3: Bump revision + LayoutUpdated on battery updates**

In `rebuildAndNotify` (Task 6), also `app.menu_revision += 1;` and `emitSignal("/MenuBar", "com.canonical.dbusmenu", "LayoutUpdated", "ui", <revision, 0>)` so the host re-reads labels after a new reading.

- [ ] **Step 4: Manual verification under waybar**

Run the Linux tray under waybar/Hyprland.
Expected: right-click (or the bar's menu affordance) shows the 7-item menu; status header/Left/Right are non-clickable; "Refresh battery now" refreshes; "Disconnect"/"Reconnect" toggles the port (verify Bazecor can open the port while disconnected); "Quit" exits and the icon disappears. Restart waybar → icon re-registers.

- [ ] **Step 5: Commit**

```bash
git add src/tray_linux.zig
git commit -m "feat(tray-linux): com.canonical.dbusmenu server"
```

---

## Task 8: `build.zig` per-target tray routing + `release` step, README, module test wiring

**Files:**
- Modify: `build.zig`
- Modify: `README.md`
- Modify: test root (the `test` block in `src/main.zig` imports sibling modules) — add `_ = @import("dbus.zig");` so `zig build test` runs the dbus tests. The Linux/Windows tray modules are OS-guarded, so import them under a matching `if (builtin.os.tag == …)` inside the test, or add a separate `addTest` per platform in `build.zig`.

**Interfaces:**
- Produces: `zig build` builds the native tray + CLI; `zig build release` cross-builds `dygmate.exe`, `dygmate-tray.exe`, `dygmate` (linux), `dygmate-tray` (linux) in ReleaseSmall.

- [ ] **Step 1: Route the tray root per target**

Replace the Windows-only tray block in `build.zig` with a per-target selection:

```zig
const tray_root = switch (target.result.os.tag) {
    .windows => "src/tray_windows.zig",
    .linux => "src/tray_linux.zig",
    else => null,
};
if (tray_root) |root| {
    const tray = b.addExecutable(.{
        .name = "dygmate-tray",
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "serial", .module = serial_mod }},
        }),
    });
    if (target.result.os.tag == .windows) {
        tray.subsystem = .Windows;
        tray.root_module.linkSystemLibrary("user32", .{});
        tray.root_module.linkSystemLibrary("shell32", .{});
        tray.root_module.linkSystemLibrary("gdi32", .{});
    }
    b.installArtifact(tray);
    const run_tray = b.addRunArtifact(tray);
    run_tray.step.dependOn(b.getInstallStep());
    const name = if (target.result.os.tag == .windows) "run-tray" else "run-tray-linux";
    b.step(name, "Run dygmate-tray").dependOn(&run_tray.step);
}
```

- [ ] **Step 2: Add the `release` step**

Add a step that installs both platforms' binaries into `zig-out/<os>/`:

```zig
const release_step = b.step("release", "Cross-build Windows + Linux binaries (ReleaseSmall)");
const targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
};
for (targets) |q| {
    const rt = b.resolveTargetQuery(q);
    // build both the CLI and the tray for rt at ReleaseSmall, install into a
    // per-OS subdir via b.addInstallArtifact with a custom dest_dir.
    // (factor the exe/tray creation above into a helper fn addBinaries(b, rt, .ReleaseSmall, serial_mod, release_step))
}
```

Factor the CLI + tray creation into a local helper `fn addBinaries(b, target, optimize, serial_mod) struct { cli: *Step.Compile, tray: ?*Step.Compile }` to avoid duplicating the module setup between the default build and `release`. Install release artifacts with `b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "windows" } } })` etc.

- [ ] **Step 3: Verify both single-target builds**

Run: `zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSmall`
Expected: `dygmate.exe`, `dygmate-tray.exe` built.

Run: `zig build -Doptimize=ReleaseSmall`
Expected (on Linux host): `dygmate`, `dygmate-tray` built.

- [ ] **Step 4: Verify the release step**

Run: `zig build release`
Expected: `zig-out/windows/dygmate-tray.exe` and `zig-out/linux/dygmate-tray` both present.

Run: `file zig-out/linux/dygmate-tray`
Expected: `ELF 64-bit ... statically linked` (or with only the dynamic loader; no libdbus/libgtk).

Run: `ldd zig-out/linux/dygmate-tray`
Expected: `not a dynamic executable` or only linux-vdso/ld-linux — no libdbus-1, no libgtk.

- [ ] **Step 5: Run the full test suite**

Run: `zig build test`
Expected: PASS, including the new dbus marshaller/auth tests.

- [ ] **Step 6: Update README**

In `README.md`, remove "Currently Windows only. Linux support is coming." Add a short Linux section: the tray is a StatusNotifierItem (works in waybar and other SNI hosts), build with `zig build -Doptimize=ReleaseSmall`, run `dygmate-tray`. Document `zig build release` producing both platforms under `zig-out/{windows,linux}/`.

- [ ] **Step 7: Commit**

```bash
git add build.zig README.md src/main.zig
git commit -m "build: per-target tray routing, release step; docs: Linux tray"
```

---

## Self-Review

**Spec coverage:**
- SNI tray icon over D-Bus, Wayland — Tasks 4, 6. ✓
- Context menu (header, per-side, Refresh, Disconnect/Reconnect, Quit) — Task 7. ✓
- Battery-percentage icon from embedded digits — Task 5. ✓
- Cross-compile `zig build release` — Task 8. ✓
- Zero C deps / static binary — enforced by the pure-Zig `dbus.zig` and verified in Task 8 Step 4 (`ldd`). ✓
- Windows unchanged — Task 1 keeps Windows building at every step (Steps 2, 5). ✓
- No overlay / no notifications on Linux — `runPollLoop(..., osd_enabled=false)` (Task 6 Step 2); no balloon code ported. ✓
- Activate = refresh (like Windows double-click) — Task 6 Step 3. ✓
- Watcher resilience / reconnect — Task 6 Step 5. ✓
- Single instance — Task 6 Step 1. ✓
- Unit tests (marshal round-trip, auth line, icon glyphs) — Tasks 2, 3, 5. ✓
- Manual verification (waybar, busctl, restart, release) — Tasks 6, 7, 8. ✓

**Placeholder scan:** No "TBD"/"add error handling"-style gaps; each code step carries real code or exact protocol rules. The two intentionally hand-implemented-by-engineer spots (Task 4 framing body, Task 8 `addBinaries` helper) give exact layouts and signatures rather than finished bodies because the surrounding std method names must be pinned by compiling against Zig 0.16.0 — the tests/verification commands make correctness objective.

**Type consistency:** `tray_common.State`/`LastKnown`/`iconColor`/`fmt*` names match across Tasks 1, 6, 7. `dbus.Writer`/`Reader`/`Connection`/`Message`/`buildMethodCall`/`parseMessage` names match across Tasks 2–4 and 6–7. `renderIcon` signature matches between Task 5 and Task 6.

**Known API risk (call out for the implementer):** the `std.Io.Reader`/`Io.Writer` method names (`readSliceAll`, `writeAll`, `flush`, `buffered`) and `std.ArrayList` init form (`.empty` + explicit allocator on `append`/`deinit`) are from Zig 0.16.0's reworked std and must be confirmed by compiling; the tests pin the observable behavior so any equivalent API usage is acceptable.
