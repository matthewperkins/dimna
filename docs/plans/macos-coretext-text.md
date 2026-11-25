# Plan: text on macOS through Core Text (overview, for discussion)

Read `docs/plans/README.md` first. This is the overview and its open decisions; each step
below gets its own plan file (`macos-text-step1-seam.md` and so on) once the owner has
settled the decisions marked **To decide**. Nothing here has been started.

## Why

On macOS dimna draws text with three libraries that macOS does not have:

- **FreeType** (rasterising, metrics, character-to-glyph): since 2026-11-24 vendored and
  linked statically (`vendor/freetype`), so nothing need be installed for it.
- **HarfBuzz and FriBidi** (shaping and bidi, for Persian and other joined or
  right-to-left scripts): loaded at run time from Homebrew, if there. Without them dimna
  falls back to English.

Core Text, which macOS has, does all three jobs. With it the Mac build would need nothing
vendored and nothing installed for any language, and an app bundle would carry no library.

**A hazard that makes this more than tidiness.** `shape.zig` hands HarfBuzz the FreeType
face (`hb_ft_font_create_referenced`), and Homebrew's HarfBuzz links Homebrew's FreeType
dylib. So on a Mac with Homebrew, Persian text is shaped by one copy of FreeType working
on a face made by another (dimna's static one). Today both are 2.14.3 and the shaping
tests pass. When Homebrew moves to another FreeType (2.15.0 is already its stable), the
two copies differ, and what happens then has not been tried. It is listed in
`docs/OPEN.md`. Core Text removes it; so would shaping without `hb-ft` (decision 5).

## What the text code is today

About 2,500 lines in three files, with 27 tests:

| file | what it does | what is system-specific in it |
|---|---|---|
| `font.zig` (507) | one font at one size: the atlas, the fixed glyphs (Latin-1 and six symbols), the fixed-width set, `Batch` (quads for text, lines, rectangles) | `Font.init`, `addMono`, `place`: FreeType calls |
| `shape.zig` (1,471) | strings beyond the fixed glyphs: which font has each character, bidi, shaping, glyphs rasterised on demand, the cache of laid-out strings | the `Engine`: FreeType faces, HarfBuzz, FriBidi, mixed in with the policy |
| `fontfind.zig` + backend (492 for Core Text) | font files by pattern | already a seam: fontconfig or Core Text; the Core Text one opens files with FreeType to find a face's index in a collection |

What is **policy**, and must stay shared and mean the same on both systems:

- which strings take the fast path (only fixed glyphs: one glyph a code point, no kerning);
- the paragraph direction rule (`Engine.rtl` from the language; else the first strong
  letter) and the isolation of Latin letters and digits inside right-to-left text
  ("فیلتر 300-6000 Hz" keeps "300-6000" in that order);
- fallback order: the primary font, the named fallbacks for Chinese and Persian, then
  whatever the system offers for the character;
- a fallback font's letters scaled to stand as tall as the primary's capitals;
- the cache, the atlas packing, the "atlas full" behaviour, the missing glyph.

What the stored test outputs depend on: **not FreeType.** `display_frame.txt`,
`control_layout*.txt` and `tiles_draw.txt` are made with a font built by hand (every
character 8 px wide, no bitmap). They do not change and need no loosening. The tests that
use real fonts are the 27 in `font.zig`, `shape.zig` and the lookup backends.

## The seam aimed at

One file chooses the backend at compile time, as `gpu.zig`, `window.zig` and `usb.zig`
do: `text_backend.zig` -> `text_freetype.zig` (Linux; and macOS until the switch) or
`text_coretext.zig`. What a backend offers, in the project's terms and nothing of the
library's:

- **a face**: opened for a pattern (as `fontfind` understands them) at a pixel size; its
  ascent, line height and capital height; whether it has a code point;
- **a glyph's coverage**: for (face, glyph id), an 8-bit bitmap with its bearings and
  advance, written where the shared code says in the atlas;
- **a run laid out**: for a stretch of code points in one face and one direction, the
  glyph ids with their offsets and advances, in visual order (HarfBuzz's job today);
- **bidi levels** for a paragraph with a given base direction (FriBidi's job today), or
  the whole of "a paragraph laid out" if the backend can only do both together
  (**to be found out for Core Text**, step 2: `CTLine` does bidi and shaping in one call,
  so the seam may have to sit one level higher on the Mac: "a string with these isolates
  and this base direction, laid out", with the shared code inserting the isolates);
- **a fallback face for a character** none of the named fonts has.

`fontfind` becomes part of the backend on the Mac (Core Text gives font objects, not
files; the file and face-index search exists only because FreeType needs a file).

## Steps

Each is one agent's work with its own plan file, evidence and "done means".

1. **The seam, with no change in behaviour** (Opus; on the rig and the Mac). Move every
   FreeType, HarfBuzz and FriBidi call of `font.zig` and `shape.zig` into
   `text_freetype.zig` behind the interface above; the policy stays where it is. Done:
   on Linux the display, control and tiles draw the same pixels (the atlas bytes and the
   vertex lists of a set of strings in seven languages compared before and after), the
   27 tests pass unchanged, the text benchmark (`DIMNA_TEXT_BENCH`) is no slower.
2. **What Core Text does, measured** (Sonnet or the lead; a throwaway tool under
   `tools/`, on the Mac). To be found out and written down, not assumed:
   - an 8-bit coverage bitmap of a glyph by id (`CTFontDrawGlyphs` into a
     `CGBitmapContext`): its bearings and advance against FreeType's for the same font and
     size, with font smoothing off, at whole and at fractional pen positions;
   - a Persian, a Chinese and a mixed string through `CTLine`: glyph ids, positions, the
     font of each run (fallback), with the base direction set and with U+2066/U+2069
     around the Latin stretches, against what `shape.zig` produces today;
   - whether bidi levels can be had without shaping, or only whole lines;
   - what Core Text picks for `sans-serif`, `monospace`, a named family, a missing family,
     and for the six symbols beyond Latin-1;
   - the cost: a line of 40 characters laid out, a glyph rasterised, a face made; and
     whether three threads (the three windows each have their own font) may use Core Text
     at once;
   - the system font is a variable font: which instance Core Text uses and whether its
     advances are whole pixels.
3. **`text_coretext.zig`** (Opus; on the Mac), to the seam of step 1 as corrected by step
   2. Tests: the shared ones as loosened below, and its own.
4. **Joining, and the owner's eye** (the lead): the Mac built with Core Text; all seven
   languages on the display, the control window and the tiles looked at by the owner;
   the benchmark; then the default switched, the docs, and decisions 3 and 4 carried out.

## Tests: looser where a real font is involved

The owner's ruling (2026-11-24): slight differences in appearance across the systems are
expected, and tests that use real fonts may be loosened to allow them.

- **Kept exact** (they do not depend on a backend): the stored outputs; the fast path's
  arithmetic with the hand-made font; the cache; the isolation rule and the paragraph
  direction on code points; visual order from given levels.
- **Loosened to properties**, the same assertions on both systems: a Persian word's
  glyphs come out right to left and fewer than its letters where they join; "300-6000"
  stays in that order inside Persian text; a Chinese string takes its glyphs from the
  Chinese fallback; a fallback's capitals are within a pixel or two of the primary's; a
  string's width is within a few per cent of the sum of its advances; every glyph drawn
  has coverage inside its box in the atlas and none outside.
- **Per backend**: glyph ids, exact advances and exact bitmaps, where a test needs them.
- Each loosened test is broken on purpose once, as `docs/plans/README.md` asks, to show
  it can still fail.

## Decided by the owner (2026-11-24)

1. Core Text for everything on the Mac (a). 2. The default font is the macOS system UI
font. 3. FreeType is removed from the Mac at once when Core Text is accepted (no build
option kept; `vendor/freetype` goes). 4. Linux unchanged. 5. The HarfBuzz hazard is left
documented (since seen to happen on the CI runner: `docs/OPEN.md`). 6. The app ships first
on the static FreeType; a new release follows when Core Text is ready. Start: now.

The questions as they were put:

1. **How far.** (a) Core Text for everything on the Mac: rasterising, shaping, lookup;
   FreeType, HarfBuzz and FriBidi gone from the Mac build. (b) Core Text for bidi and
   shaping only, FreeType still rasterising. The lead recommends (a): in (b) the glyph ids
   and advances come from Core Text's instance of a font and the bitmaps from FreeType's,
   and for a variable font (the system font is one) those need not agree.
2. **The default font.** Today `sans-serif` on the Mac resolves to the system font's file.
   With Core Text it can be the system UI font itself (`CTFontCreateUIFontForLanguage`),
   which is what Mac applications show. Recommended.
3. **FreeType on the Mac afterwards.** Keep `text_freetype.zig` buildable on macOS behind
   a build option (`-Dtext=freetype`) for comparison, or remove `vendor/freetype` once the
   owner has accepted Core Text's look. Recommended: keep it for one release, then remove.
4. **Linux.** Nothing changes there in any option; step 1 only moves its code.
5. **The HarfBuzz hazard until then.** Either leave it (documented; Persian on a Mac with
   Homebrew), or shape without `hb-ft` on the Mac now (a HarfBuzz font made from the file
   itself, so HarfBuzz never touches FreeType): a contained change in `shape.zig`, worth
   it only if Core Text is more than a few weeks off.
6. **Order against the app bundle** (`macos-app-bundle.md`). The app can ship now on the
   static FreeType (six languages; Persian only with Homebrew), and gain Persian when
   Core Text lands; or wait for Core Text. Recommended: ship the app first.

## Not in this plan

Text on Linux; colour emoji; text input methods; the app bundle itself.
