//! The macOS backend of `usb.zig` (which states what a backend must do), through IOKit's
//! USB user client. The IOKit calls themselves are in `usb_iokit.c` (IOKit's USB interfaces
//! are tables of function pointers declared in C headers); this file is the contract's
//! shape, the mapping of IOKit's results to `Error`, and the tests.
//!
//! Bulk transfers are asynchronous ones (`ReadPipeAsync`, `WritePipeAsync`) waited for on
//! the caller's thread, and aborted (`AbortPipe`) when the time is up, because the
//! contract needs the bytes that arrived before a timeout: the completion of an aborted
//! transfer carries that count. No thread and no run loop is started.
//!
//! The device itself is not opened (`USBDeviceOpen`): control requests do not need it, and
//! the interfaces are opened one by one in `claimInterface`. macOS asks for no permission
//! for a device no kernel driver has taken.
//!
//! First run with a board on 2026-11-24 (docs/plans/macos-step8-usb.md has what was seen).
//! What is still assumed is marked "to check" below.

const std = @import("std");
const log = std.log.scoped(.usb);

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

const Loc = extern struct { entry_id: u64, location_id: u32, address: u32, speed: u32 };

extern "c" fn dimna_usb_find(vendor: u16, products: [*]const u16, nproducts: usize, product: [*]const u8, product_len: usize, out: [*]Loc, out_len: usize) usize;
extern "c" fn dimna_usb_open(entry_id: u64, handle: *?*anyopaque) i32;
extern "c" fn dimna_usb_close(handle: ?*anyopaque) void;
extern "c" fn dimna_usb_claim(handle: ?*anyopaque, interface: u32) i32;
extern "c" fn dimna_usb_release(handle: ?*anyopaque, interface: u32) void;
extern "c" fn dimna_usb_control(handle: ?*anyopaque, request_type: u8, request: u8, value: u16, index: u16, data: [*]u8, len: u16, timeout_ms: u32, moved: *u32) i32;
extern "c" fn dimna_usb_bulk(handle: ?*anyopaque, endpoint: u8, buf: [*]u8, len: u32, timeout_ms: i32, actual: *u32, timed_out: *c_int) i32;
extern "c" fn dimna_usb_clear_halt(handle: ?*anyopaque, endpoint: u8) void;

// IOReturn values (<IOKit/IOReturn.h>, <IOKit/usb/USB.h>), as the i32 the C side returns.
fn ioReturn(comptime code: u32) i32 {
    return @bitCast(code);
}
const kIOReturnSuccess: i32 = 0;
const kIOReturnNoDevice = ioReturn(0xe00002c0);
const kIOReturnNotPrivileged = ioReturn(0xe00002c1);
const kIOReturnExclusiveAccess = ioReturn(0xe00002c5);
const kIOReturnNotOpen = ioReturn(0xe00002cd);
const kIOReturnNotPermitted = ioReturn(0xe00002e2);
const kIOReturnUnderrun = ioReturn(0xe00002e7);
const kIOReturnAborted = ioReturn(0xe00002eb);
const kIOReturnNotResponding = ioReturn(0xe00002ed);
const kIOReturnNotFound = ioReturn(0xe00002f0);
const kIOUSBPipeStalled = ioReturn(0xe000404f);

/// What a failed IOKit call means in the contract's terms. `kIOReturnNotResponding` is what
/// a transfer reports when the device has been unplugged (to check), as `EPROTO` is on Linux.
fn mapError(r: i32) Error {
    return switch (r) {
        kIOReturnNoDevice, kIOReturnNotResponding, kIOReturnNotOpen => error.NoDevice,
        kIOReturnExclusiveAccess => error.Busy,
        kIOReturnNotPrivileged, kIOReturnNotPermitted => error.AccessDenied,
        kIOUSBPipeStalled => error.Stall,
        else => error.Io,
    };
}

/// IOKit's device speed (`kUSBDeviceSpeed*`) in Mbit/s; 0 if unknown.
fn speedMbit(speed: u32) u32 {
    return switch (speed) {
        0 => 2, // low speed is 1.5; the driver only asks whether it is 480 or 5000 and up
        1 => 12,
        2 => 480,
        3 => 5000,
        4 => 10000,
        5 => 20000,
        else => 0,
    };
}

/// Where a matching device sits.
pub const Location = struct {
    /// The top byte of the location id: which controller (bus) the device hangs off.
    bus: u32,
    /// The device's USB address.
    dev: u32,
    /// Link speed in Mbit/s (480 = high speed, 5000 = SuperSpeed), 0 if unknown.
    speed: u32 = 0,
    /// The location id: where the device is plugged in, the same from run to run for the
    /// same port. The order of `find`.
    location_id: u32 = 0,
    /// The IORegistry entry's id: what `open` opens. New each time the device is plugged in.
    entry_id: u64 = 0,

    /// Largest bulk packet at this speed; a shorter packet ends a transfer.
    pub fn bulkPacketSize(self: Location) usize {
        return if (self.speed >= 5000) 1024 else if (self.speed >= 480) 512 else 64;
    }

    fn lessThan(_: void, a: Location, b: Location) bool {
        return if (a.location_id != b.location_id) a.location_id < b.location_id else a.entry_id < b.entry_id;
    }
};

/// Finds USB devices by vendor id, one of `products`, and product string. Returns how many
/// were found, with the first `out.len` of them in the order of their location ids. Reads
/// the IORegistry only: no device is opened or sent anything.
pub fn find(vendor: u16, products: []const u16, product_string: []const u8, out: []Location) usize {
    var raw: [16]Loc = undefined;
    const cap = @min(out.len, raw.len);
    const n = dimna_usb_find(vendor, products.ptr, products.len, product_string.ptr, product_string.len, &raw, cap);
    const have = @min(n, cap);
    for (raw[0..have], out[0..have]) |r, *o| o.* = .{
        .bus = r.location_id >> 24,
        .dev = r.address,
        .speed = speedMbit(r.speed),
        .location_id = r.location_id,
        .entry_id = r.entry_id,
    };
    std.mem.sort(Location, out[0..have], {}, Location.lessThan);
    return n;
}

pub const Transfer = struct {
    /// Bytes moved. Valid also when the transfer timed out.
    actual: usize,
    timed_out: bool,
};

pub const Device = struct {
    /// 0 while open, -1 otherwise. Linux's field: a test in `ft600.zig` makes a device on
    /// which every call fails as `.{ .fd = -1 }`.
    fd: i32,
    /// The C side's device, null when not open.
    handle: ?*anyopaque = null,

    pub fn open(loc: Location) Error!Device {
        var handle: ?*anyopaque = null;
        const r = dimna_usb_open(loc.entry_id, &handle);
        if (r != kIOReturnSuccess) {
            log.debug("open {x:0>8} failed: {x:0>8}", .{ loc.location_id, @as(u32, @bitCast(r)) });
            return mapError(r);
        }
        return .{ .fd = 0, .handle = handle };
    }

    pub fn close(self: *Device) void {
        dimna_usb_close(self.handle);
        self.handle = null;
        self.fd = -1;
    }

    pub fn claimInterface(self: *Device, interface: u32) Error!void {
        if (self.handle == null) return error.Io;
        const r = dimna_usb_claim(self.handle, interface);
        if (r == kIOReturnSuccess) return;
        log.debug("claim interface {d} failed: {x:0>8}", .{ interface, @as(u32, @bitCast(r)) });
        return mapError(r);
    }

    pub fn releaseInterface(self: *Device, interface: u32) void {
        dimna_usb_release(self.handle, interface);
    }

    /// A control transfer. `request_type` bit 7 set = device to host. Returns bytes moved.
    pub fn control(self: *Device, request_type: u8, request: u8, value: u16, index: u16, data: []u8, timeout_ms: u32) Error!usize {
        if (self.handle == null) return error.Io;
        var moved: u32 = 0;
        const r = dimna_usb_control(self.handle, request_type, request, value, index, data.ptr, @intCast(data.len), timeout_ms, &moved);
        if (r == kIOReturnSuccess) return moved;
        log.debug("control {x:0>2} {x:0>2} failed: {x:0>8}", .{ request_type, request, @as(u32, @bitCast(r)) });
        return mapError(r);
    }

    /// One bulk transfer on `endpoint` (bit 7 set = IN). Waits up to `timeout_ms`; on timeout
    /// the transfer is aborted and whatever arrived before is reported in `actual`.
    pub fn bulk(self: *Device, endpoint: u8, buf: []u8, timeout_ms: i32) Error!Transfer {
        if (self.handle == null) return error.Io;
        var actual: u32 = 0;
        var timed_out: c_int = 0;
        var wait_ms = timeout_ms;
        if (abortEvery()) |n| {
            if (endpoint & 0x80 != 0 and buf.len > 64) {
                abort_count +%= 1;
                if (abort_count % n == 0) wait_ms = 0;
            }
        }
        const r = dimna_usb_bulk(self.handle, endpoint, buf.ptr, @intCast(buf.len), wait_ms, &actual, &timed_out);
        return bulkResult(r, actual, timed_out != 0) catch |err| {
            if (err == error.Io) log.debug("ep {x:0>2} transfer failed: {x:0>8} after {d} bytes", .{ endpoint, @as(u32, @bitCast(r)), actual });
            return err;
        };
    }

    pub fn clearHalt(self: *Device, endpoint: u8) void {
        dimna_usb_clear_halt(self.handle, endpoint);
    }
};

/// A test switch (docs/plans/macos-step8-usb.md): `DIMNA_USB_TEST_ABORT_EVERY=N` gives up
/// every Nth read of more than 64 bytes at once, as if its time were up, so that reads are
/// cut off part way while the board streams and the stream's own checks show whether a
/// byte was lost or repeated. Off unless set.
var abort_every: ?u32 = null;
var abort_count: u32 = 0;
fn abortEvery() ?u32 {
    if (abort_every == null) {
        const v = std.c.getenv("DIMNA_USB_TEST_ABORT_EVERY") orelse {
            abort_every = 0;
            return null;
        };
        abort_every = std.fmt.parseInt(u32, std.mem.span(v), 10) catch 0;
    }
    return if (abort_every.? == 0) null else abort_every.?;
}

/// What a finished bulk transfer means. A transfer this side gave up is a timeout whatever
/// IOKit calls its end (`kIOReturnAborted` is expected), unless the device has
/// gone or the endpoint stalled. A read that IOKit reports as an underrun (fewer bytes than
/// asked; to check whether it ever does for a bulk pipe) is a short read, not an error.
fn bulkResult(r: i32, actual: u32, timed_out: bool) Error!Transfer {
    if (r == kIOReturnSuccess or r == kIOReturnUnderrun) return .{ .actual = actual, .timed_out = false };
    if (timed_out) return switch (mapError(r)) {
        error.NoDevice => error.NoDevice,
        error.Stall => error.Stall,
        else => .{ .actual = actual, .timed_out = true },
    };
    if (r == kIOReturnNotFound) return error.Io; // no claimed interface has the endpoint
    return mapError(r);
}

test "IOKit results map to the contract's errors" {
    try std.testing.expectEqual(error.NoDevice, mapError(kIOReturnNoDevice));
    try std.testing.expectEqual(error.NoDevice, mapError(kIOReturnNotResponding));
    try std.testing.expectEqual(error.Busy, mapError(kIOReturnExclusiveAccess));
    try std.testing.expectEqual(error.AccessDenied, mapError(kIOReturnNotPermitted));
    try std.testing.expectEqual(error.Stall, mapError(kIOUSBPipeStalled));
    try std.testing.expectEqual(error.Io, mapError(kIOReturnAborted));
    try std.testing.expectEqual(error.Io, mapError(-1));
}

test "a transfer given up reports its bytes and is not an error" {
    try std.testing.expectEqual(Transfer{ .actual = 3072, .timed_out = true }, try bulkResult(kIOReturnAborted, 3072, true));
    try std.testing.expectEqual(Transfer{ .actual = 0, .timed_out = true }, try bulkResult(kIOReturnAborted, 0, true));
    // Completed just as it was given up: complete, not a timeout (the C side clears the flag).
    try std.testing.expectEqual(Transfer{ .actual = 512, .timed_out = false }, try bulkResult(kIOReturnSuccess, 512, false));
    // An abort nobody here asked for is an error; so is a device that went away meanwhile.
    try std.testing.expectError(error.Io, bulkResult(kIOReturnAborted, 100, false));
    try std.testing.expectError(error.NoDevice, bulkResult(kIOReturnNotResponding, 100, true));
    try std.testing.expectError(error.Stall, bulkResult(kIOUSBPipeStalled, 0, false));
}

test "speeds and packet sizes" {
    try std.testing.expectEqual(@as(u32, 480), speedMbit(2));
    try std.testing.expectEqual(@as(u32, 5000), speedMbit(3));
    try std.testing.expectEqual(@as(u32, 0), speedMbit(0xffffffff));
    try std.testing.expectEqual(@as(usize, 1024), (Location{ .bus = 0, .dev = 0, .speed = speedMbit(3) }).bulkPacketSize());
    try std.testing.expectEqual(@as(usize, 512), (Location{ .bus = 0, .dev = 0, .speed = speedMbit(2) }).bulkPacketSize());
}

test "devices are ordered by where they are plugged in" {
    var locs = [_]Location{
        .{ .bus = 2, .dev = 1, .location_id = 0x02100000, .entry_id = 5 },
        .{ .bus = 1, .dev = 9, .location_id = 0x01200000, .entry_id = 9 },
        .{ .bus = 1, .dev = 3, .location_id = 0x01200000, .entry_id = 7 },
    };
    std.mem.sort(Location, &locs, {}, Location.lessThan);
    try std.testing.expectEqual(@as(u64, 7), locs[0].entry_id);
    try std.testing.expectEqual(@as(u64, 9), locs[1].entry_id);
    try std.testing.expectEqual(@as(u64, 5), locs[2].entry_id);
}

test "every call on a device that is not open fails, and nothing is called" {
    var d: Device = .{ .fd = -1 };
    var b: [8]u8 = undefined;
    try std.testing.expectError(error.Io, d.claimInterface(0));
    try std.testing.expectError(error.Io, d.bulk(0x82, &b, 10));
    d.releaseInterface(0);
    d.clearHalt(0x82);
    d.close();
}

// Reads the IORegistry's USB devices (no device is opened or sent anything), so it runs
// only when asked: DIMNA_TEST_USB=1.
test "find reads the registry and finds no device that cannot exist" {
    if (std.c.getenv("DIMNA_TEST_USB") == null) return error.SkipZigTest;
    var out: [4]Location = undefined;
    try std.testing.expectEqual(@as(usize, 0), find(0xffff, &.{0xffff}, "no such device", &out));
    try std.testing.expectError(error.NoDevice, Device.open(.{ .bus = 0, .dev = 0, .entry_id = 0xffff_ffff_ffff_fff0 }));
}

// The board itself, read only: found at SuperSpeed, its two interfaces claimed and
// released. No transfer is made. Runs only when asked: DIMNA_TEST_BOARD=1, with the
// owner's leave (docs/plans/macos-step8-usb.md).
test "the board is found at SuperSpeed and its interfaces can be claimed" {
    if (std.c.getenv("DIMNA_TEST_BOARD") == null) return error.SkipZigTest;
    var out: [4]Location = undefined;
    const n = find(0x0403, &.{ 0x601e, 0x601f }, "Open Ephys FT600 USB board", &out);
    std.debug.print("found {d}\n", .{n});
    try std.testing.expect(n >= 1);
    std.debug.print("location {x:0>8} bus {d} address {d} speed {d}\n", .{ out[0].location_id, out[0].bus, out[0].dev, out[0].speed });
    try std.testing.expect(out[0].speed >= 5000);
    var d = try Device.open(out[0]);
    defer d.close();
    try d.claimInterface(0);
    try d.claimInterface(1);
    d.releaseInterface(1);
    d.releaseInterface(0);
}
