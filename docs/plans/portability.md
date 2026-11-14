# Plan: dimna on other Linux distributions and Wayland compositors

The translations have landed (`i18n-catalogue.md`, `text-engine.md`, `translations.md`,
`rtl-control.md`). HarfBuzz and FriBidi are **not** link dependencies: `src/gui/shape.zig`
opens them with dlopen the first time a string needs shaping (Persian), and dimna draws
unshaped text if they are missing. Keep it that way.

Read `docs/plans/README.md` first; its rules apply. Nothing here changes acquisition,
recording or the display's behaviour; it changes how dimna is built, shipped and set up.

## Goal

Someone on Debian, Ubuntu, Fedora, openSUSE, Gentoo, Void (glibc and musl) or Arch, on any
Wayland compositor, can install dimna and record without a headache, and build it from
source without hunting for distro-specific files. No X11, no Snap, no Flatpak: their
sandboxes fight what an acquisition program needs (raw USB to the board, SCHED_FIFO and
locked memory, recordings written anywhere, and with Flatpak an NVIDIA runtime that must
match the host driver).

## Where it stands (2026-11-14, on the owner's Arch/Hyprland rig)

- Runtime libraries linked (`readelf -d zig-out/bin/dimna`, NEEDED): wayland-client,
  vulkan (loader), freetype, fontconfig, xkbcommon, asound, m, c. All are on any Wayland
  desktop with stable ABIs. Loaded only if present: libharfbuzz.so.0, libfribidi.so.0
  (Persian). Fonts, optional per language: Noto Sans CJK SC (Chinese), Noto Sans Arabic
  or Vazirmatn (Persian); dimna falls back to English without them.
- Build-time files from the system: Wayland protocol XMLs (`build.zig`: xdg-shell,
  presentation-time, pointer-gestures, tablet-v2 from stable/unstable; tearing-control,
  content-type, cursor-shape from **staging**, too new for Debian 12 / Ubuntu 22.04's
  wayland-protocols), and `vk.xml` at `/usr/share/vulkan/registry/vk.xml` (a different
  package and path on Debian-family systems; there is a `-Dvk-registry` option). glslc
  (shaderc) compiles the shaders. Zig 0.17.1 is pinned and is not in most distros.
- Machine setup: `docs/install.md` (udev rule for the FT60x IDs, rtprio and memlock via
  the `realtime` group). The board's udev rule today lives in `/etc/udev/rules.d/` on the
  rig (`60-open-ephys-ft600.rules`), not in the repo's packaging.
- Desktop entry and icon: `packaging/install-desktop.sh` (points at a checkout).

## Steps

1. **Vendor the build inputs** into `vendor/wayland-protocols/` (only the XMLs used) and
   `vendor/vulkan/vk.xml`, each with a README giving source, version and sha256, as
   `vendor/stb/` does. `build.zig` uses them by default (the `-Dvk-registry` option
   stays, as an override). Prove: the generated Zig bindings are identical before and
   after (diff the generated files in the cache), and the stored display outputs and
   all tests are unchanged.
2. **Shaders prebuilt and checked in** (`src/gui/shaders/*.spv`), with a build step that
   rebuilds them only when glslc is present and the source is newer, and a test that the
   checked-in .spv matches what glslc produces when glslc is there. Then glslc is needed
   only by someone changing shaders.
3. **A release build**: `zig build release` producing `dimna-<version>-x86_64-linux-gnu`
   built for glibc 2.34 (`-Dtarget=x86_64-linux-gnu.2.34`: Rocky/Alma/RHEL 9, which labs
   run; Ubuntu 22.04, Debian 12 and everything newer)
   and `-x86_64-linux-musl` for Void musl. Check each with `readelf -d` (only the
   libraries listed above are NEEDED) and `objdump -T` (no GLIBC symbol version above
   2.34). A tarball holds the binaries, `dimna-headless`, the packaging folder, the
   licence files (stb, liboni, dimna's own once it has one: an open item) and README.
4. **One install script** (`packaging/install.sh`, POSIX sh), idempotent, saying what it
   does before it does it and asking before anything needs root:
   - the udev rule for the board, moved into the repo (`packaging/60-dimna-ft60x.rules`,
     the IDs in the rig's rule), installed to `/etc/udev/rules.d/` and reloaded;
   - real-time limits: `/etc/security/limits.d/` for a `realtime`-style group (or the
     distro's existing one: Arch `realtime`, Debian `audio` has rtprio by default with
     jackd), adding the user to it; explain logging out and in;
   - the desktop entry and icons (what `install-desktop.sh` does, pointed at the
     installed binary, not a checkout);
   - checks at the end: the board's device node is accessible (if plugged in), `ulimit -r`
     and `ulimit -l`, the Noto CJK SC and Noto Arabic fonts (optional; say which languages
     need them), and that a Wayland session is running. It never writes to the board.
5. **Packages, as recipes around the same build**: an AUR `PKGBUILD` first (the owner's
   distro), then, only if someone asks, a Gentoo ebuild and a Void template. Each runs
   the vendored build; none needs network access during the build beyond Zig's package
   cache (`build.zig.zon` dependencies: zig-wayland, vulkan-zig; vendor or pre-fetch them
   so an offline build works, as Gentoo and Void require).
6. **Compositors**: a section in `docs/install.md` with what works where, and window
   placement recipes for the control and tile windows by app ID (`dimna`,
   `dimna-control`, `dimna-tiles`):
   - Hyprland (as on the rig), KDE Plasma 6 (KWin window rules; "allow tearing in full
     screen"), Sway and other wlroots compositors (labwc, Wayfire; XFCE's Wayland session
     is labwc), niri (window rules; check whether it supports tearing-control and say so
     only once checked), GNOME (no tearing-control: frames wait for the refresh, about one
     frame of latency, which the display's latency read-out shows; no per-app placement
     without an extension; and no server-side decorations, so dimna's windows have no
     title bars there).
   - dimna should say at startup, once, in the log and on the display's banner, when the
     compositor lacks tearing-control or presentation-time, and what that costs.
   Only claims checked on a real session go in; the rest are marked "not yet tried".

## Who does what

- **Steps 1 and 2** (one agent, first): files you may change are `build.zig`,
  `vendor/wayland-protocols/` and `vendor/vulkan/` (new), `src/gui/shaders/` (the .spv
  files and nothing else there), `README.md` (the build section) and `docs/install.md`
  (what a build needs). Copy the protocol XMLs and `vk.xml` from this machine's
  `/usr/share/wayland-protocols` (wayland-protocols 1.50) and
  `/usr/share/vulkan/registry/vk.xml` (vulkan-headers 1.4.363); no downloads. Record each
  file's sha256 and the package version in the folder's README. For the shaders, find
  where `build.zig` runs glslc and how the .spv files are embedded (`--dep
  traces.vert.spv` and so on). Prove "identical" by diffing the generated `wayland.zig`
  and `vk.zig` from the cache, before and after, and the .spv files glslc writes against
  the checked-in ones; and show a build with glslc hidden from PATH (for example a PATH
  without `/usr/bin/glslc`: make a temporary folder of symlinks to what the build needs, or
  run with `bwrap` binding an empty file over glslc) succeeding.
- **Step 3** (a second agent, after 1 and 2 are merged).
- **Steps 4 to 6**: after step 3, with the owner.

## Testing

There are no containers on the rig (no podman, docker or distrobox), but `systemd-nspawn`
and `bwrap` are installed. Steps 1-3 are checked on the rig (identical generated bindings,
readelf/objdump, all tests). The release binary can then be run on other distributions in
`systemd-nspawn` containers made from their published root filesystem images (Debian 12,
Ubuntu 22.04, Rocky 9, Fedora, openSUSE, Void musl), with the owner's Wayland socket bound
in for a windowed `--sim` run. That needs downloads and root, so the owner does it or
approves it; an agent never does. Other compositors need a session the owner provides:
list per distro and compositor what was actually run and what was not. Never run the GUI
against the board on someone else's machine without its owner present.

## Not in this plan

X11, Snap, Flatpak, AppImage (it would bundle libraries that must match the host:
Vulkan loader and GPU driver), Windows, macOS.

## Report: steps 1 and 2

Branch `worktree-agent-a775a4ad51bc76aef`; commits `af0f2cc` (vendoring, with all of the
`build.zig` change, shaders included), `b9a84fd` (the four `.spv` files), and this report.
Files changed: `build.zig`, `README.md`, `docs/install.md`, new `vendor/wayland-protocols/`
(7 protocol XMLs + `wayland.xml` + README), `vendor/vulkan/` (`vk.xml` + README),
`src/gui/shaders/*.spv` (4 new). Nothing else.

**Step 1.** `Scanner.create` now gets `.wayland_xml` and `.wayland_protocols` pointing into
`vendor/wayland-protocols` (same layout as `/usr/share/wayland-protocols`, so the
`addSystemProtocol` lines are unchanged). `wayland.xml` (core protocol, wayland 1.26.0) is
vendored too, because otherwise the scanner asks pkg-config for wayland-scanner. `vk.xml`
defaults to `vendor/vulkan/vk.xml`; `-Dvk-registry` remains. Versions and sha256 are in
each folder's README (wayland-protocols 1.50, vulkan-headers 1:1.4.363.0).

**Step 2.** The four `.spv` are checked in, made with this machine's glslc and the exact
old command line. `build.zig` finds glslc at configure time (`b.findProgram`). If it is
there and a shader source's mtime is newer than its `.spv`, the freshly compiled file is
embedded; otherwise the checked-in file is. `zig build shaders` copies glslc's output over
the checked-in files. The test is generated by `build.zig` (a `WriteFile` source, module
`shader-check`, run by `zig build test`), because a test file under `src/gui` was outside
my file list; it compares checked-in against compiled bytes and skips without glslc.

**Evidence** (scratch under `/tmp/dimna-steps12-461880`, removed at the end):
- Before/after, separate cache dirs: `wayland.zig` sha256 `0dcb9656...b1c0` and `vk.zig`
  sha256 `2b580fed...ce70`, `cmp` says IDENTICAL for both. The four `.spv` I checked in are
  byte-for-byte what the old build step made (they were produced by the same command; the
  test confirms it against a fresh glslc run).
- The GUI binary built before and after differs in 87 bytes; the ones I looked at (29 in a
  same-cache rebuild) are the cache-hash path strings of the embedded files, not code.
- No glslc: `bwrap --dev-bind / / --ro-bind /dev/null /usr/bin/glslc`: `zig build test
  --summary all` succeeded, `run test 133 pass`, `gui-test 139 pass, 2 skip`, `shader-check
  0 pass, 1 skip`; `zig build --release=safe` produced `dimna` and `dimna-headless`.
- No system protocol or registry files: `bwrap` with empty tmpfs over
  `/usr/share/wayland-protocols`, `/usr/share/wayland`, `/usr/share/vulkan/registry`:
  release build succeeded and regenerated `wayland.zig`/`vk.zig` with the same sha256.
- Normal run, `zig build test --summary all` (fresh cache): 22/22 steps, 273/275 passed
  (2 skipped, as before), `shader-check 1 pass`. `zig build --release=safe` succeeded,
  `zig fmt --check src build.zig` printed nothing. `src/gui/testdata` untouched
  (`git status` shows no change there).

**Broken on purpose, seen to fail:**
- Added `0.5 *` to `text.frag` without regenerating: `shader-check 0 pass, 1 fail`, with
  "src/gui/shaders/text.frag.spv is stale: run `zig build shaders` and commit it". The same
  build embedded the freshly compiled shader (the binary differed by 1.5 MB of shifted
  bytes); reverted, a rebuild matched the original apart from path strings. (The gui-test
  step was also reported failed in that run; it passed on rerun after the revert and
  carries no shader test, so I took it as the build aborting, not a real failure.)
- Moved `vendor/vulkan/vk.xml` away: build fails, `FileNotFound .../vendor/vulkan/vk.xml`.
  Moved `xdg-shell.xml` away: same kind of failure. Both restored (sha256 checked).
- Appending an XML comment to the vendored `wayland.xml` left the generated bindings
  identical, as expected (so that was not a real break; the missing-file ones are).

**Notes and not covered:**
- The test needs the same glslc output as the one that made the files; another shaderc
  version could emit different bytes and fail it (fix: `zig build shaders` and commit).
  Only shaderc 2026.4 was tried.
- Fresh git checkouts give arbitrary mtimes, so a source may look newer than its `.spv`;
  with glslc present it is then recompiled (same bytes), without it the checked-in file is
  used. Both harmless.
- `b.findProgram` makes the build configuration uncacheable (it re-runs each time).
  `build.zig` still calls `pkg-config` for FreeType/fontconfig and still links system
  libraries; those are step 3 territory.
- `README.md` still says "180 tests" (stale, before my change; the count is 133 + 139 + 1);
  I left it.
- Not run: the GUI (rules), any non-Arch distribution, a different zig-wayland/vulkan-zig
  fetch (they come from the package cache; offline vendoring is step 5).
