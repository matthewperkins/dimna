# Plan: build the core and `dimna-headless` without the GUI's inputs (macOS port, step 1)

Read `docs/plans/README.md` first, then `docs/plans/macos-port.md` (the overview; this is
its step 1). This is a refactoring plan (rule 8): what the default build produces must not
change.

## Where you work

On the rig, the Linux machine `gallbladder`, over SSH from the lead's Mac:

    ssh gb_ts 'sh -s' <<'EOF'
    cd ~/oEZ/dimna-macos-port
    ...
    EOF

The login shell there is fish, so always go through `sh -s` as above. The working copy is
the git worktree `~/oEZ/dimna-macos-port`, on the branch `macos-port`. Do not touch
`~/oEZ/oez` (the owner's checkout) except that `git` commands in the worktree share its
repository. Edit the files on the rig (for example write them with `cat > file <<'EOF'`
through SSH, or `scp`), and build and test there: Zig 0.17.1 is `/usr/bin/zig`. The rig has
4 cores; one build at a time.

Rules 1 and 2 hold in full for this step: never the board (it is plugged in: never run
`dimna-headless` without `--sim`, never pass `--driver`), and never run `zig-out/bin/dimna`
(the GUI) at all, not even `--help`. Temporary files: a new folder under `/tmp` with your
process id in its name, removed at the end (`/tmp` there is a 3.9 GB tmpfs: fine for the
short simulator runs below, not for more). Do not push.

## Why

`zig build` always configures the GUI: `build.zig` runs `pkg-config` for FreeType and
fontconfig at configure time, runs the Wayland scanner, generates the Vulkan binding, and
builds and installs `dimna` beside `dimna-headless`. On a machine without those (a Mac,
today) nothing can be built, not even the core's tests. The macOS port starts with the core
and `dimna-headless`, so they must be buildable alone.

## What to build

An option, `-Dgui=false` (default `true`). With it:

- `pkg-config` is not run; the Wayland scanner, the Vulkan binding, the shader steps and
  `glslc` lookup are not set up; the `wayland` and `vulkan` dependencies are not needed.
  Find out whether a non-lazy dependency in `build.zig.zon` is still fetched when
  `build.zig` never asks for it; if it is, making the two dependencies lazy
  (`b.lazyDependency`) is in scope, **provided** the default build is unchanged and you say
  what it does to an offline build (the portability plan's step 5 wants recipes that build
  without network access).
- `zig build -Dgui=false` builds and installs `dimna-headless` only.
- `zig build test -Dgui=false` runs the core's tests only (today's `run test`, 133 tests).
- `zig build gui`, `zig build shaders` and `zig build release` with `-Dgui=false`: say
  clearly that they need the GUI (fail with a message), rather than half-working.

Without the option, everything is as today: same steps, same step names and descriptions
(apart from the new option in `zig build --help`), same binaries.

No target handling yet: nothing in this step mentions macOS or tests `builtin.os.tag` /
the target's OS. (The core does not compile for macOS yet; that is step 2. The lead will
try `zig build -Dgui=false` on the Mac after your work, expecting it to fail only inside
`src/`, no longer in the build script.)

## Evidence

Capture before you change anything, from the branch as you find it, and again after:

1. **The default build is unchanged.** `zig build --release=safe` into two prefixes
   (`--prefix /tmp/<yours>/before`, `.../after`), same cache. `cmp` on `bin/dimna` and
   `bin/dimna-headless`: identical, or every differing byte explained (the portability
   plan's step 1-2 report found only cache-path strings differing; step 3's found the
   binaries identical).
2. **`zig build --help`** before and after, diffed: only the new option line.
3. **Tests:** `zig build test --summary all`: `22/22 steps succeeded; 273/275 tests passed
   (2 skipped)` (133; 139 + 2 skipped; shader-check 1), as on this branch today.
4. **The release build** still works: `zig build release --prefix /tmp/<yours>/rel`, exit
   0, and its `CHECK` files equal to those of a release built before your change.
5. **The option does what it says.** With `pkg-config` hidden (as the step 1-2 report did
   for `glslc`: `bwrap --dev-bind / / --ro-bind /dev/null /usr/bin/pkg-config`, or a `PATH`
   of symlinks without it; say which and show it really is hidden): the default build
   fails as it does today in that state, and `zig build -Dgui=false --release=safe`
   succeeds and installs only `dimna-headless`. The same with
   `/usr/share/wayland-protocols` and the Vulkan registry hidden is not needed (they are
   vendored), but do show that no `wayland` or `vulkan` step appears in
   `zig build -Dgui=false --summary all`.
6. **`zig build test -Dgui=false --summary all`**: the core's 133 tests, nothing else.
7. **The headless binary from `-Dgui=false` is the same program**: `cmp` against the
   default build's `dimna-headless`; then
   `dimna-headless --sim 32,16 --seconds 5 --record /tmp/<yours>/rec` ends `CLEAN`, and
   `python3 -I tools/dimna_read.py` on the recording says `OK`.
8. `zig fmt --check src build.zig` prints nothing.

Break it on purpose, once each, and show the failure: (a) make the `-Dgui=false` path
still run `pkg-config`, and see evidence 5 fail; (b) make `-Dgui=false` still add the GUI's
tests, and see evidence 6 show them.

## Files you may change

`build.zig`, `build.zig.zon` (only for lazy dependencies, if needed), `docs/install.md`
(the build section: one short entry for the option), `README.md` (only if it lists build
commands that the option belongs beside). Nothing under `src/`, `packaging/` or `.github/`.
If the release workflow or packaging would need a change, stop and say so.

## Done means

All of the evidence above is in your report, with the commands and what they printed; the
two break-it results; the work committed on `macos-port` in the rig's worktree (rule 5's
identity and the `Co-Authored-By` line for the model you are); the worktree clean
(`git status --short` prints nothing); your `/tmp` folder removed. End with the report the
README asks for.
