# Plan: dimna.app for macOS, attached to each release, installed with one `curl` line

Read `docs/plans/README.md` first; its rules apply. Written 2026-11-24 by the rig's session,
for the Mac session, which can open the result and the rig's cannot. Start when the release
workflow's `macos` job is green (it failed on `50cad8f`; it passed on `98cad88`).

## Goal

A Mac user (Apple silicon) installs dimna without Zig, Homebrew or the Command Line Tools:

```zsh
cd ~/Downloads && curl -L -O https://github.com/matthewperkins/dimna/releases/latest/download/dimna-macos-arm64.zip \
  && unzip -o dimna-macos-arm64.zip && mv dimna.app /Applications/
```

and then opens dimna from Launchpad, Spotlight or the Dock like any Mac app: its icon, its
name in the menu bar, a double-click to start. No Apple Developer ID is paid for, so no
notarization; how close to native that gets is below.

## How (the pattern of syncview-rs, the owner's other project)

`github.com/matthewperkins/syncview-rs`: `.github/workflows/release.yml` (its "Package"
step for macOS) and `packaging/macos/Info.plist`. Read both first. In short:

1. **A real bundle**: `dimna.app/Contents/MacOS/` (the programs), `Contents/Info.plist`,
   `Contents/Resources/dimna.icns`.
2. **Ad-hoc signed** (`codesign --force -s - dimna.app`, then `codesign --verify --strict
   --verbose=2`). Apple silicon runs no unsigned code; an ad-hoc signature costs nothing.
   It names nobody, so Gatekeeper still calls the app unidentified, which is why:
3. **Installed with `curl`**, which sets no `com.apple.quarantine` attribute: Gatekeeper
   never asks, the app opens at once. A browser download is quarantined; then the user
   right-clicks the app → Open once, or System Settings → Privacy & Security → Open Anyway,
   or `xattr -dr com.apple.quarantine /Applications/dimna.app`. The README says so, as
   syncview's does.
4. **Zipped with `ditto -c -k --keepParent`** (keeps the bundle's attributes and the
   signature intact; plain `zip` can break the signature).

Homebrew is not better: casks are quarantined too, and Homebrew is phasing out unsigned
casks. Paying for a Developer ID (notarization) stays an open item for the owner.

## What dimna adds to the pattern

### FreeType must travel with the app (the main problem)

**No longer a problem (2026-11-25):** dimna on macOS draws its text with Core Text
(`src/gui/text_coretext.zig`; `docs/plans/macos-coretext-text.md`). It links no FreeType
and loads no HarfBuzz or FriBidi: `otool -L zig-out/bin/dimna` lists only macOS's own
libraries, and every language works with nothing installed. So the app carries no
library, and this section and the next ("HarfBuzz and FriBidi") are history: nothing in
them is to be done. The text below is as it was written before.

Today `dimna` on macOS links Homebrew's `libfreetype.6.dylib` (`docs/install.md`, macOS,
step 2): a user without Homebrew's FreeType cannot start the app. Find out with
`otool -L zig-out/bin/dimna` (expect `/opt/homebrew/opt/freetype/lib/libfreetype.6.dylib`).
Two ways; choose one and say why in the report:

- **A (recommended): bundle the dylibs.** Copy `libfreetype.6.dylib` and whatever *it*
  links from Homebrew (`otool -L` on it: `libpng16`, maybe others; `/usr/lib` and
  `/System` ones stay) into `Contents/Frameworks/`; `install_name_tool -id
  @rpath/<name>` on each, `-change <old> @rpath/<name>` in `dimna` and in each dylib that
  links another; `install_name_tool -add_rpath @executable_path/../Frameworks` on `dimna`;
  then sign (each dylib, then the bundle; `codesign --force -s -` re-signs what
  `install_name_tool` invalidated). The check: **no `/opt/homebrew` path** in `otool -L` of
  any Mach-O file in the bundle (a script line that fails the job if there is one).
- **B: link FreeType statically**, built from source by `build.zig` for macOS only. More
  change in `build.zig` and a vendored or fetched library; no install-name surgery. Not on
  Linux (the packages use the system's FreeType).

FreeType's licence (FTL or GPLv2+) allows either; add its licence text to
`Contents/Resources/licenses/` with liboni's and stb's (as the Linux tarball's `licenses/`).

### HarfBuzz and FriBidi (Persian only): optional, decide

`shape.zig` opens them at run time from `/opt/homebrew/lib` or by name; without them
Persian is drawn unshaped and dimna says so. Either bundle them in `Frameworks/` as well
(and add `@executable_path/../Frameworks` to the places `shape.zig` looks, a small change
there, with its library-list test) or leave them to Homebrew and say so in the README. Ask
the owner if unsure; bundling is the native feel.

### Both programs, and the terminal

`Contents/MacOS/dimna` and `Contents/MacOS/dimna-headless`. `CFBundleExecutable` is
`dimna`. The README gives, as syncview's does, an optional
`sudo ln -sf /Applications/dimna.app/Contents/MacOS/dimna /usr/local/bin/dimna` (and the
same for `dimna-headless`) for terminal use; `dimna-headless` must find its own needs
(it needs no FreeType).

### Started from Finder

- **The log.** A Finder start has no terminal: stderr goes nowhere useful. As the Linux
  desktop entry does (`packaging/dimna-desktop-launch.sh`, log in
  `~/.local/state/dimna/dimna.log`), the log should go to `~/Library/Logs/dimna/dimna.log`
  when dimna is started as the app. Decide how (a launcher script as `CFBundleExecutable`
  that `exec`s dimna with stderr redirected, signed with the bundle; or dimna itself when
  stderr is not a terminal and it runs from a bundle) and say which; keep a terminal start
  unchanged.
- **Language.** A Finder start has no `LANG`; dimna then shows English unless `language`
  is in the config. Note it in the README; following the Mac's own language setting is a
  separate change, not this plan's.
- **The simulator** cannot be asked for by a double-click. The README's line for it:
  `open -a dimna --args --sim 32,16`.
- The working directory is `/`: check nothing depends on it.

### Info.plist

From syncview's, with `dimna`: `CFBundleName`, `CFBundleDisplayName`,
`CFBundleIdentifier` `io.github.matthewperkins.dimna`, `CFBundleExecutable`,
`CFBundleIconFile` `dimna`, `CFBundlePackageType` `APPL`, the version twice from
`build.zig.zon` (`.version`), `NSHighResolutionCapable` true, `LSApplicationCategoryType`
`public.app-category.medical` (or another; say why). **`LSMinimumSystemVersion`**: what the
binaries actually require, not a guess: read `minos` with `otool -l` (`LC_BUILD_VERSION`)
on `dimna` and on every bundled dylib (Homebrew's bottles are built for the runner's
macOS); the plist says the highest. If that is newer than wanted, building for an older
target is a question for the owner, not for this step.

### The icon

`packaging/icon/dimna-512.png` and `dimna-1024.png` are rendered from `dimna-icon.svg`
(added with this plan; `rsvg-convert`, as `ICON-CREDITS.md` says). Make the `.iconset`
(16, 32, 128, 256, 512, each also @2x) with `sips` from the 1024 one, then `iconutil -c
icns`. dimna also sets its Dock icon itself (`window_appkit.zig`, `dimna_aw_set_icon`);
check the two agree and that a Finder start shows the bundle's icon before the first window.

## Files

- `packaging/macos/Info.plist` (new), `packaging/make-macos-app.sh` (new: builds the bundle
  from `zig-out/bin`, as `make-packages.sh` does the `.deb`/`.rpm`; runnable by hand on a
  Mac and from CI), `packaging/ci-macos.sh` (calls it after the tests, then checks the
  bundle: `codesign --verify`, the `otool` checks above, `dimna.app/Contents/MacOS/dimna
  --help`, and `dimna-headless --sim` from inside the bundle recording 5 s, read back as the
  job already does).
- `.github/workflows/release.yml`: the `macos` job uploads `dimna-macos-arm64.zip` as an
  artifact; the `release` job attaches it to the draft with the rest and includes it in
  `SHA256SUMS`. The asset name has **no version in it**, so `releases/latest/download/…`
  in the `curl` line always gets the newest. Keep third-party actions pinned to full SHAs
  (the workflow's rule).
- `README.md` (the `curl` line, quarantine, the terminal links, `open -a dimna --args
  --sim 32,16`), `docs/install.md` (macOS: the app; building from source stays),
  `docs/plans/macos-port.md` (step 13's record), this file's report.
- If chosen: `src/gui/shape.zig` (HarfBuzz/FriBidi from the bundle), and whatever the log
  decision needs. Nothing on Linux changes; say so with the Linux release's `CHECK` and
  tarball list unchanged.

## Evidence

- From CI: the `macos` job's log with the bundle's checks passing, and the zip attached to a
  run's artifacts (`workflow_dispatch`; no tag).
- **On the owner's Mac, by hand**, from that artifact, which matters most (CI cannot see a
  Dock):
  1. a machine state like a user's: Homebrew's `freetype`, `harfbuzz`, `fribidi` made
     unreachable for the test (for example `brew unlink` them, or test on a user account
     or a second Mac without Homebrew), to prove the bundle needs nothing from it; link
     them again afterwards;
  2. the `curl`-style install (fetch the zip with `curl` or `gh run download`, not a
     browser), then open from Launchpad: icon, menu-bar name, windows;
  3. the same zip downloaded with a browser: the Gatekeeper prompt, and that the README's
     way past it works;
  4. `open -a dimna --args --sim 32,16`; the log file written where decided;
  5. with the board, only with the owner present and their leave for that session: the
     app opens it as the source build does.
- Break it once on purpose: leave one dylib's install name pointing at `/opt/homebrew` and
  show the job fail its `otool` check.

## Not in this plan

Notarization and a Developer ID (costs money; the owner's decision), a `.dmg`, Homebrew,
Intel Macs, building for an older macOS than the runner's, following the Mac's language
setting, auto-update.
