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
4. **Binary packages and a distribution-agnostic source build** (decided with the owner,
   2026-11-14, replacing "one install script for every distribution": a script that adapts
   to each distribution's package manager, groups, SELinux and file locations has a branch
   per difference, none of them testable here, and it cannot uninstall cleanly).
   - **`.deb` and `.rpm`** holding the **same** glibc 2.34 binaries `zig build release`
     makes; only the wrapper differs. They declare the runtime libraries as dependencies
     (so apt or dnf installs them) and install, in the standard places:
     - the binaries in `/usr/bin`;
     - the board's udev rule, moved into the repo as `packaging/60-dimna-ft60x.rules`
       (the product IDs in the rig's `/etc/udev/rules.d/60-open-ephys-ft600.rules`), into
       `/usr/lib/udev/rules.d/`, reloaded and triggered after install. Each line is
       `GROUP="dimna", MODE="0660", TAG+="uaccess"` (decided with the owner, 2026-11-14;
       the rig's own rule has `MODE="0666"`, which lets every account open the board).
       uaccess gives the board to whoever has the active session at the machine, which
       includes programs started over SSH or a VNC that shares that desktop; the `dimna`
       group (a system group the package creates if missing) gives it to its members with
       nobody logged in, e.g. remotely after a reboot. The package never adds anyone to
       the group; it says how (`usermod -aG dimna $USER`);
     - real-time limits in `/etc/security/limits.d/` for a `realtime` group (rtprio 80,
       memlock unlimited, as on the rig), created as a system group if missing. The
       package never adds a user to a group: it says how (`usermod -aG realtime $USER`,
       then log out and in), in the package description and in `docs/install.md`;
     - the desktop entry and icons under `/usr/share`, pointing at `/usr/bin/dimna`.
     - Both are described once, in `packaging/nfpm.yaml` (nfpm writes `.deb` and `.rpm`
       from one file). Dependencies are package names, so they are written per format and
       must allow for renames: Debian 13 and Ubuntu 24.04 call ALSA's library
       `libasound2t64`, older releases `libasound2`, so the `.deb` depends on
       `libasound2 | libasound2t64`; check every other name the same way.
     - **Built and tested by GitHub Actions, not on the rig** (decided with the owner,
       2026-11-14). See "Release workflow" below.
     - Downloads from the GitHub release page at first. An apt/dnf repository (or a PPA
       or COPR) for updates comes later, once other labs use dimna.
   - **Building from source, any distribution**: a section in `docs/install.md` and
     README: download Zig 0.17.1 from ziglang.org (self-contained, unpacks anywhere, no
     root; several versions can sit side by side), install the `-dev` libraries (package
     names for Debian/Ubuntu, Fedora/RHEL, openSUSE, Void, Gentoo), `zig build
     --release=safe`. Optionally `packaging/get-zig.sh`: reads `minimum_zig_version` from
     `build.zig.zon`, downloads that Zig, checks its minisign signature, unpacks it into
     `~/.local/opt`. An agent writes and reads it but does not run the download.
   - **Tarball helper** (`packaging/install-user.sh`, POSIX sh, replacing
     `install-desktop.sh` and `dimna-launch.sh` in the tarball): installs the desktop entry
     and icons for the current user without root, pointing at the unpacked binaries, then
     **prints** the two root steps (udev rule, real-time limits) for the user to run rather
     than running them. Ends with checks: the board's device node is accessible (if plugged
     in), `ulimit -r` and `ulimit -l`, the Noto CJK SC and Noto Arabic fonts (optional; say
     which languages need them), and that a Wayland session is running. It never writes to
     the board.
5. **Source packages, as recipes around the same build**: an AUR `PKGBUILD` first (the
   owner's distro), then, only if someone asks, a Gentoo ebuild (`zig.eclass`, `ZIG_SLOT`
   0.17 or `dev-lang/zig-bin`) and a Void template. Each runs the vendored build; none needs
   network access during the build beyond Zig's package cache (`build.zig.zon`
   dependencies: zig-wayland, vulkan-zig, given there as `git+https` URLs; the recipes fetch
   the same commits as tarballs, Gentoo's via `ZBS_DEPENDENCIES`, and must show that Zig
   accepts their hashes, so an offline build works, as Gentoo and Void require).
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
- **Step 3** (a second agent, after 1 and 2 are merged): files you may change are
  `build.zig`, `packaging/` (new files only, e.g. a release script if `zig build release`
  cannot do all of it), `docs/install.md` and `README.md` (how to make and use a release).
  The system libraries are linked by name; for a target that is not the native one, Zig
  does not search the system's library and include folders by itself, so say how you
  give it them (and the .pc files pkg-config reads for FreeType and fontconfig). The
  musl build links against this machine's glibc-built libraries only to resolve symbols;
  find out whether that works at all, and if it does not, say so and what it would need
  (a Void musl root, say) rather than forcing it. dimna has no licence file yet: list it as
  missing in the tarball, do not write one. Evidence: `readelf -d` NEEDED of each binary
  (only the libraries in "Where it stands", plus libc/libm/ld-linux; never harfbuzz or
  fribidi), `objdump -T` showing no GLIBC_ version above 2.34, the binaries running here
  (`--help`, and `dimna-headless --sim --seconds 5 --no-audio` into a /tmp folder), and the
  tarball's file list. Do not run the GUI.
- **Steps 4 to 6**: after step 3, with the owner. Decided for step 4: the udev rule's
  access (`dimna` group, 0660, uaccess) and packages built with nfpm in GitHub Actions.
  An agent writes the workflow and `packaging/nfpm.yaml` and checks them locally as far as
  it can without downloads (`actionlint` if installed, YAML parsing, the file lists against
  the tarball's); it never pushes, tags or starts a workflow. The owner pushes; the first
  run's log is the evidence.

## Release workflow (`.github/workflows/release.yml`)

Runs on a pushed version tag (`v*`) and by hand (`workflow_dispatch`). Never touches a
board; there is none.

1. **Build** in a `rockylinux:9` container, so dimna is compiled against the oldest target's
   own headers and libraries (this removes step 3's caveat that Arch's headers could hide a
   function Rocky 9 lacks). Install the `-devel` packages and git; download Zig 0.17.1 and
   nfpm from their release pages, each checked against a sha256 written in the workflow;
   `zig build test`, then `zig build release` (its readelf/objdump CHECK must pass); nfpm
   makes the `.deb` and `.rpm` from the gnu binaries. Upload everything as artifacts.
   - Whether `zig build release`'s system-paths handling (written for Arch) finds Rocky's
     libraries and `.pc` files as it is, or needs a change in `build.zig`, is the first
     thing to find out; the fix goes in `build.zig`, not in workflow tricks.
   - The musl tarball is built in the same job, as now.
2. **Test**, a matrix of containers: `ubuntu:22.04`, `ubuntu:24.04`, `debian:12`,
   `debian:13`, `rockylinux:9`, `fedora:latest`. In each: install the package with apt or
   dnf (dependencies must resolve from that distribution's own repositories); `dimna
   --help` (every library loads); `dimna-headless --sim` for 5 s recording into a temporary
   folder, then check the recording is complete (the same check as step 3's report);
   check the udev rule, limits file, desktop entry and icons are where step 4 lists and the
   `dimna` group exists; remove the package and check the files are gone. Also the musl
   tarball's `dimna-headless --sim` in a Void musl container, if Void publishes one.
   No GPU or Wayland: the GUI is not run in CI.
3. **Release**: only when the build and every test pass, create a **draft** GitHub release
   for the tag with the tarballs, `.deb`, `.rpm` and a SHA256SUMS file. The owner reads
   it and publishes it; the workflow never publishes.

Rules for the workflow file: third-party actions pinned to a full commit SHA (with the
version in a comment); `permissions:` least needed (`contents: read`, and `contents:
write` only on the release job); no secrets beyond the built-in `GITHUB_TOKEN`. The
private repository's Actions quota (2,000 minutes a month on the free plan) is ample for
a run of perhaps 10–15 minutes.

## Testing

There are no containers on the rig (no podman, docker or distrobox), but `systemd-nspawn`
and `bwrap` are installed. Steps 1-3 are checked on the rig (identical generated bindings,
readelf/objdump, all tests). Installing and running the packages on other distributions is
done by the release workflow's test matrix, not on the rig. What CI cannot do is draw: a
windowed `--sim` run on another distribution (for example in a `systemd-nspawn`
container with the owner's Wayland socket bound in) needs downloads and root, so the owner
does it or approves it; an agent never does. Other compositors need a session the owner provides:
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

## Report: step 3

Branch `worktree-agent-ac562bc10d4caccec`; commit `4822e95` (the release build) and this
report. Files changed: `build.zig`, `README.md` (one Quick start entry), `docs/install.md`
(new section "Release build"), new `packaging/check-release.sh`. Nothing else; `vendor/` is
untouched.

**What `zig build release` does.** `build.zig` now builds the programs in one function,
`addPrograms(target, ...)`; the normal build calls it once for `-Dtarget`, the release step
once per release target (`x86_64-linux-gnu.2.34`, `x86_64-linux-musl`; ReleaseSafe; baseline
x86-64 CPU, since a query without a CPU is baseline). The wayland/vulkan bindings and the
shaders are shared. Per target it stages `dimna-<version>-<target>/` with `bin/dimna`,
`bin/dimna-headless`, `packaging/` (the whole folder), `README.md`, `licenses/` (liboni,
stb, zig-wayland, vulkan-zig, and a README that lists dimna's own licence as MISSING),
`BUILD-INFO` (version, target, zig version, a note on what the target needs), `COMMIT`
(`git describe --always --dirty`, or `unknown`) and `CHECK`. It installs that folder to
`zig-out/release/` and packs it with `tar` as `zig-out/release/dimna-<version>-<target>.tar.gz`.
`<version>` is `build.zig.zon`'s (`0.0.0`, hence `COMMIT`).

**How the cross build finds the system's files.** Zig searches no system folders for a
non-native target (a glibc version or musl makes it one): before the change, `zig build
-Dtarget=x86_64-linux-gnu.2.34` failed with `unable to find dynamic system library
"wayland-client" ... searched paths: none`. The release build gets the folders Zig would
search natively, from `std.zig.system.NativePaths.detect` on the host target (so Debian's
`/usr/lib/x86_64-linux-gnu` is included there), filtered to those that exist. Here that is
`-L /usr/local/lib -L /lib64 -L /lib -L /usr/lib64 -L /usr/lib`, and `/usr/include` (etc.)
as `-idirafter` on the GUI's translate-c, so Zig's own glibc 2.34 / musl headers come first.
pkg-config still runs for every target (the build runner calls it whatever the target), so
`-I/usr/include/freetype2 -I/usr/include/libpng16` and the `-l` names come from the
system's `.pc` files as before. Linking glibc 2.34 against Arch's libraries then failed with
11 `undefined reference` errors, all inside the system libraries (`__isoc23_strtol@GLIBC_2.38`
and similar, `sqrtf@GLIBC_2.43`; "referenced by /lib64/libasound.so", libvulkan,
libxkbcommon; "disallowed by --no-allow-shlib-undefined"). So the release GUI on glibc sets
`linker_allow_shlib_undefined`, and what dimna itself needs is checked afterwards.

**The check.** `packaging/check-release.sh MAX_GLIBC FILE...` runs in the build on both
binaries before staging; its stdout becomes `CHECK`. It fails if `readelf -d` NEEDED lists
anything outside wayland-client, vulkan, freetype, fontconfig, xkbcommon, asound, libm, libc
(`libc.so.6` or musl's `libc.so`) and ld-linux, or `objdump -T` shows a `GLIBC_` version
above 2.34. A failure stops that target's tarball.

**musl: works as far as can be checked here.** It first failed: liboni's
`onidriverloader.h` includes `<execinfo.h>` (glibc only; `'execinfo.h' file not found`), and
translate-c of `src/c.h` picked up the host's `/usr/include/execinfo.h` and choked on its
glibc macros. liboni uses nothing from it, so for musl the build puts an empty `execinfo.h`
first on liboni's and translate-c's include path (vendor/liboni unchanged). Then both link.
The musl `dimna` is dynamic (interpreter `/lib/ld-musl-x86_64.so.1`), linked against this
machine's glibc-built libraries only for their sonames; it links even without
`--allow-shlib-undefined` (lld apparently does not check libraries whose own NEEDED,
`libc.so.6`, is absent). It cannot run here (no musl loader) and has not been run anywhere;
that needs a musl system, e.g. a Void musl root in `systemd-nspawn`. The musl
`dimna-headless` is static and runs here, but cannot `dlopen`, so `--driver d3xx` is
unavailable with it (D3XX is a glibc binary anyway); `--driver usb` is built in. That is
inferred from musl's static `dlopen` being a stub, not run with any `--driver`.

**Evidence** (scratch under `/tmp/dimna-step3-471090`, removed at the end):
- Normal build unchanged: `zig build --release=safe` with the old and the new `build.zig`
  into two prefixes, same cache: `cmp` says both `dimna` and `dimna-headless` IDENTICAL.
  `zig build --help` differs only by the new line `release  Build the release tarballs
  (x86_64 glibc 2.34 and musl) into zig-out/release` (the step order is kept).
- `zig build test --summary all`: `22/22 steps succeeded; 273/275 tests passed (2 skipped)`
  (`run test 133 pass`, `gui-test 139 pass, 2 skip`, `shader-check 1 pass`), as before.
  `zig fmt --check src build.zig` printed nothing.
- `zig build release --prefix /tmp/...` from the commit: exit 0. `CHECK`:

      gnu:  dimna: NEEDED libwayland-client.so.0 libvulkan.so.1 libfreetype.so.6 libfontconfig.so.1 libxkbcommon.so.0 libasound.so.2 libm.so.6 libc.so.6 ld-linux-x86-64.so.2; highest GLIBC version: 2.34
            dimna-headless: NEEDED libc.so.6 ld-linux-x86-64.so.2; highest GLIBC version: 2.34
      musl: dimna: NEEDED libwayland-client.so.0 libvulkan.so.1 libfreetype.so.6 libfontconfig.so.1 libxkbcommon.so.0 libasound.so.2 libc.so; highest GLIBC version: none
            dimna-headless: NEEDED none (static); highest GLIBC version: none

  The same by hand (`readelf -d | grep NEEDED`; `objdump -T | grep -o 'GLIBC_[0-9.]*' |
  sort -uV | tail -1`): identical lists, `GLIBC_2.34` for both gnu binaries. The 2.34
  symbols are `__libc_start_main`, the pthread functions, `execveat` and
  `dlopen`/`dlsym`/`dlclose`/`dlerror` (moved into libc in 2.34). `COMMIT`: `4822e95ce32b`.
  Tarballs: gnu 4,820,891 bytes, sha256 `c744cfac...469e`; musl 5,141,275 bytes,
  `04406f51...a35a`. They are not reproducible: the file mtimes are build times.
- File list of each tarball (`tar -tvzf`; owner `0/0`; binaries and scripts `-rwxr-xr-x`),
  under `dimna-0.0.0-x86_64-linux-{gnu,musl}/`: `BUILD-INFO`, `COMMIT`, `CHECK`, `README.md`,
  `bin/dimna`, `bin/dimna-headless`, `licenses/` (`README`, `liboni.LICENSE`, `stb.LICENSE`,
  `vulkan-zig.LICENSE`, `zig-wayland.LICENSE`), `packaging/` (`check-release.sh`,
  `dimna-launch.sh`, `install-desktop.sh`, `icon/` with `ICON-CREDITS.md`,
  `dimna-{32,48,64,128,256}.png`, `dimna-icon.svg` and `candidates/` (3 svg and
  `contact-sheet.png`), `sim-config/dimna/config.toml`).
- Unpacked from the tarballs, `dimna-headless --sim 32,16 --seconds 5 --record /tmp/...`:
  gnu `150048 samples in 4689 blocks ... dropped=0 gaps=0 bad=0 ... CLEAN`, exit 0; musl
  `150016 samples in 4688 blocks ... dropped=0 gaps=0 bad=0 ... CLEAN`, exit 0.
  `tools/dimna_read.py` on each recording: `48 channels at 30000 Hz ... complete`, `gaps: 0,
  TTL edges: 26`, `OK`.
- gnu `dimna`: `ldd` resolves every NEEDED here; `ldd -r` (relocations only, no program code
  run) reports no undefined symbol.

**Broken on purpose, seen to fail:**
- `release_max_glibc = "2.33"`: `run sh failure`, `.../dimna: needs GLIBC_2.34, above 2.33`,
  the same for `dimna-headless`, exit 1, no gnu tarball.
- Linking HarfBuzz into the release GUI. With a plain `linkSystemLibrary("harfbuzz")` the
  check passed, rightly: the library is unused, lld drops it (as-needed) and NEEDED is
  unchanged. `.needed = true` alone did not change that, because the pkg-config path turns it
  into a plain `-lharfbuzz` (the build runner appends pkg-config's libs without the needed
  prefix). With `.needed = true, .use_pkg_config = .no`: `.../dimna: needs libharfbuzz.so.0,
  which a release must not link`, for gnu and for musl, exit 1.
- Without `linker_allow_shlib_undefined`: the gnu GUI link fails with the 11 errors above;
  the musl link succeeds.
- Without the `execinfo.h` stand-in (the first musl attempt): `'execinfo.h' file not found`.
- All reverted; the final build is from the commit.

**Unexpected, and open:**
- The plan's evidence command `dimna-headless --sim --seconds 5 --no-audio` does not fit the
  program: `--sim` takes a list (`32,16`), and dimna-headless has neither `--no-audio` (it
  plays no audio) nor `--help` (an unknown argument exits 2 before anything opens). I ran the
  command above instead.
- `dimna --help` was **not run**: the permission system refused to let me run the GUI
  binary, even with `--help` (which exits during argument parsing, before Wayland). `ldd -r`
  is the substitute, so none of the GUI's code has run from a release build.
- When one target's check fails, the other target's tarball is still installed (the build
  still exits 1). docs/install.md says so.
- The headers are this machine's (Arch, the newest library versions). A FreeType,
  fontconfig, xkbcommon or ALSA function newer than RHEL 9's would link here and fail to
  load there; nothing checks that. `ldd -r bin/dimna` in a target container would.
- `packaging/install-desktop.sh` and `dimna-launch.sh` in the tarball point at a checkout's
  `zig-out/bin`, so they do not work from an unpacked tarball (step 4's `install.sh`). The
  icon `candidates/` go in because the plan says "the packaging folder".

**Not covered:** running anything on another distribution (that needs downloads and root,
in the owner's `systemd-nspawn` plan); the musl GUI at all; `--driver d3xx` from either
release; the board (rules); reproducible tarballs; any architecture other than x86_64.
