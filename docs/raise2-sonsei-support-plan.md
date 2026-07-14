# Plan: Add Dygma Raise 2 + Sonsei support

## Context

The app (CLI `dygmate` + tray `dygmate-tray`) currently detects only the Defy wireless by USB VID/PID `35EF:0012`, matched inline in `src/device.zig`. Goal: support the same wireless devices as Bazecor — the Raise 2 and the upcoming Sonsei.

Findings from Bazecor (`Bazecor/src/api/hardware-*`):

| Device | VID | Normal PID | Bootloader PID | Sides | Battery |
|---|---|---|---|---|---|
| Gen-1 Raise | 0x1209 | 0x2201 | 0x2200 | — | none (wired) — **out of scope** |
| Defy wireless | 0x35EF | 0x0012 | 0x0013 | 2 | left/right |
| Raise 2 (ANSI+ISO) | 0x35EF | 0x0021 | 0x0020 / 0x0022 | 2 | left/right, identical commands |
| Sonsei | 0x35EF | 0x0031 | 0x0030 | **1** | single battery |

- Raise 2 is a wireless split keyboard using the **identical** Focus battery command set as Defy (`wireless.battery.left/right.level/status`, `savingMode`, `forceRead` — verified in Bazecor's `BatteryStatus.tsx`, which has no per-device branching, and the virtual device mocks). Works with our two-sided model unchanged.
- Sonsei (`hardware-dygma-sonsei-wireless/index.ts`) is a single-piece board (`sides: 1`, `hasRF: false`, keyboardType "wireless" = Bluetooth). Bazecor issues the same left/right battery commands to it and only swaps a CSS class in the UI. **Working assumption (hardware unreleased): the single battery reports on the `left` channel; the right channel answers empty.** The `Model` enum below is the single place to adjust if real firmware differs.
- Bootloader PIDs expose no battery interface and must NOT match.
- Raise 2 has 10 layers like the Defy → `layer.zig` `max_layer_index = 9` stays (Sonsei unknown; revisit if needed).

`battery.zig` (readAll/Acceptor) needs no changes: a side that never answers already degrades to `level=null/.unknown`, which the Acceptor and `LastKnown` merge handle. What DOES break for a 1-sided device is everything gated on `bothLevelsKnown` (connect announcement never fires, poll never backs off from the fast interval) and the hardcoded "Left:/Right:" UI text. So the plan threads a detected `Model` through — which also lets notifications name the detected keyboard ("Dygma Defy" / "Dygma Raise 2" / "Dygma Sonsei").

## Changes

### 1. `src/device.zig` — Model enum + PID mapping (core change)

Replace lines 11–12 (`dygma_vid` stays; `defy_wireless_pid` removed — no other users, verified):

```zig
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
    /// same left/right reads to every device) — adjust here if real firmware
    /// behaves differently.
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
```

- `Discovery` gains `model: ?Model = null`.
- `scanPortInfo` (line 77): `if (port.vid == dygma_vid and port.pid == defy_wireless_pid)` → `if (modelForIds(port.vid, port.pid)) |model|`; both return paths carry `.model = model`.
- `isDygmaPresentLinux` (line 87): return `?Model` (rename `sysfsModelLinux`); line-102 check becomes `if (modelForIds(vid, pid)) |m| return m;`. `isDygmaPresent` wraps back to bool.
- `discoverDygma` Linux branch: call `scanPortInfo` directly (not via `findDygmaPort`) so the model comes through; when present-without-port, take presence AND model from `sysfsModelLinux`.
- Generalize the "Defy"-specific doc comments (lines 1–5, 14–28, 43–45, 55–57); note in `scanPortInfo` that with multiple keyboards attached the first supported device in enumeration order wins (current behavior, unchanged).
- Tests (run via `main.zig`'s existing `test { _ = @import(...) }` block):

```zig
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
```

### 2. `src/tray_common.zig` — model in State, side-aware gating + text

- `State` (line 53) gains `model: ?device.Model = null` (mutex-protected, like `reading`/`status`).
- `runPollLoop`: after successful discovery (~line 343), write `st.model = found.model` under the mutex (the lock at lines 405–410 is a natural spot; also set it in the present-without-port path).
- **Side-aware readiness** replacing `bothLevelsKnown` at its three gate uses (announcement readiness in both trays, and backoff at line 417):

```zig
/// All battery-reporting sides have a level — gates the connect announcement
/// and the poll backoff. Null model (e.g. --port override) assumes 2 sides.
pub fn levelsKnown(model: ?device.Model, r: battery.Reading) bool {
    if (r.left.level == null) return false;
    const m = model orelse return r.right.level != null;
    return m.sides() < 2 or r.right.level != null;
}
```

  Keep `bothLevelsKnown` only if still referenced by tests; otherwise replace it. `runPollLoop` line 417: `if (levelsKnown(found.model, merged))`.
- **Notification titles** — replace the two consts (lines 185–186) with functions returning comptime literals (no buffers):

```zig
pub fn notificationTitleStatus(model: ?device.Model) []const u8 {
    const m = model orelse return "Dygma battery level";
    return switch (m) {
        .defy_wireless => "Dygma Defy battery level",
        .raise2 => "Dygma Raise 2 battery level",
        .sonsei => "Dygma Sonsei battery level",
    };
}
// notificationTitleLow: same shape with "battery low".
```

- **Notification bodies** become model-aware:
  - `fmtStatusBody(buf, model, r)` (line 224): unchanged "Left: …\nRight: …" for 2-sided/null; for 1-sided render just the left side as `"Battery: {s}"`.
  - `fmtLowBody(buf, model, side, level)` (line 234): 1-sided → `"Battery at {d}%"` (no side name).
- `planNotifications` needs no change: a never-reporting right side has `level == null` and is skipped by the low-crossing loop.
- Add tests: `levelsKnown` for sonsei (left-only suffices) vs defy (needs both) vs null model; `fmtStatusBody`/`fmtLowBody` 1-sided rendering.

### 3. `src/tray_windows.zig` — model into balloons + menu

- `updateTray` (lines 780–784): copy `g_state.model` inside the existing mutex hold; `announce_ready` (line 809) becomes `common.levelsKnown(model, r)`; pass model into `showEvent` (line 885) → titles via `notificationTitleStatus/Low(model)`, bodies via the new signatures.
- `showMenu` (lines 709–720): read model with status under the mutex; for a 1-sided model append a single `"Battery: {s}"` row instead of the Left/Right pair.
- Tooltip rendering (~line 823 onward): same 1-sided treatment (single line instead of left+right) — follow the existing `fmtKnownSide` usage.
- Icon (~line 838): shows the lower of the two last-known sides via `LastKnown.display()`; with right never reporting it naturally shows the single battery — no change.
- Header comment line 1: "for the Dygma Defy wireless" → "for Dygma wireless keyboards".

### 4. `src/tray_linux.zig` — same treatment

- Snapshot `app.state.model` where status/reading are copied for the UI (~line 479); `announce_ready` → `levelsKnown`; thread model through `sendNotification`/`notifyInner` (lines 559–580) using the title/body helpers.
- `buildMenuItems` (lines 866–880): 1-sided model → single `"Battery: {s}"` item instead of `.left`/`.right` rows (MenuId can keep both variants; just emit one).
- Tooltip equivalent if present: same 1-sided treatment.

### 5. `src/main.zig` — CLI

- Strings: usage banner (lines 17–18) → "a Dygma wireless keyboard (Defy, Raise 2, or Sonsei)"; line 23 → `Default: auto-detect by USB VID/PID (35EF:0012, :0021, :0031).`; line 77 → `"dygmate: no supported Dygma keyboard serial port found\n"`; line 80 → `"waiting for keyboard (no supported Dygma serial port found), rescanning in 3s..."`.
- CLI keeps `findDygmaPort` and the existing "left … right …" output; on a Sonsei the right column shows `?%` — acceptable for now (with `--port` the model is unknowable anyway). Optional follow-up, not in scope.

### 6. Packaging / docs

- `99-dygmate.rules`: three rule lines (`0012`, `0021`, `0031`), generalized comment:
  ```
  SUBSYSTEM=="tty", ATTRS{idVendor}=="35ef", ATTRS{idProduct}=="0012", TAG+="uaccess"
  SUBSYSTEM=="tty", ATTRS{idVendor}=="35ef", ATTRS{idProduct}=="0021", TAG+="uaccess"
  SUBSYSTEM=="tty", ATTRS{idVendor}=="35ef", ATTRS{idProduct}=="0031", TAG+="uaccess"
  ```
- `README.md`: line 3 mention Defy / Raise 2 / Sonsei; the manual udev one-liner (~lines 109–110) must write all three lines (`printf '%s\n' ... | sudo tee`).
- `dygmate-tray.service`: `Description=Dygmate Defy battery tray indicator` → `Description=Dygmate battery tray indicator`.
- `packaging/winget/0.1.1/dlnilsson.dygmate.locale.en-US.yaml` (latest dir = copy source for the next release; published copies immutable): ShortDescription/Description → "Dygma wireless keyboard battery status (Defy, Raise 2, Sonsei)"; add `raise-2`, `sonsei` tags. Leave `0.1.0/` untouched.
- `src/layer.zig` comment (~line 63): "beyond the Defy's 10 layers" → generalize; `max_layer_index` unchanged.

## Verification

Without hardware:
- `zig build test` — new `modelForIds`, `levelsKnown`, and body-formatting tests + existing suites.
- Build both binaries for Windows and cross-compile the Linux tray (tray_linux.zig changed) — catches the removed `defy_wireless_pid` and all signature changes.
- No keyboard: `dygmate --once` prints the new "no supported Dygma keyboard" message, exit 1.

With the Defy (regression, hardware on hand):
- `dygmate --once` still detects; tray connect notification now titled "Dygma Defy battery level" (same wording as before); menu still shows Left/Right rows; backoff still engages once both sides report.

With a Raise 2 / Sonsei (when available):
- Raise 2: auto-detect 35EF:0021, left/right levels, notifications titled "Dygma Raise 2 …".
- Sonsei: auto-detect 35EF:0031, menu shows single "Battery:" row, connect notification fires off the left level alone, poll backs off to 30s–2min despite the silent right channel. **Validate the left-channel assumption on real firmware; if it reports differently, adjust `Model.sides()`/`modelForIds` mapping in one place.**
- Linux: install the 3-line udev rule, replug, no AccessDenied.
- Two keyboards attached: first enumerated wins, no flapping (mirrors existing multi-Defy behavior).
