# Work plans

The program was called oEZ when this was written; it is dimna now.

One file per piece of work that is handed to someone who has not been in the conversations
that produced this code: another agent, or a person. Each plan says what to do, what not
to touch, and what counts as done. This file holds what all of them need to know.

## The project in one paragraph

dimna acquires and records electrophysiology from an Open Ephys acquisition board, in Zig.
The core (`src/*.zig`, module root `src/root.zig`) is the board driver, an acquisition
thread writing into a lock-free multi-reader ring (`ring.zig`), a recorder (`record.zig`,
format described in the README under "Recording format (v1)"), a simulator (`sim.zig`), and
signal code used by the display. `src/headless.zig` is a command-line program around the
core. `src/gui/` is the display, control window, tiles and audio. The owner's first
priority is that recordings are complete and correct.

## Building and testing

    zig build --release=safe     # zig-out/bin/dimna-headless and zig-out/bin/dimna
    zig build test               # unit tests of the core (everything reachable from src/root.zig)

`zig build test` caches its run: when nothing changed it prints no test count. To see the
count, use `zig build test --summary all` after a change.

Zig is 0.17.1 (pinned in `build.zig.zon`). It differs from older Zig you may know:

- No `@cImport`; C headers are translated by the build (`b.addTranslateC`).
- `pub fn main(init: std.process.Init)`. I/O takes an explicit `Io`: `io.sleep(.fromMilliseconds(n), .awake)`,
  `Io.Clock.awake.now(io)`, `Io.Dir.cwd().openDir(io, path, .{})`, `file.writeStreamingAll(io, bytes)`.
- In tests, `std.testing.io` is the `Io` and `std.testing.allocator` the allocator.
- `std.ArrayList(T)` is unmanaged: `.empty`, `list.append(gpa, x)`, `list.deinit(gpa)`.
- `std.Io.Writer`: `var w: std.Io.Writer = .fixed(&buf); try w.print(...); w.buffered()`.
- A local may not shadow a declaration or another local in an outer scope (compile error).
- `std.fmt.bufPrintSentinel(&buf, fmt, args, 0)` for zero-terminated strings.
- Raw Linux calls are used in places: `std.os.linux.open`, `pread`, `write`, with
  `linux.errno(rc)`.

Look at an existing test before writing one: `src/review.zig` (files in a temporary
folder, raw syscalls), `src/feed.zig` and `src/ring.zig` (the ring, threads).

## Rules that are not negotiable

1. **Never touch the acquisition board.** Do not run `zig-out/bin/dimna` without `--sim`.
   Do not run `dimna-headless` without `--sim`. Do not pass `--driver`. The owner may be
   recording from an animal on this machine while you work.
2. **Do not open windows.** The plans here need none. Do not run `zig-out/bin/dimna` (the
   GUI) at all unless your plan says you may. `dimna-headless --sim ...` is fine.
3. **Temporary files** go under a new folder in `/tmp` whose name contains your process
   id, and are removed afterwards. Never write under the owner's home except inside your
   working copy.
4. **Stay inside your plan's list of files.** If the work needs a change elsewhere, stop
   and say so in your report instead of making it.
5. **Do not push**, do not change git configuration, do not rewrite history. Commit on the
   branch you are given, with:

       git -c user.name="Matthew Perkins" -c user.email="matthew.perkins@mssm.edu" commit ...

   and end the commit message with the `Co-Authored-By:` line for the model you are.
6. **Formatting:** the tree is `zig fmt` clean and stays so. Run `zig fmt` on the files you
   change; `zig fmt --check src build.zig` must print nothing when you finish.
7. **Start from the local `main`.** Your working copy may have been made from an older
   commit. Before anything else: `git merge --ff-only main` (it must succeed; if it does
   not, stop and report).
8. **Refactoring plans are moves, not rewrites.** Unless your plan says otherwise, the
   program must behave exactly as before: same output, same log lines, same file formats.
   If you find a bug while moving code, leave it, and describe it in your report.

## What counts as evidence

This project has been bitten by "it passed" meaning less than it seemed. So:

- A test must be able to fail. For each property you test, **break the code on purpose
  once** (a one-line change you then revert), run the test, and confirm it fails for the
  reason you expect. Say in your report what you broke and what the failure looked like.
- Report what you ran and what it printed, not a summary of how it went. If you did not
  run something, say "not run".
- If the code does something you did not expect, do not adjust the test until it passes
  and move on. Stop, describe what you saw, and say which of the two (code or
  expectation) you think is wrong and why.
- Say plainly what your work does **not** cover.

## Your report

End with: the branch and commit hash; the files changed; each command you ran to verify,
with its relevant output; the break-it-on-purpose results; anything unexpected; what is
not covered.
