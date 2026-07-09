# Linux tray support — design

Date: 2026-07-09
Status: approved
Step 1 of 3 (tray only; overlay = step 2, notifications = step 3)

## Goal

Port the dygmate tray app to Linux alongside Windows. Linux gets a
StatusNotifierItem (SNI) tray icon with a context menu matching the Windows
implementation (minus overlay toggle and notifications). One build tree
produces both a Windows `.exe` and a Linux binary.

## Scope

In scope:

- SNI tray icon over D-Bus, Wayland-oriented (waybar is the primary target).
- Context menu: status header, per-side battery levels, Refresh,
  Disconnect/Reconnect, Quit.
- Battery-percentage icon rendered from embedded bitmap digits.
- Cross-compilation: `zig build release` produces Windows + Linux binaries.

Out of scope (explicitly):

- Layer overlay (step 2).
- Desktop notifications / low-battery balloons on Linux (step 3).
- Legacy X11 XEmbed tray protocol — Wayland only.
- Overlay toggle menu item on Linux.

## Constraints

- Zero C dependencies on Linux: raw D-Bus wire protocol in Zig, pure-Zig
  unix socket, fully static binary. Matches the project ethos (the Windows
  tray hand-writes Win32 externs; ~2.4 MB memory footprint).
- Windows behavior unchanged.

## Architecture

### File layout

```
src/
  tray_windows.zig   # renamed from tray.zig; mostly unchanged; imports tray_common
  tray_linux.zig     # new: main loop, SNI item, dbusmenu, icon pixmap
  tray_common.zig    # new: State struct, poll thread loop, fmt helpers,
                     # color palette, thresholds
  dbus.zig           # new: minimal D-Bus client
```

- `build.zig` picks the tray root module per target: `.windows` builds
  `tray_windows.zig` (subsystem `.Windows`, links user32/shell32/gdi32),
  `.linux` builds `tray_linux.zig` (no system libraries). No comptime
  dispatcher file; the build system does the split.
- The poll thread moves to `tray_common.zig`, parameterized by comptime
  platform hooks: a `wake()` hook notifies the UI loop of new readings
  (Windows: `PostMessageW`; Linux: eventfd write). State struct, mutex, and
  atomics are shared and identical to today.
- Notification and OSD logic stays in `tray_windows.zig` until steps 2–3.
- New build step `release`: cross-builds `dygmate-tray.exe`
  (x86_64-windows) + `dygmate-tray` (x86_64-linux) + both CLI binaries with
  ReleaseSmall in one command.

### D-Bus client (`src/dbus.zig`)

Minimal client implementing only what SNI + dbusmenu need:

- **Connect:** parse `$DBUS_SESSION_BUS_ADDRESS` (`unix:path=...` form),
  connect a `std.net` unix stream socket.
- **Auth:** `AUTH EXTERNAL <hex-encoded-uid>` handshake, then `BEGIN`. No
  unix-fd negotiation.
- **Wire format:** marshal/unmarshal for the needed type subset:
  `y b n q i u s o g v`, arrays, structs, dict entries (`a{sv}`). This
  covers the SNI pixmap `a(iiay)`, tooltip `(sa(iiay)ss)`, and the
  recursive dbusmenu layout `(ia{sv}av)`.
- **Operations:** `Hello`, `RequestName`, outgoing method calls with reply
  matching by serial, signal emission, dispatch of incoming method calls to
  registered handlers, `AddMatch` (for `NameOwnerChanged`).
- Marshal/unmarshal is unit-testable against known byte fixtures.

### Linux tray (`src/tray_linux.zig`)

- **Main loop:** `poll()` on two fds: the D-Bus socket and an eventfd. The
  shared poll thread writes the eventfd on every new reading; the main loop
  then rebuilds icon/tooltip/menu and emits `NewIcon`, `NewToolTip`, and
  dbusmenu `LayoutUpdated` (revision incremented).
- **SNI item:** register via
  `org.kde.StatusNotifierWatcher.RegisterStatusNotifierItem`. Properties:
  `Category=Hardware`, `Id=dygmate`, `Status=Active`, `IconPixmap` (22x22
  ARGB32, big-endian), `ToolTip`, `Menu=/MenuBar`. `Activate` (left-click)
  triggers a battery refresh, mirroring the Windows double-click.
- **Menu (`com.canonical.dbusmenu` at `/MenuBar`):** items in order:
  1. Status header — "Connected" / "Not connected" / "Paused (port free
     for Bazecor)" — `enabled=false`
  2. "Left: {d}% (Status)" — `enabled=false`
  3. "Right: {d}% (Status)" — `enabled=false`
  4. separator
  5. "Refresh battery now"
  6. "Disconnect (release port for Bazecor)" / "Reconnect" (label swaps
     with paused state)
  7. "Quit"

  Served methods: `GetLayout`, `GetGroupProperties`, `Event` (react to
  `clicked`), `AboutToShow`. Labels reuse the shared formatting helpers
  (`fmtMenuSide` etc.) from `tray_common.zig`.
- **Icon:** embedded 5x7 bitmap glyphs (`0`–`9`, `-`) blitted onto a
  status-colored background in an ARGB buffer. Same palette as Windows
  (green >= 50%, amber >= 20%, red < 20%, blue charging, gray
  offline/paused) and same "lower of the two sides" display logic,
  including last-known-good per-side snapshots.
- **Watcher resilience:** if no `org.kde.StatusNotifierWatcher` is on the
  bus at startup, retry with backoff (the bar may start later). Watch
  `NameOwnerChanged` for the watcher name and re-register when it gains a
  new owner (waybar restart). If the D-Bus socket dies, reconnect and
  re-register in a loop.
- **Single instance:** `flock` on `$XDG_RUNTIME_DIR/dygmate-tray.lock`
  (fallback `/tmp`); exit silently if already held. Mirrors the Windows
  named-mutex singleton.
- **No notifications on Linux this step:** the low-battery latch logic
  stays Windows-only until step 3.

## Data flow

Unchanged from Windows in shape: a background poll thread owns the serial
connection and runs discover -> connect -> poll; shared `State` guarded by
mutex/atomics; the UI loop is woken per reading (eventfd instead of
`PostMessageW`) and re-renders icon, tooltip, and menu labels.

## Error handling

- No session bus address / connect failure: log to stderr, retry with
  backoff.
- No watcher: retry loop, keep polling serial meanwhile.
- Malformed or unexpected incoming D-Bus messages: skip, don't crash.
- Serial errors: same rescan behavior as today (shared poll loop).

## Testing

- Unit tests: D-Bus marshal/unmarshal round-trips against byte fixtures,
  auth line formatting, icon glyph blitting.
- Manual verification: run under waybar on Hyprland; `busctl --user
  introspect` the item; kill and restart waybar and confirm re-register;
  `zig build release` produces both binaries; Windows exe cross-builds
  cleanly.
