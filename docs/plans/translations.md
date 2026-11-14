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

## Report: pl, zh

Branch `worktree-agent-a1801113efe0130d3`, on main at 241b0a4 (`git merge --ff-only main`
fast-forwarded from 87942fc). Translations in commit 1534d4f; this report in the commit after.

Files: `src/gui/lang/pl.zig`, `src/gui/lang/zh.zig`, `docs/translations/pl.md`,
`docs/translations/zh.md` (new), and this section. Nothing else. Comments and headings are
kept in English, in en.zig's order; each file's `//!` header names its plural forms.

### Messages

- **pl**: 279 declarations: every message of en.zig (269) except the two
  `notice_language_*` (always English, per the plan), with each of the 12 counted messages
  as `_one`, `_few`, `_many` (no `_other`). en.zig has 245 plain messages and 12 counted
  ones (24 forms); pl has 243 plain + 36 forms = 279. Left out: 2.
- **zh**: 255 declarations: the same 243 plain, and each counted message as `_other` only
  (12). Left out: the same 2.

### Possibly too long (width > 1.5 × English; Chinese counted as 2 columns per character)

Polish: `btn_shaped` "kształtowany" (6 → 12), `section_headstages` "Przedwzmacniacze"
(10 → 16), `label_dsp_highpass` "górnoprzepustowy DSP" (13 → 20), `audio_muted`
", wyciszony" (7 → 11), `mode_sweep` "przebieg" (5 → 8), `help_time_base` "podstawa czasu",
`help_quit` "wyjście", and in the key summary `key_drag_red_line` / `key_drag_the_red_line`
"przeciągnąć czerwoną linię" (15/17 → 26). Shortened after the check: `key_the_chips`,
`help_stamp_preset`, `label_rows_shown`. Chinese: none over 1.5 ×.

### Evidence

- `zig build test --summary all`: `Build Summary: 18/18 steps succeeded; 129/130 tests passed (1 skipped)`.
- `zig fmt --check src build.zig`: printed nothing (exit 0).
- `zig build --release=safe`: exit 0, `zig-out/bin/dimna` and `dimna-headless` built.
- Break-it-on-purpose (each reverted; the `de title_review`, `de alarm_disk_full_in` and
  `pl alarm_gaps_few` lines are the test's own self-checks, printed every run):
  - trailing space added to pl `rec_failed`: `pl rec_failed: starts or ends with 0/1 spaces
    where English has 0/0`; `128/130 tests passed (1 skipped, 1 failed)`.
  - pl `note_saved_to` `{[path]s}` → `{[paht]s}`: `pl note_saved_to: its placeholders differ
    from English's`; 1 failed.
  - zh `rec_gaps_other` and `alarm_gaps_other` `{[gaps]d}` → `{[gap]d}`: a compile error,
    `src/gui/i18n.zig:239:37: error: '{[gap]d} 个间隙' needs a field 'gap'` (the call sites
    pass `.gaps`), so a renamed placeholder in a counted message cannot even build.
  - pl `alarm_dropped_few` deleted: `pl alarm_dropped: no form 'few'`; 1 failed.
- The languages are really used: a temporary test appended to `src/gui/i18n.zig` (removed
  with `git checkout`, not committed) set `current = .pl`, then `.zh`, and printed:

      [pl] Klawisze i mysz   (? lub Esc zamyka)
      [pl] DYSK ZAPEŁNI SIĘ ZA ok. 12 min
      [pl] x   30000 Hz   kanały: 46, elektrody: 32
      [pl] n=1: 1 przerwa | PŁYTKA ZGUBIŁA 1 PRÓBKĘ | PŁYTKA UCICHŁA RAZ (0.5 s lub dłużej bez danych)
      [pl] n=2: 2 przerwy | PŁYTKA ZGUBIŁA 2 PRÓBKI | PŁYTKA UCICHŁA 2 RAZY (0.5 s lub dłużej bez danych)
      [pl] n=5: 5 przerw | PŁYTKA ZGUBIŁA 5 PRÓBEK | PŁYTKA UCICHŁA 5 RAZY (0.5 s lub dłużej bez danych)
      [pl] n=12: 12 przerw | PŁYTKA ZGUBIŁA 12 PRÓBEK | PŁYTKA UCICHŁA 12 RAZY (0.5 s lub dłużej bez danych)
      [pl] n=22: 22 przerwy | PŁYTKA ZGUBIŁA 22 PRÓBKI | PŁYTKA UCICHŁA 22 RAZY (0.5 s lub dłużej bez danych)
      [pl] n=0: 0 przerw | PŁYTKA ZGUBIŁA 0 PRÓBEK | PŁYTKA UCICHŁA 0 RAZY (0.5 s lub dłużej bez danych)
      [zh] 按键与鼠标   （? 或 Esc 关闭）
      [zh] 磁盘即将写满：剩余约 12 min
      [zh] x   30000 Hz   通道：46，电极：32
      [zh] n=1: 1 个间隙 | 采集板丢失 1 个样本 | 采集板中断 1 次（0.5 s 以上无数据）
      [zh] n=2: 2 个间隙 | 采集板丢失 2 个样本 | 采集板中断 2 次（0.5 s 以上无数据）
      ... (5, 12, 22, 0 likewise)

  With it: `130/131 tests passed (1 skipped)`.

### Unexpected

- Nothing in the code. Every test run (before my change too) prints
  `[font] (warn): font atlas full: glyphs not yet drawn are drawn as the missing glyph`;
  I did not look into it. With Chinese's many glyphs, the atlas size may matter on screen.

### Not covered

Nothing was drawn (no GUI run, per the plan), so fonts, fit and layout are unchecked; the
translations are not reviewed by a native speaker; key names were chosen from convention,
not checked against a Polish or Chinese keyboard.

### In en.zig I would change

- `audio_listening_nothing` "nothing (click a row on the display)" addresses the user where
  the plan otherwise avoids it; Polish renders it "nic (klik na wierszu ekranu)".
- `notes_drafts_other` "0 drafts (` stamps one)" reads oddly at 0 (and so do the
  translations); a separate empty text would help.
- zh `alarm_disk_full_in` / `warn_disk_full_in` depend on `about_minutes` starting with a
  Chinese character ("约 12 min") to need no space before it; a comment in en.zig saying
  `left` is always one of `about_*` would make that safe to rely on.
- `mode_sweep` (a mode) and `title_sweeps_*` / `stepper_sweeps_*` (overlaid traces) use one
  word for two things; fine in Polish and Chinese, but worth a comment for translators.
