# Plan: get the GUI's pure logic under `zig build test`

Read `docs/plans/README.md` first.

## Why

`zig build test` builds `src/root.zig` only. Nothing under `src/gui/` is ever compiled as
a test: the one test there (`src/gui/control.zig`, "edits queue and snapshots cross
between the two sides") has never run. `src/gui/notes.zig` is all logic (typing, UTF-8
backspace, drafts, presets) and has no test at all.

## What to build

1. **A test step for the GUI module** in `build.zig`, run by `zig build test` together
   with the core's tests. The GUI module imports Wayland, Vulkan, FreeType and so on
   (see how `gui_mod` is set up); the test binary needs the same imports and libraries to
   compile, but **no test may connect to Wayland, create a Vulkan instance, open a sound
   device or open a window**: tests must pass on a machine with no display. A test root
   such as `src/gui/tests.zig` that references the files with tests is the expected
   shape; find out what Zig 0.17.1 needs for tests in imported files of a module to be
   collected (a test in a file that is merely imported is not run unless referenced from a
   `test` block; `src/root.zig` shows the pattern, and a previous agent found that a
   non-`pub` import was silently skipped). Prove the existing `control.zig` test now runs:
   make it fail on purpose once.
2. **Tests for `src/gui/notes.zig`** (`Notes.handle` and what surrounds it). Read the
   file's header for what the keys do. Cover at least: `/` opens a note and the keys that
   follow are text, not shortcuts; Enter saves it with the stamp it was opened at; Esc
   drops it; Tab keeps it as a draft and backtick stamps a draft; Backspace removes one
   whole UTF-8 character (test with a two-byte and a three-byte character, and at an empty
   note); a note longer than the buffer is cut without splitting a character (if the code
   does not guarantee that, report it, do not fix it); presets 1 to 9 stamp only when no
   note is open; `fresh` holds what was saved this turn. `Notes` appends to a log file
   under `XDG_STATE_HOME`: find how the path is chosen and make sure the tests never write
   under the owner's home (rule 3). If that needs a small change to `notes.zig` (a way to
   give it the folder, or to turn the log off), make it and describe it.
3. **Tests for the tile grid** in `src/gui/tiles.zig` (`Grid`: how many columns and rows
   for N tiles in a rectangle, which tile a pixel is in) and for the layout arithmetic of
   `src/gui/ui.zig` (wrapping of a row of chips, the rectangle a button gets), as far as
   they can be called without a GPU. If a function mixes arithmetic with drawing so that
   it cannot be tested, do not restructure it: list it in your report.
4. Mention the GUI tests in the README where it says what `zig build test` covers.

Each test goes at the **end** of the file it tests. For each group, break the code under
test on purpose once and show the test fails.

## Files you may change

`build.zig`, `src/gui/tests.zig` (new), `src/gui/notes.zig`, `src/gui/tiles.zig`,
`src/gui/ui.zig`, `README.md`. In `notes.zig`, `tiles.zig` and `ui.zig`: tests at the end,
`pub` added where a test root needs it, and the small change item 2 allows; nothing else.
Do not change `src/gui/control.zig` (another agent is changing its `Shared` at the same
time; its test only has to run).

## Done means

`zig build test --summary all` shows the GUI tests running and passing (give the count
before and after); `zig build --release=safe` builds; `zig fmt --check src build.zig`
prints nothing; the tests pass with `WAYLAND_DISPLAY` unset
(`env -u WAYLAND_DISPLAY zig build test ...`); break-it-on-purpose results for the
control test, the notes tests, the grid and the ui tests; a list of what could not be
tested and why.
