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

    const dimna = b.addModule("dimna", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = c_api.createModule() }},
    });
    dimna.linkLibrary(liboni);

    const headless = b.addExecutable(.{
        .name = "dimna-headless",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/headless.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "dimna", .module = dimna }},
        }),
    });
    b.installArtifact(headless);

    const run = b.addRunArtifact(headless);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("headless", "Run the headless acquisition tool").dependOn(&run.step);

    // ---- dimna: the GUI. Wayland directly (zig-wayland), Vulkan (vulkan-zig). ----
    // The protocol XMLs are vendored (vendor/wayland-protocols), so a build needs neither
    // wayland-protocols nor wayland-scanner installed, and no distribution's older copy.
    const scanner = Scanner.create(b, .{
        .wayland_xml = b.path("vendor/wayland-protocols/wayland.xml"),
        .wayland_protocols = b.path("vendor/wayland-protocols"),
    });
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
    // The pointer's shape (a hand over something that can be dragged). The protocol also
    // names tablet tools, so the tablet protocol has to be known to the scanner.
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.generate("wp_cursor_shape_manager_v1", 1);
    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    // Vulkan bindings are generated from the vendored registry (vendor/vulkan/vk.xml);
    // -Dvk-registry=<path> overrides it, e.g. with the system's vulkan-headers copy.
    const vk_registry: std.Build.LazyPath = if (b.option([]const u8, "vk-registry", "Path to vk.xml (default: vendor/vulkan/vk.xml)")) |path|
        .{ .cwd_relative = path }
    else
        b.path("vendor/vulkan/vk.xml");
    const vulkan = b.dependency("vulkan", .{ .registry = vk_registry }).module("vulkan-zig");

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
    // stb_image / stb_image_write (vendor/stb): the colour scheme's image and the swatch.
    const stb_c = b.addTranslateC(.{ .root_source_file = b.path("vendor/stb/stb.h"), .target = target, .optimize = optimize });
    const stb_mod = stb_c.createModule();
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
        m.addImport("dimna", dimna);
        m.addImport("wayland", wayland);
        m.addImport("vulkan", vulkan);
        m.addImport("gui_c", gui_c_mod);
        m.addImport("stb", stb_mod);
        m.addCSourceFile(.{
            .file = b.path("vendor/stb/stb_impl.c"),
            .flags = &.{ "-DNDEBUG", "-w", "-fno-sanitize=undefined" },
        });
        m.addIncludePath(b.path("vendor/stb"));
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
    // Shaders: GLSL compiled to SPIR-V and embedded. The compiled .spv files are checked in
    // next to the sources, so building dimna does not need glslc. When glslc is installed
    // and a source is newer than its .spv, that shader is compiled during the build and the
    // fresh result is embedded instead. `zig build shaders` rewrites the checked-in .spv
    // files from the sources (needs glslc); the GUI tests fail while a checked-in .spv
    // differs from what glslc makes of its source.
    const shader_names = [_][]const u8{ "traces.vert", "traces.frag", "text.vert", "text.frag" };
    const glslc_path = b.findProgram(.{ .names = &.{"glslc"} });
    const shader_check_src = b.addWriteFiles();
    const shader_check_mod = b.createModule(.{
        .root_source_file = shader_check_src.add("shader_check.zig", shader_check_zig),
        .target = target,
        .optimize = optimize,
    });
    const shader_opts = b.addOptions();
    shader_opts.addOption(bool, "glslc_available", glslc_path != null);
    shader_check_mod.addOptions("shader_opts", shader_opts);
    const update_shaders = b.addUpdateSourceFiles();
    inline for (shader_names) |name| {
        const checked_in = b.path("src/gui/shaders/" ++ name ++ ".spv");
        var compiled: ?std.Build.LazyPath = null;
        if (glslc_path) |glslc_exe| {
            const glslc = b.addSystemCommand(&.{ glslc_exe, "--target-env=vulkan1.2", "-O", "-o" });
            compiled = glslc.addOutputFileArg(name ++ ".spv");
            glslc.addFileArg(b.path("src/gui/shaders/" ++ name));
            update_shaders.addCopyFileToSource(compiled.?, "src/gui/shaders/" ++ name ++ ".spv");
        }
        const embedded = if (compiled != null and sourceNewer(b, "src/gui/shaders/" ++ name, "src/gui/shaders/" ++ name ++ ".spv"))
            compiled.?
        else
            checked_in;
        gui_mod.addAnonymousImport(name ++ ".spv", .{ .root_source_file = embedded });
        gui_test_mod.addAnonymousImport(name ++ ".spv", .{ .root_source_file = embedded });
        // For the up-to-date test: the checked-in file, and what glslc makes of the source
        // (the checked-in file again when there is no glslc; the test then skips).
        shader_check_mod.addAnonymousImport("checked_in/" ++ name ++ ".spv", .{ .root_source_file = checked_in });
        shader_check_mod.addAnonymousImport("compiled/" ++ name ++ ".spv", .{ .root_source_file = compiled orelse checked_in });
    }
    b.step("shaders", "Rebuild the checked-in src/gui/shaders/*.spv with glslc").dependOn(&update_shaders.step);
    const gui = b.addExecutable(.{ .name = "dimna", .root_module = gui_mod });
    b.installArtifact(gui);
    const run_gui = b.addRunArtifact(gui);
    run_gui.step.dependOn(b.getInstallStep());
    run_gui.addPassthruArgs();
    b.step("gui", "Run the GUI").dependOn(&run_gui.step);

    const tests = b.addTest(.{ .root_module = dimna });
    const gui_tests = b.addTest(.{ .name = "gui-test", .root_module = gui_test_mod });
    const test_step = b.step("test", "Run unit tests (the core's and the GUI's)");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(gui_tests).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "shader-check", .root_module = shader_check_mod })).step);
}

/// True when `source` was modified after `spv`, or `spv` cannot be read (both relative to
/// the build root). Read at configure time.
fn sourceNewer(b: *std.Build, source: []const u8, spv: []const u8) bool {
    const io = b.graph.io;
    const src_stat = b.root.root_dir.handle.statFile(io, source, .{}) catch return true;
    const spv_stat = b.root.root_dir.handle.statFile(io, spv, .{}) catch return true;
    return src_stat.mtime.nanoseconds > spv_stat.mtime.nanoseconds;
}

/// The shader up-to-date test, generated here so it needs no file outside the build.
const shader_check_zig =
    \\const std = @import("std");
    \\const opts = @import("shader_opts");
    \\
    \\test "checked-in shaders match what glslc makes of the sources" {
    \\    if (!opts.glslc_available) return error.SkipZigTest;
    \\    inline for (.{ "traces.vert", "traces.frag", "text.vert", "text.frag" }) |name| {
    \\        const checked_in = @embedFile("checked_in/" ++ name ++ ".spv");
    \\        const compiled = @embedFile("compiled/" ++ name ++ ".spv");
    \\        std.testing.expectEqualSlices(u8, compiled, checked_in) catch |err| {
    \\            std.debug.print("src/gui/shaders/{s}.spv is stale: run `zig build shaders` and commit it\n", .{name});
    \\            return err;
    \\        };
    \\    }
    \\}
    \\
;
