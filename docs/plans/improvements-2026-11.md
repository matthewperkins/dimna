# Note: improvements suggested by a review, 2026-11-25

Read `docs/plans/README.md` first; its rules apply to everything here, above all rule 1
(never touch the board; the simulator only) on the rig, where animals are recorded.

This is a list of work, not one plan. Each item is independent and gets its own branch
and its own commits. Where an item is large (1, 2, 6, 7), write a plan file for it in
this folder before the code, and have the owner read it.

## Where this comes from, and how far to trust it

A review of commit `0aa7e96` (version 0.2.1) by Claude, on the owner's Mac. What was read
in full: `acquisition.zig`, `ring.zig`, `record.zig`, `published.zig`, `source.zig`,
`types.zig`, `parser.zig` (the parser, not its tests), `board.zig` from `start` to
`stop`, `tools/dimna_read.py`, `docs/OPEN.md`, `docs/recording.md`, `docs/hardware.md`,
`docs/platforms.md`, `docs/review-as-claude.md`. The GUI was searched, not read.
**Nothing was built or run**: there was no `zig` on that machine's PATH. So every
statement below is from reading. Before acting on an item, confirm what it says about
the code is still so; line numbers are those of `0aa7e96`.

The order is by how much each protects an experiment.

---

## A. Not losing a session

### 1. A USB read error ends acquisition until dimna is restarted

`Acquisition.run` (`src/acquisition.zig:165`): any error from `source.readBlock` is
stored in `failure`, logged, and the thread returns. The alarm then reads "acquisition
stopped (...): nothing is being read; restart dimna" (the text is in a test at
`src/gui/session.zig:1052`), and `main` exits 1 at the end. One glitch on the cable
costs the rest of the session until someone notices and starts the program again.

Wanted: after a read error, the board is opened again and acquisition restarts without
anyone at the keyboard, the alarm says that it happened and stays until acknowledged,
and if a recording was running, recording carries on.

What to settle in the plan, with the owner:

- **Sample numbers.** The parser is made anew in `Board.start`, so numbering starts at 0
  again. Two honest choices: a new recording folder in the same session (simple; each
  recording stays self-consistent), or the same recording with a gap flag and an offset
  so numbers keep rising (one file, but the size of the gap in samples is then an
  estimate from the board clock or the wall clock, and the files must say so). The
  reviewer leans to the first.
- **What happens to the running recording** when acquisition ends today: not read by the
  reviewer. Find out first (is it closed with `[final]`, or left to the user?), and say
  so in the plan.
- How many attempts, how far apart, and what is shown while it tries.
- What is *not* retried: a board that is gone (`NoDevice`) can only be waited for.

Evidence that can be had without the board: `DIMNA_TEST_SIM_FAIL_AT` makes the simulator
fail with a read error; a test (core, no window) that the source is restarted and that
every sample acquired before and after the failure is on disk and verifies with
`dimna_read.py`. On the board itself only the owner can try it (pulling the cable), and
until he has, the commit says "simulator only".

### 2. The recorder gives up at the first failed write

`Recorder.run` (`src/record.zig:336`): any error from `loop` (a write, a sync) sets
`failure`, logs "recording FAILED", and detaches from the ring. That keeps acquisition
safe, which is right. But the ring holds 30 s (`ringSlots`, `src/gui/pipeline.zig`), and
none of it is used to ride out an error that passes (a network or USB disk that returns,
space freed after `ENOSPC`).

Wanted, in order of worth:

- a **second place to record** (`record_dir_fallback` in the config): on a failure, the
  recorder closes what it can of the first recording and starts a new one there, from
  the blocks still in the ring, with the alarm raised;
- failing that, a bounded retry on the same file for errors that can pass, staying
  attached while the backlog is under some part of the ring.

Careful with: a partial write (the file's length and `byte_offset` must stay true, or
the index points at the wrong bytes); never blocking acquisition (detach before the ring
fills, as now); the order of syncs (samples before their index records) holding across
the retry. The existing fault injection (`test_fail_after`, `DIMNA_TEST_RECORD_FAIL_AFTER`)
fails once and for good; a test for this needs one that fails N times and then works.
`src/record_test.zig` is where it goes. A full disk and power loss stay untested by the
crash test (`docs/OPEN.md`, "Never tested"); a small loop-mounted or tmpfs file system
that is really full would test `ENOSPC` for real, if the rules allow it on the machine
(ask).

### 3. The `published.zig` caveat in OPEN.md is now live

`docs/OPEN.md` says the reader's re-check "is correct on x86-64, where this runs". dimna
now also runs on Apple silicon, which is weakly ordered: the plain loads of the copy are
not kept before the second load of the sequence number, so a torn copy can be accepted.

Its users (found by search): `control.zig` (the control window's snapshot),
`audio_out.zig` (audio settings), `tile_link.zig` (the tiles' config and report). None
is on the recording path, so this cannot touch a recording; it can show or apply a
half-old value for one frame or one audio period.

Wanted: the reader made right for any CPU (the usual form: the value's loads followed by
a fence, or the sequence re-read with an ordering that covers them; decide and say why),
the OPEN.md entry removed, and the existing torn-value test run on an arm64 machine
(the Mac, or CI's macOS job). Note the test passing proves little: the fault is rare.
Say so; the argument for correctness is the reasoning, not the run.

---

## B. What a recording says about itself

### 4. Settings changed during a recording are not in `meta.toml`

Item B2 of `docs/review-as-claude.md`, the one still open. The band and the DSP
high-pass can be changed while recording; the change goes to `events.tsv`, but
`[settings]` holds the values at the start, and nothing in `[final]` says they changed.
An analysis that reads only `meta.toml` takes the whole recording as one band.

Wanted: `[final]` says whether an `amplifier` event was written (for example
`amplifier_changed = true` and the count), and `tools/dimna_read.py` prints a warning
when it is so. This adds keys to format v1; decide with the owner whether that is still
version 1 (readers that ignore unknown keys are unaffected) and write the decision into
`docs/recording.md`.

### 5. The version in `meta.toml` is typed by hand

`src/record.zig:86`: `software: []const u8 = "dimna 0.2.1"`, beside `.version = "0.2.1"`
in `build.zig.zon`. They agree today and will not after the next release unless someone
remembers. Wanted: one source (the build passes the version in as an option), and the
git commit beside it when the build can know it (`software_commit`; absent, not
invented, when it cannot, as in a tarball build). Look at how `dimna --help` or the
packaging gets the version first; there may already be an option to reuse.

### 6. Reading recordings from analysis tools

The only reader is `tools/dimna_read.py`. `samples.i16` looks like the flat int16 file
that Kilosort and SpikeInterface's binary reader take as they are, and with no gaps it
is. With a gap (`index.bin` flag bit 0) the rows after it are later in time than their
row number says, and a tool given the bare file cannot know.

Wanted (plan first; ask the owner what he analyses with):

- the reader as something installable (`pip install`), with its verifier;
- a SpikeInterface extractor, or a documented recipe, that **refuses or splits at gaps**
  instead of reading through them, and applies `bit_volts`;
- room in `meta.toml` for a channel map or probe geometry (none today), since every
  spike sorter asks for one.

---

## C. What the rig's stock software does and dimna does not

Each of these writes to the board or reads something new from it, so none can be
finished on the simulator. Port from the Open Ephys plugin as `board.zig` was (same
writes, same order), say "not run on the board" until the owner has run it, and keep to
`docs/hardware.md`'s rule: volatile registers only.

### 7. Impedance measurement

Not in dimna at all (searched: no trace). For single units it is the stock feature most
missed: which electrodes are open, shorted or good, before the animal's time is spent.

### 8. IMU frames, and DAC / TTL outputs

BNO055 frames are thrown away with one warning (`src/board.zig:1105`). `docs/OPEN.md`
lists DAC and TTL outputs as "not ported", although `LiveCommand` has `dac_route` and
`set_ttl_out`: find out which of the two is true today and correct whichever is wrong.

---

## D. Keeping it true

### 9. Tests run only when a release is tagged

`.github/workflows/release.yml` starts on `v*` tags and by hand. Nothing runs the tests
on an ordinary push. Wanted: a workflow on pushes and pull requests to `main` that runs
what `packaging/ci-build.sh` and `packaging/ci-macos.sh` run up to and including
`zig build test`, without making release files.

### 10. The Mac's three open checks

`docs/platforms.md`: a soak of hours, a recording compared against the rig's
(`tools/dimna_compare.py`), a latency measurement that is not macOS's own report. These
are the owner's to run, with the board on the Mac; listed so they are not forgotten.

### 11. Small faults already in OPEN.md

Cheap ones, each a commit with a test: `--record /proc/...` hangs; `--seconds 0` prints
`-nan`; a top-level `span_s` is ignored without a warning; the Vulkan set-up leaks and
the empty `formats` list in `gpu_vulkan.zig`.

### 12. Housekeeping (the owner's Mac, not the rig)

Five old worktrees under `.claude/worktrees` (5.7 GB, one locked) and their branches;
`src/gui/display.zig` is 3,899 lines, the largest file by far. Neither is urgent.

---

## Suggested order

1 and 2 first (they are the ways left to lose a session without a crash), each behind a
plan the owner has read. 4, 5, 9 and 11 are small and can go in between. 3 is small but
wants care in the argument. 6, 7 and 8 need the owner's decisions before any code.
