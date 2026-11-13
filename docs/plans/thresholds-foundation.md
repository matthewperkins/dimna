# Plan: one detection threshold per channel (the foundation)

Read `docs/plans/README.md` first. This plan changes behaviour, as agreed with the owner.
It lays the foundation only: the state, the detector, the plumbing and the saving. The
ways to *set* a threshold by hand (dragging the line on the display, the wheel on a
tile, the control window's layout) are three later plans; this one must leave the
program working, with the simplest controls that keep every setting reachable.

## Why

Today there are two thresholds that can disagree for one channel:

1. The spike tiles' detector (`src/spikes.zig`, run in the tile window's thread):
   4.5 sigma below zero for every electrode, the 4.5 fixed in the code, sigma following
   the noise. It is what the tiles show, and what the display draws as a red line on the
   focused channel's trace.
2. A triggered-sweep panel's slope trigger (`src/slope.zig`, run by
   `Display.feedBlock`): per panel, either "follows the noise" (4.5 sigma, its own
   estimate) or a fixed µV level, rising or falling, kept in `Panel.trigger` (`auto`,
   `level_uv`, `rising`, `level_now_uv`) and drawn as a dashed amber line.

The owner wants **one threshold per channel**: what a tile shows is what triggers a
sweep.

## The model

For each electrode, a threshold that is either

- **following the noise**: `-sigmas x sigma`, with `sigmas` one global number that can be
  4, 4.5, 5, 5.5 or 6 (default 4.5), or
- **fixed**: a signed number of µV. Its **sign is the slope**: a negative threshold is
  crossed falling (a trough follows), a positive one rising (a peak follows).

Rules:

- The tile detector uses each channel's threshold (fixed, or following the noise with
  the global `sigmas`).
- A triggered-sweep panel that triggers on a channel triggers at that channel's
  threshold, and that channel's threshold is then **always fixed**: when a panel starts
  triggering on a channel whose threshold follows the noise (the `s` key, a left click
  on another row of a slope-triggered panel, the control window's "spikes" button, the
  row stepper, or a config with `trigger_channel`), the threshold is **latched**: it
  becomes fixed at the value it has at that moment. The value comes from the tile
  window's report if there is one for that channel; otherwise from the slope trigger's
  own estimate as soon as it has seen one second of signal (until then the trigger
  follows the noise, as now).
- The display owns the thresholds (as it owns focus and listening); the tile window
  asks through a request and draws what it is told.

## What to build

1. **`src/thresholds.zig`** (core, pure, tested; export from `src/root.zig`):
   `Thresholds { sigmas: f32 = 4.5, fixed_uv: [max]f32 = 0 }` (0 = follows the noise;
   `max` = `tile_view.max_tiles`), with: `isFixed(ch)`; `levelUv(ch, sigma_uv)` (the
   threshold in µV given that channel's noise sigma in µV); `stepSigmas(up)` through
   `{4, 4.5, 5, 5.5, 6}`; `set(ch, uv)` clamped to a sane span (say 5 µV to 5 mV in
   magnitude, either sign; `0` or `follow(ch)` returns it to the noise); `eql`; and
   `read(doc)` / `render(w, n)` for a `[thresholds]` table of the view file, in the
   style of `src/tile_view.zig` (`sigmas = 4.5`, `fixed_uv = [...]` per electrode, 0 =
   follows the noise, values to a hundredth of a µV). A file without the table, or with
   nonsense in it, gives the defaults.
2. **`src/spikes.zig`**: the detector takes a `Thresholds` (a field the tile thread sets
   when the display's `Config` changes) instead of its `sigmas`. Per unit the level is
   `thresholds.levelUv(...)` in sample units. A positive level is detected rising and
   aligned on the **peak** within the same 0.5 ms; a negative one as now. (See how
   `slope.zig` folds the two slopes into one comparison with a sign.) `threshold(u)`
   keeps returning the level in use, in sample units (now of either sign). Changing a
   threshold mid-stream must not produce a spurious detection from stale state. Tests:
   a fixed negative level finds what the sigma rule found on the existing test's
   stream; a fixed level beyond the spikes finds none; a positive level finds the
   positive phase and aligns on its peak; `sigmas` 6 finds no more than 4.5.
3. **`Panel.trigger`** (`src/panels.zig`): remove `auto`, `level_uv`, `rising` and
   `level_now_uv`: they are the channel's threshold now. `holdoff_ms`, `row`, `source`,
   the windows and `overlay` stay. The config and view-file keys `level_uv`,
   `level_auto` and `slope` stop being panel settings: `renderViews` no longer writes
   them, and reading must **accept and ignore** them (the owner's `views.toml`, written
   by the present version, has them), with one log line saying they are no longer used.
   Check how unknown keys are treated today before choosing how to ignore these three.
   `session.carryOver` loses the three lines.
4. **`src/gui/display.zig`**: `Display` gets `thresholds: Thresholds` and what the tile
   window last reported for every channel. One function answers "this channel's
   threshold in µV, if known": the fixed value, or else the reported one.
   `focus_threshold_uv` goes: the focused row's line uses that function. `feedBlock`
   builds the slope trigger's settings from the trigger channel's threshold (fixed:
   that level, `rising` from its sign; not yet fixed: follow the noise with the global
   `sigmas`, and latch as described). The dashed level line of a triggered panel and
   `trigText` use the same function. `applyInput`: `s` and the left click that moves a
   slope trigger latch. The three `PanelAction`s `trig_rising`, `trig_auto`,
   `trig_level` go; in their place the display handles a new edit (below).
5. **`src/gui/control.zig`**: `Edit` gains `threshold: ThresholdEdit`, a union:
   `sigmas: bool` (one step up or down), `scale: { channel, factor }` (multiply a fixed
   threshold; a channel following the noise is latched first), `set: { channel, uv }`,
   `follow: u32` (back to the noise), `flip: u32` (change sign). `main.zig`'s switch
   handles it by calling one function on the display. In the panel's trigger section,
   replace the falling/rising and follows-noise/fixed buttons and the level stepper
   with: the level of the trigger channel with a − / + stepper (`scale`, 15 % a step, as
   the old stepper), and a "falling | rising" pair that flips the sign. Somewhere
   sensible (say after the Audio section) one row "spike threshold" with a − / +
   stepper showing "4.5 σ". Do not redesign the window: a later plan does. The snapshot
   needs the thresholds and the reported values the control window shows.
6. **`src/gui/tile_link.zig`**: `Config` carries the `Thresholds`; `Request` gains
   `threshold: { channel: u32, uv: f32 }` (0 = follow the noise); `Report` carries every
   electrode's threshold in use in µV (replacing the single focused one; a count says
   how many are valid). **`src/gui/tiles.zig`**: the detector gets the thresholds from
   `Config`; the report is filled for every electrode (still at most ten times a
   second); nothing else changes there (no new controls: a later plan). Keep its tests
   meaningful: adapt them, do not delete them.
7. **Saving**: `session.ViewFile.View` and `files.renderViews` include the thresholds
   (`[thresholds]`), `main.zig` reads them from the view file at start, and they survive
   a restart of acquisition (`src/gui/pipeline.zig` makes a new `Display` in `assemble`:
   carry the thresholds over as the tile view is carried). The view counts as unsaved
   when they change.
8. **README**: the slope-trigger and tile passages, the config-key list (the three keys
   that are gone), `[thresholds]`. Keep it short.

## The stored tests

Three files record what is drawn: `src/gui/testdata/control_layout.txt`,
`display_frame.txt`, `tiles_draw.txt` (each test has an environment variable that writes
the present output, named in its source). This plan changes them deliberately in a few
places. For each file: regenerate, and put in your report the **complete** diff against
the old file with every hunk explained (the trigger section of the control window, the
new threshold row and the positions below it; trigger titles on the display; nothing in
the tiles unless a threshold value moved, which it should not with default settings).
A hunk you cannot explain is a mistake to find.

## Files you may change

`src/thresholds.zig` (new), `src/root.zig`, `src/spikes.zig`, `src/panels.zig`,
`src/gui/display.zig`, `src/gui/control.zig`, `src/gui/tile_link.zig`,
`src/gui/tiles.zig`, `src/gui/main.zig`, `src/gui/session.zig`, `src/gui/files.zig`,
`src/gui/pipeline.zig`, `src/gui/testdata/*.txt`, `src/independence_test.zig` (it runs a
detector and builds panels), `README.md`, and any test that constructs the things
above. `src/slope.zig` only if it truly needs it (say why).

## Evidence

No windows (rule 2). Unit tests for `thresholds.zig`, the detector, the latching rule
(a test that drives `Display.feedBlock` and `applyInput`: a channel following the noise
becomes fixed when a panel starts triggering on it, at the reported value if there is
one, else after one second of signal; a fixed one is left alone), the request and
report, and reading a view file written by the present version (with `level_uv`,
`level_auto`, `slope` in it) without an error. Break-it-on-purpose for each new test.
`oez-headless --sim 32,16 --seconds 5` still CLEAN (it does not use any of this, but it
shares the core).

## Done means

`zig build --release=safe` builds; `zig build test --summary all` passes (counts before
and after); `zig fmt --check src build.zig` prints nothing; no new line over 140
characters; no function over about 80 lines; `grep` shows no use left of
`trigger.auto`, `trigger.level_uv`, `trigger.rising`, `level_now_uv`,
`focus_threshold_uv` or the detector's own `sigmas`; the report lists every decision
the plan left to you, and anything that looked wrong and was left alone.
