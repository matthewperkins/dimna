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
    scanner.generate("wl_output", 4); // v4 gives the connector name (DP-2), to pick a monitor
    scanner.generate("xdg_wm_base", 2);
    scanner.generate("wp_presentation", 1);
    scanner.generate("zwp_pointer_gestures_v1", 1);
    scanner.addSystemProtocol("staging/tearing-control/tearing-control-v1.xml");
    scanner.generate("wp_tearing_control_manager_v1", 1);
    scanner.addSystemProtocol("staging/content-type/content-type-v1.xml");
    scanner.generate("wp_content_type_manager_v1", 1);
    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    // Vulkan bindings are generated from the system's registry (vulkan-headers).
    const vk_registry = b.option([]const u8, "vk-registry", "Path to vk.xml") orelse "/usr/share/vulkan/registry/vk.xml";
    const vulkan = b.dependency("vulkan", .{
        .registry = std.Build.LazyPath{ .cwd_relative = vk_registry },
    }).module("vulkan-zig");

    // Two modules over the same files: the program (main.zig) and its unit tests
    // (tests.zig), with the same imports and libraries so the test binary compiles the
    // same code. The tests only link these libraries; none of them opens a window, a
    // Vulkan instance or a sound device.
    const gui_c = b.addTranslateC(.{ .root_source_file = b.path("src/gui/c.h"), .target = target, .optimize = optimize });
    {
        // FreeType's headers live in their own directory; ask pkg-config where.
        const flags = b.run(&.{ "pkg-config", "--cflags-only-I", "freetype2", "fontconfig" });
        var it = std.mem.tokenizeAny(u8, flags, " \n");
        while (it.next()) |f| {
            if (std.mem.startsWith(u8, f, "-I")) gui_c.addIncludePath(.{ .cwd_relative = f[2..] });
        }
    }
    const gui_c_mod = gui_c.createModule();
    const gui_mod = b.createModule(.{
        .root_source_file = b.path("src/gui/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const gui_test_mod = b.createModule(.{
        .root_source_file = b.path("src/gui/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for ([_]*std.Build.Module{ gui_mod, gui_test_mod }) |m| {
        m.addImport("oez", oez);
        m.addImport("wayland", wayland);
        m.addImport("vulkan", vulkan);
        m.addImport("gui_c", gui_c_mod);
        m.linkSystemLibrary("wayland-client", .{});
        m.linkSystemLibrary("vulkan", .{});
        // Text: fontconfig finds the font, FreeType rasterizes it.
        m.linkSystemLibrary("freetype2", .{});
        m.linkSystemLibrary("fontconfig", .{});
        // Keys by what they are labelled, whatever the keyboard layout.
        m.linkSystemLibrary("xkbcommon", .{});
        // Sound: ALSA's API (PipeWire serves it on a desktop).
        m.linkSystemLibrary("alsa", .{});
    }
    // Shaders: GLSL compiled to SPIR-V by glslc (shaderc) and embedded.
    inline for (.{ "traces.vert", "traces.frag", "text.vert", "text.frag" }) |name| {
        const glslc = b.addSystemCommand(&.{ "glslc", "--target-env=vulkan1.2", "-O", "-o" });
        const spv = glslc.addOutputFileArg(name ++ ".spv");
        glslc.addFileArg(b.path("src/gui/shaders/" ++ name));
        gui_mod.addAnonymousImport(name ++ ".spv", .{ .root_source_file = spv });
        gui_test_mod.addAnonymousImport(name ++ ".spv", .{ .root_source_file = spv });
    }
    const gui = b.addExecutable(.{ .name = "oez", .root_module = gui_mod });
    b.installArtifact(gui);
    const run_gui = b.addRunArtifact(gui);
    run_gui.step.dependOn(b.getInstallStep());
    run_gui.addPassthruArgs();
    b.step("gui", "Run the GUI").dependOn(&run_gui.step);

    const tests = b.addTest(.{ .root_module = oez });
    const gui_tests = b.addTest(.{ .name = "gui-test", .root_module = gui_test_mod });
    const test_step = b.step("test", "Run unit tests (the core's and the GUI's)");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(gui_tests).step);
}
