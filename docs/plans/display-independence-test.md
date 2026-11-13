# Plan: prove that display features never change what is recorded

Read `docs/plans/README.md` first.

## Why

Filters, common average reference, hidden rows, scales, spike detection, the audio chain
and scroll-back review are all documented as "for the display only: the recording holds
the samples as acquired". That is true by construction today: the recorder reads blocks
from the ring (`ring.readSlot`, a `*const Block`), and everything else works on its own
copy (`ring.LossyReader.next` copies a block out). Nothing tests it. A refactor could
break it silently, and it is the one promise an experimenter relies on without looking.

## What to build

### 1. A unit test (in `zig build test`)

New file `src/independence_test.zig`, imported from `src/root.zig`.

One ring, one producer thread writing deterministic blocks (every sample a pure function
of sample number and channel, the TTL word a function of the sample number), one
`record.Recorder`. Beside it, on its own thread, a "display side" that does to every
block what the GUI does, through a `ring.LossyReader`:

- a `feed.Feed` built from a `panels.Set` with everything switched on: a filtered panel
  with a band, some `raw_rows`, some `hidden` rows, `car` on with both row sets, and a
  `ttl` panel (see the tests at the bottom of `src/feed.zig` and `src/panels.zig` for how
  to build these); call `feed.rows(...)` on each block, and `feed.sync(...)` after
  changing the panel's band or reference part-way through;
- a `spikes.Detector` with a `spikes.Car`;
- a `slope.Slope` on one channel;
- an `audio.Monitor` processing one or two channels.

Record the same deterministic stream twice, into two folders: once with the display side
running flat out, once without it. Then:

- `samples.i16`, `ttl_sample.i64` and `ttl_word.u16` of the two recordings are identical,
  byte for byte, and equal to what the producer generated;
- the index records agree in everything except wall time.

The producer must not be throttled by the display side (it is lossy by design); it is
fine, and worth asserting, that the display side sees fewer blocks than were produced if
it is slow.

### 2. An end-to-end script, written but not run by you

`tools/display-independence-test.sh`, for the owner or the lead to run when the screen is
free (it opens windows, which you must not do). It should:

- run `zig-out/bin/oez --sim 32,16 --no-audio --seconds 12` twice with
  `OEZ_APP_ID=oez-test`, `XDG_CONFIG_HOME` pointing at two scratch configs: one plain
  (two panels, nothing else), one with every display feature on (band, `raw_rows`,
  `hide`, `car_ref`, a triggered panel with `trigger_channel`, a `ttl` panel, `tint`);
  each config sets `record_dir` to its own scratch folder;
- start a recording in each with `OEZ_CONTROL_CLICKS="2:45,94"` (a click on the Record
  button of the control window, 2 s after start);
- then compare, with a short Python snippet using `tools/oez_read.py`'s `Recording`
  class, the samples and TTL edges of the two recordings over the range of sample
  numbers they share. The simulator is deterministic from its start (fixed seed in
  `src/sim.zig`), so the same sample number holds the same values in both runs; check
  that this is so by reading `sim.zig`, and say in your report whether you are sure.

Say clearly at the top of the script that it opens windows and must not be run during an
experiment.

## Files you may change

`src/independence_test.zig` (new), `src/root.zig` (one import line),
`tools/display-independence-test.sh` (new), `README.md` (one short paragraph). Nothing
in the recorder, the ring, the feed or the GUI.

## Done means

`zig build test` passes with the new test. You showed the test can fail: temporarily
make the display side write into the ring's block (for example through `@constCast` on a
slot it reads) and confirm the comparison fails; revert. The script exists, is
executable, passes `bash -n`, and is marked "not run". The report says what this does
not cover (the GUI thread itself: that is what the script is for).
