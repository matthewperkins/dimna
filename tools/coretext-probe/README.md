# coretext-probe

A throwaway probe for `docs/plans/macos-text-step2-probe.md`: what Core Text gives, measured,
against FreeType (dimna's static `vendor/freetype`) and, for cost, HarfBuzz and FriBidi.
It opens no window, plays no sound and touches no USB device. It asks only for fonts that are
installed (the one name that is not installed is gibberish, looked up in the installed
families first, and made with downloading turned off; see `fonts` mode).

    sh tools/coretext-probe/build.sh "$T/b"          # T=$(mktemp -d /private/tmp/dimna-ctp-XXXXXX)
    "$T/b/coretext_probe" MODE [-v] [--out DIR] [--seconds N]

Build needs `zig` (`$ZIG`, else `~/.local/opt/zig-aarch64-macos-0.17.1/zig`), the Command Line
Tools' SDK, and Homebrew's HarfBuzz and FriBidi (headers and dylibs under `/opt/homebrew`,
used only for the comparisons in `cost`).

| MODE | plan question | what it prints |
|---|---|---|
| `glyph` | 1 | per font (system SFNS, Helvetica Neue, Menlo, Hiragino Sans GB, Geeza Pro, SFNS with Core Text's automatic optical size off) and size (14, 20, 24 px): advances, ink boxes, coverage differences to FreeType for four CGContext settings, pen at +.25/.5/.75; pixel formats; "Port A 300-6000 Hz" as PGMs with `--out DIR`, plus an ASCII picture at 14 px. `-v`: one row per glyph |
| `metrics` | 2 | ascent, descent, leading, line height, cap height (alef for Geeza Pro) against FreeType's |
| `fonts` | 3 | the UI font kinds, the variable axes, families by name, a name that is not installed, `CTFontCreateForString` for the characters of the plan |
| `lines` | 4 | `CTTypesetter` lines: runs, fonts, glyph ids, positions, with natural, forced LTR and forced RTL base direction, with and without U+2066/U+2069; a cascade list |
| `bidi` | 5 | forced embedding levels on a typesetter; the RTL bit of a run; ICU's `ubidi_*` found in libicucore |
| `cost` | 6 | median, p99 and worst over 3000 repetitions |
| `threads` | 7 | three threads for 10 s (`--seconds`), each with its own CTFont, lines and bitmap contexts, results compared with a single-thread reference |

`results/` holds the output of one run of each mode on the owner's Mac (Apple silicon, macOS
27.0.1), and, for comparison, what dimna's present code printed for the same strings
(`dimna_layout_dump.txt`, from a throwaway test added to `src/gui/shape.zig` and not
committed) and its `DIMNA_TEXT_BENCH` output (`dimna_text_bench.txt`). Timings change from run
to run by tens of per cent.
