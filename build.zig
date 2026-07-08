const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const serial_dep = b.dependency("serial", .{});
    const serial_mod = serial_dep.module("serial");

    // CLI: dygma-battery
    const exe = b.addExecutable(.{
        .name = "dygma-battery",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "serial", .module = serial_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run dygma-battery");
    run_step.dependOn(&run_cmd.step);

    // Tray app: dygma-battery-tray (Windows only, GUI subsystem — no console).
    if (target.result.os.tag == .windows) {
        const tray = b.addExecutable(.{
            .name = "dygma-battery-tray",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tray.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "serial", .module = serial_mod },
                },
            }),
        });
        tray.subsystem = .Windows;
        tray.root_module.linkSystemLibrary("user32", .{});
        tray.root_module.linkSystemLibrary("shell32", .{});
        tray.root_module.linkSystemLibrary("gdi32", .{});
        b.installArtifact(tray);

        const run_tray = b.addRunArtifact(tray);
        run_tray.step.dependOn(b.getInstallStep());
        const run_tray_step = b.step("run-tray", "Run dygma-battery-tray");
        run_tray_step.dependOn(&run_tray.step);
    }

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
