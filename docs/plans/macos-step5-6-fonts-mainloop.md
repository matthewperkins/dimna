# Plan: font lookup behind a seam; the display loop able to leave the main thread (macOS port, steps 5 and 6)

Read `docs/plans/README.md` first, then `docs/plans/macos-port.md` (the overview: "Where
the code stands", "The layout aimed at", "Rules for every step on Linux", "Steps done").
Two refactoring steps (rule 8), each its own commit or commits: moves. The Linux program
must do exactly what it does now. The audio half of the overview's step 5 is already done
(`render`, `audio_alsa.zig`).

You work on the rig over SSH, as `docs/plans/macos-step1-build.md` describes under "Where
you work" (same worktree, same branch, same rules: never the board, never the GUI binary,
no windows). Start builds and tests with `chrt -o 0 <command>` (an SSH session on the rig
is at idle priority). Temporary files in `T=$(mktemp -d /tmp/dimna-s56-XXXXXX)`; before
any `rm -rf`: `set -u`, the variable quoted, and a `case "$T" in /tmp/dimna-s56-??????)`
check.

## Step 5: font lookup

Why: text is rasterized with FreeType and shaped with HarfBuzz and FriBidi on every
system, but **finding** a font file is fontconfig, which the Mac does not have (Core Text
will do it there). The lookups are three functions; everything after them takes a file
path and a face index.

- New `src/gui/fontfind.zig`: the three lookups, with the meaning their callers rely on,
  and the choice of backend at compile time (`.linux` => `fontfind_fontconfig.zig`, else
  `@compileError`). Move into `src/gui/fontfind_fontconfig.zig`, unchanged:
  - `font.findFont` (a fontconfig pattern, such as `sans-serif`, `monospace`, a family
    name, or `sans-serif:charset=<hex>`, to a font file's path);
  - `font.anyFontHas` (does any installed font cover these code points);
  - `shape.Engine.match` and the `FcConfig` the engine keeps (a pattern, and optionally a
    family that must match exactly, to a path and a face index).
  The header of `fontfind.zig` states what a backend must understand: exactly the
  patterns the program asks for today (list them from the callers), what "no such font"
  looks like for each function, and that paths are files FreeType can open.
- `font.zig` and `shape.zig` call `fontfind`; no fontconfig call is left in them. Their
  log lines (`font: ... from <path>`) are unchanged.
- The names of the HarfBuzz and FriBidi libraries (`shape.zig`, `libs()`): one hard-coded
  `.so.0` name each today. Make each a list chosen by system (Linux: the one name it has
  now; no other system's names yet, the list is the seam), tried in order. Same warning
  when none loads.
- `src/gui/c.h` includes fontconfig's header for everyone; leave it (the build's side of
  this is for the Mac step).
- Tests: every font and shape test that ran still runs, with the same names apart from
  the prefix of moved ones; the fontconfig-backed tests keep skipping exactly when they
  skipped before.

## Step 6: the display loop able to run on another thread

Why: on macOS the process's main thread must belong to AppKit (windows and events), so
dimna's display loop, which is `main` itself today, has to be able to run on a thread of
its own there. On Linux it stays on the main thread. Making and destroying windows from
other threads (control, tiles) will be handled inside the Mac's window backend (it asks
the main thread and waits), so the callers of `Window.init` do not change.

- In `src/gui/main.zig`, everything that is the display's work (from making the display's
  window to the end of the loop and its teardown, with the exit status it yields) becomes
  one function that `main` calls. What stays in `main` proper is what must happen before
  any thread or window exists (reading the environment, the config and the arguments,
  `--help`, `--print-scheme`, setting `PIPEWIRE_LATENCY`) and returning the status. Find
  the right cut by reading it; the order of every effect (log lines, the board being
  opened, memory locked, windows made, threads started and joined, files closed) must be
  the same, and so must every exit status. Say where you cut and why.
- In `src/gui/window.zig`, one function that runs such a body with the program's
  windowing set up around it: on Linux it calls the body on the calling thread and
  returns its status, nothing else (the Wayland backend's version). Its doc comment says
  what the Mac's version will do instead (start the body on a new thread, run AppKit's
  loop on the main thread, return the body's status when it ends). `main` uses it.
- Nothing about the loop itself changes: not one statement inside it.

## What must not change

Everything under "Rules for every step on Linux" in the overview. No log line, no exit
status, no order of start-up or shutdown. No lock, queue, thread or copy appears on Linux.

## Evidence

Before changing anything, and again after each step:

1. `zig build test --summary all` (use a fresh `--cache-dir` so the counts print), and the
   lists of test names from running the `gui-test` and core test binaries directly:
   identical apart from the prefix of moved tests.
2. The stored GUI outputs untouched.
3. `zig build --release=safe` into prefixes before and after each step; compare `dimna`
   function by function as step 4's report did (its normaliser scripts are in the lead's
   scratch folder, see your brief). For step 5: the font and shape functions the same
   instructions under their new names. For step 6: `main.main` and the new function
   together against the old `main.main`: if the body was inlined back, the same
   instructions; if it was not, show that the new function is the old code and that
   `main` only calls it, and that the loop's instructions (the part from `pump` to the
   once-a-second line) are the same.
4. `zig build release` passes its CHECK; `zig build test -Dgui=false --summary all`;
   `zig fmt --check src build.zig`.
5. Start-up and exit paths that need no window, before and after, with output and exit
   status compared: `zig-out/bin/dimna` may **not** be run, so use what the tests cover
   and say which paths (bad argument, `--help`, `--print-scheme`, no such monitor, no
   board) are covered by no test and rest on the binary comparison and the lead's runs.

Break it on purpose, once each: `fontfind`'s pattern for a missing code point changed
(which test notices); the library list emptied (which test notices); the body's status
dropped in the wrapper so `main` always returns 0 (say which test notices, or that none
does).

What you cannot give, and the lead will get on the board: alternating runs before and
after (display latency, late frames, lost blocks, audio), and the exit statuses of the
real program for `--help`, a bad argument, and a monitor that does not exist.

## Files you may change

Step 5: new `src/gui/fontfind.zig`, `src/gui/fontfind_fontconfig.zig`; `src/gui/font.zig`,
`src/gui/shape.zig`, `src/gui/tests.zig`, and callers of the three functions if their
names change (`main.zig`, `control.zig`, `display.zig`, `i18n.zig`: the call only).
Step 6: `src/gui/main.zig`, `src/gui/window.zig`, `src/gui/window_wayland.zig`.
Both: `docs/*.md` and `README.md` where a moved function or file is named. Anything else:
stop and report.

## Done means

The evidence and the break-it results are in your report; where you cut `main` and why;
the work committed on `macos-port` in the rig's worktree, step 5 and step 6 separately;
the worktree clean; nothing of yours left in `/tmp`.
