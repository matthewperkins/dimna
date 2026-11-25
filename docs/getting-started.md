# Getting started: building, the three windows, a first config

Installing a release on Linux is in [install.md](install.md); what differs between Linux
and macOS is in [platforms.md](platforms.md).

## Building and running

**Building from source**, on either system:

    zig build --release=safe                 # Zig 0.17.1
                                             # Linux: needs Wayland, Vulkan loader, FreeType, fontconfig, ALSA,
                                             # xkbcommon (development files); no glslc: shaders are checked in
                                             # optional at run time: harfbuzz and fribidi (Persian),
                                             # Noto Sans CJK SC (Chinese), Noto Sans Arabic or Vazirmatn
                                             # macOS: needs Apple's Command Line Tools only
    zig build test                           # about 280 tests, none needs a display or the board
    zig build -Dgui=false --release=safe     # dimna-headless only: no GUI libraries, no pkg-config

    zig-out/bin/dimna --sim 32,16            # simulated headstages, in a window
    zig-out/bin/dimna                        # the board; ~/.config/dimna/config.toml decides the rest
    zig-out/bin/dimna-headless --seconds 600 --record ~/somewhere    # soak test, no windows

    packaging/install-desktop.sh             # Linux: a launcher entry and icon for this checkout

    zig build release                        # Linux: tarballs for other distributions (glibc 2.34+, musl),
                                             # in zig-out/release; see docs/install.md, "Release build"

Press **`?`** on the display for every key and mouse action. `dimna --help` lists the
options. Only one program can hold the board at a time.

## The three windows

| window | what it is for |
|---|---|
| the neural display | the traces, in panels you lay out in the config; meant for a monitor of its own, fullscreen |
| the control window | Record, notes, audio, board settings and each panel's settings, in sections that open on a click |
| the spike tiles | one tile per electrode with its last spike waveforms, threshold, noise and rate |

Left click focuses a channel (amber, in both the tiles and the display); right click
listens to it (♪). Shift+wheel scrolls back in time, `l` returns to live.

## A minimal config

`~/.config/dimna/config.toml` (the same path on macOS):

    monitor = "DP-2"          # the display goes fullscreen there (macOS: "Built-in Retina Display")
    tearing = true            # lowest latency; on Linux it needs the compositor's cooperation
    scheme_image = "~/Pictures/lab.jpg"   # optional: take the GUI's colours from this picture
    language = "en"           # optional: en, de, fr, pt, pl, zh or fa (see Languages)

    [board]
    lower_hz = 0.1
    half_channels = "A1"      # a 16-channel headstage on an RHD2132

    [[panel]]
    name = "Port A"
    source = "A1"
    rect = [0.0, 0.0, 0.5, 1.0]
    band = [300, 6000]        # display only; the recording is always as acquired

What you change while running (scales, filters, thresholds, which sections are open) is
kept in `views.toml` beside it by "Save view"; the config itself is never rewritten except
for its `[board]` table, by "Save as default".

Panels, filters, triggered sweeps and the rest of the config are in
[display.md](display.md); the control window and saving in [control.md](control.md).

## Languages

The windows can show English, German (`de`), French (`fr`), Brazilian Portuguese (`pt`),
Polish (`pl`), Simplified Chinese (`zh`) or Persian (`fa`): set `language` in the config,
or leave it out to follow `LANG`. Only the windows' texts change: log messages, `--help`,
config keys and recordings stay in English.

- Nothing extra is needed for the Latin-script languages. Chinese needs a Chinese font
  (Noto Sans CJK SC). Persian needs an Arabic-script font (Noto Sans Arabic or
  Vazirmatn) and, to join its letters, HarfBuzz and FriBidi. These are loaded at run time
  only when needed, never linked. Without them dimna says what is missing and shows
  English. On macOS every language works with nothing installed: fonts, joining and
  right-to-left layout are Core Text's.
- In Persian the control window is mirrored and reads from the right. The neural display
  and the spike tiles keep their left-to-right layout, since that is the direction of time.
- The translations are drafts that native speakers have not yet reviewed. Each language's
  notes for a reviewer are in [translations/](translations/), and corrections are welcome. The
  messages are in `src/gui/lang/<code>.zig`.

More in [display.md](display.md), "Language".

## Recordings

One session per press of Record, under `~/dimna-recordings/<date_time>/ephys/`, with
`~/dimna-recordings/current` pointing at the newest so other programs (a camera recorder)
can write beside it. Raw int16 samples, TTL edges, typed notes and a text `meta.toml`.
`tools/dimna_read.py` is the reference reader and verifies every chunk.

The layout and the format are in [recording.md](recording.md).
