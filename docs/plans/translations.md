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

## Report: fa

Branch `worktree-agent-a814c5158788ecf78`, translation commit `7cd6069` (on main at 241b0a4).
Files: `src/gui/lang/fa.zig`, `docs/translations/fa.md` (and this report).

- **Messages:** 267 written (all of `en.zig`'s 269 names, in its order and under its
  headings; comments kept in English). Left out: `notice_language_missing` and
  `notice_language_where` (always English). Persian counts 0 as `_one`, so every `_one`
  form keeps its number except `alarm_quiet_times_one` ("once"; shown only for 1).
- **Checked by script:** no Arabic ي (U+064A), ك (U+0643), ى or ة; no Persian or
  Arabic-Indic digits; no raw U+200C (75 written as `\u{200C}`).
- **Possibly too long** (characters, ZWNJ not counted; Persian letters are narrower than
  Latin ones, so this may be fine): `tag_threshold` 3 → 6 (آستانه, no usual
  abbreviation), `section_notes` 5 → 9, `notes_typing` 13 → 20, `board_restart_pending`
  17 → 28, `label_cutoff` 6 → 10 (فرکانس قطع), `btn_32_ch` 5 → 8 (32 کانال), `btn_reset`
  5 → 8. The longer sentences (`btn_apply`, `board_apply_after_stop`, `hint_keys`,
  `notice_colours_change`) are near English's length.
- **Choices to know about:** "> 300 Hz" / "< 6000 Hz" in titles became words
  (بالای / زیر), since the signs would mirror in right-to-left text. Recording is ثبت (the
  electrophysiology word), acquisition دریافت داده. Keys keep their Latin labels (Iranian
  keyboards carry them); `key_left_right` is چپ / راست.
- **Evidence:**
  - `zig build test --summary all`: `Build Summary: 18/18 steps succeeded; 129/130 tests
    passed (1 skipped)`. Its output also holds a `failed command: ./.zig-cache/.../gui-test`
    line, as it did before my change; the build still succeeds. Not looked into.
  - `zig fmt --check src build.zig`: printed nothing.
  - `zig build --release=safe`: exit 0, `zig-out/bin/dimna` and `dimna-headless` built.
  - Break 1, placeholder renamed (`alarm_disk_full_in`: `{[left]s}` → `{[lefft]s}`): the
    build failed at compile time, `error: no argument with name 'lefft'` (from the
    call through `i18n.fmt`), before the catalogue test could run. Reverted.
  - Break 2, leading space (`title_review` "   " → "  "): the test failed with
    `fa title_review: starts or ends with 2/0 spaces where English has 3/0`. Reverted.
  - Break 3, plural form removed (`rec_gaps_one` deleted): `fa rec_gaps: no form 'one'`.
    Reverted.
  - Language really used: a temporary test at the end of `i18n.zig` (removed, not
    committed) set `i18n.current = .fa` and printed:

        FA1 توقف ثبت
        FA2 دیسک تا حدود 12 min دیگر پر می‌شود
        FA3 2 شکاف
        FA4 برد یک بار ساکت ماند (0.5 s یا بیشتر بدون داده)
        FA5 برد 3 بار ساکت ماند (0.5 s یا بیشتر بدون داده)
        FA6 0 پیش‌تنظیم
        FA7 تشخیص اسپایک و تریگر شیب همیشه از 300-6000 Hz استفاده می‌کنند،

    (FA4/FA5: one counted message for 1 and 3; FA6: 0 takes `_one` and keeps its number.)
- **Not covered:** nothing was drawn (no GUI run): fonts, shaping, right-to-left layout,
  mixed Latin/Persian runs (`Ctrl+چرخ`, `µV/ردیف`, `l = زنده`) and whether texts fit are
  unchecked. A native speaker has not reviewed the wording.
- **In `en.zig` I would change:** nothing that blocks. `title_band_above` / `below` use
  ">" and "<", which mirror in right-to-left text; worth a note to translators.
  `alarm_quiet_times_one` without a number is fine for English but would be wrong in a
  language whose `_one` includes 0, if the alarm could ever be shown for 0 (it cannot now).
