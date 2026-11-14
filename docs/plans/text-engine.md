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

**Changed by the owner during the work:** dimna gains no new link-time dependency.
HarfBuzz and FriBidi are not linked and their headers are not in `c.h`; they are loaded at
run time (`std.DynLib`: `libharfbuzz.so.0`, `libfribidi.so.0`) the first time a string with a
right-to-left or joined script needs them, the few functions used declared in Zig. A
missing library or function logs one line once, and that text is laid out unshaped, left to
right. CJK and Latin Extended need neither: glyphs on demand and font fallback only.
`readelf -d zig-out/bin/dimna | grep NEEDED` must list the same libraries before and after.

`src/gui/font.zig`, `src/gui/shape.zig` (new, if you want the shaping apart),
`src/gui/c.h` and `build.zig` (no longer needed: see the owner's change above), `src/gui/gpu.zig` (the atlas: its
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

## Report

Branch `worktree-agent-a77053814de62737c`, first commit `1d60892` (code and docs).

**What was built.** `src/gui/shape.zig` (new) holds the engine; `font.zig` hands it every
string that is not made only of the fixed glyphs (Latin-1, the six extra symbols).

- Fast path: a string of fixed glyphs is laid out as before. A test checks that with the
  engine it gives byte-identical vertices and widths to the same font without one, and that
  the engine is not called. The stored outputs (`display_frame.txt`, `tiles_draw.txt`,
  `control_layout.txt`) were not touched and their tests pass.
- Unshaped path (no libraries needed): Latin Extended, CJK and the like. One glyph per code
  point from the first font that has it, left to right, with advances rounded as on the fast
  path. Spaces and punctuation stay in the font of the text around them; marks stay with
  the character before them.
- Shaped path: used when a string has a character of a right-to-left or joined script
  (Hebrew, Arabic, Indic, ...; combining marks; joiners and bidi controls). FriBidi gives
  the levels (base direction from the first strong character) and rule L1. Rule L2 is done
  here on the runs. Each run is split by font and shaped by HarfBuzz (`hb_ft` font, hinted
  load flags), and positions are rounded to whole pixels.
- **Owner's change applied:** HarfBuzz and FriBidi are dlopened on first need, not linked.
  The 13 + 4 functions are declared in Zig and looked up by name. A missing library or
  function logs one line once ("... install harfbuzz and fribidi"), and that text falls back
  to the unshaped path. `build.zig` and `c.h` are unchanged from main.
  `readelf -d zig-out/bin/dimna | grep NEEDED` gives the same list before (main, built in
  /tmp) and after: libwayland-client.so.0, libvulkan.so.1, libfreetype.so.6,
  libfontconfig.so.1, libxkbcommon.so.0, libasound.so.2, libm.so.6, libc.so.6,
  ld-linux-x86-64.so.2.
- Fallbacks: `Noto Sans CJK SC` (with fontconfig's face index, so SC, not JP), then
  `Vazirmatn`, else `Noto Sans Arabic`, then fontconfig's best match for the code point
  (looked up lazily, once per code point, at most 8 fonts). The named ones are checked by
  family name, because fontconfig always offers something. Each fallback is sized
  (`FT_Set_Char_Size`, 26.6) so its line height is within 1 px of the primary's. All fonts
  share the primary's baseline.
- Atlas: 2048x2048. Glyphs are keyed by (font, glyph index); the fixed glyphs are seeded
  into that map. `gpu.textFont(&font)` is called once after `createText` in main, control
  and tiles. `Gpu.draw` then copies the rows changed since the last frame through a
  host-visible staging buffer, made on first use, before the render pass. When the atlas is
  full: one warning, and the missing glyph with the glyph's own advance.
- Cache of laid-out strings: 2048 entries, least recently used out, keyed by the bytes (one
  engine per font).
- `font.Batch`'s public API is unchanged. `Font` gains a defaulted `engine` field,
  `takeDirty()`, and a public `Pen` and `codepointAt`. Fonts made by hand in tests have no
  engine and behave exactly as before.

**Deviation from plain Unicode bidi (intended).** With UAX #9 alone, "فیلتر 300-6000 Hz"
shows as "Hz 6000-300 ..." (`fribidi` on the command line confirms this): digits after an
Arabic-script letter become AN, and an ASCII '-' between two AN does not join them. So in any
string with an R/AL letter, each stretch from an L/EN (or a sign before an EN) to the last
L/EN before the next R/AL letter is wrapped in LRI…PDI, which are not drawn. This keeps
"300-6000 Hz", "-10 ms" and "50%" as one left-to-right block. It applies to any Latin word
inside right-to-left text. The translators should know about it.

**Timings** (ReleaseSafe, thread CPU time, `DIMNA_TEXT_BENCH=1 zig build test
--release=safe`). One frame of 200 labels (fast: 37-43 Latin-1 characters each; shaped:
half Persian with numbers, shaped; half Chinese, about 30 characters each):

| path | ms per frame |
|---|---|
| fast path | 0.22 |
| shaped, first frame (layout and rasterising 215 glyphs) | 5.0-6.1 |
| shaped, cache miss (glyphs already drawn) | 3.8-4.1 |
| shaped, cached | 0.075 |

The cached shaped path costs less than the fast path, because it replays stored glyphs
without decoding UTF-8. A label whose text changes every frame (a live number in Persian)
pays the cache-miss cost of about 20 µs per label. The GPU upload of changed rows was not
measured: that would need a window, and none was opened.

**CJK glyphs that fit:** 23,098 at 14 px, Noto Sans CJK SC at about 11.6 px. All of
U+4E00-U+9F9F (20,896) plus most of Extension A, alongside the fixed glyphs, the fixed-width
set and the benchmark's 215 glyphs.

**Fonts on this machine:**
- Lato Regular (`/usr/share/fonts/TTF/Lato-Regular.ttf`, primary)
- Noto Sans CJK SC (`/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc`, face 2)
- Noto Sans Arabic (`/usr/share/fonts/noto/NotoSansArabic-Regular.ttf`)
- Vazirmatn: not installed
- DejaVu Sans (used by one test)
- Hack (monospace)

HarfBuzz 15.1.0 and FriBidi 1.0.18 are installed and loaded.

**Lam-alef.** Noto Sans Arabic does not draw lam-alef as one glyph: HarfBuzz gives two glyphs
(`uni0644.init.rlig` + `uni0627.fina.rlig`). So there are two tests:
- "one glyph in a font that has the ligature" uses DejaVu Sans as the primary;
- "its own forms in a font that draws it as two glyphs" checks that Noto's pair is neither
  the isolated nor the ordinary joined forms.

In سلام the meem is correctly isolated (it follows alef), so that test checks the other
letters.

**Tests.** `zig build test --summary all`: core 133 pass; gui-test 121 pass, 1 skipped (the
benchmark, which runs only with `DIMNA_TEXT_BENCH`). `zig build --release=safe` succeeds and
`zig fmt --check src build.zig` prints nothing.

**Break-it results.** Each break was a one-line change, reverted afterwards.

| break | tests that failed |
|---|---|
| `bidi.EN` = 0x221 | bidi types, isolation, Hz range |
| isolation off (`break false`) | isolation (strings differ); Hz range (gid 402 vs 15) |
| L2 reverses nothing | L2 order; Hz range |
| `allow_shaping` false | joined word, both lam-alef tests, Hz range |
| fallback size ignores units per em | Chinese line height |
| named fonts tried in reverse | DejaVu lam-alef (2 glyphs); Hz range |
| cache never hits | cache (shape calls 3, expected 1) |
| cache not LRU | cache |
| dirty rows not marked | atlas (aborted on unwrapping a null; a crash, not a clean failure) |
| atlas full not remembered | atlas (warning count) |
| unshaped path's pen not advanced | unshaped Persian, Chinese, Hz range |
| fast path not taken for Latin-1 | fast-path test (shape calls 1, expected 0); vertices were still identical, since the unshaped path gives the same result |
| loader returns true on a missing function | loader test |

**Left open / unsure:**
- The case where the libraries are actually absent was not run, because both are installed.
  It is covered by the loader test (a missing library and a missing function both report
  failure) and by `allow_shaping = false` (the fallback layout).
- Latin text that goes through the shaped path (inside Persian) is kerned by HarfBuzz;
  fixed-glyph and unshaped text is not. Lato's "300-6000 Hz" came out the same either way.
- A Latin-1 character in an otherwise Chinese or Polish string goes through the unshaped
  path. It gives the same advances as the fast path but may come from a different
  rasterisation of the same glyph (by glyph index, seeded from the fixed glyphs, so it is
  normally the same).
- CJK at the primary's line height is small (about 11.6 px ideographs at `font_px` 14).
  This is what the plan asked for, but it may be hard to read; worth a look on the rig.
- Bidi isolation uses heuristic character ranges (`needsShaping`, `isMark`, `isNeutral`)
  instead of the Unicode database, so that the unshaped path needs no library.
- Strings with invalid UTF-8 or control characters mixed with non-Latin-1 text now go
  through the engine (U+FFFD from a fallback font, or the missing glyph) instead of "?".
- The control window's mirrored layout and translations are not part of this plan.
