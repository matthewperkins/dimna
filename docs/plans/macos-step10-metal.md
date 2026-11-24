# Plan: the Mac's renderer, with Metal (macOS port, step 10)

Read `docs/plans/README.md` first, then `docs/plans/macos-port.md` (the overview: the
decisions, the Mac latency table, "The layout aimed at", "Steps done"), then the header of
`src/gui/gpu.zig`: it is the contract this step fulfils. `src/gui/gpu_vulkan.zig` and
`src/gui/shaders/*.vert|frag` are the implementation to match in meaning;
`tools/metal-latency/metal_latency.m` is a working Metal layer with sync off from this
project.

Step 9a left `src/gui/gpu_metal.zig` as a stand-in whose `init` fails. This step makes it
real. A second agent writes the AppKit window (`docs/plans/macos-step9b-appkit-window.md`)
at the same time in another worktree; the two meet at `Target`, fixed below. The lead
joins them afterwards. On Linux nothing may change.

The owner's decision: the Mac's picture need not match Linux's pixel for pixel. It must
show the same things in the same places with the same meaning (every trace, the min/max
envelope, sweep and scroll, review, fills, text), and nothing may be slower than it has
to be.

## Where you work

On the owner's Mac (Apple silicon, macOS 27), in the git worktree you are given, on its
own branch off `macos-port`. Zig 0.17.1 is `~/.local/opt/zig-aarch64-macos-0.17.1/zig`
(not on `PATH`). Only the Command Line Tools are installed: there is **no `metal` shader
compiler** (`xcrun -f metal` fails), so shaders are Metal Shading Language source embedded
in the program and compiled when the `Gpu` is made (say how long that takes; it must
fail with the compiler's message, not silently).

The owner has allowed windows on this laptop, but this step should need almost none:
render **offscreen** to a texture and read it back. If you do open a window for a check
(a throwaway host like the latency probe's), keep it open for seconds and leave none
behind. Not allowed: USB; sound; `sudo`; installing anything; SSH; anything that needs a
permission prompt (Screen Recording, Accessibility: no screenshots of the screen; if a
prompt appears, stop what caused it and report); asking macOS for fonts that are not
installed. Temporary files: `T=$(mktemp -d /private/tmp/dimna-s10-XXXXXX)`, and before any
`rm -rf`: `set -u`, the variable quoted, a `case` check on that prefix. Do not rewrite
history (no reset, amend or rebase, also of your own commits).

## What to build

1. **An Objective-C shim** (`src/gui/metal_shim.m`, `src/gui/metal_shim.h`, compiled by
   `build.zig` for macOS only, with ARC), with a small C interface that `gpu_metal.zig`
   calls: devices, buffers, textures, pipelines, one frame's encoding. No Objective-C
   runtime calls from Zig. Keep the per-frame path free of allocation and of anything
   autoreleased piling up on a thread that has no pool (the drawing threads are plain
   threads: give each frame its pool). Frameworks: Metal, QuartzCore.
2. **`Gpu`**, to the contract in `gpu.zig`'s header, every function and field:
   - The mapped slices (`hist`, `rev`, `rev_cols`, `row_gains`, `dec`) are the contents
     of shared-storage buffers: written by the CPU, seen by the next frame with no copy
     and no flush. Say what limits there are on a buffer's size and what `createHistory`
     does at `least_samples` when the wanted size cannot be had, as Vulkan's does.
   - The shaders: `traces` and `text`, in MSL, doing what the GLSL does. `TraceParams` is
     an `extern struct` whose layout the stored test output prints: do not reorder it;
     match it in the shader and assert the size and offsets at compile time.
   - `draw`: panels, then fills, then text, one render pass, as Vulkan's. It gets the
     layer's next drawable, puts it in `target.drawable`, calls `before_present(context)`
     immediately before presenting, presents, and clears the slot. It must not wait for
     a free drawable longer than a moment: return `.busy` instead (say how; Metal's
     `nextDrawable` blocks by default). `.out_of_date` when the layer's size no longer
     matches what `resize` set. `wait_render`/`last_render_ns` as on Linux.
   - `mode` (`gpu.PresentMode`): `immediate`, `mailbox` and `auto` free-run with the
     layer's display sync off (the overview's fullscreen sync-off row is the target);
     `fifo` turns it on. Say what `auto` means on the Mac and why. Set what else lowers
     latency (the number of drawables, presenting without a transaction) and say what you
     set, with the reason.
   - `resize(width, height)` sets the layer's drawable size in pixels; `pixelSize` reads
     back what it is.
   - `share`: one device and one compiled shader library for the process's three
     renderers, if that is what sharing should mean on the Mac; say.
   - `textFont`/`createText`: the atlas texture, and the dirty region copied up before
     the frame that uses it, as on Linux.
3. **An offscreen target for tests**: a `Gpu` that draws into a texture of a given size
   instead of a layer (a second way to make one, used only by tests; the per-frame path
   the program uses must not pay for it), and a way to read the pixels back.
4. **`build.zig`**: the shim and its frameworks, for macOS only, in one small block inside
   `addMacGui` (the other agent adds a block there too; keep yours contiguous and
   commented so the two merge easily).
5. **Tests** in `gpu_metal.zig`, run by `gui-test` on the Mac; they need a Metal device
   but no window, so they run in a plain `zig build test` (skip, saying so, if there is
   no device). Offscreen, with data whose picture is known:
   - one channel at a constant value draws a horizontal line at the row that value maps
     to; a step draws a vertical join; a sine stays inside its row's band; many channels
     land in their own rows in order; `first_ch`, `rows`, `cols`, `span`, `lsb_per_row`,
     `half_px`, `gain`, row gains, `future` and sweep `phase` each change the picture the
     way the GLSL says (one check each, by the pixels);
   - the three sources agree where they overlap: samples, buckets (`dec_mask`), and
     review columns (`from_columns`) of the same data light the same pixel columns;
   - the ring wraps: data written across the end of `hist` draws continuously;
   - fills land on exactly their rectangles with their colours, over the panels; text
     quads land where their vertices say, over the fills, with the atlas's coverage, and
     a glyph added to the atlas after the first frame appears in the next;
   - `createHistory` twice with different shapes, `createReview`, `destroyReview`,
     `deinit`: no leak (use the testing allocator for the Zig side; say how you checked
     the Metal side).
   Where a check needs to know what Vulkan draws, read the GLSL; you cannot run it here.
6. **A speed check**, offscreen, not a test that can fail on a busy machine: the time to
   encode and for the GPU to finish a frame like the rig's (32 channels in 2 panels at
   3456 x 2234, and 128 channels), median and worst over a few hundred frames, reported.

## Where the two agents meet

`gpu_metal.zig` declares exactly this (replacing the stand-in's empty struct):

    /// What a window hands the GPU (`Window.gpuTarget`).
    pub const Target = struct {
        /// The window's CAMetalLayer.
        layer: *anyopaque,
        /// Where `Gpu.draw` puts the frame's drawable (an id<CAMetalDrawable>, not
        /// retained for the window) before it calls `before_present`, and null again
        /// after presenting. The window's `beforePresent(tag)` reads it to attach its
        /// report of when the frame reached the screen.
        drawable: *?*anyopaque,
    };

The window creates the layer and sets its `contentsScale`; the `Gpu` sets its device,
pixel format, drawable size, display sync and whatever else is the renderer's. The
window's stand-in in your branch returns `.{}` from `gpuTarget`: change that one line so
it compiles (the stand-in cannot make a window anyway) and say what you put.

You may write a throwaway host (like the latency probe: a window with a layer) to see
your renderer present on the screen and to time it; keep it out of the program and out
of the commit unless it belongs under `tools/`.

## Evidence

1. `zig build test --summary all` and `zig build test -Dgui=false --summary all`: counts,
   against 149 passed and 4 skipped, and 139 of 140; your new tests by name.
2. The speed check's figures, and the shader compile time at `init`.
3. If you used a throwaway host: frames per second and the presented-time latency with
   sync off, fullscreen and windowed, against the overview's table.
4. `zig-out/bin/dimna --sim 32,16` still exits 1 at the window stand-in, opening nothing.
5. Linux untouched: `git diff macos-port -- src/gui/gpu_vulkan.zig src/gui/shaders
   src/gui/window_wayland.zig` empty; `zig build -Dgui=false -Dtarget=x86_64-linux-gnu
   --release=safe` before and after gives the same binary (`cmp`); `zig fmt --check src
   build.zig`.

Break it on purpose, once each: a `TraceParams` field read at the wrong offset in the
shader; the ring mask off by one; the fills drawn before the panels; the atlas's dirty
region not copied. Say which test notices each.

## Files you may change

`src/gui/gpu_metal.zig`; new `src/gui/metal_shim.m`, `src/gui/metal_shim.h`, and the MSL
sources under `src/gui/shaders/` (new files; the GLSL and `.spv` files are not touched);
`src/gui/window_appkit.zig` (the one line in `gpuTarget`); `build.zig` (your block in
`addMacGui`); `src/gui/gpu.zig` (the header's backend line only); `docs/install.md`
(macOS section). A line elsewhere that must change for the Mac: do not edit it; list it
with the reason. Anything else: stop and report.

## Done means

The evidence and the break-it results are in your report; every decision the plan left to
you, with its reason; every place the Mac's picture knowingly differs from Linux's; what
the window's agent and the lead must know to join the two; the work committed on your
branch, not pushed; the worktree clean; no window, process or temporary folder of yours
left.
