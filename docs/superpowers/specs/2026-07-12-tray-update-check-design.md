# Tray update check — design

## Goal

Both tray binaries (`dygmate-tray`, Linux + Windows) check GitHub once at
startup for a newer release. When one exists, the tray context menu grows an
extra item linking to the release page. The CLI (`dygmate`) is unchanged.

## Behavior

- One check per process, ~60 s after startup, on a dedicated worker thread.
- No retry. All failures (no network, HTTP error, malformed JSON, rate limit)
  are silent — debug-logged on Linux, ignored on Windows.
- If the latest GitHub release tag is semver-greater than the running
  `build_options.version`, a menu item `Update available: vX.Y.Z` appears.
  Clicking it opens the release `html_url` in the default browser.

## Module: `src/update.zig`

std-only, no `build_options` import (current version passed in as a parameter),
so it stays trivially testable.

```zig
pub const Result = struct {
    url_buf: [256]u8 = undefined,
    url_len: usize = 0,
    tag_buf: [32]u8 = undefined,
    tag_len: usize = 0,
    pub fn url(r: *const Result) []const u8 { return r.url_buf[0..r.url_len]; }
    pub fn tag(r: *const Result) []const u8 { return r.tag_buf[0..r.tag_len]; }
};

/// GET the latest release; return true and fill `out` only when the remote
/// tag is semver-greater than `current`. Any error returns false.
pub fn check(io: std.Io, gpa: Allocator, current: []const u8, out: *Result) bool;
```

- Endpoint: `https://api.github.com/repos/dlnilsson/dygmate/releases/latest`
  (owner/repo hardcoded).
- Request headers: `User-Agent: dygmate` (GitHub requires it) and
  `Accept: application/vnd.github+json`.
- Body read capped at 64 KB. Parsed with `std.json` extracting `tag_name` and
  `html_url` (ignore unknown fields).
- `fn semverGreater(remote, current) bool`: strip a leading `v`, drop any
  `-prerelease`/`+build` suffix, parse `major.minor.patch` as integers, compare
  lexically by component. Non-parseable input compares as "not greater" (no
  item shown). Unit-tested.

## Worker thread

One-shot, spawned in each tray's startup:

1. `std.Thread.sleep(60 * ns_per_s)`.
2. Create an isolated `std.Io.Threaded` (its own `io`), so the HTTP/TLS work
   never touches the main event loop's `io` (Linux D-Bus lives there).
3. Call `update.check`. On a hit, copy `url` + build the label into the shared
   state, then `@atomicStore` the `available` flag with release ordering.
4. `deinit` the threaded io and exit.

## Shared state

A small struct owned by each tray:

```zig
available: std.atomic.Value(bool) = .init(false),
url_buf: [256]u8,   url_len: usize,   // written before the flag store
label_buf: [64]u8,  label_len: usize,
```

Single writer (worker thread), read on the menu thread after an acquire-load of
`available`. Buffers are fully written before the flag flips, so the acquire
load is the only synchronization needed.

## Menu integration

Both trays rebuild their menu each time it opens, so the conditional item needs
no push/refresh.

- **Linux** (`tray_linux.zig`): add `MenuId.update = 9`. `buildMenuItems`
  conditionally includes the update item (enabled) when the flag is set; the
  items container becomes a slice sized 8 or 9. `GetLayout` /
  `GetGroupProperties` already iterate the slice generically. Click dispatch:
  `.update => openUrl(app, url)`.
- **Windows** (`tray_windows.zig`): add `ID_UPDATE`. When the flag is set,
  `AppendMenuW` the item before Quit. `TrackPopupMenu` dispatch:
  `ID_UPDATE => shellOpen(url)`.

## Opening the URL

- **Linux**: detached spawn of `xdg-open <url>`.
- **Windows**: `ShellExecuteW(null, "open", url_utf16, null, null, SW_SHOWNORMAL)`
  (shell32 already linked by the tray).

## Build

`update.zig` is pulled in via `@import` from both tray sources; no `build.zig`
change is required. TLS + JSON increase the ReleaseSmall binary size — accepted.

## Testing

- Unit tests for `semverGreater` (greater / equal / less / prerelease / bad
  input) and JSON field extraction from a sample GitHub payload.
- Network fetch verified manually (real run), not unit-tested.
