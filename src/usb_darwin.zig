//! The macOS backend of `usb.zig` (which states what a backend must do): for now a stand-in
//! that finds no device, so opening the board fails with `NotFound`, as on a machine with
//! none plugged in. It calls nothing of the system: no IOKit, no device is looked for,
//! opened or sent anything. The real backend (IOKit) is the next step of the macOS port.
//!
//! `Device` keeps Linux's shape, one `fd` field, because a test in `ft600.zig` makes one as
//! `.{ .fd = -1 }` (a device on which every call fails). The real backend will hold IOKit
//! interfaces instead and needs either a field of that name or that test changed.

const std = @import("std");

pub const Error = error{
    /// No matching device (the stand-in never finds one).
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

/// Where a matching device sits.
pub const Location = struct {
    bus: u32,
    dev: u32,
    /// Link speed in Mbit/s (480 = high speed, 5000 = SuperSpeed), 0 if unknown.
    speed: u32 = 0,

    /// Largest bulk packet at this speed; a shorter packet ends a transfer.
    pub fn bulkPacketSize(self: Location) usize {
        return if (self.speed >= 5000) 1024 else if (self.speed >= 480) 512 else 64;
    }
};

/// Finds no device: returns 0 and leaves `out` as it is. Nothing is enumerated.
pub fn find(vendor: u16, products: []const u16, product_string: []const u8, out: []Location) usize {
    _ = vendor;
    _ = products;
    _ = product_string;
    _ = out;
    return 0;
}

pub const Transfer = struct {
    /// Bytes moved. Valid also when the transfer timed out.
    actual: usize,
    timed_out: bool,
};

/// Every call fails without doing anything (there is never a device to call).
pub const Device = struct {
    fd: i32,

    pub fn open(loc: Location) Error!Device {
        _ = loc;
        return error.NotFound;
    }

    pub fn close(self: *Device) void {
        self.fd = -1;
    }

    pub fn claimInterface(self: *Device, interface: u32) Error!void {
        _ = self;
        _ = interface;
        return error.Io;
    }

    pub fn releaseInterface(self: *Device, interface: u32) void {
        _ = self;
        _ = interface;
    }

    /// A control transfer: refused (`Io`), nothing is sent.
    pub fn control(self: *Device, request_type: u8, request: u8, value: u16, index: u16, data: []u8, timeout_ms: u32) Error!usize {
        _ = self;
        _ = request_type;
        _ = request;
        _ = value;
        _ = index;
        _ = data;
        _ = timeout_ms;
        return error.Io;
    }

    /// A bulk transfer: refused (`Io`), nothing is sent or received.
    pub fn bulk(self: *Device, endpoint: u8, buf: []u8, timeout_ms: i32) Error!Transfer {
        _ = self;
        _ = endpoint;
        _ = buf;
        _ = timeout_ms;
        return error.Io;
    }

    pub fn clearHalt(self: *Device, endpoint: u8) void {
        _ = self;
        _ = endpoint;
    }
};

test "the stand-in finds nothing and every device call fails" {
    var out: [4]Location = undefined;
    try std.testing.expectEqual(@as(usize, 0), find(0x0403, &.{ 0x601e, 0x601f }, "anything", &out));
    try std.testing.expectError(error.NotFound, Device.open(.{ .bus = 1, .dev = 1 }));
    var d: Device = .{ .fd = -1 };
    var b: [8]u8 = undefined;
    try std.testing.expectError(error.Io, d.claimInterface(0));
    try std.testing.expectError(error.Io, d.bulk(0x82, &b, 10));
}
