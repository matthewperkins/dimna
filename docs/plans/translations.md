# Plan: the translations (German, French, Portuguese, Polish, Chinese, Persian)

Read `docs/plans/README.md` first; its rules apply. Display only: nothing here touches
acquisition, recording, the board or the feed. You are given one or more of the languages
below; do only those.

## Files you may change

`src/gui/lang/<code>.zig` for your languages (each exists, holding only a header comment),
and `docs/translations/<code>.md` (new, one per language: the notes for a native reviewer,
below). Nothing else: not `en.zig` (if an English text is wrong or unclear, say so in the
report), not `i18n.zig`, not the tests.

## What to write

Read `src/gui/lang/en.zig` whole, and "Counted messages" in `src/gui/i18n.zig`. Then give
your file one `pub const` per message of `en.zig`, with the same name, in the same order
and under the same comment headings (translate the headings and the one-line comments too,
or keep them in English: either, but be consistent). A message you leave out is shown in
English; leave out only:

- `notice_language_missing` and `notice_language_where`: shown only when the language
  cannot be displayed, so they are always English.

The program is used by electrophysiologists at the rig, often in a dark room, glancing at
it while handling an animal. Texts are short and plain. Translate for that reader: the
words a lab in that country uses, not a dictionary's. Where the field uses the English
word (often "spike", "TTL", "CAR"), use it.

### Rules the tests check (`zig build test`)

- **Placeholders** stay exactly as English has them: the same names and kinds
  (`{[gaps]d}`, `{[ms]d:.1}`, `{[err]t}`, `{[left]s}`), in whatever order your language
  needs. Literal braces are written `{{` and `}}`.
- **Leading and trailing spaces** are English's, exactly: the layout depends on them (a
  panel title's parts begin with three spaces). Spaces inside a message are yours.
- **Counted messages** (`*_one` / `*_other` in English) need the forms your language uses:
  `de`, `fr`, `pt`, `fa`: `_one` and `_other`; `pl`: `_one`, `_few` and `_many`; `zh`:
  `_other` only. French and Portuguese (Brazilian, which is what `pt` means here) count 0
  as `_one`; Polish `_few` is 2–4, 22–24, … (not 12–14), `_many` is 0, 5–21, 25–31, ….
  A form may leave the number out, as English's "THE BOARD WENT QUIET ONCE" does.

### Rules the tests cannot check

- **Units and symbols** stay as they are: µV, mV, V, ms, s, min, Hz, kHz, GB, dB, σ, ±,
  fps, the clock "1:05". So do channel names (A1-5, TTL2, AUX1, ADC) and acronyms (CAR,
  TTL, DSP, REC).
- **Keys.** In `key_*`, write keys the way a keyboard sold in that country labels them
  (German: Strg, Umschalt or Shift, Pos1, Ende, Bild↑/Bild↓, Leertaste; French: Ctrl,
  Maj, Début, Fin, Espace; and so on), and the letter keys as they are (`r`, `m`, `/`,
  `` ` ``, `~`, `?`). Mouse actions ("wheel", "left-click a row") are translated.
  `help_these_keys`, `help_title` and `notes_hint` name keys too: keep them consistent.
- **Case.** English alarms are in capitals on purpose (they must be seen across the room).
  Keep capitals in German, French, Portuguese and Polish. Chinese and Persian have no
  case: make an alarm short and plain instead.
- **Length.** Stay near English's length; buttons and labels in the control window should
  not grow by more than about half. Prefer the short word a lab would use. List any text
  you could not keep short in your report: a later step checks that every text fits its
  window.
- **Address.** Avoid addressing the user where English does not. Where you must (the
  hints: "press Shift+a to acknowledge"), use the form software in your language uses:
  German infinitive or Sie, French vous or infinitive, Portuguese impersonal or você,
  Polish impersonal or the infinitive.
- **Chinese**: Simplified characters. Full-width punctuation for Chinese text (，：（）),
  half-width inside numbers and units. A space between a Chinese character and a Latin
  word or number ("3 个间隙", "300-6000 Hz 带通"), none between Chinese characters.
- **Persian**:
  - Persian letters, not Arabic ones: ی (U+06CC), not ي; ک (U+06A9), not ك.
  - **Latin digits** (0-9), not Persian ones. The numbers come from the program's
    formatting, and the display keeps Latin runs ("300-6000 Hz") left to right inside
    the Persian text (see `src/gui/shape.zig`, "isolated"), so units stay next to their
    number.
  - Use the zero-width non-joiner (U+200C) where Persian spelling needs it (می‌شود).
    Write it as `\u{200C}` so it can be seen in the source.
  - Write the message in logical order (the order it is read in), as plain Persian text.
    The program does the right-to-left layout. Persian punctuation (، ؛ ؟) is fine.
  - The control window will be mirrored for Persian by a separate plan. You need not do
    anything for that.

## Notes for a native reviewer (`docs/translations/<code>.md`)

The owner will ask a native speaker to review each language. Write for that person, in
English, short:

1. A glossary: the 20–30 terms that recur (threshold, sweep, panel, row, band, corner,
   filter, raw, scale, trigger, review, live, note, preset, draft, acknowledge, recording,
   gap, block, headstage, spike tile, focus, listen, …), each with the word you chose
   and why when it is not the obvious one.
2. The messages you were unsure of: name, English, yours, and a back-translation into
   English.
3. Anything in English that was ambiguous and how you read it.

## Evidence

- `zig build test --summary all` passes, and `zig fmt --check src build.zig` prints
  nothing.
- Break each kind of check once in one of your files, and see the test fail: a renamed
  placeholder, a changed leading space, a missing plural form (README rule). Revert.
- Show that your language is really used: a test you run but do not commit (in your
  working copy only), or a temporary edit of an existing test, that sets
  `i18n.current = .<code>` and prints three formatted messages, among them a counted
  one for two different counts (`i18n.count(&buf, "rec_gaps", 2, .{ .gaps = 2 })`). Put
  what it printed in your report, then revert it.
- `zig build --release=safe` succeeds.

## Do not

Run the GUI or `dimna` at all (the font checks and drawing are checked later, on screen,
by the owner). Change any file outside your list. Translate log messages, file names,
config keys, `--help`, or anything not in `en.zig`.

## Report

Per language: the number of messages written and left out (and why), the texts you think
may be too long, the evidence above, and anything in `en.zig` you would change.

## Report: de, fr, pt

Branch `worktree-agent-a45271d1d6348aeb9`, work commit 2f1fc72 (this report is the next commit).
Files: `src/gui/lang/{de,fr,pt}.zig`, `docs/translations/{de,fr,pt}.md`, this plan file.

**Messages.** Each language: 267 written, 2 left out (`notice_language_missing`,
`notice_language_where`, as the plan says). Comments and headings stay in English.

**Failing test, not fixed (outside my files).** After the files were filled, `zig build test`
reports 1 failure: `i18n.test.text, fmt and print give the current language's message...`,
line 584: `countIn(.fr, &buf, "rec_gaps", 0, ...)` expects "0 gaps" because French was empty;
French now has its own file and counts 0 as one ("0 trou"). The test needs another language
that still has no file (pl, zh or fa until their files arrive). I did not change it. With
the line temporarily switched to `.pl`, `zig build test --summary all` gave
130/131 passed, 1 skipped, 0 failed; reverted.

**Evidence.**
- `zig fmt --check src build.zig`: no output. `zig build --release=safe`: succeeded.
- Break-it (in fr.zig, each reverted; i18n.zig untouched in the end):
  - renamed `{[gaps]d}` to `{[gapz]d}` in `rec_gaps_other`: compile error `'{[gapz]d} trous' needs a field 'gapz'`.
  - `title_car` leading spaces 3 to 2: `every message of every language formats with its placeholders, and agrees with English` failed.
  - deleted `rec_gaps_other`: `every counted message of a language has the forms its language needs` failed.
  - (the "text, fmt and print" test also failed in the last two runs, from the stale `.fr` line above.)
- Language in use (temporary test with `i18n.current` set, then removed), printed:

      [de] Tasten und Maus   (? oder Esc schließt dies)
      [de] DIE PLATTE IST VOLL IN 12 min
      [de] 0:0 Lücken | 1:1 Lücke | 2:2 Lücken
      [fr] Touches et souris   (? ou Échap ferme)
      [fr] LE DISQUE SERA PLEIN DANS 12 min
      [fr] 0:0 trou | 1:1 trou | 2:2 trous
      [pt] Teclas e mouse   (? ou Esc fecha)
      [pt] O DISCO ENCHE EM 12 min
      [pt] 0:0 lacuna | 1:1 lacuna | 2:2 lacunas

**Texts that may be too long** (English length to mine, characters; ones that grew over 1.5x,
control window and display): de: `btn_save_view` 9 to 17, `btn_reset` 5 to 12, `label_cutoff` 6 to 13,
`label_volume` 6 to 10, `btn_quit` 4 to 7, `tiles_range_mixed` 5 to 8; fr: `btn_save_view` 9 to 18,
`btn_stop_recording` 14 to 24, `label_sample_rate` 11 to 23 (already abbreviated), `rec_idle` 13 to 20,
`btn_record` 6 to 11, `mode_scroll` 6 to 10, `label_trigger` 7 to 11, `btn_plain` 5 to 8;
pt: `label_sample_rate` 11 to 18. Help-window key names ("clic gauche sur une ligne" 25,
"clique esquerdo em uma linha" 28, "Linksklick auf eine Zeile" 25, "pincement du pavé tactile" 25)
are also longer. Also the longest German text, `window_title_status`, is 103 characters.

**Choices to note.** "on"/"off" kept in fr and pt (short, common); alarm "0.5 s" keeps a decimal
point in all three, since the program's own numbers do; "tile" kept as a loan word in pt.

**Not covered.** Nothing was drawn or looked at on screen (no font, fit or glyph check); a
native speaker has not read anything. Hyphen "Bild↑/Bild↓" arrows rely on the font having ↑ ↓.

**en.zig.** Nothing wrong, but `help_low_corner` / `help_high_corner` ("low corner down / up") and
"stamp" are terse; I read them as filter cutoff lowered / raised and a note given the current sample.
