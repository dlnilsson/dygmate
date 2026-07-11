# Persistent Overlay Config — Design

## Goal

Remember the last state of the tray's "Show layer overlay" toggle across
restarts. Persist it to a small INI file so the OSD comes back the way the user
left it. Applies to both Linux and Windows trays.

## Non-goals

- No general settings framework. One key today (`show_layer_overlay`); the
  reader is extensible so more keys can be added with minimal code, but we do
  not add speculative keys now (YAGNI).
- No migration/versioning of the config file.
- No live file-watching. Config is read once at startup and written on toggle.

## Config file

Location (`config.ini`):

- Linux: `$XDG_CONFIG_HOME/dygmate/config.ini`, falling back to
  `$HOME/.config/dygmate/config.ini` when `XDG_CONFIG_HOME` is unset. This
  lands at the stated `$HOME/.config/dygmate/config.ini` for a typical setup.
- Windows: `%APPDATA%\dygmate\config.ini`.

Format — line-based `key = value`, one key today:

```
# dygmate config
show_layer_overlay = true
```

## Module: `src/config.zig`

Self-contained. Owns path building, parsing, and serialization. Best-effort:
never crashes or blocks the tray. All environment lookups happen internally;
callers pass only an allocator.

```zig
pub const Config = struct {
    show_layer_overlay: bool = true, // defaults live here
};

/// Read and parse the config file. Any error (missing file, bad path,
/// unreadable, parse failure) returns defaults. Never fails.
pub fn load(alloc: std.mem.Allocator) Config;

/// Serialize and write the config file, creating the parent directory if
/// needed. All errors are ignored — a failed save must never block the UI.
pub fn save(alloc: std.mem.Allocator, cfg: Config) void;

/// Build the platform config file path. Caller frees.
fn path(alloc: std.mem.Allocator) ![]u8;
```

### Parser

Iterate lines. For each line:

1. Trim leading/trailing whitespace.
2. Skip blank lines, comments (`#` or `;` first char), and `[section]` headers.
3. Split on the first `=`. Trim key and value.
4. Match key against known fields; parse value. Unknown keys are ignored.

Bool parse: `true` → true, `false` → false; anything else leaves the field at
its default.

Adding a future key = one struct field + one match arm + one serializer line.

### Serializer

Write a short header comment plus one `key = value` line per field:

```
# dygmate config
show_layer_overlay = true
```

Create the parent directory (mkdir -p equivalent) before writing.

## Integration

### Linux (`src/tray_linux.zig`)

- Startup, at the point OSD availability is decided (currently
  `app.state.osd_enabled.store(app.osd != null, .release);`, ~line 221):
  load config and combine with OSD availability:

  ```zig
  const cfg = config.load(gpa);
  app.state.osd_enabled.store(app.osd != null and cfg.show_layer_overlay, .release);
  ```

  OSD-unavailable still forces the toggle off — existing behavior wins over the
  saved preference.

- Toggle handler (`.osd` case, ~line 998), after storing the new `enabled`
  value: `config.save(gpa, .{ .show_layer_overlay = enabled });`

### Windows (`src/tray_windows.zig`)

- Startup: load config and set `g_state.osd_enabled` from
  `cfg.show_layer_overlay`. (Windows has no OSD-availability gating.)
- Toggle handler (~line 486), after storing `now_on`:
  `config.save(alloc, .{ .show_layer_overlay = now_on });`

## Error handling

- `load` failure (any cause) → defaults. Tray always starts.
- `save` failure (any cause) → silently ignored. UI never blocks or crashes on
  a bad path, read-only filesystem, or missing parent directory that could not
  be created.

## Testing (`src/config.zig` unit tests)

- Round-trip: serialize a `Config`, parse it back, values match.
- Unknown key ignored (does not error, does not affect known fields).
- Comment lines (`#`, `;`) and `[section]` headers skipped.
- Missing/empty input → defaults.
- Malformed bool value → field stays at default.
