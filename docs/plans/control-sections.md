# Plan: `control.build` as one function per section, and one way to format a label

Read `docs/plans/README.md` first. Refactoring plan (rule 8): the control window must look
and behave exactly as before, pixel for pixel.

## Why

`docs/readability-review.md` items 9 and 6. `build` in `src/gui/control.zig` is one
function of about 320 lines that lays out the whole control window: status line, the quit
prompt, recording, review, notes, audio, the headstage settings, then every panel. Each
part already starts with a comment that names it. And the file has about 33
`catch ""` / `catch {}`, nearly all on `std.fmt.bufPrint` into a buffer that is big
enough, where failing would mean a cut label; a reader has to decide for each whether it
matters.

## What to build

1. **Sections.** `build` becomes a short list of calls: one function per section
   (`statusSection`, `quitPrompt`, `recordSection`, `reviewSection`, `notesSection`,
   `audioSection`, `boardSection`, `panelSection` for one panel, or the names you find fit
   better). Each takes the `Ui`, the part of the snapshot it shows, and what it needs to
   queue an edit. Order of calls and every coordinate stay the same: the layout is
   immediate-mode, so the order of `ui.*` calls **is** the layout. Do not reorder them, and
   do not "simplify" a sequence of calls while moving it.
2. **One truncating formatter.** In `src/gui/format.zig`:
   `pub fn fmt(buf: []u8, comptime f: []const u8, args: anytype) []const u8`, which
   formats into `buf` and, if it does not fit, returns what did fit (cut at a UTF-8
   character boundary), never an error. Check what `bufPrint` leaves in the buffer on
   `NoSpaceLeft` in this Zig version before relying on it; a `std.Io.Writer.fixed` and
   `buffered()` is the other way. Tests for it go in `format.zig` (exact fit, one byte
   short, cut in the middle of a multi-byte character, empty buffer).
   Then replace the `bufPrint(...) catch ""` (and equivalents) in `control.zig` with it.
   Today a label that does not fit becomes empty; with `fmt` it becomes cut. That is the
   one intended behaviour change; list in your report any buffer where you think it can
   actually happen.
   A `catch` that is **not** label formatting (a queue that is full, a thread that did not
   start, a save) is left alone, but gets a one-line comment saying what is given up, if
   it has none.

## Files you may change

`src/gui/control.zig`, `src/gui/format.zig`. Nothing else: other agents are working in
`src/gui/gpu.zig` and in the config parsers and their callers.

## Evidence

You may not open windows (rule 2), so you cannot look at the result. Therefore:

- Before you start, record the sequence of `ui.*` calls `build` makes, as text, for a few
  snapshots: add a temporary test (the GUI module's tests run in `zig build test`; see
  `src/gui/tests.zig`) or a temporary instrumented `Ui`, whichever the code allows without
  a GPU; look at how `ui.zig` is structured and at its existing tests first. Snapshots to
  cover: not recording; recording; review active; the quit prompt up; a restart pending in
  the board section; two panels of which one is triggered with a slope trigger and one has
  a reference on; an alarm text set. After the refactor the recorded sequences (call,
  arguments, resulting rectangles) must be identical. If you can keep that as a permanent
  test with a stored expected output of reasonable size, do; otherwise describe what you
  compared and remove the instrumentation.
- If `Ui` cannot be driven without a GPU at all, stop and report that instead of
  proceeding on reading alone.

The lead will compare screenshots before merging.

## Done means

`build` is under about 40 lines and no function in the file is over about 80;
`zig build --release=safe` builds; tests pass; `zig fmt --check src build.zig` prints
nothing; the before/after call sequences are identical for every snapshot above (say how
many calls each has); break-it-on-purpose: swap two `ui` calls in one section and show the
comparison catches it; the report counts the `catch`es before and after.
