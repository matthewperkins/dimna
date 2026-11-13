# Plan: the control window in sections that open and close

Read `docs/plans/README.md` first. This plan changes the control window's layout as the
owner asked: less on screen at once, the detail one click away.

## What exists (read first)

`src/gui/control.zig`: `build` calls one function per section (`titleSection`,
`statusSection`, `recordSection`, `reviewSection`, `notesSection`, `audioSection`, a
"spike threshold" row, `boardSection`, and per panel `panelSection` with `panelView`,
`panelFilter`, `panelCar`, `panelTrigger`). The window is drawn with `src/gui/ui.zig`
(immediate mode: the order of calls is the layout). The test "the control window's
layout is unchanged" compares everything drawn, and every edit each click queues, with
`src/gui/testdata/control_layout.txt` (`OEZ_CONTROL_LAYOUT_OUT` regenerates). A click
queues a `control.Edit`, handled once in `src/gui/main.zig`.

## What to build

1. **Sections that open.** Each of these is one summary line with its heading; a click
   on the heading (make it look clickable: a small ▸ / ▾ before it, if the font has
   them; `src/gui/font.zig` takes a character the display font lacks from another font
   when it is in `extra_cps`) opens the section's controls below it, another closes it:

   | section | the summary line | opens to |
   |---|---|---|
   | Notes | how many presets, and the last note with its time | presets and recent notes |
   | Audio | on or off, volume, the channels listened to, latency | everything it has now |
   | Spikes | "threshold 4.5 σ" with its − / + (always usable, open or not) | (nothing more) |
   | Headstages | sample rate, amplifier band, DSP on/off, which headstages are 16 of 32 | everything it has now |
   | each panel | name, view mode, time base and scale, as text | view, filter, rows shown, reference, trigger |

   Always shown, as now: the title and status line with Save view and Quit, the alarm
   row, Record with its state, and the quit prompt when it is up.
2. **The Review section goes** (its buttons, `reviewSection`, and the `Edit.review`
   case if nothing else uses it; `ReviewAction` itself stays, the display's keys use it,
   and another agent is adding a case to it: do not touch its definition). Review is
   driven from the display now (Shift+wheel, keys, `l`).
3. **Headstages opens by itself** while a restart is pending or the settings differ
   from the config file, so "Apply" and "Save as default" cannot be hidden when they
   matter; it can be closed again only when neither holds.
4. **Which sections are open is remembered**: at start all are closed (Headstages
   subject to rule 3). The state lives in the control window; to save it with "Save
   view" it has to reach the display thread, which writes `views.toml`: report it the
   way the tile window reports its view (`src/gui/tile_link.zig`, `src/tile_view.zig`,
   `session.ViewFile.View`, `files.renderViews`, and how `main.zig` reads the view file
   at start and hands the initial value over): a small plain struct (which sections are
   open; panels by name), a `[control]` table in the view file, an `Edit` case that
   carries it to the display thread when it changes, and the initial value handed to
   the control thread before it starts. The view counts as unsaved when it changes.
5. Keep every existing control reachable and every existing `Edit` unchanged in what it
   does. Do not change `ui.zig`'s existing widgets' behaviour; add to it what a heading
   that toggles needs.

## The stored test

It will change a great deal, by design. To keep that reviewable:

- First add to the test a state for each section open (one at a time) and all open,
  **before** changing the layout, so that after the change "all open" can be compared
  with the old layout: with every section open, every control that existed before must
  still be drawn and must queue the same edit when clicked. Show that comparison in
  your report as a list of (label, edit) pairs before and after, order aside: the only
  differences allowed are the Review buttons (gone) and the new headings.
- Then states for: all closed; Headstages forced open by a pending restart and by
  unsaved settings; one panel open among several; the summary lines' texts for a
  triggered panel, a filtered one, a TTL one.

## Files you may change

`src/gui/control.zig`, `src/gui/ui.zig`, `src/gui/testdata/control_layout.txt`,
`src/gui/font.zig` (`extra_cps` only), `src/control_view.zig` (new, core, with a test,
exported from `src/root.zig`), `src/gui/session.zig` and `src/gui/files.zig` (the view
file only), `src/gui/main.zig` (only: the `Edit` switch, reading the view file at start,
the saved view), `src/gui/theme.zig` (new constants in the widget section). Another
agent is working in `display.zig`, `session.zig` (review only), `main.zig` (the cursor
and the review keys) and adds a `ReviewAction` case in `control.zig`; a third in
`tiles.zig`. Keep your hunks in the shared files small.

## Evidence and done

No windows (rule 2): the stored test, the before/after list of controls and edits, unit
tests for the view struct and its table, break-it-on-purpose. Builds;
`zig build test --summary all` passes (counts before and after);
`zig fmt --check src build.zig` prints nothing; no new line over 140 characters; no
function over about 80 lines; the report lists every decision left to you. The lead
will look at the window.
