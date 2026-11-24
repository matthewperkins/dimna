# Plan: the GPU and the window behind neutral surfaces (macOS port, step 4)

Read `docs/plans/README.md` first, then `docs/plans/macos-port.md` (the overview; this is
its step 4: read "Where the code stands", "The layout aimed at" and "Rules for every step
on Linux" in full). This is a refactoring plan (rule 8): a move. The Linux program must do
exactly what it does now, frame for frame.

You work on the rig over SSH, as `docs/plans/macos-step1-build.md` describes under "Where
you work" (same worktree, same branch, same rules: never the board, never the GUI binary,
no windows). Also: start builds, tests and anything timed with `chrt -o 0 nice -n -16
<command>` (an SSH session on the rig is at idle priority); temporary files in
`T=$(mktemp -d /tmp/dimna-s4-XXXXXX)`, and before any `rm -rf`: `set -u`, the variable
quoted, and a `case "$T" in /tmp/dimna-s4-??????)` check.

## Why

`src/gui/gpu.zig` is Vulkan on a Wayland surface and `src/gui/window.zig` is a Wayland
window. The Mac needs a second implementation of each (Metal, AppKit), chosen at compile
time as `os.zig` and `usb.zig` choose theirs. Today the callers (`main.zig`, `control.zig`,
`tiles.zig`, `display.zig`, `session.zig`, `pacing.zig`, `pipeline.zig`, `args.zig`,
`script.zig`, `notes.zig`, `ui.zig`) import those two files directly, and a few Vulkan and
Wayland things show through:

- `gpu.swapchain == .null` (a Vulkan handle) in `main.zig`, `control.zig`, `tiles.zig`;
- `gpu.extent.width` / `.height` (a `vk.Extent2D`) in `display.zig`, `main.zig`,
  `control.zig`, `tiles.zig`;
- `gpu.Target` holding a Wayland display and surface, built by three callers from
  `win.display` and `win.surface`;
- `Gpu.DrawResult` named through the backend's type in `pacing.zig`;
- `win.outputs`, `win.num_outputs`, `Output.name()` read by `main.zig` for the "no such
  monitor" message;
- `win.presentation_clock`, a Linux clock id, passed to the pacer, which warns if it is
  not 1;
- one raw Linux clock call inside `gpu.zig` (the `wait_render` timing).

## What to build

- **`src/gui/gpu_vulkan.zig`**: today's `gpu.zig`, moved with `git mv`, its code unchanged
  apart from what is listed here. **`src/gui/gpu.zig`** becomes the shared surface: the
  types every backend and caller agree on (`TraceParams`, `PanelDraw`, `Fill`,
  `PixelRect`, `PresentMode`, `DrawResult`, `column_region`, `from_columns`, `max_rows`,
  `max_gain_panels`), and the choice of backend:

      const backend = switch (builtin.os.tag) {
          .linux => @import("gpu_vulkan.zig"),
          else => @compileError("dimna has no GPU backend for this system yet"),
      };
      pub const Gpu = backend.Gpu;
      pub const Target = backend.Target;

  The shared types are declared once, in `gpu.zig`, and the backend uses them from there
  (so a second backend cannot come to differ). `TraceParams` keeps its field names and
  order: the stored display output prints them, and the shader's layout matches them.
  Its header comment states what a backend must offer, taken from what the callers use
  (list every function and every field read or written from outside, with one line on
  what each means: the mapped slices `hist`, `rev`, `rev_cols`, `row_gains`, `dec`, the
  counts `nch`, `hist_cap`, `rev_cap`, `wait_render`, `last_render_ns`; "written by the
  CPU, never read back, visible to the next frame without a flush").
- **Neutral queries on `Gpu`**, replacing the two leaks: one for "there is no swapchain
  yet" and one for the drawable size in pixels (`width`, `height` as `u32`). Small enough
  that the optimizer inlines them; the callers' logic is otherwise untouched. Tests that
  build a `Gpu` as `undefined` and set `hist_cap` must still compile and pass unchanged.
- **`src/gui/window_wayland.zig`**: today's `window.zig`, moved with `git mv`.
  **`src/gui/window.zig`** becomes the shared surface: `Key`, `Cursor`, `Input`,
  `Presented` (declared once, there), and `pub const Window = backend.Window`, chosen as
  above. Its header comment states the contract, from what the callers rely on (the seam
  survey found, and you must check against the code): which `Input` fields `takeInput`
  resets and which stay; no key repeat; keys by the unmodified character of the layout;
  scroll in units of about 15 per wheel click, positive down or right; pinch as a ratio
  per take; pointer positions and `width`/`height` in the same unit as the GPU's size;
  the plain fields callers read and write (`width`, `height`, `resized`, `closed`,
  `frame_ready`); `beforePresent(tag)` called immediately before the frame is presented;
  `takePresented` valid until the next `pump`.
- **The window hands the GPU its target**: a function on `Window` that returns the
  backend's `Target`; the three callers stop touching `win.display` and `win.surface`.
- **The monitor list**: an accessor on `Window` for the names of the monitors (for
  `main.zig`'s message), instead of the three fields.
- **The presentation clock**: the pacer needs to know only whether presentation times are
  on the clock `clock.nowNs` reads. Give it that as a bool from the window; the warning it
  logs when they are not keeps its text (it prints the clock's number: keep that reachable
  for the message).
- **The raw clock call in the GPU file** goes through `dimna.os.nowNs` (the same clock).
- **`src/os.zig`'s test**: its list of exceptions follows the renames (`gui/window.zig`
  becomes `gui/window_wayland.zig`; `gui/gpu.zig` drops out if the Vulkan file no longer
  calls the system, else becomes `gui/gpu_vulkan.zig`). The stale comment there about USB
  "becoming" a backend may be corrected while you are on those lines.
- **`src/gui/tests.zig`**: lists the files with tests; follow the renames so every test
  that ran still runs (compare the names of the tests run before and after).
- Mentions of the two files by name in `README.md` and `docs/*.md` (not `docs/plans/`):
  update where the text is about the file.

## What must not change

Everything under "Rules for every step on Linux" in the overview. In particular for this
step: `pump` (flush, `poll` on the Wayland socket, dispatch) is not touched; the
listeners and the order they are attached in are not touched; `beforePresent` still runs
immediately before `vkQueuePresentKHR`; callers still write `frame_ready` and `resized`
directly; the draw function, the swapchain, the present mode choice and the shaders are
not touched; no lock, queue or copy appears anywhere; no log line changes.

## Evidence

Before changing anything, and again after:

1. `zig build test --summary all`: the same counts; and the list of test names run by the
   `gui-test` binary before and after (run the built binary directly if the build prints
   no names), identical apart from the file prefix of moved tests.
2. The stored GUI outputs untouched (`git status` under `src/gui/testdata`).
3. `zig build --release=safe` before and after into two prefixes; compare the `dimna`
   binaries function by function as step 3's report did (addresses and compiler-numbered
   names normalised, `gpu.` against `gpu_vulkan.` and `window.` against `window_wayland.`
   renamed): no function added or removed other than the new accessors if they were not
   inlined (say which), and every function the same instructions, or each difference shown
   and explained. Pay particular attention to `main.main`, `Gpu.draw`, `Gpu.resize`,
   `Window.pump`, `Window.beforePresent`, the control and tiles loops, `Pacer.presented`
   and `Pacer.due`.
4. `zig build release` passes its CHECK; `zig build test -Dgui=false --summary all`.
5. `zig fmt --check src build.zig`.
6. `git log --follow --oneline` reaches the history of both moved files.

Break it on purpose, once each: a raw `std.os.linux` call left in `gpu_vulkan.zig` after
it has dropped out of the exceptions (the `os` test fails), or, if it stays an exception,
one added to the facade `gpu.zig`; a field of `TraceParams` reordered (say which test
notices; if none does, say so plainly); the presentation-clock bool inverted (say which
test notices, or that only the log line on the rig would).

What you cannot give, and the lead will get on the board with the session unlocked:
alternating runs of the build before and after (display latency, best and worst frame,
frames a refresh late, blocks lost, audio).

## Files you may change

`src/gui/gpu.zig` and `src/gui/window.zig` (moved, and written anew as the shared
surfaces), `src/gui/main.zig`, `control.zig`, `tiles.zig`, `display.zig`, `session.zig`,
`pacing.zig`, `pipeline.zig`, `args.zig`, `script.zig`, `notes.zig`, `ui.zig`,
`tile_link.zig`, `tests.zig` (all under `src/gui/`: only the imports and the uses listed
above), `src/os.zig` (its test's list and that comment), `README.md` and `docs/*.md`
(file names only). `build.zig` only if a module's root or an embedded file's name makes it
necessary: say why. Anything else: stop and report.

## Done means

The evidence and the break-it results are in your report; every line of the two moved
files that differs from before is listed; the work is committed on `macos-port` in the
rig's worktree (the GPU and the window as separate commits if that keeps each buildable);
the worktree is clean; nothing of yours is left in `/tmp`.
