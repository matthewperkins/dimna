const std = @import("std");
const Scanner = @import("wayland").Scanner;

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

    // ---- oez: the GUI. Wayland directly (zig-wayland), Vulkan (vulkan-zig). ----
    const scanner = Scanner.create(b, .{});
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("stable/presentation-time/presentation-time.xml");
    scanner.addSystemProtocol("unstable/pointer-gestures/pointer-gestures-unstable-v1.xml");
    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_seat", 5);
    scanner.generate("wl_output", 2); // referenced by surface and presentation events
    scanner.generate("xdg_wm_base", 2);
    scanner.generate("wp_presentation", 1);
    scanner.generate("zwp_pointer_gestures_v1", 1);
    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    // Vulkan bindings are generated from the system's registry (vulkan-headers).
    const vk_registry = b.option([]const u8, "vk-registry", "Path to vk.xml") orelse "/usr/share/vulkan/registry/vk.xml";
    const vulkan = b.dependency("vulkan", .{
        .registry = std.Build.LazyPath{ .cwd_relative = vk_registry },
    }).module("vulkan-zig");

    const gui_mod = b.createModule(.{
        .root_source_file = b.path("src/gui/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "oez", .module = oez },
            .{ .name = "wayland", .module = wayland },
            .{ .name = "vulkan", .module = vulkan },
        },
    });
    gui_mod.linkSystemLibrary("wayland-client", .{});
    gui_mod.linkSystemLibrary("vulkan", .{});
    // Shaders: GLSL compiled to SPIR-V by glslc (shaderc) and embedded.
    inline for (.{ "traces.vert", "traces.frag" }) |name| {
        const glslc = b.addSystemCommand(&.{ "glslc", "--target-env=vulkan1.2", "-O", "-o" });
        const spv = glslc.addOutputFileArg(name ++ ".spv");
        glslc.addFileArg(b.path("src/gui/shaders/" ++ name));
        gui_mod.addAnonymousImport(name ++ ".spv", .{ .root_source_file = spv });
    }
    const gui = b.addExecutable(.{ .name = "oez", .root_module = gui_mod });
    b.installArtifact(gui);
    const run_gui = b.addRunArtifact(gui);
    run_gui.step.dependOn(b.getInstallStep());
    run_gui.addPassthruArgs();
    b.step("gui", "Run the GUI").dependOn(&run_gui.step);

    const tests = b.addTest(.{ .root_module = oez });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
