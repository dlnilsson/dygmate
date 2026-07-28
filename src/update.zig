//! One-shot "is there a newer release?" check against the GitHub API. A tray
//! worker thread calls check() ~60s after startup; on a newer release it fills
//! Result with the tag and release URL, which the tray surfaces as a
//! context-menu item linking to the release page.

const std = @import("std");
const Allocator = std.mem.Allocator;

const owner_repo = "dlnilsson/dygmate";
const api_url = "https://api.github.com/repos/" ++ owner_repo ++ "/releases/latest";

/// Cap on the response body we buffer. GitHub release JSON (including notes) is
/// a few KB; anything past this is treated as a failed check.
const body_cap = 128 * 1024;

/// Delay before the single check runs, giving the tray time to settle first.
const check_delay_s = 60;

/// Shared publish target for the background check. The worker thread is the
/// sole writer; menu-thread readers see a consistent snapshot via the acquire
/// load of `available` paired with the worker's release store.
pub const State = struct {
    available: std.atomic.Value(bool) = .init(false),
    url_buf: [256]u8 = undefined,
    url_len: usize = 0,
    label_buf: [64]u8 = undefined,
    label_len: usize = 0,

    pub fn isAvailable(s: *const State) bool {
        return s.available.load(.acquire);
    }
    pub fn url(s: *const State) []const u8 {
        return s.url_buf[0..s.url_len];
    }
    pub fn label(s: *const State) []const u8 {
        return s.label_buf[0..s.label_len];
    }
};

/// Spawn the one-shot background update check. `current` must outlive the
/// thread (pass the static build_options.version). Returns immediately; the
/// thread sleeps `check_delay_ns`, checks once, and on a hit publishes to
/// `state`. Silent on any failure, including a failed thread spawn.
pub fn spawnCheck(gpa: Allocator, current: []const u8, state: *State) void {
    const t = std.Thread.spawn(.{}, checkWorker, .{ gpa, current, state }) catch return;
    t.detach();
}

fn checkWorker(gpa: Allocator, current: []const u8, state: *State) void {
    // Isolated Io so the TLS/network work never shares the tray's main-loop io
    // (Linux runs D-Bus on it).
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const dur: std.Io.Clock.Duration = .{
        .clock = .awake,
        .raw = std.Io.Duration.fromSeconds(check_delay_s),
    };
    dur.sleep(io) catch {};

    var res = Result{};
    if (!check(io, gpa, current, &res)) return;

    @memcpy(state.url_buf[0..res.url_len], res.url());
    state.url_len = res.url_len;
    const label = std.fmt.bufPrint(&state.label_buf, "Update available: {s}", .{res.tag()}) catch state.label_buf[0..0];
    state.label_len = label.len;
    state.available.store(true, .release);
}

pub const Result = struct {
    url_buf: [256]u8 = undefined,
    url_len: usize = 0,
    tag_buf: [32]u8 = undefined,
    tag_len: usize = 0,

    pub fn url(r: *const Result) []const u8 {
        return r.url_buf[0..r.url_len];
    }
    pub fn tag(r: *const Result) []const u8 {
        return r.tag_buf[0..r.tag_len];
    }
};

/// GET the latest release; when its tag is semver-greater than `current`, fill
/// `out` and return true. Any failure (network, HTTP status, oversized body,
/// malformed JSON, unparseable version) returns false and shows nothing.
pub fn check(io: std.Io, gpa: Allocator, current: []const u8, out: *Result) bool {
    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();

    const buf = gpa.alloc(u8, body_cap) catch return false;
    defer gpa.free(buf);
    var bw = std.Io.Writer.fixed(buf);

    const res = client.fetch(.{
        .location = .{ .url = api_url },
        .extra_headers = &.{
            // GitHub rejects requests without a User-Agent.
            .{ .name = "user-agent", .value = "dygmate" },
            .{ .name = "accept", .value = "application/vnd.github+json" },
        },
        .response_writer = &bw,
    }) catch return false;
    if (res.status != .ok) return false;

    return parseAndCompare(gpa, bw.buffered(), current, out);
}

const Release = struct {
    tag_name: []const u8,
    html_url: []const u8,
};

/// Split out from check() so the JSON + semver logic is unit-testable without
/// touching the network.
fn parseAndCompare(gpa: Allocator, body: []const u8, current: []const u8, out: *Result) bool {
    const parsed = std.json.parseFromSlice(Release, gpa, body, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    defer parsed.deinit();

    const rel = parsed.value;
    if (rel.tag_name.len > out.tag_buf.len or rel.html_url.len > out.url_buf.len) return false;
    if (!semverGreater(rel.tag_name, current)) return false;

    @memcpy(out.tag_buf[0..rel.tag_name.len], rel.tag_name);
    out.tag_len = rel.tag_name.len;
    @memcpy(out.url_buf[0..rel.html_url.len], rel.html_url);
    out.url_len = rel.html_url.len;
    return true;
}

const Semver = struct { major: u32, minor: u32, patch: u32 };

/// Parse `major.minor.patch`, tolerating a leading `v` and dropping any
/// `-prerelease` / `+build` suffix. Missing minor/patch default to 0.
fn parseSemver(raw: []const u8) ?Semver {
    var s = raw;
    if (s.len > 0 and (s[0] == 'v' or s[0] == 'V')) s = s[1..];
    // Cut off pre-release / build metadata.
    if (std.mem.indexOfAny(u8, s, "-+")) |i| s = s[0..i];
    if (s.len == 0) return null;

    var it = std.mem.splitScalar(u8, s, '.');
    var parts: [3]u32 = .{ 0, 0, 0 };
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (n >= 3) return null; // more than 3 components: not a plain semver
        parts[n] = std.fmt.parseInt(u32, part, 10) catch return null;
    }
    return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
}

/// True when `remote` is a strictly newer semver than `current`. Unparseable
/// input on either side returns false (nothing shown).
fn semverGreater(remote: []const u8, current: []const u8) bool {
    const r = parseSemver(remote) orelse return false;
    const c = parseSemver(current) orelse return false;
    if (r.major != c.major) return r.major > c.major;
    if (r.minor != c.minor) return r.minor > c.minor;
    return r.patch > c.patch;
}

test parseSemver {
    try std.testing.expectEqual(Semver{ .major = 1, .minor = 2, .patch = 3 }, parseSemver("1.2.3").?);
    try std.testing.expectEqual(Semver{ .major = 0, .minor = 2, .patch = 0 }, parseSemver("v0.2.0").?);
    try std.testing.expectEqual(Semver{ .major = 1, .minor = 0, .patch = 0 }, parseSemver("1").?);
    try std.testing.expectEqual(Semver{ .major = 1, .minor = 2, .patch = 0 }, parseSemver("v1.2-rc1").?);
    try std.testing.expect(parseSemver("") == null);
    try std.testing.expect(parseSemver("v") == null);
    try std.testing.expect(parseSemver("1.x.3") == null);
    try std.testing.expect(parseSemver("1.2.3.4") == null);
}

test semverGreater {
    try std.testing.expect(semverGreater("0.2.0", "0.1.0"));
    try std.testing.expect(semverGreater("v0.2.0", "0.1.99"));
    try std.testing.expect(semverGreater("1.0.0", "0.9.9"));
    try std.testing.expect(semverGreater("0.1.1", "0.1.0"));
    try std.testing.expect(!semverGreater("0.1.0", "0.1.0"));
    try std.testing.expect(!semverGreater("0.1.0", "0.2.0"));
    try std.testing.expect(!semverGreater("v0.1.0", "0.1.0"));
    try std.testing.expect(!semverGreater("garbage", "0.1.0"));
    try std.testing.expect(!semverGreater("0.2.0", "garbage"));
}

test parseAndCompare {
    const gpa = std.testing.allocator;
    const body =
        \\{"tag_name":"v0.2.0","html_url":"https://github.com/dlnilsson/dygmate/releases/tag/v0.2.0","name":"0.2.0","extra":123}
    ;
    var out = Result{};
    try std.testing.expect(parseAndCompare(gpa, body, "0.1.0", &out));
    try std.testing.expectEqualStrings("v0.2.0", out.tag());
    try std.testing.expectEqualStrings("https://github.com/dlnilsson/dygmate/releases/tag/v0.2.0", out.url());

    // Same version: no update.
    var out2 = Result{};
    try std.testing.expect(!parseAndCompare(gpa, body, "0.2.0", &out2));

    // Malformed JSON.
    var out3 = Result{};
    try std.testing.expect(!parseAndCompare(gpa, "not json", "0.1.0", &out3));
}

test "release check recognizes a major-version update" {
    const gpa = std.testing.allocator;
    const body =
        \\{"tag_name":"v1.0.0","html_url":"https://github.com/dlnilsson/dygmate/releases/tag/v1.0.0"}
    ;
    var out = Result{};

    try std.testing.expect(parseAndCompare(gpa, body, "v0.1.5", &out));
    try std.testing.expectEqualStrings("v1.0.0", out.tag());
    try std.testing.expectEqualStrings("https://github.com/dlnilsson/dygmate/releases/tag/v1.0.0", out.url());
}
