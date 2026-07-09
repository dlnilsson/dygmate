# dygmate

Windows tray app for checking Dygma Defy wireless battery status.

Currently Windows only. Linux support is coming.

Tiny runtime footprint: about 2.4 MB memory usage and very low CPU usage.

Shows desktop notifications on startup and when either side reaches a low battery level.

<p align="center">
  <img src="docs/tray.png" alt="Dygmate tray" width="120">
  <img src="docs/context-menu.png" alt="Dygmate context menu" width="360">
</p>

<p align="center">
  <img src="docs/dygmate-overlay.gif" alt="Dygmate layer overlay" width="720">
</p>

## Build

Requires [Zig 0.16.0](https://ziglang.org/download/).

```sh
zig build -Doptimize=ReleaseSmall
```
