const std = @import("std");

/// The release tarballs: `zig build release` builds both, whatever -Dtarget says.
/// glibc 2.34 covers Rocky/Alma/RHEL 9, Ubuntu 22.04, Debian 12 and everything newer.
const release_targets = [_]struct { query: []const u8, name: []const u8, note: []const u8 }{
    .{
        .query = "x86_64-linux-gnu.2.34",
        .name = "x86_64-linux-gnu",
        .note =
        \\Needs glibc 2.34 or newer. dimna needs the Wayland client library, the Vulkan
        \\loader, FreeType, fontconfig, xkbcommon and ALSA (the distribution's own).
        \\dimna-headless needs only the C library.
        ,
    },
    .{
        .query = "x86_64-linux-musl",
        .name = "x86_64-linux-musl",
        .note =
        \\For a musl system (Void musl). dimna is linked dynamically and needs the same
        \\libraries as the glibc build, the system's musl builds of them; it was linked
        \\against glibc-built copies and has not been run on a musl system.
        \\dimna-headless is static: it runs on any x86_64 Linux, but cannot dlopen, so
        \\`--driver d3xx` (liboni's ft600 driver on FTDI's D3XX) is not available; the
        \\default `--driver usb` is built in.
        ,
    },
};

/// The files of packaging/ that a release carries: what install-user.sh needs, the files the
/// .deb and .rpm install (nfpm.yaml names them by their place in the release), and the
/// workflow's test script, so it can be run against an unpacked tarball. install-desktop.sh
/// and dimna-launch.sh stay out: they are for a source checkout's zig-out/bin.
const release_packaging = [_][]const u8{
    "install-user.sh",
    "dimna-desktop-launch.sh",
    "dimna.desktop",
    "60-dimna-ft60x.rules",
    "99-dimna-realtime.conf",
    "nfpm.yaml",
    "package-postinstall.sh",
    "package-postremove.sh",
    "ci-test-install.sh",
    "icon/ICON-CREDITS.md",
    "icon/dimna-icon.svg",
    "icon/dimna-32.png",
    "icon/dimna-48.png",
    "icon/dimna-64.png",
    "icon/dimna-128.png",
    "icon/dimna-256.png",
    "sim-config/dimna/config.toml",
};

/// The highest glibc symbol version a release binary may need (packaging/check-release.sh).
const release_max_glibc = "2.34";

const shader_names = [_][]const u8{ "traces.vert", "traces.frag", "text.vert", "text.frag" };

/// What every build of the programs shares, whatever its target.
const Inputs = struct {
    wayland: *std.Build.Module,
    vulkan: *std.Build.Module,
    /// The SPIR-V embedded for each of `shader_names`.
    shaders: [shader_names.len]std.Build.LazyPath,
    /// FreeType's and fontconfig's header folders (pkg-config --cflags-only-I).
    gui_include_dirs: []const []const u8,
};

/// The folders Zig searches for headers and libraries when it builds for this machine.
/// Zig searches none of them by itself for any other target (a glibc version given, or
/// musl), so a release build is handed them explicitly.
const SystemDirs = struct {
    include: []const []const u8,
    lib: []const []const u8,
};

/// The core and dimna-headless for one target.
const Core = struct {
    dimna: *std.Build.Module,
    headless: *std.Build.Step.Compile,
};

/// dimna and the GUI's test module for one target.
const Gui = struct {
    gui: *std.Build.Step.Compile,
    gui_test_mod: *std.Build.Module,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Acquisition code ships with safety checks on (bounds, overflow, unreachable).
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    // -Dgui=false: the core and dimna-headless alone. Nothing of the GUI is set up: no
    // pkg-config, no Wayland scanner, no Vulkan binding, no shaders, no glslc lookup, and
    // zig-wayland and vulkan-zig (lazy dependencies) are not fetched.
    const with_gui = b.option(bool, "gui", "Build the GUI, dimna (default: true; false: the core and dimna-headless only)") orelse true;
    const vk_registry_option = b.option([]const u8, "vk-registry", "Path to vk.xml (default: vendor/vulkan/vk.xml)");

    // Made first, so that `zig build --help` lists the steps in the order it always has.
    const headless_step = b.step("headless", "Run the headless acquisition tool");
    const shaders_step = b.step("shaders", "Rebuild the checked-in src/gui/shaders/*.spv with glslc");
    const gui_step = b.step("gui", "Run the GUI");
    const test_step = b.step("test", if (with_gui) "Run unit tests (the core's and the GUI's)" else "Run unit tests (the core's; -Dgui=false)");
    const release_step = b.step("release", "Build the release tarballs (x86_64 glibc 2.34 and musl) into zig-out/release");

    // ---- The normal build: -Dtarget (this machine by default). ----
    const core = addCore(b, target, optimize, null);
    b.installArtifact(core.headless);

    const run = b.addRunArtifact(core.headless);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    headless_step.dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = core.dimna });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    if (!with_gui) {
        // Said plainly, rather than half-working.
        for ([_]*std.Build.Step{ shaders_step, gui_step, release_step }) |step| {
            step.dependOn(&b.addFail(b.fmt("`zig build {s}` needs the GUI; it is not set up with -Dgui=false", .{step.name})).step);
        }
        return;
    }

    // ---- macOS: dimna without a window or a GPU yet (see addMacGui). ----
    if (target.result.os.tag == .macos) {
        const gui = addMacGui(b, target, optimize, core.dimna);
        b.installArtifact(gui.gui);
        const run_gui = b.addRunArtifact(gui.gui);
        run_gui.step.dependOn(b.getInstallStep());
        run_gui.addPassthruArgs();
        gui_step.dependOn(&run_gui.step);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "gui-test", .root_module = gui.gui_test_mod })).step);
        // The Vulkan shaders and the release tarballs are Linux's.
        shaders_step.dependOn(&b.addFail("`zig build shaders` compiles the Vulkan shaders, which macOS does not use").step);
        release_step.dependOn(&b.addFail("`zig build release` builds the Linux tarballs; it runs on Linux").step);
        return;
    }

    // ---- dimna: the GUI. Wayland directly (zig-wayland), Vulkan (vulkan-zig). ----
    // Both are lazy dependencies, fetched only for a build with the GUI. While one is not
    // fetched yet, lazyImport and lazyDependency return null; the build runner then fetches
    // what was asked for and runs this function again.
    const wayland: ?*std.Build.Module = if (b.lazyImport(@This(), "wayland")) |zig_wayland| waylandBindings(b, zig_wayland.Scanner) else null;

    // Vulkan bindings are generated from the vendored registry (vendor/vulkan/vk.xml);
    // -Dvk-registry=<path> overrides it, e.g. with the system's vulkan-headers copy.
    const vk_registry: std.Build.LazyPath = if (vk_registry_option) |path|
        .{ .cwd_relative = path }
    else
        b.path("vendor/vulkan/vk.xml");
    const vulkan_dep = b.lazyDependency("vulkan", .{ .registry = vk_registry }) orelse return;
    const vulkan = vulkan_dep.module("vulkan-zig");
    if (wayland == null) return;

    // FreeType's headers live in their own directory; ask pkg-config where.
    var gui_include_dirs: std.ArrayList([]const u8) = .empty;
    {
        const flags = b.run(&.{ "pkg-config", "--cflags-only-I", "freetype2", "fontconfig" });
        var it = std.mem.tokenizeAny(u8, flags, " \n");
        while (it.next()) |f| {
            if (std.mem.startsWith(u8, f, "-I")) gui_include_dirs.append(b.allocator, f[2..]) catch @panic("OOM");
        }
    }

    // Shaders: GLSL compiled to SPIR-V and embedded. The compiled .spv files are checked in
    // next to the sources, so building dimna does not need glslc. When glslc is installed
    // and a source is newer than its .spv, that shader is compiled during the build and the
    // fresh result is embedded instead. `zig build shaders` rewrites the checked-in .spv
    // files from the sources (needs glslc); the GUI tests fail while a checked-in .spv
    // differs from what glslc makes of its source.
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
    var shaders: [shader_names.len]std.Build.LazyPath = undefined;
    inline for (shader_names, &shaders) |name, *embedded| {
        const checked_in = b.path("src/gui/shaders/" ++ name ++ ".spv");
        var compiled: ?std.Build.LazyPath = null;
        if (glslc_path) |glslc_exe| {
            const glslc = b.addSystemCommand(&.{ glslc_exe, "--target-env=vulkan1.2", "-O", "-o" });
            compiled = glslc.addOutputFileArg(name ++ ".spv");
            glslc.addFileArg(b.path("src/gui/shaders/" ++ name));
            update_shaders.addCopyFileToSource(compiled.?, "src/gui/shaders/" ++ name ++ ".spv");
        }
        embedded.* = if (compiled != null and sourceNewer(b, "src/gui/shaders/" ++ name, "src/gui/shaders/" ++ name ++ ".spv"))
            compiled.?
        else
            checked_in;
        // For the up-to-date test: the checked-in file, and what glslc makes of the source
        // (the checked-in file again when there is no glslc; the test then skips).
        shader_check_mod.addAnonymousImport("checked_in/" ++ name ++ ".spv", .{ .root_source_file = checked_in });
        shader_check_mod.addAnonymousImport("compiled/" ++ name ++ ".spv", .{ .root_source_file = compiled orelse checked_in });
    }
    shaders_step.dependOn(&update_shaders.step);

    const inputs: Inputs = .{
        .wayland = wayland.?,
        .vulkan = vulkan,
        .shaders = shaders,
        .gui_include_dirs = gui_include_dirs.items,
    };

    const gui = addGui(b, target, optimize, inputs, null, core.dimna);
    b.installArtifact(gui.gui);
    const run_gui = b.addRunArtifact(gui.gui);
    run_gui.step.dependOn(b.getInstallStep());
    run_gui.addPassthruArgs();
    gui_step.dependOn(&run_gui.step);

    const gui_tests = b.addTest(.{ .name = "gui-test", .root_module = gui.gui_test_mod });
    test_step.dependOn(&b.addRunArtifact(gui_tests).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "shader-check", .root_module = shader_check_mod })).step);

    // ---- zig build release: one tarball per entry of release_targets, in zig-out/release. ----
    addRelease(b, release_step, inputs, &.{
        b.path("vendor/liboni/LICENSE"),
        b.path("vendor/stb/LICENSE"),
        b.dependency("wayland", .{}).path("LICENSE"),
        vulkan_dep.path("LICENSE"),
    });
}

/// The Wayland bindings: zig-wayland's scanner run over the protocols dimna uses.
fn waylandBindings(b: *std.Build, comptime Scanner: type) *std.Build.Module {
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
    return b.createModule(.{ .root_source_file = scanner.result });
}

/// The core (the `dimna` module, with liboni) and dimna-headless for one target.
/// `system_dirs` is null for the normal build and set for a release build.
fn addCore(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    system_dirs: ?SystemDirs,
) Core {
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

    // onidriverloader.h includes <execinfo.h>, which is glibc's and which musl lacks; liboni
    // uses nothing from it. For musl an empty one stands in, so vendor/liboni stays as it is.
    if (target.result.abi.isMusl()) {
        const shim = b.addWriteFiles();
        _ = shim.add("execinfo.h", "/* Empty: liboni includes execinfo.h but uses nothing from it. */\n");
        liboni_mod.addIncludePath(shim.getDirectory());
        c_api.addIncludePath(shim.getDirectory());
    }

    const dimna_options: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = c_api.createModule() }},
    };
    // The normal build's module is also offered to packages that depend on this one.
    const dimna = if (system_dirs == null) b.addModule("dimna", dimna_options) else b.createModule(dimna_options);
    dimna.linkLibrary(liboni);
    // macOS: the power assertion that keeps the machine awake while acquiring
    // (src/os_darwin.zig, IOPMAssertionCreateWithName) and the strings it takes.
    if (target.result.os.tag == .macos) {
        dimna.linkFramework("IOKit", .{});
        dimna.linkFramework("CoreFoundation", .{});
    }

    const headless = b.addExecutable(.{
        .name = "dimna-headless",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/headless.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "dimna", .module = dimna }},
        }),
    });
    return .{ .dimna = dimna, .headless = headless };
}

/// dimna and the GUI's test module for one target, over the core's `dimna` module.
/// `system_dirs` is null for the normal build (Zig then searches this machine's folders
/// itself, for the native target) and set for a release build.
fn addGui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    inputs: Inputs,
    system_dirs: ?SystemDirs,
    dimna: *std.Build.Module,
) Gui {
    // Two modules over the same files: the program (main.zig) and its unit tests
    // (tests.zig), with the same imports and libraries so the test binary compiles the
    // same code. The tests only link these libraries; none of them opens a window, a
    // Vulkan instance or a sound device.
    const gui_c = b.addTranslateC(.{ .root_source_file = b.path("src/gui/c.h"), .target = target, .optimize = optimize });
    for (inputs.gui_include_dirs) |dir| gui_c.addIncludePath(.{ .cwd_relative = dir });
    // After Zig's own libc headers (glibc 2.34's or musl's), never before them.
    if (system_dirs) |dirs| for (dirs.include) |dir| gui_c.addAfterIncludePath(.{ .cwd_relative = dir });
    // Fedora and RHEL's multilib freetype2/freetype/config/ftconfig.h includes glibc's
    // <bits/wordsize.h> to pick ftconfig-64.h; musl has no such header. For musl a stand-in
    // gives the word size (the release builds on Rocky 9).
    if (target.result.abi.isMusl()) {
        const shim = b.addWriteFiles();
        _ = shim.add("bits/wordsize.h",
            \\/* Stand-in for glibc's bits/wordsize.h, which Fedora/RHEL's multilib ftconfig.h includes. */
            \\#ifndef __WORDSIZE
            \\#define __WORDSIZE 64
            \\#endif
            \\
        );
        gui_c.addAfterIncludePath(shim.getDirectory());
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
        m.addImport("wayland", inputs.wayland);
        m.addImport("vulkan", inputs.vulkan);
        m.addImport("gui_c", gui_c_mod);
        m.addImport("stb", stb_mod);
        m.addCSourceFile(.{
            .file = b.path("vendor/stb/stb_impl.c"),
            .flags = &.{ "-DNDEBUG", "-w", "-fno-sanitize=undefined" },
        });
        m.addIncludePath(b.path("vendor/stb"));
        // The system libraries are linked by name (pkg-config gives the flags); a release
        // build searches this machine's library folders for them.
        if (system_dirs) |dirs| for (dirs.lib) |dir| m.addLibraryPath(.{ .cwd_relative = dir });
        m.linkSystemLibrary("wayland-client", .{});
        m.linkSystemLibrary("vulkan", .{});
        // Text: fontconfig finds the font, FreeType rasterizes it.
        m.linkSystemLibrary("freetype2", .{});
        m.linkSystemLibrary("fontconfig", .{});
        // Keys by what they are labelled, whatever the keyboard layout.
        m.linkSystemLibrary("xkbcommon", .{});
        // Sound: ALSA's API (PipeWire serves it on a desktop).
        m.linkSystemLibrary("alsa", .{});
        inline for (shader_names, inputs.shaders) |name, spv| {
            m.addAnonymousImport(name ++ ".spv", .{ .root_source_file = spv });
        }
    }
    const gui = b.addExecutable(.{ .name = "dimna", .root_module = gui_mod });
    // A release links against this machine's copies of the libraries only to resolve dimna's
    // own symbols; at run time the target machine's copies are loaded. This machine's were
    // built against its own (newer) glibc, so they reference versions such as GLIBC_2.38
    // that the 2.34 stubs lack, which lld would otherwise refuse. What dimna itself needs is
    // checked after the link (packaging/check-release.sh). The musl link does not need it:
    // lld does not refuse there (those libraries need libc.so.6, which is not in that link).
    if (system_dirs != null and target.result.abi.isGnu()) gui.linker_allow_shlib_undefined = true;
    return .{ .gui = gui, .gui_test_mod = gui_test_mod };
}

/// dimna and the GUI's test module for macOS, over the core's `dimna` module. The same two
/// modules over the same files as `addGui`, with the Mac's libraries: no Wayland, Vulkan,
/// SPIR-V, fontconfig, xkbcommon or ALSA. FreeType through pkg-config (Homebrew's, which a
/// Mac then needs installed); fonts are found with Core Text and sound goes through Core
/// Audio, both called through their C interfaces, declared in the Zig files that use them
/// (src/gui/fontfind_coretext.zig, src/gui/audio_coreaudio.zig). The window and the GPU are
/// stand-ins that fail (src/gui/window_appkit.zig, src/gui/gpu_metal.zig): AppKit and Metal
/// are the next step, and neither is linked yet.
fn addMacGui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dimna: *std.Build.Module,
) Gui {
    const gui_c = b.addTranslateC(.{ .root_source_file = b.path("src/gui/c_darwin.h"), .target = target, .optimize = optimize });
    const flags = b.run(&.{ "pkg-config", "--cflags-only-I", "freetype2" });
    var it = std.mem.tokenizeAny(u8, flags, " \n");
    while (it.next()) |f| {
        if (std.mem.startsWith(u8, f, "-I")) gui_c.addIncludePath(.{ .cwd_relative = f[2..] });
    }
    const gui_c_mod = gui_c.createModule();
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
        m.addImport("gui_c", gui_c_mod);
        m.addImport("stb", stb_mod);
        m.addCSourceFile(.{
            .file = b.path("vendor/stb/stb_impl.c"),
            .flags = &.{ "-DNDEBUG", "-w", "-fno-sanitize=undefined" },
        });
        m.addIncludePath(b.path("vendor/stb"));
        // Text: Core Text finds the font, FreeType rasterizes it.
        m.linkSystemLibrary("freetype2", .{});
        m.linkFramework("CoreText", .{});
        m.linkFramework("CoreFoundation", .{});
        // Sound: the default output device through an output audio unit.
        m.linkFramework("AudioToolbox", .{});
        m.linkFramework("CoreAudio", .{});
    }
    const gui = b.addExecutable(.{ .name = "dimna", .root_module = gui_mod });
    return .{ .gui = gui, .gui_test_mod = gui_test_mod };
}

/// `zig build release`: for each of `release_targets`, zig-out/release/dimna-<version>-<name>/
/// (bin/dimna, bin/dimna-headless, packaging/, tools/dimna_read.py, licenses/, README.md,
/// BUILD-INFO, COMMIT, CHECK) and the same folder as dimna-<version>-<name>.tar.gz. Needs tar, gzip, readelf and
/// objdump; and git for COMMIT (it says "unknown" without).
fn addRelease(b: *std.Build, release_step: *std.Build.Step, inputs: Inputs, licences: []const std.Build.LazyPath) void {
    const version = @import("build.zig.zon").version;

    // This machine's header and library folders, as Zig would search them for a native
    // build (Debian's multiarch folders included), keeping only those that exist.
    const native = std.zig.system.NativePaths.detect(b.graph.arena, b.graph.io, &b.graph.host.result, &b.graph.environ_map) catch @panic("cannot list the system's folders");
    const system_dirs: SystemDirs = .{
        .include = existingDirs(b, native.include_dirs.items),
        .lib = existingDirs(b, native.lib_dirs.items),
    };

    // The commit the release was built from. Runs on every `zig build release`.
    const describe = b.addSystemCommand(&.{ "sh", "-c", "git describe --always --dirty --abbrev=12 2>/dev/null || echo unknown" });
    describe.setCwd(b.path("."));
    describe.has_side_effects = true;
    const commit = describe.captureStdOut(.{});

    for (release_targets) |rt| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = rt.query }) catch @panic("bad release target");
        const release_target = b.resolveTargetQuery(query);
        const core = addCore(b, release_target, .ReleaseSafe, system_dirs);
        const gui = addGui(b, release_target, .ReleaseSafe, inputs, system_dirs, core.dimna);
        const dir = b.fmt("dimna-{s}-{s}", .{ version, rt.name });

        const stage = b.addWriteFiles();
        _ = stage.addCopyFile(gui.gui.getEmittedBin(), b.fmt("{s}/bin/dimna", .{dir}));
        _ = stage.addCopyFile(core.headless.getEmittedBin(), b.fmt("{s}/bin/dimna-headless", .{dir}));
        // What an installation needs, named one by one: the folder on disk may hold other
        // files (icon candidates, files of other work) that are not part of a release.
        for (release_packaging) |f| {
            _ = stage.addCopyFile(b.path(b.fmt("packaging/{s}", .{f})), b.fmt("{s}/packaging/{s}", .{ dir, f }));
        }
        _ = stage.addCopyFile(b.path("README.md"), b.fmt("{s}/README.md", .{dir}));
        // The reference reader: verifies a recording (ci-test-install.sh runs it).
        _ = stage.addCopyFile(b.path("tools/dimna_read.py"), b.fmt("{s}/tools/dimna_read.py", .{dir}));
        for (licences, licence_names) |licence, name| {
            _ = stage.addCopyFile(licence, b.fmt("{s}/licenses/{s}", .{ dir, name }));
        }
        _ = stage.add(b.fmt("{s}/licenses/README", .{dir}), licences_readme);
        _ = stage.addCopyFile(commit, b.fmt("{s}/COMMIT", .{dir}));
        _ = stage.add(b.fmt("{s}/BUILD-INFO", .{dir}), b.fmt(
            \\dimna {s}
            \\target {s} (baseline x86-64 CPU), ReleaseSafe
            \\zig {s}
            \\commit: see COMMIT; the binaries' libraries: see CHECK
            \\
            \\{s}
            \\
        , .{ version, rt.query, @import("builtin").zig_version_string, rt.note }));

        // The binaries' NEEDED libraries and glibc symbol versions. A binary that needs any
        // other library, or a newer glibc, fails the release; the report goes in as CHECK.
        const check = b.addSystemCommand(&.{"sh"});
        check.addFileArg(b.path("packaging/check-release.sh"));
        check.addArg(release_max_glibc);
        check.addFileArg(gui.gui.getEmittedBin());
        check.addFileArg(core.headless.getEmittedBin());
        _ = stage.addCopyFile(check.captureStdOut(.{}), b.fmt("{s}/CHECK", .{dir}));

        const tar = b.addSystemCommand(&.{ "tar", "--sort=name", "--owner=0", "--group=0", "--numeric-owner", "-czf" });
        const tarball = tar.addOutputFileArg(b.fmt("{s}.tar.gz", .{dir}));
        tar.addArg("-C");
        tar.addDirectoryArg(stage.getDirectory());
        tar.addArg(dir);

        release_step.dependOn(&b.addInstallDirectory(.{
            .source_dir = stage.getDirectory().path(b, dir),
            .install_dir = .{ .custom = "release" },
            .install_subdir = dir,
        }).step);
        release_step.dependOn(&b.addInstallFileWithDir(tarball, .{ .custom = "release" }, b.fmt("{s}.tar.gz", .{dir})).step);
    }
}

/// The licence files in a release, by the order addRelease is given them.
const licence_names = [_][]const u8{ "liboni.LICENSE", "stb.LICENSE", "zig-wayland.LICENSE", "vulkan-zig.LICENSE" };

const licences_readme =
    \\Licences of the code in these binaries
    \\
    \\liboni.LICENSE       liboni (MIT), vendor/liboni, built into both programs
    \\stb.LICENSE          stb_image and stb_image_write (public domain or MIT), in dimna
    \\zig-wayland.LICENSE  zig-wayland (MIT), its Wayland bindings are in dimna
    \\vulkan-zig.LICENSE   vulkan-zig (MIT), its Vulkan bindings are in dimna
    \\
    \\The bindings are generated from the Wayland protocol XMLs and the Vulkan registry
    \\(vk.xml); their licences are in the files' own headers (vendor/ in the source tree).
    \\
    \\MISSING: dimna's own licence. dimna has no licence file yet.
    \\
;

fn existingDirs(b: *std.Build, dirs: []const []const u8) []const []const u8 {
    var kept: std.ArrayList([]const u8) = .empty;
    for (dirs) |dir| {
        var d = std.Io.Dir.openDirAbsolute(b.graph.io, dir, .{}) catch continue;
        d.close(b.graph.io);
        kept.append(b.allocator, dir) catch @panic("OOM");
    }
    return kept.items;
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
