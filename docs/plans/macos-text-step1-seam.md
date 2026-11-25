# Plan: the text seam, with no change in behaviour (Core Text, step 1)

Read `docs/plans/README.md` first, then `docs/plans/macos-coretext-text.md` (the overview:
why, what is policy, "The seam aimed at", the owner's decisions), then the headers of
`src/gui/font.zig`, `src/gui/shape.zig` and `src/gui/fontfind.zig`.

Today the FreeType, HarfBuzz and FriBidi calls are mixed into `font.zig` and `shape.zig`
with the policy. This step moves every such call behind one interface, so that a second
backend (Core Text, step 3, another agent) can be written without touching the policy.
**Nothing may change in what is drawn, on Linux or on macOS.** It is a move, not a
rewrite (README rule 8).

## Where you work

On the owner's Mac, in the git worktree you are given, on its own branch off `main`.
Zig 0.17.1 is `~/.local/opt/zig-aarch64-macos-0.17.1/zig` (not on `PATH`). The Mac builds
and tests the macOS side (FreeType is `vendor/freetype`; HarfBuzz and FriBidi are in
Homebrew here, so the shaping tests run).

The Linux side is built and tested on the rig over SSH (`ssh gb_ts 'sh -s' <<'EOF2'`; its
login shell is fish, so always `sh -s`). To get your branch there without GitHub:

    git push gb_ts:oEZ/oez HEAD:refs/heads/text-seam        # from your worktree; -f only for this branch
    # on the rig, once:  W=$(mktemp -d /tmp/dimna-text-XXXXXX); cd ~/oEZ/oez && git worktree add "$W/w" text-seam
    # later:             cd "$W/w" && git merge --ff-only text-seam   (or reset your temp worktree to it)

Rules on the rig, not negotiable: never run `dimna` or `dimna-headless` without `--sim`;
open no window (run no `zig-out/bin/dimna` at all: tests and `zig build` only); start builds
and tests with `chrt -o 0`; temporary files only under your `mktemp -d /tmp/dimna-text-XXXXXX`
folder, removed at the end with `set -u`, the variable quoted and a `case` check on that
prefix before any `rm -rf`; touch no other worktree or branch there (`~/oEZ/oez` is the
owner's checkout, `~/oEZ/dimna-macos-port` and the branch `smooth-scroll` are someone
else's work), and remove your worktree and the `text-seam` branch there when done. No
`sudo`, nothing installed, on either machine. On the Mac: open no window, play nothing, no
USB. Do not push to GitHub. Do not rewrite history.

## What to build

1. **`src/gui/text_backend.zig`**: the choice of backend at compile time and the
   statement of what a backend must do, as `gpu.zig`, `window.zig` and `usb.zig` are
   written. For now both systems choose `text_freetype.zig`.
2. **`src/gui/text_freetype.zig`**: every call into FreeType, HarfBuzz and FriBidi that
   `font.zig` and `shape.zig` make today, and the run-time loading of the two libraries.
   After this step `font.zig` and `shape.zig` import neither `gui_c` nor declare any
   `FT_`, `hb_` or `fribidi_` name; a test (like the one at the end of `ft600.zig` for
   control transfers) fails if they do.
3. The interface, in dimna's terms and nothing of the libraries': a face (opened for a
   `fontfind` pattern or a file and index, at a pixel size; ascent, line height, capital
   height or alef height, units for the scaling `shape.zig` does; has it a code point;
   the glyph id of a code point), a glyph's coverage (for a face and glyph id: an 8-bit
   bitmap with bearings and advance, written into the atlas where the shared code says),
   a run shaped (code points of one face and direction -> glyph ids, offsets, advances),
   bidi (types, levels, visual order: whatever `shape.zig` asks of FriBidi today), and
   "is shaping available". Design it from what the callers need; keep it as small as it
   can be. Core Text lays out a whole line at once (bidi and shaping together): do not
   design for that here, but do not make the policy depend on having bidi levels
   separately more than it does today, and say in your report where it does.
4. `fontfind.zig` and its two backends stay as they are (the Core Text one's use of
   FreeType to find a face's index moves behind the interface only if that is a pure
   move; otherwise leave it and say so).

## Evidence

1. **The same pixels, Linux** (the rig). Before any change, write a test-only dump (in
   the test binary, off unless an environment variable names an output file): for a fixed
   list of strings in the seven languages (take them from `src/gui/lang/*.zig`, plus the
   strings the shaping tests use, plus fixed-width text), at 14 and 24 px, the vertex
   lists `Batch.text`/`textMono`/`label` produce and a hash of the atlas afterwards. Run
   it before and after: the files are identical (`cmp`). Say which fonts and whether
   HarfBuzz and FriBidi were found on the rig; if a language's font is missing there, say
   so (then that language is covered on the Mac only).
2. **The same pixels, macOS**: the same dump on the Mac, before and after, identical.
3. `zig build test --summary all` on both, counts before and after equal (Mac today: 325
   of 341, 16 skipped; rig: 285 of 287), the 27 text tests among them, none edited except
   to follow a moved name.
4. The text benchmark (`DIMNA_TEXT_BENCH=1 zig build test --release=safe`, see
   `shape.zig`) on both machines, three runs each before and after: the figures.
5. `zig fmt --check src build.zig`; `zig build --release=safe` on both; on the rig the
   release tarball check `sh packaging/ci-test-install.sh tarball zig-out/release/*gnu.tar.gz`
   after `zig build release`.
6. The Linux `dimna` binary's `.text` and `.rodata` sizes before and after (they will
   differ; say by how much).

Break it on purpose, once each, and say which check notices: a glyph's left bearing off
by one in the backend; the visual order of two runs swapped; an `FT_` call left in
`shape.zig`.

## Files you may change

`src/gui/font.zig`, `src/gui/shape.zig`, new `src/gui/text_backend.zig` and
`src/gui/text_freetype.zig`, `src/gui/tests.zig` (to add the new files' tests),
`src/gui/fontfind_coretext.zig` (only as item 4 allows), `build.zig` (only if a module
needs the new files named). Anything else: stop and report.

## Done means

The evidence and the break-it results in your report; the interface as built, with the
reason for each thing in it; every place the policy still knows something of how the
backend works; what the Core Text agent must know; the work committed on your branch in
your worktree, not pushed to GitHub; your rig worktree, the `text-seam` branch there and
your temporary folders removed.
