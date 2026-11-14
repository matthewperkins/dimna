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
