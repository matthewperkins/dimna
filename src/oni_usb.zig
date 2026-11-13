//! An ONI driver for the FT600 acquisition board that talks to the chip directly (`ft600.zig`)
//! instead of through FTDI's D3XX library. It is compiled into the program and registered with
//! liboni under the name `driver_name`.
//!
//! Port of liboni's `drivers/ft600/onidriver_ft600.c` (MIT), Linux path (control stream
//! polled, synchronous reads). The ONI side is unchanged: commands and register access go
//! over channel 1, sample frames over channel 0. Differences are marked `DIFF:`.

const std = @import("std");
const c = @import("c");
const ft600 = @import("ft600.zig");
const Ft600 = ft600.Ft600;
const log = std.log.scoped(.oni_usb);

pub const driver_name = "dimnausb";
const usb_description = "Open Ephys FT600 USB board";

const cmd_writereg: u8 = 0x01;
const cmd_readreg: u8 = 0x02;
const cmd_setprio: u8 = 0x03;
const sigres_signal: u8 = 0x01;
const sigres_reg: u8 = 0x02;
const default_prio: u32 = 0x0A0A0000;
const aux_size = 8192;

const gpa = std.heap.c_allocator;

/// `DIMNA_USB_PACE=0` turns read pacing off (see `readStream`).
fn pacing() bool {
    const v = std.c.getenv("DIMNA_USB_PACE") orelse return true;
    return v[0] != '0';
}

fn Ring(comptime size: usize) type {
    return struct {
        const Self = @This();
        buf: [size]u8 = undefined,
        r: usize = 0,
        w: usize = 0,

        fn len(self: *const Self) usize {
            return if (self.w >= self.r) self.w - self.r else size - (self.r - self.w);
        }
        fn canWrite(self: *const Self, n: usize) bool {
            return size - self.len() > n;
        }
        fn write(self: *Self, src: []const u8) void {
            for (src) |b| {
                self.buf[self.w] = b;
                self.w = (self.w + 1) % size;
            }
        }
        fn read(self: *Self, dst: []u8) void {
            for (dst) |*b| {
                b.* = self.buf[self.r];
                self.r = (self.r + 1) % size;
            }
        }
    };
}

const State = enum { noinit, init, running };
const SigState = enum { cmd, signal, reg };

const Ctx = struct {
    ft: ?Ft600 = null,
    in_block: u32 = 4096,
    out_block: u32 = 4096,
    signal: Ring(8192) = .{},
    reg: Ring(512) = .{},
    aux: [aux_size]u8 = undefined,
    state: State = .noinit,
    sig_state: SigState = .cmd,
    sig_offset: usize = 0,
    sig_error: bool = false,
    reg_op: struct { dev_idx: u32 = 0, dev_addr: u32 = 0, value: u32 = 0, rw: u32 = 0 } = .{},
    /// Read pacing: how long the board takes to produce one byte (running estimate, 0 =
    /// unknown), and when the last block was completed.
    ns_per_byte: f64 = 0,
    last_block_ns: i128 = 0,
    pace: bool = true,

    fn resetCtx(self: *Ctx) void {
        self.sig_state = .cmd;
        self.sig_offset = 0;
        self.sig_error = false;
        self.state = .init;
    }

    /// Sorts bytes from the control channel into the signal and register-reply buffers.
    fn fillControlBuffers(self: *Ctx, data: []const u8) void {
        var index: usize = 0;
        while (index < data.len) {
            switch (self.sig_state) {
                .cmd => {
                    if (data[index] == sigres_signal) self.sig_state = .signal else if (data[index] == sigres_reg) self.sig_state = .reg;
                    index += 1;
                },
                .signal => {
                    const first = index;
                    while (index < data.len and data[index] != 0) index += 1;
                    if (index >= data.len) index -= 1;
                    const part = data[first .. index + 1];
                    // DIFF: upstream spins until there is room, which cannot happen on one
                    // thread; report it instead.
                    if (!self.signal.canWrite(part.len)) {
                        self.sig_error = true;
                        return;
                    }
                    self.signal.write(part);
                    if (data[index] == 0) self.sig_state = .cmd;
                    index += 1;
                },
                .reg => {
                    // DIFF: upstream takes min(4, left) even after a split reply; take the
                    // rest of the 4-byte value.
                    const n = @min(4 - self.sig_offset, data.len - index);
                    if (!self.reg.canWrite(n)) {
                        self.sig_error = true;
                        return;
                    }
                    self.reg.write(data[index..][0..n]);
                    self.sig_offset = (self.sig_offset + n) % 4;
                    index += n;
                    if (self.sig_offset == 0) self.sig_state = .cmd;
                },
            }
        }
    }

    /// Reads whatever the control channel has (waiting up to 100 ms) into the buffers.
    fn updateControl(self: *Ctx) void {
        const ft = &self.ft.?;
        const n = ft.read(.control, &self.aux, 100) catch {
            self.sig_error = true;
            return;
        };
        if (n > 0) self.fillControlBuffers(self.aux[0..n]);
    }

    fn sendCmd(self: *Ctx, data: []const u8) c_int {
        const ft = &self.ft.?;
        var total: usize = 0;
        while (total < data.len) {
            total += ft.write(.control, data[total..], 1000) catch return c.ONI_ESEEKFAILURE;
        }
        return c.ONI_ESUCCESS;
    }

    fn resetAcq(self: *Ctx, hard: bool) void {
        const ft = &self.ft.?;
        if (hard) {
            ft.gpioWrite(1, 1) catch {};
            ft600.sleepMs(10);
        }
        ft.abort(ft600.Channel.data.in()) catch {};
        ft.abort(ft600.Channel.data.out()) catch {};
        self.resetCtx();
        ft.gpioWrite(1, 0) catch {};
        ft600.sleepMs(1);
    }

    fn stopAcq(self: *Ctx) void {
        ft600.sleepMs(10);
        const ft = &self.ft.?;
        if (self.state == .running and ft.data_transfers > 1000) {
            log.info(
                "data channel: {d} transfers, {d} bytes ({d} bytes per transfer)",
                .{ ft.data_transfers, ft.data_bytes, ft.data_bytes / ft.data_transfers },
            );
        }
        ft.abort(ft600.Channel.data.in()) catch {};
        self.state = .init;
    }

    fn startAcq(self: *Ctx) void {
        const ft = &self.ft.?;
        ft.data_transfers = 0;
        ft.data_bytes = 0;
        self.ns_per_byte = 0;
        self.last_block_ns = 0;
        self.pace = pacing();
        self.state = .running;
    }

    fn closeDevice(self: *Ctx) void {
        if (self.ft) |*ft| {
            ft.abort(ft600.Channel.data.in()) catch {};
            ft.abort(ft600.Channel.data.out()) catch {};
            ft.abort(ft600.Channel.control.out()) catch {};
            ft.abort(ft600.Channel.control.in()) catch {};
            ft.close(gpa);
            self.ft = null;
        }
    }
};

fn regOffset(reg: c.oni_config_t) u32 {
    return switch (reg) {
        c.ONI_CONFIG_DEV_IDX => 0,
        c.ONI_CONFIG_REG_ADDR => 1,
        c.ONI_CONFIG_REG_VALUE => 2,
        c.ONI_CONFIG_RW => 3,
        c.ONI_CONFIG_TRIG => 4,
        c.ONI_CONFIG_RUNNING => 5,
        c.ONI_CONFIG_RESET => 6,
        c.ONI_CONFIG_SYSCLKHZ => 7,
        c.ONI_CONFIG_ACQCLKHZ => 8,
        c.ONI_CONFIG_RESETACQCOUNTER => 9,
        c.ONI_CONFIG_HWADDRESS => 10,
        else => 0,
    };
}

fn cast(p: c.oni_driver_ctx) *Ctx {
    return @ptrCast(@alignCast(p.?));
}

fn createCtx() callconv(.c) c.oni_driver_ctx {
    const ctx = gpa.create(Ctx) catch return null;
    ctx.* = .{};
    return ctx;
}

fn destroyCtx(p: c.oni_driver_ctx) callconv(.c) c_int {
    const ctx = cast(p);
    // Leave the board's FIFO in reset, as upstream does.
    if (ctx.ft) |*ft| ft.gpioWrite(1, 1) catch {};
    ctx.closeDevice();
    gpa.destroy(ctx);
    return c.ONI_ESUCCESS;
}

fn init(p: c.oni_driver_ctx, host_idx: c_int) callconv(.c) c_int {
    const ctx = cast(p);
    ctx.ft = Ft600.open(gpa, usb_description, host_idx) catch |e| {
        log.err("could not open the FT600: {t}", .{e});
        return switch (e) {
            error.NotFound => if (host_idx > 0) c.ONI_EDEVIDX else c.ONI_EDEVID,
            else => c.ONI_EINIT,
        };
    };
    const ft = &ctx.ft.?;
    const cfg = ft.chipConfig() catch {
        ctx.closeDevice();
        return c.ONI_EINIT;
    };
    // FIFO mode "600" with all optional features (notifications and the like) off.
    if (cfg.fifo_mode != 1 or cfg.optional_features != 0) {
        log.err("FT600 configuration not supported: FIFO mode {d}, optional features 0x{x}", .{ cfg.fifo_mode, cfg.optional_features });
        ctx.closeDevice();
        return c.ONI_EBADCONTROLLER;
    }
    // GPIO 0 is the board's FIFO reset.
    const gpio_ok = blk: {
        ft.gpioPullOni() catch break :blk false;
        ft.gpioWrite(1, 0) catch break :blk false;
        ft.gpioEnable(1, 1) catch break :blk false;
        break :blk true;
    };
    if (!gpio_ok) {
        ctx.closeDevice();
        return c.ONI_EINIT;
    }
    ctx.resetAcq(true);
    var buf: [5]u8 = undefined;
    buf[0] = cmd_setprio;
    std.mem.writeInt(u32, buf[1..5], default_prio, .little);
    const res = ctx.sendCmd(&buf);
    if (res != c.ONI_ESUCCESS) {
        ctx.closeDevice();
        return res;
    }
    ctx.state = .init;
    return c.ONI_ESUCCESS;
}

fn readStream(p: c.oni_driver_ctx, stream: c.oni_read_stream_t, data: ?*anyopaque, size: usize) callconv(.c) c_int {
    const ctx = cast(p);
    const dst: [*]u8 = @ptrCast(data.?);
    if (stream == c.ONI_READ_STREAM_SIGNAL) {
        while (ctx.signal.len() < size) {
            ctx.updateControl();
            if (ctx.sig_error) {
                ctx.sig_error = false;
                return c.ONI_ESEEKFAILURE;
            }
        }
        ctx.signal.read(dst[0..size]);
        return @intCast(size);
    } else if (stream == c.ONI_READ_STREAM_DATA) {
        // DIFF: upstream spins until another thread starts acquisition; here that is an error.
        if (ctx.state != .running) return c.ONI_EINVALSTATE;
        const want = (size >> 2) << 2; // whole 32-bit words
        if (want < ctx.in_block) return c.ONI_EINVALREADSIZE;
        const ft = &ctx.ft.?;
        // The chip ends a transfer whenever its FIFO runs empty, so reading as fast as
        // possible fetches a block in dozens of pieces of one sample each (about 12,000
        // transfers a second, each with its announcement). liboni needs the whole block
        // before it hands anything on, so nothing is gained by that. Pacing: after a short
        // read (we have caught up), sleep until the rest of the block should have been
        // produced, less a margin, and fetch it in one transfer. When we are behind, the
        // chip's FIFO does not run empty (`caught_up` is false) and there is no sleep.
        const margin_ns = 100_000;
        var got: usize = 0;
        while (got < want) {
            got += ft.read(.data, dst[got..want], 1000) catch |e| {
                log.err("data read failed: {t}", .{e});
                return c.ONI_EREADFAILURE;
            };
            if (got < want and ft.caught_up and ctx.pace and ctx.ns_per_byte > 0) {
                const wait: f64 = @as(f64, @floatFromInt(want - got)) * ctx.ns_per_byte - margin_ns;
                if (wait > 50_000) ft600.sleepNs(@intFromFloat(@min(wait, 5_000_000)));
            }
        }
        const now = ft600.monotonicNs();
        if (ctx.last_block_ns != 0) {
            var per_byte: f64 = @as(f64, @floatFromInt(now - ctx.last_block_ns)) / @as(f64, @floatFromInt(want));
            if (ctx.ns_per_byte == 0) {
                ctx.ns_per_byte = per_byte;
            } else {
                // A stall must not teach us to sleep long: limit each step, then smooth.
                per_byte = std.math.clamp(per_byte, 0.5 * ctx.ns_per_byte, 2.0 * ctx.ns_per_byte);
                ctx.ns_per_byte = 0.9 * ctx.ns_per_byte + 0.1 * per_byte;
            }
        }
        ctx.last_block_ns = now;
        return @intCast(got);
    }
    return c.ONI_EPATHINVALID;
}

fn writeStream(p: c.oni_driver_ctx, stream: c.oni_write_stream_t, data: [*c]const u8, size: usize) callconv(.c) c_int {
    const ctx = cast(p);
    if (stream != c.ONI_WRITE_STREAM_DATA) return c.ONI_EPATHINVALID;
    const ft = &ctx.ft.?;
    const total = (size >> 2) << 2;
    var done: usize = 0;
    while (done < total) {
        const n = @min(total - done, ctx.out_block);
        done += ft.write(.data, data[done..][0..n], 1000) catch return c.ONI_EWRITEFAILURE;
    }
    return @intCast(size);
}

fn putRegWrite(buf: []u8, i: *usize, reg: u32, value: u32) void {
    buf[9 * i.*] = cmd_writereg;
    std.mem.writeInt(u32, buf[9 * i.* + 1 ..][0..4], reg, .little);
    std.mem.writeInt(u32, buf[9 * i.* + 5 ..][0..4], value, .little);
    i.* += 1;
}

fn writeConfig(p: c.oni_driver_ctx, reg: c.oni_config_t, value: c.oni_reg_val_t) callconv(.c) c_int {
    const ctx = cast(p);
    // The steps of a device register access are latched and sent as one USB transfer.
    switch (reg) {
        c.ONI_CONFIG_DEV_IDX => {
            ctx.reg_op.dev_idx = value;
            return c.ONI_ESUCCESS;
        },
        c.ONI_CONFIG_REG_ADDR => {
            ctx.reg_op.dev_addr = value;
            return c.ONI_ESUCCESS;
        },
        c.ONI_CONFIG_REG_VALUE => {
            ctx.reg_op.value = value;
            return c.ONI_ESUCCESS;
        },
        c.ONI_CONFIG_RW => {
            ctx.reg_op.rw = value;
            return c.ONI_ESUCCESS;
        },
        else => {},
    }
    var buf: [45]u8 = undefined;
    var i: usize = 0;
    if (reg == c.ONI_CONFIG_TRIG) {
        putRegWrite(&buf, &i, regOffset(c.ONI_CONFIG_DEV_IDX), ctx.reg_op.dev_idx);
        putRegWrite(&buf, &i, regOffset(c.ONI_CONFIG_REG_ADDR), ctx.reg_op.dev_addr);
        putRegWrite(&buf, &i, regOffset(c.ONI_CONFIG_RW), ctx.reg_op.rw);
        if (ctx.reg_op.rw != 0) putRegWrite(&buf, &i, regOffset(c.ONI_CONFIG_REG_VALUE), ctx.reg_op.value);
        putRegWrite(&buf, &i, regOffset(c.ONI_CONFIG_TRIG), 1);
    } else {
        putRegWrite(&buf, &i, regOffset(reg), value);
    }
    if (reg == c.ONI_CONFIG_RESET and value != 0) ctx.stopAcq();
    return ctx.sendCmd(buf[0 .. 9 * i]);
}

fn readConfig(p: c.oni_driver_ctx, reg: c.oni_config_t, value: [*c]c.oni_reg_val_t) callconv(.c) c_int {
    const ctx = cast(p);
    var buf: [5]u8 = undefined;
    buf[0] = cmd_readreg;
    std.mem.writeInt(u32, buf[1..5], regOffset(reg), .little);
    const res = ctx.sendCmd(&buf);
    if (res != c.ONI_ESUCCESS) return res;
    while (ctx.reg.len() < 4) {
        ctx.updateControl();
        if (ctx.sig_error) {
            ctx.sig_error = false;
            return c.ONI_ESEEKFAILURE;
        }
    }
    var v: [4]u8 = undefined;
    ctx.reg.read(&v);
    value.* = std.mem.readInt(u32, &v, .little);
    return c.ONI_ESUCCESS;
}

fn setOptCallback(p: c.oni_driver_ctx, option: c_int, value: ?*const anyopaque, len: usize) callconv(.c) c_int {
    _ = len;
    const ctx = cast(p);
    const v: u32 = @as(*align(1) const u32, @ptrCast(value.?)).*;
    if (option == c.ONI_OPT_RUNNING) {
        if (v == 0) ctx.stopAcq() else ctx.startAcq();
    } else if (option == c.ONI_OPT_RESETACQCOUNTER) {
        if (v > 1) ctx.startAcq();
    } else if (option == c.ONI_OPT_BLOCKREADSIZE) {
        if (ctx.state == .running) return c.ONI_EINVALSTATE;
        if (v % 4 != 0) return c.ONI_EINVALREADSIZE;
        ctx.in_block = v;
    }
    return c.ONI_ESUCCESS;
}

fn setOpt(_: c.oni_driver_ctx, _: c_int, _: ?*const anyopaque, _: usize) callconv(.c) c_int {
    return c.ONI_EINVALOPT;
}

/// Option 0: the FT60x firmware version. (Upstream: D3XX driver and library versions.)
fn getOpt(p: c.oni_driver_ctx, option: c_int, value: ?*anyopaque, len: [*c]usize) callconv(.c) c_int {
    const ctx = cast(p);
    const ft = if (ctx.ft) |*f| f else return c.ONI_EINVALSTATE;
    if (option != 0) return c.ONI_EINVALOPT;
    if (len.* < 4) return c.ONI_EBUFFERSIZE;
    @as(*align(1) u32, @ptrCast(value.?)).* = ft.firmware;
    return c.ONI_ESUCCESS;
}

const driver_info: c.oni_driver_info_t = .{ .name = "dimna-ft600-usb", .major = 0, .minor = 1, .patch = 0, .pre_release = null };

fn info() callconv(.c) [*c]const c.oni_driver_info_t {
    return &driver_info;
}

/// Makes liboni use this driver for `oni_create_ctx(driver_name)`.
pub fn register() void {
    const table: c.oni_driver_t = .{
        .handle = null,
        .ctx = null,
        .create_ctx = createCtx,
        .destroy_ctx = destroyCtx,
        .init = init,
        .read_stream = readStream,
        .write_stream = writeStream,
        .read_config = readConfig,
        .write_config = writeConfig,
        .set_opt_callback = setOptCallback,
        .set_opt = setOpt,
        .get_opt = getOpt,
        .info = info,
    };
    c.oni_register_builtin_driver(driver_name, &table);
}

const testing = std.testing;

test "control stream parser splits signals and register replies" {
    var ctx: Ctx = .{};
    // A register reply, then a signal packet ending in 0, then a reply split over two reads.
    ctx.fillControlBuffers(&.{ sigres_reg, 0x78, 0x56, 0x34, 0x12, sigres_signal, 5, 6, 7, 0, sigres_reg, 0xaa, 0xbb });
    ctx.fillControlBuffers(&.{ 0xcc, 0xdd, sigres_signal, 9 });
    ctx.fillControlBuffers(&.{0});
    try testing.expectEqual(8, ctx.reg.len());
    var v: [4]u8 = undefined;
    ctx.reg.read(&v);
    try testing.expectEqual(@as(u32, 0x12345678), std.mem.readInt(u32, &v, .little));
    ctx.reg.read(&v);
    try testing.expectEqual(@as(u32, 0xddccbbaa), std.mem.readInt(u32, &v, .little));
    var s: [6]u8 = undefined;
    try testing.expectEqual(6, ctx.signal.len());
    ctx.signal.read(&s);
    try testing.expectEqualSlices(u8, &.{ 5, 6, 7, 0, 9, 0 }, &s);
    try testing.expect(!ctx.sig_error);
}

test "ring wraps" {
    var r: Ring(8) = .{};
    var out: [5]u8 = undefined;
    for (0..4) |k| {
        try testing.expect(r.canWrite(5));
        r.write(&.{ @intCast(k), 1, 2, 3, 4 });
        r.read(&out);
        try testing.expectEqual(@as(u8, @intCast(k)), out[0]);
    }
    try testing.expectEqual(0, r.len());
}
