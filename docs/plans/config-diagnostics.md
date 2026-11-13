# Plan: config errors returned to the caller, not left in globals

Read `docs/plans/README.md` first. Refactoring plan (rule 8): the messages a user sees
must stay word for word.

## Why

`docs/readability-review.md` item 5. Three parsers report what went wrong through global
mutable variables: `panels.error_message` (+ `error_message_buf`), 
`board_config.error_message` (+ buf), `toml.error_line`. And `panels.default_mode` is a
global that `fromConfig` sets and `Panel` construction reads. They work because one thread
parses configs at start-up; nothing enforces that.

## What to build

1. A small diagnostics type the caller owns and passes in, in the style of `std.json`'s
   `Diagnostics`: for `toml.parse`, the line number; for `panels.fromConfig`,
   `panels.applyViews` and `board_config.read`, the message (a buffer inside the struct and
   a length, with a `message()` accessor). One type per module or one shared type in
   `toml.zig`: your choice; say why. The parameter is a pointer the caller passes, optional
   only if that keeps existing call sites in tests readable.
2. Remove the four globals. `default_mode` becomes a parameter (or a field of something
   passed) on the path from `fromConfig` to where panels are constructed; find every
   reader with a search before choosing.
3. Update every caller. Today they are (search again; this list may be stale):
   `src/gui/main.zig` (two uses of `toml.error_line`), `src/gui/args.zig`
   (`board_config.error_message`), `src/gui/display.zig` `makeDisplay` (two uses of
   `panels.error_message`), `src/headless.zig` if it parses a config, and the tests in
   `panels.zig`, `board_config.zig`, `toml.zig`, `independence_test.zig` and anything else
   that calls these functions. The log lines the callers print must be identical.
4. Tests: the existing tests that check a message or a line number keep checking it,
   through the diagnostics. Add one test per parser that two parses in a row with
   different errors each report their own (the property the globals could not promise
   across threads; a sequential test is enough).

## Files you may change

`src/toml.zig`, `src/panels.zig`, `src/board_config.zig`, and callers:
`src/gui/main.zig`, `src/gui/args.zig`, `src/gui/display.zig`, `src/headless.zig`,
`src/independence_test.zig`, `src/review.zig`, `src/feed.zig` (tests that build panels),
and any other file only where a call's signature forces it (list those in your report).

Other agents are working in `src/gui/control.zig` and `src/gui/gpu.zig`: do not touch
those two.

## Evidence

No windows (rule 2). `zig build test --summary all` covers the core parsers and, since the
GUI test step was added, the GUI module's tests. For the user-visible messages, use the
simulator through `oez-headless` only if it reads the config (check); otherwise write a
test that feeds a bad config through the same calls `args.zig` and `makeDisplay` make and
compares the message text. Give before/after text for one bad `[board]` key, one bad
`[[panel]]` key, and one TOML syntax error.

## Done means

No `pub var` or file-level `var` left in the three parsers (show the grep);
`zig build --release=safe` builds; tests pass; `zig fmt --check src build.zig` prints
nothing; break-it-on-purpose for the new tests.
