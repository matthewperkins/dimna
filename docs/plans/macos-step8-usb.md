# Plan: the board on the Mac, through IOKit (macOS port, step 8)

Read `docs/plans/README.md` first, then `docs/plans/macos-port.md` (step 8 in "Steps"), then
the header of `src/usb.zig`: it is the contract this step fulfils. `src/usb_linux.zig` is
the implementation to match in meaning; `src/ft600.zig` is the only caller.

**This is the first step in which a Mac talks to the board.** README rule 1 ("never touch
the acquisition board") holds until the owner lifts it, for a named session, with the
board on the Mac and no animal on it. The owner is present for every run below that is
marked BOARD. Nothing marked BOARD is run by an agent on its own.

## State (2026-11-24)

Written and compiling, **not yet run with a board**:

- `src/usb_iokit.c`: the IOKit calls (plain C, no Objective-C, no thread, no run loop).
- `src/usb_darwin.zig`: the contract's shape, the error mapping, the tests.
- `build.zig`: the C file compiled into the core for macOS only.

Checked without a board: core tests 143 of 146 pass, 3 skipped (two of them the new
switches below); `dimna-headless --sim 32,16 --seconds 5 --record` CLEAN; the Linux
headless cross-build compiles; `zig fmt --check src build.zig` clean.

The board is connected to the owner's MacBook Air (M4) through Apple's USB-C Digital AV
Multiport Adapter (A2119); System Information shows it at 5 Gb/s.

## How it works

- **Finding**: the IORegistry's `IOUSBHostDevice` entries, by `idVendor`, `idProduct` and
  the product string, ordered by location id (where the device is plugged in; stable from
  run to run for the same port). Reading the registry sends nothing to any device.
- **Opening**: the device's user client, by the registry entry's id. The device itself is
  not opened (`USBDeviceOpen`): control requests do not need it. `claimInterface(n)` finds
  the interface numbered n, opens it for this program alone, and learns its endpoints.
- **Control transfers**: `DeviceRequestTO` on the default pipe.
- **Bulk transfers**: `ReadPipeAsync`/`WritePipeAsync`; the completion arrives as a Mach
  message on the interface's port, received on the caller's thread with the timeout. When
  the time is up: `AbortPipe`, then wait for the completion, which carries the bytes that
  had arrived. If an aborted transfer does not report back within 2 s the device is
  treated as gone.

## What is assumed and must be seen with the board

Each is marked "to check" in the code.

1. **A read given up reports the bytes that arrived.** The driver counts on it
   (`ft600.zig`, `read`). IOKit documents the count for a completed read; for an aborted
   one it is to be seen.
2. **`AbortPipe` leaves the pipe usable** for the next read with nothing lost or
   repeated. Its documentation says it clears the halt in the controller and leaves the
   data toggle alone. No clear-halt is sent to the chip afterwards (Linux sends none).
3. **The registry keys** for the product string, the address and the speed (two spellings
   of each are tried), and that the speed read there says 5000.
4. **No kernel driver takes the FT600's interfaces** (if one does, `claimInterface` fails
   with `Busy`).
5. **What a transfer reports when the board is unplugged** (mapped to `NoDevice`:
   `kIOReturnNoDevice`, `kIOReturnNotResponding`, `kIOReturnNotOpen`).
6. **Whether a short bulk read is ever reported as an underrun** (treated as a short read).
7. **The cost per transfer** (IOKit maps the buffer on every call): the delivery-delay
   table will show it.

## The sessions with the board, in order

Stop at the first thing that is not as expected, and write down what was seen.

1. **Registry only** (sends nothing to the board):
   `DIMNA_TEST_USB=1 zig build test -Dgui=false` and, BOARD,
   `DIMNA_TEST_BOARD=1 zig build test -Dgui=false`: the board found once, at 5000, its two
   interfaces claimed and released. No transfer is made.
2. BOARD **Ten seconds, traced**:
   `DIMNA_USB_TRACE=1 zig-out/bin/dimna-headless --seconds 10 2> trace.txt`. Expect the
   chip configuration read, the ONI context made, streaming, `dropped=0 gaps=0 bad=0`,
   and a clean close. In the trace: `TIMEOUT` lines with a count above 0 are assumption 1
   seen (a count that is not a multiple of 1024 followed by correct data is the proof);
   the frame parser reports any byte lost or repeated after a timeout (assumption 2).
3. BOARD **Open and close twenty times** in a row: every run starts and ends clean, none
   leaves the board in a state the next cannot open.
4. BOARD **Ten minutes recorded**, then `tools/dimna_read.py` on the recording: CLEAN,
   every checksum good.
5. BOARD **Unplug while streaming**: the program reports the device gone and exits; it
   does not hang (assumption 5).
6. BOARD **A soak of hours** (`--seconds 14400 --record`): `dropped=0 gaps=0 bad=0`.
7. BOARD **The delivery-delay table** of `docs/install.md`, repeated on the Mac, through
   the adapter and, if a direct cable is at hand, without it.
8. BOARD **The same signal on both machines**: a recording made on the Mac compared with
   one from the rig (`tools/dimna_compare.py`).
9. BOARD **The display**: `zig-out/bin/dimna` with the board, fullscreen.

## Break it on purpose

Without a board, once each: `mapError` sending `kIOReturnExclusiveAccess` to `Io`;
`bulkResult` reporting a given-up transfer's bytes as 0; `Location.lessThan` reversed.
Each has a test that must fail. With the board: in `usb_iokit.c`, report 0 bytes for an
aborted transfer; session 2 must then show bad frames or a stall, not a clean run (if it
stays clean, the ten seconds never exercised a partial timeout, and a test that does is
needed before the soak is believed).

## Files

`src/usb_darwin.zig`, `src/usb_iokit.c`, `build.zig` (the macOS block of the core),
`src/usb.zig` (the backend's comment line only), `docs/install.md` (macOS section),
`docs/plans/macos-port.md` (the step's record). On Linux nothing changes: no statement in
`usb_linux.zig` or `ft600.zig`.

## Done means

Sessions 1 to 8 with what each printed; every assumption above answered, with what was
seen; the break-it results; `docs/install.md` saying what a Mac user needs (cable or
adapter, no driver, no permission); the Linux headless binary's code unchanged.
