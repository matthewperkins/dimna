# Plan: a text engine for every script (HarfBuzz, FriBidi, glyphs on demand, font fallback)

Read `docs/plans/README.md` first; its rules apply. Display only: nothing here touches
acquisition, recording, the board or the feed.

## Why

dimna is being translated into German, French, Portuguese, Polish, **Mandarin (Simplified)**
and **Farsi**. Today `src/gui/font.zig` rasterises Latin-1 plus a few symbols into one
512x512 atlas at startup and lays text out one glyph per code point, left to right, with
no shaping. That cannot draw Polish ł (outside Latin-1), Chinese (thousands of glyphs) or
Persian (letters join and change form: needs shaping; written right to left with numbers
and units such as "300-6000 Hz" left to right inside: needs bidi).

Another plan runs at the same time (`docs/plans/i18n-catalogue.md`): it moves texts into a
catalogue in `display.zig`, `control.zig`, `tiles.zig`, etc. **Do not edit those files**
except where this plan lists; keep `font.Batch`'s public API (`text`, `label`, `rect`,
`textMono`, `font.width`, `line_height`) the same so the two merge cleanly.

## Files you may change or add

`src/gui/font.zig`, `src/gui/shape.zig` (new, if you want the shaping apart),
`src/gui/c.h`, `build.zig` (link `harfbuzz`, `fribidi`), `src/gui/gpu.zig` (the atlas: its
size and updating part of it), `src/gui/tiles.zig` and `src/gui/control.zig` **only** where
they create the font or upload its atlas, `src/gui/main.zig` likewise, `src/gui/tests.zig`,
`docs/display.md` (a paragraph on fonts), `README.md` (build dependencies: harfbuzz,
fribidi, and the Noto fonts as optional).

## What to build

1. **Fast path unchanged.** A string whose code points all have glyphs already in the
   atlas from the primary font *and* that needs no shaping (no code point at or above
   U+0590, i.e. no RTL or complex script, no CJK) is laid out exactly as now: same
   advances, no kerning. This keeps every existing stored output byte-for-byte
   identical and keeps the common case as cheap as it is. Prove it: the stored outputs
   (`src/gui/testdata/display_frame.txt`, and the tiles' and control's if they have them)
   do not change.
2. **Shaped path** for everything else: FriBidi splits the string into runs in visual
   order (base direction: from the string's first strong character; Persian text with
   "300-6000 Hz" inside must put the numbers left to right in place); each run is split
   further by font coverage; HarfBuzz (`hb_ft_font_create_referenced` on the FreeType
   face, `hb_buffer_guess_segment_properties` or set script/direction from the run)
   shapes each piece; glyph positions are converted to pixels (26.6 fixed point) and
   rounded as the fast path rounds.
3. **Fonts.** The primary font as now (fontconfig `family`). Fallbacks, looked up once at
   startup with fontconfig, used for code points the primary lacks: `Noto Sans CJK SC`
   (Simplified Chinese; fontconfig's default for zh on the rig is the JP face, so name SC
   explicitly, and choose the SC face index in the .ttc), then `Noto Sans Arabic` (or
   `Vazirmatn` if installed), then fontconfig's best match for the code point. A missing
   fallback logs one line and those characters draw as the primary font's missing glyph;
   it never stops the program. Fallback fonts are scaled so their line height matches the
   primary's within a pixel (CJK fonts are tall), and their baseline aligned.
4. **Glyphs on demand.** Glyphs are keyed by (font, glyph index) and rasterised the first
   time they are drawn into free space in the atlas. Grow the atlas to 2048x2048 (4 MB,
   R8); when a frame adds glyphs, upload only the changed rows (or the whole atlas if
   simpler and under ~1 ms; measure) before that frame draws. If the atlas fills, log
   once and draw the missing glyph; no eviction is needed for a UI's vocabulary, but
   say in the report how many CJK glyphs fit.
5. **A cache of shaped strings**: keyed by (string bytes, font), holding the glyph list
   with positions and the width; bounded (e.g. 2048 entries, least recently used out).
   The display redraws the same labels every frame; with the cache, a frame of shaped
   text should cost about what the fast path costs. `width()` uses the same shaping.
6. `textMono` stays ASCII-only, unchanged.

## Tests

- Stored outputs unchanged (the fast path): do not regenerate them.
- Persian: shaping "سلام" gives glyphs that are not the isolated forms (glyph indices
  differ from shaping each letter alone); "لا" gives one glyph (the lam-alef ligature) in a
  font that has it; in "فیلتر 300-6000 Hz" the visual order puts the Latin/number run as
  one left-to-right block, with "300" left of "6000". Skip (do not fail) a test whose font
  is not installed, saying so in the test name's output.
- Chinese: "阈值" draws two glyphs from the CJK fallback (not the missing glyph), each
  non-empty in the atlas, with the line height within a pixel of the primary's.
- Polish: "ł" draws from the primary font if it has it (Lato does).
- The cache: the second layout of a string does not call the shaper (count calls), and an
  entry past the bound is evicted.
- The atlas: adding glyphs marks the region to upload; filling it logs once and does not
  crash.
- Break each new test once on purpose (README rule).
- **Timing**: in a test or a small benchmark in the report, the CPU time to lay out a
  frame's worth of text (say 200 labels of 20-60 characters) on the fast path, on the
  shaped path cold, and on the shaped path cached. Report the numbers.
- `zig build test --summary all`, `zig build --release=safe`, `zig fmt --check src build.zig`.

## Do not

Run the GUI (no windows: tests and benchmarks only); translate anything; change any text;
mirror any layout (the control window's right-to-left layout is a later plan).

## Report

Append a "Report" section: what you built, timings, how many CJK glyphs fit, the fonts
found on this machine, test break-it results, and anything left open.
