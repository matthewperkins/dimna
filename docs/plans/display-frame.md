# Plan: `Display.frame` as one function per thing drawn

Read `docs/plans/README.md` first. Refactoring plan (rule 8): every pixel the display
draws stays where and what it is.

## Why

`docs/readability-review.md` item 8. `Display.frame` in `src/gui/display.zig` is about 350
lines with ten parameters. For each panel it works out what stretch of time to show
(live, sweep, review, triggered), makes the trace draws, the triggered overlays (the
pulse shading, the trigger line, the slope level), the note markers, the tint, the sweep
cursor, the dividers, the title, the time axis and the row labels; then, once, the alarm
or warning bar, the review badge, the note being typed, and the status read-out. It is
the code that decides what the experimenter sees, and nobody can hold it in their head.

## Step 1, before changing `frame`: a stored-output test

`src/gui/control.zig` has the model: the test "the control window's layout is unchanged"
runs `build` on a set of snapshots with a hand-made `font.Font` (every glyph 8 px wide,
no FreeType), turns everything drawn into text, and compares it with
`src/gui/testdata/control_layout.txt`; `OEZ_CONTROL_LAYOUT_OUT=<path>` writes the current
output for regenerating. Read it and `src/gui/ui.zig`'s tests first.

Build the same for the display: a test in `display.zig` that calls `Display.frame` on a
set of states and writes, as text, everything it returns: every `PanelDraw` (rectangle
and every field of its `TraceParams`, the review flag, the per-row gains it refers to if
`frame` sets them), every `Fill` (rectangle and colour), and every text run and rectangle
in the batch (position, colour, string), in order. Compare with a stored file
`src/gui/testdata/display_frame.txt`, with `OEZ_DISPLAY_FRAME_OUT=<path>` to regenerate.

`frame` takes a `*const Gpu` only to read a few numbers (`extent`, `nch`, perhaps the
history's size and whether a review history exists). Find exactly which fields it and
the functions it calls read. You may not create a Vulkan device in a test. The cleanest
way is to give `frame` those numbers in a small struct of its own (a `Surface` or
`Target`: width, height, channels, ...) that `main.zig` fills from the `Gpu` at the one
call site; that is a signature change, it is allowed, and it is the only change to
`main.zig` this plan permits. If instead a `Gpu` value can be made with just those
fields set and everything else at its defaults without touching Vulkan, that is
acceptable too; say which you chose and why.

States to cover (each at a fixed `newest`, with sweeps and notes put into the `Display`
through its own functions: `feedBlock`, the trigger lists, `notes`): look at how
`control.zig`'s test builds its snapshots, and at `src/independence_test.zig` for a
deterministic stream.

1. Two electrode panels scrolling, one filtered with raw rows, hidden rows, a per-row
   scale and a reference on; an ADC panel; a TTL lane panel with named lines.
2. A sweep-mode panel (the cursor and the blank stretch ahead), with a tint line that was
   high across the cursor.
3. A triggered panel on a TTL line with several sweeps, the newest part-filled, pulse
   shading.
4. A triggered panel on a slope trigger: the level line, fixed and following the noise.
5. Notes within the window (one in this pass, one in the previous pass of a sweep panel),
   and a note being typed.
6. Review active from a file, and frozen without one: the badge, the panels showing the
   review stretch, a triggered panel staying live.
7. The alarm bar (not acknowledged, and acknowledged), and the warning bar.
8. A heard row (its label's colour), the target panel's bar, and the status read-out
   with and without a valid latency and while recording.
9. A small window (rows shorter than a line of text: labels thinned; a narrow panel
   where the time axis's left label does not fit).

Commit this step on its own, with the stored file recorded from the **unchanged**
`frame`, before step 2. Show the test can fail: three one-line changes to `frame`
(a colour, an x position, one field of a `TraceParams`), each caught.

## Step 2: split `frame`

One function per thing drawn, each named for it and taking what it needs: the panel, its
pixel rectangle, and a small value that says what time the panel shows (where the right
edge is, live or review, the sweep's pass and phase, the triggered window). Computing
that value for a panel is itself one function: it is the heart of the code, and today it
is spread through the top of the loop. `frame` becomes the list of what a display is
made of.

The order in which draws, fills and text are appended **is** what is on top of what.
Do not reorder anything. Do not "simplify" arithmetic while moving it: floating-point
expressions must stay as they are, operation for operation, or pixels move.

The stored file must not change in step 2 (not regenerated; `git diff` shows it
untouched).

## Files you may change

`src/gui/display.zig`, `src/gui/testdata/display_frame.txt` (new), `src/gui/tests.zig`
(one line, if `display.zig` is not yet listed), and `src/gui/main.zig` only at the call
of `display.frame` if the signature changes as described. Nothing else. The lead is
working in `src/gui/main.zig` and `src/gui/session.zig` at the same time (the restart of
acquisition): keep the hunk in `main.zig` to that one call, and keep the public
signatures of `makeDisplay`, `Display.init`, `feedBlock`, `applyInput`, `applyPanelEdit`
and the rest as they are.

## Evidence

You may not open windows (rule 2); the lead will compare screenshots. Yours is the
stored-output test: identical before and after for every state, with the number of
draws, fills and text runs per state in your report.

## Done means

`frame` under about 60 lines and no function in `display.zig` over about 80;
`zig build --release=safe` builds; `zig build test --summary all` passes (counts before
and after); `zig fmt --check src build.zig` prints nothing; no new line over 140
characters; the break-it results for step 1; a list of anything in `frame` that looked
wrong and was left alone (rule 8).
