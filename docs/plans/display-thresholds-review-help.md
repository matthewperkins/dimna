# Plan: on the display: drag the threshold, scroll back with the wheel, a key summary

Read `docs/plans/README.md` first. This plan adds behaviour the owner asked for; follow it
to the letter where it is specific and report what you chose where it is not. Three
parts, each its own commit; all in `src/gui/display.zig` and what it needs.

## What exists (read first)

- One detection threshold per channel (`src/thresholds.zig`; `Display.thresholds`,
  `Display.thresholdUv(ch)`, `Display.latch`, `Display.applyThreshold`): it follows the
  noise or is fixed in µV, its sign the slope. The focused channel's threshold is drawn
  on its row (`thresholdLine`, a thin red line placed by `levelPixelY`); a
  slope-triggered panel draws its trigger channel's level as a dashed line.
- `src/gui/window.zig`: `Input` has `left_down` (the left button is held), `clicks`,
  `right_clicks`, `middle_clicks`, `scroll_x`, `scroll_y`, `shift`, `ctrl`, `alt`,
  `pointer_x`, `pointer_y`, `keys`; `Window.setCursor(.default | .grab | .grabbing)`.
- Scroll-back review (`src/gui/session.zig` `ReviewSession`, driven from `main.zig` by
  the keys Space, arrows, PgUp/PgDn, Home, End, mapped to `control.ReviewAction`s).
- The stored test "what the display draws is unchanged" and
  `src/gui/testdata/display_frame.txt` (`OEZ_DISPLAY_FRAME_OUT` regenerates).

## Part 1: the threshold: drag it, toggle it, and when it latches

1. **Latching changes.** Today a panel in triggered mode on a channel latches that
   channel's threshold whenever it follows the noise (every block). The owner wants to
   be able to return a trigger channel to following the noise. So: latch **once, at the
   moment a panel starts triggering on a channel** (`s`, `t` into triggered mode with a
   channel source, a left click that moves the trigger, the control window's spikes
   button and row stepper, start-up with a config that triggers on a channel). If no
   value is known yet at that moment (no report from the tile window), remember that
   this panel still owes a latch and do it as soon as one is (the report, or the slope
   trigger's own estimate after one second, as now). After that the channel stays as the
   user sets it: a trigger channel that is put back to following the noise is triggered
   at `sigmas x sigma`, continuously, and is **not** latched again until triggering is
   started anew. Remove the rule that refuses "follow the noise" for a trigger channel.
2. **`n` toggles** the threshold of the electrode channel under the pointer between
   following the noise and fixed: fixed -> follows the noise; follows the noise -> fixed
   at its present value (`latch`; nothing if no value is known).
3. **Dragging.** Where a threshold line is drawn (the focused row's line, a triggered
   panel's level line) and the pointer is within 4 px of it vertically, inside that
   panel: the pointer becomes a hand (`.grab`); pressing the left button there and
   moving drags the threshold (`.grabbing`): the channel's threshold becomes fixed at
   the µV value under the pointer, by the inverse of `levelPixelY` (write that inverse
   beside it and test that the two round-trip), clamped as `Thresholds.set` clamps.
   Crossing the row's centre changes the sign (rising/falling), which is intended.
   Releasing ends it. A press that starts a drag must not also focus a row, move a
   slope trigger or do whatever else a left click does there; a click elsewhere does
   what it did. The display does not own the window: return what the cursor should be
   from the frame's input handling (a field on `Display`, say `cursor`) and let
   `main.zig` call `win.setCursor` with it once per turn (that one line in `main.zig` is
   allowed).
4. **One line per channel.** A triggered panel's trigger row and a focused row can be
   the same channel: draw one line, not two. Keep the trigger row's line distinguishable
   as the trigger (dashed) but in the threshold's colour; say what you chose.
5. The "thr" tag case (the row does not show the detector's band): no line, so nothing
   to drag there; `n` still works.

## Part 2: review by the wheel

The control window's Review section is being removed (another plan). On the display:

- **Shift+wheel moves back and forward in time**: it enters review when it moves back
  from live, and scrolls the review position by a tenth of the panel's time base per
  wheel click (15 axis units; proportional for a touchpad). Sideways scroll does the
  same. Scrolling forward to the live edge leaves review.
- **Alt+wheel changes the time base** (what Shift+wheel and sideways scroll do today;
  in a triggered panel, the window around the trigger). Pinch and `[` `]` keep changing
  the time base.
- **`l` snaps back to live.** The existing keys (Space, arrows, PgUp/PgDn, Home, End)
  stay.
- The display keeps showing that it is in review as it does now (the badge).
- Find how review positions are driven today (`ReviewSession.queue`, `step`, the
  `ReviewAction`s) and add what a continuous scroll needs (an action that moves by a
  number of samples is the natural shape). `ReviewAction` is defined in
  `src/gui/control.zig`: add to it there with the smallest possible hunk (another agent
  is restructuring that file), and handle it in `src/gui/session.zig`.
- A triggered panel stays live in review, as now; Shift+wheel over one still scrolls
  the others.

## Part 3: `?` shows the keys

- `?` (Shift+/ on a US layout: the window delivers the unshifted symbol with
  `in.shift`, and typed text in `in.text`; find which is reliable and say so; `/` alone
  still starts a note) shows a panel over the middle of the display listing every key
  and mouse action of the display **and** of the spike-tile window, in two columns, in
  a **fixed-width font**. Esc dismisses it (and then does not quit); `?` again also
  dismisses it. While it is shown, other keys do what they always do.
- The fixed-width font: `src/gui/font.zig` loads one face into one atlas. Add a second
  set of glyphs for fontconfig's "monospace" at the same pixel size **into the same
  atlas** (ASCII is enough; check there is room in the 512 x 512 atlas at the usual 14
  px and at 24 px, and report what happens when there is not), and a way for `Batch` to
  draw text with it. Without a monospace font the panel uses the ordinary one.
- The text of the panel is one table in the source (key, what it does), from which both
  the panel and nothing else are made; it must agree with `args.zig`'s `usage` text on
  the display's keys (bring that text up to date for this plan's changes too: Shift+wheel,
  Alt+wheel, `l`, `n`, `?`, dragging). Tile-window keys to list: wheel, Ctrl+wheel,
  Ctrl+Shift+wheel (threshold), `r`, `a`, `u`, Shift+`u`, `n`, left / right / middle
  click, dragging the red line (see `docs/plans/tiles-thresholds.md`).

## The stored test and other tests

Existing states must change only where this plan says (the trigger row's line style;
nothing else by default). Show the complete diff for them. New states: a drag in
progress (the line at the dragged value), the trigger row and focus on the same channel
(one line), the help panel (with and without a monospace face), review entered by
scrolling. Unit tests: the `levelPixelY` inverse; hit-testing the line (4 px, only
inside the panel, only where a line is drawn); a drag from press to release including a
sign change, and that it does not focus or move a trigger; `n` in each state; latching
once (a trigger channel put back to the noise stays there; starting triggering again
latches again); Shift+wheel into and out of review, Alt+wheel on the time base, `l`;
`?` and Esc (Esc with the panel up does not quit; without it, it does).

## Files you may change

`src/gui/display.zig`, `src/gui/testdata/display_frame.txt`, `src/gui/font.zig`,
`src/gui/session.zig` (review only), `src/gui/script.zig` (steps a test needs: say
`swheel=N`, `awheel=N`, `press`, `release`, `move=FX,FY`; update its comment),
`src/gui/args.zig` (usage text), `src/gui/theme.zig` (new constants in the display
sections), `src/gui/main.zig` (only: the cursor line, and the place where keys are
mapped to review actions), `src/gui/control.zig` (only: a new `ReviewAction` case).
Not `tiles.zig`, `window.zig`, `README.md`.

## Evidence

No windows (rule 2). The stored test, the unit tests above with break-it-on-purpose for
each, and the complete diff of the existing states. The lead will try it on the
simulator and the board.

## Done means

Builds; `zig build test --summary all` passes (counts before and after);
`zig fmt --check src build.zig` prints nothing; no new line over 140 characters; no
function over about 80 lines; the report lists every decision left to you.
