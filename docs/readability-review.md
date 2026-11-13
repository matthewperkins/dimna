# A readability review of oEZ

The program was called oEZ when this was written; it is dimna now.

> **Andrew Kelley did not write, review or endorse this document, and has never seen
> this project.** It was written by Claude, the AI assistant that wrote most of this
> code, at the owner's request, as an exercise: re-read the code base and list what
> would make it easier to read, *imagining* how the author of Zig might see it. The
> opinions are the assistant's guesses at that point of view, and any resemblance to what
> he would actually say is unverified. The only words of his here are the short phrases
> in quotation marks, which are lines from `zig zen`.

The yardstick is `zig zen`, mainly "Communicate intent precisely", "Favor reading code
over writing code", "Only one obvious way to do things", "Reduce the amount one must
remember", and "Edge cases matter". A second review, in the assistant's own voice and
about different things, is in `review-as-claude.md`.

State reviewed: commit `0446c97`, 15,400 lines of Zig in 32 files. Nothing below changes
behaviour; nothing below has been done yet.

---

Okay. I read all of it. The core is in good shape: `ring.zig`, `record.zig`, `feed.zig`,
`dsp.zig`, `slope.zig`, `review.zig` each do one thing, say what it is at the top, and come
with tests that read like a description of the feature. That is the hard part and it is
done. The GUI grew by accretion and it shows in one place above all others.

## Status (2026-11-13)

Done since this was written, each with its evidence in the commit: 1 (main() is 461
lines; start-up and restart share `pipeline.zig`), 2 (the direct loop is deleted), 3, 4,
5, 6, 7, 8, 9, 10, 11, 12 (nine lines left long, each one string literal), 13, 15 (the
`*Status` values are made beside their state, `Status` is the display's, the words row,
column and slot are defined at the top of `feed.zig`; short local names in the remaining
long functions were not gone through one by one), 16, 17 (header and usage; the README
pass is not done), 18, 19, 20, 21 (except merging the threshold state machines of
spikes.zig and slope.zig, and review.zig's `fill`, tried and left as it reads better in
two branches). Not done, by the owner's choice: 14 (one test-input format). Line numbers
below are from when it was written.

## 1. The big one: `main()` is 1,005 lines

`src/gui/main.zig:1306`. One function, 99 `var` declarations, nine levels of indentation at
line 1735. To understand what happens when you press Space you have to hold the recorder,
the quit prompt, the restart, review, notes, audio and tiles in your head at the same
time, because they all live in the same scope and can all see each other's variables.
"Reduce the amount one must remember."

What I'd do, in this order, each a small commit that moves code without changing it:

1. **Give each concern a struct with its state and three methods** (`init`, `step`,
   `deinit`): `Recording` (the recorder, its status, the note queue), `ReviewSession`
   (`rv`, `reviewing`, `view_end`, `shown_end`, the file's bounds), `BoardControl`
   (`pending`, `saved_settings`, the quit prompt, save), `ViewFile` (the two render
   buffers and the path), `FramePacing` (the fifteen pacing variables at the top of the
   loop). The loop body becomes a dozen lines that name what happens each turn.
2. **Pull the restart out** (`main.zig:1867`, about 90 lines inside an `if` inside the
   loop). It rebuilds ring, feed, history, display, audio, tiles: a function
   `Pipeline.rebuild(settings)` with the "new first, then swap" rule stated once.
3. **Split the file.** `main.zig` holds argument parsing, the test-script interpreter,
   formatting helpers, `Display` (559 lines), file saving, the direct-display loop and
   `main`. Candidates: `args.zig`, `script.zig`, `display.zig`, `session.zig`, `direct.zig`.
   A file should be readable top to bottom in one sitting.

Do this before adding the next feature, not after. Every feature so far made it worse by
about a hundred lines, and the next one will too.

## 2. `runDirect` is a second, older main loop

`main.zig:1159`. It predates notes, the control window, audio, tiles and review, and has
none of them. Two loops that drift apart is a bug factory. Either the direct display
becomes a `Target` the one loop presents to (the renderer already has that union), or it
is deleted along with `lease_probe.zig` until someone needs it again. "Avoid local
maximums": it was an experiment, the experiment answered its question (tearing won), and
git remembers it.

## 3. Three copies of the same lock-free publish, four clocks, two channel namers

- The sequence-checked snapshot appears three times: `control.zig` (`Shared.publish` /
  `read`), `audio_out.zig`, `tiles.zig`. One generic `Published(T)` in one file, with the
  comment about why a torn read is detected, and one test.
- `nowNs` is defined in `audio_out.zig:331`, `tiles.zig:334`, `main.zig:1302` (taking an
  `Io`), and as `nowSeconds` in `control.zig:418`. One `clock.zig`.
- `channelName` exists in `main.zig:415` and `tiles.zig:326`; `rowLabel` (`main.zig:452`)
  is a third way to name an electrode. Put naming on `Layout`.
- Parsing a list of row numbers from the config is written twice in `panels.zig` (`:512`
  and `:529`) as `inline for` over key names with `comptime std.mem.eql` inside to decide
  which field to assign. That is clever, and clever is the problem: a function
  `rowSetFrom(doc, table, i, key, rows) !?RowSet` called four times is longer by a few
  lines and can be read by anyone.

"Only one obvious way to do things."

## 4. Edits are a union, but the code does not switch on it

`control.Action` is a tagged union with nineteen cases. `Display.applyEdit`
(`main.zig:661`) starts with a 200-character `if (edit.action == .record or .board or
.quit_answer or .note_preset or .save_view or .review or ...) return false`, and the main
loop then tests `e.action == .board`, `== .record`, `== .review`, `== .save_view` in
separate `if`s further down. Add a case and nothing tells you which of those places to
visit. Split the union by who handles it (`PanelAction`, `BoardAction`, `AudioAction`,
`SessionAction`) and `switch` once at the top; then the compiler lists what you forgot.
"Compile errors are better than runtime crashes."

## 5. Global mutable error messages

`panels.error_message` (`panels.zig:414`), `board_config.error_message`
(`board_config.zig:24`), `toml.error_line` (`toml.zig:77`), `panels.default_mode`
(`:435`). They work today because one thread parses configs. They are also the kind of
thing that is fine until the day it is not. Return a small diagnostics struct the caller
passes in (`fn fromConfig(doc, layout, diag: *Diagnostic)`), the way `std.json` and
`std.zig` do it.

## 6. Swallowed errors

`catch {}` or `catch ""` occurs 33 times in `control.zig`, 23 in `main.zig`. Most are
`bufPrint` into a buffer that is big enough, where failing means a truncated label.
Fine, but then say so once: a helper `fmt(buf, ...) []const u8` that truncates, named for
what it does, instead of thirty anonymous catches that each need the reader to decide
whether this one matters. The ones that are not formatting (`gpa.alloc ... catch return`
in `main.zig` `Text.init`, `r.follow(...) catch { ok = false; }`) deserve a log line or
a comment each. "Edge cases matter."

## 7. `Panel` knows too much

37 fields (`panels.zig`): where it is, what it shows, the time base, the filter, per-row
gains, hidden rows, the reference, the TTL trigger, the slope trigger with its level
"right now" (a value the display writes back into it for showing), two windows, the tint,
the slot. And it is copied by value: `var own: Panel = p.*` at `main.zig:983` copies a
kilobyte to format one number. Group it: `Place`, `Time`, `Rows { raw, hidden, gain }`,
`Filter`, `Reference`, `Trigger { ttl, slope }`. Then `signalSignature`, `renderViews` and
`applyKeys` each take the part they care about, and `fmtScale` takes a kind and a number.

## 8. `Display.frame` draws everything

`main.zig:779`, 254 lines, eight parameters. Trace parameters, sweep cursor, triggered
overlays, note markers, tint, titles, axis labels, row labels, the review badge, the note
box and the status read-out, in that order, in one function. One function per thing drawn,
each taking the panel's pixel rectangle and a small `View` (what time the right edge is,
live or review), and `frame` becomes the list of what a panel is made of.

## 9. `control.build` is the same story

`control.zig:425`, 321 lines. One function per section (`recordSection`,
`reviewSection`, `notesSection`, `audioSection`, `boardSection`, `panelSection`). Each
already starts with a comment that is a function name waiting to happen.

## 10. `gpu.zig`: two 200-line setup functions

`Gpu.init` (`:183`, 239 lines) and `createText` (`:574`, 198 lines). The Vulkan calls are
what they are, but the two pipelines repeat their rasterization, multisample and dynamic
state verbatim. A `pipelineInfo(stages, vertex_input, topology, blend)` helper removes a
screen of noise from each. Also: live history and review history are created by two
functions (`createHistory`, `createReview`) that differ in three lines.

## 11. Run `zig fmt`

`zig fmt --check src build.zig` lists seven files (`board.zig`, `usbfs.zig`, `ft600.zig`,
`headless.zig`, `window.zig`, `notes.zig`, `main.zig`). Format on save, check in CI, never
think about it again. "Focus on code rather than style."

## 12. Lines you have to scroll sideways to read

59 lines over 140 characters in `main.zig`; the longest is 438 (`main.zig:2134`, a log
call). 35 in `gpu.zig`, 26 in `control.zig`. `zig fmt` will not wrap them for you; a
trailing comma in the argument list will.

## 13. The tests that never run

`zig build test` builds `src/root.zig`. The test in `src/gui/control.zig` (the edit queue
and the snapshot) is never compiled, and nothing under `src/gui/` can have one. Either
add a test step for the GUI module, or move the pure parts (`Shared`, `Grid` in
`tiles.zig`, `Notes.handle`, `Ui` layout) to where tests run. `notes.zig` in particular
is all logic and has no test, and it is exactly the code where an off-by-one in UTF-8
backspace would live.

## 14. Three ways to fake input

`--script` (keys, wheel, typing on the display), `OEZ_CONTROL_CLICKS`, `OEZ_TILE_CLICKS`.
Three formats, three parsers, and the history of this project says scripted input hid a
real bug for a day (the seat listener). One `TestInput` reader that every window takes,
one format, documented in one place; and a note next to it that it bypasses the seat, so
it does not test what it looks like it tests.

## 15. Names

- `rv`, `pd`, `st`, `tp`, `sl`, `fr`, `au`, `nt`, `bd`: fine in a ten-line function, not
  in a thousand-line one. This fixes itself with item 1.
- `Review`, `ReviewView`, `ReviewStatus`, `ReviewAction`; `Status`, `RecStatus`,
  `BoardStatus`, `AudioStatus`, `NotesStatus`. The `*Status` structs are "what the control
  window shows", and they live in `control.zig` but are filled in `main.zig` by long
  struct literals inside a `publish` call. Give each a `fn of(...)` next to the state it
  describes.
- `Status` (display latency and fps) is defined in `control.zig` and imported by the
  display. It is the display's.
- `feed.zig`'s "slot" and "column", `panels.zig`'s "row" and "shown row", the shader's
  "row" and "channel": write the vocabulary down once at the top of `feed.zig` and use
  exactly those words.

## 16. Colours and sizes as literals

Fifteen `.{ r, g, b, a }` literals in `main.zig`, six in `tiles.zig`, nine in `ui.zig`,
and near-identical ambers (`255, 205, 120`, `255, 225, 120`, `255, 190, 90`) seven times. A `theme.zig` with named
constants (`trace`, `heard`, `warn`, `dim`, `note`, `off_scale`), shared with the
shader's palette by a comment at least. Same for `966, 624, 938, 560`, which appears in
the README, a Hyprland rule and a comment.

## 17. Comments that have gone stale

- `main.zig:1`: "oez: the GUI. One window of live traces for now." It is three windows,
  recording, review and audio. The header then spends forty lines on the history of frame
  pacing experiments; that is a design note (`docs/latency.md`), not what a reader of
  `main.zig` needs first.
- The usage lines at the top list none of `--no-tiles`, `--no-audio`, `--sweep` or
  `--no-control`, which `parseArgs` accepts. Generate the usage from one table of options
  and they cannot disagree.
- README: it has grown by a section per feature, each with the measurements of the day
  it was written (2.4 ms here, 2.6 there). Worth one pass to say each thing once.

A comment that is wrong is worse than none: "Communicate intent precisely."

## 18. Environment variables

Nine of them (`OEZ_APP_ID`, `OEZ_KEY_DEBUG`, `OEZ_FRAME_DEBUG`, `OEZ_NO_TITLE`,
`OEZ_USB_PACE`, `OEZ_USB_TRACE`, two click scripts, `XDG_STATE_HOME`), read with
`std.c.getenv` wherever they are needed, three of them more than once. Read them once in
`main`, into a `Debug` struct that is passed down, and list them in one doc comment. Then
"what can change this program's behaviour from outside" has one answer.

## 19. `window.zig`'s `Key`

An enum of X keysyms that also carries "digits are used as numbers, see below", with
callers doing `@intFromEnum(k) >= '1'`. Make it a tagged union: `.char: u21`,
`.named: enum { escape, enter, ... }`. The digit case then reads as what it is.

## 20. `headless.zig` `main` is 278 lines too

Smaller sibling of item 1, same cure: the live-settings test steps are a table already;
the soak loop, the verification and the summary are three functions.

## 21. Small things

- `main.zig:1964`: a labelled block `new_display_audio: { ... break :new_display_audio; }`
  used as a pair of braces. Delete the label.
- `feed.zig`: `rows()` takes `gpa` on every call only to grow a scratch buffer; size the
  buffer in `init` from the block capacity.
- `audio.zig`: `Monitor.process` rebuilds chains by comparing settings field by field in
  one long condition; a `Key` struct with `eql`.
- `board_config.zig`: `diff` takes two parallel arrays (`lines`, `lens`); return a small
  list of slices.
- `spikes.zig` and `slope.zig` share the threshold-crossing state machine by copy; the
  detector could own an array of the slope's state.
- `review.zig` `fill`: the two branches (extend forward, extend backward) are the same
  eight lines mirrored; a `Stretch { lo, hi }` type with `extendTo` would say it once.

---

## If I only got one afternoon

1. `zig fmt` (item 11). Five minutes.
2. Split `main()` into the five structs of item 1.1, moving code only. This is the one
   that changes what it is like to work on the project.
3. `Published(T)`, `clock.zig`, one `channelName` (item 3).
4. Switch on `Action` (item 4).
5. Get the GUI's pure logic under `zig build test` (item 13).

Everything else can wait for the day the file it lives in needs to change anyway.
"Incremental improvements."
