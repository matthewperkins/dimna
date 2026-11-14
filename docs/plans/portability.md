# Plan: dimna on other Linux distributions and Wayland compositors

**Not before the translations land** (`i18n-catalogue.md`, `text-engine.md`, and the
translation and right-to-left plans after them): those add HarfBuzz and FriBidi, which
this plan must cover.

Read `docs/plans/README.md` first; its rules apply. Nothing here changes acquisition,
recording or the display's behaviour; it changes how dimna is built, shipped and set up.

## Goal

Someone on Debian, Ubuntu, Fedora, openSUSE, Gentoo, Void (glibc and musl) or Arch, on any
Wayland compositor, can install dimna and record without a headache, and build it from
source without hunting for distro-specific files. No X11, no Snap, no Flatpak: their
sandboxes fight what an acquisition program needs (raw USB to the board, SCHED_FIFO and
locked memory, recordings written anywhere, and with Flatpak an NVIDIA runtime that must
match the host driver).

## Where it stands (2026-11-13, on the owner's Arch/Hyprland rig)

- Runtime libraries, all dynamically linked: wayland-client, vulkan (loader), freetype2,
  fontconfig, xkbcommon, alsa; after the text engine, harfbuzz and fribidi. All are on
  any Wayland desktop with stable ABIs.
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
   built for glibc 2.31 (`-Dtarget=x86_64-linux-gnu.2.31`; Debian 11 / Ubuntu 20.04 era)
   and `-x86_64-linux-musl` for Void musl. Check each with `readelf -d` (only the
   libraries listed above are NEEDED) and `objdump -T` (no GLIBC symbol version above
   2.31). A tarball holds the binaries, `dimna-headless`, the packaging folder, the
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

## Testing

There are no containers on the rig (no podman, docker or distrobox). Steps 1-3 are
checked on the rig (identical generated bindings, readelf/objdump, all tests). Running
the release binary on other distros and compositors needs a VM or a machine the owner
provides: list per distro what was actually run and what was not. Never run the GUI
against the board on someone else's machine without its owner present.

## Not in this plan

X11, Snap, Flatpak, AppImage (it would bundle libraries that must match the host:
Vulkan loader and GPU driver), Windows, macOS.
