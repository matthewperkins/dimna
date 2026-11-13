# Long time bases: 30 s live, up to 2 h in review

Agreed with the owner on 2026-11-13. This file is the overview; the delegated pieces have
their own plans (`pyramid-store.md`, later `pyramid-review.md`).

## Why

The display needs one (min, max) per pixel column and DP-2 is 1920 columns wide. Today the
shader reads every sample in every column from a ring of raw int16 (2^20 samples, 35 s:
151 MB at the rig's 72 history columns). The memory dimna can write directly on the card
is 246 MiB, so the ring cannot grow, the review buffer (same size) does not fit beside it,
and 80 channels (335 MB) fall back to host memory at about 30 fps. The shader's work also
grows with the span.

## Decisions

- Live time base up to 30 s, in scroll and in sweep (a sweep shows two passes: 60 s).
- Review up to 2 h (the whole session if it is shorter), only while recording.
- 1.5 GB of RAM for the pyramids; the finest level's oldest part is released first.
- At 80 channels the raw ring may shrink to 17 s (that limits how far back overlaid
  triggered sweeps reach).

## Phase 0: measure (board)

GPU time per frame and display latency at 2, 10 and 20 s, scroll and sweep, DP-2 with
tearing; where the review buffer is allocated. Results: see "Measurements" below.

## Phase 1: a decimated level on the card (not delegated)

- A second ring beside the raw one: (min, max) per 16 samples of every history column,
  2^17 buckets (70 s): 38 MB at 72 columns.
- The feed's rows are folded into it as they are written; the newest, partial bucket is
  rewritten each block. Same direct-write path as the raw ring.
- `traces.vert`: a panel whose pixel columns hold 64 samples or more reads buckets, else
  samples as now. Triggered sweeps always read samples.
- Sizes from the budget: the decimated ring first, then the largest power of two of raw
  samples that fits.
- `span_max` and `sweep_span_max` become 30 s.
- Evidence: the decimated ring equals brute force (across the wrap, with a partial
  bucket, after a refilter); the stored display frame; Vulkan validation; phase 0 again.

## Phase 2: pyramids in RAM for review

- `pyramid-store.md` (delegated): the store, built from history rows, levels of 64
  samples and x4 upward, queried per pixel column, with a RAM budget and a backfill from
  the recording.
- Wiring (not delegated): the display thread adds the live feed's rows; a thread at idle
  priority backfills; `signalSignature` changes restart the slots' part.
- `pyramid-review.md` (to write): review at long spans uploads one (min, max) per pixel
  column instead of samples; the review sample buffer shrinks to about 9 s.

## Not relied on

Resizable BAR (unverified whether the firmware offers it); staging uploads into the 16 GiB
heap (adds a GPU copy per frame and does not reduce what the shader reads).

## Measurements

(filled in as they are made)
