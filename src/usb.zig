//! USB, for `ft600.zig` (its only user): the choice of this system's backend, at compile
//! time, and nothing else. The declarations are the backend's own, re-exported, so the
//! driver calls the backend's functions directly; there is no indirect call.
//!
//! What a backend must keep, because `ft600.zig` relies on it:
//!
//! - `Error` is exactly these errors, each meaning one thing:
//!   - `NotFound`: no matching device (`ft600.zig` returns it itself when `find` has not
//!     found the board asked for);
//!   - `AccessDenied`: the device is there but may not be opened read/write (on Linux, the
//!     udev rule is missing);
//!   - `Busy`: another program has claimed the interface;
//!   - `NoDevice`: the device went away (at open, at a claim, or during a transfer);
//!   - `Stall`: the endpoint stalled;
//!   - `Io`: any other transfer or system error.
//! - `find(vendor, products, product_string, out)` matches the vendor id, one of
//!   `products`, and the product string exactly (whole string, same bytes). It returns how
//!   many matched, which may be more than `out.len`, with the first `out.len` of them in
//!   `out` in an order that is the same from run to run (on Linux, bus then device number):
//!   the driver opens the board by its index in that order.
//! - A `Location` has `bus`, `dev` (printed in the driver's log line) and `speed`, the link
//!   speed in Mbit/s (480 = high speed, 5000 = SuperSpeed, 0 if unknown); and
//!   `bulkPacketSize()`, the largest bulk packet at that speed. The driver uses it to tell
//!   whether a timed-out read ended on a short packet (the chip ended the transfer).
//! - `Device.open(location)`, `close`, `claimInterface(n)`, `releaseInterface(n)`; and
//!   `clearHalt(endpoint)`, which nothing calls today. A test in `ft600.zig` makes a
//!   `Device` as `.{ .fd = -1 }`, one on which every call fails: another backend's
//!   `Device` needs that too, or the test needs changing.
//! - `Device.control` is one control transfer (`request_type` bit 7 set = device to host)
//!   that returns the bytes moved. Only `Ft600.controlTransfer` calls it, after checking the
//!   request against its list; the test at the end of `ft600.zig` fails on a call anywhere
//!   else under src/ and on a definition outside a `usb_*.zig` backend.
//! - `Device.bulk(endpoint, buf, timeout_ms)` is one bulk transfer (`endpoint` bit 7 set =
//!   IN) that waits up to `timeout_ms`, and returns a `Transfer`: `actual`, the bytes moved,
//!   and `timed_out`. A transfer that times out is cancelled, **reports the bytes that
//!   arrived** before it was given up in `actual`, and is not an error. The driver counts
//!   on that number to know how much of an announced read the chip still owes. A transfer
//!   that completes may be short (the chip ended it). An OUT buffer is only read. When
//!   `bulk` returns, nothing of the transfer is still in flight.
//! - One transfer is in flight at a time per `Device`, made and finished on the caller's
//!   thread; a backend starts no thread of its own.

const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .linux => @import("usb_linux.zig"),
    // IOKit's USB user client.
    .macos => @import("usb_darwin.zig"),
    // None: the board is reached through FTDI's library there (`usb_windows.zig`).
    .windows => @import("usb_windows.zig"),
    else => @compileError("dimna has no USB layer for this system yet"),
};

pub const Error = impl.Error;
pub const Location = impl.Location;
pub const find = impl.find;
pub const Transfer = impl.Transfer;
pub const Device = impl.Device;
