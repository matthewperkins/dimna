# Plan: tests for the recorder

Read `docs/plans/README.md` first.

## Why

`src/record.zig` is the code the whole project exists for, and it has one unit test (an
index record is 48 bytes). What is believed about it comes from manual runs on hardware.
It has been changed four times since the first of those. This plan gives it tests that
anyone can run.

## What the recorder does (read the code; this is orientation)

- `Recorder.create(gpa, io, ring, root, info)` makes `<root>/<date_time>/` (or
  `<root>/<date_time>/ephys/` when `info.session` is true), opens `samples.i16`,
  `index.bin`, `ttl_sample.i64`, `ttl_word.u16`, `events.tsv`, writes a first `meta.toml`,
  and registers itself as a reader of the ring (`ring.addConsumer()`), so it sees every
  block committed from then on. It may be created while a producer is already running.
- `start()` runs its thread. It gathers blocks into chunks of about 0.1 s, writes each
  chunk's samples, and keeps an index record per chunk (`IndexRecord`: first sample,
  count, flags with `flag_gap`, byte offset, wall time, board clock, CRC-32 of the chunk's
  bytes). About once a second it syncs the samples and only then writes and syncs the
  index records for them.
- TTL: every change of the digital word is written as (sample, word); the first entry is
  the initial state.
- `requestStop()` then `done` then `finish()`, or `finish()` alone: it records up to the
  ring's head at the moment it notices, finalizes (`meta.toml` gains `[final]`), detaches
  from the ring. The producer may keep running. `finish()` gives the ring place back
  (`ring.free`).
- A write error ends the recording: `failure` is set, `done` becomes true, the recorder
  detaches so the producer is never held up. `test_fail_after` and `test_stall_after` /
  `test_stall_ms` inject a failure or a stall.
- `notes_in` / `events_in` are queues of events written to `events.tsv`.

`tools/oez_read.py` is the reference reader and verifier (Python, numpy).

## What to build

### 1. Unit tests (in `zig build test`)

Put them in a new file `src/record_test.zig`, imported from `src/root.zig` so they run.
A small helper in that file should: make a ring; produce blocks whose every sample is a
pure function of (sample number, channel), whose TTL word is a pure function of the
sample number, and whose `hw_time` is plausible; and read a finished recording back
(index records decoded and CRC-checked against `samples.i16`, samples, TTL edges,
`events.tsv` lines, the `[final]` table of `meta.toml`). You may add
`IndexRecord.decode` to `record.zig` for this.

The producer is the test's own thread: `ring.writeSlot()`, fill, `ring.commit()`. The
recorder is its own thread; wait for it with `r.backlog() == 0` plus a short sleep, with
a time limit so a hang fails the test instead of hanging the suite.

Tests, each with a name that states the property:

1. **A whole stream comes back exactly.** Every sample equals the function; every TTL
   change is there, once, at the right sample, and the first entry is the initial state;
   the index covers the file with no holes; every CRC matches; `[final]` counts match;
   `events.tsv` has `start` at the first sample and `stop` at the end.
2. **Attached to a running stream, it starts at a block boundary and misses nothing
   after.** Commit blocks before `create`; none of them are in the file; the first sample
   recorded is the first sample of a block; everything after is there.
3. **Stopped while the producer keeps going, it ends at a block boundary and lets go of
   the ring.** After `finish()`, the producer can lap the ring without `writeSlot()`
   ever returning null, and a second recorder can be created on the same ring and
   records correctly (the ring place was freed).
4. **Lost blocks are flagged, and sample numbers survive.** Make the producer skip sample
   numbers between two blocks (as when a block is dropped). The chunk after the jump has
   `flag_gap`; `stats.gaps` counts it; the samples on both sides are right, at the sample
   numbers the index gives.
5. **A write failure does not hold the producer, and what was indexed is intact.** With
   `test_fail_after` set: `done` becomes true with a failure; the producer is never
   blocked afterwards; every index record that reached the file points at bytes that are
   in `samples.i16` and match their CRC.
6. **Events from both queues land in `events.tsv` with their samples.**

### 2. A crash test that can be rerun

`tools/crash-test.sh`: start `zig-out/bin/oez-headless --sim 32,16 --seconds 30 --record <tmp>`
(check `src/headless.zig` for the exact options), wait a few seconds, `kill -9` it, then
run `python3 tools/oez_read.py` on the recording folder and check that it reports the
indexed part as verified, that the recording is reported as not complete (no `[final]`),
and that any tail after the last index record is reported as such and is less than about
1.5 s of data. Exit non-zero if not. Run it three times with different kill times and
give the output.

## Files you may change

`src/record_test.zig` (new), `src/root.zig` (one import line), `src/record.zig` (only
`IndexRecord.decode` and, if truly needed, small accessors; no behaviour changes),
`tools/crash-test.sh` (new), `README.md` (a short "Testing the recorder" paragraph).

If a test exposes a real bug in the recorder: do not fix it. Leave the test in, marked
clearly, and report it.

## Done means

`zig build test` passes with the new tests; each of the six properties was shown to fail
when the code was broken on purpose (say how); `tools/crash-test.sh` ran three times and
passed, output included; the report says what is not covered (for one: real disks
filling, and the hardware path).
