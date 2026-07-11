//! Tiny persistent settings file. Remembers a handful of user toggles across
//! restarts in a plain `key = value` INI file. Best-effort by design: every
//! read or write failure falls back to defaults or is silently dropped, so a
//! missing, unreadable, or read-only config never blocks or crashes the tray.
//!
//! Location (`config.ini`):
//!   Linux:   $XDG_CONFIG_HOME/dygmate/  else  $HOME/.config/dygmate/
//!   Windows: %APPDATA%\dygmate\
//!
//! Adding a setting later: add a field to `Config`, one match arm in `parse`,
//! and one line in `serialize`.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;

/// Cap on the config file size we will read into memory.
const read_limit: Io.Limit = .limited(64 * 1024);

pub const Config = struct {
    /// Last state of the tray's "Show layer overlay" toggle. Defaults on.
    show_layer_overlay: bool = true,
};

/// Read and parse the config file. Any failure (no path, missing file,
/// unreadable, parse error) yields defaults. Never fails.
pub fn load(io: Io, gpa: Allocator, environ: *EnvMap) Config {
    const p = path(gpa, environ) catch return .{};
    defer gpa.free(p);
    return loadFrom(io, gpa, p);
}

/// `load` against a pre-resolved absolute path (Windows resolves the path once
/// at startup and reuses it from the window callback, which has no environ).
pub fn loadFrom(io: Io, gpa: Allocator, abs_path: []const u8) Config {
    const data = Io.Dir.cwd().readFileAlloc(io, abs_path, gpa, read_limit) catch return .{};
    defer gpa.free(data);
    return parse(data);
}

/// Serialize and write the config file, creating the parent directory as
/// needed. All errors are ignored — a failed save must never block the UI.
pub fn save(io: Io, gpa: Allocator, environ: *EnvMap, cfg: Config) void {
    const p = path(gpa, environ) catch return;
    defer gpa.free(p);
    saveTo(io, gpa, p, cfg);
}

/// `save` against a pre-resolved absolute path. See `loadFrom`.
pub fn saveTo(io: Io, gpa: Allocator, abs_path: []const u8, cfg: Config) void {
    if (std.fs.path.dirname(abs_path)) |dir| {
        Io.Dir.cwd().createDirPath(io, dir) catch {};
    }
    const body = serialize(gpa, cfg) catch return;
    defer gpa.free(body);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = abs_path, .data = body }) catch {};
}

/// Build the platform config file path. Caller frees.
pub fn path(gpa: Allocator, environ: *EnvMap) ![]u8 {
    if (builtin.os.tag == .windows) {
        const base = environ.get("APPDATA") orelse return error.NoConfigDir;
        return std.fmt.allocPrint(gpa, "{s}\\dygmate\\config.ini", .{base});
    }
    if (environ.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len != 0) return std.fmt.allocPrint(gpa, "{s}/dygmate/config.ini", .{xdg});
    }
    const home = environ.get("HOME") orelse return error.NoConfigDir;
    return std.fmt.allocPrint(gpa, "{s}/.config/dygmate/config.ini", .{home});
}

/// Parse INI text into a `Config`. Unknown keys, comments (`#`/`;`), section
/// headers (`[...]`), and malformed lines are ignored; unset or unparseable
/// fields keep their default.
pub fn parse(data: []const u8) Config {
    var cfg: Config = .{};
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#' or line[0] == ';' or line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "show_layer_overlay")) {
            if (parseBool(val)) |b| cfg.show_layer_overlay = b;
        }
    }
    return cfg;
}

fn serialize(gpa: Allocator, cfg: Config) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "# dygmate config\nshow_layer_overlay = {s}\n",
        .{boolStr(cfg.show_layer_overlay)},
    );
}

fn parseBool(s: []const u8) ?bool {
    if (std.mem.eql(u8, s, "true")) return true;
    if (std.mem.eql(u8, s, "false")) return false;
    return null;
}

fn boolStr(b: bool) []const u8 {
    return if (b) "true" else "false";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
test "defaults on empty input" {
    const cfg = parse("");
    try std.testing.expect(cfg.show_layer_overlay);
}

test "round-trip" {
    const gpa = std.testing.allocator;
    const body = try serialize(gpa, .{ .show_layer_overlay = false });
    defer gpa.free(body);
    const cfg = parse(body);
    try std.testing.expect(!cfg.show_layer_overlay);
}

test "explicit values" {
    try std.testing.expect(parse("show_layer_overlay = true").show_layer_overlay);
    try std.testing.expect(!parse("show_layer_overlay = false").show_layer_overlay);
    // whitespace and no-space variants
    try std.testing.expect(!parse("  show_layer_overlay=false  ").show_layer_overlay);
}

test "comments, sections, and unknown keys ignored" {
    const text =
        \\# a comment
        \\; another comment
        \\[section]
        \\unknown_key = false
        \\show_layer_overlay = false
    ;
    try std.testing.expect(!parse(text).show_layer_overlay);
}

test "malformed bool keeps default" {
    try std.testing.expect(parse("show_layer_overlay = maybe").show_layer_overlay);
    try std.testing.expect(parse("show_layer_overlay").show_layer_overlay);
}
