# Plan: setting a threshold in the spike-tile window

Read `docs/plans/README.md` first. This plan adds behaviour the owner asked for.

## What exists (read first)

- `src/gui/tiles.zig`: the tile window (one tile per electrode: waveforms, the
  threshold as a red line, sigma, rate; scales with an undo history in
  `src/tile_scale.zig`; port chips; focus and listening by requests to the display).
  Its tests include a stored-output test against `src/gui/testdata/tiles_draw.txt`
  (`OEZ_TILES_DRAW_OUT` regenerates) and a scripted-input parser (`OEZ_TILE_CLICKS`).
- One detection threshold per channel (`src/thresholds.zig`), owned by the display.
  The tile window gets it in `tile_link.Config.thresholds` and asks for a change with
  `tile_link.Request.threshold { channel, uv }` (`uv` 0 = follow the noise). It never
  changes a threshold by itself: it sends the request and draws what `Config` says.
- `src/gui/window.zig`: `Input.left_down`, `shift`, `ctrl`, `alt`, `scroll_y`;
  `Window.setCursor(.default | .grab | .grabbing)`.

## What to build

1. **Drag the red line.** With the pointer within 4 px of a tile's threshold line
   (inside that tile), the pointer is a hand (`.grab`); pressing the left button there
   and moving drags it (`.grabbing`): each movement sends
   `Request.threshold` with the µV value under the pointer, by the inverse of the
   mapping that draws the line (in the tile's present vertical scale; write the pair of
   functions together and test that they round-trip). Crossing zero changes the sign,
   which is intended (a positive threshold is detected rising). Releasing ends it. A
   press that starts a drag does not also focus the tile. Draw the line where the
   pointer is while dragging (do not wait for the display's answer: at 20 pictures a
   second the round trip would lag), then follow `Config` again once the drag ends.
   Requests go through a 32-entry queue the display drains every few milliseconds: send
   at most one per picture.
2. **Ctrl+Shift+wheel** over a tile: that channel's threshold by 5 % per click (the
   same proportion as the scale wheel in `tile_scale.zig`), larger in magnitude for the
   direction that makes the tile's waveforms larger with the plain wheel; say which. A
   channel following the noise is taken at its present value first.
3. **`n`** toggles the threshold of the tile under the pointer between following the
   noise and fixed: fixed -> `uv = 0`; following the noise -> fixed at its present
   value.
4. **What a tile shows**: beside sigma, a fixed threshold as its value ("-52 µV", in a
   colour that sets it apart from one that follows the noise; a new theme constant),
   where there is room; a threshold that follows the noise shows nothing new. The
   strip along the bottom keeps what it has.
5. **Scripted input**: extend `OEZ_TILE_CLICKS` so a test can press, move and release
   (say `p` press, `v` move, `l` release as actions, and `XN` for Ctrl+Shift+wheel),
   keeping what exists working; document it where the format is documented.
6. The file's header comment, and the usage of these in it.

## Tests

Unit tests: the line's y <-> µV round trip in auto and fixed scales; hit-testing (4 px,
inside the tile, not on the chips); a drag from press to release, the requests it sends
(at most one per picture, the last at the release position), a sign change, and that it
sends no focus request; Ctrl+Shift+wheel from a fixed and from a following threshold;
`n` in both states; the scripted-input parser's new actions. The stored test: existing
states unchanged except where a fixed threshold's text is now shown (there should be
none by default: show the diff); new states: a fixed negative and a fixed positive
threshold with their text, and a drag in progress. Break-it-on-purpose for each.

## Files you may change

`src/gui/tiles.zig`, `src/gui/testdata/tiles_draw.txt`, `src/gui/theme.zig` (new
constants at the end of the tile section), `src/gui/env.zig` (the `OEZ_TILE_CLICKS` doc
line). Not `tile_link.zig`, `thresholds.zig`, `display.zig`, `main.zig`, `window.zig`,
`README.md`: if you need something there, say so in your report.

## Evidence and done

No windows (rule 2). Builds; `zig build test --summary all` passes (counts before and
after); `zig fmt --check src build.zig` prints nothing; no new line over 140 characters;
no function over about 80 lines; the report lists every decision left to you.
