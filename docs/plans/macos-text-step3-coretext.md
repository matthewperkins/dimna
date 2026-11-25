# Plan: the Core Text backend (Core Text, step 3)

Read `docs/plans/README.md` first, then `docs/plans/macos-coretext-text.md` (the overview:
why, the owner's decisions, "What step 2 found", "What the lead will build to", the
tests), then the header of `src/gui/text_backend.zig`: it is the contract this step
fulfils. `src/gui/text_freetype.zig` is the implementation to match in meaning;
`tools/coretext-probe/coretext_probe.c` is working Core Text code from this project for
everything this step needs (fonts, a typesetter's line with a base direction, glyph
coverage into a bitmap context), with what it measured in `tools/coretext-probe/results/`.

Step 1 put FreeType, HarfBuzz and FriBidi behind `text_backend.zig`. This step writes the
second backend, `src/gui/text_coretext.zig`, for macOS. **On Linux nothing may change**, and
on macOS the FreeType backend stays the default until the owner has looked at Core Text's
(step 4, the lead's).

## Where you work

On the owner's Mac (Apple silicon, macOS 27), in the git worktree you are given, on its own
branch off `main`. Zig 0.17.1 is `~/.local/opt/zig-aarch64-macos-0.17.1/zig` (not on
`PATH`); only Apple's Command Line Tools are installed. Open no window, play nothing, touch
no USB; run `zig-out/bin/dimna` only with `--help`. No `sudo`, nothing installed. Never ask
macOS for a font that is not installed (it may offer to download it): a family is asked
for by name only after it is found among the installed family names, and fonts are made
with the options that prevent activation and download (the probe shows both). If a
permission prompt appears, stop what caused it and report. Temporary files:
`T=$(mktemp -d /private/tmp/dimna-ct3-XXXXXX)`, removed at the end with `set -u`, the
variable quoted and a `case` check on that prefix before any `rm -rf`. Do not push; do not
rewrite history.

You should not need the rig. If you find the shared code (`font.zig`, `shape.zig`, outside
their tests) or `text_freetype.zig` must change, stop and report what and why before
changing it: such a change needs the Linux dump of step 1 repeated on the rig, which is
the lead's to arrange.

## What to build

1. **`build.zig`**: an option for macOS, `-Dtext=freetype` (the default, as today) or
   `-Dtext=coretext`, which `text_backend.zig` reads to choose the backend (Linux: always
   FreeType; the option is refused there). With `coretext` the Mac build compiles and
   links no FreeType (`vendor/freetype` is not built, `gui_c` is not needed by the text
   code) and loads no HarfBuzz or FriBidi; it links CoreText, CoreGraphics and
   CoreFoundation. Both choices must build and pass their tests. The option is temporary:
   step 4 removes it with FreeType.
2. **`src/gui/text_coretext.zig`**, to the contract in `text_backend.zig`'s header, every
   function and field the callers use. Core Text, CoreGraphics and CoreFoundation through
   their C interfaces, declared by hand in the file as `fontfind_coretext.zig` does (the
   probe found about 40 functions are needed), or through a small C file if a struct
   return or a callback makes that the honest choice; say which and why. Every CF object
   made is released; say how you checked.
   - **Fonts by pattern** (`findFont`, `Face.open`): `sans-serif` is the system UI font
     (`CTFontCreateUIFontForLanguage`, the kind a label uses), with Core Text's own
     optical sizing; `monospace` the system's fixed-pitch UI font; another name is a
     family, used if installed, and if not the system font with one line in the log
     (never an error that stops the program, never a download);
     `sans-serif:charset=<hex>` is whatever Core Text falls back to for that character.
     What `findFont` writes into the buffer and `Face.open` takes back is yours to define
     (a name, not a file); the log shows it.
   - **Sizes are pixels**: an em of `px` pixels, as the probe did it.
   - **Metrics**: `ascent()` and `lineHeight()` feed `Font.ascent` and `line_height`, which
     lay out every window. Core Text's are fractional where FreeType's are whole pixels:
     decide the rounding (so that rows of text are a whole number of pixels high and
     glyphs do not clip), say what you chose, and give the figures beside FreeType's for
     the system font at 14, 20 and 24 px.
   - **Coverage**: an 8-bit alpha-only bitmap context, font smoothing off, subpixel
     positioning and quantization off, glyphs drawn at whole-pixel pens; bearings from
     the glyph's bounding box, widened so that no ink is cut. One context per `Face` or
     `Fonts`, reused. A colour glyph (emoji) is reported as not gray.
   - **`Fonts.layout`**: a `CTTypesetter` line of the given code points (isolates
     included) with the base direction in its paragraph style (`par_on`: natural); the
     runs' glyphs in visual order with their positions turned into offsets and advances
     as the contract says; each run's font added to the faces (by identity, so the same
     font is one face; at most `max_faces`, and what happens beyond that: say) and its
     index returned. Glyphs of the isolate marks (zero width, no ink) may be dropped or
     returned; the shared code accepts both. Core Text's own fallbacks, not scaled.
   - **`Fonts.mapSimple`**: one glyph per code point from the face Core Text would use for
     it, without laying out a line.
   - **`shaping()`** is always available on the Mac; **`bidiTypes`** through ICU's
     `u_charDirection` (`libicucore`, declared in the SDK's `unicode/uchar.h`), mapped to
     the values in `text_backend.bidi`; a test checks the mapping for one character of
     each class the shared code looks at.
   - The fields the tests read (`named`, `cap_px`, `capPx`, `faces[k].line_height`): give
     them the meaning nearest FreeType's that is true of Core Text, or change those tests
     to be per backend; say which.
3. **Tests.** The text tests in `font.zig`, `shape.zig` and `text_backend.zig` must pass
   with both choices. Where one asserts what only FreeType gives (exact advances, glyph
   ids, a named fallback font, a scaled fallback), loosen it to the property it stands
   for, the same assertion for both backends, as the overview's "Tests" section lists; or
   make it per backend. For each test you change: its name, what it asserted, what it
   asserts now, and the one-line break that still makes it fail. New tests of your own
   in `text_coretext.zig` for what is specific to it (the font for each pattern, a name
   not installed, coverage inside its box, the faces list, releasing everything).
4. **A picture for the lead** (who can open images): a test, off unless an environment
   variable names an output file, that draws a sheet of sample text through `font.Batch`
   exactly as the windows do (the atlas and the quads, composited on the display's
   background colour in software) and writes it as a PNG (`stb_image_write` is in the
   tree): at 14, 20 and 24 px, a panel title ("A   2.00 s   400µV/row   300-6000 Hz"),
   the digits and punctuation, fixed-width text, the six symbols, one label in each of
   the seven languages (from `src/gui/lang/`), the Persian string with a range in Hz, and
   Chinese. Run it with both choices and keep both PNGs in your temporary folder until
   you have reported their paths; then copy them to the session scratchpad the lead
   names in your instructions before removing your folder.

## Evidence

1. `zig build test --summary all` with `-Dtext=freetype` and with `-Dtext=coretext`: the
   counts (today: 326 of 343 with 17 skipped, or 327 with the dump test's variable set),
   and each test that differs between the two.
2. With `-Dtext=freetype`: the dump of step 1 (`DIMNA_TEXT_DUMP=<file> zig build test`)
   has sha1 `84312276b252f909b15cc1f4b798831e59e737c1` on this Mac, before and after your
   work. (If Homebrew's FreeType has changed since, it may not: then compare before and
   after instead and say so.)
3. `git diff main -- src/gui/text_freetype.zig src/gui/font.zig src/gui/shape.zig`: only
   test changes in the last two, none in the first; and the Linux cross-build of the
   headless program still compiles (`zig build -Dgui=false -Dtarget=x86_64-linux-gnu`).
4. With `-Dtext=coretext`: `otool -L zig-out/bin/dimna` (no FreeType, nothing outside
   macOS); `dimna --help` exit 0; the binary's size beside the FreeType build's.
5. The benchmark (`DIMNA_TEXT_BENCH=1`, release-safe) with both choices, three runs each.
6. Three threads, each with its own `Font`, laying out and drawing the seven languages'
   strings for ten seconds: no wrong result against a single-threaded reference.
7. The two PNGs, and what you see in them yourself that differs.
8. `zig fmt --check src build.zig`.

Break it on purpose, once each, and say which test notices: the base direction ignored in
`layout`; a glyph's top bearing off by one; a CF object of a line not released (if no
test can notice, say how a leak would be found); `bidiTypes` giving AL as R.

## Files you may change

New `src/gui/text_coretext.zig` (and a C file and header beside it only if you chose that
way); `src/gui/text_backend.zig` (the choice, and the contract's wording where Core Text
makes it more precise); `build.zig` (the option, the frameworks, what is compiled for
which choice); `src/gui/tests.zig`; the **tests** in `src/gui/font.zig` and
`src/gui/shape.zig` as item 3 allows. Anything else: stop and report.

## Done means

The evidence and the break-it results in your report; every decision the plan left to you
with its reason; every place Core Text's text will knowingly differ from FreeType's on
screen; what you could not make the contract express and worked around; the work
committed on your branch, not pushed; the worktree clean; the PNGs copied where the lead
asked; your temporary folder gone.
