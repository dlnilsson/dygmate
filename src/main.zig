const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const focus = @import("focus.zig");
const battery = @import("battery.zig");
const device = @import("device.zig");
const porthint = @import("porthint.zig");

const rescan_delay_s = 3;

const usage =
    \\Usage: dygmate [options]
    \\
    \\Reports battery level and charging status of both halves of a
    \\Dygma Defy wireless keyboard. Close Bazecor first: the serial
    \\port is exclusive.
    \\
    \\Options:
    \\  --port <name>      Serial port (e.g. COM5 or /dev/ttyACM0).
    \\                     Default: auto-detect by USB VID/PID 35EF:0012.
    \\  --interval <secs>  Fixed poll interval in seconds (minimum: 900).
    \\                     Default: adaptive 15-60 minutes.
    \\  --once             Print one reading and exit.
    \\  --version          Print version and exit.
    \\  -h, --help         Show this help.
    \\
;

const Options = struct {
    port: ?[]const u8 = null,
    fixed_interval_s: ?u64 = null,
    once: bool = false,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const alloc = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [256]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const out = &stdout_writer.interface;

    const opts = parseArgs(args) catch |err| switch (err) {
        error.Help => {
            try out.writeAll(usage);
            try out.flush();
            return 0;
        },
        error.Version => {
            try out.print("dygmate {s}\n", .{build_options.version});
            try out.flush();
            return 0;
        },
        error.InvalidArgs => {
            std.debug.print("{s}", .{usage});
            return 2;
        },
    };

    while (true) {
        // DISCOVER
        const path: []u8 = blk: {
            if (opts.port) |p| break :blk try device.normalizePortPath(alloc, p);
            if (device.findDygmaPort(io, alloc) catch null) |p| break :blk p;
            if (opts.once) {
                std.debug.print("dygmate: no Dygma Defy wireless (35EF:0012) serial port found\n", .{});
                return 1;
            }
            std.debug.print("waiting for keyboard (no 35EF:0012 serial port found), rescanning in 3s...\n", .{});
            sleepSeconds(io, rescan_delay_s);
            continue;
        };
        defer alloc.free(path);

        // CONNECT
        var dev = focus.Focus.open(io, path) catch |err| {
            const hint = porthint.forOpenError(err);
            if (opts.once) {
                std.debug.print("dygmate: failed to open {s}: {s}{s}\n", .{ path, @errorName(err), hint });
                return 1;
            }
            std.debug.print("failed to open {s} ({s}){s}, retrying in 3s...\n", .{ path, @errorName(err), hint });
            sleepSeconds(io, rescan_delay_s);
            continue;
        };
        std.debug.print("connected to {s}\n", .{path});
        defer dev.close();

        // POLL. No forceRead: the neuron serves cached values on a plain read
        // (Bazecor only forceReads on an explicit button press). battery.read
        // retries once when a side momentarily reports "disconnected".
        while (true) {
            const reading = battery.read(&dev) catch |err| {
                if (opts.once) {
                    std.debug.print("dygmate: communication failed: {s}\n", .{@errorName(err)});
                    return 1;
                }
                std.debug.print("connection lost ({s}), rescanning...\n", .{@errorName(err)});
                break;
            };
            try printReading(out, reading);
            if (opts.once) {
                return 0;
            }
            const interval_s = opts.fixed_interval_s orelse battery.suggestedPollIntervalSeconds(reading);
            sleepSeconds(io, interval_s);
        }
    }
}

/// Best-effort blocking sleep; cancellation is not meaningful for the CLI.
fn sleepSeconds(io: std.Io, secs: u64) void {
    const dur: std.Io.Clock.Duration = .{
        .clock = .awake,
        .raw = std.Io.Duration.fromSeconds(@intCast(secs)),
    };
    dur.sleep(io) catch {};
}

fn parseArgs(args: []const [:0]const u8) error{ Help, Version, InvalidArgs }!Options {
    var opts = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            opts.port = args[i];
        } else if (std.mem.eql(u8, arg, "--interval")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            const interval_s = std.fmt.parseInt(u64, args[i], 10) catch return error.InvalidArgs;
            if (interval_s < battery.min_poll_interval_s) return error.InvalidArgs;
            opts.fixed_interval_s = interval_s;
        } else if (std.mem.eql(u8, arg, "--once")) {
            opts.once = true;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            focus.debug = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            return error.Version;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.Help;
        } else {
            return error.InvalidArgs;
        }
    }
    return opts;
}

fn printReading(out: *std.Io.Writer, r: battery.Reading) !void {
    try printSide(out, "left", r.left);
    try out.writeAll("   ");
    try printSide(out, "right", r.right);
    try out.writeAll("\n");
    try out.flush();
}

fn printSide(out: *std.Io.Writer, name: []const u8, s: battery.SideReading) !void {
    if (s.level) |lvl| {
        try out.print("{s} {d:>3}% ({s})", .{ name, lvl, s.status.label() });
    } else {
        try out.print("{s}   ?% ({s})", .{ name, s.status.label() });
    }
}

test {
    _ = @import("focus.zig");
    _ = @import("battery.zig");
    _ = @import("device.zig");
    _ = @import("layer.zig");
    _ = @import("porthint.zig");
    _ = @import("config.zig");
}
