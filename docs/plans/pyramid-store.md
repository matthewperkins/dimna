# Plan: min/max pyramid store (`src/pyramid.zig`)

Read `docs/plans/README.md` first (rules, Zig 0.17.1 notes, what counts as evidence), then
`docs/plans/long-timebases.md` for where this fits.

## What it is for

Review of long stretches (seconds to 2 hours across 1920 pixel columns) must not read and
filter millions of samples. The store keeps, for every history column, the (min, max) of
every bucket of 64 samples and of coarser levels (x4 each), so any stretch is drawn from a
few buckets per pixel column. The sister program has one in Rust; its header describes the
same idea (read-only reference, do not copy code structure blindly):
`/home/matthew/kalila/crates/engine/src/pyramid.rs`.

"History row", "history column", "slot": see the top of `src/feed.zig`. A history row is
`width` int16: the `nch` channels as acquired, then every panel's slot (filtered,
referenced, hidden rows left out), then TTL lanes.

## What to build

A new file `src/pyramid.zig`, exported from `src/root.zig`, with tests in the file.

1. **`Store`**: single-threaded (the display thread owns it; no locks, no atomics).
   - `init(gpa, width, nch, budget_bytes)`, `deinit`.
   - Levels: bucket 64 samples at level 0, x4 per level, 8 levels. Buckets are aligned to
     absolute sample numbers (bucket k of level 0 is samples [64k, 64k+64)).
   - Storage in chunks of 2^24 samples (2^20 under test), allocated when first written,
     aligned across levels, so memory follows the recording's length.
   - `add(first: i64, rows: []const i16)`: `rows.len / width` consecutive history rows
     starting at sample `first`. Normally continues where the last call ended. Coarser
     levels are merged incrementally, so the live edge is right at every level,
     including the bucket that is still filling.
   - Per bucket also the OR of the TTL words (`addTtl` or an extra argument: your choice,
     say which), so review can draw the TTL lanes.
   - **Coverage**: which stretches are held, separately for the raw part (columns
     `0..nch` and the TTL words) and the slots part (columns `nch..width`). A gap in what
     `add` was given is a hole. `holes(part)` returns the newest hole first.
   - `resetSlots(width)`: the panels' filters, rows or references changed (the slots part
     may have a new width): drop the slots part, keep the raw part.
   - `put(part, level0_first_bucket, buckets...)`: splice in buckets made elsewhere (the
     backfill), rebuilding the coarser levels above them, and mark them covered. A
     backfill result made for an older slots layout must be refused (give `resetSlots` a
     generation number that `put` checks).
   - `columns(lo: i64, hi: i64, cols: usize, history_columns: []const usize, out: [][2]i16) bool`:
     for each of `cols` pixel columns over samples [lo, hi) and each requested history
     column, the min and max, from the finest level that has at least 1 bucket per pixel
     column... choose the level so each pixel column reads between 1 and 4 buckets.
     Returns false (and writes nothing useful) if any part of [lo, hi) is not covered or
     its level has been released, or if the span is shorter than 64 samples per pixel
     column (the caller reads samples then). A second function for the TTL words.
   - **Budget**: when the bytes held exceed `budget_bytes`, release the oldest chunk of
     level 0, then of level 1 (never the chunk at the live edge, never levels 2 and up).
     `bytes()` reports what is held.

2. **`Backfill`**: fills holes from a recording, used from another thread. It owns
   nothing of the store.
   - Built on `src/review.zig`'s `Review` (which already reads `samples.i16` and the TTL
     edge files read-only, runs a private `Feed` set up as the live one, and runs a
     lead-in so filters have settled). Give it a small private ring. You may add small
     read accessors to `review.zig`; do not change what it does.
   - `step(hole_lo, hole_hi, end) -> ?Result`: processes at most 2 s of samples at the
     newest end of the hole and returns the level-0 buckets for whole buckets only, with
     the part (raw, slots or both), the first bucket number and the generation, ready
     for `Store.put`. No sleeping, no thread, no priority changes in this file: the
     caller paces it.

## Not in this plan

Threads, queues, the GUI, the GPU, `src/gui/*`, `src/feed.zig` (read it; do not change
it), the recorder. Files you may change: `src/pyramid.zig` (new), `src/root.zig` (one
export line), `src/review.zig` (read accessors only), `docs/plans/pyramid-store.md` (a
"Report" section at the end).

## Done means

- `zig build --release=safe` and `zig build test --summary all` pass; `zig fmt --check src build.zig` prints nothing.
- Tests, each broken on purpose once (README, "What counts as evidence"):
  - every level equals brute-force min/max over random rows, added in blocks of odd
    lengths, including the partly filled newest bucket and across a chunk boundary;
  - `columns` equals brute force for spans from 64 to 2^18 samples per pixel column,
    with `lo`/`hi` not aligned to buckets (say in a comment exactly which samples a pixel
    column may include beyond its own: at most the rest of its first and last bucket);
  - a gap in `add` is reported as a hole, `columns` over it returns false, `put` closes
    it and the result equals a store that never had the gap;
  - `resetSlots` drops only the slots part; a `put` with the old generation is refused;
  - the budget: bytes stay under it, level 0's oldest chunk goes first, the live edge
    stays, `columns` at a coarse level still answers for the released stretch;
  - `Backfill` against a recording made in a temporary folder (see the tests in
    `src/review.zig` for how): a store filled only by backfill equals one filled live
    through a `Feed` with the same panels, apart from each filter's lead-in (state how
    close, and why not exact if it is not), for a band-passed panel with a reference.
- Report as the README asks, including RAM per hour at 72 history columns as measured,
  and the time `add` takes per second of 30 kHz x 72 columns (it runs on the display
  thread; say if it is more than about 0.2 ms per 1 ms of... more than 1% of real time).
