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

### Before (2026-11-13, commit 0c2ec9e)

Board, 16 + 16 electrodes + 8 ADC (72 history columns, 151 MB, on the card), DP-2
1920x1080 fullscreen with tearing, no audio, no control or tile window, all three panels
at the same time base, `DIMNA_FRAME_DEBUG=1`, last three seconds of each run:

| time base | mode | GPU ms per frame | latency ms (avg) | fps |
|---|---|---|---|---|
| 2 s | scroll | 0.9 | 2.7 | 290 |
| 2 s | sweep | 0.9 | 2.7 | 305 |
| 10 s | scroll | 2.4 | 4.0 | 371 |
| 10 s | sweep | 2.4 | 4.0 | 368 |
| 20 s | scroll | 6.75 | 8.5 | 140 |

So the latency already grows with the time base: the frame's GPU time is added to it.
No blocks lost in any run. (A top-level `span_s` in the config is ignored without a
warning; the runs set it per panel.)

### After phase 1 (2026-11-13)

Same conditions; 151.0 MB of samples and 37.7 MB of buckets, both on the card.

| time base | mode | GPU ms per frame | latency ms (avg) | fps |
|---|---|---|---|---|
| 2 s | scroll | 1.05 | 2.5 | 275 |
| 10 s | scroll | 0.97 | 2.4 | 280 |
| 20 s | scroll | 0.95 | 2.6 | 280 |
| 30 s | scroll | 1.1 | 2.4 | 280 |
| 30 s | sweep | 0.7 | 2.4 | 290 |

Screenshots of DP-2 looked at: 30 s scroll after 37 s (full width drawn); 30 s sweep after
65 s (cursor a sixth across, the earlier pass whole); 30 s sweep with panel 1's filter
switched off at 62 s (both passes redrawn unfiltered; the frame that did it took 0.81 s).
No blocks lost. Not done: the review buffer's place (needs a recording), 80 channels.
