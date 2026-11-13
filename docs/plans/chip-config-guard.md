# Plan: make "never writes the FT600 chip configuration" something the code enforces

Read `docs/plans/README.md` first.

## Why

`src/ft600.zig` talks to the board's FT600 USB chip directly. Its header says, as a
hardware-safety statement, that nothing in it writes the chip's configuration (a vendor
control request `0xcf` in the host-to-device direction, `bmRequestType 0x40`), because a
bad configuration write can leave the chip unable to enumerate. Today that statement is
true and is enforced by a comment. Someone adding a control transfer later would not be
stopped by anything.

## What to build

1. In `src/ft600.zig`, route every control transfer through one function. Today there
   are three call sites of `self.dev.control(...)` (firmware version `0xc0 0xf1`, read
   chip configuration `0xc0 0xcf`, GPIO `0x40 0x02`); check for others in the file.
2. That function refuses anything not on an explicit list of the requests the driver
   needs, and in particular refuses `0xcf` host-to-device, with `error.ForbiddenRequest`,
   before anything reaches the kernel. The decision is a small pure function
   (`fn allowed(request_type: u8, request: u8) bool` or similar) so it can be tested
   without a device.
3. Tests in `src/ft600.zig` (they run in `zig build test`; check that `ft600.zig` is
   reachable from `src/root.zig`): the three requests in use are allowed; `0x40 0xcf` is
   refused; a few others that are not on the list are refused; and a test that scans the
   source of `ft600.zig` itself (`@embedFile`) and fails if `dev.control(` appears
   anywhere outside the one wrapper, so the guard cannot be walked around by accident.
4. Update the header comment to say the property is enforced by that function and
   those tests.
5. `tools/usbshim/usbshim.c`: add or extend the comment at the top to say plainly what
   it is: a preload shim that logs the USB requests FTDI's closed D3XX library makes, used
   once on the owner's own board to learn the wire protocol for interoperability; that it
   contains no FTDI code; and that what was learned is unofficial. Do not change its code.

Check whether any other file issues control transfers to this device (`src/oni_usb.zig`,
`src/usbfs.zig`): `usbfs.control` is the general mechanism and stays general; if another
file calls it for the FT600, say so in your report rather than changing it.

## Files you may change

`src/ft600.zig`, `tools/usbshim/usbshim.c` (comment only), `README.md` (the "Hardware
safety" section: one sentence).

## You cannot test against hardware, and must not try

No device is involved in any of the tests. Do not run anything that opens the board (see
the rules). Your report must say that the change was not exercised on hardware, so that
the lead runs a short acquisition before it is merged.

## Done means

`zig build test` passes; `zig build --release=safe` builds; you showed the guard test can
fail (temporarily add `0xcf` host-to-device to the allowed list, and temporarily add a
stray `dev.control(` call: each must fail a test; revert both); the report lists every
control request the driver issues after your change.
