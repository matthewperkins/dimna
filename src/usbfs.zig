//! USB from user space through the kernel's usbdevfs (`/dev/bus/usb/BBB/DDD`), with no
//! library in between: find a device in sysfs, claim interfaces, control transfers, and bulk
//! transfers as asynchronous URBs.
//!
//! Bulk transfers use submit / poll / reap rather than the synchronous USBDEVFS_BULK ioctl,
//! because that one throws away partial data when it times out. A reaped URB always reports
//! how many bytes arrived, also when it was cancelled.
//!
//! One transfer is in flight at a time per `Device` (the caller's thread).

const std = @import("std");
const linux = std.os.linux;
const log = std.log.scoped(.usbfs);

pub const Error = error{
    /// No matching device in sysfs.
    NotFound,
    /// The device node cannot be opened read/write (udev rule missing?).
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

// From <linux/usbdevice_fs.h> on x86-64 (checked against the header's values).
const USBDEVFS_CONTROL: u32 = 0xc0185500;
const USBDEVFS_SUBMITURB: u32 = 0x8038550a;
const USBDEVFS_DISCARDURB: u32 = 0x550b;
const USBDEVFS_REAPURB: u32 = 0x4008550c;
const USBDEVFS_REAPURBNDELAY: u32 = 0x4008550d;
const USBDEVFS_CLAIMINTERFACE: u32 = 0x8004550f;
const USBDEVFS_RELEASEINTERFACE: u32 = 0x80045510;
const USBDEVFS_CLEAR_HALT: u32 = 0x80045515;
const USBDEVFS_URB_TYPE_BULK: u8 = 3;

const Urb = extern struct {
    type: u8,
    endpoint: u8,
    status: i32 = 0,
    flags: u32 = 0,
    buffer: ?*anyopaque,
    buffer_length: i32,
    actual_length: i32 = 0,
    start_frame: i32 = 0,
    number_of_packets: i32 = 0,
    error_count: i32 = 0,
    signr: u32 = 0,
    usercontext: ?*anyopaque = null,
};

const CtrlTransfer = extern struct {
    bRequestType: u8,
    bRequest: u8,
    wValue: u16,
    wIndex: u16,
    wLength: u16,
    timeout: u32,
    data: ?*anyopaque,
};

comptime {
    std.debug.assert(@sizeOf(Urb) == 56 and @offsetOf(Urb, "buffer") == 16 and @offsetOf(Urb, "actual_length") == 28 and @offsetOf(Urb, "usercontext") == 48);
    std.debug.assert(@sizeOf(CtrlTransfer) == 24 and @offsetOf(CtrlTransfer, "data") == 16);
    std.debug.assert(linux.IOCTL.IOR('U', 10, Urb) == USBDEVFS_SUBMITURB);
    std.debug.assert(linux.IOCTL.IOWR('U', 0, CtrlTransfer) == USBDEVFS_CONTROL);
    std.debug.assert(linux.IOCTL.IOW('U', 13, ?*anyopaque) == USBDEVFS_REAPURBNDELAY);
}

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

fn readSysfs(dir: []const u8, name: []const u8, attr: []const u8, out: []u8) ?[]const u8 {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}/{s}", .{ dir, name, attr }, 0) catch return null;
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.read(fd, out.ptr, out.len);
    if (linux.errno(n) != .SUCCESS) return null;
    return std.mem.trimEnd(u8, out[0..n], "\n\r ");
}

/// Finds USB devices by vendor id, one of `products`, and product string. Returns how many
/// were found, with the first `out.len` of them in bus/device order.
pub fn find(vendor: u16, products: []const u16, product_string: []const u8, out: []Location) usize {
    const dir = "/sys/bus/usb/devices";
    const rc = linux.open(dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return 0;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var n: usize = 0;
    var buf: [4096]u8 align(@alignOf(linux.dirent64)) = undefined;
    while (true) {
        const got = linux.getdents64(fd, &buf, buf.len);
        if (linux.errno(got) != .SUCCESS or got == 0) break;
        var off: usize = 0;
        while (off < got) {
            const d: *align(1) linux.dirent64 = @ptrCast(&buf[off]);
            off += d.reclen;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&d.name)));
            // Devices are "1-2", "2-1.3"; skip root hubs ("usb1") and interfaces ("1-2:1.0").
            if (name.len == 0 or name[0] == '.' or std.mem.startsWith(u8, name, "usb") or std.mem.indexOfScalar(u8, name, ':') != null) continue;
            var b: [128]u8 = undefined;
            const vid = std.fmt.parseInt(u16, readSysfs(dir, name, "idVendor", &b) orelse continue, 16) catch continue;
            if (vid != vendor) continue;
            const pid = std.fmt.parseInt(u16, readSysfs(dir, name, "idProduct", &b) orelse continue, 16) catch continue;
            if (std.mem.indexOfScalar(u16, products, pid) == null) continue;
            if (!std.mem.eql(u8, readSysfs(dir, name, "product", &b) orelse continue, product_string)) continue;
            const bus = std.fmt.parseInt(u32, readSysfs(dir, name, "busnum", &b) orelse continue, 10) catch continue;
            const dev = std.fmt.parseInt(u32, readSysfs(dir, name, "devnum", &b) orelse continue, 10) catch continue;
            const speed = std.fmt.parseInt(u32, readSysfs(dir, name, "speed", &b) orelse "0", 10) catch 0;
            if (n < out.len) out[n] = .{ .bus = bus, .dev = dev, .speed = speed };
            n += 1;
        }
    }
    const have = @min(n, out.len);
    std.mem.sort(Location, out[0..have], {}, struct {
        fn lt(_: void, a: Location, b: Location) bool {
            return if (a.bus != b.bus) a.bus < b.bus else a.dev < b.dev;
        }
    }.lt);
    return n;
}

pub const Transfer = struct {
    /// Bytes moved. Valid also when the transfer timed out.
    actual: usize,
    timed_out: bool,
};

pub const Device = struct {
    fd: i32,

    pub fn open(loc: Location) Error!Device {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buf, "/dev/bus/usb/{d:0>3}/{d:0>3}", .{ loc.bus, loc.dev }, 0) catch unreachable;
        const rc = linux.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        return switch (linux.errno(rc)) {
            .SUCCESS => .{ .fd = @intCast(rc) },
            .ACCES, .PERM => error.AccessDenied,
            .NOENT, .NODEV => error.NoDevice,
            else => error.Io,
        };
    }

    pub fn close(self: *Device) void {
        _ = linux.close(self.fd);
        self.fd = -1;
    }

    fn ioctl(self: *const Device, req: u32, arg: usize) linux.E {
        while (true) {
            const e = linux.errno(linux.ioctl(self.fd, req, arg));
            if (e != .INTR) return e;
        }
    }

    pub fn claimInterface(self: *Device, interface: u32) Error!void {
        var n: u32 = interface;
        return switch (self.ioctl(USBDEVFS_CLAIMINTERFACE, @intFromPtr(&n))) {
            .SUCCESS => {},
            .BUSY => error.Busy,
            .NODEV => error.NoDevice,
            else => error.Io,
        };
    }

    pub fn releaseInterface(self: *Device, interface: u32) void {
        var n: u32 = interface;
        _ = self.ioctl(USBDEVFS_RELEASEINTERFACE, @intFromPtr(&n));
    }

    /// A control transfer. `request_type` bit 7 set = device to host. Returns bytes moved.
    pub fn control(self: *Device, request_type: u8, request: u8, value: u16, index: u16, data: []u8, timeout_ms: u32) Error!usize {
        var ct: CtrlTransfer = .{
            .bRequestType = request_type,
            .bRequest = request,
            .wValue = value,
            .wIndex = index,
            .wLength = @intCast(data.len),
            .timeout = timeout_ms,
            .data = data.ptr,
        };
        const rc = while (true) {
            const r = linux.ioctl(self.fd, USBDEVFS_CONTROL, @intFromPtr(&ct));
            if (linux.errno(r) != .INTR) break r;
        };
        return switch (linux.errno(rc)) {
            .SUCCESS => rc,
            .NODEV, .SHUTDOWN => error.NoDevice,
            .PIPE => error.Stall,
            else => |e| blk: {
                log.debug("control {x:0>2} {x:0>2} failed: {t}", .{ request_type, request, e });
                break :blk error.Io;
            },
        };
    }

    /// One bulk transfer on `endpoint` (bit 7 set = IN). Waits up to `timeout_ms`; on timeout
    /// the transfer is cancelled and whatever arrived before is reported in `actual`.
    pub fn bulk(self: *Device, endpoint: u8, buf: []u8, timeout_ms: i32) Error!Transfer {
        var urb: Urb = .{ .type = USBDEVFS_URB_TYPE_BULK, .endpoint = endpoint, .buffer = buf.ptr, .buffer_length = @intCast(buf.len) };
        switch (self.ioctl(USBDEVFS_SUBMITURB, @intFromPtr(&urb))) {
            .SUCCESS => {},
            .NODEV, .SHUTDOWN => return error.NoDevice,
            else => |e| {
                log.debug("submit ep {x:0>2} len {d} failed: {t}", .{ endpoint, buf.len, e });
                return error.Io;
            },
        }
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &ts);
        const deadline_ms: i64 = @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000) + timeout_ms;
        var cancelled = false;
        while (true) {
            if (!cancelled) {
                _ = linux.clock_gettime(.MONOTONIC, &ts);
                const left = deadline_ms - (@as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000));
                if (left <= 0) {
                    // EINVAL here means it completed in the meantime; the reap then returns it.
                    _ = self.ioctl(USBDEVFS_DISCARDURB, @intFromPtr(&urb));
                    cancelled = true;
                } else {
                    // Wait first: usbdevfs reports a reapable URB as writable.
                    var pfd = [1]linux.pollfd{.{ .fd = self.fd, .events = linux.POLL.OUT, .revents = 0 }};
                    const pr = linux.poll(&pfd, 1, @intCast(@min(left, std.math.maxInt(i32))));
                    if (linux.errno(pr) == .SUCCESS and pr > 0 and (pfd[0].revents & (linux.POLL.ERR | linux.POLL.HUP)) != 0 and (pfd[0].revents & linux.POLL.OUT) == 0) return error.NoDevice;
                    if (linux.errno(pr) == .SUCCESS and pr == 0) continue; // timed out: cancel above
                }
            }
            var done: ?*Urb = null;
            // After a cancel the URB always completes, so a blocking reap cannot hang.
            const req = if (cancelled) USBDEVFS_REAPURB else USBDEVFS_REAPURBNDELAY;
            switch (self.ioctl(req, @intFromPtr(&done))) {
                .SUCCESS => if (done == &urb) break, // any other cannot happen with one in flight
                .AGAIN => {},
                .NODEV, .SHUTDOWN => return error.NoDevice,
                else => return error.Io,
            }
        }
        const actual: usize = @intCast(@max(urb.actual_length, 0));
        if (urb.status == 0) return .{ .actual = actual, .timed_out = false };
        const e: linux.E = @enumFromInt(-urb.status);
        return switch (e) {
            // Cancelled by us (ENOENT), or the kernel's own unlink code (ECONNRESET).
            .NOENT, .CONNRESET => .{ .actual = actual, .timed_out = true },
            .NODEV, .SHUTDOWN, .PROTO => error.NoDevice,
            .PIPE => error.Stall,
            else => blk: {
                log.debug("ep {x:0>2} transfer failed: {t} after {d} bytes", .{ endpoint, e, actual });
                break :blk error.Io;
            },
        };
    }

    pub fn clearHalt(self: *Device, endpoint: u8) void {
        var ep: u32 = endpoint;
        _ = self.ioctl(USBDEVFS_CLEAR_HALT, @intFromPtr(&ep));
    }
};

test "usbdevfs ioctl numbers match the kernel header" {
    try std.testing.expectEqual(USBDEVFS_CLAIMINTERFACE, linux.IOCTL.IOR('U', 15, u32));
    try std.testing.expectEqual(USBDEVFS_RELEASEINTERFACE, linux.IOCTL.IOR('U', 16, u32));
    try std.testing.expectEqual(USBDEVFS_DISCARDURB, linux.IOCTL.IO('U', 11));
    try std.testing.expectEqual(USBDEVFS_REAPURB, linux.IOCTL.IOW('U', 12, ?*anyopaque));
    try std.testing.expectEqual(USBDEVFS_CLEAR_HALT, linux.IOCTL.IOR('U', 21, u32));
}
