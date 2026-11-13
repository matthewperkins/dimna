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

- **A slope trigger on a hidden row draws no level line**, and **more sweeps than the
  display can draw at once** are not covered by the stored display test.
- **`Display.frame` never reads `Display.acknowledged`**: acknowledging works because the
  alarm is taken out of `Status` (session.zig). Correct today, easy to break.

## Tried, and not possible on this board

- **Different amplifier settings per port** (the band and the DSP high-pass of port A's
  headstage apart from port B's). The driver has a bank selector per port
  (`AUXCMD_BANK_3`, four bits each for A to D) and the stock software always sets all
  four alike. On this board (ECP5-ONI gateware 2.0.0) the register holds what is written
  (read back `0x3313` and the like) but **port B's chips run port A's list**, whatever
  port B's own field says and whichever bank numbers are used. Measured 2026-11-13 with
  the headstages as they hung (16-ch on A, Myomatrix on B), 14 s recordings, median
  2-100 Hz rms per port in µV:

  | lower corner asked for | port A | port B |
  |---|---|---|
  | both 1 Hz | 198 | 10.3 |
  | both 300 Hz | 21.0 | 2.6 |
  | A 300 Hz, B 0.1 Hz | 21.9 | 2.6 (as A) |
  | A 0.1 Hz, B 300 Hz | 199.7 | 9.8 (as A) |
  | A 0.1 Hz, rest 300 Hz | 225.9 | 14.9 (as A) |
  | B 300 Hz, rest 0.1 Hz | 200.0 | 9.9 (as A) |
  | the last two again with B's bank allocated first | 198.9 / 21.2 | 9.6 / 2.7 (as A) |
  | A 300 / B 0.1, then A 0.1 / B 300, repeated with the board checked free before and after each run | 21.0 / 250.4 | 2.6 / 48.3 (as A) |

  The cause is presumably in the gateware (one command stream for all ports); that is an
  inference from the measurements, not something read in its source. The driver, config
  and metadata changes that implemented per-port settings were not kept, since a setting
  the board ignores would put false values in a recording's `meta.toml`; they are saved
  as `~/oez-test/per-port-filters.patch` (against commit `fecc02a`). `tools/band_power.py`
  is the measurement. What works instead: the widest band any port needs, board-wide,
  and each panel's display filter for the rest (the recording is wide-band either way).

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
