# Plan: the program is renamed from oEZ to dimna

Read `docs/plans/README.md` first. A rename and nothing else: the program must behave
exactly as before under its new name.

## Why

The two acquisition programs are named after the two jackals of the Tales of Bidpai:
the Rust one (oers) becomes **kalila**, this one (oEZ) becomes **dimna**. The owner's
decisions: the names are lower case everywhere, also in titles and prose ("dimna", never
"Dimna" or "DIMNA", except environment variables, which are upper case by convention);
history is not rewritten.

## What changes

Every place the name is something a program, a file or a user depends on:

| what | from | to |
|---|---|---|
| binaries | `oez`, `oez-headless` | `dimna`, `dimna-headless` |
| package and module name (`build.zig.zon`, `build.zig`, `@import("oez")` and every `oez.` in the sources) | `oez` | `dimna` |
| config and state folders | `~/.config/oez`, `~/.local/state/oez` (and under `XDG_*`) | `.../dimna` |
| default recordings folder | `~/oez-recordings` | `~/dimna-recordings` |
| recording format name and software name in `meta.toml` | `format = "oez-recording"`, `oez 0.0.0` | `format = "dimna-recording"`, `dimna 0.0.0` |
| window titles and classes | "oEZ", "oEZ control", "oEZ spikes"; `oez`, `oez-control`, `oez-tiles` | "dimna", "dimna control", "dimna spikes"; `dimna`, `dimna-control`, `dimna-tiles` |
| environment variables | `OEZ_*` (all of them; `src/gui/env.zig` lists the GUI's, `src/ft600.zig` and `src/oni_usb.zig` have two more, three are read by tests) | `DIMNA_*` |
| the USB driver's name to liboni, its thread name | `oez-ft600-usb`, `oezusb` | `dimna-ft600-usb`, `dimnausb` (thread names are at most 15 bytes) |
| tools | `tools/oez_read.py`, `tools/oez_compare.py`, and the name inside every script | `tools/dimna_read.py`, `tools/dimna_compare.py` |
| packaging | `packaging/oez-launch.sh`, `packaging/icon/oez-*.png`, `oez-icon.svg`, `packaging/sim-config/oez/`, the desktop entry `oez.desktop` with `Name=oEZ`, `Icon=oez`, `StartupWMClass=oez` | `dimna-…` throughout |
| temporary folders in tests and scripts | `/tmp/oez-…` | `/tmp/dimna-…` |
| comments, log messages, usage text, the README, `docs/OPEN.md`, `docs/latency.md` | oEZ, oez | dimna |

Rename files with `git mv`, so history follows them.

## What does not change

- **Recordings must stay readable.** `tools/dimna_read.py` (and anything else that
  checks the format name) accepts both `oez-recording` and `dimna-recording`; a test
  reads a `meta.toml` of each. The format **version** does not change: nothing about the
  files does but that one string.
- **History.** `docs/readability-review.md`, `docs/review-as-claude.md` and the plans
  under `docs/plans/` describe the project as it was; do not rewrite them. Add one line
  at the top of each of the two reviews and of `docs/plans/README.md`: "The program
  was called oEZ when this was written; it is dimna now." (`docs/plans/README.md`'s
  build commands and rules are current instructions: update the names there.)
- **The other program.** Mentions of oers stay as they are in prose about history ("a
  port of oers's driver"), with "(now kalila)" added once in the README where it is
  first named. The checks that the board is free must look for both names of both
  programs: `tools/direct-test.sh` (if it still exists) and
  `tools/display-independence-test.sh` test for running `oers`, `kalila`, `oez`,
  `oez-headless`, `dimna`, `dimna-headless`.
- The vendored `vendor/liboni` (one mention there is a comment of ours about a driver
  search directory: leave the upstream code alone, change only our own words if any).
- `src/gui/testdata/*.txt` are generated: regenerate them (each test's environment
  variable, now `DIMNA_*_OUT`, writes the present output) and show that the diff against
  the old files is the name and nothing else.
- Old settings are **not** migrated by the program: no reading of `~/.config/oez`. The
  lead moves the owner's folders (below).

## How

Mechanically, in an order that keeps the tree building: the module name first (one
commit: `build.zig`, `build.zig.zon`, every `@import("oez")` and `oez.`); then the
binaries, folders, classes, titles and environment variables (one commit); then the file
renames in `tools/` and `packaging/` (one commit); then the docs (one commit). Use a
script for the substitutions and read every diff hunk: "oez" also occurs inside other
words nowhere in this tree today (check: `git grep -n -i "oez" | grep -v -i "\boez"`),
but verify before trusting a blanket replace. Case matters: `oEZ` -> `dimna`, `oez` ->
`dimna`, `OEZ_` -> `DIMNA_`.

## Evidence

- `zig build --release=safe` builds and installs `zig-out/bin/dimna` and
  `dimna-headless`, and no `oez*` binary.
- `zig build test --summary all`: the same counts as before, all passing.
- `zig-out/bin/dimna-headless --sim 32,16 --seconds 5 --record /tmp/<yours>`: CLEAN; the
  recording's `meta.toml` says `dimna-recording`; `python3 -I tools/dimna_read.py` reads
  it, and reads a recording made by the old binary before you started (make one first).
- `tools/crash-test.sh` passes.
- `git grep -n -i "oez"` afterwards: every remaining hit listed in your report with the
  reason it stays (history notes, the format name accepted for old recordings, the
  process names in the board-free checks).
- `zig fmt --check src build.zig` prints nothing; no new line over 140 characters.

You may not open windows (rule 2) or touch anything under the owner's home (rule 3): the
lead installs the launcher, moves the folders and updates the compositor's rules.

## Files you may change

Everything in the repository except `vendor/` (see above) and the two review documents
beyond their one-line note.

## For the lead, after merging (not for the agent)

- Reinstall the launcher (`packaging/install-desktop.sh ~/dimna-init/cfg` or wherever
  the config goes) and remove `~/.local/share/applications/oez.desktop` and the `oez`
  icons.
- Move `~/oez-init/cfg/oez` to the new config folder name, `~/.local/state/oez` to
  `~/.local/state/dimna`, `~/oez-recordings` to `~/dimna-recordings` (the `current` link
  inside it is absolute or relative: check), and tell the owner that the camera script's
  `--out-root` now points at `~/dimna-recordings/current`.
- The owner asked for existing recordings to carry the new format name: rewrite the
  `format = "oez-recording"` line of each `meta.toml` under the recordings folder to
  `dimna-recording` (nothing else in the file; keep the software line, which records
  what wrote it), with a copy of each original kept beside it until the owner has opened
  a few.
- Hyprland rules in `~/.config/hypr/custom.d/regular/rules.lua`: classes `oez`,
  `oez-control`, `oez-tiles` become `dimna`, `dimna-control`, `dimna-tiles`.
- Rename the GitHub repository and the working folder, with the owner.
