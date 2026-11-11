//! Open Ephys acquisition board (ECP5 FPGA, FT600 USB 3, ONI protocol).
//!
//! Port of oers `crates/rhythm/src/oni_board.rs`, itself a port of `Rhd2000ONIBoard` +
//! `AcqBoardONI` from the Open Ephys acquisition-board plugin. Register writes, their order and
//! timing follow upstream; differences are marked `DIFF:` and exist only to make failures
//! visible instead of silent.
//!
//! Hardware safety: every register written here is volatile FPGA or Intan-chip state. There
//! are no flash, EEPROM or FTDI chip-configuration writes; the worst case is a power cycle.

const std = @import("std");
const oni = @import("oni.zig");
const oni_usb = @import("oni_usb.zig");
const types = @import("types.zig");
const parser_mod = @import("parser.zig");
const registers = @import("registers.zig");
const Rhd2000Registers = registers.Rhd2000Registers;
const Settings = types.Settings;
const Health = types.Health;
const Block = types.Block;
const Layout = types.Layout;
const LiveCommand = types.LiveCommand;
const RhythmParser = parser_mod.RhythmParser;
const log = std.log.scoped(.board);
const Io = std.Io;

// ---- ONI device indices ------------------------------------------------------------
pub const device_info: u32 = 254;
pub const device_rhythm: u32 = 0x0101;
pub const device_ttl: u32 = 0x0102;
pub const device_dac: u32 = 0x0103;
pub const device_memory: u32 = 0x0001;
pub const device_bno_a: u32 = 0x0002;
pub const device_i2c_raw_a: u32 = 0x0003;
const rhythm_hub_manager: u32 = 0x01FE;
const hub_clock_sel: u32 = 0x2000;
const hub_clock_busy: u32 = 0x2001;

// ---- Rhythm registers --------------------------------------------------------------
const reg = struct {
    const mode: u32 = 1;
    const max_timestep: u32 = 2;
    const cable_delay: u32 = 3;
    const auxcmd_bank_1: u32 = 4;
    const max_auxcmd_index_1: u32 = 7;
    const loop_auxcmd_index_1: u32 = 10;
    const data_stream_1_8_sel: u32 = 13;
    const data_stream_en: u32 = 15;
    const external_fast_settle: u32 = 16;
    const external_digout_a: u32 = 17;
    const sync_clkout_divide: u32 = 21;
    const dac_ctl: u32 = 22;
    const dac_sel_1: u32 = 23;
    const dac_thresh_1: u32 = 31;
    const hpf: u32 = 39;
    const spi_running: u32 = 40;
};
const mode_spi_run_continuous = 1;
const mode_dsp_settle = 2;
const mode_ttl_out = 3;
const mode_led_enable = 4;

const max_streams = types.max_streams;
const init_step = 64;
const memory_monitor_fs: u32 = 100;
const register_59_miso_a: i32 = 53;
const device_id_v3: u32 = 0x0102;

pub const chip_id_rhd2132 = parser_mod.chip_id_rhd2132;
pub const chip_id_rhd2216 = parser_mod.chip_id_rhd2216;
pub const chip_id_rhd2164 = parser_mod.chip_id_rhd2164;
pub const chip_id_rhd2164_b = parser_mod.chip_id_rhd2164_b;

pub const Error = oni.Error || Io.Cancelable || error{
    UnsupportedSampleRate,
    PllTimeout,
    BoardMemoryInitializing,
    BoardMemoryError,
    BoardMemoryInvalid,
    NoHeadstages,
    Busy,
};

const AuxSlot = enum(u32) { cmd1 = 0, cmd2 = 1, cmd3 = 2 };

const Headstage = struct {
    num_streams: usize = 0,
    channels_per_stream: usize = 0,
    first_stream_index: usize = 0,
    first_channel: usize = 0,
    has_bno: bool = false,
    chip_id: i32 = 0,

    fn connected(self: Headstage) bool {
        return self.num_streams > 0 or self.has_bno;
    }
    fn numChannels(self: Headstage) usize {
        return self.num_streams * self.channels_per_stream;
    }
};

/// Supported per-channel rates and their hub clock settings (divEn, clockSel, divider).
const SampleRate = struct { hz: u32, actual: f64, div_en: u32, sel: u32, div: u32 };
const sample_rates = [_]SampleRate{
    .{ .hz = 1000, .actual = 1000.0, .div_en = 1, .sel = 2, .div = 9 },
    .{ .hz = 1250, .actual = 1250.0, .div_en = 1, .sel = 1, .div = 9 },
    .{ .hz = 1500, .actual = 1500.0, .div_en = 1, .sel = 0, .div = 9 },
    .{ .hz = 2000, .actual = 2000.0, .div_en = 1, .sel = 2, .div = 4 },
    .{ .hz = 2500, .actual = 2500.0, .div_en = 1, .sel = 1, .div = 4 },
    .{ .hz = 3000, .actual = 3000.0, .div_en = 1, .sel = 0, .div = 4 },
    .{ .hz = 3333, .actual = 10000.0 / 3.0, .div_en = 1, .sel = 2, .div = 2 },
    .{ .hz = 5000, .actual = 5000.0, .div_en = 1, .sel = 2, .div = 1 },
    .{ .hz = 6250, .actual = 6250.0, .div_en = 1, .sel = 1, .div = 1 },
    .{ .hz = 10000, .actual = 10000.0, .div_en = 1, .sel = 2, .div = 0 },
    .{ .hz = 12500, .actual = 12500.0, .div_en = 1, .sel = 1, .div = 0 },
    .{ .hz = 15000, .actual = 15000.0, .div_en = 1, .sel = 0, .div = 0 },
    .{ .hz = 20000, .actual = 20000.0, .div_en = 0, .sel = 2, .div = 0 },
    .{ .hz = 25000, .actual = 25000.0, .div_en = 0, .sel = 1, .div = 0 },
    .{ .hz = 30000, .actual = 30000.0, .div_en = 0, .sel = 0, .div = 0 },
};

/// Per-sample aux readout of the init and scan runs: aux[stream][slot][t].
const ScanBlock = struct { aux: [max_streams][3][init_step]u16 };

const DacRoute = struct { stream: usize, channel: usize, threshold_uv: f32 };

pub fn chipName(id: i32) []const u8 {
    return switch (id) {
        chip_id_rhd2132 => "RHD2132",
        chip_id_rhd2216 => "RHD2216",
        chip_id_rhd2164 => "RHD2164",
        else => "unknown",
    };
}

/// How the FT600 is reached.
pub const Driver = enum {
    /// oEZ's own driver straight on the kernel's USB interface (`oni_usb.zig`). The default.
    usb,
    /// liboni's ft600 driver on FTDI's closed D3XX library (libonidriver_ft600.so): a fallback.
    d3xx,
};

pub const Board = struct {
    io: Io,
    driver: Driver = .usb,
    ctx: oni.Context,
    settings: Settings = .{},
    regs: Rhd2000Registers,
    sample_rate: f64 = 30000.0,
    stream_enabled: [max_streams]bool = @splat(false),
    num_data_streams: usize = 0,
    cable_delay: [4]i32 = @splat(-1),
    optimum_delay: [4]i32 = @splat(-1),
    headstages: [8]Headstage = @splat(.{}),
    /// Data source (0..15) for each enabled stream, in stream order.
    enabled_streams: [max_streams]u32 = @splat(0),
    channels_per_stream: [max_streams]usize = @splat(0),
    chip_ids: [max_streams]i32 = @splat(0),
    num_streams: usize = 0,
    has_bno: [4]bool = @splat(false),
    /// Gateware major, minor, patch, rc.
    fw: [4]u32 = @splat(0),
    device_id: u32 = 0,
    has_i2c_support: bool = false,
    has_memmon: bool = false,
    total_memory: u32 = 0,
    acq_clock_hz: u32 = 0,
    common_commands_set: bool = false,
    initial_scan: bool = true,
    // ---- acquisition state ----
    health: ?*Health = null,
    running: bool = false,
    pending: ?oni.Frame = null,
    parser: RhythmParser = .{},
    ttl_out: u16 = 0,
    dac_route: [8]?DacRoute = @splat(null),
    bno_warned: bool = false,
    /// AuxCmd3 banks holding the running register-config lists: [normal, fast settle]. Live
    /// amplifier changes upload into the idle pair (1/2 <-> 3/4) and then switch to it.
    reg_banks: [2]u32 = .{ 1, 2 },
    /// What AuxCmd3 banks 0..4 hold, as last uploaded (null = unknown), so live changes only
    /// write the entries that differ. Forgotten on every board reset, to be safe.
    cmd3_banks: [5]?registers.CommandList = @splat(null),

    /// Open the first ONI acquisition board on the FT600 bus, initialize it and scan ports.
    /// Uses default settings; apply others with `applySettings` afterwards (as oers does, so a
    /// non-default sample rate gets its cable-delay rescan).
    pub fn open(io: Io, driver: Driver) (oni.OpenError || Error)!Board {
        const name: [:0]const u8 = switch (driver) {
            .d3xx => "ft600",
            .usb => blk: {
                oni_usb.register();
                break :blk oni_usb.driver_name;
            },
        };
        log.info("searching for ONI acquisition board (driver {s})", .{name});
        var b: Board = .{ .io = io, .driver = driver, .ctx = try oni.Context.open(name, -1), .regs = .init(30000.0) };
        errdefer b.ctx.deinit();
        try b.detect();
        try b.initialize();
        try b.scanPortsImpl();
        return b;
    }

    pub fn close(self: *Board) void {
        self.stop() catch |e| log.warn("stop on close failed: {t}", .{e});
        self.ctx.deinit();
    }

    fn detect(self: *Board) Error!void {
        const lv = oni.libraryVersion();
        log.info("liboni {d}.{d}.{d}", .{ lv[0], lv[1], lv[2] });
        if (self.ctx.driverInfo()) |d| {
            log.info("ONI driver {s} {d}.{d}.{d}{s}{s}", .{ d.name, d.version[0], d.version[1], d.version[2], if (d.pre_release != null) "-" else "", d.pre_release orelse "" });
        }
        if (self.driver == .d3xx) {
            if (self.ctx.getDriverOptU32(0)) |v| {
                log.info("FTDI driver {d}.{d}.{d}", .{ (v >> 24) & 0xff, (v >> 16) & 0xff, v & 0xffff });
            } else |_| {}
            if (self.ctx.getDriverOptU32(1)) |v| {
                log.info("FTDI library {d}.{d}.{d}", .{ (v >> 24) & 0xff, (v >> 16) & 0xff, v & 0xff });
            } else |_| {}
        }
        const v = try self.ctx.readReg(device_info, 2);
        self.fw = .{ (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff, (v >> 24) & 0xff };
        log.info("ECP5-ONI gateware v{d}.{d}.{d}", .{ self.fw[0], self.fw[1], self.fw[2] });
        if (self.fw[0] == 0) log.warn("gateware v{d}.{d}.{d} is outdated and should be updated", .{ self.fw[0], self.fw[1], self.fw[2] });
        self.has_i2c_support = semverGe(self.fw, .{ 1, 5, 0 });
        self.has_memmon = semverGe(self.fw, .{ 1, 5, 1 });
        self.device_id = self.ctx.readReg(device_info, 0) catch 0;
        log.info("acquisition board ID = 0x{x}", .{self.device_id});
        if (self.has_memmon) {
            try self.ctx.writeReg(device_memory, 0, 1);
            const clk = try self.ctx.readReg(device_memory, 2);
            try self.ctx.writeReg(device_memory, 1, clk / memory_monitor_fs);
            self.total_memory = try self.ctx.readReg(device_memory, 3);
        } else {
            self.ctx.writeReg(device_memory, 0, 0) catch {};
        }
        var tbl: [64]oni.Device = undefined;
        if (self.ctx.deviceTable(&tbl)) |devs| {
            for (devs) |d| log.debug("dev idx 0x{x} id 0x{x} ver 0x{x} rd {d} wr {d}", .{ d.idx, d.id, d.version, d.read_size, d.write_size });
        } else |_| {}
    }

    fn semverGe(fw: [4]u32, t: [3]u32) bool {
        for (0..3) |i| {
            if (fw[i] != t[i]) return fw[i] > t[i];
        }
        return true;
    }

    fn checkBoardMem(self: *Board) Error!void {
        const v = (try self.ctx.readReg(device_info, 0x1000)) & 3;
        switch (v) {
            1 => {},
            0 => {
                log.err("board memory still initializing; wait and retry", .{});
                return error.BoardMemoryInitializing;
            },
            3 => {
                log.err("on-board memory error: power-cycle the board (USB and power)", .{});
                return error.BoardMemoryError;
            },
            else => return error.BoardMemoryInvalid,
        }
    }

    fn elapsedMs(self: *Board, t0: Io.Timestamp) i64 {
        return t0.untilNow(self.io, .awake).toMilliseconds();
    }

    // ------------------------------------------------------------------ low level
    fn resetBoard(self: *Board) Error!void {
        self.cmd3_banks = @splat(null);
        try self.io.sleep(.fromMilliseconds(50), .awake);
        try self.ctx.setOptU32(oni.opt.reset, 1);
        try self.ctx.setOptU32(oni.opt.block_read_size, self.settings.usb_block_bytes);
    }
    fn rw(self: *Board, addr: u32, val: u32, mask: u32) Error!void {
        try self.ctx.writeRegMask(device_rhythm, addr, val, mask);
    }
    fn setContinuous(self: *Board, on: bool) Error!void {
        try self.rw(reg.mode, @as(u32, @intFromBool(on)) << mode_spi_run_continuous, 1 << mode_spi_run_continuous);
    }
    fn setMaxTimestep(self: *Board, n: u32) Error!void {
        try self.ctx.writeReg(device_rhythm, reg.max_timestep, n);
    }
    fn run(self: *Board) Error!void {
        try self.ctx.setOptU32(oni.opt.reset_acq_counter, 2);
    }
    fn stopHw(self: *Board) Error!void {
        try self.ctx.setOptU32(oni.opt.running, 0);
    }
    fn isRunning(self: *Board) bool {
        const v = self.ctx.readReg(device_rhythm, reg.spi_running) catch return false;
        return v != 0;
    }
    fn setCableDelay(self: *Board, port: usize, delay: i32) Error!void {
        if (delay < 0 or delay > 15) log.warn("cable delay out of range: {d}", .{delay});
        const d = std.math.clamp(delay, 0, 15);
        self.cable_delay[port] = d;
        const sh: u5 = @intCast(4 * port);
        try self.rw(reg.cable_delay, @as(u32, @intCast(d)) << sh, @as(u32, 0xf) << sh);
    }
    fn setCableLengthM(self: *Board, port: usize, m: f64) Error!void {
        const t_step = 1.0 / (2800.0 * self.sample_rate);
        const v = 0.555 * 299_792_458.0;
        const td = 2.0 * m / v + 1.9e-9 + 9.0e-9 + 1.4e-9 + 6.7e-9;
        var d: i32 = @intFromFloat(@floor((td / t_step) + 1.0 + 0.5));
        if (d < 1) d = 1;
        try self.setCableDelay(port, d + 1);
    }
    fn uploadCommandList(self: *Board, list: []const i32, slot: AuxSlot, bank: u32) Error!void {
        const base = 0x4000 + (bank << 10) + (@intFromEnum(slot) << 14);
        for (list, 0..) |cmd, i| try self.ctx.writeReg(device_rhythm, base + @as(u32, @intCast(i)), @bitCast(cmd));
    }
    /// Uploads an AuxCmd3 list, writing only the entries that differ from what the bank is
    /// known to hold (all of them if unknown).
    fn uploadCmd3(self: *Board, list: *const registers.CommandList, bank: u32) Error!usize {
        const base = 0x4000 + (bank << 10) + (@intFromEnum(AuxSlot.cmd3) << 14);
        const known = if (self.cmd3_banks[bank]) |*k| (if (k.len == list.len) k else null) else null;
        // A failed write leaves the bank partly updated: forget what it holds.
        errdefer self.cmd3_banks[bank] = null;
        var writes: usize = 0;
        for (list.slice(), 0..) |cmd, i| {
            if (known) |k| {
                if (k.buf[i] == cmd) continue;
            }
            try self.ctx.writeReg(device_rhythm, base + @as(u32, @intCast(i)), @bitCast(cmd));
            writes += 1;
        }
        self.cmd3_banks[bank] = list.*;
        return writes;
    }
    fn selectAuxBank(self: *Board, port: usize, slot: AuxSlot, bank: u32) Error!void {
        const sh: u5 = @intCast(4 * port);
        try self.rw(reg.auxcmd_bank_1 + @intFromEnum(slot), bank << sh, @as(u32, 0xf) << sh);
    }
    fn selectAuxBankAll(self: *Board, slot: AuxSlot, bank: u32) Error!void {
        for (0..4) |p| try self.selectAuxBank(p, slot, bank);
    }
    fn selectAuxLength(self: *Board, slot: AuxSlot, loop_idx: u32, end_idx: u32) Error!void {
        try self.ctx.writeReg(device_rhythm, reg.loop_auxcmd_index_1 + @intFromEnum(slot), loop_idx);
        try self.ctx.writeReg(device_rhythm, reg.max_auxcmd_index_1 + @intFromEnum(slot), end_idx);
    }
    fn setDspSettle(self: *Board, on: bool) Error!void {
        try self.rw(reg.mode, @as(u32, @intFromBool(on)) << mode_dsp_settle, 1 << mode_dsp_settle);
    }
    fn setDataSource(self: *Board, stream: usize, src: u32) Error!void {
        const sh: u5 = @intCast(4 * (stream % 8));
        try self.rw(reg.data_stream_1_8_sel + @as(u32, @intCast(stream / 8)), src << sh, @as(u32, 0xf) << sh);
    }
    fn enableDataStream(self: *Board, stream: usize, on: bool) Error!void {
        if (self.stream_enabled[stream] != on) {
            const sh: u5 = @intCast(stream);
            try self.rw(reg.data_stream_en, @as(u32, @intFromBool(on)) << sh, @as(u32, 1) << sh);
            self.stream_enabled[stream] = on;
            if (on) self.num_data_streams += 1 else self.num_data_streams -= 1;
        }
    }
    fn enableDac(self: *Board, ch: usize, on: bool) Error!void {
        try self.rw(reg.dac_sel_1 + @as(u32, @intCast(ch)), if (on) 0x400 else 0, 0x400);
    }
    fn selectDacStream(self: *Board, ch: usize, stream: u32) Error!void {
        try self.rw(reg.dac_sel_1 + @as(u32, @intCast(ch)), stream << 5, 0x1f << 5);
    }
    fn selectDacChannel(self: *Board, ch: usize, chan: u32) Error!void {
        try self.rw(reg.dac_sel_1 + @as(u32, @intCast(ch)), chan, 0x1f);
    }
    fn setDacGain(self: *Board, g: u32) Error!void {
        try self.rw(reg.dac_ctl, g << 7, 0x7 << 7);
    }
    fn setAudioNoiseSuppress(self: *Board, n: i32) Error!void {
        try self.rw(reg.dac_ctl, @intCast(std.math.clamp(n, 0, 127)), 0x7f);
    }
    fn setDacThreshold(self: *Board, ch: usize, thr: i32, pol: bool) Error!void {
        const v = (@as(u32, @intCast(std.math.clamp(thr, 0, 65535))) & 0xffff) | (@as(u32, @intFromBool(pol)) << 16);
        try self.ctx.writeReg(device_rhythm, reg.dac_thresh_1 + @as(u32, @intCast(ch)), v);
    }
    fn setTtlMode(self: *Board, m: u32) Error!void {
        try self.rw(reg.mode, m << mode_ttl_out, 1 << mode_ttl_out);
    }
    fn enableExternalFastSettle(self: *Board, on: bool) Error!void {
        try self.rw(reg.external_fast_settle, @as(u32, @intFromBool(on)) << 4, 1 << 4);
    }
    fn setExternalFastSettleChannel(self: *Board, ch: u32) Error!void {
        try self.rw(reg.external_fast_settle, ch & 0xf, 0xf);
    }
    fn enableExternalDigout(self: *Board, port: usize, on: bool) Error!void {
        try self.rw(reg.external_digout_a + @as(u32, @intCast(port)), @as(u32, @intFromBool(on)) << 4, 1 << 4);
    }
    fn setExternalDigoutChannel(self: *Board, port: usize, ch: u32) Error!void {
        try self.rw(reg.external_digout_a + @as(u32, @intCast(port)), ch & 0xf, 0xf);
    }
    fn enableDacHpf(self: *Board, on: bool) Error!void {
        try self.rw(reg.hpf, @as(u32, @intFromBool(on)) << 16, 1 << 16);
    }
    fn setDacHpf(self: *Board, hz: f64) Error!void {
        const b = 1.0 - @exp(-2.0 * std.math.pi * hz / self.sample_rate);
        const cval: i32 = std.math.clamp(@as(i32, @intFromFloat(@floor(65536.0 * b + 0.5))), 1, 65535);
        try self.rw(reg.hpf, @intCast(cval), 0xffff);
    }
    fn enableLeds(self: *Board, on: bool) Error!void {
        try self.rw(reg.mode, @as(u32, @intFromBool(on)) << mode_led_enable, 1 << mode_led_enable);
    }
    fn setClockDivider(self: *Board, ratio: u32) Error!void {
        const r = if (ratio != 1 and ratio % 2 == 1) ratio - 1 else ratio;
        const f = if (r <= 1) 0 else r / 2;
        try self.ctx.writeReg(device_rhythm, reg.sync_clkout_divide, f);
    }
    fn writeTtlOut(self: *Board, word: u16) Error!void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, word, .little);
        try self.ctx.writeFrame(device_ttl, &b);
    }
    fn setDacManual(self: *Board, value: i32) Error!void {
        // Faithful to upstream's conversion (which saturates for any midrange value).
        const bit16 = 1.0 / 65536.0;
        const x = (@as(f64, @floatFromInt(value & 0xffff)) + 5.0) / (10.0 * bit16);
        const v: u32 = @intFromFloat(@min(x, 65535.0));
        var buf: [16]u8 = undefined;
        for (0..4) |i| std.mem.writeInt(u32, buf[i * 4 ..][0..4], v, .little);
        try self.ctx.writeFrame(device_dac, &buf);
    }

    fn setSampleRateHw(self: *Board, hz: u32) Error!void {
        const r = for (sample_rates) |r| {
            if (r.hz == hz) break r;
        } else return error.UnsupportedSampleRate;
        const v = ((r.div & 0xf) << 3) + ((r.sel & 3) << 1) + (r.div_en & 1);
        try self.ctx.writeReg(rhythm_hub_manager, hub_clock_sel, v);
        // DIFF: upstream polls forever; we time out so a wedged board is reported.
        const t0 = Io.Clock.awake.now(self.io);
        while ((try self.ctx.readReg(rhythm_hub_manager, hub_clock_busy)) != 0) {
            if (self.elapsedMs(t0) > 2000) {
                log.err("timeout waiting for the sample-clock PLL", .{});
                return error.PllTimeout;
            }
        }
        self.sample_rate = r.actual;
    }

    // ----------------------------------------------------------------- high level
    /// `Rhd2000ONIBoard::initialize` followed by `AcqBoardONI::initializeBoardInThread`.
    fn initialize(self: *Board) Error!void {
        log.info("initializing ONI acquisition board", .{});
        try self.resetBoard();
        try self.setSampleRateHw(30000);
        for ([_]AuxSlot{ .cmd1, .cmd2, .cmd3 }) |slot| {
            try self.selectAuxBankAll(slot, 0);
            try self.selectAuxLength(slot, 0, 0);
        }
        try self.setContinuous(true);
        try self.setMaxTimestep(std.math.maxInt(u32));
        for (0..4) |p| try self.setCableLengthM(p, 3.0 * 0.3048);
        try self.setDspSettle(false);
        const srcs = [8]u32{ 0, 2, 4, 6, 1, 3, 5, 7 };
        for (0..16) |i| try self.setDataSource(i, srcs[i % 8]);
        try self.enableDataStream(0, true);
        for (1..max_streams) |i| try self.enableDataStream(i, false);
        try self.resetBoard();
        try self.writeTtlOut(0);
        for (0..8) |d| {
            try self.enableDac(d, false);
            try self.selectDacStream(d, 0);
            try self.selectDacChannel(d, 0);
        }
        try self.setDacManual(32768);
        try self.setDacGain(0);
        try self.setAudioNoiseSuppress(0);
        try self.setTtlMode(1);
        for (0..8) |d| try self.setDacThreshold(d, 32768, true);
        try self.enableExternalFastSettle(false);
        try self.setExternalFastSettleChannel(0);
        for (0..4) |p| {
            try self.enableExternalDigout(p, false);
            try self.setExternalDigoutChannel(p, 0);
        }
        try self.enableLeds(true);

        // initializeBoardInThread
        try self.setSampleRate(30000, false);
        for (0..4) |p| try self.setCableLengthM(p, self.settings.cable_length_m[p]);
        try self.selectAuxBankAll(.cmd3, 0);
        try self.setMaxTimestep(init_step);
        try self.setContinuous(false);
        try self.run();
        const t0 = Io.Clock.awake.now(self.io);
        while (self.isRunning()) {
            if (self.elapsedMs(t0) > 2000) {
                log.warn("ADC calibration run did not finish within 2 s", .{});
                break;
            }
        }
        try self.stopHw();
        try self.selectAuxBankAll(.cmd3, if (self.settings.fast_settle) 2 else 1);
        self.acq_clock_hz = try self.ctx.getOptU32(oni.opt.acq_clk_hz);
        log.info("acquisition clock {d} Hz", .{self.acq_clock_hz});
    }

    fn setSampleRate(self: *Board, hz: u32, rescan: bool) Error!void {
        try self.setSampleRateHw(hz);
        self.settings.sample_rate = hz;
        log.info("sample rate set to {d} Hz", .{self.sample_rate});
        if (rescan) try self.checkAllCableDelays();
        try self.updateRegisters();
    }

    fn updateRegisters(self: *Board) Error!void {
        self.regs.defineSampleRate(self.sample_rate);
        if (!self.common_commands_set) {
            self.regs.setDigOutLow();
            var l = self.regs.commandListUpdateDigOut();
            try self.uploadCommandList(l.slice(), .cmd1, 0);
            try self.selectAuxLength(.cmd1, 0, @intCast(l.len - 1));
            try self.selectAuxBankAll(.cmd1, 0);
            l = self.regs.commandListTempSensor();
            try self.uploadCommandList(l.slice(), .cmd2, 0);
            try self.selectAuxLength(.cmd2, 0, @intCast(l.len - 1));
            try self.selectAuxBankAll(.cmd2, 0);
            self.common_commands_set = true;
        }
        const s = &self.settings;
        s.dsp_cutoff = self.regs.setDspCutoffFreq(s.dsp_cutoff);
        const lo = self.regs.setLowerBandwidth(s.lower_bandwidth);
        const up = self.regs.setUpperBandwidth(s.upper_bandwidth);
        log.debug("bandwidth requested {d}..{d} Hz, actual {d:.3}..{d:.1} Hz", .{ s.lower_bandwidth, s.upper_bandwidth, lo, up });
        self.regs.enableDsp(s.dsp_enabled);
        self.regs.enableAux(s.acquire_aux);
        const fast = s.fast_settle;

        var l = self.regs.commandListRegisterConfig(true);
        _ = try self.uploadCmd3(&l, 0);
        try self.selectAuxLength(.cmd3, 0, @intCast(l.len - 1));
        l = self.regs.commandListRegisterConfig(false);
        _ = try self.uploadCmd3(&l, 1);
        try self.selectAuxLength(.cmd3, 0, @intCast(l.len - 1));
        // The spare pair for live changes (`setAmpLive`) gets the same lists now, while idle,
        // so a live change only has to write the entries that differ.
        _ = try self.uploadCmd3(&l, 3);
        self.regs.setFastSettle(true);
        l = self.regs.commandListRegisterConfig(false);
        _ = try self.uploadCmd3(&l, 2);
        _ = try self.uploadCmd3(&l, 4);
        try self.selectAuxLength(.cmd3, 0, @intCast(l.len - 1));
        self.regs.setFastSettle(false);
        self.reg_banks = .{ 1, 2 };
        try self.selectAuxBankAll(.cmd3, if (fast) 2 else 1);
    }

    pub const AmpSettings = struct {
        lower_bandwidth: f64,
        upper_bandwidth: f64,
        dsp_enabled: bool,
        dsp_cutoff: f64,
        fast_settle: bool,
    };

    pub fn ampSettings(self: *const Board) AmpSettings {
        const s = self.settings;
        return .{ .lower_bandwidth = s.lower_bandwidth, .upper_bandwidth = s.upper_bandwidth, .dsp_enabled = s.dsp_enabled, .dsp_cutoff = s.dsp_cutoff, .fast_settle = s.fast_settle };
    }

    /// The bandwidths and DSP cutoff the chips actually get (the nearest the hardware can do),
    /// and when the switch was written.
    pub const AmpActual = struct {
        lower: f64,
        upper: f64,
        dsp_cutoff: f64,
        /// Monotonic time at which the bank switch had been written.
        switched_ns: i96,
        /// Register writes for the list now in use, before the switch.
        writes_before_switch: usize,
    };

    /// Reprograms the amplifier bandwidth, DSP high-pass and fast settle while acquiring,
    /// without stopping. The idle AuxCmd3 bank pair gets the new register-config list that is
    /// needed now (normal or fast settle), all four ports switch to it with one register write,
    /// then the pair's other list is updated. Only entries that differ from the bank's known
    /// contents are written. The lists have identical structure, so a switch that lands
    /// mid-cycle only mixes complete old and new register writes for one cycle (60 samples).
    /// DIFF: stock and oers stop, upload into banks 1/2 and restart (a gap, counter reset).
    /// Writes: Rhythm aux command RAM (AuxCmd3, idle banks) and AUXCMD_BANK_3. Volatile.
    pub fn setAmpLive(self: *Board, a: AmpSettings) Error!AmpActual {
        const s = &self.settings;
        s.lower_bandwidth = a.lower_bandwidth;
        s.upper_bandwidth = a.upper_bandwidth;
        s.dsp_enabled = a.dsp_enabled;
        s.fast_settle = a.fast_settle;
        self.regs.defineSampleRate(self.sample_rate);
        s.dsp_cutoff = self.regs.setDspCutoffFreq(a.dsp_cutoff);
        const lo = self.regs.setLowerBandwidth(a.lower_bandwidth);
        const up = self.regs.setUpperBandwidth(a.upper_bandwidth);
        self.regs.enableDsp(a.dsp_enabled);
        self.regs.enableAux(s.acquire_aux);
        var lists: [2]registers.CommandList = undefined;
        lists[0] = self.regs.commandListRegisterConfig(false);
        self.regs.setFastSettle(true);
        lists[1] = self.regs.commandListRegisterConfig(false);
        self.regs.setFastSettle(false);
        const next: [2]u32 = if (self.reg_banks[0] == 1) .{ 3, 4 } else .{ 1, 2 };
        const now: usize = @intFromBool(a.fast_settle);
        const writes = try self.uploadCmd3(&lists[now], next[now]);
        self.reg_banks = next;
        try self.selectRegBank(a.fast_settle);
        const switched = Io.Clock.awake.now(self.io).nanoseconds;
        const later = try self.uploadCmd3(&lists[1 - now], next[1 - now]);
        log.info("amplifier bandwidth now {d:.3}..{d:.1} Hz, DSP {s} {d:.3} Hz, fast settle {s} (banks {d}/{d}, {d}+{d} writes)", .{ lo, up, if (a.dsp_enabled) "on" else "off", s.dsp_cutoff, if (a.fast_settle) "on" else "off", next[0], next[1], writes, later });
        return .{ .lower = lo, .upper = up, .dsp_cutoff = s.dsp_cutoff, .switched_ns = switched, .writes_before_switch = writes };
    }

    /// All four ports to the normal or fast-settle bank of the current pair, in one write.
    fn selectRegBank(self: *Board, fast: bool) Error!void {
        const b = self.reg_banks[@intFromBool(fast)];
        try self.rw(reg.auxcmd_bank_1 + @intFromEnum(AuxSlot.cmd3), b * 0x1111, 0xffff);
    }

    /// Run `n` frames of the (already started) SPI sequence and collect the aux words.
    fn readScanBlock(self: *Board, sb: *ScanBlock, n: usize) Error!void {
        const ns = self.num_data_streams;
        sb.* = .{ .aux = @splat(@splat(@splat(0))) };
        var t: usize = 0;
        while (t < n) {
            const f = try self.ctx.readFrame();
            defer f.deinit();
            if (f.devIdx() != device_rhythm) continue;
            const full = f.data();
            // DIFF: upstream indexes without a length check; a short frame counts as bad.
            if (full.len < 8 + 12 + 6 * ns or std.mem.readInt(u64, full[8..16], .little) != parser_mod.rhd2000_magic) {
                log.warn("incorrect Rhythm header during scan", .{});
                t += 1;
                continue;
            }
            const d = full[8..];
            for (0..3) |slot| for (0..ns) |s| {
                const o = 12 + 2 * (slot * ns + s);
                sb.aux[s][slot][t] = std.mem.readInt(u16, d[o..][0..2], .little);
            };
            t += 1;
        }
    }

    const ChipId = struct { id: i32, r59: i32 };
    /// Chip id and register 59, or -1/-1 when SPI communication is bad.
    fn intanChipId(sb: *const ScanBlock, stream: usize) ChipId {
        const a = &sb.aux[stream][2];
        const ch = struct {
            fn f(x: *const [init_step]u16, i: usize) u8 {
                return @truncate(x[i]);
            }
        }.f;
        const ok = ch(a, 32) == 'I' and ch(a, 33) == 'N' and ch(a, 34) == 'T' and ch(a, 35) == 'A' and ch(a, 36) == 'N' and ch(a, 24) == 'R' and ch(a, 25) == 'H' and ch(a, 26) == 'D';
        return if (!ok) .{ .id = -1, .r59 = -1 } else .{ .id = a[19], .r59 = a[23] };
    }

    fn goodChip(c: ChipId) bool {
        return c.id == chip_id_rhd2132 or c.id == chip_id_rhd2216 or (c.id == chip_id_rhd2164 and c.r59 == register_59_miso_a);
    }

    fn delayForPort(self: *Board, port: usize, adjust: bool) i32 {
        var d = self.optimum_delay[port];
        if (adjust) d += std.math.clamp(self.settings.cable_delay_adjust[port], 0, 1);
        return std.math.clamp(d, 0, 15);
    }

    /// Runs the scan sequence once and stops the hardware, even if reading failed.
    fn scanOnce(self: *Board, sb: *ScanBlock) Error!void {
        try self.run();
        const r = self.readScanBlock(sb, init_step);
        try self.stopHw();
        return r;
    }

    fn checkAllCableDelays(self: *Board) Error!void {
        var connected: [4]bool = undefined;
        for (0..4) |p| connected[p] = self.headstages[2 * p].connected() or self.headstages[2 * p + 1].connected();
        try self.selectAuxBankAll(.cmd3, 0);
        try self.setMaxTimestep(128 * init_step);
        try self.setContinuous(false);
        var sum: [8]i32 = @splat(0);
        var first: [8]i32 = @splat(-1);
        var second: [8]i32 = @splat(-1);
        var sb: ScanBlock = undefined;
        var delay: i32 = -2;
        while (delay < 2) : (delay += 1) {
            for (0..4) |p| try self.setCableDelay(p, std.math.clamp(self.delayForPort(p, false) + delay, 0, 15));
            try self.scanOnce(&sb);
            for (0..8) |hs| {
                const h = self.headstages[hs];
                if (h.num_streams > 0 and goodChip(intanChipId(&sb, h.first_stream_index))) {
                    sum[hs] += 1;
                    if (first[hs] == -1) first[hs] = delay else if (second[hs] == -1) second[hs] = delay;
                }
            }
        }
        var opt: [8]i32 = @splat(-5);
        for (0..8) |hs| {
            if (sum[hs] == 1 or sum[hs] == 2) opt[hs] = first[hs] else if (sum[hs] > 2) opt[hs] = second[hs];
        }
        for (0..4) |p| {
            if (connected[p]) {
                const shift = @max(opt[2 * p], opt[2 * p + 1]);
                const d = std.math.clamp(self.delayForPort(p, true) + shift, 0, 15);
                try self.setCableDelay(p, d);
                log.debug("port {c} cable delay at {d} Hz: {d}", .{ "ABCD"[p], self.sample_rate, d });
            }
        }
    }

    fn i2cReadByte(self: *Board, dev: u32, i2c_addr: u32, reg_addr: u32) oni.Error!u32 {
        const a = ((reg_addr << 7) | (i2c_addr & 0x7f)) | 0x8000_0000;
        return self.ctx.readReg(dev, a);
    }
    fn eepromDeviceId(self: *Board, port: u32) u32 {
        const dev = device_i2c_raw_a + port * 2;
        for ("OESH", 0..) |c, i| {
            const b = self.i2cReadByte(dev, 0x50, @intCast(i)) catch return 0;
            if (@as(u8, @truncate(b)) != c) return 0;
        }
        const ver = self.i2cReadByte(dev, 0x50, 4) catch return 0;
        if ((ver & 0xff) != 1 and (ver & 0xff) != 2) return 0;
        var id: u32 = 0;
        for (0..4) |i| {
            const b = self.i2cReadByte(dev, 0x50, @intCast(8 + i)) catch return 0;
            id += (b & 0xff) << @intCast(8 * i);
        }
        return id;
    }
    fn bnoConnected(self: *Board, port: u32) bool {
        const dev = device_bno_a + port * 2;
        const t0 = Io.Clock.awake.now(self.io);
        var v: u32 = 2;
        while (v >= 2 and self.elapsedMs(t0) < 1000) {
            v = self.ctx.readReg(dev, 2) catch return false;
        }
        return v == 1;
    }

    fn enableHeadstage(self: *Board, hs: usize, enabled: bool, nstr: usize, chans: usize, bno: bool, chip: i32) void {
        var first_channel: usize = 0;
        for (self.channels_per_stream[0..self.num_streams]) |c| first_channel += c;
        const h = &self.headstages[hs];
        if (enabled) {
            h.first_channel = first_channel;
            h.num_streams = nstr;
            h.channels_per_stream = chans;
            h.has_bno = bno;
            h.chip_id = chip;
            if (nstr > 0) {
                h.first_stream_index = self.num_streams;
                self.enabled_streams[self.num_streams] = @intCast(hs);
                self.channels_per_stream[self.num_streams] = chans;
                self.num_streams += 1;
            }
            if (nstr > 1) {
                self.enabled_streams[self.num_streams] = @intCast(hs + 8);
                self.channels_per_stream[self.num_streams] = chans;
                self.num_streams += 1;
            }
        } else {
            h.num_streams = 0;
            h.has_bno = bno;
        }
    }

    /// Re-derive per-stream channel counts and first channels after the RHD2132 16-channel
    /// option changes, without rescanning. Parsing and layout only; no register writes.
    fn updateChannelCounts(self: *Board) void {
        var first: usize = 0;
        for (&self.headstages, 0..) |*h, hs| {
            if (h.num_streams == 0) continue;
            if (h.chip_id == chip_id_rhd2132) {
                h.channels_per_stream = if (self.settings.rhd2132_16ch[hs]) 16 else 32;
                for (0..h.num_streams) |k| self.channels_per_stream[h.first_stream_index + k] = h.channels_per_stream;
            }
            h.first_channel = first;
            first += h.numChannels();
        }
    }

    fn updateBoardStreams(self: *Board) Error!void {
        for (0..max_streams) |i| {
            if (i < self.num_streams) {
                try self.enableDataStream(i, true);
                try self.setDataSource(i, self.enabled_streams[i]);
            } else {
                try self.enableDataStream(i, false);
            }
        }
        try self.resetBoard();
    }

    fn scanPortsImpl(self: *Board) Error!void {
        try self.checkBoardMem();
        if (self.has_i2c_support) {
            const dev_i2c_enable = 0x1001;
            try self.ctx.writeReg(device_info, dev_i2c_enable, 0xf);
            try self.resetBoard();
            var mask: u32 = 0;
            for (0..4) |pi| {
                const p: u32 = @intCast(pi);
                const bno = self.bnoConnected(p);
                self.has_bno[pi] = bno;
                self.ctx.writeReg(device_bno_a + p * 2, 0, @intFromBool(bno)) catch {};
                const i2c = if (self.ctx.readReg(device_i2c_raw_a + p * 2, 1 + (1 << 15))) |v| v > 0 else |_| false;
                const id = if (i2c) self.eepromDeviceId(p) else 0;
                if (bno) {
                    const map: u32 = switch (id) {
                        0 => blk: {
                            log.debug("BNO without EEPROM on port {d}; assuming low-profile 3D headstage", .{p});
                            break :blk 0b00100100;
                        },
                        0x8000_0002, 0x8000_0003 => 0b10000011000,
                        else => 0b00000100100,
                    };
                    self.ctx.writeReg(device_bno_a + p * 2, 1, map) catch {};
                }
                if (id != 0) log.info("headstage EEPROM id 0x{x} on port {c}", .{ id, "ABCD"[pi] });
                if (bno or (i2c and id != 0)) mask |= @as(u32, 1) << @intCast(pi);
            }
            try self.ctx.writeReg(device_info, dev_i2c_enable, mask);
            try self.resetBoard();
        }

        self.num_streams = 0;
        for (&self.headstages) |*h| h.num_streams = 0;
        const current_rate = self.settings.sample_rate;
        try self.setSampleRate(30000, false);
        for (0..8) |i| try self.setDataSource(i, @intCast(i)); // A1 A2 B1 B2 C1 C2 D1 D2
        for (0..8) |i| try self.enableDataStream(i, true);
        try self.resetBoard();
        try self.selectAuxBankAll(.cmd3, 0);
        try self.setMaxTimestep(128 * init_step);
        try self.setContinuous(false);

        var sum: [8]i32 = @splat(0);
        var first: [8]i32 = @splat(-1);
        var second: [8]i32 = @splat(-1);
        var tmp_chip: [8]i32 = @splat(-1);
        var sb: ScanBlock = undefined;
        var delay: i32 = 0;
        while (delay < 16) : (delay += 1) {
            for (0..4) |p| try self.setCableDelay(p, delay);
            try self.scanOnce(&sb);
            for (0..8) |hs| {
                const c = intanChipId(&sb, hs);
                if (goodChip(c)) {
                    sum[hs] += 1;
                    if (first[hs] == -1) {
                        first[hs] = delay;
                        tmp_chip[hs] = c.id;
                    } else if (second[hs] == -1) {
                        second[hs] = delay;
                        tmp_chip[hs] = c.id;
                    }
                }
            }
        }

        for (0..8) |hs| {
            const bno = self.has_bno[hs / 2];
            if (tmp_chip[hs] > 0 and self.num_streams < max_streams) {
                self.chip_ids[self.num_streams] = tmp_chip[hs];
                if (tmp_chip[hs] == chip_id_rhd2164) {
                    if (self.num_streams < max_streams - 1) {
                        self.chip_ids[self.num_streams + 1] = chip_id_rhd2164_b;
                        self.enableHeadstage(hs, true, 2, 32, bno, tmp_chip[hs]);
                    } else {
                        self.enableHeadstage(hs, true, 1, 32, bno, tmp_chip[hs]);
                    }
                } else {
                    const ch: usize = if (tmp_chip[hs] == chip_id_rhd2132) (if (self.settings.rhd2132_16ch[hs]) 16 else 32) else 16;
                    self.enableHeadstage(hs, true, 1, ch, bno, tmp_chip[hs]);
                }
                log.info("headstage {s} found: {s} ({d} ch)", .{ types.headstage_names[hs], chipName(tmp_chip[hs]), self.headstages[hs].numChannels() });
            } else if (hs % 2 == 1 and bno) {
                self.enableHeadstage(hs, true, 0, 0, true, 0);
            } else {
                self.enableHeadstage(hs, false, 0, 0, false, 0);
            }
        }
        try self.updateBoardStreams();

        var opt: [8]i32 = @splat(0);
        for (0..8) |hs| {
            if (sum[hs] == 1 or sum[hs] == 2) opt[hs] = first[hs] else if (sum[hs] > 2) opt[hs] = second[hs];
        }
        for (0..4) |p| self.optimum_delay[p] = @max(opt[2 * p], opt[2 * p + 1]);
        for (0..4) |p| {
            const d = self.delayForPort(p, true);
            try self.setCableDelay(p, d);
            log.debug("optimum delay port {c}: {d}", .{ "ABCD"[p], d });
        }
        const rescan = !self.initial_scan;
        try self.setSampleRate(current_rate, rescan);
        self.initial_scan = false;
    }

    const StreamChannel = struct { stream: usize, channel: usize };
    fn electrodeToStream(self: *const Board, electrode: usize) ?StreamChannel {
        var acc: usize = 0;
        for (self.channels_per_stream[0..self.num_streams], 0..) |n, i| {
            if (electrode < acc + n) {
                // Physical chip channel. (Stock omits the RHD2132 16-ch offset here, so its DAC
                // outputs an unwired channel in that mode.)
                return .{ .stream = i, .channel = electrode - acc + parser_mod.firstChipChannel(self.chip_ids[i], n) };
            }
            acc += n;
        }
        return null;
    }

    fn applyLiveSettings(self: *Board) Error!void {
        const s = self.settings;
        try self.setTtlMode(@intFromBool(s.ttl_output_mode));
        try self.enableExternalFastSettle(s.fast_ttl_settle != null);
        try self.setExternalFastSettleChannel(s.fast_ttl_settle orelse 0);
        try self.setDacHpf(s.dac_hpf_hz);
        try self.enableDacHpf(s.dac_hpf_enabled);
        try self.enableLeds(s.leds);
        try self.setClockDivider(s.clock_divider);
        try self.setAudioNoiseSuppress(s.noise_slicer);
        for (0..8) |d| try self.applyDac(d);
    }

    fn applyDac(self: *Board, d: usize) Error!void {
        if (self.dac_route[d]) |r| {
            try self.enableDac(d, true);
            try self.selectDacStream(d, @intCast(r.stream));
            try self.selectDacChannel(d, @intCast(r.channel));
            const thr: i32 = @intFromFloat(@abs(@as(f64, r.threshold_uv) / 0.195 + 32768.0));
            try self.setDacThreshold(d, thr, r.threshold_uv >= 0.0);
        } else {
            try self.enableDac(d, false);
        }
    }

    fn numAuxChannels(self: *const Board) usize {
        if (!self.settings.acquire_aux) return 0;
        var n: usize = 0;
        for (self.chip_ids[0..self.num_streams]) |c| {
            if (c != chip_id_rhd2164_b) n += 3;
        }
        return n;
    }

    pub fn layout(self: *const Board) Layout {
        var l: Layout = .{ .sample_rate = self.sample_rate, .hw_clock_hz = @floatFromInt(self.acq_clock_hz) };
        for (self.headstages, 0..) |h, hs| {
            if (h.num_streams == 0) continue;
            l.headstages[l.num_headstages] = .{ .slot = hs, .chip = chipName(h.chip_id), .num_channels = h.numChannels(), .first_channel = h.first_channel, .has_bno = h.has_bno };
            l.num_headstages += 1;
            l.num_electrodes += h.numChannels();
        }
        l.num_aux = self.numAuxChannels();
        l.num_adc = if (self.settings.acquire_adc) 8 else 0;
        return l;
    }

    /// Apply settings while idle (may reprogram the chips).
    pub fn applySettings(self: *Board, new: Settings) Error!void {
        if (self.running) return error.Busy;
        const old = self.settings;
        self.settings = new;
        if (!std.mem.eql(bool, &new.rhd2132_16ch, &old.rhd2132_16ch)) self.updateChannelCounts();
        if (new.usb_block_bytes != old.usb_block_bytes) try self.resetBoard();
        if (new.sample_rate != old.sample_rate) {
            try self.setSampleRate(new.sample_rate, true);
        } else if (!std.mem.eql(i32, &new.cable_delay_adjust, &old.cable_delay_adjust)) {
            try self.checkAllCableDelays();
            try self.updateRegisters();
        } else if (new.lower_bandwidth != old.lower_bandwidth or new.upper_bandwidth != old.upper_bandwidth or new.dsp_enabled != old.dsp_enabled or new.dsp_cutoff != old.dsp_cutoff or new.acquire_aux != old.acquire_aux or new.fast_settle != old.fast_settle) {
            try self.updateRegisters();
        }
        try self.applyLiveSettings();
    }

    pub fn start(self: *Board, health: *Health) Error!void {
        // DIFF: oers also runs IMU-only configurations; oEZ does not record IMU data yet.
        if (self.num_streams == 0) return error.NoHeadstages;
        try self.checkBoardMem();
        try self.applyLiveSettings();
        self.ttl_out = 0;
        try self.writeTtlOut(0);
        self.parser = .init(self.channels_per_stream[0..self.num_streams], self.chip_ids[0..self.num_streams], self.settings.acquire_aux, self.settings.acquire_adc, self.device_id == device_id_v3);
        if (self.pending) |f| f.deinit();
        self.pending = null;
        health.reset();
        self.health = health;
        try self.setContinuous(true);
        try self.run();
        self.running = true;
        log.info("acquisition started: {d} streams, {d} channels", .{ self.num_streams, self.parser.numChannels() });
    }

    /// Number of channels in the blocks `readBlock` fills (valid after `start`).
    pub fn numChannels(self: *const Board) usize {
        return self.parser.numChannels();
    }

    /// Blocks until `blk` is full, or ends early at a discontinuity (the next call starts the
    /// new run). Never allocates.
    pub fn readBlock(self: *Board, blk: *Block) Error!void {
        const health = self.health.?;
        blk.clear();
        std.debug.assert(blk.num_channels == self.parser.numChannels());
        const has_rhythm = self.num_streams > 0;
        while (true) {
            const f = if (self.pending) |p| p else self.ctx.readFrame() catch |e| {
                health.add(&health.read_errors, 1);
                return e;
            };
            self.pending = null;
            health.add(&health.frames, 1);
            if (f.devIdx() == device_rhythm and has_rhythm) {
                const d = f.data();
                switch (self.parser.parse(d[@min(8, d.len)..], f.time(), blk, health)) {
                    .discontinuous => {
                        self.pending = f;
                        return;
                    },
                    .appended, .bad => f.deinit(),
                }
                if (blk.full()) return;
            } else {
                self.handleSide(f, health);
                f.deinit();
            }
        }
    }

    fn handleSide(self: *Board, f: oni.Frame, health: *Health) void {
        const dev = f.devIdx();
        if (dev == device_memory and self.has_memmon) {
            const d = f.data();
            if (d.len >= 12) {
                const used = std.mem.readInt(u32, d[8..12], .little);
                const milli: u64 = @intFromFloat(100_000.0 * @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(@max(self.total_memory, 1))));
                health.hw_buffer_milli_pct.store(milli, .monotonic);
                _ = health.hw_buffer_peak_milli_pct.fetchMax(milli, .monotonic);
            }
            return;
        }
        // TODO(oEZ): BNO055 IMU frames (oers records them; the rig's headstages have none).
        if (!self.bno_warned and dev >= device_bno_a and dev <= device_bno_a + 6 and (dev - device_bno_a) % 2 == 0) {
            self.bno_warned = true;
            log.warn("IMU frames arrive but are not recorded yet", .{});
        }
    }

    /// Commands that may be applied while acquiring. Writes Rhythm registers (DAC routing,
    /// HPF, LEDs, MODE) or a TTL-out frame; all volatile.
    pub fn live(self: *Board, cmd: LiveCommand) Error!void {
        switch (cmd) {
            .set_ttl_out => |w| {
                self.ttl_out = w;
                try self.writeTtlOut(w);
            },
            .dac_route => |r| if (r.dac < 8) {
                self.dac_route[r.dac] = if (r.electrode) |e| (if (self.electrodeToStream(e)) |sc| DacRoute{ .stream = sc.stream, .channel = sc.channel, .threshold_uv = r.threshold_uv } else null) else null;
                try self.applyDac(r.dac);
            },
            .set_leds => |on| {
                self.settings.leds = on;
                try self.enableLeds(on);
            },
            .set_dac_hpf => |h| {
                self.settings.dac_hpf_enabled = h.enabled;
                self.settings.dac_hpf_hz = h.hz;
                try self.setDacHpf(h.hz);
                try self.enableDacHpf(h.enabled);
            },
            .set_noise_slicer => |n| {
                self.settings.noise_slicer = n;
                try self.setAudioNoiseSuppress(n);
            },
            .set_ttl_mode => |on| {
                self.settings.ttl_output_mode = on;
                try self.setTtlMode(@intFromBool(on));
            },
            .set_fast_ttl_settle => |ch| {
                self.settings.fast_ttl_settle = ch;
                try self.enableExternalFastSettle(ch != null);
                try self.setExternalFastSettleChannel(ch orelse 0);
            },
            .set_clock_divider => |d| {
                self.settings.clock_divider = d;
                try self.setClockDivider(d);
            },
        }
    }

    pub fn stop(self: *Board) Error!void {
        if (!self.running) return;
        if (self.pending) |f| f.deinit();
        self.pending = null;
        self.running = false;
        try self.setContinuous(false);
        try self.setMaxTimestep(0);
        try self.stopHw();
        try self.resetBoard();
        log.info("acquisition stopped", .{});
    }
};
