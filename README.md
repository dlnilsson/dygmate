# dygma-battery

Reports the battery level and charging status of both halves of a Dygma
Defy wireless keyboard — the battery-reading slice of
[Bazecor](https://github.com/Dygmalab/Bazecor) without Electron. Ships as a
cross-platform console tool and a Windows system-tray indicator.

It talks the line-oriented ASCII [Focus API](https://github.com/Dygmalab/Bazecor/blob/development/FOCUS_API.md)
directly over the keyboard's USB CDC-ACM serial port (115200 baud) and
polls `wireless.battery.{left,right}.{level,status}` on an adaptive
cadence.

## Build

Requires [Zig 0.16.0](https://ziglang.org/download/).

```
zig build
```

Binaries land in `zig-out/bin/`:

- `dygma-battery(.exe)` — the console tool.
- `dygma-battery-tray.exe` — the Windows system-tray indicator (built only
  when targeting Windows).

## Usage

```
dygma-battery                 # auto-detect, adaptive 15-60 min polling
dygma-battery --once          # single reading, then exit
dygma-battery --interval 900  # fixed 15 min polling (minimum)
dygma-battery --port COM5     # skip auto-detection
```

Output, one line per poll:

```
left  87% (charging)   right  92% (full)
```

Statuses: `discharging`, `charging`, `full`, `fault`, `disconnected`
(side not reachable over RF), `?` (unreadable). If the keyboard is
unplugged the tool keeps rescanning and reconnects when it returns.

Exit codes: `0` ok, `1` device not found / communication failed
(`--once`), `2` bad usage.

## System tray (Windows)

```
zig build run-tray        # or run zig-out/bin/dygma-battery-tray.exe
```

`dygma-battery-tray` runs in the background with no console window. The tray
icon shows the **lower** of the two sides' battery percentage, colored by
level (green ≥ 50, amber ≥ 20, red below, blue while charging). Hover for a
tooltip with both sides in full; right-click for **Refresh now** /
**Disconnect** / **Quit**; double-click to force an immediate re-read.
Startup and reconnect show a desktop notification with the current battery
status once both sides have numeric battery levels. If either side reports
`?`, the tray retries with capped exponential backoff instead of showing a
partial notification. Dropping below 20% on a side raises a one-off balloon
notification.

A background thread owns the serial connection and runs the same
discover → connect → poll loop as the CLI, so the tray auto-reconnects when
the keyboard returns. Only one instance runs at a time (the exclusive port
makes a second copy pointless). New tray icons default to Windows' hidden
"overflow" area — drag it onto the taskbar to keep it visible.

## Notes

- **Close Bazecor first.** The serial port is exclusive-open; whichever
  program grabs it first wins.
- The keyboard is auto-detected by USB VID/PID `35EF:0012` (Defy
  wireless).
- **Linux**: your user must be able to open the port — typically
  `sudo usermod -aG dialout $USER` (some distros use the `uucp` group),
  then log out and back in.
- **macOS**: auto-detection is not supported by the serial library on
  macOS; pass `--port /dev/cu.usbmodemXXXX` explicitly. (Verified on
  Windows.)
- **Flash wear**: Focus commands with an argument (`<command> <data>`)
  are setters that write the keyboard's flash memory, which has a finite
  write lifespan. This tool only ever sends bare read commands, and the
  transport layer asserts that no command carries data.
- **Poll cadence**: the default cadence is adaptive based on the lower valid
  side percentage: 15 min below 50% or when unreadable, 30 min at 50%+,
  45 min at 80%+, and 1 hour near full. `--interval` can set a fixed CLI
  cadence, but values below 900 seconds are rejected.
- Dependency: [ZigEmbeddedGroup/serial](https://github.com/ZigEmbeddedGroup/serial)
  (master, which targets Zig 0.16). Pinned by hash in `build.zig.zon`.
