//! The FTDI FT600 (USB 3 FIFO bridge) wire protocol, as far as the ONI acquisition board
//! needs it, without FTDI's D3XX library.
//!
//! Learned by logging what D3XX 1.0.14 sends for the calls the ONI driver makes, on this
//! board. The chip has two interfaces:
//!
//!   interface 0: EP 0x01 OUT (commands), EP 0x81 IN (notifications, unused here)
//!   interface 1: EP 0x02/0x82 = channel 0 (ONI data), EP 0x03/0x83 = channel 1 (ONI control)
//!
//! Every transfer on a channel is first announced with a 20-byte command on EP 0x01:
//!
//!   index u32 | pipe u8 | command u8 | 0 u16 | length u32 | 0 u32 | 0 u32      (little-endian)
//!
//!   command 1 = "a transfer of `length` bytes on `pipe` follows" (IN and OUT alike)
//!   command 3 = abort the pipe
//!
//! An announced IN transfer ends when `length` bytes have been sent or the chip's FIFO runs
//! empty (a short packet), whichever comes first; the next read needs a new announcement.
//! D3XX leaves stack garbage in the fields the chip ignores; zeros are sent here.
//!
//! GPIO and configuration are vendor control requests:
//!
//!   0x40 0x02 wValue=1  u16 (mask << 2) | level       write GPIO
//!   0x40 0x02 wValue=2  u16 (mask << 2) | direction   enable GPIO (1 = output)
//!   0x40 0x02 wValue=3  u16                           GPIO pulls
//!   0xc0 0xcf wValue=1  152 bytes                     read chip configuration
//!   0xc0 0xf1           u32                           firmware version
//!
//! Hardware safety: nothing here writes the chip configuration (that would be 0x40 0xcf,
//! which is deliberately not implemented). Everything sent is what D3XX sends on every open.

const std = @import("std");
const usbfs = @import("usbfs.zig");
const linux = std.os.linux;
const log = std.log.scoped(.ft600);

pub const vendor_id: u16 = 0x0403;
/// FT600 (16-bit FIFO) and FT601 (32-bit FIFO).
pub const product_ids = [_]u16{ 0x601e, 0x601f };

const ep_command: u8 = 0x01;
const cmd_transfer: u8 = 1;
const cmd_abort: u8 = 3;

pub const Channel = enum(u1) {
    data = 0,
    control = 1,

    pub fn in(self: Channel) u8 {
        return 0x82 + @as(u8, @intFromEnum(self));
    }
    pub fn out(self: Channel) u8 {
        return 0x02 + @as(u8, @intFromEnum(self));
    }
};

pub const ChipConfig = struct {
    vendor_id: u16,
    product_id: u16,
    fifo_clock: u8,
    /// 0 = "245" mode, 1 = "600" (multi-channel) mode.
    fifo_mode: u8,
    channel_config: u8,
    optional_features: u16,
};

pub const Error = usbfs.Error || error{ShortCommand};

/// `OEZ_USB_TRACE=1` logs every command and transfer to stderr.
var trace_on: ?bool = null;
fn tracing() bool {
    if (trace_on == null) trace_on = std.c.getenv("OEZ_USB_TRACE") != null;
    return trace_on.?;
}
fn trace(comptime fmt: []const u8, args: anytype) void {
    if (!tracing()) return;
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    std.debug.print("[usb {d}.{d:0>6}] " ++ fmt ++ "\n", .{ @as(u64, @intCast(@mod(ts.sec, 1000))), @as(u64, @intCast(@divTrunc(ts.nsec, 1000))) } ++ args);
}

pub const Ft600 = struct {
    dev: usbfs.Device,
    firmware: u32 = 0,
    /// Bytes announced on each channel's IN pipe that the chip has not delivered yet.
    outstanding: [2]usize = .{ 0, 0 },
    /// Announcements sent, for statistics.
    announces: u64 = 0,
    /// Bulk packet size at the link's speed (1024 at SuperSpeed).
    packet_size: usize,
    drain: []u8,

    /// Opens the `index`-th board (bus/device order) whose product string is `product`;
    /// a negative index means the first. Claims both interfaces.
    pub fn open(gpa: std.mem.Allocator, product: []const u8, index: i32) (Error || error{OutOfMemory})!Ft600 {
        var locs: [8]usbfs.Location = undefined;
        const found = usbfs.find(vendor_id, &product_ids, product, &locs);
        const want: usize = if (index < 0) 0 else @intCast(index);
        if (want >= @min(found, locs.len)) return error.NotFound;
        var dev = try usbfs.Device.open(locs[want]);
        errdefer dev.close();
        try dev.claimInterface(0);
        errdefer dev.releaseInterface(0);
        try dev.claimInterface(1);
        errdefer dev.releaseInterface(1);
        const drain = try gpa.alloc(u8, 65536);
        var ft: Ft600 = .{ .dev = dev, .drain = drain, .packet_size = locs[want].bulkPacketSize() };
        var v: [4]u8 = undefined;
        if (ft.dev.control(0xc0, 0xf1, 0, 0, &v, 1000)) |n| {
            if (n == 4) ft.firmware = std.mem.readInt(u32, &v, .little);
        } else |_| {}
        log.info("FT60x at bus {d} device {d} ({d} Mbit/s), firmware {x}.{x:0>2}, opened without D3XX", .{ locs[want].bus, locs[want].dev, locs[want].speed, (ft.firmware >> 8) & 0xff, ft.firmware & 0xff });
        // As D3XX does on open: both IN pipes start from a known state.
        try ft.command(Channel.data.in(), cmd_abort, 0);
        try ft.command(Channel.control.in(), cmd_abort, 0);
        return ft;
    }

    pub fn close(self: *Ft600, gpa: std.mem.Allocator) void {
        self.dev.releaseInterface(1);
        self.dev.releaseInterface(0);
        self.dev.close();
        gpa.free(self.drain);
    }

    /// Reads (never writes) the chip configuration.
    pub fn chipConfig(self: *Ft600) Error!ChipConfig {
        var b: [152]u8 = undefined;
        const n = try self.dev.control(0xc0, 0xcf, 1, 0, &b, 1000);
        if (n != b.len) return error.Io;
        return .{
            .vendor_id = std.mem.readInt(u16, b[0..2], .little),
            .product_id = std.mem.readInt(u16, b[2..4], .little),
            .fifo_clock = b[137],
            .fifo_mode = b[138],
            .channel_config = b[139],
            .optional_features = std.mem.readInt(u16, b[140..142], .little),
        };
    }

    fn gpioRequest(self: *Ft600, what: u16, value: u16) Error!void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, value, .little);
        _ = try self.dev.control(0x40, 0x02, what, 0, &b, 1000);
    }
    /// Drives the GPIOs in `mask` (bits 0..1) to `level`. D3XX: FT_WriteGPIO.
    pub fn gpioWrite(self: *Ft600, mask: u2, level: u2) Error!void {
        try self.gpioRequest(1, (@as(u16, mask) << 2) | level);
    }
    /// Sets the direction of the GPIOs in `mask` (1 = output). D3XX: FT_EnableGPIO.
    pub fn gpioEnable(self: *Ft600, mask: u2, direction: u2) Error!void {
        try self.gpioRequest(2, (@as(u16, mask) << 2) | direction);
    }
    /// The pull setting the ONI driver uses, `FT_SetGPIOPull(0x3, 0x05)`, sent as the value
    /// D3XX puts on the wire for it. (The general encoding was not worked out.)
    pub fn gpioPullOni(self: *Ft600) Error!void {
        try self.gpioRequest(3, 0x002d);
    }

    fn command(self: *Ft600, pipe: u8, cmd: u8, len: u32) Error!void {
        var b: [20]u8 = @splat(0);
        b[4] = pipe;
        b[5] = cmd;
        std.mem.writeInt(u32, b[8..12], len, .little);
        const t = try self.dev.bulk(ep_command, &b, 1000);
        trace("cmd {d} pipe {x:0>2} len {d}{s}", .{ cmd, pipe, len, if (t.timed_out or t.actual != b.len) " FAILED" else "" });
        if (t.timed_out or t.actual != b.len) return error.ShortCommand;
    }

    /// Reads up to `buf.len` bytes from a channel: returns as soon as the chip ends the
    /// transfer (its FIFO ran empty), so often fewer. Zero means nothing arrived within
    /// `timeout_ms`; the announcement then stays pending and the next call continues it.
    pub fn read(self: *Ft600, ch: Channel, buf: []u8, timeout_ms: i32) Error!usize {
        const i = @intFromEnum(ch);
        if (self.outstanding[i] == 0) {
            try self.command(ch.in(), cmd_transfer, @intCast(buf.len));
            self.outstanding[i] = buf.len;
            self.announces += 1;
        }
        const want = @min(buf.len, self.outstanding[i]);
        const t = try self.dev.bulk(ch.in(), buf[0..want], timeout_ms);
        if (ch == .control or t.timed_out) trace("read {x:0>2} want {d} (announced {d}) -> {d}{s} {x}", .{ ch.in(), want, self.outstanding[i], t.actual, if (t.timed_out) " TIMEOUT" else "", buf[0..@min(t.actual, 24)] });
        if (t.timed_out) {
            // Cancelled. If the last packet received was a short one, the chip has ended the
            // transfer (the data arrived just as the read was given up) and owes nothing.
            // Otherwise it still owes the rest. A cancel that lands exactly on a packet
            // boundary is ambiguous; if the transfer had in fact ended, the next read
            // completes at once with nothing, which clears the announcement below.
            if (t.actual % self.packet_size != 0) self.outstanding[i] = 0 else self.outstanding[i] -= t.actual;
        } else if (t.actual == want and want < self.outstanding[i]) {
            // Our buffer was smaller than what is announced: the chip still owes the rest.
            self.outstanding[i] -= t.actual;
        } else {
            // Complete, or ended early by the chip (short packet): the announcement is used up.
            self.outstanding[i] = 0;
        }
        return t.actual;
    }

    /// Writes all of `data` to a channel. Returns the bytes written (less only on timeout).
    pub fn write(self: *Ft600, ch: Channel, data: []const u8, timeout_ms: i32) Error!usize {
        try self.command(ch.out(), cmd_transfer, @intCast(data.len));
        // The kernel only reads from an OUT buffer.
        const t = try self.dev.bulk(ch.out(), @constCast(data), timeout_ms);
        trace("write {x:0>2} {d} -> {d}{s} {x}", .{ ch.out(), data.len, t.actual, if (t.timed_out) " TIMEOUT" else "", data[0..@min(data.len, 45)] });
        return t.actual;
    }

    /// Aborts a pipe. For an IN pipe with an announcement still pending, first collects and
    /// discards what is still arriving for up to 200 ms, then sends the abort command.
    /// DIFF: D3XX's FT_AbortPipe does that 200 ms read on every call, also when nothing is
    /// announced. Then the chip has nothing it may send (232 of 232 such reads returned no
    /// data on the rig), so it is skipped; that takes about 6 s off opening the board.
    pub fn abort(self: *Ft600, pipe: u8) Error!void {
        if (pipe & 0x80 != 0) {
            const i = (pipe & 0x7f) - 2;
            if (self.outstanding[i] != 0) {
                const t = try self.dev.bulk(pipe, self.drain, 200);
                trace("drain {x:0>2} -> {d} bytes (announced {d})", .{ pipe, t.actual, self.outstanding[i] });
                self.outstanding[i] = 0;
            }
        }
        try self.command(pipe, cmd_abort, 0);
    }
};

pub fn sleepMs(ms: u32) void {
    var ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * 1_000_000) };
    while (linux.errno(linux.nanosleep(&ts, &ts)) == .INTR) {}
}
