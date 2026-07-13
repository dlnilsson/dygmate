const std = @import("std");

/// Falls back to the package version; release builds override it with the git
/// tag via `-Dversion=<tag>` so `--version` reports the tagged release.
const default_version = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const serial_dep = b.dependency("serial", .{});
    const serial_mod = serial_dep.module("serial");

    const version = b.option([]const u8, "version", "Version string reported by --version") orelse default_version;
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    const build_options_mod = build_options.createModule();

    const test_step = b.step("test", "Run unit tests");

    // Default build: CLI + tray for the host (or -Dtarget), installed normally.
    const bins = addBinaries(b, target, optimize, serial_mod, build_options_mod, null);

    const run_cmd = b.addRunArtifact(bins.cli);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run dygmate").dependOn(&run_cmd.step);

    if (bins.tray) |tray| {
        const run_tray = b.addRunArtifact(tray);
        run_tray.step.dependOn(b.getInstallStep());
        const run_tray_name = if (target.result.os.tag == .windows) "run-tray" else "run-tray-linux";
        b.step(run_tray_name, "Run dygmate-tray").dependOn(&run_tray.step);

        // Tray unit tests (icon rendering, D-Bus marshalling).
        const tray_tests = b.addTest(.{ .root_module = tray.root_module });
        const run_tray_tests = b.addRunArtifact(tray_tests);
        b.step("test-tray", "Run tray unit tests").dependOn(&run_tray_tests.step);
        test_step.dependOn(&run_tray_tests.step);
    }

    const tests = b.addTest(.{ .root_module = bins.cli.root_module });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // `release`: cross-build Windows + Linux binaries (ReleaseSmall) into
    // zig-out/<os>/ in a single command.
    const release_step = b.step("release", "Cross-build Windows + Linux binaries (ReleaseSmall)");
    const release_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .x86_64, .os_tag = .linux },
    };
    for (release_targets) |q| {
        const rt = b.resolveTargetQuery(q);
        const dir = @tagName(q.os_tag.?);
        _ = addBinaries(b, rt, .ReleaseSmall, serial_mod, build_options_mod, .{ .step = release_step, .dir = dir });
    }
}

const ReleaseInstall = struct {
    step: *std.Build.Step,
    dir: []const u8,
};

const Binaries = struct {
    cli: *std.Build.Step.Compile,
    tray: ?*std.Build.Step.Compile,
};

/// Create the CLI (`dygmate`) and, where supported, the tray (`dygmate-tray`)
/// for the given target. When `release` is null the artifacts install to the
/// default prefix; otherwise they install into `zig-out/<dir>/` and attach to
/// the release step instead of the default install.
fn addBinaries(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    serial_mod: *std.Build.Module,
    build_options_mod: *std.Build.Module,
    release: ?ReleaseInstall,
) Binaries {
    const cli = b.addExecutable(.{
        .name = "dygmate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "serial", .module = serial_mod },
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    installBinary(b, cli, release);

    const tray_root: ?[]const u8 = switch (target.result.os.tag) {
        .windows => "src/tray_windows.zig",
        .linux => "src/tray_linux.zig",
        else => null,
    };
    var tray: ?*std.Build.Step.Compile = null;
    if (tray_root) |root| {
        const t = b.addExecutable(.{
            .name = "dygmate-tray",
            .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "serial", .module = serial_mod },
                    .{ .name = "build_options", .module = build_options_mod },
                },
            }),
        });
        if (target.result.os.tag == .windows) {
            // GUI subsystem (no console) + the Win32 GUI libraries.
            t.subsystem = .Windows;
            t.root_module.linkSystemLibrary("user32", .{});
            t.root_module.linkSystemLibrary("shell32", .{});
            t.root_module.linkSystemLibrary("gdi32", .{});
            t.root_module.linkSystemLibrary("advapi32", .{});
            t.root_module.linkSystemLibrary("ole32", .{});
        }
        installBinary(b, t, release);
        tray = t;
    }

    return .{ .cli = cli, .tray = tray };
}

fn installBinary(b: *std.Build, exe: *std.Build.Step.Compile, release: ?ReleaseInstall) void {
    if (release) |r| {
        const inst = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = r.dir } },
        });
        r.step.dependOn(&inst.step);
    } else {
        b.installArtifact(exe);
    }
}
