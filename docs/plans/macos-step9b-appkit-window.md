# Plan: the Mac's window, with AppKit (macOS port, step 9b)

Read `docs/plans/README.md` first, then `docs/plans/macos-port.md` (the overview: the
decisions, the Mac latency table, "The layout aimed at", "Steps done"), then the header of
`src/gui/window.zig`: it is the contract this step fulfils. `src/gui/window_wayland.zig`
is the implementation to match in meaning; `tools/metal-latency/metal_latency.m` is a
working AppKit window with a Metal layer, sync off, fullscreen, from this project.

Step 9a left `src/gui/window_appkit.zig` as a stand-in whose `init` fails. This step makes
it real. A second agent writes the Metal renderer (`docs/plans/macos-step10-metal.md`) at
the same time in another worktree; the two meet at `Target`, fixed below. On Linux
nothing may change.

## Where you work

On the owner's Mac (Apple silicon, macOS 27), in the git worktree you are given, on its
own branch off `macos-port`. Zig 0.17.1 is `~/.local/opt/zig-aarch64-macos-0.17.1/zig`
(not on `PATH`). The owner has allowed windows on this laptop, fullscreen included. They
may be using it: keep each window open only as long as its check needs (seconds), never
leave one behind, and do not open windows in a loop without a pause.

Not allowed: USB (nothing may enumerate, open or talk to a device); sound; `sudo`;
installing anything; SSH; synthetic input sent to the system (`CGEventPost`, AppleScript,
`osascript`, anything needing the Accessibility or Screen Recording permission, any
permission prompt at all: if one appears, stop what caused it and report); asking macOS
for fonts that are not installed. Temporary files:
`T=$(mktemp -d /private/tmp/dimna-s9b-XXXXXX)`, and before any `rm -rf`: `set -u`, the
variable quoted, a `case` check on that prefix. Do not rewrite history (no reset, amend or
rebase, also of your own commits).

## What to build

1. **An Objective-C shim** (`src/gui/appkit_shim.m`, `src/gui/appkit_shim.h`, compiled by
   `build.zig` for macOS only, with ARC), with a small C interface that
   `window_appkit.zig` calls. No Objective-C runtime calls from Zig. Frameworks: AppKit,
   QuartzCore (and Metal only for the layer's type, if needed). No nib, no bundle: the
   program is a plain executable, so it sets its activation policy itself so that its
   windows come forward and take the keyboard, and builds a minimal menu (Quit with
   Cmd-Q, which closes the windows as the close button does).
2. **`run(body, args)`**: AppKit owns the process's main thread. `run` starts `body` on a
   new thread, runs the application's loop on the main thread, and returns `body`'s
   result (status or error) when `body` has ended, with the loop stopped cleanly. The
   test in `window.zig` ("run returns what the body returns") must pass on the Mac, in the
   test binary, repeatedly in one process (it calls `run` four times).
3. **`Window`**, to the contract in `window.zig`'s header:
   - `init`/`deinit` from any thread (the display's, the control window's and the tiles'
     threads each make their own): the asking thread hands the work to the main thread
     and waits. Before `run` is running (tests, or a caller on the main thread itself)
     this must not deadlock: say what happens then.
   - The window's content is a view backed by a `CAMetalLayer`, which the shim creates.
   - Events are received on the main thread and handed to the window's own thread:
     `pump(timeout_ms)` waits up to the timeout for some and takes them. Nothing on the
     main thread may wait for a window's thread. The cost of that hand-over per event
     must be small and must not allocate per event at a high event rate (scrolling and
     pointer motion come at hundreds per second).
   - `width`, `height`, `pointer_x`, `pointer_y` in **pixels** of the layer's drawable
     (backing pixels, origin top left, y down), also when the window moves between a
     Retina and a non-Retina display. The layer's `contentsScale` follows the screen; the
     drawable's size is set by the GPU (`Gpu.resize`), not by you.
   - Keys as the contract says: one `Key` per press, no repeat, by the character the key
     has in the user's layout without modifiers; `text` is what the press typed. Decide
     and say how dead keys and input methods behave (the Linux backend has no compose
     support either; do not build an input method client).
   - Scroll in the contract's units and signs (a wheel click about 15, positive down or
     right), for both a wheel and a trackpad, and independent of the user's "natural
     scrolling" setting only if that is what Linux does: check what Wayland delivers and
     say what you chose. Pinch from the trackpad's magnify gesture as a ratio per take.
   - `frame_ready`: read `src/gui/pacing.zig` and the loops in `main.zig`, `control.zig`
     and `tiles.zig` to see what they need of it. The Mac display free-runs with sync off
     (overview, after the latency table); the control window and the tiles should draw at
     the screen's refresh, not faster. Choose the mechanism (a display link, or another)
     and say why.
   - `beforePresent(tag)` and `takePresented()`: see "Where the two agents meet".
     `presentsOnNowClock()` is true if the times are on the clock `dimna.os.nowNs` reads
     (the overview says which clock that is on the Mac); check it rather than assume.
   - `monitorName(i)` and `fullscreenOn(name)`: the screens by the name macOS shows the
     user. Fullscreen in the way the latency probe found fastest (overview table); say
     which, and what happens to the menu bar and the Dock.
   - `declareLowLatency`, `preferTearing`: return what is true on the Mac.
   - `setTitle`, `setCursor` (grab and grabbing are the open and closed hand).
   - `closed` on the close button and Cmd-Q.
4. **`build.zig`**: the shim and its frameworks, for macOS only, in one small block inside
   `addMacGui` (the other agent adds a block there too; keep yours contiguous and
   commented so the two merge easily).
5. **Tests** in `window_appkit.zig`, run by `gui-test` on the Mac. Those that open a
   window run only when `DIMNA_TEST_WINDOW=1` (so a plain `zig build test` opens
   nothing). With it set: a window opens and closes; its size is reported in pixels and
   `resized` is true at start; events **delivered inside the process** (built `NSEvent`s
   handed to the window or the view directly, not posted to the system) come out of
   `takeInput` with the contract's meaning: a key with and without Shift, a named key, a
   key held (one press only), text, the three buttons, pointer position in pixels with y
   down, scroll signs and size, magnify, and what `takeInput` resets and keeps; three
   windows on three threads pump at once and each gets only its own events; `deinit`
   leaves no window. Without the variable: the pure parts (key mapping from key codes and
   characters, scroll scaling, the event queue between threads) are tested without AppKit.

## Where the two agents meet

`gpu_metal.zig` declares, and you use, exactly this (the stand-in has an empty struct;
change it to this in your branch, the other agent does the same):

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

So `beforePresent(tag)` runs on the drawing thread with the drawable in that slot: it adds
a presented handler to it that records `(tag, presentedTime)` for `takePresented`, with
the refresh period of the screen the window is on. A drawable that was never shown
reports a time of 0: say what you do with it. The handler runs on a thread of the
system's.

Until the renderer exists you need something that presents: write a **test-only** helper
in your shim or test (a few lines: take the layer's next drawable, clear it to a colour,
present) to check `beforePresent`/`takePresented` and the times, with sync on and off,
windowed and fullscreen. It is not the renderer and stays out of the program.

## Evidence

1. `zig build test --summary all` and `zig build test -Dgui=false --summary all`: counts,
   against 149 passed and 4 skipped, and 139 of 140.
2. `DIMNA_TEST_WINDOW=1` run of `gui-test`: each window test's result.
3. With the test-only presenter, for windowed and fullscreen, sync on and off: frames per
   second, and the time from `beforePresent` to the reported presentation time (median,
   worst), set against the overview's table; whether the times are on the `nowNs` clock.
4. The hand-over's cost: time from the main thread receiving an event to `pump`
   returning with it (median, worst over a few thousand in-process events), and that a
   burst of 10,000 events loses none that matter (say what is merged or dropped, if any).
5. `zig-out/bin/dimna --sim 32,16`: now gets as far as the GPU stand-in and exits 1 with
   its message; say what appeared on the screen, if anything, and that nothing is left.
   `--help` exit 0, a bad argument exit 2, a monitor that does not exist: status and
   message as on Linux (it lists the monitors).
6. Linux untouched: `git diff macos-port -- src/gui/window_wayland.zig
   src/gui/gpu_vulkan.zig` and the other Linux backends empty; `zig build -Dgui=false
   -Dtarget=x86_64-linux-gnu --release=safe` before and after gives the same binary
   (`cmp`); `zig fmt --check src build.zig`.

Break it on purpose, once each: the y axis not flipped (which test notices); key repeat
let through; `run` dropping the body's status.

## Files you may change

`src/gui/window_appkit.zig`; new `src/gui/appkit_shim.m`, `src/gui/appkit_shim.h`;
`src/gui/gpu_metal.zig` (the `Target` declaration only); `build.zig` (your block in
`addMacGui`); `src/gui/window.zig` (the header's "macOS (to come)" wording and the
backend line only); `docs/install.md` (macOS section). A line elsewhere that must change
for the Mac: do not edit it; list it with the reason. Anything else: stop and report.

## Done means

The evidence and the break-it results are in your report; every decision the plan left to
you, with its reason; what the renderer's agent and the lead must know to join the two;
the work committed on your branch, not pushed; the worktree clean; no window, process or
temporary folder of yours left.
