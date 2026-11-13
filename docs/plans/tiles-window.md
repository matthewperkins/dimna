# Plan: the spike-tile window: scales with a history, ports, focus

Read `docs/plans/README.md` first. This plan adds behaviour (it is not a refactor), agreed
with the owner in detail; where it is specific, follow it to the letter, and where it is
silent, say what you chose in your report.

## What exists

`src/gui/tiles.zig`: a window with one tile per electrode (last 16 spike waveforms
overlaid, the detection threshold, noise sigma, firing rate), on its own thread with its
own detector (`src/spikes.zig`). Today each tile scales itself to its own waveforms, a
left click listens to the channel, and an amber frame marks a channel listened to.

Already in place for you (read these first; do not change their meaning):

- `src/gui/tile_link.zig`: what the tile window and the display exchange. `Config`
  (from the display: `listening`, `focus`, references), `Request` (to the display:
  `.focus`, `.unfocus`, `.listen`), `Report` (to the display: the focused channel's
  threshold in µV, and the tile window's `view`), `Shared.initial_view`. The tile window
  never changes focus or listening by itself: it sends a request and draws what `Config`
  says.
- `src/tile_view.zig`: `TileView { port: ?u8, range_uv: [max_tiles]f32 }` (0 = that tile
  scales itself), saved by the display thread in `views.toml`.
- `src/gui/window.zig` `Input`: `clicks` (left), `right_clicks`, `middle_clicks`,
  `scroll_y`, `ctrl`, `shift`, `keys` (`Key`: `.char` or `.named`; `key.is('u')`).
- `src/gui/theme.zig`: `focus` (the amber). `src/gui/font.zig` draws "♪" (U+266A).

## What to build

### 1. The scale model: `src/tile_scale.zig` (core, pure, tested)

No GUI types, no clock of its own (times are passed in), so every rule below has a unit
test. Export it from `src/root.zig`.

A tile's **range** is the µV from zero to the tile's edge (the picture is
zero-centred as today). Range 0 means the tile scales itself to its own waveforms
("auto"), as all tiles do at start.

- **Auto range of a tile**: what the present code computes (`max(8 sigma, 1.15 x the
  largest sample of the waveforms shown)`, at least one LSB), in µV. The model is given
  these as numbers; it does not know the detector.
- **Wheel** (all tiles): if no tile has a fixed range yet (all auto), first set every
  tile to one common range, the **largest** of the tiles' auto ranges at that moment;
  remember it as the **initial common range**; push that state onto the history. Then,
  and on every later wheel movement, multiply every tile's range by `1.05 ^ clicks`
  (a proportion, not a number of µV; one click of a wheel is 15 axis units of
  `scroll_y`; fractional clicks from a touchpad scale accordingly). Use the sign
  convention of the display (`Display.applyInput` in `src/gui/display.zig`: which way
  the wheel makes traces larger) so the wheel feels the same in both windows; say which
  way it is. A tile that is still auto when the wheel turns (possible after an undo to a
  mixed state) takes its auto range first.
- **Ctrl+wheel** (the tile under the pointer): the same proportion for that tile alone;
  if it was auto it takes its auto range first. The others are untouched.
- **History**: an entry is the whole set of ranges. The state at start (all auto) is the
  first entry. A wheel or Ctrl+wheel change is pushed once the wheel has been still for
  `settle_ms = 750` (a named constant); `r` and `a` push at once. At most 16 entries; the
  oldest is dropped. A push after an undo discards the entries that were undone
  (ordinary undo/redo).
- **`u`** steps back one entry, **Shift+`u`** forward again; at either end nothing
  happens. If a wheel change is waiting to be pushed, `u` pushes it first, then steps
  back (so it takes back that gesture).
- **`r`**: every tile to the initial common range, and push. If there is none yet (the
  wheel was never used), it is made now, as the wheel would.
- **`a`**: every tile to its own auto range **as a fixed number** (computed now, from
  the waveforms it holds now), and push. It does not go back to continuous autoscaling;
  undoing to the first entry does.
- Ranges are clamped to a sane span (say 1 µV to 10 mV); say what you chose.
- The model also holds the port choice only if that is simpler for you; the port choice
  is **not** part of the history.

Tests: each rule above, including: first wheel from all-auto takes the largest auto
range and pushes it before scaling; 5 % per click compounds (ten clicks up then ten down
returns to the start within rounding); the settle delay (a change at t pushes at
t + 750 ms, not before; further movement postpones it); `u`/Shift+`u` at both ends; a
push after undo drops the redo entries; the 17th entry drops the first; `r` before any
wheel; `a` gives fixed numbers; Ctrl+wheel on an auto tile; undo with a pending change.

### 2. `src/gui/tiles.zig`

- **Scaling**: tiles are drawn with the model's ranges. Wheel, Ctrl+wheel, `r`, `a`,
  `u`, Shift+`u` as above (keys only when the pointer is in the window, as the window
  delivers them). Each tile shows its range in the bottom left corner in small dim text
  ("±150 µV"; a tile that is auto shows nothing there), where there is room.
- **Ports**: a strip along the bottom of the window with chips: one per port that has a
  headstage (a headstage's port is its `slot / 2`: slots are A1, A2, B1, B2, ...), and
  "All". The grid shows only the electrodes of the chosen port (All by default; from
  `Shared.initial_view.port` at start; a port with no headstage falls back to All).
  Detection goes on for every channel whatever is shown. The strip also shows the common
  range ("±150 µV"), or "auto" when every tile is auto, or "mixed". Look at
  `src/gui/ui.zig` (`Ui.chip`, `Ui.button`) before drawing chips by hand; use it if it
  fits a window that is otherwise drawn directly, and say why if not.
- **Clicks on a tile**: left = `Request.focus` with that channel; right =
  `Request.listen` (`add` = Ctrl held); middle (anywhere in the window) =
  `Request.unfocus`. A left click on a chip is the chip's, not a tile's.
- **What marks what**: the amber frame (`theme.focus`) is on the tile whose channel is
  `Config.focus`, and nothing else is amber. A channel listened to has "♪ " before its
  name; its name and waveforms are the ordinary colours. A channel can be both.
- **Report** (`Shared.report.publish`): the threshold of the focused channel in µV
  (`det.threshold(unit) * types.electrode_uv_per_bit`; negative), `threshold_valid`
  false when nothing is in focus or the channel is not an electrode; and `view` (port and
  ranges). Publish when something in it changed, and the threshold at most about ten
  times a second (it moves with the noise).
- **Start**: ranges and port from `Shared.initial_view` (a range of 0 is auto). They
  form the first history entry.
- **Scripted input for tests** (`OEZ_TILE_CLICKS`, parsed in `tiles.zig`; read from
  `Env.tile_clicks`): extend the format so a test can do everything above, keeping the
  present form working ("SECONDS:X,Y" = left click; negative X = with Ctrl). Suggested:
  an optional fourth field: `r` right click, `m` middle click, `wN` wheel by N axis
  units, `WN` Ctrl+wheel, `kC` key C, `KC` Shift+key C. Document it where the present
  format is documented (the comment in `tiles.zig`, and the one line in
  `src/gui/env.zig`).
- **Header comment** of `tiles.zig`: bring it up to date.

### 3. A stored-output test of what the tile window draws

As `src/gui/control.zig` ("the control window's layout is unchanged") and
`src/gui/display.zig` ("what the display draws is unchanged") do: run the drawing on a
few states with the hand-made 8 px font and compare everything drawn (rectangles, text,
colours, in order) with `src/gui/testdata/tiles_draw.txt`; `OEZ_TILES_DRAW_OUT=<path>`
regenerates. States: all auto, no focus; a common range with one tile's own range; focus
on one tile and two channels listened to (one of them the focused one); port A only on a
two-port layout, and a layout with three headstages on two ports; a small window (no
room for the range text or the rate); 64 + 16 electrodes. The detector's units need
waveforms: feed `spikes.Detector` a deterministic stream as `src/independence_test.zig`
does. This test is the baseline for whoever changes the tiles next; in your report, show
it failing for three one-line changes.

## Files you may change

`src/tile_scale.zig` (new), `src/root.zig` (one line), `src/gui/tiles.zig`,
`src/gui/testdata/tiles_draw.txt` (new), `src/gui/theme.zig` (new constants only, at the
end of the tile section; another agent adds display constants elsewhere in the file),
`src/gui/env.zig` (the one doc line for `OEZ_TILE_CLICKS`). Not `tile_link.zig`,
`tile_view.zig`, `window.zig`, `main.zig`, `display.zig`, `README.md` (the lead does the
README): if you need something changed there, say so in your report.

## Evidence

No windows (rule 2): you cannot see the tile window. The unit tests of the model and the
stored-output test are your evidence, with break-it-on-purpose for both. The lead will
run the window on the simulator and on the board.

## Done means

`zig build --release=safe` builds; `zig build test --summary all` passes (counts before
and after); `zig fmt --check src build.zig` prints nothing; no new line over 140
characters; no function over about 80 lines; the report lists every decision the plan
left to you.
