const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Acquisition code ships with safety checks on (bounds, overflow, unreachable).
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // liboni (MIT, vendored from oers, which carries one patch: oni_set_driver_search_dir).
    // It dlopen()s libonidriver_<name>.so at runtime, so nothing here links FTDI's library.
    const liboni_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    liboni_mod.addCSourceFiles(.{
        .root = b.path("vendor/liboni"),
        .files = &.{ "oni.c", "onix.c", "onidriverloader.c" },
        // As upstream release builds: asserts off. No UBSan trap in third-party C.
        .flags = &.{ "-DNDEBUG", "-w", "-fno-sanitize=undefined" },
    });
    liboni_mod.addIncludePath(b.path("vendor/liboni"));
    const liboni = b.addLibrary(.{ .name = "oni", .root_module = liboni_mod });

    const c_api = b.addTranslateC(.{ .root_source_file = b.path("src/c.h"), .target = target, .optimize = optimize });
    c_api.addIncludePath(b.path("vendor/liboni"));

    const oez = b.addModule("oez", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = c_api.createModule() }},
    });
    oez.linkLibrary(liboni);

    const headless = b.addExecutable(.{
        .name = "oez-headless",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/headless.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "oez", .module = oez }},
        }),
    });
    b.installArtifact(headless);

    const run = b.addRunArtifact(headless);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("headless", "Run the headless acquisition tool").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = oez });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
