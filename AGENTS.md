# AGENTS.md

Battery status for Dygma wireless keyboards (Defy, Raise 2, Sonsei) in the
system tray, over the Focus serial protocol. Windows + Linux. Zig 0.16.0.
Two binaries: `dygmate` (CLI, `src/main.zig`) and `dygmate-tray`
(`src/tray_windows.zig` / `src/tray_linux.zig`).

## Commands

```sh
zig build                      # build CLI + tray for the host
zig build test                 # all unit tests (CLI + tray modules)
zig build run -- --once        # one battery reading, then exit
zig build run-tray             # tray on Windows (run-tray-linux on Linux)
zig build release              # cross-build both OSes, ReleaseSmall, zig-out/{windows,linux}/
```

## Hardware safety — read before touching serial code

- **Only bare Focus reads.** Focus commands with an argument are setters that
  write the keyboard's flash; flash write cycles are finite. Never issue a
  setter from a polling loop (see `src/battery.zig` module doc).
- **Poll interval ≥ 5s.** Bazecor polls at 5s; that is the proven-safe floor
  (`min_cli_interval_s` in `src/main.zig`). Default is adaptive 30s–2min.
- **The serial port is exclusive.** Bazecor must be closed; on-device testing
  fails with AccessDenied otherwise (`src/porthint.zig` explains per-OS hints).
- Battery readings pass through `battery.Acceptor`, a plausibility gate that
  rejects bogus values after sleep/hibernation wake. Keep it outside the
  reconnect loop so the baseline survives reconnects.

## Architecture

Layering: transport → domain → shared UI state → platform UI.

- `src/focus.zig` — Focus transport: line-oriented ASCII over CDC-ACM serial,
  115200 8N1; request `<cmd>\n`, response ends with a lone `.` line. Protocol
  reference (commands, getter/setter semantics, response formats):
  [Bazecor FOCUS_API.md](https://github.com/Dygmalab/Bazecor/blob/e6b51b607f25627492fb30d2a64c68c8eca6d27f/FOCUS_API.md).
- `src/device.zig` — USB discovery by VID/PID (VID 0x35EF; bootloader PIDs
  deliberately unsupported). Shared by CLI and tray.
- `src/battery.zig`, `src/layer.zig` — domain: command strings, parsing,
  Acceptor, poll-interval suggestion / active-layer read.
- `src/tray_common.zig` — platform-agnostic tray state, discover→connect→poll
  loop, formatting, color palette. Logic shared by both trays lives here only.
- `src/tray_windows.zig` — Win32 tray (hidden window + Shell_NotifyIcon; a
  background thread owns the serial port, posts readings to the UI thread).
- `src/tray_linux.zig` — StatusNotifierItem + dbusmenu over D-Bus.
- `src/dbus.zig`, `src/wayland.zig` — hand-rolled minimal protocol clients.
  No system libraries; only the subset the tray/OSD needs is implemented.
- `src/osd_linux.zig` — wlr-layer-shell layer OSD; must keep visual parity
  with the Windows OSD (`paintOsd` in tray_windows.zig).
- `src/config.zig` — best-effort INI config; never fails, falls back to
  defaults. Adding a setting: field in `Config` + `parse` arm + `serialize` line.
- `src/porthint.zig`, `src/update.zig` — open-error hints, GitHub update check.

Only external dependency: `serial` (vendored under `zig-pkg/`, pinned in
`build.zig.zon`). Prefer implementing protocol subsets by hand over adding
dependencies — that is the established style here.

## Conventions

- Tests live inline in each module (`test "..." { ... }`). New CLI-side
  modules must be registered in the `test` block at the bottom of
  `src/main.zig`; tray-only modules are covered via `zig build test-tray`.
- Modules start with a `//!` doc comment stating scope and invariants. Keep
  these updated — they are the primary architecture docs.
- Platform-specific code branches on `builtin.os.tag`; macOS has no port
  enumeration (users pass `--port`), don't assume it does.
- This uses Zig 0.16 idioms: `std.Io` interface (`io` parameter threaded
  through), `std.process.Init` main signature. Match them.
- Cross-cutting behavior changes must land in `tray_common.zig`, not be
  duplicated per platform.

## Releases

- Version source of truth: `.version` in `build.zig.zon`. Release builds
  override with the git tag via `-Dversion` (see `build.zig`).
- Tag `v*` → CI (`.github/workflows/release.yml`) cross-builds and publishes;
  `scripts/release.sh` mirrors it locally. Winget manifests live in
  `packaging/winget/<version>/` (see its README); Arch uses
  `scripts/bump-pkgver` + the tarball's udev rule and systemd unit.
