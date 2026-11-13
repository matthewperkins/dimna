# Open: known faults and unexplained observations

Things that are known and not fixed, or seen and not understood. Each says how it was
seen, so it can be told apart from a guess. Remove an entry when it is fixed or explained
(the commit says how).

## Known faults, not fixed

- **`oez-headless --record /proc/...` hangs** at 100 % CPU inside `Recorder.create`, with
  no message (probably `createDirPath` under `/proc`). An ordinary bad path
  (`--record <file>/x`) fails cleanly with `NotDir`. Seen by the agent that split
  `headless.zig`, on the simulator, before and after its change.
- **`gpu.zig`, failed set-up calls.** After the device exists, nothing destroys the render
  pass, command pool, semaphores, fence or pipeline objects if a later step of `init`
  fails. `createText` has no `errdefer`s: a failure part-way leaks the atlas, and a failed
  `allocateMemory` leads `deinit` to unmap a null memory. `chooseSurfaceFormat` indexes
  `formats[0]` of a possibly empty list. All found by reading; none has been seen to
  happen (they need Vulkan set-up itself to fail).
- **Keys and text within one frame lose their order** (`notes.zig` `handle`): "/a" in one
  frame opens the note but the "a" goes through as a shortcut; Backspaces are applied
  before the frame's text. Needs input faster than a frame. Seen with a probe test.
- **`oez-headless --seconds 0`** prints a rate of `-nan` or `inf` (0/0 or n/0).
- **`oez-headless --live-test` without `--record` always exits 1**: "ADC off" comes back
  `NeedsRestart`, and only `RecordingActive` is treated as expected. The doc comment says
  to use it with `--record`.
- **View-file error messages say "panel N"** where N counts `[[view]]` tables.
- **After a restart whose panels cannot be made from the config, the fallback panels
  ignore a top-level `mode`** (`main.zig`, `panels.default(&layout, .scroll)`).
- **The published-snapshot reader re-checks the sequence with an acquire load after plain
  loads** (`published.zig`). Correct on x86-64, where this runs; a strict reading of the
  memory model wants a fence before the re-check on weakly ordered CPUs.
- **The write-failure recorder test runs in a forked child**, because the test runner
  counts the recorder's `log.err` as a failure. Logging it as a warning, or a custom test
  runner, would remove the fork.
- **An event queued before the first block can precede the `start` line in `events.tsv`.**
  Sample numbers are right; the format promises no line order.
- **After a restart, the control window reports the view as unsaved** (the panels' rows
  changed), and the quit prompt lists "panel views". Seen on the simulator.
- **There is no cap on a recording session's RAM for review** beyond the ring; long
  sessions were not measured.

## Seen, not explained

- **The latency read-out shows about 8 ms while in review** (2.2 ms live), on the board.
  Harmless for a frozen picture.
- **One 81 ms frame** during a board run; not reproduced.
- **One audio gap per change of the channel listened to** (after the fix for gaps at
  calibration: 2 gaps in 95 s with 3 channel changes, on the board).
- **Latency under tearing reads 1.6 to 2.0 ms in some runs and 2.4 to 2.6 ms in others**,
  same mode, same monitor.
- **Two release builds of identical source differed in 31 bytes** (seen once by an agent,
  not investigated).
- **Display stalls during an early soak** were blamed on a compile running at the time;
  the experiment to reproduce that did not.

## Never tested

- Real mouse clicks and wheel on the display by anyone but the owner; the scripted input
  goes in above the compositor's seat.
- The audio by ear, by the author of the code.
- CAR and the spike tiles on real spikes (the owner has looked; no measurement).
- Cameras and triggers running beside a recording made with oEZ.
- DAC and TTL outputs: not ported.
- Power loss or a full disk during a recording (the crash test kills the process only).
