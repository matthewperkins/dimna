# Plan: the overview (`src/overview.zig`): the pyramid store kept up to date

Read `docs/plans/README.md` first, then `docs/plans/long-timebases.md` and
`docs/plans/pyramid-store.md` with its Report (the store and `Backfill` you build on are in
`src/pyramid.zig`).

## What it is for

While a recording runs, the display thread must be able to ask "the min and max per pixel
column of these history columns over [lo, hi)" for stretches up to two hours and get an
answer in about a millisecond. This plan builds the part that owns the store, keeps it
filled from the live rows, and fills its holes from the recording on a second thread.
The display side (GPU buffer, shader, review logic) is being written by someone else at
the same time against the interface below: keep it as written, or say in your report
exactly what you changed and why.

## What to build

### 1. `src/pyramid.zig`: no 50 ms call

The store's report found that `add` takes 50 ms whenever a new chunk starts (100 MB
allocated and set to "empty"). It runs on the display thread; that must go.
- Store each pair so that all-zero bytes mean "empty" (for example the minimum XOR 0x7FFF
  and the maximum XOR 0x8000, or what you find cleaner), hide that behind the accessors,
  and take chunks from zeroed pages the kernel hands out on first touch (`mmap` anonymous,
  via `std.heap.page_allocator` if it gives that, without a `@memset`).
- Measure as the store's report did (1 h, 30 kHz x 72 columns, real chunk size): worst
  single `add` call, and total. Target: worst call under 2 ms. Report both numbers.

### 2. `src/panels.zig`: `Panel.signalSignature`

It does not change when a panel's row count, its kind, or a TTL panel's lines change, so
a feed made for the old panels is kept (the store's report, "Unexpected" 2). Make it
cover everything that decides a slot's width and contents. Add a test with the cases the
report names. Then `Backfill.follow` may go back to `Review.follow` if that is now right
(your choice; say which).

### 3. `src/overview.zig` (new, exported from `src/root.zig`)

    pub const Overview = struct {
        pub fn init(gpa, io, layout: *const types.Layout, budget_bytes: usize) !Overview
        pub fn deinit(self) void                       // stops the thread

        /// A recording has started: its folder, its first sample. Starts the store and
        /// the backfill thread. `set` and `width` as the live feed has them.
        pub fn begin(self, dir: []const u8, first_sample: i64, set: *const panels.Set, width: usize) !void
        /// The recording has ended (or review must let go): thread stopped, store freed.
        pub fn end(self) void
        pub fn active(self) bool

        /// Live history rows from the display's feed, with their TTL words. Display thread.
        pub fn add(self, first: i64, rows: []const i16, ttl: []const u16) void
        /// Once per frame, display thread. Notices that the panels' signals changed
        /// (signature or width): drops the slots part and tells the thread. Takes
        /// finished buckets from the thread into the store. If the thread is idle and
        /// holes remain in [first_sample, file_end), asks for the next one: a hole that
        /// overlaps `want` first (what the view is showing), else the newest.
        /// `hold`: the recorder is behind; ask for nothing this turn.
        pub fn turn(self, set: *const panels.Set, width: usize, file_end: i64, want: ?pyramid.Range, hold: bool) void
        /// As `Store.columns`. False while not active.
        pub fn columns(self, lo: i64, hi: i64, cols: usize, history_columns: []const usize, out: []pyramid.Pair) bool
        /// Holes remain in [first_sample, file_end) (for a "building" badge).
        pub fn building(self) bool
        pub fn bytes(self) usize
    };

- The store is touched only by the display thread. The thread owns the `Backfill` and
  talks through two single-producer single-consumer queues (see how `src/gui/tile_link.zig`
  and `src/published.zig` pass things between threads; use what the tree has, or a small
  bounded queue of your own with atomics; no mutex that the display thread could wait on
  while an idle-priority thread holds it).
- The thread runs at `SCHED_IDLE` (see how other threads here set priority, if any does;
  else `sched_setscheduler` by raw syscall), sleeps when it has nothing to do, does one
  `Backfill.step` per request, and waits 10 ms after each. `file_end` passed with a
  request must be a flushed length: the caller gives the recorder's count of samples
  written; say in a comment what happens if the file is shorter than that (it must be a
  refused step, retried later, never a crash).
- A change of the panels while a request is in flight: the result is stale; `put` refuses
  it; make sure it is freed and the hole asked for again.
- Errors (cannot open the recording, a read fails, no memory): logged once as a warning,
  the overview goes inactive, nothing else is affected.

## Not in this plan

`src/gui/*`, the GPU, `src/feed.zig`, `src/decimate.zig`, the recorder, `src/review.zig`
beyond what `signalSignature` needs. Files you may change: `src/overview.zig` (new),
`src/pyramid.zig`, `src/panels.zig` (`signalSignature` and its test only), `src/root.zig`
(one line), `src/review.zig` (only if the signature change requires it), and a "Report"
section at the end of this file.

## Done means

- Build, `zig build test --summary all`, and `zig fmt --check src build.zig` clean.
- Tests, each broken on purpose once:
  - the store's existing tests still pass with the new encoding; one new test that a
    fresh chunk reads as empty without having been written;
  - `signalSignature` changes for each of: row count, kind, a TTL panel's lines; and does
    not change for display-only things (scale, time base, mode);
  - overview, with a recording in a temporary folder and the real thread: rows added
    live from the middle of the recording on; `turn` called in a loop (with short
    sleeps) until `building()` is false; the store then equals one filled live from the
    start. The loop must have a time limit so a hang fails the test instead of hanging
    the run;
  - `want` is served first: with holes at both ends, the one overlapping `want` is
    filled before the other;
  - a signal change mid-backfill: the slots part ends equal to a live-filled store with
    the new panels, the raw part was not redone (count the requests or the steps);
  - `hold` stops new requests; `end` during a request neither leaks nor hangs (the
    testing allocator will report a leak);
  - a recording folder that is removed, or a file shorter than `file_end`: inactive or
    retried, logged, no crash. (The test runner counts `log.err` as a failure: use
    warnings.)
- Report as the README asks, with the measurements of part 1, and how long backfilling
  10 min of 72 columns takes on this machine through the thread (and so the multiple of
  real time).

## Report

Branch `worktree-agent-a7394bae9237a7c00`, one commit on top of `main` (7ffdf25); the
commit hash is in the hand-off message (a commit cannot name itself).

### Files changed

- `src/pyramid.zig`: the zero-means-empty encoding (`Held`, `encode`, `decode`, `merge`),
  chunks as fresh anonymous mappings (`mapZeroed`, no memset), released chunks unmapped a
  piece per `add`/`put` (`Retired`), `Store.retiredBytes`, `Store.compare` (for tests), an
  assert in `Store.deinit` that every chunk was let go (the mappings bypass the testing
  allocator's leak check), 2 new tests, the backfill test's slots comparison now through
  `compare`, and the comments on `Backfill.follow` and at the top.
- `src/panels.zig`: `Panel.signalSignature` and one new test.
- `src/overview.zig` (new): `Overview`, its thread, 5 tests.
- `src/root.zig`: `pub const overview = @import("overview.zig");`.
- `docs/plans/pyramid-overview.md`: this section.

### Interface: as written, with these additions

- `Overview` has two public fields beyond the plan: `stats` (requests, accepted,
  refused, empty, short, raw buckets made, skipped adds; for tests and logging) and
  `retry_ns` (default 1 s; the tests shorten it).
- `turn`'s doc says what the plan implied: `set` and `width` must be those of the feed
  whose rows `add` gets from then on. `building()` is false until the first `turn` (it
  knows `file_end` only from there).
- `add` takes rows whose width is not the store's (the panels changed and `turn` has not
  seen it yet) as nothing: they become a hole. `ttl` may be empty.
- `pyramid.Store` gains `compare`, `Comparison`, `retiredBytes`. Nothing in the store's
  existing interface changed. `Buckets` still carries `Pair`s (i16 min, max); the encoding
  is internal.
- `Backfill.follow` still makes its `Review` afresh. With the new signature
  `Review.follow` would notice the change, but it keeps the ring it was given, and the
  backfill's ring is sized by the history's width, which changes with the panels.

### What the code does

- **Encoding.** Stored: minimum XOR 0x7FFF and maximum XOR 0x8000, as u16. Both halves
  then grow with what they stand for, so every merge is `@max` of each half, and empty
  (32767, -32768) is all-zero bytes (asserted at compile time). Chunks come from `mmap`
  (anonymous, private), which the kernel zeroes on first touch.
- **Unmapping in pieces (not in the plan; see "Unexpected", 1).** A released chunk goes
  to a list; each `add` and `put` unmaps at most 2 MB of it (newest first, from its end).
  `bytes()` stops counting a chunk when it is released, so for a moment after a release
  more is mapped than `bytes()` says (`retiredBytes()`): at 117 adds/s, a 75 MB level-0
  chunk is gone in about a third of a second.
- **signalSignature** now also hashes the kind, `first_ch`, `rows` and, for a TTL panel,
  `ttl_lines[0..rows]`, besides the filter, raw/hidden rows and reference as before. It
  leaves out scale, span, mode, trigger, gains, place, tint, name and `slot`.
- **Overview.** The store is on the display thread only. The thread (`SCHED_IDLE` via
  `sched_setscheduler`, a warning if refused) makes its `Backfill` and opens the
  recording itself, so the display thread never touches the disk. Queues: `events.Spsc`
  of requests (a hole, or "follow these panels at this generation") and of results
  (buckets, "nothing yet", "file too short"); a futex word wakes the thread, which
  otherwise sleeps (200 ms timeout). One hole in flight at a time; 10 ms pause after each
  step. Hole choice: within `want` where a hole overlaps it (the newest such, clipped to
  `want`), else the newest hole of either part; `.both` over the overlap where the other
  part lacks it too, else one part. Panel change (signature or width): `resetSlots`, then
  a follow request; a result made before it is refused by `put` (`Stale` or
  `WrongWidth`), freed, counted, and its hole asked again. A `WrongWidth` result made for
  the *current* generation means the caller's `width` does not belong to its `set`: fatal.
  Errors on the thread (open, read, memory) set a flag the next `turn` sees: one warning,
  `end()`, inactive. `error.RecordingTooShort` (the file is shorter than `file_end`) is a
  refused step: warning the first time, nothing asked for `retry_ns`, then again. "No
  whole bucket yet" waits for `retry_ns` or a change of `file_end`.
- `end()` stops the thread, joins it (it finishes the step it is in first), frees
  whatever results are still queued, frees the store.

### Verification

    $ zig fmt --check src build.zig; echo "fmt exit $?"
    fmt exit 0
    $ chrt -i 0 nice -n 19 zig build --release=safe; echo "build exit $?"
    build exit 0
    $ chrt -i 0 nice -n 19 zig build test --summary all
    Build Summary: 17/17 steps succeeded; 198/198 tests passed
    +- run test 127 pass (127 total) 10s MaxRSS:52M
    +- run test gui-test 71 pass (71 total) 2s MaxRSS:22M

(127 core tests, 8 of them new: 2 in pyramid.zig, 1 in panels.zig, 5 in overview.zig.
That summary is from the last run before two comment-only edits and `zig fmt`; after
those `zig build test` was cached, so I ran the final core test binary directly, four
times: "All 127 tests passed." each time.) The tests print two expected warnings
("overview off for this recording: backfill: CannotOpenRecording" and "recording file
shorter than its count of samples written; backfill retried later").

The tests:

1. pyramid, "a fresh chunk reads as empty without having been written": one row in the
   middle of chunk 1; on every level and both parts, every pair except the written
   bucket's is zero bytes, the TTL words zero, neighbours read as (32767, -32768), the
   written bucket as the row; -32768 and 32767 survive as a minimum and a maximum.
2. pyramid, "released chunks are unmapped a piece per add": two retired mappings (2.5 and
   1 pieces); after each add 2.5, 1.5, 0.5, 0, 0 pieces left; a partly unmapped mapping
   keeps its start.
3. panels, signalSignature: changes for row count, kind, first channel, a TTL line, the
   TTL lane count, filter on, a hidden row, the reference; not for a TTL line past the
   lane count, nor (on each of three panels) scale, span, sweep and triggered mode, a
   row's gain, trigger line and window, place, tint, slot, name.
4. overview, "rows from the middle on": 7 s recording from sample 5000; one feed runs
   from the start (the display's), the overview begins at 3.5 s + 17 samples and from
   then gets every block while `file_end` follows the live position. Ends with
   `building()` false; raw part (and TTL words) equal to a store filled live from the
   start, the slots part too (worst difference 0 LSB, same chunks); 2 requests, 2
   accepted, 0 refused.
5. overview, `want`: rows given for [2 s, 4 s) and [6 s, 8 s) of 8 s; `want` inside the
   older hole. When `columns` first answers for `want`, the newer hole is still exactly as
   it was; at the end the store equals the live one.
6. overview, panels changed mid-backfill: rows (panels A) for the second half; after the
   first result is in, `turn` gets panels B (a third TTL lane, so one column wider, and
   corners 500 to 3000 Hz). At the end: width B, raw part equal to the live store,
   slots equal to a store filled live with panels B (0 LSB). Raw buckets made: at least
   the raw hole's and at most that plus one step's (937); measured 2353 for a hole of
   1646 (one in-flight step of 707 buckets made for A was refused and redone; see
   "Unexpected", 3), 1 refused, 6 requests.
7. overview, `hold` and `end`: 300 ms of turns with `hold`: 0 requests, 0 steps,
   `building()` true; then one turn without: 1 request, and `end()` at once (on another
   thread, failing after 10 s instead of hanging): inactive, `columns` false. Again with
   the finished buckets left in the queue untaken: `end()` frees them (the testing
   allocator would report the leak).
8. overview, errors: a folder that does not exist: inactive within the time limit,
   `building()` false, `bytes()` 0, `add`/`turn` afterwards harmless. A file written to
   3 s while `file_end` says 6 s: 3 refused steps (`short`), still active and building,
   nothing accepted; then the rest is written and the store fills and equals the live
   one.

Every loop that waits on the thread has a deadline (30 or 60 s) and returns
`error.Timeout` past it.

### Break-it-on-purpose (one change each, reverted; full `zig build test` each time)

| broken | result |
|---|---|
| `ensure`: new chunk filled with `encode(.{0, 0})` | test 1 fails, plus 4 older pyramid tests and all 4 overview equality tests |
| `Retired.some` returns at once | test 2: "expected 5242880, found 7340032" |
| signature without `rows` | test 3 fails at the row-count case |
| signature without the TTL lines | test 3 fails at the TTL-line case |
| signature also hashes `mode` | test 3 fails at the display-only loop |
| `Overview.add` adds at `first + 1` | tests 4, 5, 6 fail in `expectSameStore` |
| `turn` never `put`s results (counts them accepted) | tests 4, 5, 6, 8 fail with `error.Timeout` after 60/30 s (220 s for the run): the time limits work |
| `next` ignores `want` | test 5: the newer hole had been touched (`expect(found)`) |
| a panel change makes a new store instead of `resetSlots` | test 6: raw buckets over the bound |
| `turn` ignores `hold` | test 7: "expected 0, found 2" requests |
| `end` does not free queued results | test 7: "leaked 4 allocations" (both `end` cases left one result each) |
| `RecordingTooShort` treated as fatal | test 8: overview went off ("RecordingTooShort" warning), `error.Timeout` |
| `turn` ignores the thread's failure flag | test 8: `error.Timeout` waiting for inactive |

### Measured (ReleaseSafe, this machine, `nice -n 19`)

**`add`** (scratch program outside the tree, as the store's report did: 1 h of 30 kHz x 72
history columns, 40 raw + 32 slots, TTL words, blocks of 256 rows, real 2^24 chunks):

    budget 0 MB: 424800 add calls; total 6.480 s = 1.800 ms per s of data (0.180 % of real time); mean 15.3 us; worst 0.644 ms at sample 41215600; calls > 1 ms: 0, > 2 ms: 0; bytes held 709525600; worst thread CPU time of one call 0.431 ms
    budget 300 MB: 424800 add calls; total 6.332 s = 1.759 ms per s of data (0.176 % of real time); mean 14.9 us; worst 0.598 ms at sample 4004336; calls > 1 ms: 0, > 2 ms: 0; bytes held 253395040; worst thread CPU time of one call 0.542 ms
    budget 0 MB: 424800 add calls; total 6.396 s = 1.777 ms per s of data (0.178 % of real time); mean 15.1 us; worst 0.548 ms at sample 53462304; calls > 1 ms: 0, > 2 ms: 0; bytes held 709525600; worst thread CPU time of one call 0.668 ms

- **Worst single `add`: 0.55 to 0.64 ms** (was 49.7 ms at each chunk boundary), no call
  over 1 ms in 424,800. **Total: 6.4 to 6.5 s per hour, 0.18 % of real time** (was 7.3 s,
  0.20 %). The 300 MB budget run releases chunks (level 0 from about 27 min on, at 652.5 MB per hour).
- With the encoding but before `Retired` (chunks unmapped at once): unlimited budget,
  worst 2.49, 1.95 and 1.28 ms wall in three runs, but only 0.66 ms of thread CPU time in
  the run that measured it (so the wall-clock outliers were the scheduler, at nice 19);
  300 MB budget, worst **5.49 ms of wall and 5.30 ms of CPU**, at sample 50,331,504 =
  3 x 2^24 + 48: the `munmap` of a released, fully touched level-0 chunk. Hence `Retired`.

**Backfill through the thread** (scratch program: `Overview.begin`, then `turn` every
1 ms until `building()` is false; no live rows, so everything is a hole; 2 x 16 electrodes
+ 8 ADC, two electrode panels band-passed 300 Hz to 6 kHz with a reference over all
rows: 72 history columns):

    real 60 s of 40 channels, 72 history columns: backfilled in 1.13 s = 52.9 x real time; steps 31, ... accepted = 31, refused = 0 ...
    sparse 600 s of 40 channels, 72 history columns: backfilled in 11.25 s = 53.3 x real time; steps 301, ... accepted = 301, refused = 0 ...

- **10 min of 72 columns: 11.25 s, 53 x real time** (a 2 h recording in about 2.3 min).
  3.0 s of it is the 10 ms pause after each of the 301 steps; a step is about 27 ms.
- The 10 min file was sparse (zeros, `ftruncate`), because a written one is 1.44 GB in
  `/tmp`, which is RAM on this machine (3.9 GB tmpfs, about 3 GB available), and the
  owner may be recording here. A written 60 s file of varied data went at the same rate
  (52.9 x), so the content does not change the cost (the filters' and min/max work do
  not depend on it). Both from tmpfs: reading a recording from disk would add its read
  time.

### Unexpected

1. **Releasing a chunk cost 5 ms** on the display thread (`munmap` frees every touched
   page). Only seen once the budget is reached (after about 2.3 h at 72 columns, then once
   per 9.3 min), and `resetSlots` after a long recording would have done the same for the
   whole slots part at once (about 290 MB per hour at 32 slot columns, so tens of ms). I
   added the piecewise unmapping (`Retired`) inside `pyramid.zig`; nothing outside sees
   it except `retiredBytes`.
2. **A recording's last, partial bucket is never backfilled** (`Backfill.step` makes whole
   buckets only). With live rows that bucket is covered by `add`, so nothing is missing in
   use. But a store filled only by backfill whose recording does not end on a bucket
   boundary keeps a hole of under 64 samples there, and `building()` stays true for good.
   That would show after a panel change once acquisition has stopped but before `end()`.
   The tests that fill a whole store by backfill use recordings that end on a bucket
   boundary for that reason. A fix would be for `Backfill` to make the last partial
   bucket once `end` is final; not done (it is the store's interface, and nothing marks a
   recording's end as final today).
3. **One step of raw work is redone after a panel change.** The step in flight was made
   for the old panels; its `Buckets` hold every column, and `put` refuses them whole
   (`WrongWidth` here, since the width changed), raw part included. So up to 2 s of raw
   is made twice (measured: 707 of 1646 buckets). Letting `put` take the raw columns of an
   old-layout result would avoid it; not done, as it changes `put`'s contract.
4. `zig fmt` rewrote my `@intFromEnum(self.kind)` to `@backingInt(self.kind)` (0.17's
   spelling).
5. The first test run crashed four overview tests (my bug: `@min(256, ...)` typed the
   block length as `u9`, so `n * 5` overflowed) and left five
   `/tmp/dimna-overview-test-<pid>-*` folders, removed by hand. As in the review and
   pyramid tests, a crash skips the `defer` that removes them.

### Not covered

- The wiring into the display (`src/gui/*`, by someone else): nothing here ran in the GUI,
  against the board, or in `dimna-headless` (not run).
- Real disk reads (everything was on tmpfs), a written 10 min file (see above), and the
  thread's speed while the machine is busy: at `SCHED_IDLE` it gets only idle CPU, so on a
  loaded machine backfill can stall entirely; that is intended but not measured.
- Untested paths: a follow request that does not fit in the queue (`follow_pending`),
  the fatal "wrong width for the current generation" path, out-of-memory anywhere, more
  than 64 holes in a part (the rest are seen as the newer ones fill), `want` spanning
  several holes, and the budget releasing chunks while backfill puts into them.
- The cost of `turn` and of `Overview.columns` per frame was not measured (`turn` hashes
  the panels and lists up to 64 holes per part).
