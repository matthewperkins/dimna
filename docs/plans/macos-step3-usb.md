# Plan: the USB layer behind `src/usb.zig` (macOS port, step 3)

Read `docs/plans/README.md` first, then `docs/plans/macos-port.md` (the overview; this is
its step 3). This is a refactoring plan (rule 8): a move. The program on Linux must do
exactly what it does now.

You work on the rig over SSH, as `docs/plans/macos-step1-build.md` describes under "Where
you work" (same worktree, same branch, same rules: never the board, never the GUI binary,
no windows, a `/tmp` folder with your process id). Steps 1 and 2 are on the branch.

This step is about the code that talks to the board, and you may not run it against the
board. Read every line you move. The lead soaks it on the board before it is merged.

## Why

`src/usbfs.zig` is USB through Linux's usbdevfs. The Mac needs another implementation of
the same few functions (IOKit, a later step). Only `src/ft600.zig` calls it, so the seam
is one file wide: `ft600.zig` should import a `usb.zig` that picks the system's backend at
compile time, as `os.zig` does.

There is also a hardware-safety rule to carry across. `ft600.zig` refuses every control
request outside a fixed list (in particular 0x40 0xcf, which would write the FT600's chip
configuration), and a test of its own source checks that it makes control transfers only
in that one function. With a second backend coming, the rule must hold for the whole
tree, not for one file.

## What to build

- `src/usbfs.zig` becomes `src/usb_linux.zig` (`git mv`, so its history follows), its
  code unchanged. Its header comment says it is the Linux backend of `usb.zig`.
- `src/usb.zig`: the choice of backend and nothing else.

      const impl = switch (builtin.os.tag) {
          .linux => @import("usb_linux.zig"),
          else => @compileError("dimna has no USB layer for this system yet"),
      };
      pub const Error = impl.Error;
      pub const Location = impl.Location;
      ...

  Re-export the declarations (`Error`, `Location`, `find`, `Transfer`, `Device`), do not
  wrap them in functions: `ft600.zig` then calls the backend's own functions, as today.
  Its header comment states the contract a backend must keep, taken from what `ft600.zig`
  relies on (read `ft600.zig` and say it exactly; at least): a bulk transfer that times
  out is cancelled and **reports the bytes that arrived**, and is not an error; one
  transfer in flight per device, on the caller's thread; the meaning of each error
  (`NotFound`, `AccessDenied`, `Busy`, `NoDevice`, `Stall`, `Io`); `find` matches vendor,
  one of the products, and the product string exactly, and returns locations in a stable
  order with the link speed; `bulkPacketSize`.
- `src/ft600.zig` imports `usb.zig`. Nothing else in it changes, except its test below.
- `src/root.zig` exports `usb` in place of `usbfs` (check that nothing else names
  `dimna.usbfs`).
- `src/os.zig`: in its test's list of exceptions, `usbfs.zig` becomes `usb_linux.zig`.
  That one line only.
- **The safety test, for the whole tree.** Beside the existing test in `ft600.zig` (keep
  it), a test that walks `src/` (as `os.zig`'s test does; reuse its way of finding
  `src/`) and fails if any `.zig` file other than `ft600.zig` contains a call of a
  function named `control` (the text `.control(`), or if any file other than a USB
  backend (`usb_*.zig`) defines one (`fn control(`). So a backend can offer `control`,
  only `ft600.zig` can call it, and there it is already confined to `controlTransfer`
  behind the list. State in the test what it does not see (a function pointer, another
  name).
- Mentions of `src/usbfs.zig` in `README.md`, `docs/install.md`, `docs/hardware.md` and
  `docs/recording.md`: update the name where the text is about the file. `tools/usbshim`
  is untouched.

## Evidence

Before changing anything, and again after:

1. `zig build test --summary all` and `zig build test -Dgui=false --summary all`: the
   same counts as before plus your new test.
2. `zig build --release=safe` before and after into two prefixes; `cmp` both binaries. A
   rename changes file names inside the binaries (panic and log messages), so they will
   differ; show that the disassembly of the functions that carry the USB code
   (`Ft600.read`, `Ft600.write`, `Ft600.abort`, `Ft600.open`, `controlTransfer`, the
   backend's `bulk` and `control` wherever they ended up, `oni_usb.readStream`) is the
   same instruction for instruction once addresses are stripped, as step 2's report did,
   and that no function was added or removed.
3. `dimna-headless --sim 32,16 --seconds 10 --record /tmp/<yours>/a` before and after:
   `CLEAN`, exit 0, `python3 -I tools/dimna_read.py` `OK`. (The simulator does not reach
   the USB code; this shows only that nothing else broke.)
4. `zig fmt --check src build.zig` prints nothing.
5. `git log --follow --oneline src/usb_linux.zig | tail -3` reaches the file's history as
   `usbfs.zig`.

Break it on purpose, once each: (a) add a call `x.control(...)` in another core file (it
need not compile into anything used; the test reads the text) and see the new test fail;
(b) add a `fn control(` to a file that is not a backend and see it fail; (c) add
`.{ 0x40, 0xcf }` to `allowed_requests` in `ft600.zig` and see the **existing** test fail
(it must still guard the list after your change). Revert each.

What you cannot give, and the lead will get: a soak on the board against the baseline.

## Files you may change

`src/usbfs.zig` (moved to `src/usb_linux.zig`), new `src/usb.zig`, `src/ft600.zig` (the
import, and the new test if it lives there), `src/root.zig`, `src/os.zig` (the one line),
`README.md`, `docs/install.md`, `docs/hardware.md`, `docs/recording.md` (the file's name
only). Anything else: stop and report.

## Done means

The evidence and the three break-it results are in your report; every line of
`usb_linux.zig` that differs from `usbfs.zig` is listed (there should be only the header
comment); the work is committed on `macos-port` in the rig's worktree; the worktree is
clean; your `/tmp` folder is gone.
