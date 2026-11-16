# Plan: dimna on macOS, in this repository

Read `docs/plans/README.md` first; its rules apply. This file is the overview, as
`portability.md` is for the Linux distributions: it fixes the decisions, the layout and the
order. Each step below gets its own plan file (file list, evidence, "done means") when it is
handed out; nothing here is handed out as it stands.

## Goal

dimna builds and runs on macOS from this repository, with the two things the owner cares
about most kept: recordings that are complete and correct, and a display that is as quick
as the Mac allows. The Linux program must not get slower, later or different on the way.

## Decided with the owner (2026-11-15)

- **One repository, a thin platform layer, no framework** (no JUCE, Qt, SDL, GLFW). Each
  platform's code sits behind a narrow interface chosen at compile time
  (`switch (builtin.os.tag)`); everything else is one shared copy.
- **Native Metal on the Mac**, not MoltenVK: a second GPU file beside the Vulkan one, with
  its own shaders in Metal Shading Language.
- **Same behaviour, not same pixels.** The Mac display may look slightly different. What
  must be equal is listed under "What the Metal trace shader must keep". No pixel
  comparison between the two.
- **Objective-C through small shim files** (`.m`, with a C interface, compiled by the
  build), not calls through the Objective-C runtime from Zig.
- **USB on the Mac through IOKit directly**; libusb only if the timed-out-read property
  cannot be had that way.
- **No FTDI D3XX on the Mac.** `--driver d3xx` stays a Linux option; the Mac has the `usb`
  transport only.
- **Apple silicon only.** No Intel Macs, so GPU buffers are shared memory and need no
  flush call after a write.
- **The work is on the branch `macos-port`**, the Linux steps included. An agent works on
  the rig over SSH for the Linux steps (build, tests, `--sim`), under the README's rules:
  never the board, no windows.

## What was measured on the Mac (2026-11-15)

`tools/metal-latency/` (a standalone Objective-C program, not part of the build)
on a MacBook with an M4 and its built-in 60 Hz display, macOS 27.0.1, 4 s per mode. Latency
is from a stamp taken just before drawing to the time the system reports for the frame
(`MTLDrawable.presentedTime`).

| mode | median | 95th percentile | best |
|---|---|---|---|
| window, sync on | 32.0 ms | 32.5 ms | 26.8 ms |
| fullscreen, sync on | 16.4 ms | 16.4 ms | 16.2 ms |
| window, sync off | 7.1 ms | 11.5 ms | 4.7 ms |
| fullscreen, sync off | 5.2 ms | 8.9 ms | 2.4 ms |

- With sync on, `nextDrawable` is held back until the refresh, so drawing "a margin before
  the refresh" (margins of 1 to 8 ms, two and three drawables) gained nothing.
- With sync off, frames are reported shown between refreshes (every 5.5 ms fullscreen).
  The owner ran the fullscreen sync-off mode and saw the moving bar tear, plainly (by eye,
  2026-11-15). So frames do reach the screen mid-scan, as with tearing on Hyprland. Not
  measured: the latency itself by photodiode or high-speed video; the figures are macOS's
  own report.
- Every sync-off run had a worst frame of 34 to 58 ms; not looked into.
- Not tried: a 120 Hz monitor, `CAMetalDisplayLink`, presenting at a chosen time, any load.

So the Mac display will free-run with sync off (dimna's `--free` mode), and the plan
promises "about 5 ms as reported", not the rig's 1.6 to 2 ms.

## Where the code stands

From four read-only surveys of the tree at `8c02d48`, spot-checked against the source.
Nothing was built on the Mac: Zig is not installed there yet.

- **No platform switch exists.** Nothing tests `builtin.os.tag`. `std.os.linux` is used
  directly in the core (`acquisition`, `clock`, `ft600`, `usbfs`, `record`, `review`,
  `pyramid`, `overview`, the test files) and in the GUI (`window`, `gpu`, `audio_out`,
  `notes`, `session`, `shape`, `control`).
- **The build always builds the GUI.** `build.zig:128` runs `pkg-config` for FreeType and
  fontconfig at configure time, and the Wayland scanner and the Vulkan binding run for any
  target. There is no way to build `dimna-headless` alone.
- **The recorder's own path is already portable**: it creates, writes, syncs and renames
  through `std.Io`. The exception is the `current` link (`record.zig:112-120`), made once
  per recording.
- **`dimna-headless` reaches little**: acquisition, board, oni, oni_usb, ft600, usbfs,
  record, ring, sim, source, types. `review`, `pyramid`, `overview` and `clock` are reached
  only from the GUI, but `zig build test` pulls in every file (`root.zig`'s `refAllDecls`).
- **Hot-path system calls are few.** Acquisition thread: one clock read per block and the
  pacing sleep (`oni_usb.zig:313-316`). Display thread: `clock.nowNs` per frame, `pread`
  while reviewing a recording, `munmap` in 2 MiB pieces from the overview store. Everything
  else is start-up or once a second or slower.
- **No portable idiom in the repository yet** for: positional reads, append-mode open,
  swapping a symlink, anonymous zeroed memory, free disk space (`session.zig:398`, a raw
  `statfs` with Linux's struct layout), real-time and idle priority, `mlockall`, the
  Ctrl-C handler, `fork` in `record_test.zig`.
- **USB is one file wide.** Only `ft600.zig` calls `usbfs.zig`. What it relies on: a
  timed-out bulk read returns the bytes that did arrive (`ft600.zig:245-251` uses that
  count to know whether the chip still owes data), one transfer in flight, and the error
  mapping (`NoDevice`, `Stall`, `Busy`, `AccessDenied`, `Io`).
- **The FT600 safety test guards one file.** It counts `.control(` in `ft600.zig`'s own
  source. A new transport file is outside it.
- **Audio splits at an existing queue.** The feeder, resampler, margin and statistics never
  touch ALSA; the output thread does (`audio_out.zig:179-245`). The rate trim steers on the
  queue's `min_fill` only. The code assumes a fixed period in three places (`:213`, `:349`,
  `:358`).
- **Font lookup is three functions**: `font.findFont`, `font.anyFontHas`,
  `shape.Engine.match`. Everything after them takes a file path and a face index. HarfBuzz
  and FriBidi are opened by one hard-coded `.so.0` name each (`shape.zig:117`).
- **Three windows, three threads, three Wayland connections** (`control.zig:4-6` says why).
  The display window is made and pumped on the process's main thread; the tiles window is
  made by its own thread and remade at every acquisition restart (`pipeline.zig:87,102`).
- **No loop is woken by new samples.** The display polls with a wait of 0 to 2 ms
  (`pacing.zig:123-126`), the tiles every 4 ms. That is part of today's latency figure.
- **Window units are taken to be pixels.** There is no HiDPI handling; pointer positions
  and the GPU's extent are compared directly.
- **Vulkan leaks from `gpu.zig` in two places**: `gpu.swapchain == .null` (3 sites) and
  `gpu.extent` (6 sites); and `gpu.Target` holds Wayland pointers. The data handed to the
  GPU (`TraceParams`, `PanelDraw`, `Fill`, `font.Vertex`, the mapped slices) is neutral.
- **The pacer's free-running mode needs no frame callback**: `due()` ignores `frame_ready`
  when `free_ms >= 0`. It needs presentation times only for the latency read-out, in the
  same clock as `clock.nowNs` and the blocks' `acquired_ns`.
- **No test draws.** The GUI's stored outputs are draw lists as text, upstream of the GPU,
  so they check what either backend is given and nothing of what it draws.

## What Zig 0.17.1's standard library does on macOS

Read from the std source and proved with small programs on the Mac (2026-11-15):

- `Io.Clock.awake` reads `CLOCK_UPTIME_RAW` on macOS and `CLOCK_MONOTONIC` on Linux. On
  the Mac it shares its epoch with `mach_absolute_time` (readings back to back agreed
  within 170 ns), which is the base Metal's presentation times use. So latency figures
  stay differences on one clock. Not tested: an actual sleep of the machine.
- `File.sync` is a plain `fsync` on macOS: it does **not** flush the drive's cache. std
  has the constants (`std.c.F.FULLFSYNC`, `BARRIERFSYNC`) but no call that uses them; the
  port calls `std.c.fcntl` itself. Both returned 0 on the Mac's disk.
- `Io.File` has `readPositionalAll(io, buf, offset)` (the `pread`), `Io.Dir` has
  `deleteFile`, `deleteDir`, `symLink`, `symLinkAtomic` (not tried) and a `rename` that
  replaces its destination. There is **no append mode**: open with `std.c.open` and wrap
  the descriptor, or write at the file's size.
- There is no sleep and no clock without an `Io` (`std.Thread.sleep`, `std.time.Timer`
  and `std.posix.nanosleep` are gone). The helpers that have no `Io` use `std.c.nanosleep`
  and `std.c.clock_gettime` on macOS, `std.os.linux` on Linux, in `os.zig`. A 100 µs
  `nanosleep` on the Mac slept 128 µs on average (worst 135), at default priority.
- **`std.os.linux` calls compile for macOS and misbehave silently** (`getpid` returned
  22): only `clock_gettime` fails to compile. So a forgotten raw call is not caught by the
  compiler; step 2 must end with none left outside the Linux backends, checked by a test
  that searches the sources.
- `std.posix.mmap`/`munmap` work on both, including unmapping a 2 MiB piece. `std.c` has
  `getpid`, `mlock`, `sigaction`, `pthread_set_qos_class_self_np`, `mach_absolute_time`;
  it lacks `statfs`, `thread_policy_set` and `clock_gettime_nsec_np` (declare them).
- `Thread.setName` (own thread only), `executableDirPath` and `DynLib.open` work on macOS.

## Baseline on the rig (2026-11-15, branch at `15b65b2`, before any change)

With the board (RHD2132 in 16-channel mode on A, RHD2216 on B, ADC; 40 channels, 30 kHz),
the owner's config, 60 s each. The owner had lifted README rules 1 and 2 until the next
morning.

| figure | value |
|---|---|
| `dimna-headless --seconds 60 --16ch A1 --adc --record`: lost | `dropped=0 gaps=0 bad=0`, `CLEAN`; `dimna_read.py` `OK` |
| delivery delay beyond the quickest block of each second | avg 0.76 ms, worst 2.65 ms |
| USB data transfers | 88,428 in 60 s (1,474 per s), 4,074 bytes each |
| CPU of the 60 s run (user + sys) | 2.4 + 3.4 s |
| recorder: longest write, longest sync | 249 µs, 19.0 ms |
| GUI, fullscreen on DP-2 with `tearing`: frames | 283 to 355 per s; display lost 0 blocks |
| GUI: audio latency | 15.7 to 19.2 ms (queue about 5, device 10.5); gaps 0, dropped 0 |
| GUI: USB data transfers | 88,870 in 60 s |
| tests | 273/275 passed, 2 skipped (133; 139 + 2; shader-check 1) |

**Display latency** needs the rig's session unlocked: under `hyprlock` the compositor sends
no presentation feedback and the log line reads `latency ms avg 0.0`, `refresh 0.00`. An
agent does not unlock the session. The owner unlocked it for the night; then, same binary,
tearing active on DP-2 (`hyprctl monitors`: `activelyTearing: true`), no frame "a refresh
later", no block lost:

| run | per-second average | best frame | worst frame | frames per s | audio |
|---|---|---|---|---|---|
| 45 s, a build running beside it | 1.7 to 2.3 ms typical (2.5 over the run) | 0.7 ms | 13.6 ms | 292 | 16.6 ms |
| 60 s, rig quiet | 2.3 to 2.9 ms (median 2.7) | 1.1 ms | 15.7 ms (per-second worst: median 10.1) | 289 | 15.6 to 18.0 ms (median 16.8) |
| the owner's own log, same day | 1.9 to 2.6 ms | 0.8 to 0.9 ms | | | |

**The runs differ by about half a millisecond among themselves**, with nothing changed.
So a single before/after pair cannot show a change smaller than that: a step is compared
by alternating runs (before, after, before, after; three of each), and what counts is the
ranges overlapping, the best frame, no frame a refresh late and nothing lost.

## Steps done

- **Step 1** (`ee07171`, plan `macos-step1-build.md`): `-Dgui=false`. The default binaries
  are byte-identical to before; on the Mac, `zig build -Dgui=false` now fails only inside
  `src/` (the raw clock call).
- **Step 2** (`5267866`, `243843b`, `171eca3`, plan `macos-step2-os.md`): `src/os.zig`
  and `src/os_linux.zig`; a test that finds raw system calls left elsewhere. In the
  release build every `os` function is inlined; three of the four hot paths are the same
  instructions, the fourth (`Review.process`) differs in register choice. On the board,
  alternating runs of the build before (`cf89744`) and after, 60 s each, session
  unlocked, tearing active in every GUI run:

  | | before | after |
  |---|---|---|
  | headless ×2: lost | `dropped=0 gaps=0 bad=0`, `CLEAN` | the same |
  | delivery delay avg / worst | 0.78 / 2.86, 0.78 / 2.57 ms | 0.76 / 2.70, 0.77 / 2.35 ms |
  | USB data transfers in 60 s | 88,640, 88,608 | 88,429, 88,365 |
  | CPU, user + sys | 2.69 + 3.30, 2.68 + 3.36 s | 2.34 + 3.26, 2.41 + 3.26 s |
  | GUI ×3: per-second latency, median | 2.7, 2.5, 2.5 ms | 2.5, 2.7, 2.7 ms |
  | GUI: best frame | 1.1, 0.6, 0.6 ms | 0.7, 0.7, 0.6 ms |
  | GUI: worst frame | 17.4, 13.8, 20.8 ms | 19.7, 19.5, 18.1 ms |
  | GUI: frames a refresh late; blocks lost | 0; 0 | 0; 0 |
  | GUI: audio latency, median | 17.5, 16.8, 16.8 ms | 17.6, 16.8, 16.9 ms |
  | GUI: audio gaps | 1, 0, 0 | 1, 0, 0 |

  No difference beyond the spread between like runs. One audio gap in the first GUI run
  on each side (none in the earlier baseline runs); not followed up. What no test covers,
  by the agent's own break-it: a sleep that returns at once passes every test, so the USB
  pacing sleep is checked only by the board runs above (the transfer counts would more
  than double without it).

- **Step 3** (`54b217d`, plan `macos-step3-usb.md`): `src/usb.zig`, with `usbfs.zig` moved
  to `src/usb_linux.zig` (one header line added). In both release binaries every loaded
  section is byte-identical to before, and every function is the same instruction for
  instruction (784 and 1,448 functions; only names in the debug sections differ). A new
  test fails if any file but `ft600.zig` calls a control transfer or any file but a USB
  backend defines one. On the board, 60 s headless: `dropped=0 gaps=0 bad=0`, `CLEAN`,
  delivery 0.77 / 2.63 ms, 88,457 transfers, recording `OK`. For a Mac backend to note:
  `ft600.zig`'s test builds its device as `.{ .fd = -1 }`. Left stale on purpose (outside
  the step's file list): the comment at `os.zig`'s test about files that "become" backends,
  `ft600.zig`'s header and `docs/hardware.md`, which still describe the control-transfer
  test as guarding one file.
- **Next, by the owner's choice (2026-11-15):** audio through JACK, `jack-audio.md`, ahead
  of steps 4 to 6.

## The layout aimed at

Names are proposals; the step that makes each file settles its name.

| shared | Linux | macOS |
|---|---|---|
| `src/os.zig`: monotonic clock, sleep, thread priority, memory locking, free disk space, zeroed memory, the `current` link, the interrupt handler | `src/os_linux.zig` | `src/os_darwin.zig` |
| `src/usb.zig`: what `usbfs.zig` offers today | `src/usb_linux.zig` (today's `usbfs.zig`, moved) | `src/usb_darwin.zig` |
| `src/gui/window.zig`: `Key`, `Input`, `Cursor`, `Presented`, and the choice of backend | `window_wayland.zig` | `window_appkit.zig` |
| `src/gui/gpu.zig`: `TraceParams`, `PanelDraw`, `Fill`, `PixelRect`, `PresentMode`, `DrawResult`, the constants, and the choice of backend | `gpu_vulkan.zig`, `shaders/*.vert,*.frag` | `gpu_metal.zig`, `shaders/*.metal` |
| `src/gui/audio_out.zig`: feeder, queue, statistics | `audio_alsa.zig` | `audio_coreaudio.zig` |
| `src/gui/fontfind.zig`: the three lookups | fontconfig | Core Text |

The selection is at compile time, so the Linux build contains no indirect call it does not
have today.

## Rules for every step on Linux (steps 1 to 6)

These are refactoring steps (README rule 8): moves, not rewrites.

- **Must not change:** `pump`'s flush, `poll` on the Wayland socket and dispatch; the
  0 to 2 ms wait and its integer truncation; `beforePresent` running immediately before
  `vkQueuePresentKHR`; one Wayland connection per window thread; which `Input` fields
  `takeInput` resets and which stay; no key repeat; callers writing `frame_ready` and
  `resized` back; the audio output loop's blocking write of one period; the pacing sleep in
  `readStream`; the recorder's order of sync then index.
- **Must not appear on Linux:** a lock, a queue hop or a copy between an event, a block or
  a period and its consumer; a buffered writer where there was a direct write; a sleep or
  timeout computed in other units than before.
- **Evidence an agent gives:** the tests (`zig build test --summary all`, same counts);
  `zig fmt --check`; the stored GUI outputs unchanged; `dimna-headless --sim` recordings
  from before and after verified with `tools/dimna_read.py`; and, where the step is a pure
  move, the binaries compared (`cmp`, as in `portability.md`'s step 3 report), with any
  difference explained.
- **Evidence only the owner can give**, on the rig with the board, before a step is merged:
  the figures below from the same session before and after. Tests do not see timing.

| figure | where it is printed |
|---|---|
| display latency, late frames | the once-a-second log line (`pacing.zig`) |
| audio latency, its queue and device parts, underruns | the audio statistics (`audio_out.zig`, `Shared`) |
| USB delivery delay (average, worst), CPU per 10 s | `dimna-headless` soak, as tabled in `docs/install.md` |
| dropped, gaps, bad | `dimna-headless` summary; must stay 0 |

## Steps

### Linux first, no Mac code

1. **Build: headless without the GUI's inputs.** `pkg-config`, the Wayland scanner, the
   Vulkan binding and the GUI's libraries are needed only when the GUI is built; a way to
   build and test the core alone (an option or a step). The default `zig build` and
   `zig build release` produce the same binaries as before. Files: `build.zig`,
   `docs/install.md`.
2. **`src/os.zig` and the core's raw calls.** One file for what has no portable call
   (list in the layout table), Linux implementation moved in unchanged. File calls that
   `std.Io` already covers (`review.zig`, `notes.zig`, the tests' temporary folders) go
   through it, copying the idioms in `record.zig`. Find out first whether `std.Io` in
   0.17.1 has a positional read; if not, it belongs in `os.zig`. `clock.nowNs` keeps its
   meaning (the clock `Io.Clock.awake` reads) and its test. `record_test.zig`'s write-failure
   test keeps running on Linux; what replaces `fork` elsewhere is decided in step 7, not
   here. Hot paths (above) are named in the step's plan, each with a before/after check.
3. **`src/usb.zig`.** `usbfs.zig` becomes the Linux backend behind the same public
   surface; `ft600.zig`'s clock and sleeps go through `os.zig`. The safety rule is widened
   to match: every control transfer in the core goes through `Ft600.controlTransfer`, and
   the test fails if any core file other than a backend defines, or any file other than
   `ft600.zig` calls, a control transfer. An agent never runs this on the board; the owner
   soaks it.
4. **Neutral GPU and window surfaces.** The shared types move to `gpu.zig` and
   `window.zig` as facades; `swapchain == .null` and `extent` become neutral queries; the
   window hands the GPU its target; the monitor list gets an accessor; the "presentation
   clock is CLOCK_MONOTONIC" check becomes "the same clock as `nowNs`". `TraceParams` keeps
   its field names and order (the stored display output prints them). Tests still build a
   `Gpu` as `undefined` and set `hist_cap`. `gpu_vulkan.zig`'s one Linux clock call goes
   through `os.zig`.
5. **Audio and font seams.** `audio_out.zig` keeps the feeder; the ALSA calls move to
   `audio_alsa.zig` with the output loop as it is. The three font lookups move to
   `fontfind.zig`; the HarfBuzz and FriBidi file names become per-platform lists.
6. **The display loop callable from another thread.** `main.zig`'s set-up, loop and
   teardown become a function that returns the exit status; on Linux `main` calls it on the
   main thread as now. Making and closing a window becomes a request to the window module
   (on Linux, done on the spot by the calling thread, as now), which is what lets the tiles
   window be remade at a restart on the Mac.

Steps 1 to 3 are in order. Steps 4 and 5 can run side by side after step 2 (their file
lists do not overlap); step 6 follows step 4 (both change `main.zig`).

### Mac, no window

7. **The core and `dimna-headless --sim` on macOS.** Zig 0.17.1 on the Mac; a macOS target
   in `build.zig`; `os_darwin.zig`. To be found out and written down, not assumed:
   - what `Io.Clock.awake` reads on macOS and whether Metal's presentation times are on it
     (`clock.zig`'s test is the check);
   - whether `File.sync` is `fsync` or `F_FULLFSYNC`. A plain `fsync` on macOS does not
     flush the drive's cache, so "a crash costs at most the last second" would hold for a
     killed process but not for power loss. Measure what `F_FULLFSYNC` costs once a second
     on five files (`max_sync_us`) before choosing;
   - real-time: a Mach time-constraint policy and QoS class for the acquisition thread (so
     it stays off the efficiency cores), the lowest QoS for the backfill thread; `mlock` of
     the ring in place of `mlockall`, best effort;
   - a power assertion so the machine neither sleeps nor App-Naps while acquiring;
   - the write-failure test without `fork`, or skipped with the gap stated.
   Done: `zig build test` for the core passes on the Mac; `dimna-headless --sim` records and
   `dimna_read.py` verifies; `tools/crash-test.sh` passes; the Linux build is untouched.
8. **`usb_darwin.zig`, with the board.** IOKit called directly through its C interface.
   The property to prove first, on its own: a read that times out reports the bytes that
   arrived. Then discovery by vendor, product and product string, the link speed, the error
   mapping. This is the first step that touches a board from a Mac, so its plan must say
   so explicitly, and the owner is present. Done: a soak of hours with `dropped=0 gaps=0
   bad=0`, the delivery-delay table of `docs/install.md` repeated on the Mac, and a
   recording made on the Mac compared with one from the rig (`tools/dimna_compare.py`).

### Mac, the windows

9. **`window_appkit.zig` and the main thread.** AppKit owns the process's main thread and
   posts events to a queue per window; each window's thread drains it in `pump`, with a
   wake when something is posted (so input is not held until the next timeout). The Mac
   backend converts to what the shared code already expects, so display, tiles, control,
   notes and the scripts stay unchanged:
   - sizes and pointer positions in **pixels** (the backing size), not points;
   - scroll at about 15 per wheel click with Wayland's sign; pinch as a ratio per take;
   - keys by the unmodified character of the user's layout; repeats dropped; text for notes;
   - fullscreen by display name; the hints with no Mac meaning return false.
10. **`gpu_metal.zig` and its shaders.** Sync off and free-running by default; the
    drawable's presented time feeds the pacer as `Presented`. Notes for whoever writes it:
    Metal's y points up (both vertex shaders flip); no push constants (`setVertexBytes`);
    fills become opaque quads drawn after the traces and before the text; fast math off for
    the trace shader; `nextDrawable` blocks where Vulkan's acquire returns `busy`.
11. **`audio_coreaudio.zig` and Core Text lookup.** The render callback reads the same
    queue; it must cope with a varying number of frames per call, which the three
    fixed-period places have to allow for without changing the Linux arithmetic.
12. **Measure and tune on the Mac**: the display's latency line, the audio figures, long
    frames, a 120 Hz monitor if there is one, and the tearing question above.
13. **Packaging**: an `.app` bundle, signing and notarization, the release workflow. Last,
    and only once the program is worth handing to another lab.

## What the Metal trace shader must keep

Statements a test or a careful reading can check; appearance beyond them is free.

- Every sample in the window lies inside its pixel column's drawn range: the range covers
  the minimum and maximum of the samples in the column (from samples, from the 16-sample
  buckets when a column holds 64 samples or more, or from the review columns). No spike is
  lost at any time base.
- It never reads a sample at or after `newest`.
- Scroll and sweep place a column's samples as `traces.vert` does (`phase`, `future`).
- Row k's centre and scale are the same: a value sits at the same height for the same
  `lsb_per_row` and row gain, within the tolerance of the existing threshold-line test
  (`display.zig`, `shaderPixelY`), which must hold for the Metal arithmetic too.
- A trace beyond 1.5 rows is shown as the dashed line at the edge it left by.
- Colour by channel (`theme.trace[(first_ch + row) & 3]` times `gain`); later draws cover
  earlier ones; each panel stays inside its rectangle.
- Frame order: background, panels in order, fills, text.

## Open, for the owner

- (Answered 2026-11-15: Zig 0.17.1 compiles Objective-C itself. `zig cc -fobjc-arc
  tools/metal-latency/metal_latency.m -framework Cocoa -framework Metal -framework
  QuartzCore` built on the Mac with the Command Line Tools' SDK; the binary was not run.
  Whether `build.zig`'s `addCSourceFiles` takes `.m` the same way is still for step 9.)
- (Seen 2026-11-15, first `zig build` on the Mac, unchanged tree: liboni compiles;
  `dimna-headless` fails in `std/os/linux/vdso.zig`, reached from `clock_gettime`; the GUI
  fails at `xkbcommon/xkbcommon.h` in `src/gui/c.h`. As the survey predicted.)
- **The oldest macOS supported.** Until decided: the one on the owner's Mac (27).
- **What the Linux sound output should be** (raised by the owner, 2026-11-15; to settle
  before step 5). Today dimna opens ALSA's `default`, which on the rig is PipeWire, and
  10.5 of the 16.8 ms are on the device's side. Candidates: the sound card opened directly
  (`hw:`), or JACK. JACK, like Core Audio, asks for frames through a callback, so with it
  both platforms would have the same shape and step 5's seam would be "a function that
  fills N frames from the queue" on both. To be measured on the rig before choosing.
- **A hardware monitor through the board's DAC outputs** (raised by the owner, same day):
  the driver can route an electrode to a DAC, with a high-pass and a noise slicer, but
  nothing in the control window, the config file or the command line reaches it. Separate
  from the port; noted here so it is not lost.
- **The board figures on the rig.** Over SSH an agent can build, test and run `--sim`, but
  the timing figures in the table above need the real board streaming and the display on
  the rig's monitor, which README rules 1 and 2 keep from agents. So for each of steps 2 to
  6 either the owner runs the before/after pair, or the owner lifts those rules for a named
  time when no animal is on the rig. To be settled before step 2 is merged.
- **The board on the Mac** (step 8) waits for the owner to bring the laptop to the rig.
  Steps 7 and 9 to 11 do not need it: they run on the simulator.
- **A latency measurement on the Mac that is not macOS's own report** (photodiode or
  high-speed video), for step 12.
- dimna still has no licence file (`portability.md`); notarized builds will want one.

## Not in this plan

Windows, X11, MoltenVK, pixel-for-pixel parity, the Mac App Store, iPadOS.
