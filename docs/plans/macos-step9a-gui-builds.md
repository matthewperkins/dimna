# Plan: the GUI's code builds and its tests pass on macOS, without a window (macOS port, step 9a)

Read `docs/plans/README.md` first, then `docs/plans/macos-port.md` (the overview: the
decisions, "What Zig 0.17.1's standard library does on macOS", "The layout aimed at",
"Steps done"). Steps 1 to 7 are done: the core runs on the Mac, and on Linux every part
of the GUI that differs by system sits behind a file that chooses its backend at compile
time (`gpu.zig`, `window.zig`, `fontfind.zig`; the audio output through `render`).

This step fills in the Mac's side of everything that needs **no window**: the build, font
lookup (Core Text), the audio device (Core Audio), and stand-ins for the window and the
GPU so that the rest of the GUI compiles and its tests run. The window (AppKit) and the
renderer (Metal) are the next step. On Linux nothing may change.

## Where you work

On the owner's Mac (Apple silicon, macOS 27), in the git worktree you are given, on its
own branch off `macos-port`. Zig 0.17.1 is `~/.local/opt/zig-aarch64-macos-0.17.1/zig`
(not on `PATH`). No board (nothing may enumerate, open or talk to USB devices). **No
windows:** nothing you run may create a window, and `zig-out/bin/dimna` is run only with
`--help`, a bad argument, or `--print-scheme` (which open none). **No sound:** the one
test that opens the audio device plays silence and is off unless an environment variable
turns it on. Temporary files: `T=$(mktemp -d /private/tmp/dimna-s9a-XXXXXX)`, and before
any `rm -rf`: `set -u`, the variable quoted, a `case` check on that prefix. No `sudo`, no
installing (no `brew install`): Homebrew is there (`/opt/homebrew`, with `pkg-config`,
FreeType and fontconfig already installed; see what else is), and what is missing is
reported, not installed. No SSH. Do not rewrite history (no reset, amend or rebase, also
of your own commits); a pure `git mv` gets a commit of its own.

## What to build

1. **The build for macOS with the GUI** (`build.zig`). Today a macOS target with the GUI
   fails at once with a message. Now it builds `dimna` and `gui-test`: no Wayland scanner,
   no Vulkan binding, no SPIR-V, no fontconfig, xkbcommon or ALSA. FreeType comes from
   `pkg-config` (Homebrew's, for now: where the Mac's FreeType, HarfBuzz and FriBidi
   should come from in a packaged app is the packaging step's question; say what a user
   must have installed). The system frameworks this step uses are linked for macOS only.
   `src/gui/c.h` is what the build translates for the GUI's C libraries; give macOS its
   own header (or guard the includes), so Linux's translation is byte for byte what it
   was. If translating an Apple framework header fails or drags in thousands of
   declarations, declare the few functions used as `extern` in Zig instead and say so.
2. **`src/gui/fontfind_coretext.zig`**: the three lookups of `fontfind.zig`, with Core
   Text (a C API: no Objective-C is needed). The header of `fontfind.zig` lists the
   patterns the program asks for and what "no such font" means for each; the Mac must
   answer each of them with a file FreeType can open and the face's index in it:
   - `sans-serif` (the default `font`), `monospace`, a family name the user gave;
   - `sans-serif:charset=<hex>`: a font that has that code point;
   - the named fallbacks for Chinese and Persian. Their family names are Linux's today
     (`shape.zig`: Noto Sans CJK SC, Vazirmatn, Noto Sans Arabic). The Mac ships other
     families for those scripts: make the list per system, Linux's unchanged, and choose
     the Mac's from what macOS installs by default (say which and why);
   - `anyFontHas`.
   Many system fonts are collections (`.ttc`), and Core Text gives a file and a name, not
   an index: finding the index is yours to solve and to test. Some system fonts cannot be
   opened by FreeType at all or are not files; say what you found and what the lookup
   does then.
3. **The HarfBuzz and FriBidi names for macOS** in `shape.zig`'s lists (what Homebrew
   installs, by full path and by name). If they are not installed here, the shaping tests
   skip, as on a Linux machine without them: say whether they ran.
4. **`src/gui/audio_coreaudio.zig`**: the audio device, chosen at compile time where
   `audio_alsa.zig` is chosen now. The default output device through Core Audio's C API;
   its callback calls `AudioOut.render` and nothing else that could block, allocate, lock
   or log. `fs_out` is the device's rate, known before the feeder starts; the buffer size
   asked for is the `audio_period` setting (default 128 frames); `max_request` is the
   largest request the device can make; `device_delay` is what the device reports as its
   latency (its latency, its safety offset and its buffer; say exactly which properties),
   so the read-out means what it means on Linux. `PIPEWIRE_LATENCY` has no meaning on the
   Mac: it must not be set there. If the device cannot be opened, there is no sound and a
   warning, as on Linux.
   Its test: skipped unless `DIMNA_TEST_AUDIO=1`; then it opens the device, lets it pull
   silence for half a second (the queue is empty and the monitor is not active, so
   nothing is heard), and checks that frames were asked for at about the device's rate,
   that `max_request` covered every request, and that stopping it leaves nothing running.
   Run it once with the variable set, and say what the device, rate, buffer and reported
   latency were.
5. **Stand-ins for the window and the GPU** (`src/gui/window_appkit.zig`,
   `src/gui/gpu_metal.zig`), chosen for `.macos`: just enough for the callers to compile
   and for every test that does not need a real window or GPU to run. Making a window or
   a GPU fails with an error that says they are not ported yet, so `dimna` on the Mac
   starts, reads its config, and exits with status 1 and that message, having opened
   nothing. Keep them small: the next step replaces them.
6. **`src/gui/tests.zig`**: every test that runs on Linux and does not depend on Linux
   runs on the Mac. For each test that is skipped or cannot run on macOS, say why. The
   stored outputs (`src/gui/testdata/*.txt`) must match on the Mac as they are: they are
   what the display, the control window and the tiles draw, as text, and the code that
   makes them is shared.
7. **`docs/install.md`**, the macOS section: what now builds, what a build needs.

## Linux must not change

No statement in a Linux backend changes. The shared files change only where a backend is
chosen (a new arm in a `switch`) or a per-system list gains the Mac's entries. You cannot
build the Linux GUI on the Mac (it needs Linux's libraries); `zig build -Dgui=false
-Dtarget=x86_64-linux-gnu --release=safe` before and after must give the same headless
binary (`cmp`), and `git diff` over the Linux backends must be empty. The lead builds and
compares the Linux GUI on the rig before this is merged.

## Evidence

1. `zig build test --summary all` on the Mac (GUI included): the counts, and the names of
   the tests run by `gui-test` set against the list from Linux (the lead's last run there:
   147 passed, 2 skipped of 149; get the names by running the binary) with every
   difference explained.
2. `zig build --release=safe`: `dimna` links; `otool -L zig-out/bin/dimna` (what it needs
   at run time); `dimna --help` exit 0 and its text equal to Linux's apart from what is
   system-specific (say what); a bad argument exit 2; plain `dimna --sim 32,16` exits 1
   with the not-ported message and opens nothing.
3. The font lookups, by a small test or program: for each pattern above, the file and
   index found, and that FreeType opens it and has the code point asked for.
4. The audio test's output with `DIMNA_TEST_AUDIO=1`.
5. `dimna-headless --sim 32,16 --seconds 10 --record <tmp>` still `CLEAN`, and
   `zig build test -Dgui=false --summary all` as before (139 of 140, 1 skipped).
6. The Linux checks above; `zig fmt --check src build.zig`.

Break it on purpose, once each: the collection index off by one (which check notices);
the Core Audio callback not calling `render` (the audio test fails); a stored GUI output
changed by one character (the Mac's `gui-test` fails, which shows those tests really run
here).

## Files you may change

`build.zig`; `src/gui/c.h` and a new header beside it; `src/gui/fontfind.zig` (the
choice), new `src/gui/fontfind_coretext.zig`; `src/gui/shape.zig` (the library lists and
the fallback families' list only); `src/gui/audio_out.zig` (the choice of device file
only), new `src/gui/audio_coreaudio.zig`; `src/gui/gpu.zig` and `src/gui/window.zig` (the
choice only), new `src/gui/gpu_metal.zig` and `src/gui/window_appkit.zig`;
`src/gui/main.zig` (only where it sets `PIPEWIRE_LATENCY`); `src/gui/tests.zig`;
`docs/install.md`. A test or a line in another file that assumes Linux: do not edit it;
list it. Anything else: stop and report.

## Done means

The evidence and the break-it results are in your report; what a Mac needs installed to
build and to run; every test skipped on macOS and why; the work committed on your branch,
not pushed; the worktree clean; your temporary folder gone.
