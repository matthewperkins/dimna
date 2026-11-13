# Plan: the small things

Read `docs/plans/README.md` first. Refactoring plan (rule 8): behaviour must not change.
Five independent items from `docs/readability-review.md` item 21, in the core (and its
callers). One commit per item, so each can be taken or left.

1. **`src/feed.zig`: `rows()` takes an allocator on every call** only to grow two scratch
   buffers (`row_buf`, `mean_buf`) the first time. Size them in `init` (and wherever the
   feed is rebuilt: read `sync` and `restart`) from the largest block the feed can be
   given, and drop the `gpa` parameter and the `!`. Find what bounds the block size: the
   callers are the display loop (`src/gui/main.zig`), `src/review.zig` and
   `src/independence_test.zig`; `review.zig` may pass larger stretches than one ring
   block. If no bound can be known at `init`, do not guess one: keep growth, but move it
   out of the hot path in a way you can justify, or leave the item and explain. A buffer
   too small must be impossible or be a checked error, never a silent truncation.
2. **`src/audio.zig`: `Monitor.process`** decides whether to rebuild its chains by
   comparing settings field by field in one long condition. Give the things a rebuild
   depends on a small struct with an `eql`, built from `Settings`, and compare that. Check
   by reading `rebuild` that the struct holds exactly what `rebuild` reads: if `rebuild`
   reads a setting the condition does not compare today, that is a bug to **report, not
   fix** (say what would go stale).
3. **`src/board_config.zig`: `diff`** fills two parallel caller-provided arrays (`lines`,
   `lens`). Return one small value instead (for example a struct holding the buffers and
   a count, with a `line(i) []const u8` accessor), and update the callers
   (`src/gui/session.zig` `BoardControl`, `src/gui/control.zig`'s `QuitPrompt` if it
   stores them, tests). `control.QuitPrompt` is copied into a snapshot between threads, so
   whatever it stores must stay plain data. Change `control.zig` only in the lines this
   needs.
4. **`src/review.zig`: `fill`** has two branches (extend forward, extend backward) that
   mirror each other. Say it once if, and only if, the result is easier to read than the
   two branches; if your attempt is not clearly better, leave the code and say so in the
   report with what you tried. The tests in `review.zig` must pass unchanged.
5. **`src/gui/main.zig`**: a labelled block `new_display_audio: { ... break
   :new_display_audio; }` is used as a pair of braces. Remove the label (keep the
   statements).
6. **The label-formatting `catch ""` in `src/gui/session.zig`**: use `format.fmt` (the
   truncating formatter in `src/gui/format.zig`), as in the control window. A `catch`
   that is not label formatting is left alone, with a one-line comment if it has none.

Not in this plan: merging the threshold-crossing state machines of `spikes.zig` and
`slope.zig` (the lead keeps that).

## Files you may change

`src/feed.zig`, `src/audio.zig`, `src/board_config.zig`, `src/review.zig`,
`src/independence_test.zig`, `src/gui/main.zig` (items 1 and 5 only),
`src/gui/session.zig`, `src/gui/control.zig` (item 3 only, smallest possible change),
`src/gui/audio_out.zig` (only if item 2 changes a signature it calls). Another agent is
changing colours and label formatting in `src/gui/display.zig`, `tiles.zig`, `ui.zig`,
`control.zig`, `main.zig`: keep your hunks in the shared files small and say exactly
which lines you touched.

## Evidence

`zig build test --summary all` (core and GUI tests) before and after, with counts. For
item 1 add a test that a block of the largest size goes through `rows` and that a feed
rebuilt by `sync` still can. For item 2 add a test that each field in the new struct
triggers a rebuild when it changes (and break-it: drop a field from `eql`). For item 3 the
existing `diff` tests, adapted. You may run `oez-headless --sim 32,16 --seconds 5`
(no board, no windows, no sound) as a smoke test; never without `--sim`.

## Done means

Six commits (or fewer, with the reason for each item left out); builds; tests pass;
`zig fmt --check src build.zig` prints nothing; break-it-on-purpose for each new test.
