//! The Windows backend of `usb.zig`: there is none. On Windows the board's FT600 belongs to
//! FTDI's own driver, which the Open Ephys GUI needs there, and a device has one driver; so
//! dimna reaches the board through FTDI's library (`--driver d3xx`, the default on
//! Windows) and not through `ft600.zig` (docs/plans/windows-port.md, "The USB decision").
//!
//! This file has the contract's shape so that `ft600.zig` compiles: `find` finds nothing,
//! and every call on a `Device` fails. A WinUSB backend, if one is ever wanted, replaces it.

const std = @import("std");

pub const Error = error{
    /// No matching device.
    NotFound,
    /// The device is there but may not be opened.
    AccessDenied,
    /// Another program has claimed the interface.
    Busy,
    /// The device went away.
    NoDevice,
    /// The endpoint stalled.
    Stall,
    /// Any other transfer or system error.
    Io,
};

pub const Location = struct {
    bus: u32 = 0,
    dev: u32 = 0,
    speed: u32 = 0,

    pub fn bulkPacketSize(self: Location) usize {
        return if (self.speed >= 5000) 1024 else if (self.speed >= 480) 512 else 64;
    }
};

/// Always 0: nothing is looked for.
pub fn find(vendor: u16, products: []const u16, product_string: []const u8, out: []Location) usize {
    _ = .{ vendor, products, product_string, out };
    return 0;
}

pub const Transfer = struct { actual: usize, timed_out: bool };

pub const Device = struct {
    /// Unused; there so that a `Device` can be written `.{ .fd = -1 }`, as `ft600.zig`'s
    /// test does.
    fd: i32 = -1,

    pub fn open(location: Location) Error!Device {
        _ = location;
        return error.NotFound;
    }

    pub fn close(self: *Device) void {
        _ = self;
    }

    pub fn claimInterface(self: *Device, interface: u32) Error!void {
        _ = .{ self, interface };
        return error.NoDevice;
    }

    pub fn releaseInterface(self: *Device, interface: u32) void {
        _ = .{ self, interface };
    }

    pub fn clearHalt(self: *Device, endpoint: u8) void {
        _ = .{ self, endpoint };
    }

    pub fn control(self: *Device, request_type: u8, request: u8, value: u16, index: u16, data: []u8, timeout_ms: u32) Error!usize {
        _ = .{ self, request_type, request, value, index, data, timeout_ms };
        return error.NoDevice;
    }

    pub fn bulk(self: *Device, endpoint: u8, buf: []u8, timeout_ms: i32) Error!Transfer {
        _ = .{ self, endpoint, buf, timeout_ms };
        return error.NoDevice;
    }
};
