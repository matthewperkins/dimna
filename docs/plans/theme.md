# Plan: named colours, and the rest of the label formatting

Read `docs/plans/README.md` first. Refactoring plan (rule 8): every pixel stays the colour
it is.

## Why

`docs/readability-review.md` items 16 and 6. Colours are written as `.{ r, g, b, a }`
literals where they are used: about 18 in `src/gui/display.zig`, 6 in `tiles.zig`, 9 in
`ui.zig`, and a few elsewhere, with near-identical ambers repeated. A reader cannot tell
whether two ambers differ on purpose. And `display.zig`, `tiles.zig` and `main.zig` still
format labels with `bufPrint(...) catch ""`.

## What to build

1. **`src/gui/theme.zig`**: named constants for every colour the GUI draws with, grouped
   by what they mean (trace colours, text, dim text, the warning and alarm colours, note
   markers, the "heard" channel colours, off-scale, panel chrome, widget colours in
   `ui.zig`). First make a table of every literal: file, line, value, what it colours.
   Put that table in your report. Then:
   - literals with the same value and the same meaning share one name;
   - literals with the same value but different meanings get two names (equal today);
   - **near-identical values are NOT merged.** List them in your report as candidates for
     the owner to decide (for example the ambers `255,205,120`, `255,225,120`,
     `255,190,90`), each with where it is used. Keep each exactly as it is, under its own
     name.
   The shaders (`src/gui/shaders/*.frag`, `*.vert`) have their own palette for traces: do
   not change the shaders, but note in `theme.zig`, by a comment, which constants must
   match a shader value and where, after checking that they do match today (report any
   that do not).
2. **The remaining `catch ""` on label formatting** in `src/gui/display.zig`,
   `src/gui/tiles.zig` and `src/gui/main.zig`: use `format.fmt` (the truncating formatter
   in `src/gui/format.zig`; read its doc comment). A `catch` that is not label formatting
   is left alone, with a one-line comment saying what is given up if it has none.

## Files you may change

`src/gui/theme.zig` (new), `src/gui/display.zig`, `src/gui/tiles.zig`, `src/gui/ui.zig`,
`src/gui/control.zig`, `src/gui/font.zig`, `src/gui/main.zig`, `src/gui/notes.zig` (only
if it holds a colour). Not `src/gui/session.zig`, not the shaders, not anything under
`src/` outside `gui/`: another agent is working there.

## Evidence

You may not open windows (rule 2). So:

- A script (keep it out of the repository, in your /tmp folder) that extracts every
  colour value used in the GUI sources before and after, resolving your new names to
  their values, and shows the multiset of (file, value) is unchanged. Give its output.
- The existing GUI tests (`zig build test --summary all`) inspect quads' rectangles; if
  any also checks a colour, it must still pass unchanged.
- The lead will compare screenshots before merging.

## Done means

No `.{ N, N, N, N }` colour literal left in the GUI outside `theme.zig` (show the grep;
say what the remaining matches are, if any, and why they are not colours);
`zig build --release=safe` builds; tests pass; `zig fmt --check src build.zig` prints
nothing; the table and the list of near-identical values are in the report.
