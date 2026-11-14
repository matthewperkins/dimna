# Plan: every user-facing text in one catalogue (English), ready for translations

Read `docs/plans/README.md` first; its rules apply. Display only: nothing here touches
acquisition, recording, the board or the feed.

## Why

dimna will be translated into German, French, Portuguese, Polish, Mandarin and Farsi.
This step moves every text the user sees into a catalogue, in English only, with the
program's output **byte for byte unchanged**. Translations and the text engine (HarfBuzz
shaping, right-to-left, glyphs on demand) come later, in other plans; do not start them.

## Files you may change or add

`src/gui/i18n.zig` (new), `src/gui/lang/en.zig` (new), `src/gui/display.zig`,
`src/gui/control.zig`, `src/gui/tiles.zig`, `src/gui/session.zig`, `src/gui/notes.zig`,
`src/gui/main.zig`, `src/gui/ui.zig`, `src/gui/format.zig`, `src/gui/args.zig` (only the
config key `language`), `src/gui/tests.zig` (registering tests), `docs/display.md` and
`README.md` (the config key, one paragraph).

## The design (follow it)

- `src/gui/lang/en.zig`: one `pub const` per message, named for what it says
  (`disk_full_alarm`, `key_help_ack_alarm`, `panel_sweeps`), each a comptime string.
  Messages with values use **named** placeholders, so translations can reorder them:
  `pub const disk_full_in = "THE DISK IS FULL IN {[left]s}";` and are formatted with a
  struct: `.{ .left = text }`. Group the file by window/part with comment headings, and
  give each message a one-line comment saying where it appears when the name does not.
- `src/gui/i18n.zig`:
  - `pub const Language = enum { en, de, fr, pt, pl, zh, fa };` and
    `pub var current: Language = .en;` set once at startup, before any window draws.
  - A table `catalogue(lang)` returning the language's file as a type; for now every
    language returns `en` (the other files do not exist yet). Later plans add
    `lang/de.zig` etc.; a message missing from a language falls back to English at
    comptime (`@hasDecl`).
  - `pub fn text(comptime id: Id) []const u8` and
    `pub fn fmt(buf: []u8, comptime id: Id, args: anytype) []const u8` (formatting as
    `format.fmt` does now: cut at a whole UTF-8 character when the buffer is short),
    where `Id` is an enum made at comptime from `en.zig`'s declarations, so a typo is a
    compile error. Both `inline` switch over `current`.
  - A test that walks every language's file (only `en` now) and fails on a declaration
    that `en.zig` does not have (a stale translation), and one that formats every
    message with placeholders using dummy values, so a bad placeholder fails a test, not
    a user.
- **Moving the texts.** Every string a user can see in a window: panel titles, labels,
  alarms and warnings, banners, the key summary (`key_help`), the control window's
  headings, buttons, notes and tooltips, the tile window's texts, notes UI, review badge,
  waiting messages. Format strings that only lay out numbers and units (`"{d:.2} s"`,
  `"{d}µV/row"`) may stay where they are if nothing in them is a word; units stay as they
  are (µV, ms, Hz). **Not moved:** log messages, the command-line usage text, config keys,
  file contents (recordings, events.tsv), test-only strings.
- Config: top-level `language = "de"` (any of the enum's names); without it, the first
  two letters of `LANG` if they name one, else `en`. Unknown values log one warning and
  use `en`. Set `i18n.current` in `main.zig` right after the config is read.

## Tests and evidence

- `src/gui/testdata/display_frame.txt` must be **unchanged** (proof nothing visible
  changed); same for the control and tile stored outputs if they exist. Do not regenerate
  them.
- The two catalogue tests above, each broken once on purpose (README rule).
- A test for the language choice: config value, `LANG=pl_PL.UTF-8` → `.pl`,
  `LANG=C` → `.en`, a bad value → `.en`.
- `zig build test --summary all`, `zig build --release=safe`, `zig fmt --check src build.zig`.
- Report: how many messages `en.zig` holds, by part; any string you were unsure was
  user-facing; anything you left in place and why.

## Do not

Run the GUI; touch the font code; translate anything; change any text's wording (if a text
reads badly, list it in the report instead).

## Report

Branch `worktree-agent-a1646439f13b76d4c`, commits `46b964c` (catalogue, `i18n.zig`, config key,
tests, docs) and `c438fd1` (the call sites). Files changed: `src/gui/i18n.zig` and `src/gui/lang/en.zig`
(new), `display.zig`, `control.zig`, `tiles.zig`, `session.zig`, `main.zig`, `args.zig`, `tests.zig`,
`README.md`, `docs/display.md`. `notes.zig`, `ui.zig` and `format.zig` needed no change (no user-facing
text in them). The stored outputs in `src/gui/testdata/` are untouched (`git status` clean there).

**What I ran.** The core `zig build test` was green throughout (133 tests, not changed by this work).
`zig build test --summary all` ends with `Build Summary: 18/18 steps succeeded; 112/112 tests passed`
(GUI tests: 107 before, 112 now: four in `i18n.zig`, one in `args.zig`). `zig build --release=safe`
printed nothing (success). `zig fmt --check src build.zig` printed nothing. Not run: the GUI, `--sim`,
anything touching the board.

**Messages in `en.zig`: 256.** By part: shared words 15; display panel titles 18; display rows,
banners, status 10; key summary 87 (35 keys, 49 descriptions, 3 headings); spike-tile window 3;
control window: title/status/recording 25, notes and audio 22, spikes and headstages 20, a panel's
section 26; alarms 9; warnings 5 (with the two "about N min/s" fragments); notes under the board and
recording lines 12; start-up notice 4. Every message is referenced from code (checked by grep).

**Break it on purpose** (each reverted; the tree passes again):
- Stale translation: `catalogue(.de)` returning a struct with an extra `bogus` declaration. The test
  failed with `de: 'bogus' is not in lang/en.zig`.
- Placeholders: a `de` message `alarm_disk_full_in = "VOLL IN {s}"` (positional, not `{[left]s}`)
  failed `every message of every language ...` with `de alarm_disk_full_in: its placeholders differ
  from English's`. A `de` message with a wrong *name* (`{[gapz]d}`) does not reach the test: it is a
  compile error at the call sites (`no argument with name 'gapz'`), so the build fails instead.
  That is stricter than a test, but it means a wrong name is found by compiling, not by this test.
- Language choice: making a bad config value fall through to `LANG` failed with
  `expected .en, found .pl`; removing the "pl must end or be followed by a separator" check
  (so `LANG=plain` is Polish) failed the same test.
- Config key: renaming the key in `applyConfig` failed `args.test.language is read from the config`.
- Output unchanged: changing `tag_threshold`, `btn_save_view`, `tiles_all` and (before) the disk alarm
  text failed `display.test.what the display draws is unchanged`, `control.test.the control window's
  layout is unchanged`, `tiles.test.what the tile window draws is unchanged` and the `session` disk
  alarm test respectively.

**Design points.**
- `i18n.text(.id)`, `i18n.fmt(&buf, .id, .{ .name = v })` (cut at a whole UTF-8 character, like
  `format.fmt`), `i18n.print(writer, .id, args)` (for the places that write into a fixed writer, e.g.
  the alarm bar), `i18n.textOf(id)` for the key table. `pick(config, LANG)` chooses the language;
  `main.zig` sets `i18n.current` right after `parseArgs`.
- `KeyHelp` now holds two message ids; the display's key-summary vs usage test and the ASCII test read
  them with `textOfIn(.en, ...)`. Those two tests are about English by nature.
- `RecStatus`/`BoardStatus.say(id, args)` and `Notice.say(id1, a1, id2, a2)` are new; the old
  `setNote`/`set` with literal formats stay because the stored-output tests call them with test-only
  strings. They are no longer used by production code.
- Plural forms are kept as English had them: "{d} presets"/"1 preset" got two messages
  (`presets_one`, `presets_many`) because the "s" was added in code; "{d} sweeps", "{d} gaps",
  "{d} drafts", "{d} BLOCKS" are single messages and still read "1 sweeps"/"1 gaps" as before.
  Languages with several plural forms will need a plan for this (counted messages).

**Unsure whether user-facing, and left in place:**
- Window titles `"dimna"`, `"dimna control"`, `"dimna spikes"` (a compositor rule can match them;
  `window_title_status`, the display's title bar, which carries words, was moved).
- Texts that come from files outside this plan's list: panel names and `shortLabel`/`unit()`
  (`src/panels.zig`, e.g. "uV"), the board-settings diff lines in the quit prompt
  (`board_config.Diff`, "sample_rate   30000 -> 20000"), `scheme.Diagnostics.message()` (shown in the
  start-up notice), the `{t}` error names in alarms and notes. Only the fixed sentence around them moved.
- Pure layout/number formats ("{d:.1} ms   {d} fps", "{d:.0} ms", "{d} Hz", "µV", "σ", "±", "♪", clock
  "1:05", channel names "A1-5", "TTL2", "AUX1") and the `"   |   "` separator between alarms and
  warnings, and the three-space gap `triggeredTitle` strips from the filter text (it assumes
  the catalogue's titles start with `"   "`; a translation that changes that breaks the hot area).
- `usage` (command line), config keys, log lines and file contents, as the plan says.
- `win.init("dimna ...")` class names; `board_kind` text in `structure`-like recording info.

**Behaviour that differs in a corner case from before** (display of the normal case is identical):
`fmtLeft` ("about 12 min") used to return `"?"` if its 24-byte buffer overflowed and now cuts the text;
the window title is cut to its buffer instead of left unchanged when too long; the control window's
source line is computed once (its length was `min(160, count)` of the uncut text before, now the
length of the cut text). None can happen with real values.

**Wording I did not touch but that reads badly or is inconsistent:** "1 sweeps" (above); the key help
says "uV" while everything else says "µV" (ASCII only in the fixed-width font, so intended); the filter
corner is "from/to" in the control window but "low/high corner" in the key help; "scale" for the Y
range and "scale" for the tiles' threshold range; "THE BOARD WENT QUIET ONCE" reads oddly next to
"{n} TIMES"; "raw" is one message for the filter button, the row tag and the title's "raw", which a
translation may want to say differently.

**Not covered:** the stored outputs exercise the display's, control window's and tile window's
layouts, not every message (for example the control window's audio-running states, the quit prompt,
most alarm and note texts); those moved texts are compared only by reading the diff and, for the alarms
and the disk warnings, by the existing `session` tests. No second language exists, so nothing shows
that a different language file works end to end, beyond the comptime fallback and the checks above.
No GUI run; no check that a long translation fits any window.
