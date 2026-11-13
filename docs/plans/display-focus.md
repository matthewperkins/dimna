# Plan: focus on the display: the threshold line, and what clicks mean

Read `docs/plans/README.md` first. This plan adds behaviour, agreed with the owner;
follow it to the letter where it is specific and report what you chose where it is not.

## What exists

`src/gui/display.zig`: the neural display. Today a left click on an electrode row
listens to that channel (Ctrl+click adds or removes it), a row listened to has an amber
label, and `a` acknowledges an alarm. `Display.frame` is split into one function per
thing drawn, and the test "what the display draws is unchanged" compares everything it
draws in 15 states with `src/gui/testdata/display_frame.txt`
(`OEZ_DISPLAY_FRAME_OUT=<path>` regenerates).

Already in place for you:

- `Display.focus: ?u32`: the channel in focus (one, or none). The spike-tile window sets
  it through a request that `main.zig` applies; this plan lets the display's own clicks
  set it too. `Display.focus_threshold_uv: ?f32`: that channel's spike-detection
  threshold in µV (negative), as the tile window's detector last reported it; null when
  there is no focus, no tile window, or no report yet.
- `src/gui/window.zig` `Input`: `clicks` (left), `right_clicks`, `middle_clicks`,
  `ctrl`, `shift`.
- `src/gui/theme.zig`: `focus` (the amber), `tile_threshold` (the red of the threshold
  line in a tile). `src/gui/font.zig` draws "♪" (U+266A).

## What to build

Focus and listening become two things, on the display as in the tile window: **amber
means focus, a note means listening.**

1. **Clicks on an electrode row** (`Display.applyInput`): left = focus that channel
   (`self.focus = channel`); right = listen to it (`listenClick(channel, in.ctrl)`:
   alone, or with Ctrl added to or taken out of the mix); middle click anywhere = clear
   the focus. A left click no longer changes what is listened to.
2. **Row labels** (`rowLabels`): the focused channel's label is `theme.focus`; a channel
   listened to has "♪ " before its label, in the label's ordinary colour (or amber if it
   is also the focus). Nothing else is amber because of listening.
3. **The threshold line.** For the focused channel, in every electrode panel that shows
   it (the row is not hidden), when `focus_threshold_uv` is known: a thin horizontal line
   (1 px, `theme.tile_threshold`) across the panel's width at the threshold's height on
   that row, in that row's own scale (`p.rowScale(row)`), exactly as far below the row's
   centre as a trace sample of that value would be drawn (see how `triggerMarks` places
   the slope trigger's level line, and the shader `src/gui/shaders/traces.vert` for where
   a value lands in a row; the line must sit on the trace, so derive it from the same
   arithmetic and say how you checked). In scroll, sweep and triggered panels alike.
   Clamp it to the row's drawn extent as the trace is.
   The detector works on the channel band-passed 300 Hz to 6 kHz. The line is only
   honest where the row shows about that: draw it when the row goes through the panel's
   filter (`p.rowFiltered(row)`) and the band's corners are within 250..350 Hz and
   5000..7000 Hz. Otherwise draw no line and put a small tag "thr" after the row's label
   (dim), so the user sees why there is none. Make the corners' limits named constants.
4. **Shift+`a` acknowledges an alarm**; plain `a` does nothing on the display (it is the
   tile window's autoscale key). The alarm bar's hint text says "press Shift+a to
   acknowledge". The control window's Acknowledge button is untouched.
5. **Scripted input** (`src/gui/script.zig`, `--script`): add steps `rclick`, `crclick`
   (Ctrl+right), `mclick`, and `A` among the key characters for Shift+a (keep `a` as the
   plain key). Update the format comment at the top of `script.zig`.
6. **`oez --help`** (`src/gui/args.zig`, the `usage` text's "On the display" part): the
   new meaning of clicks, Shift+a, and one line on focus. The test there (every option
   the parser accepts is listed) must still pass.

## The stored test

- First, with no code change, confirm the test passes as it is.
- Your changes will alter the stored output where a heard row's label was amber, and in
  the alarm hint text. After the change, regenerate and show in your report the complete
  `diff` between the old and new file for the **existing** states: it must contain only
  those label colours, the "♪ " prefixes (and the positions they shift), and the hint
  text. Anything else is a mistake.
- Add states (appended after the existing ones, so the existing ones stay comparable):
  focus on a filtered row with a threshold (line drawn; check its y against a number you
  compute by hand in a comment); focus on a row shown raw, and on a filtered row whose
  band is 10 Hz high-pass (tag, no line); focus with no threshold reported (amber label,
  no line, no tag); focus and listening on the same channel, and on different ones; the
  focused channel in two panels at once; a focused row that is hidden; focus on a
  channel in a triggered panel and in a sweep panel.
- Unit tests for `applyInput`: left, right, Ctrl+right, middle clicks, and that Shift+a
  acknowledges and plain a does not.

## Files you may change

`src/gui/display.zig`, `src/gui/testdata/display_frame.txt`, `src/gui/script.zig`,
`src/gui/args.zig` (the usage text only), `src/gui/theme.zig` (new constants only, in
the display sections; another agent adds tile constants at the end of the tile section).
Not `main.zig`, `tiles.zig`, `tile_link.zig`, `window.zig`, `README.md` (the lead does
the README): if you need something changed there, say so in your report.

## Evidence

No windows (rule 2). The stored test, the unit tests, break-it-on-purpose for the new
states (move the line by one pixel; draw it for a raw row; make a left click listen),
and the complete diff of the existing states. The lead will look at the display on the
simulator and the board.

## Done means

`zig build --release=safe` builds; `zig build test --summary all` passes (counts before
and after); `zig fmt --check src build.zig` prints nothing; no new line over 140
characters; no function over about 80 lines; the report lists every decision the plan
left to you.
