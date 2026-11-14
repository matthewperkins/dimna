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
