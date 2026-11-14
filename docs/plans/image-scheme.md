# Plan: a colour scheme taken from an image

Read `docs/plans/README.md` first; its rules apply. Display only: nothing here touches
acquisition, recording, the board or the feed.

## Goal

The config names an image; at startup dimna derives its GUI colours from it. Fast (a few
ms for a typical photo after decoding), light (no new Zig dependencies), stable (nothing
that tracks Zig master), and good-looking. No UI for it. Without the key, the GUI looks
exactly as it does today, bit for bit.

## Files you may change or add

`vendor/stb/` (new), `build.zig`, `src/gui/theme.zig`, `src/gui/scheme.zig` (new),
`src/gui/args.zig`, `src/gui/main.zig` (startup and the `--print-scheme` exit path only),
`src/gui/gpu.zig` (trace palette parameter), `src/gui/shaders/traces.vert` (palette),
`src/gui/display.zig` (only where it passes the palette to the trace parameters),
`src/gui/tests.zig` (registering new tests, if needed), `README.md`, `docs/display.md`.
Another agent is changing titles and layout in `display.zig` at the same time: keep your
edits there minimal so the two merge.

## Pieces

1. **Image decoding: stb_image**, vendored, not zigimg (zigimg follows Zig master and
   breaks; we are pinned to 0.17.1).
   - Download `stb_image.h` and `stb_image_write.h` from github.com/nothings/stb at a
     fixed commit (use the current master commit hash, fetched with the GitHub API or
     `git ls-remote`). Put them in a new folder of your own under `/tmp` first, look at
     them, then copy into `vendor/stb/`. Write `vendor/stb/README.md`: what they are,
     the commit, the sha256 of each file, the URL, and that dimna uses them only to read
     the scheme image (and to write the swatch, below). Copy the licence text (the
     public-domain / MIT notice at the bottom of stb_image.h) to `vendor/stb/LICENSE`.
   - One C file `vendor/stb/stb_impl.c` defines the implementations, with
     `STBI_ONLY_JPEG`, `STBI_ONLY_PNG`, `STBI_NO_STDIO` (Zig reads the file and calls
     `stbi_load_from_memory`, forcing 3 channels; refuse files over 64 MB), and
     `STBI_WRITE_NO_STDIO` with `stbi_write_png_to_func`. Compile it into the GUI with
     `addCSourceFile` (see how `build.zig` builds liboni) and translate the two headers
     with `b.addTranslateC` (no `@cImport` in 0.17.1).
   - Credit line in README.md beside where liboni is credited.
2. **theme.zig becomes runtime values without touching its call sites.** Change the
   themed colours from `pub const` to `pub var` with today's values as initialisers, so
   the 121 `theme.x` uses elsewhere stay as they are. Where one constant is defined from
   another (`note_text = focus`, `trigger_level = tile_threshold`, …), keep today's value
   as the initialiser and set it again in `apply`. Add the four trace colours here
   (`trace: [4][3]f32`, today's shader values) and have the shader take them from the
   trace parameters (push constants; check the size stays within 128 bytes, or use the
   existing uniform/storage path if it does not) instead of its constant `palette`. The
   off-scale amber and converter-limit red stay in the shader, fixed.
   These are **fixed, never themed** (they mean something): `text_warn`, `text_rec`,
   `alarm_bar`, `warning_bar`, `bar_text`, `alarm_hint_text`, `review_badge_text`,
   `tile_threshold`, `tile_threshold_text`, `trigger_level`, `note_*`, `tint_pulse`,
   `row_scale_text`, `focus`. Leave them `const`.
   Colours are set once at startup, before any window or thread draws, and never again.
3. **`src/gui/scheme.zig`: image → scheme**, pure Zig apart from the decode, unit-tested
   without files (feed it pixel arrays).
   - Shrink the image by box-averaging (in linear light, from sRGB) to at most 96×96;
     convert each cell to **Oklab**.
   - **k-means, k = 8**, k-means++ seeding with a fixed seed
     (`std.Random.DefaultPrng.init(0x5eed)`), at most 20 iterations or until no
     assignment changes. Each cluster: mean Oklab, weight (cell count). Same image, same
     scheme, always.
   - Work in OkLCh (lightness L, chroma C, hue h) for assigning roles:
     - **Base hue**: the hue of the heaviest cluster. Neutrals: chroma clamped low.
       `background` L 0.16, C ≤ 0.02 (the `[4]f32` fill; alpha 1); `label_backing` the
       same at alpha 200; `help_backing` L 0.18 alpha 245; `tile_bg` 0.19,
       `tile_bg_hover` 0.23, `heading_idle` 0.21, `heading_hover` 0.32, `button_idle`
       0.27, `button_hover` 0.34, `rule` and `panel_divider` 0.30, `sweep_cursor` 0.60
       (all C ≤ 0.03). `text_bright` and `help_title` L 0.93 C ≤ 0.02; `help_text` 0.80;
       `text_dim` 0.72; `tile_range_text` 0.62 (C ≤ 0.025).
     - **Trace colours (4)**: score clusters by `C * sqrt(weight)`; pick greedily the
       best one whose hue is ≥ 40° from every hue already picked; if fewer than 4,
       repeat with 25°, then fill the rest by rotating the first pick's hue by 90°
       steps. Clusters with C < 0.04 never count as picks. Keep the greedy order (row
       `ch & 3` uses them in order, so the strongest colour is on row 0 and neighbours
       differ). Set L into [0.74, 0.86] and C into [0.09, 0.17], then reduce C until the
       colour is inside sRGB.
     - **Accent** = the first trace pick's hue: `button_on` L 0.45, `button_on_hover`
       0.52, `help_key` 0.82, `target_bar` 0.60, C as the pick's clamped to [0.08,
       0.14], gamut-mapped; `tile_wave` = trace colour 0.
     - **Contrast guarantee** (WCAG relative-luminance ratio against `background`):
       `text_bright` ≥ 10, `text_dim` ≥ 4.5, every trace colour ≥ 6, `help_key` ≥ 6.
       Raise L in 0.01 steps until met. A test checks these on several synthetic
       images: one colour, greyscale, two hues, saturated rainbow, near-black, near-white.
   - Speed: report the time of decode and of clustering for a 12-megapixel JPEG and a
     1-megapixel PNG (make them yourself under /tmp, e.g. with ImageMagick if present,
     otherwise with `stbi_write_png`; delete them after).
4. **Config and command line.**
   - Top-level key `scheme_image = "<path>"` in the config (parsed in `args.zig` like
     `tearing`). `~/` expands to `$HOME`; a relative path is relative to the config
     file's folder.
   - At startup, before windows: load, derive, `theme.apply(scheme)`. Any failure (file
     missing, too big, not JPEG/PNG, decode error) logs one warning line naming the file
     and the reason, and the default theme is used. It must never stop the program.
   - `dimna --print-scheme <image> [--swatch <out.png>]`: prints the derived colours (name
     and `#rrggbb`, the cluster centres with weights, and the contrast ratios), writes a
     swatch PNG if asked (background with a row of each themed colour and four
     trace-coloured noise traces drawn over it, ~800×400, plain CPU drawing), and exits
     without opening a window or touching the board. This is how the result is judged:
     the owner and the reviewer look at swatches. Make one swatch each for three
     different real-looking images you can produce (e.g. ImageMagick's built-in
     `rose:`/`logo:`/`wizard:` if available, or `plasma:` gradients) and leave them in
     the report as paths under /tmp (do not delete those three until the reviewer says).
     This is the one exception to the README's /tmp clean-up rule.
5. **Docs**: `scheme_image` in README's config section and `docs/display.md` (what is
   themed, what is fixed and why, `--print-scheme`).

## Tests

- No `scheme_image`: the stored display output `src/gui/testdata/display_frame.txt` is
  unchanged (this is the proof that the default theme is bit for bit today's).
- scheme.zig: determinism (same pixels twice → same scheme), the contrast guarantees on
  the synthetic images, trace hues ≥ 25° apart when the image has ≥ 4 distinct hues,
  gamut (every output channel in 0..255 without clamping having been needed — check in
  the test by converting back), k-means on a two-colour image finds both colours.
- Config: missing file → default theme and the warning text; `~/` expansion.
- Break each test once on purpose (README rule).
- `zig build test --summary all`, `zig build --release=safe`, `zig fmt --check src build.zig`.
- You may run `zig-out/bin/dimna --print-scheme ...` (it opens no window). Run nothing
  else of the GUI.

## Report

Append a "Report" section here: what you vendored (commit, hashes), timings, the swatch
paths, test break-it results, anything you were unsure of in the role assignment.
