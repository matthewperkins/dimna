//! Pure parser for Rhythm sample frames (the ONI `DEVICE_RHYTHM` payload). Port of oers
//! `crates/rhythm/src/parser.rs`.
//!
//! Layout after the 8-byte ONI hub timestamp (little-endian u16 unless noted):
//!
//!     magic u64 | counter u32 | aux[3][ns] | amp[32][ns] | filler[ns] | adc[8] | ttl_in | ttl_out
//!
//! (`[a][b]` = outer a, inner b: the stream index varies fastest.)

const std = @import("std");
const types = @import("types.zig");
const Block = types.Block;
const Health = types.Health;
const max_streams = types.max_streams;

pub const rhd2000_magic: u64 = 0xc691199927021942;
pub const chip_id_rhd2132: i32 = 1;
pub const chip_id_rhd2216: i32 = 2;
pub const chip_id_rhd2164: i32 = 4;
pub const chip_id_rhd2164_b: i32 = 1000;
/// First chip channel recorded from an RHD2132 used as a 16-channel headstage (stock:
/// `RHD2132_16CH_OFFSET`). Such headstages wire chip channels 8–23.
pub const rhd2132_16ch_offset = 8;

/// First chip channel read from a stream: 8 for an RHD2132 in 16-channel mode, else 0.
/// Same rule as stock (`chipId == RHD2132 && nChans == 16`).
pub fn firstChipChannel(chip_id: i32, channels: usize) usize {
    return if (chip_id == chip_id_rhd2132 and channels == 16) rhd2132_16ch_offset else 0;
}

pub const ParseResult = enum {
    /// Sample appended to the block.
    appended,
    /// The frame starts a new contiguous run: hand the block on and re-submit the frame.
    discontinuous,
    /// Malformed frame (bad magic or size); skipped.
    bad,
};

pub const RhythmParser = struct {
    num_streams: usize = 0,
    channels_per_stream: [max_streams]usize = @splat(0),
    chip_ids: [max_streams]i32 = @splat(0),
    acquire_aux: bool = false,
    acquire_adc: bool = false,
    adc_v3: bool = false,
    aux_samples: [max_streams][3]i16 = @splat(@splat(0)),
    aux_hold: [3 * max_streams]i16 = @splat(0),
    last_counter: ?u32 = null,
    counter_hi: i64 = 0,

    pub fn init(
        channels_per_stream: []const usize,
        chip_ids: []const i32,
        acquire_aux: bool,
        acquire_adc: bool,
        adc_v3: bool,
    ) RhythmParser {
        std.debug.assert(channels_per_stream.len == chip_ids.len and chip_ids.len <= max_streams);
        var p: RhythmParser = .{ .num_streams = chip_ids.len, .acquire_aux = acquire_aux, .acquire_adc = acquire_adc, .adc_v3 = adc_v3 };
        @memcpy(p.channels_per_stream[0..p.num_streams], channels_per_stream);
        @memcpy(p.chip_ids[0..p.num_streams], chip_ids);
        return p;
    }

    pub fn reset(self: *RhythmParser) void {
        self.aux_samples = @splat(@splat(0));
        self.aux_hold = @splat(0);
        self.last_counter = null;
        self.counter_hi = 0;
    }

    pub fn numAux(self: *const RhythmParser) usize {
        if (!self.acquire_aux) return 0;
        var n: usize = 0;
        for (self.chip_ids[0..self.num_streams]) |c| {
            if (c != chip_id_rhd2164_b) n += 3;
        }
        return n;
    }

    pub fn numElectrodes(self: *const RhythmParser) usize {
        var n: usize = 0;
        for (self.channels_per_stream[0..self.num_streams]) |c| n += c;
        return n;
    }

    pub fn numChannels(self: *const RhythmParser) usize {
        return self.numElectrodes() + self.numAux() + @as(usize, if (self.acquire_adc) 8 else 0);
    }

    /// Payload size in bytes (excluding the 8-byte hub timestamp).
    pub fn payloadLen(self: *const RhythmParser) usize {
        const ns = self.num_streams;
        return 12 + 2 * (3 * ns + 32 * ns + ns + 8 + 2);
    }

    /// `d` is the Rhythm payload (frame data without the 8-byte hub timestamp).
    pub fn parse(self: *RhythmParser, d: []const u8, hw_time: u64, blk: *Block, health: *Health) ParseResult {
        if (d.len < self.payloadLen() or std.mem.readInt(u64, d[0..8], .little) != rhd2000_magic) {
            health.add(&health.bad_frames, 1);
            return .bad;
        }
        std.debug.assert(blk.num_channels == self.numChannels());
        std.debug.assert(!blk.full());
        const counter = std.mem.readInt(u32, d[8..12], .little);
        const delta: ?u32 = if (self.last_counter) |last| counter -% last else null;
        const sample_number: i64 = if (delta) |dl| self.counter_hi + dl else 0;
        if (blk.len > 0 and sample_number != blk.first_sample + @as(i64, @intCast(blk.len))) {
            return .discontinuous;
        }
        if (delta) |dl| {
            if (dl != 1) {
                health.add(&health.discontinuities, 1);
                health.add(&health.dropped_samples, dl -% 1);
            }
        }
        self.last_counter = counter;
        self.counter_hi = sample_number;
        if (blk.len == 0) blk.first_sample = sample_number;

        const ns = self.num_streams;
        const word = struct {
            fn f(b: []const u8, o: usize) u16 {
                return std.mem.readInt(u16, b[o..][0..2], .little);
            }
        }.f;
        const centre = struct {
            fn f(w: u16) i16 {
                return @intCast(@as(i32, w) - 32768);
            }
        }.f;
        const row = blk.data[blk.len * blk.num_channels ..][0..blk.num_channels];
        var ch: usize = 0;

        const aux_base: usize = 12;
        const amp_base = aux_base + 6 * ns;
        for (0..ns) |s| {
            var o = amp_base + 2 * s + 2 * ns * firstChipChannel(self.chip_ids[s], self.channels_per_stream[s]);
            for (0..self.channels_per_stream[s]) |_| {
                row[ch] = centre(word(d, o));
                ch += 1;
                o += 2 * ns;
            }
        }
        if (self.acquire_aux) {
            // AuxCmd2 cycles AuxIn1..3 plus one other command; values are held between
            // updates exactly as the stock plugin does.
            const aux_num: usize = @intCast((counter +% 3) % 4);
            var ai = aux_base + 2 * ns;
            var k_all: usize = 0;
            for (0..ns) |s| {
                if (self.chip_ids[s] != chip_id_rhd2164_b) {
                    if (aux_num < 3) self.aux_samples[s][aux_num] = centre(word(d, ai));
                    for (0..3) |k| {
                        if (aux_num == 3) self.aux_hold[k_all] = self.aux_samples[s][k];
                        row[ch] = self.aux_hold[k_all];
                        ch += 1;
                        k_all += 1;
                    }
                }
                ai += 2;
            }
        }
        const adc_base = amp_base + 64 * ns + 2 * ns;
        if (self.acquire_adc) {
            const bv = types.adc_v_per_bit;
            for (0..8) |k| {
                const raw: f64 = @floatFromInt(word(d, adc_base + 2 * k));
                const volts = if (self.adc_v3) -(bv * raw - 5.0) else bv * raw - 5.0 - 0.4096;
                row[ch] = @intFromFloat(std.math.clamp(@round(volts / bv), -32768.0, 32767.0));
                ch += 1;
            }
        }
        std.debug.assert(ch == blk.num_channels);
        blk.ttl[blk.len] = word(d, adc_base + 16);
        blk.hw_time[blk.len] = hw_time;
        blk.len += 1;
        health.add(&health.samples, 1);
        return .appended;
    }
};

// ---------------------------------------------------------------------------- tests

const testing = std.testing;

/// Build a synthetic Rhythm payload into `buf`; returns its length.
fn encodePayload(
    buf: []u8,
    ns: usize,
    counter: u32,
    aux: *const fn (usize, usize) u16,
    amp: *const fn (usize, usize) u16,
    adc: [8]u16,
    ttl: u16,
) usize {
    var o: usize = 0;
    const put16 = struct {
        fn f(b: []u8, off: *usize, v: u16) void {
            std.mem.writeInt(u16, b[off.*..][0..2], v, .little);
            off.* += 2;
        }
    }.f;
    std.mem.writeInt(u64, buf[0..8], rhd2000_magic, .little);
    std.mem.writeInt(u32, buf[8..12], counter, .little);
    o = 12;
    for (0..3) |c| for (0..ns) |s| put16(buf, &o, aux(s, c));
    for (0..32) |c| for (0..ns) |s| put16(buf, &o, amp(s, c));
    for (0..ns) |_| put16(buf, &o, 0);
    for (adc) |a| put16(buf, &o, a);
    put16(buf, &o, ttl);
    put16(buf, &o, 0);
    return o;
}

fn ampVal(s: usize, c: usize) u16 {
    return @intCast(32768 + 100 * s + c);
}
fn zero(_: usize, _: usize) u16 {
    return 0;
}
fn mid(_: usize, _: usize) u16 {
    return 32768;
}

test "maps streams and channels like upstream" {
    // Three streams: RHD2132 (32 ch), RHD2164 A+B (32+32).
    var p = RhythmParser.init(&.{ 32, 32, 32 }, &.{ 1, 4, chip_id_rhd2164_b }, false, true, false);
    var h: Health = .{};
    var b = try Block.init(testing.allocator, p.numChannels(), 4);
    defer b.deinit(testing.allocator);
    var buf: [2048]u8 = undefined;
    const n = encodePayload(&buf, 3, 7, zero, ampVal, .{ 0, 32768, 65535, 0, 0, 0, 0, 0 }, 0b1010_0101);
    try testing.expectEqual(p.payloadLen(), n);
    try testing.expectEqual(.appended, p.parse(buf[0..n], 0, &b, &h));
    try testing.expectEqual(96 + 8, b.num_channels);
    for (0..3) |s| for (0..32) |c| try testing.expectEqual(@as(i16, @intCast(100 * s + c)), b.data[s * 32 + c]);
    // ADC: raw 32768 -> 0 V - 0.4096 V on non-v3 boards.
    const v = @as(f64, @floatFromInt(b.data[96 + 1])) * types.adc_v_per_bit;
    try testing.expect(@abs(v + 0.4096) < 1e-3);
    try testing.expectEqual(0b1010_0101, b.ttl[0]);
}

test "RHD2132 in 16-channel mode reads chip channels 8 to 23" {
    // Stream 0: RHD2132 in 16-channel mode; stream 1: RHD2216 (16 ch, no offset).
    var p = RhythmParser.init(&.{ 16, 16 }, &.{ 1, 2 }, false, false, false);
    var h: Health = .{};
    var b = try Block.init(testing.allocator, p.numChannels(), 4);
    defer b.deinit(testing.allocator);
    try testing.expectEqual(32, p.numChannels());
    var buf: [2048]u8 = undefined;
    const n = encodePayload(&buf, 2, 0, zero, ampVal, @splat(0), 0);
    try testing.expectEqual(p.payloadLen(), n);
    try testing.expectEqual(.appended, p.parse(buf[0..n], 0, &b, &h));
    for (0..16) |c| {
        try testing.expectEqual(@as(i16, @intCast(8 + c)), b.data[c]);
        try testing.expectEqual(@as(i16, @intCast(100 + c)), b.data[16 + c]);
    }
    try testing.expectEqual(0, firstChipChannel(1, 32));
    try testing.expectEqual(0, firstChipChannel(2, 16));
    try testing.expectEqual(8, firstChipChannel(1, 16));
}

var aux_test_counter: u32 = 0;
fn auxSlot1(s: usize, slot: usize) u16 {
    return if (slot == 1) @intCast(32768 + 10 * aux_test_counter + s) else 0;
}

test "aux sample-and-hold skips RHD2164 B" {
    var p = RhythmParser.init(&.{ 32, 32 }, &.{ 4, chip_id_rhd2164_b }, true, false, false);
    var h: Health = .{};
    var b = try Block.init(testing.allocator, p.numChannels(), 8);
    defer b.deinit(testing.allocator);
    var buf: [2048]u8 = undefined;
    // Counters 1, 2, 3 carry aux 0, 1, 2 (aux_num = (c + 3) % 4); counter 4 latches them.
    var c: u32 = 1;
    while (c <= 4) : (c += 1) {
        aux_test_counter = c;
        const n = encodePayload(&buf, 2, c, auxSlot1, mid, @splat(0), 0);
        try testing.expectEqual(.appended, p.parse(buf[0..n], 0, &b, &h));
    }
    try testing.expectEqual(3, p.numAux());
    try testing.expectEqualSlices(i16, &.{ 10, 20, 30 }, b.sample(3)[64..67]);
}

test "detects gaps without double counting" {
    var p = RhythmParser.init(&.{32}, &.{1}, false, false, false);
    var h: Health = .{};
    var b = try Block.init(testing.allocator, 32, 8);
    defer b.deinit(testing.allocator);
    var buf: [2048]u8 = undefined;
    const f = struct {
        fn f(bf: []u8, counter: u32) []const u8 {
            return bf[0..encodePayload(bf, 1, counter, zero, mid, @splat(0), 0)];
        }
    }.f;
    try testing.expectEqual(.appended, p.parse(f(&buf, 100), 0, &b, &h));
    try testing.expectEqual(.appended, p.parse(f(&buf, 101), 0, &b, &h));
    // Gap: 102..104 missing.
    try testing.expectEqual(.discontinuous, p.parse(f(&buf, 105), 0, &b, &h));
    try testing.expectEqual(0, h.dropped_samples.load(.monotonic));
    b.clear();
    try testing.expectEqual(.appended, p.parse(f(&buf, 105), 0, &b, &h));
    try testing.expectEqual(5, b.first_sample);
    try testing.expectEqual(3, h.dropped_samples.load(.monotonic));
    try testing.expectEqual(1, h.discontinuities.load(.monotonic));
    // Counter wrap-around is continuous.
    p = RhythmParser.init(&.{32}, &.{1}, false, false, false);
    b.clear();
    try testing.expectEqual(.appended, p.parse(f(&buf, std.math.maxInt(u32)), 0, &b, &h));
    try testing.expectEqual(.appended, p.parse(f(&buf, 0), 0, &b, &h));
    try testing.expectEqual(2, b.len);
}

test "rejects bad magic" {
    var p = RhythmParser.init(&.{32}, &.{1}, false, false, false);
    var h: Health = .{};
    var b = try Block.init(testing.allocator, 32, 8);
    defer b.deinit(testing.allocator);
    var buf: [2048]u8 = undefined;
    const n = encodePayload(&buf, 1, 0, zero, zero, @splat(0), 0);
    buf[0] ^= 1;
    try testing.expectEqual(.bad, p.parse(buf[0..n], 0, &b, &h));
    try testing.expectEqual(0, b.len);
}
