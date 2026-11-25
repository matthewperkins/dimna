# Plan: what Core Text does, measured (Core Text, step 2)

Read `docs/plans/README.md` first, then `docs/plans/macos-coretext-text.md` (the overview),
then the headers of `src/gui/font.zig` and `src/gui/shape.zig` for what dimna asks of its
text libraries today.

The Mac's text is to move from FreeType, HarfBuzz and FriBidi to Core Text. Before anyone
writes that backend, this step finds out what Core Text gives, with a small program of
its own. **It changes nothing in dimna.** Its product is a report of measured facts and
the program that produced them.

## Where you work

On the owner's Mac (Apple silicon, macOS 27), in the git worktree you are given, on its own
branch off `main`. Zig 0.17.1 is `~/.local/opt/zig-aarch64-macos-0.17.1/zig` (not on
`PATH`); only Apple's Command Line Tools are installed (no Xcode). Write the probe in C or
Objective-C under `tools/coretext-probe/` (as `tools/metal-latency/` is), built with
`zig cc` and a short script; it prints text and may write PGM images of glyph bitmaps to a
folder you name. It opens no window, plays nothing, touches no USB. No `sudo`, nothing
installed, no SSH, no permission prompt (if one appears, stop what caused it and report).
Never ask macOS for a font that is not installed (it may offer to download it): use
only fonts already on the machine. Temporary files:
`T=$(mktemp -d /private/tmp/dimna-ctp-XXXXXX)`, removed at the end with `set -u`, the
variable quoted and a `case` check on that prefix before any `rm -rf`. Do not push; do not
rewrite history.

For comparison you may call dimna's present text code from a test (read only: add a
test-only dump if you need one, in your worktree, and do not commit it), or FreeType
directly from the probe (`vendor/freetype` is in the tree and builds as `build.zig`
shows; Homebrew's HarfBuzz and FriBidi are installed on this Mac).

## What to find out

For each, what you ran, what it printed, and the answer in a sentence.

1. **A glyph's coverage.** For a `CTFont` at 14, 20 and 24 px (pixels, not points: say
   how the size is given so that it is pixels) and a glyph id: an 8-bit coverage bitmap
   through `CTFontDrawGlyphs` into a `CGBitmapContext` (which pixel format gives
   coverage, with font smoothing and subpixel positioning off or on, and what each
   setting changes), its bounding box, bearings and advance. Against FreeType for the
   same font file and size (the system font, Helvetica Neue, Menlo, Hiragino Sans GB,
   Geeza Pro): advances (whole pixels or not), bearings, and how the bitmaps differ (mean
   and largest difference in coverage, and a pair of PGMs for "Port A 300-6000 Hz").
2. **Metrics.** Ascent, descent, leading, line height, capital height (and alef height
   for Geeza Pro) against FreeType's for the same fonts and sizes.
3. **Which font.** What Core Text gives for the system UI font
   (`CTFontCreateUIFontForLanguage`: which kinds there are, which one a label would use),
   for a fixed-width system font, for a family by name, and for a name that is not
   installed (without triggering a download: say how you made sure). Whether the system
   font is a variable font and which instance is used. Which font Core Text falls back to
   (`CTFontCreateForString`) for each of U+03C3, U+2013, U+2192, U+266A, U+25B8, U+25BE,
   a Chinese character, a Persian letter.
4. **A line laid out.** Through `CTLine` (and `CTTypesetter` if it differs): for "Port A",
   a Persian word, "فیلتر 300-6000 Hz", a Chinese label, and a Latin name followed by
   Persian, with the base writing direction forced left-to-right and right-to-left: the
   runs, each run's font, glyph ids, positions and advances, in visual order. The same
   strings with U+2066/U+2069 around each Latin-or-digit stretch (the rule in
   `shape.zig`'s header): does "300-6000" keep its order, are the digits kept European.
   Against what dimna lays out today for the same strings (glyph count, order, width).
5. **Bidi apart from shaping.** Can the bidi levels or the visual order of a paragraph be
   had from Core Text or Core Foundation without laying out a line (and which calls), or
   only as the runs of a `CTLine`?
6. **Cost.** Median and worst over a few thousand: a face made; a 40-character Latin line
   laid out; a Persian line; one glyph rasterised at 14 px. Against the same through
   dimna's present code where it is easy to measure (`DIMNA_TEXT_BENCH`, `shape.zig`).
7. **Threads.** dimna's three windows each have their own font on their own thread: may
   three threads each use their own `CTFont`, `CTLine` and bitmap context at once? Run it
   (three threads laying out and rasterising for ten seconds) and look at Apple's
   documentation in the SDK headers for what is promised.
8. **Linking.** Which frameworks, and whether the calls translate through Zig's
   `addTranslateC` or are better declared by hand (as `fontfind_coretext.zig` does, and
   why it does).

## Done means

The answers above with their evidence; a recommendation, from what you measured, of
where the seam between dimna's shared text code and a Core Text backend should sit (a
glyph and a run at a time, as with FreeType and HarfBuzz, or a whole line at a time);
everything that surprised you; the probe and its script committed on your branch under
`tools/coretext-probe/` with a short README, not pushed; your temporary folder gone.

## Files you may change

New files under `tools/coretext-probe/` only.
