//! Types shared by the board driver, the acquisition loop and consumers.

const std = @import("std");
const Atomic = std.atomic.Value;

/// RHD2000 amplifier channels: µV per LSB.
pub const electrode_uv_per_bit: f64 = 0.195;
/// RHD2000 auxiliary inputs: V per LSB. Stored as raw − 32768, so values are the true voltage
/// minus 1.2255 V (same convention as stock).
pub const aux_v_per_bit: f64 = 0.0000374;
/// Board ADC inputs: V per LSB.
pub const adc_v_per_bit: f64 = 0.00015258789;

pub const max_streams = 16;
pub const max_channels = max_streams * 32 + 3 * max_streams + 8;

/// A contiguous run of the main stream. `data` is sample-major (`data[s * nch + ch]`), int16,
/// the representation that is written to disk.
pub const Block = struct {
    first_sample: i64 = 0,
    num_channels: usize,
    len: usize = 0,
    capacity: usize,
    data: []i16,
    /// Board acquisition-clock ticks, one per sample (see `Layout.hw_clock_hz`).
    hw_time: []u64,
    /// Digital input word, one per sample.
    ttl: []u16,
    /// Monotonic (`.awake`) nanoseconds when the acquisition thread completed the block.
    acquired_ns: i96 = 0,

    pub fn init(gpa: std.mem.Allocator, num_channels: usize, capacity: usize) !Block {
        const data = try gpa.alloc(i16, num_channels * capacity);
        errdefer gpa.free(data);
        const hw_time = try gpa.alloc(u64, capacity);
        errdefer gpa.free(hw_time);
        const ttl = try gpa.alloc(u16, capacity);
        return .{ .num_channels = num_channels, .capacity = capacity, .data = data, .hw_time = hw_time, .ttl = ttl };
    }
    pub fn deinit(self: *Block, gpa: std.mem.Allocator) void {
        gpa.free(self.data);
        gpa.free(self.hw_time);
        gpa.free(self.ttl);
    }
    pub fn clear(self: *Block) void {
        self.len = 0;
    }
    pub fn full(self: *const Block) bool {
        return self.len == self.capacity;
    }
    pub fn sample(self: *const Block, s: usize) []const i16 {
        return self.data[s * self.num_channels ..][0..self.num_channels];
    }
    pub fn samples(self: *const Block) []const i16 {
        return self.data[0 .. self.len * self.num_channels];
    }
};

/// Lock-free health counters, written by the acquisition thread, read by anyone.
pub const Health = struct {
    frames: Atomic(u64) = .init(0),
    samples: Atomic(u64) = .init(0),
    /// Samples missing according to the hardware sample counter.
    dropped_samples: Atomic(u64) = .init(0),
    discontinuities: Atomic(u64) = .init(0),
    bad_frames: Atomic(u64) = .init(0),
    /// Board DRAM buffer usage, in 1/1000 percent.
    hw_buffer_milli_pct: Atomic(u64) = .init(0),
    /// Highest `hw_buffer_milli_pct` seen since start.
    hw_buffer_peak_milli_pct: Atomic(u64) = .init(0),
    read_errors: Atomic(u64) = .init(0),

    pub fn add(_: *Health, a: *Atomic(u64), n: u64) void {
        _ = a.fetchAdd(n, .monotonic);
    }

    pub fn reset(self: *Health) void {
        self.* = .{};
    }
};

pub const Settings = struct {
    sample_rate: u32 = 30000,
    lower_bandwidth: f64 = 1.0,
    upper_bandwidth: f64 = 7500.0,
    dsp_enabled: bool = true,
    dsp_cutoff: f64 = 0.5,
    acquire_aux: bool = false,
    acquire_adc: bool = false,
    /// Per-port cable delay adjustment (0 or +1 step), as in the stock plugin.
    cable_delay_adjust: [4]i32 = @splat(0),
    cable_length_m: [4]f32 = @splat(0.914),
    fast_settle: bool = false,
    ttl_output_mode: bool = false,
    dac_hpf_enabled: bool = false,
    dac_hpf_hz: f64 = 300.0,
    fast_ttl_settle: ?u8 = null,
    noise_slicer: i32 = 0,
    /// Board status LEDs. Off by default: their driver puts a ~1.06 kHz tone on the analog
    /// inputs (floating ADC noise rose ~9× with them on; neural channels are unaffected).
    leds: bool = false,
    /// Per headstage slot (A1, A2, B1, … D2): treat an RHD2132 as a 16-channel headstage,
    /// recording chip channels 8–23 only (stock "half channels" mode). Parsing and layout
    /// only, no register writes.
    rhd2132_16ch: [8]bool = @splat(false),
    clock_divider: u32 = 1,
    /// liboni block read size in bytes. Smaller = lower latency, more USB transactions.
    usb_block_bytes: u32 = 8 * 1024,
    /// Samples per block handed to the pipeline.
    block_samples: usize = 32,
};

pub const headstage_names = [8][]const u8{ "A1", "A2", "B1", "B2", "C1", "C2", "D1", "D2" };

pub const HeadstageInfo = struct {
    /// Slot 0..8 (A1, A2, B1, … D2).
    slot: usize,
    chip: []const u8,
    num_channels: usize,
    first_channel: usize,
    has_bno: bool,
};

/// Describes the main continuous stream: electrodes (headstage order), then AUX, then ADC.
pub const Layout = struct {
    sample_rate: f64,
    hw_clock_hz: f64,
    headstages: [8]HeadstageInfo = undefined,
    num_headstages: usize = 0,
    num_electrodes: usize = 0,
    num_aux: usize = 0,
    num_adc: usize = 0,
    ttl_lines: usize = 8,

    pub fn numChannels(self: *const Layout) usize {
        return self.num_electrodes + self.num_aux + self.num_adc;
    }
    pub fn headstageSlice(self: *const Layout) []const HeadstageInfo {
        return self.headstages[0..self.num_headstages];
    }

    /// An electrode channel by headstage and its number there ("A1-5"), or "ch 37" (the
    /// channel's number in the stream, from 1) if it is not an electrode. "" if `buf` is
    /// too short.
    pub fn channelName(self: *const Layout, buf: []u8, ch: usize) []const u8 {
        for (self.headstageSlice()) |h| {
            if (ch >= h.first_channel and ch < h.first_channel + h.num_channels)
                return std.fmt.bufPrint(buf, "{s}-{d}", .{ headstage_names[h.slot], ch - h.first_channel + 1 }) catch "";
        }
        return std.fmt.bufPrint(buf, "ch {d}", .{ch + 1}) catch "";
    }
};

test "channel names: electrodes by headstage, the rest by number" {
    var l: Layout = .{ .sample_rate = 30000, .hw_clock_hz = 50e6, .num_electrodes = 48, .num_aux = 6, .num_adc = 8 };
    l.headstages[0] = .{ .slot = 0, .chip = "RHD2132", .num_channels = 32, .first_channel = 0, .has_bno = false };
    l.headstages[1] = .{ .slot = 2, .chip = "RHD2216", .num_channels = 16, .first_channel = 32, .has_bno = false };
    l.num_headstages = 2;
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("A1-1", l.channelName(&buf, 0));
    try std.testing.expectEqualStrings("A1-32", l.channelName(&buf, 31));
    try std.testing.expectEqualStrings("B1-1", l.channelName(&buf, 32));
    try std.testing.expectEqualStrings("B1-16", l.channelName(&buf, 47));
    // AUX (48..53) and ADC (54..61) channels have no headstage name.
    try std.testing.expectEqualStrings("ch 49", l.channelName(&buf, 48));
    try std.testing.expectEqualStrings("ch 62", l.channelName(&buf, 61));
    var short: [3]u8 = undefined;
    try std.testing.expectEqualStrings("", l.channelName(&short, 31));
}

/// Commands that may be applied while acquiring (executed by the acquisition thread).
pub const LiveCommand = union(enum) {
    set_ttl_out: u16,
    /// Route an electrode (global electrode index) to a board DAC, or disable it with null.
    dac_route: struct { dac: usize, electrode: ?usize, threshold_uv: f32 },
    set_leds: bool,
    set_dac_hpf: struct { enabled: bool, hz: f64 },
    set_noise_slicer: i32,
    /// TTL outputs 1–8 driven by the DAC threshold comparators instead of software.
    set_ttl_mode: bool,
    /// Amplifier fast settle while this TTL input is high (null = off).
    set_fast_ttl_settle: ?u8,
    /// Sync clock-out divider.
    set_clock_divider: u32,
};
