# Linux desktop notifications — design

Date: 2026-07-10
Status: approved
Step 3 of 3 (tray = step 1, overlay = step 2)

## Goal

Bring desktop notifications to the Linux tray with exact behavior parity to
Windows: a battery-status notification when the keyboard connects, and a
latched per-side low-battery warning. Delivered via the freedesktop
`org.freedesktop.Notifications` D-Bus interface using the existing hand-rolled
D-Bus client — zero new dependencies.

## Scope

In scope:

- Connect announcement: battery status for both sides, shown once when the
  keyboard connects and both sides have reported a level (same gating as
  Windows `canNotifyBatteryStatus`).
- Low-battery warning: per side, fires once when a non-charging side crosses
  below `low_threshold` (20%); latch resets when the side charges or recovers.
- Refactor: trigger/latch logic and notification texts move from
  `tray_windows.zig` to `tray_common.zig`; both platforms consume the shared
  planner. Windows behavior unchanged.
- Urgency hints: `critical` for warnings, `normal` for plain status.
- Notification replacement: track the daemon-assigned notification id and pass
  it as `replaces_id` so repeated events update one popup instead of stacking
  (single slot — matches the Windows single-balloon behavior).
- Theme icons via `app_icon`: `battery-caution` for warnings, `battery`
  otherwise. No embedded image assets.

Out of scope:

- Layer-change notifications, charge-complete, disconnect notices.
- Notification actions (buttons) and daemon capability probing.
- Any Windows behavior change beyond the internal refactor.

## Constraints

- Zero C dependencies; reuse `dbus.zig` marshaller and the tray's existing
  session-bus connection.
- All bus I/O stays on the main thread (established invariant).
- A missing/broken notification daemon must never break the tray: every
  notification failure is swallowed.
- `dbus.Connection.callAndWait` discards non-matching inbound messages while
  waiting for its reply (`dbus.zig:626`). Acceptable during startup, not at
  runtime — a Notify round-trip could swallow incoming menu calls. Runtime
  notifications therefore use fire-and-forget `call()` with async reply
  handling in the existing dispatch loop.

## Design

### 1. Shared trigger logic (`tray_common.zig`)

Move from `tray_windows.zig`, behavior unchanged:
`canNotifyBatteryStatus`, `hasLowBattery`, and the latch logic of
`checkLowBattery` / `latchLowBatteryNotifications`. New shape — a planner
that mutates the `notified_low` latch and returns events instead of calling a
platform API:

```zig
pub const NotifyEvent = struct {
    kind: enum { connect_status, low_battery },
    side: ?u1,      // low_battery only: 0 = left, 1 = right
    level: ?u8,     // low_battery only
    warning: bool,  // true => warning urgency/icon
};

/// Mutates latch. Returns 0..3 events (1 connect_status, or up to 2
/// low_battery). Mirrors the Windows updateTray decision flow exactly:
/// - announce + both levels known: emit connect_status, latch lows.
/// - announce pending but a side unknown: emit nothing, keep announce set.
/// - otherwise: per-side low check against the latch.
pub fn planNotifications(
    latch: *[2]bool,
    announce: bool,
    snapshot: battery.Reading,
) struct { events: [3]?NotifyEvent, consumed_announce: bool }
```

(Exact return shape may be adjusted during implementation; the contract is:
pure decision + latch mutation, no platform calls.)

Notification texts also move to `tray_common` so both platforms render
identical strings:

- Title (status): `"Dygma Defy battery level"`
- Title (low): `"Dygma Defy battery low"`
- Body (status): `"Left: {s}\nRight: {s}"` via `fmtSide`
- Body (low): `"{Left|Right} side at {d}%"`

`State.notified_low` doc comment drops "Windows only".

### 2. Windows refactor (`tray_windows.zig`)

`updateTray` consumes planner events and renders them through the existing
`showBalloon` (`NIIF_WARNING` when `warning`, else `NIIF_INFO_ICON`). The
four moved functions are deleted locally. No behavior change; the reset of
`notified_low` when disconnected/paused stays where it is.

### 3. Linux sender (`tray_linux.zig`)

New function sending `org.freedesktop.Notifications.Notify` on the existing
connection, called from `rebuildAndNotify`:

- Destination `org.freedesktop.Notifications`, path
  `/org/freedesktop/Notifications`, interface same as destination,
  member `Notify`, signature `susssasa{sv}i`.
- `app_name`: `"dygmate"`
- `replaces_id`: `App.notify_id` (0 until the first reply arrives)
- `app_icon`: `"battery-caution"` when `warning`, else `"battery"`
- `summary`/`body`: shared texts from `tray_common`
- `actions`: empty `as`
- `hints`: `a{sv}` with one entry, `"urgency"` → variant byte:
  2 (critical) when `warning`, 1 (normal) otherwise
- `expire_timeout`: `-1` (daemon default)

Marshalling uses the existing `dbus.Writer` (string/uint32/int32/byte/
beginArray/beginStruct cover everything; dict entries align 8 like structs).

### 4. Async reply handling

- Send with `conn.call()` (returns serial, does not block).
- New `App` fields: `notify_id: u32 = 0`, `pending_notify_serial: ?u32 = null`.
- `dispatch` gets a new early branch: a `method_return` whose `reply_serial`
  matches `pending_notify_serial` has its body's `u32` parsed into
  `App.notify_id`; clear the pending serial. Parse failures ignored.
- `reconnect` resets both fields (ids are daemon/connection-scoped).
- Only one Notify is typically in flight; if a second fires before the first
  reply, the newer serial wins and the older reply is ignored — worst case
  one popup stacks once. Not worth a queue.

### 5. Trigger point (`rebuildAndNotify`)

Mirror the Windows `updateTray` flow:

- Read `announce_connection` under the mutex along with reading/connected;
  clear it only when the planner consumed it (both sides known).
- Connected, not paused, live reading: merge into `app.last`, build the
  snapshot, run `planNotifications`, send each event.
- Not connected or paused: reset `notified_low` latch — same as Windows.

## Error handling

- Every Notify send failure: `catch {}`. Tray icon, tooltip, and menu are
  unaffected when no notification daemon is running.
- Malformed/missing Notify reply: `notify_id` stays 0; next notification
  creates a new popup instead of replacing. Cosmetic only.

## Testing

- Unit tests in `tray_common.zig` for `planNotifications`:
  - low crossing fires once, does not re-fire while latched;
  - recovery above threshold resets the latch;
  - charging side never warns and resets the latch;
  - announce with both sides known emits `connect_status` and latches lows;
  - announce with one side unknown emits nothing and stays pending;
  - `warning` set when any non-charging side is below threshold.
- Manual verification on a live desktop (dunst/mako/GNOME): connect keyboard
  → status popup; simulate low battery → critical popup replaces the
  previous one; kill the daemon → tray keeps working, no notifications.
- `busctl --user monitor org.freedesktop.Notifications` to inspect the wire
  call (hints, urgency, replaces_id) during manual testing.

## Non-goals / future

- Daemon capability detection (`GetCapabilities`) — daemons ignore unknown
  hints; not needed.
- Notification actions ("open Bazecor" button) — possible later via the
  `actions` array plus `ActionInvoked` signal subscription.
