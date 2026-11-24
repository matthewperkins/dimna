# Plan: one file for the operating system's calls (macOS port, step 2)

Read `docs/plans/README.md` first, then `docs/plans/macos-port.md` (the overview; this is
its step 2). This is a refactoring plan (rule 8): moves, not rewrites. The program on
Linux must do exactly what it does now, and take no longer over it.

You work on the rig over SSH, as `docs/plans/macos-step1-build.md` describes under "Where
you work" (same worktree, same branch, same rules: never the board, never the GUI binary,
no windows, `/tmp` folder with your process id). Step 1 must be merged first.

## Why

The sources call Linux directly (`std.os.linux`: clocks, sleeps, files, priorities,
memory) in about twenty files. For macOS those calls need another implementation, and
there is a trap: in Zig 0.17.1 most `std.os.linux` calls **compile for macOS and then do
the wrong thing silently** (a raw system call number the other kernel reads differently;
`getpid` returned 22 on the Mac). So "it compiles" will prove nothing later. This step
gathers every such call behind one module, so that the Mac needs one new file and a
forgotten call is caught by a test.

## What to build

`src/os.zig`, exported from `src/root.zig` as `dimna.os`: the functions the rest of the
program calls. It picks its implementation at compile time:

    const impl = switch (builtin.os.tag) {
        .linux => @import("os_linux.zig"),
        else => @compileError("dimna has no os layer for this system yet"),
    };

`src/os_linux.zig` holds today's code, moved. No macOS code in this step. The functions
(names are yours to settle; keep them few and say what each is for):

| what | today |
|---|---|
| nanoseconds on the monotonic clock, without an `Io` | `clock.zig:11-15`, `ft600.zig:295-299` and `:107-110`, `gpu.zig` is **not** yours |
| sleep for nanoseconds, retried when interrupted | `ft600.zig:301-309`, `audio_out.zig:366-369` |
| real-time priority for the calling thread; idle priority | `acquisition.zig:248-255`, `overview.zig:91-92` |
| lock the process's memory | `acquisition.zig:258-261` |
| free bytes on the filesystem holding a path | `gui/session.zig:398-423` |
| zero-filled pages, and giving a piece of them back | `pyramid.zig:128-166` |
| point a link at a new target in one step | `record.zig:112-120` |
| the process id | tests' temporary folders, `notes.zig` |
| files by descriptor: open for reading, read at an offset, open for appending, write, close, make a directory, remove a file, remove a directory | `review.zig:121-240`, `gui/notes.zig:88-230`, and the tests of `review`, `pyramid`, `overview`, `notes` |

Rules for the move:

- **Thin.** Each function does what the call site did, with the same flags, modes, retry
  loops and error handling. Callers keep their own logic and log lines. Do not convert
  callers to `std.Io` here, and do not "improve" anything (rule 8). If a call site's
  behaviour looks wrong, leave it and report it.
- **`clock.zig` stays**, with its doc comment and its test, calling `os`. Its contract is
  unchanged: the clock `Io.Clock.awake` reads.
- **Hot paths**, where a slower or different call would show in the latency figures. For
  each, say in your report how the call is made before and after (a direct call to the
  same `std.os.linux` function, through one function that the compiler can inline):
  `oni_usb.zig:313-316` (the pacing sleep and the clock read, per block, acquisition
  thread); `clock.nowNs` (several times per frame); `review.zig:213` and `:238-240` (reads
  per frame while reviewing); `pyramid.zig`'s giving back of 2 MiB pieces (per block).
- **Tests** may use `os` or the `std.Io` idioms already in the repository
  (`Io.Dir.cwd().deleteTree(testing.io, ...)`, `createFile`), whichever is the smaller
  change. `record_test.zig`'s write-failure test keeps its `fork`, `dup2`, `wait4`, `kill`
  as they are (Linux only; what replaces them on the Mac is step 7's question).
- **A test that can fail**: no file under `src/` refers to `std.os.linux` (in any
  spelling: `std.os.linux`, `os.linux`, a `linux` alias of it) except `os_linux.zig`,
  `usbfs.zig`, `gui/window.zig`, `gui/gpu.zig` (the last three become Linux backends in
  later steps), and the one test in `record_test.zig`. `ft600.zig` has such a test of its
  own source (`@embedFile`); how to cover the whole tree is yours to work out, and the
  list of exceptions must be in the test, not implied.

Left alone in this step: `usbfs.zig`, `gui/window.zig`, `gui/gpu.zig`, the ALSA calls,
fontconfig, `std.c.getenv`, `std.posix.sigaction` in `headless.zig`, the libc time calls
in `record.zig`, every path and environment variable.

## Evidence

Before changing anything, and again after:

1. `zig build test --summary all`: the same counts as before plus your new test, and
   `zig build test -Dgui=false --summary all`.
2. `zig build --release=safe` before and after into two prefixes; `cmp` both binaries.
   They will probably differ; say how much, and for the four hot paths show from the
   disassembly (`objdump -d`, the function around the call) or by other means you can
   defend that no call was added on the way to the system call.
3. `dimna-headless --sim 32,16 --seconds 10 --record /tmp/<yours>/a` before and after:
   `CLEAN`, exit 0, `python3 -I tools/dimna_read.py` `OK`, and the output's lines the same
   in kind, order and wording.
4. `tools/crash-test.sh` (simulator; read it first; it must not open a window): passes.
5. The GUI's stored outputs are untouched (`git status` shows no change under
   `src/gui/testdata`).
6. `zig fmt --check src build.zig` prints nothing.

Break it on purpose, once each: add a raw `std.os.linux` call to a file outside the
exceptions and see your new test fail; make the sleep wrapper return at once and say which
existing test notices, or that none does (then say so plainly: it is the board soak that
would).

What you cannot give, and the lead will get before this is merged: a soak on the board
(`dimna-headless --seconds 60 --16ch A1 --adc --record ...`) and a GUI run, compared with
the baseline in `macos-port.md`. Never run those yourself.

## Files you may change

New: `src/os.zig`, `src/os_linux.zig`. Changed: `src/root.zig`, `src/clock.zig`,
`src/acquisition.zig`, `src/ft600.zig`, `src/oni_usb.zig`, `src/record.zig` (the link
only), `src/review.zig`, `src/pyramid.zig`, `src/overview.zig`, `src/published.zig`,
`src/record_test.zig`, `src/independence_test.zig`, `src/gui/session.zig`,
`src/gui/notes.zig`, `src/gui/audio_out.zig` (its sleep only), `src/gui/control.zig` and
`src/gui/shape.zig` (their tests' raw calls only). `docs/plans/README.md`: the one line
under "Zig is 0.17.1" that says raw Linux calls are used in places, to say where they live
now. Anything else: stop and report.

## Done means

The evidence and both break-it results are in your report; the hot-path section is
written; the work is committed on `macos-port` in the rig's worktree; the worktree is
clean; your `/tmp` folder is gone.
