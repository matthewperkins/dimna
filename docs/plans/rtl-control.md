# Plan: the control window mirrored for Persian, and Persian text read right to left

Read `docs/plans/README.md` first; its rules apply. Display only: nothing here touches
acquisition, recording, the board or the feed.

## Why

dimna is being translated (`docs/plans/translations.md`; another agent writes
`lang/fa.zig` at the same time as you, so it is empty in your copy). In Persian, the
owner wants the control window mirrored: it reads from the right, as Persian software
does. The neural display, the tile window and the key summary are not mirrored (their
layout is the data's, which runs left to right in time).

## Files you may change

`src/gui/ui.zig`, `src/gui/control.zig`, `src/gui/i18n.zig` (only to add the direction of
a language), `src/gui/shape.zig` and `src/gui/font.zig` (only for the paragraph
direction, part 2), `src/gui/main.zig` (only to pass the direction where the control
window and fonts are set up), `src/gui/testdata/control_layout_rtl.txt` (new),
`docs/display.md` (one paragraph). Not `src/gui/testdata/control_layout.txt`: it must stay
byte for byte the same (English is unchanged).

## Part 1: mirroring the control window

`ui.zig` lays widgets out left to right in rows (`x`, `fit`, `column`, `newline`), and
`control.zig` sometimes places things itself (`ui.x = @max(ui.x, ui.width - 130)`) or
draws through `ui.batch` directly (the alarm bar). The design, which you should follow
unless you find it does not work (then say why in the report):

- **Layout stays logical.** Every widget is laid out exactly as now, in left-to-right
  coordinates. Only drawing and the pointer are mirrored: with `Ui.rtl`, a box at logical
  `x`..`x + w` is drawn at `width - x - w`, and the pointer's x is mirrored once, at
  `begin` (`mouse_x = width - mouse_x`), so every hit test is unchanged. Then a row that
  started at the left edge starts at the right edge, things placed "at width - 130" are on
  the left, continuation rows are indented from the right, and a stepper reads
  "[+] value [-] label" from left to right, which is right for a right-to-left reader.
- **Every drawing call goes through `Ui`**: add the small helpers you need (a rectangle,
  a text at a logical box) and replace the direct `ui.batch.rect` / `batch.text` calls in
  `control.zig` with them. A text is drawn so that its run fills its mirrored box.
- **Shapes with a direction** turn with the layout: the heading's ▸ (closed) becomes ◂
  when mirrored. Look for any other (arrows in labels, "->").
- `Ui.rtl` comes from the language: add `pub fn rightToLeft(lang: Language) bool` to
  `i18n.zig` (true for `fa`), and set it where the control window begins its frame.

## Part 2: Persian sentences read right to left

`shape.zig` picks a string's paragraph direction from its first strong character. A
Persian message that starts with a value ("{[source]s} ...", an error name, a number
before the first Persian word) then comes out laid out left to right, in the wrong order.
When the current language is right to left, a string that contains a right-to-left
letter is to be laid out with a right-to-left paragraph direction. A string with no
right-to-left letter is unchanged: it does not go through shaping at all (the Latin-1
fast path must stay as it is: check that its timing in the existing benchmark did not
move). Keep the isolation of Latin and number runs (`isolateLtr`) working with it.

Make the paragraph direction a setting of the engine, chosen once at start-up from the
language, not a global read on every call. Notes the user types are text too: in Persian,
they follow the same rule (a note with a Persian letter reads right to left).

## Tests and evidence

- `testdata/control_layout.txt` is unchanged (proof that English is untouched).
- A stored output `testdata/control_layout_rtl.txt`: the same frames as the existing
  layout test, with `rtl` set and the English texts (the Persian file is empty in your
  copy). Write a test that checks, for every rectangle and text run, that it is the
  mirror of the left-to-right run's (`x' = width - x - w`, same y and size), apart from
  the turned triangle; then the stored file is a record, and the test is the proof.
- Clicks: a test that a click at the mirrored position of a button reports that button,
  and at the unmirrored one does not (for a button that is not centred).
- Part 2: tests in `shape.zig` with Persian strings (use a few words, e.g.
  "فیلتر 300-6000 Hz" and "{source} ..." formatted with a Latin value first): with the
  right-to-left setting, the glyphs come out in the right visual order. The existing
  tests show how glyph order is checked without a window. If HarfBuzz or FriBidi is not
  present, those tests skip, as the existing ones do.
- Break each new test once on purpose (README rule).
- `zig build test --summary all`, `zig build --release=safe`, `zig fmt --check src build.zig`.

## Do not

Run the GUI. Mirror the display, the tile window or the key summary. Change English
output. Touch `lang/*.zig`.

## Report

What you changed and where; any drawing in `control.zig` you could not route through
`Ui`, and why; the stored-output and test evidence; the benchmark numbers before and after
for the fast path.

## Report (2026-11-14)

Branch `worktree-agent-a93e35566e06b98a3`, started from `241b0a4` (`git merge --ff-only main`
succeeded). Commits: `e03ac94` (part 1), `89547ea` (part 2 and `docs/display.md`), then this
report. Local `main` has moved on since (the translations); `git merge-tree` says the branch
merges with it without conflicts. Not merged, not pushed.

**Files changed:** `src/gui/ui.zig`, `src/gui/control.zig`, `src/gui/i18n.zig`,
`src/gui/shape.zig`, `src/gui/main.zig` (3 lines), `src/gui/testdata/control_layout_rtl.txt`
(new), `docs/display.md` (one paragraph). `font.zig` was not changed.
`testdata/control_layout.txt` is byte for byte the same (`git diff 241b0a4 --stat` does not
list it, and its test passes).

### Part 1: the mirrored control window

I followed the design as written. It works.
- `Ui.rtl` (defaults to false, so `tiles.zig`, which builds a `Ui` by hand, is unchanged).
  `Ui.begin` takes it as a new last argument and mirrors the pointer's x once
  (`width - mouse_x`). A negative x means no pointer and is left negative, so nothing is hot.
- New drawing helpers:
  - `Ui.fill(x, y, w, h, colour)` draws at `width - x - w` when mirrored.
  - `Ui.textAt(x, y, string, colour)` draws the text through `font.Batch.text` at its
    logical place, then moves the quads it added by `(width - end) - round(x)`. The run
    therefore fills its mirrored box with its glyphs in their own order, for shaped text
    too. The logical advance is exactly what it was, because it is still the batch's own
    return value.
  - Every `batch.rect` / `batch.text` in `Ui` goes through these two now.
- Hit test: `hovering` takes the box's right edge instead of its left when mirrored. A drawn
  box then takes in its left pixel edge and not its right, exactly as it does unmirrored. A
  test checks the edges.
- Shapes with a direction: a closed heading's ▸ becomes ◂ (U+25C2). I found no other:
  - `control.zig` and `lang/en.zig` contain no "→" or "->" in labels;
  - "<->" appears only in the key summary's help strings, which are not mirrored and are
    symmetric anyway;
  - the stepper's "-" and "+" read "[+] value [-] label" when mirrored, as the plan wants.
- `control.zig`:
  - the alarm bar's direct `ui.batch.rect` is now `ui.fill`. Nothing in `control.zig` draws
    around `Ui` any more (`grep batch` finds only the set-up in `loop` and the tests);
  - `loop` reads `i18n.rightToLeft(i18n.current)` once, before its first frame. The language
    is final, after the English fallback, before the control thread is spawned.
- `i18n.rightToLeft(lang)`: true only for `fa`. It has a test.

**One thing to know:** ◂ is not one of the font's fixed glyphs (`font.extra_cps` has only ▸
and ▾), and `font.zig` was outside what I could change for this. In the real program ◂ goes
through the shaping engine's unshaped path, taking the glyph from the primary font or a
fallback. In the hand-made test font it is drawn as "?". That is why the stored
`control_layout_rtl.txt` shows "? Notes" for closed headings. Adding U+25C2 to `extra_cps`
would make it a fixed glyph, but that is a change to `font.zig`'s atlas.

**Tests and evidence (part 1):**
- "the control window's mirrored layout is unchanged": the same frames as the existing layout
  test, with `rtl` set, compared with `testdata/control_layout_rtl.txt` (2364 lines, the same
  count as the left-to-right file). `DIMNA_CONTROL_LAYOUT_RTL_OUT` writes a run's output.
  The existing test was refactored to share `layoutText` and `writeEdits`; its output is
  unchanged.
  - Each "ends at x" header line gives the logical `ui.x`, so it is the same as in the
    left-to-right file.
- "mirrored, every rectangle and text ... is the mirror of its unmirrored one, and does the
  same". This is the proof.
  - For every state, it draws the frame both ways and splits each into rectangles and runs
    of glyphs, in the order drawn.
  - For each pair it checks: `x' = 800 - x - w`; the same y, size and colour; the same
    number of quads; the same glyphs, except a closed heading's first glyph, which must be
    the turned triangle.
  - It then clicks the middle of each rectangle and of its mirror, and checks that both
    queue the same edits.
  - It printed: `mirrored layout: 931 rectangles, 1415 runs of text, 38 triangles turned`.
- "mirrored, a click where a button is drawn is that button's, and one where it would be
  unmirrored is not". It uses "Record" (unmirrored x 12..78, mirrored 722..788).
  - Mirrored, x 755 records and x 45 does not; unmirrored, the reverse.
  - Edges: 722 and 787.9 are in; 788 and 721.9 are out.

**Break-it (part 1)**, each a one-line change in `ui.zig`, reverted with `git checkout`:

| break | result |
|---|---|
| text shift `+ 1` | the stored-RTL test fails (first difference on line 2); the mirror test fails "expected 748, found 749" in state "not recording, all open" |
| `fill` not mirrored | the stored-RTL test fails (line 7); the mirror test fails "expected 80, found 630" |
| pointer not mirrored at `begin` | all three new tests fail; the click test at case `.{ .rtl = true, .x = 755, .record = true }` |
| `hovering` with the unmirrored edges | only the click test fails, at case `.{ .rtl = true, .x = 722, .record = true }` |
| triangle not turned | the stored-RTL test fails (line 1564); the mirror test fails "expected 31, found 228" in "notes open" (31 is '?', 228 is ▸) |

The alarm bar spans the whole width, so whether it is mirrored cannot be seen. No test can
catch it going back to `ui.batch.rect`.

### Part 2: Persian sentences read right to left

**Unexpected, before any change.** The plan says a Persian message that starts with a value
comes out left to right. On `241b0a4` it did not. I ran a probe test (since removed) on
"abc فیلتر" and on "فیلتر abc". Both came out right to left: in the first, the Persian glyphs
were at x 0..12 and "abc" at 15..34.
- The cause: `isolateLtr` wraps every Latin or number stretch in LRI…PDI before FriBidi
  picks the paragraph direction with `FRIBIDI_PAR_ON`.
- Rule P2 skips isolated text, so the first strong letter FriBidi sees is always the Persian
  one.
- So, in every language, any string with a Persian letter got a right-to-left paragraph.
  That contradicts the module comment ("from its first strong character").

I judged the code wrong and the comment and the plan right, for this reason: the plan's rule
("when the current language is right to left …") only means something if the other
languages use the first strong letter.

**What I changed:**
- `Engine.rtl` is the setting. It is copied from `shape.start_rtl` when an engine is made.
  `main.zig` sets `shape.start_rtl = i18n.rightToLeft(i18n.current)` once, after the English
  fallback and before any font is made. So the display's, the control window's and the
  tiles' fonts all get it, without changing `display.zig` or `tiles.zig`. Nothing reads a
  global per call.
- `shape()` takes the paragraph direction from `paragraphDirection(raw_types, rtl)`, which
  runs on the types before the isolation:
  - with `rtl` and an R/AL letter, it is RTL;
  - otherwise it is the first L, R or AL, giving LTR or RTL;
  - with none, it is `PAR_ON` as before.
  - Explicit isolates in the input are not skipped. That is a simplification of P2 for the
    rare text that has them.
- `isolateLtr` is unchanged and works with both directions.
- Typed notes are drawn through the same engines, so in Persian a note with a Persian letter
  reads right to left.

**Behaviour change outside Persian:** in the other languages, a string that starts with a
Latin letter and also has a Persian letter (a typed note, say "cell 3 فیلتر") is now laid
out left to right. Before, it was right to left. English UI messages have no Persian letter,
so the stored English outputs are unchanged and their tests pass.

**Tests (shape.zig):**
- `paragraphDirection` with hand-written type sequences.
- A font made after `start_rtl` is set has `rtl`; one made before keeps `rtl` false.
- Glyph order with Lato plus Noto Sans Arabic, HarfBuzz and FriBidi (skips without them; they
  ran here):
  - "Simulator فیلتر" (formatted "{s} {s}", Latin first), with the setting: every Persian
    glyph is left of every Latin one. "Simulator"'s glyphs are those of "Simulator" laid out
    alone, in the same order, left to right.
  - The same string without the setting: Latin on the left.
  - "12 فیلتر", with the setting or without: the number on the right.
  - "فیلتر 300-6000 Hz", with the setting: the range is one block on the left, with the same
    glyphs and spacing as "300-6000 Hz" alone.
- With the setting, strings with no right-to-left letter:
  - a Latin-1 label gives byte-identical quads to the same font without an engine, and
    `shape_calls` stays 0;
  - "łódź 300 Hz" is laid out unshaped, left to right, and `shaped_calls` stays 0.

**Break-it (part 2)**, each a one-line change in `shape.zig`, reverted:

| break | result |
|---|---|
| setting ignored (`if (rtl and false)`) | direction test ("expected 273, found 272", i.e. RTL vs LTR) and the glyph-order test fail |
| direction always `PAR_ON` (the old behaviour) | only the glyph-order test fails, at `o.latin[1] < o.persian[0]` (the unset case); the set case passes, which confirms the finding above |
| isolation off | the isolation test, the existing Hz test and the new glyph-order test fail ("expected 402, found 15") |
| engine ignores `start_rtl` | the start-up test fails |

### Fast-path benchmark (`DIMNA_TEXT_BENCH=1`, ReleaseSafe)

Method: the gui-test binary built before part 2 (at `e03ac94`) and the one built after were
copied aside. Each was run 5 times, in the order before, after, before, after; nothing else
was building at the time. Figures are ms per frame of 200 labels:

| | fast path | shaped, cache miss | shaped, cached |
|---|---|---|---|
| before | 0.218–0.222 | 3.80–3.91 | 0.075–0.078 |
| after | 0.217–0.219 | 3.77–3.91 | 0.074–0.077 |
| before (again) | 0.218–0.223 | 3.78–4.09 | 0.075 |
| after (again) | 0.218–0.228 | 3.77–3.83 | 0.074–0.078 |

The fast path did not move. It does not reach the engine at all.

### Commands run, final state

- `zig build test --summary all` gives `Build Summary: 18/18 steps succeeded; 137/138 tests
  passed (1 skipped)`; gui-test passes 137 with 1 skipped (the benchmark). Core: 133 pass;
  that was in the first run after my changes, since cached.
- `zig build --release=safe`: exit 0.
- `zig fmt --check src build.zig`: prints nothing.
- Not run: the GUI (no window was opened), the board, `dimna-headless`.

Temporary files were in `/tmp/dimna-rtl-<pid>` and the session scratchpad. They have been
removed.

### Not covered

- No real font or real window: the mirrored layout was checked only with the hand-made 8 px
  font. With Lato, ◂'s advance may differ from ▸'s. The layout is computed from what is
  drawn, so this only shifts a closed heading's label by a pixel or two.
- Persian strings in the control window: `lang/fa.zig` was empty in my copy. The
  combination of mirroring and right-to-left runs inside a mirrored box was not seen
  together. The engine and Ui tests cover each half.
- The text-entry box for notes, if it has a caret, was not looked at for direction; I found
  none in `control.zig`.
- The tiles window is not mirrored (as the plan says). Its fonts do get the paragraph
  direction.
