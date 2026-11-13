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
