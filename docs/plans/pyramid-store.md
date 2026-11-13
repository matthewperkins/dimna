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
     column, the min and max, from the coarsest level that still gives every pixel column
     at least one whole bucket (so a pixel column reads 1 to 4 buckets, plus the two it
     shares with its neighbours).
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
  thread; say so plainly if it is more than 1% of real time).

## Report

Branch `worktree-agent-a91188b2685dc5d85`, one commit on top of `main` (0c2ec9e); the commit
hash is in the hand-off message (a commit cannot name itself).

### Files changed

- `src/pyramid.zig` (new): `Store`, `Backfill`, `Buckets`, and 6 tests.
- `src/root.zig`: `pub const pyramid = @import("pyramid.zig");`.
- `src/review.zig`: one read accessor, `pub fn ttlWords(first, out)`, which calls the
  existing private `words`. Nothing else changed there.
- `docs/plans/pyramid-store.md`: this section.

### Interface choices (where the plan left it open, or where it did not fit)

- **TTL words:** an extra argument, `add(first, rows, ttl)` (one word per row, or empty).
- **`holes(part, lo, hi, out)`** takes the bounds: holes of `part`'s coverage within
  [lo, hi), newest first. The store does not know where the recording starts, and a store
  filled only by `put` has no live edge, so the caller gives both (the recording's first
  sample, the live edge).
- **`put(*const Buckets)`:** `Buckets` holds parts, generation, first bucket, count, width,
  `count * width` (min, max) pairs (every history column, whichever parts are meant) and one
  TTL word per bucket. Put *replaces* the level-0 buckets (so a partly filled bucket at a
  hole's edge becomes the whole one), then remakes each coarser bucket above them from its
  four children; where the level below has been released, it merges the new buckets into
  what the coarser bucket had. Refused with `error.Stale` if it carries slots and the
  generation is not the store's, `error.WrongWidth` if made for another width. Raw-only
  buckets of the right width are taken whatever the generation.
- **`resetSlots(width)`** returns the new generation; `Backfill.init`/`follow` take it.
- **`Backfill.step(parts, hole_lo, hole_hi, end)`:** one extra argument, which parts the
  result is for. Holes are per part and only the caller knows which one it is filling;
  `.both` when the raw and slots holes coincide (e.g. a store filled only by backfill).
  Results own their memory (`Buckets.deinit(gpa)`) so they can be handed from the backfill
  thread to the display thread. A step covers every bucket that holds a sample of the hole
  and lies whole within the recording (the recording's first bucket counts as whole from
  its first sample; a partial last bucket is left for a later step), at most 2 s
  (59,968 samples) at the hole's newest end, read with a fresh lead-in every time.
- **Level choice in `columns`:** the coarsest level whose bucket is no wider than the
  narrowest pixel column, floor((hi - lo) / cols). That is what gives "1 to 4 buckets plus
  the two shared with neighbours"; it does not guarantee a *whole* bucket inside every
  pixel column (a 64-sample pixel column straddling two buckets has none).
- **`Backfill.follow`** makes its `Review` afresh rather than calling `Review.follow` (see
  "Unexpected", 2).
- `bytes()` counts bucket storage (values and TTL words) only, not coverage lists or
  scratch.

### Verification

    $ chrt -i 0 nice -n 19 zig build --release=safe; echo "build exit $?"
    build exit 0
    $ zig fmt --check src build.zig; echo "fmt exit $?"
    fmt exit 0
    $ chrt -i 0 nice -n 19 zig build test --summary all
    Build Summary: 17/17 steps succeeded; 186/186 tests passed
    +- run test 115 pass (115 total) 8s MaxRSS:52M
    +- run test gui-test 71 pass (71 total) 2s MaxRSS:21M

(115 core tests, 6 of them new.) The tests:

1. Every level equals brute force, added in odd blocks (1, 63, 64, 65, 127, 1000, 4097, 7,
   333, 2), starting and ending mid-bucket and across the chunk boundary at 2^20. The
   newest, still-filling bucket of every level is checked against brute force every 97th
   block and at the end, then every bucket of every level, with the TTL OR.
2. `columns` and `ttlColumns` equal brute force for 64, 65, 100, 255, 256, 257, 1000, 1023,
   1024, 4095, 4096, 5000, 16384, 65535, 65536, 65537, 200000, 262143 and 262144 samples per
   pixel column, with 4 and 7 pixel columns, `lo` and `hi` off the bucket grid, and history
   columns out of order across both parts. The brute force is over the pixel column's own
   samples plus the rest of its first and last bucket (comment in the test and on
   `columns`). Refused: 63 samples per pixel column, past the newest sample, before the
   first, a column past the width.
3. A gap in `add` is reported as the one hole (and the stretch before the first sample as
   a second, older one when asked from 0). `columns` over or inside it is false (raw and
   slots columns). After `put` of its buckets there is no hole, and every chunk of every
   level of both parts equals a store that never had the gap.
4. `resetSlots` keeps raw coverage and raw `columns` output byte for byte, and drops the
   slots part (hole = everything, bytes down, chunks gone). It refuses a put with the old
   generation (`error.Stale`) and leaves the store unchanged, takes raw-only buckets, takes
   slots for the new generation, then takes rows of the new width.
5. Budget (1.8 x one chunk's stretch on every level, 4.5 chunks added): after every add,
   `bytes() <= budget`, and the live chunk is held on every level in both parts. Level 0's
   chunks go oldest first; level 1 loses a chunk only once level 0 holds nothing but the
   live chunk, and only when keeping it would be over the budget. Levels 2 to 7 keep all 5
   chunks. Over the released stretch, `columns` is false at 64 and 256 samples per pixel
   column and equals brute force at 1024 (level 2), with TTL. A put into the released
   stretch allocates nothing and reaches levels 2 to 7, merged.
6. `Backfill` against a 5 s recording in `/tmp/dimna-pyramid-test-<pid>` (4 electrodes +
   1 ADC, starting mid-bucket at sample 5000; a 300 Hz to 6 kHz panel with one row raw,
   referenced to rows 1, 2, 4 and subtracted from rows 1 to 3; a TTL panel with two lanes).
   The store filled only by backfill (3 steps, newest first) equals the one filled live
   through a `Feed` with the same panels: the raw part and TTL words exactly, and the slots
   part **exactly as well** (largest difference 0 LSB, 0 values differ). Why exact:
   Review's lead-in is 0.05 s for a 300 Hz corner, over which the slowest pole's transient
   decays by about e^-36. With a 10 Hz corner instead (lead-in 0.3 s; tried once, not kept)
   36 values differ, by 1 LSB at most. Then the TTL panel gets a third lane: `resetSlots` to
   the new width, a result made before is refused (`error.WrongWidth`), and `follow` plus
   3 more steps fill the slots part. The new lane holds -ttl_level and the raw part is
   unchanged.

### Break-it-on-purpose (each a one-line change, reverted; full `zig build test` each time)

| broken | result |
|---|---|
| `fold`: `idx >>= 2` -> `idx >>= 1` (coarse bucket index) | tests 1 (null bucket), 2, 3, 5, 6 fail |
| `columns`: last bucket `floor(s1/size)` instead of `ceil` | tests 2 and 5 fail (min/max differ) |
| `levelFor`: `bucketSize(k+1) <= 2*w` (a level too coarse) | test 2 fails |
| `cover`: fast path takes any `lo >= last.lo` (gaps swallowed) | test 3: "expected 1, found 0" holes |
| `splice`: coarser levels not remade (`for (1..1)`) | tests 3, 5, 6 fail |
| `put`: generation check off | test 4: "expected error.Stale, found void" |
| `resetSlots` also clears raw coverage | test 4: "expected 0, found 1" raw holes |
| `enforceBudget`: level 1 before level 0 | test 5 fails (the "only when needed" check) |
| `enforceBudget`: `floor <= live` (live chunk may go) | test 5 fails (live chunk held) |
| `splice`, released branch: new TTL word not merged | test 5 fails |
| `Backfill.step`: ring row of sample s+1 | test 6 fails (raw part differs) |
| `Backfill.init`: its review's high corner 5900 Hz | test 6: slots "expected 0, found 5" LSB |
| `Backfill.follow` via `Review.follow` | test 6: "expected 12, found 11" width |

The release-order break passed at first. The test then only checked that level 0 held
nothing but the live chunk when level 1 first lost one, and that is also true if level 1
goes first within the same call. I added the "only when keeping it would be over the
budget" check, and the break then failed.

### Measured (ReleaseSafe, this machine, `nice -n 19`)

A scratch program outside the tree (`zig build-exe -OReleaseSafe --dep pyramid
-Mroot=measure.zig -Mpyramid=src/pyramid.zig`, real 2^24 chunks) added 1 h of 30 kHz x 72
history columns (40 raw + 32 slots, with TTL words), in blocks of 256 rows:

    3600.0 s of 30 kHz x 72 columns (40 raw), 421875 add calls of 256 rows
    add: total 7.306 s, 2.029 ms per second of data = 0.203 % of real time; mean 17.3 us per call; worst call 49.67 ms at sample 83886080
    bytes held after the run: 709525600 (709.5 MB; chunks of 2^24 samples are allocated whole)
    one chunk's stretch (559.2 s) on every level: 101360800 bytes -> 652.5 MB per hour

- **RAM: 652.5 MB per hour** at 72 history columns (709.5 MB held after 1 h, because the 7th
  chunk is allocated whole). The 1.5 GB budget holds about 2.3 h with every level kept.
  Releasing level 0 (about 3/4 of the bytes) stretches that roughly 4x.
- **`add`: 2.0 ms per second of data, 0.20 % of real time** on the display thread (a
  first run gave 2.24 ms, 0.22 %). That is under 1 %.

### Unexpected

1. **A 50 ms `add` call every 9.3 min.** The worst call (49.7 ms; 51.4 ms in the first run)
   falls on a chunk boundary (sample 5 x 2^24). There the new chunk on every level (about
   100 MB at 72 columns, 75 MB of it level 0) is allocated and set to "empty" on the display
   thread, which touches every page. The mean is fine; this costs a few dropped frames per
   chunk. Not changed, since the plan fixes the chunk size. Options for whoever wires it:
   allocate the next chunk ahead of time on the idle thread, or store (min, max) so that
   zero bytes mean empty and take lazily zeroed pages (mmap), which spreads the cost over
   the writes.
2. **`Panel.signalSignature` does not cover a TTL panel's lanes** (its `rows` and
   `ttl_lines`), nor a panel's row count or kind. It hashes the filter, per-row raw/hidden
   and the reference only. So `Review.follow` keeps its old feed when a TTL panel gains a
   lane, and its rows then have the old width (found by the follow test). That is why
   `Backfill.follow` makes its review afresh. The overview's wiring ("`signalSignature`
   changes restart the slots' part") would miss such a change too. I think the signature
   (or whatever triggers `resetSlots`) is what is wrong. `review.zig` and `panels.zig` were
   not changed.
3. A test that crashes (panics) leaves its `/tmp/dimna-pyramid-test-<pid>` folder behind,
   because `defer` does not run. Failing runs during this work left three such folders,
   which I removed by hand. The existing review test has the same weakness.

### Not covered

- Threads, queues, wiring, the GUI and the GPU (by the plan). Nothing here ran against the
  board or the GUI, and `dimna-headless` was not run.
- `add` given the same samples twice, or out of order, merges them. That is fine for raw
  data and wrong if the values differ. Not tested.
- The merge branch of `put` (level below released) was tested only with levels 0 and 1
  both released. Level 1 released with level 0 held cannot happen, since level 0 goes first.
- The budget is enforced only after `add` and `put`, so a single call can go over it by the
  chunks it allocates before releasing. If the budget is still exceeded once only the live
  chunk and levels 2 and up are left, it stays exceeded (nothing is logged here).
- The cost of `columns` was not measured (about 1920 x up to 6 buckets x the requested
  columns).
- Sample numbers below 0 are refused (`error.NegativeSample`; `columns` returns false).
