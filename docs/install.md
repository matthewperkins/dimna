# Installing and building dimna, reaching the board, and the headless tool

[Back to the README](../README.md)

## Installing a release

Releases are on the repository's GitHub release page: a `.deb`, an `.rpm`, two tarballs and
`SHA256SUMS`. They are made by the release workflow (`.github/workflows/release.yml`, below
under "Release build"), never by hand. All are x86_64 only.

| file | for |
|---|---|
| `dimna_<version>-1_amd64.deb` | Debian 12 and 13, Ubuntu 22.04 and 24.04, and newer |
| `dimna-<version>-1.x86_64.rpm` | Rocky, Alma and RHEL 9, Fedora |
| `dimna-<version>-x86_64-linux-gnu.tar.gz` | any other glibc distribution (glibc 2.34 or newer) |
| `dimna-<version>-x86_64-linux-musl.tar.gz` | Void musl (see "musl" below) |

Check a download with `sha256sum -c --ignore-missing SHA256SUMS`.

### The .deb or .rpm

    sudo apt install ./dimna_<version>-1_amd64.deb      # Debian, Ubuntu
    sudo dnf install ./dimna-<version>-1.x86_64.rpm     # Rocky, Alma, RHEL, Fedora

apt or dnf installs the libraries dimna needs from the distribution's own repositories (the
Wayland client library, the Vulkan loader, FreeType, fontconfig, xkbcommon, ALSA). The
package installs:

| where | what |
|---|---|
| `/usr/bin/dimna`, `/usr/bin/dimna-headless` | the programs |
| `/usr/lib/udev/rules.d/60-dimna-ft60x.rules` | the board's udev rule (below) |
| `/etc/security/limits.d/99-dimna-realtime.conf` | real-time priority 95 and unlimited locked memory for the `realtime` group |
| `/usr/share/applications/dimna.desktop`, `/usr/share/icons/hicolor/*/apps/dimna.*` | the menu entry (with a "simulated board" action) and the icon |
| `/usr/libexec/dimna/dimna-desktop-launch` | what the menu entry runs: `/usr/bin/dimna`, its output appended to `~/.local/state/dimna/dimna.log` |
| `/usr/share/dimna/` | the simulator action's config; `tools/dimna_read.py`, the reference reader |
| `/usr/share/doc/dimna/` | README, licences, the build's `BUILD-INFO`, `COMMIT` and `CHECK` |

After installing, it creates the system groups `dimna` and `realtime` if they are missing,
reloads udev's rules and re-applies them to USB devices of vendor 0403 (FTDI) only. It
**never adds anyone to a group**. Who may open the board, per the udev rule:

- whoever has the **active local session** (logged in at the machine), while it is active,
  including programs they start over SSH or a VNC that shares that desktop (udev's
  `uaccess`);
- members of the **`dimna` group**, at any time, also with nobody logged in at the machine
  (e.g. remotely after a reboot). The device node is root's, mode 0660; nobody else.

To record with real-time priority you must be in `realtime`; to reach the board without a
local session, in `dimna`. Add yourself to both, then **log out and in** (group membership
and limits are read at login):

    sudo usermod -aG dimna,realtime $USER

Then check, after logging in again: `ulimit -r` prints 95, `ulimit -l` prints `unlimited`.

An existing installation may still have `rtprio 80` in that file (the limit was 80 before
the acquisition thread asked for 90). Change that line to `@realtime - rtprio 95`
(`sudoedit /etc/security/limits.d/99-dimna-realtime.conf`), then log out and in. Until then
the acquisition thread runs at SCHED_FIFO 80, level with PipeWire's audio thread inside
dimna instead of above it, and says so in the log ("Run" below has why).
An older rule for the same board (an Open Ephys install's `/etc/udev/rules.d/*ft600*.rules`
with `MODE="0666"`) still applies alongside; remove it if only the `dimna` group should reach
the board.

Removing the package (`sudo apt purge dimna` or `sudo dnf remove dimna`) removes every file
above. The groups stay, with their members: other programs may use them.

### A tarball

Unpack it anywhere (no root) and run `bin/dimna` or `bin/dimna-headless`. The machine needs
the same libraries as above (not their development files). Then:

    dimna-<version>-x86_64-linux-gnu/packaging/install-user.sh

installs the menu entry and icon for you (`~/.local/share/applications/dimna.desktop`,
`~/.local/share/icons/hicolor`), pointing at this unpacked folder (move it and run the script
again). It does not use root: it **prints** the root steps for you to read and run (the two
groups, the udev rule into `/etc/udev/rules.d/`, the limits file into
`/etc/security/limits.d/`, `usermod`). It ends with checks, which
`install-user.sh --check` runs alone (exit status 1 if something needs doing):

- the board's device node is readable and writable by you, if the board is plugged in (found
  through `/sys/bus/usb/devices`, vendor 0403; the node is never opened);
- `ulimit -r` at least 95 (the acquisition thread asks for 90, above PipeWire's audio thread
  inside dimna, which asks for 88 and gets what the limit allows) and `ulimit -l` unlimited;
- the optional fonts: Noto Sans CJK SC, only for Chinese; Noto Sans Arabic or Vazirmatn,
  and HarfBuzz and FriBidi, only for Persian;
- a Wayland session (the windows need one; `dimna-headless` does not).

In a source checkout, `packaging/install-desktop.sh` does the menu entry for `zig-out/bin`
instead (it also takes a config folder: see the script).

## Building from source, any distribution

1. **Zig 0.17.1**, the version `build.zig.zon` pins. Most distributions do not package it;
   ziglang.org's build is self-contained and needs no root: download
   `zig-x86_64-linux-0.17.1.tar.xz` from https://ziglang.org/download/, check it (sha256 from
   that page, or its minisign signature), unpack it anywhere and put the folder on `PATH`.
   Several versions can sit side by side. `packaging/get-zig.sh` does this: it reads the
   version from `build.zig.zon`, downloads it, checks the minisign signature against Zig's
   public key (in the script) and unpacks it into `~/.local/opt/` (needs `minisign`).
2. **The development files** of the six libraries, and pkg-config:

   | distribution | packages |
   |---|---|
   | Debian 12/13, Ubuntu 22.04/24.04 | `libwayland-dev libvulkan-dev libfreetype-dev libfontconfig-dev libxkbcommon-dev libasound2-dev pkg-config` |
   | Fedora, Rocky/Alma/RHEL 9 | `wayland-devel vulkan-loader-devel freetype-devel fontconfig-devel libxkbcommon-devel alsa-lib-devel pkgconf-pkg-config` (all in AppStream on Rocky 9; CRB is not needed) |
   | openSUSE Tumbleweed | `wayland-devel vulkan-devel freetype2-devel fontconfig-devel libxkbcommon-devel alsa-devel pkgconf-pkg-config` |
   | Void | `wayland-devel vulkan-loader-devel freetype-devel fontconfig-devel libxkbcommon-devel alsa-lib-devel pkg-config` |
   | Arch | `wayland vulkan-icd-loader freetype2 fontconfig libxkbcommon alsa-lib pkgconf` |
   | Gentoo | `dev-libs/wayland media-libs/vulkan-loader media-libs/freetype media-libs/fontconfig x11-libs/libxkbcommon media-libs/alsa-lib dev-util/pkgconf` |

   The names were looked up in each distribution's package index (2026-11-14); only the
   Rocky 9 build is exercised, by the release workflow. openSUSE Leap was not checked.
3. Build (Zig fetches zig-wayland and vulkan-zig, named in `build.zig.zon`, on the first
   build):

       zig build --release=safe     # zig-out/bin/dimna and dimna-headless (safety checks stay on)
       zig build test               # unit tests: the core (src/root.zig) and the GUI (src/gui/tests.zig)

   `-Dgui=false` builds the core and `dimna-headless` alone: it needs none of the libraries in
   2, nor pkg-config, and zig-wayland and vulkan-zig are not fetched (they are lazy
   dependencies; `zig build --fetch=all` fetches them ahead of an offline build, plain
   `--fetch` does not). `zig build test -Dgui=false` runs the core's tests only; `gui`,
   `shaders` and `release` fail with a message that they need the GUI.

4. The machine setup as for a tarball: `packaging/60-dimna-ft60x.rules` into
   `/etc/udev/rules.d/`, `packaging/99-dimna-realtime.conf` into `/etc/security/limits.d/`, the
   `dimna` and `realtime` groups, `usermod`, log out and in (`install-user.sh` in a release
   tarball prints the exact commands).

## macOS (so far: the simulator, no board)

On a Mac with Apple silicon (tried on macOS 27), the core and `dimna-headless` build and
run from the simulator, and `dimna --sim 32,16` opens its windows (AppKit) and draws
(Metal). The board is not ported yet.

1. **Zig 0.17.1**: `zig-aarch64-macos-0.17.1.tar.xz` from https://ziglang.org/download/,
   checked and unpacked anywhere, as above (no root needed). The build also needs Apple's
   Command Line Tools (`xcode-select --install`) for the system's headers and frameworks.
2. **For `dimna`** (not for `dimna-headless`): FreeType and `pkg-config` from Homebrew
   (`brew install pkg-config freetype`), found through `pkg-config freetype2`; `dimna`
   then loads Homebrew's `libfreetype.6.dylib` when it runs. For Persian and other
   right-to-left or joined scripts, also `brew install harfbuzz fribidi` (loaded when such
   text is first drawn, from /opt/homebrew/lib or by name; without them that text is drawn
   unshaped). Nothing else: fonts come from Core Text (Chinese from Hiragino Sans GB,
   Persian from Geeza Pro, both installed with macOS), sound from Core Audio. No fontconfig,
   Wayland, Vulkan, xkbcommon or ALSA. Where a packaged app should get FreeType, HarfBuzz and
   FriBidi from is the packaging step's question.
3. Build and test:

       zig build -Dgui=false --release=safe     # zig-out/bin/dimna-headless only
       zig build test -Dgui=false               # the core's tests
       zig build --release=safe                 # also zig-out/bin/dimna
       zig build test                           # the core's tests and the GUI's
       zig-out/bin/dimna-headless --sim 32,16 --seconds 60 --record /tmp/dimna-test

   The GUI's tests open no window and play nothing. One test opens the sound device, and
   only with `DIMNA_TEST_AUDIO=1`: it lets the default output pull silence for half a second
   and prints the device, its rate, buffer and reported latency. With `DIMNA_TEST_WINDOW=1`
   the window's tests open windows for a second or so each (and bring dimna to the front):
   events made inside the process, never sent to the system, so no permission is asked
   for. With `DIMNA_TEST_PRESENT=1` as well, one more test draws plain frames for about 20
   s, windowed and fullscreen, and prints how long they took to reach the screen (the
   screen must be on and unlocked: a window not shown has its frames discarded).
   The drawing tests draw
   offscreen with Metal and read the pixels back (they need the Mac's GPU, no window), and
   `DIMNA_GPU_SPEED=1` adds a speed check that prints how long frames like the rig's take.
   The shaders are Metal Shading Language source compiled when dimna starts (no `metal`
   tool, so no Xcode needed). `zig build shaders` and `zig build release` are Linux's (they
   say so on a Mac).

What works: the core's tests, `dimna-headless --sim` with a recording (`tools/dimna_read.py`
verifies it; it needs Python 3.11 or newer with numpy), Ctrl-C ending a recording cleanly,
`tools/crash-test.sh`. What differs from Linux:

- **Syncing.** Once a second the recorder makes its files durable with `F_FULLFSYNC`,
  which makes the drive write its own cache (a plain `fsync` on macOS does not; on Linux
  `fsync` does). On the Mac's internal disk that costs about 17 ms a second for a
  48-channel recording, against about 2 ms for `fsync`.
- **Staying awake.** While acquisition runs dimna holds a power assertion
  (`PreventUserIdleSystemSleep`, named "dimna is acquiring"; `pmset -g assertions` shows
  it), so the Mac does not sleep for being idle. It does **not** keep a Mac awake whose lid
  is closed (without an external display), nor one put to sleep from the menu: close the
  lid and acquisition stops.
- **Priority and memory.** With the board, the acquisition thread would ask for a Mach
  time-constraint policy instead of `SCHED_FIFO` (nothing to set up, no group), and no
  memory is locked (macOS has no `mlockall`). The simulator asks for neither.

- **Windows.** AppKit runs on the process's main thread; the display, the control window
  and the tiles each run on a thread of their own, as on Linux. Sizes and pointer positions
  are in the screen's pixels (twice the points on a Retina screen). `--monitor` takes the
  name macOS gives the screen (System Settings > Displays; e.g. `--monitor "Built-in
  Retina Display"`); a name that is not there lists those that are. Fullscreen there is a
  borderless window above the menu bar, with the menu bar and the Dock hidden while dimna
  is in front (not a Space of its own). Keys are read by what they type in the keyboard
  layout in use (on Dvorak, `r` is the key marked R); Command combinations are left to the
  system, and Cmd-Q closes dimna's windows as their close buttons do. There is no input
  method and no press-and-hold accent menu in notes; dead keys are as AppKit gives them.
  Scrolling follows the system's "natural scrolling" setting, as libinput's does on Linux;
  a trackpad's glide after the fingers lift is ignored.
- **Fonts.** The config's `font` is a family name as on Linux; `sans-serif` is the
  system's interface font (SF), `monospace` the user's fixed-pitch font (Menlo). A family
  that is not installed is replaced by `sans-serif` and is never downloaded (Core Text
  would otherwise offer to fetch fonts from Apple's catalogue, such as Lato).
- **Sound.** The system's default output device, at its own rate, with a buffer of
  `audio_period` frames (default 128). The latency read-out's device part is what the
  device reports: its latency, safety offset, stream latency and buffer (on a MacBook Air's
  speakers 1516 frames at 48 kHz, 31.6 ms, most of it the speakers' stream latency).
  `PIPEWIRE_LATENCY` is not set.
- **Drawing.** Metal, with the layer's display sync off for the display window (it tears,
  as Linux's `--present immediate` does, and frames reach the screen in about 5 ms as
  macOS reports it) and on for the control and tile windows; `--present fifo` turns it on
  for the display too. `mailbox` means the same as `immediate` on a Mac. Colours are
  written as they are, with no colour matching to the display.
- **The default waits for the refresh** (`--present fifo` is the Mac's default): about 58
  frames a second and 20 ms from sample to screen on a 60 Hz MacBook Air, scrolling evenly.
- **Where the display is quick.** With `--tearing`, fullscreen (`--monitor "Built-in
  Retina Display"`, or another screen's name as macOS shows it): about 210 frames a second and
  7 ms from sample to screen as macOS reports it, on a 60 Hz MacBook Air. In a window it is
  as quick only while it is in front and nothing else on the screen is redrawing (about
  225 frames a second, 6 ms, alone); with dimna's control and tile windows beside it, about
  110 frames a second and 20 ms; behind another application's window, 60 and 45 ms. The
  window server shows a lone front window at once and everything else at the refresh. On
  one screen, fullscreen covers dimna's other windows; with a second screen they go there.
  Not tried yet: two screens, a 120 Hz screen.
- **Windows.** The display opens on the left of the screen, the control window and the
  tiles on the right, and dimna comes to the front. Cmd-Q closes like the close button;
  keys with Cmd held are not dimna's.

The board: the Mac's USB backend (IOKit; no driver to install, no permission asked) has
run the board on a MacBook Air M4 through Apple's USB-C Digital AV Multiport Adapter at
5 Gb/s: ten minutes recorded and verified with nothing lost, delivery delay 0.73 ms on
average as on Linux, with an occasional block 10 to 17 ms late. A soak of hours, an
unplugged cable and a comparison with the rig are still to do
(`docs/plans/macos-step8-usb.md`). Not yet: an `.app`.

## Build details

The GUI's tests cover its pure logic only (typed notes, the tile grid, the widget layout, the
control window's queue and snapshot, the audio output's `render`); none opens a window,
connects to Wayland, creates a Vulkan instance or opens a sound device, so they pass without
a display. A GUI file's tests run only if the file is listed in `src/gui/tests.zig`.

The display also needs the development files of the Wayland client library, the Vulkan
loader, FreeType, fontconfig, xkbcommon and ALSA. It needs no wayland-protocols,
wayland-scanner or vulkan-headers package (the protocol XMLs and `vk.xml` are in `vendor/`;
`-Dvk-registry=<path>` substitutes another `vk.xml`), and no `glslc`: the compiled shaders
are checked in as `src/gui/shaders/*.spv`. Only someone who changes a shader needs `glslc`
(shaderc): when it is installed, a shader whose source is newer than its `.spv` is compiled
during the build and that result is embedded; `zig build shaders` rewrites the checked-in
`.spv` files, and `zig build test` fails while one differs from what glslc makes of its
source (skipped when glslc is absent). Commit the `.spv` with the source.

liboni is vendored (`vendor/liboni`, MIT) and built in. Two patches are carried in
`onidriverloader.c`: a driver search directory (from oers) and a driver compiled into the
program (`oni_register_builtin_driver`).

## Release build

    zig build release

builds both programs for two targets, whatever `-Dtarget` says, ReleaseSafe and for the
baseline x86-64 CPU (a normal build is for this machine's CPU):

| tarball | for |
|---|---|
| `zig-out/release/dimna-<version>-x86_64-linux-gnu.tar.gz` | glibc 2.34 or newer: Rocky/Alma/RHEL 9, Ubuntu 22.04, Debian 12 and everything newer |
| `zig-out/release/dimna-<version>-x86_64-linux-musl.tar.gz` | musl (Void musl); see below |

Each is also left unpacked beside it. A tarball holds `bin/dimna`, `bin/dimna-headless`,
`packaging/` (the files named in `build.zig`'s `release_packaging`: `install-user.sh`, the udev
rule, the limits file, the menu entry, its launcher and icons, the simulator config,
`nfpm.yaml` and the package scripts, `ci-test-install.sh`), `tools/dimna_read.py`,
`README.md`, `licenses/` (liboni, stb, zig-wayland, vulkan-zig; **dimna's own licence is
missing**: there is none yet), `BUILD-INFO`, `COMMIT` (`git describe`) and `CHECK`.
`<version>` is the one in `build.zig.zon`. Using one: "A tarball", above.

**Testing one.** `packaging/ci-test-install.sh run <unpacked>/bin` (or `tarball FILE.tar.gz`)
runs `dimna --help` (and `ldd -r` on it), then `dimna-headless --sim 32,16` for 5 s recording
into a temporary folder, and checks the recording: `[final]` present, file sizes exactly as
its counts say, no gaps, 5 s of samples, and `tools/dimna_read.py` (every chunk's CRC) where
Python 3.11+ with numpy is installed. `--headless-only` skips `dimna` (for the musl tarball
on a glibc machine). It never touches the board, and sets `HOME` and the `XDG_*` folders to a
temporary folder.

### Releases: the workflow

A pushed tag `v<version>` (or a run started by hand from the Actions tab) runs
`.github/workflows/release.yml`; the steps are scripts in `packaging/`, so they can be read
without the YAML:

1. **Build** in a `rockylinux/rockylinux:9` container (`packaging/ci-build.sh`), so dimna is
   compiled against the oldest supported distribution's own headers and libraries: the
   development packages, Zig and nfpm downloaded and checked against the sha256 written in
   the workflow, `zig build test`, `zig build release`, then `packaging/make-packages.sh`
   (nfpm, `packaging/nfpm.yaml`) writes the `.deb` and `.rpm` from the glibc release folder.
   For a tag the tag must equal `v` + `build.zig.zon`'s version; an untagged run's packages are
   versioned `<version>-dev.g<commit>`.
2. **Test** in Ubuntu 22.04 and 24.04, Debian 12 and 13, Rocky 9 and Fedora containers
   (`ci-test-install.sh package`): the package installs with apt or dnf from that
   distribution's own repositories, every file is where the table above says and equal to the
   checkout's, the groups exist, `dimna --help` and the recording test pass, and after removal
   no file is left and the groups are kept. The musl tarball's `dimna-headless` is tested in
   `ghcr.io/void-linux/void-musl`; its `dimna --help` too, but not yet as a requirement (it has
   never been run). No GPU and no Wayland: the windows are not tested.
3. **Release**, for a tag, only when everything passed: a **draft** GitHub release with the
   tarballs, packages and `SHA256SUMS`. The owner reads and publishes it; the workflow never
   publishes.

**What the build machine needs:** what a normal build needs, plus `tar`, `gzip`, `readelf`
and `objdump` (binutils) and GNU `sort`; `git` for `COMMIT` (it says `unknown` without).

**The check.** Before a tarball is packed, `packaging/check-release.sh` reads each binary:
`readelf -d` must list only the libraries above, libc, libm and the dynamic loader (never
HarfBuzz or FriBidi, which dimna opens at run time only for Persian), and `objdump -T` must
show no `GLIBC_` version above 2.34. Anything else fails the release, and that target gets
no tarball (the other target's may still be written; the build exits with an error). What it
printed is the tarball's `CHECK`.

**How the system libraries are found.** For any target other than the native one (and a
glibc version or musl makes it another), Zig searches none of the system's header or library
folders. `build.zig` hands the release build the folders Zig would search for a native build
(`std.zig.system.NativePaths`: `/usr/local/include`, `/usr/include/<triple>`, `/usr/include`;
`/usr/local/lib`, `/usr/lib/<triple>`, `/lib64`, `/lib`, `/usr/lib64`, `/usr/lib`,
`/lib/<triple>`, plus `C_INCLUDE_PATH` and `LIBRARY_PATH`), those that exist. Headers come
after Zig's own C library headers (`-idirafter`), so glibc 2.34's or musl's declarations are
the ones used; libraries are `-L` folders. pkg-config runs as for a normal build, whatever
the target: it gives the `-I` folders (FreeType's `freetype2`, `libpng16`) and the `-l`
names, from the system's `.pc` files (`PKG_CONFIG_PATH` works as usual).

This machine's libraries are only linked against: the target's own copies are loaded at run
time. Built against a newer glibc, they reference symbol versions the 2.34 stubs lack
(on Arch, `__isoc23_strtol@GLIBC_2.38` and `sqrtf@GLIBC_2.43`, among others, from libasound,
libvulkan and libxkbcommon), so the
glibc link allows undefined symbols in shared libraries (`--allow-shlib-undefined`); what
dimna itself needs is what the check reads. The headers are this machine's too: a function
newer than the oldest supported distribution's library would link here and fail to load
there. Nothing checks that yet; `ldd -r bin/dimna` on the target would show it.

**musl.** Both programs build. `dimna` is linked dynamically against this machine's
glibc-built libraries, only to resolve names. (It links even without
`--allow-shlib-undefined`: lld seems not to check a library's own needs when what that
library needs, here glibc's `libc.so.6`, is not in the link.) It asks for
`/lib/ld-musl-x86_64.so.1` and the same sonames, which a musl system's builds of those
libraries have. It has not been run: that needs a musl system (a Void musl root, say).
`dimna-headless` is static, so it runs on any x86_64 Linux, but a static musl program cannot
`dlopen`: `--driver d3xx` (liboni's ft600 driver on FTDI's D3XX, itself built for glibc) is
not available there; the default `--driver usb` is built in. liboni includes glibc's
`<execinfo.h>` and uses nothing from it; for musl the build supplies an empty one.

## Two ways to reach the FT600

    dimna-headless ...                # --driver usb, the default: no FTDI code in the process
    dimna-headless --driver d3xx ...  # fallback: liboni's ft600 driver on FTDI's closed D3XX

**`usb`** needs nothing installed beyond read/write access to the device node (the udev rule,
`packaging/60-dimna-ft60x.rules`; see "Installing a release"). Three layers, all in this repo:

- `src/usb_linux.zig`: USB through the kernel's usbdevfs, in Zig, without libusb. Bulk transfers
  are asynchronous URBs, so a read that times out still reports the bytes that arrived.
- `src/ft600.zig`: the FT600 wire protocol (documented at the top of the file). It was learned
  by logging the usbdevfs requests D3XX 1.0.14 makes for the ONI driver's calls on this board.
  Nothing is sent that D3XX does not send on every open, and the chip configuration is only
  ever read.
- `src/oni_usb.zig`: a port of liboni's `drivers/ft600/onidriver_ft600.c` onto that.

`DIMNA_USB_TRACE=1` logs every command and control-channel transfer to stderr.

Measured on the rig against `d3xx` (46 channels, 30 kHz):

| | usb | d3xx |
|---|---|---|
| CPU for a 20 s recording run (user + sys) | 2.2 s | 8.7 s |
| open + port scan | about 2.5 s | about 8.6 s |
| delivery delay, avg / worst (8 KB USB blocks) | 0.76 / 2.45 ms | 0.73 / 4.58 ms |

Recordings made back to back agree: electrode noise profile r = 0.9999, AUX within 0.3 mV,
ADC within 0.03 mV. Two things make the difference:

- **Paced reads.** The chip ends a transfer whenever its FIFO runs empty, so reading as fast
  as possible (as D3XX does) fetches each block in dozens of one-sample pieces: about 12,400
  transfers a second, each with its announcement. liboni needs the whole block before it hands
  anything on, so after a read that emptied the FIFO the driver sleeps until the rest of the
  block should have been produced and fetches it in one transfer. `DIMNA_USB_PACE=0` turns that
  off.
- **No idle waits.** D3XX waits 200 ms on every pipe abort; that is skipped when no transfer
  is announced (the chip then has nothing it may send).

`--usb-block BYTES` (`Settings.usb_block_bytes`) sets how much liboni fetches at a time.
Nothing reaches the pipeline before a block is complete, so it sets the delivery delay:

| usb block | delivery delay avg / worst | CPU per 10 s | transfers per s |
|---|---|---|---|
| 24576 | 2.05 / 4.21 ms | 0.40 s | 495 |
| 8192 (default) | 0.70 / 1.92 ms | 0.60 s | 1,498 |
| 4096 | 0.38 / 1.34 ms | 0.89 s | 3,531 |
| 2048 | 0.23 / 2.10 ms | 1.37 s | 8,263 |

(Delivery delay: how much later than the quickest block of the same second a block's newest
sample reached the ring; `dimna-headless` prints it.) The FT600's stream mode was also tried and
is not used: see the notes at the top of `src/ft600.zig`.

**`d3xx`** needs `libonidriver_ft600.so`, built by `../oers/scripts/build-ft600-driver.sh`
(D3XX **1.0.x** only) into `~/.local/lib`. It is found via `$ONI_DRIVER_PATH`, next to the
executable, `../lib`, `~/.local/lib` or `/usr/local/lib`.

## Run

    dimna-headless --seconds 600 --16ch A1 --aux --adc --record ~/oez-test

`--16ch A1` is needed on the rig (16-channel headstage on an RHD2132). Prints one status line
per second and `CLEAN` at the end if nothing was lost (exit status 0). Record to disk, not
`/tmp`.

The acquisition thread runs SCHED_FIFO (needs rtprio, e.g. the `realtime` group) and locks
memory. It asks for priority 90: above PipeWire's audio thread inside dimna (`data-loop.0`,
which asks for 88 and gets what the limit allows), so sound can never hold acquisition up.
If 90 is refused it takes the most the limit (`ulimit -r`) allows and logs a warning saying
so and that the limit should be 95 (`packaging/99-dimna-realtime.conf`); if that is refused
too, it runs at normal priority, also with a warning. On macOS the number means nothing (a
Mach time-constraint policy instead). It never waits on readers: the recorder and other readers take blocks from a
preallocated ring (30 s when recording).
