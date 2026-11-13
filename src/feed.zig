//! What the display's sample history holds, and the display filters.
//!
//! Each sample of the history is a row of `width` int16: the `nch` acquired channels as they
//! came, then for every electrode panel what it shows of its channels (the panel's "slot"):
//! its rows that are not hidden, one column each in order, band-passed or not row by row.
//! So one panel can show fast signals filtered beside slow ones as they are, leave rows
//! out, and two panels can show the same channels differently.
//! A TTL panel's slot holds its input lines as square waves, one column per line.
//!
//! Filtering happens here, on the display's thread, as blocks arrive: a few million biquad
//! steps a second. It never touches acquisition or what is recorded.
//!
//! A panel's common average reference is applied here too: the mean of its reference rows,
//! taken from the samples as acquired, is subtracted from its subtract rows before the
//! filter (or instead of one, for rows shown unfiltered).
//!
//! When a panel's corners or reference change, the recent past of its slot is filtered again from a copy
//! of the raw samples kept here (`refilter`), so the whole trace changes, not only what
//! arrives afterwards.

const std = @import("std");
const types = @import("types.zig");
const panels = @import("panels.zig");
const dsp = @import("dsp.zig");

const Slot = struct {
    first_ch: usize,
    rows: usize,
    /// First column of the slot in a history row.
    column: usize,
    cfg: Config,
    band: dsp.Band,
    /// One per channel.
    states: []dsp.Band.State,
};

/// What a slot holds, from its panel's settings.
const Config = struct {
    low_hz: f64,
    high_hz: f64,
    /// The rows that go through the band (the others are passed as they are).
    band_rows: panels.RowSet,
    hidden: panels.RowSet,
    car: bool,
    ref: panels.RowSet,
    sub: panels.RowSet,

    fn of(p: *const panels.Panel) Config {
        const car = p.carActive();
        var band_rows: panels.RowSet = .{};
        for (0..@min(p.rows, panels.max_rows)) |r| band_rows.set(r, p.rowFiltered(r));
        return .{
            .low_hz = p.filter.low_hz,
            .high_hz = p.filter.high_hz,
            .band_rows = band_rows,
            .hidden = p.per_row.hidden,
            .car = car,
            .ref = if (car) p.reference.ref else .{},
            .sub = if (car) p.reference.sub else .{},
        };
    }

    fn eql(a: *const Config, b: *const Config) bool {
        return a.low_hz == b.low_hz and a.high_hz == b.high_hz and a.band_rows.eql(&b.band_rows) and a.hidden.eql(&b.hidden) and
            a.car == b.car and a.ref.eql(&b.ref) and a.sub.eql(&b.sub);
    }
};

const TtlSlot = struct {
    column: usize,
    /// Bit masks of the lines, in row order.
    masks: [8]u16,
    rows: usize,
};

pub const Feed = struct {
    ttl_slots: [panels.max_panels]TtlSlot = undefined,
    num_ttl_slots: usize = 0,
    nch: usize,
    width: usize,
    fs: f64,
    slots: [panels.max_panels]Slot = undefined,
    num_slots: usize = 0,
    /// Which slot each panel has, if any.
    slot_of: [panels.max_panels]?usize = @splat(null),
    /// The longest block `rows` takes (samples).
    max_block: usize,
    /// Scratch for the rows of one block: `max_block` rows.
    row_buf: []i16 = &.{},
    /// Scratch for a slot's reference, one value per sample: at least `max_block`
    /// (`refilter` may grow it).
    mean_buf: []f64 = &.{},
    /// The raw samples of the last `raw_cap` (a power of two) sample numbers, `nch` each.
    raw: []i16,
    raw_cap: usize,
    /// Sample numbers held in `raw`: [`oldest`, `newest`).
    oldest: i64 = 0,
    newest: i64 = 0,
    started: bool = false,

    /// Gives every electrode panel of `set` a slot (`Panel.slot`) and keeps `keep_samples`
    /// of raw history (rounded up to a power of two) for refiltering. `rows` takes blocks of
    /// up to `max_block` samples.
    pub fn init(gpa: std.mem.Allocator, layout: *const types.Layout, set: *panels.Set, keep_samples: usize, max_block: usize) !Feed {
        const nch = layout.numChannels();
        const cap = try std.math.ceilPowerOfTwo(usize, keep_samples);
        var self: Feed = .{
            .nch = nch,
            .width = nch,
            .fs = layout.sample_rate,
            .max_block = max_block,
            .raw = try gpa.alloc(i16, cap * nch),
            .raw_cap = cap,
        };
        errdefer self.deinit(gpa);
        @memset(self.raw, 0);
        self.mean_buf = try gpa.alloc(f64, max_block);
        for (set.slice(), 0..) |*p, i| {
            if (p.kind == .ttl) {
                var slot: TtlSlot = .{ .column = self.width, .masks = @splat(0), .rows = p.rows };
                for (0..p.rows) |r| slot.masks[r] = @as(u16, 1) << @intCast(std.math.clamp(p.ttl_lines[r], 1, 16) - 1);
                p.slot = @intCast(self.width);
                self.ttl_slots[self.num_ttl_slots] = slot;
                self.num_ttl_slots += 1;
                self.width += p.rows;
                continue;
            }
            if (p.kind != .electrode) continue;
            const states = try gpa.alloc(dsp.Band.State, p.rows);
            @memset(states, @splat(.{}));
            p.slot = @intCast(self.width);
            self.slot_of[i] = self.num_slots;
            const cfg: Config = .of(p);
            self.slots[self.num_slots] = .{
                .first_ch = p.first_ch,
                .rows = p.rows,
                .column = self.width,
                .cfg = cfg,
                .band = .init(cfg.low_hz, cfg.high_hz, self.fs),
                .states = states,
            };
            self.num_slots += 1;
            self.width += p.rows;
        }
        self.row_buf = try gpa.alloc(i16, max_block * self.width);
        return self;
    }

    /// Forgets the filters' states: the next block is taken as the start of a signal (each
    /// filter settles on its first sample). For feeding a stretch from somewhere else in
    /// a recording.
    pub fn restart(self: *Feed) void {
        self.started = false;
    }

    pub fn deinit(self: *Feed, gpa: std.mem.Allocator) void {
        for (self.slots[0..self.num_slots]) |s| gpa.free(s.states);
        gpa.free(self.row_buf);
        gpa.free(self.mean_buf);
        gpa.free(self.raw);
    }

    /// The history rows for a block of raw samples (`nch` interleaved) that starts at sample
    /// number `first`, with its digital input words `ttl` (one per sample). The result is
    /// valid until the next call. A block longer than `max_block` is refused, untouched.
    pub fn rows(self: *Feed, first: i64, samples: []const i16, ttl: []const u16) error{BlockTooLong}![]const i16 {
        const nch = self.nch;
        const width = self.width;
        const count = samples.len / nch;
        if (count > self.max_block) return error.BlockTooLong;
        const out = self.row_buf[0 .. count * width];
        const starting = !self.started and count > 0;
        if (starting) {
            self.oldest = first;
            self.started = true;
        }
        const mask = self.raw_cap - 1;
        for (0..count) |i| {
            const in = samples[i * nch ..][0..nch];
            const row = out[i * width ..][0..width];
            @memcpy(row[0..nch], in);
            const pos: usize = @intCast(@as(u64, @bitCast(first + @as(i64, @intCast(i)))) & mask);
            @memcpy(self.raw[pos * nch ..][0..nch], in);
        }
        for (self.slots[0..self.num_slots]) |*s| {
            // The reference: the mean of the reference rows, for each sample.
            const mean = self.mean_buf[0..count];
            if (s.cfg.car) {
                const n: f64 = @floatFromInt(s.cfg.ref.count(s.rows));
                @memset(mean, 0);
                for (0..s.rows) |r| {
                    if (!s.cfg.ref.has(r)) continue;
                    const ch = s.first_ch + r;
                    for (mean, 0..) |*m, i| m.* += @floatFromInt(samples[i * nch + ch]);
                }
                for (mean) |*m| m.* /= n;
            }
            // Channel by channel, so each filter's state stays in registers. The rows shown
            // take the slot's columns in order.
            var col = s.column;
            for (s.states, 0..) |*st_ptr, r| {
                if (s.cfg.hidden.has(r)) continue;
                defer col += 1;
                const ch = s.first_ch + r;
                const sub = s.cfg.car and s.cfg.sub.has(r);
                if (!s.cfg.band_rows.has(r)) {
                    // Shown as it is (less the reference).
                    if (sub) {
                        for (0..count) |i| out[i * width + col] = dsp.toI16(@as(f64, @floatFromInt(samples[i * nch + ch])) - mean[i]);
                    } else {
                        for (0..count) |i| out[i * width + col] = samples[i * nch + ch];
                    }
                    continue;
                }
                // Start every filter settled on its channel's first sample.
                if (starting) s.band.settle(st_ptr, @as(f64, @floatFromInt(samples[ch])) - (if (sub) mean[0] else 0));
                var st = st_ptr.*;
                if (sub) {
                    for (0..count) |i| out[i * width + col] = dsp.toI16(s.band.step(
                        &st,
                        @as(f64, @floatFromInt(samples[i * nch + ch])) - mean[i],
                    ));
                } else {
                    for (0..count) |i| out[i * width + col] = dsp.toI16(s.band.step(&st, @floatFromInt(samples[i * nch + ch])));
                }
                st_ptr.* = st;
            }
        }
        for (self.ttl_slots[0..self.num_ttl_slots]) |*s| {
            for (0..s.rows) |r| {
                const bit = s.masks[r];
                const col = s.column + r;
                for (0..count) |i| out[i * width + col] = if (i < ttl.len and ttl[i] & bit != 0) panels.ttl_level else -panels.ttl_level;
            }
        }
        self.newest = first + @as(i64, @intCast(count));
        self.oldest = @max(self.oldest, self.newest - @as(i64, @intCast(self.raw_cap)));
        return out;
    }

    /// Brings the slots in line with the panels' corners and references. A slot for which
    /// they changed has its last `recent` samples made again, into `hist` (the history: a
    /// ring of `hist_cap` rows indexed by sample number). True if anything changed.
    pub fn sync(self: *Feed, gpa: std.mem.Allocator, set: *const panels.Set, recent: usize, hist: []i16, hist_cap: usize) !bool {
        var changed = false;
        for (set.items[0..set.len], 0..) |*p, i| {
            const s = &self.slots[self.slot_of[i] orelse continue];
            const cfg: Config = .of(p);
            if (s.cfg.eql(&cfg)) continue;
            s.cfg = cfg;
            s.band = .init(cfg.low_hz, cfg.high_hz, self.fs);
            try self.refilter(gpa, s, recent, hist, hist_cap);
            changed = true;
        }
        return changed;
    }

    fn refilter(self: *Feed, gpa: std.mem.Allocator, s: *Slot, recent: usize, hist: []i16, hist_cap: usize) !void {
        if (!self.started) return;
        const start = @max(self.oldest, self.newest - @as(i64, @intCast(@min(recent, hist_cap))));
        const count: usize = @intCast(self.newest - start);
        if (count == 0) return;
        const raw_mask = self.raw_cap - 1;
        const hist_mask = hist_cap - 1;
        const nch = self.nch;
        if (self.mean_buf.len < count) {
            // New first, then free: if allocating fails, `rows` keeps its buffer.
            const bigger = try gpa.alloc(f64, count);
            gpa.free(self.mean_buf);
            self.mean_buf = bigger;
        }
        const mean = self.mean_buf[0..count];
        if (s.cfg.car) {
            const n: f64 = @floatFromInt(s.cfg.ref.count(s.rows));
            @memset(mean, 0);
            for (0..s.rows) |r| {
                if (!s.cfg.ref.has(r)) continue;
                const ch = s.first_ch + r;
                for (mean, 0..) |*m, i| {
                    const k: u64 = @bitCast(start + @as(i64, @intCast(i)));
                    m.* += @floatFromInt(self.raw[@as(usize, @intCast(k & raw_mask)) * nch + ch]);
                }
            }
            for (mean) |*m| m.* /= n;
        } else @memset(mean, 0);
        var col = s.column;
        for (s.states, 0..) |*st_ptr, r| {
            if (s.cfg.hidden.has(r)) continue;
            defer col += 1;
            const ch = s.first_ch + r;
            const sub: f64 = if (s.cfg.car and s.cfg.sub.has(r)) 1 else 0;
            const through_band = s.cfg.band_rows.has(r);
            var st: dsp.Band.State = @splat(.{});
            const first_pos: usize = @intCast(@as(u64, @bitCast(start)) & raw_mask);
            s.band.settle(&st, @as(f64, @floatFromInt(self.raw[first_pos * nch + ch])) - sub * mean[0]);
            for (0..count) |i| {
                const n: u64 = @bitCast(start + @as(i64, @intCast(i)));
                const x = @as(f64, @floatFromInt(self.raw[@as(usize, @intCast(n & raw_mask)) * nch + ch])) - sub * mean[i];
                hist[@as(usize, @intCast(n & hist_mask)) * self.width + col] = dsp.toI16(if (through_band) s.band.step(&st, x) else x);
            }
            st_ptr.* = st;
        }
    }
};

const testing = std.testing;

test "rows carry raw channels and each electrode panel's filtered copy; refilter redoes the past" {
    const gpa = testing.allocator;
    var layout: types.Layout = .{ .sample_rate = 30000, .hw_clock_hz = 50e6 };
    layout.headstages[0] = .{ .slot = 0, .chip = "RHD2132", .num_channels = 2, .first_channel = 0, .has_bno = false };
    layout.num_headstages = 1;
    layout.num_electrodes = 2;
    layout.num_adc = 1;
    var set = panels.default(&layout, .scroll);
    set.items[0].filter.on = true;
    set.items[0].filter.low_hz = 300;
    set.items[0].filter.high_hz = 6000;
    var feed = try Feed.init(gpa, &layout, &set, 4096, 256);
    defer feed.deinit(gpa);
    try testing.expectEqual(3, feed.nch);
    try testing.expectEqual(5, feed.width);
    try testing.expectEqual(3, set.items[0].slot);

    // Channel 0: a 1 kHz sine on a large offset; channel 1: a slow 20 Hz sine; ADC: a ramp.
    const cap = 4096;
    const hist = try gpa.alloc(i16, cap * feed.width);
    defer gpa.free(hist);
    @memset(hist, 0);
    var block: [256 * 3]i16 = undefined;
    var n: i64 = 1000; // not starting at 0, as after a late start
    const total = 3000;
    while (n < 1000 + total) : (n += 256) {
        for (0..256) |i| {
            const t = @as(f64, @floatFromInt(n + @as(i64, @intCast(i)))) / 30000.0;
            block[i * 3 + 0] = @intFromFloat(8000.0 + 1000.0 * @sin(2.0 * std.math.pi * 1000.0 * t));
            block[i * 3 + 1] = @intFromFloat(3000.0 * @sin(2.0 * std.math.pi * 20.0 * t));
            block[i * 3 + 2] = @intCast(@mod(n + @as(i64, @intCast(i)), 1000));
        }
        const out = try feed.rows(n, &block, &.{});
        for (0..256) |i| {
            const pos: usize = @intCast(@mod(n + @as(i64, @intCast(i)), cap));
            @memcpy(hist[pos * feed.width ..][0..feed.width], out[i * feed.width ..][0..feed.width]);
        }
    }
    const newest = n;
    const Peak = struct {
        fn of(h: []const i16, width: usize, col: usize, from: i64, to: i64) i32 {
            var peak: i32 = 0;
            var k = from;
            while (k < to) : (k += 1) peak = @max(peak, @as(i32, @intCast(@abs(h[@as(usize, @intCast(@mod(k, cap))) * width + col]))));
            return peak;
        }
    };
    // Raw columns untouched; filtered: the offset of 8000 never shows (the filter starts
    // settled on the first sample, so the start is off by the sine's own size at most),
    // the 1 kHz sine passes, the 20 Hz sine is removed.
    try testing.expect(Peak.of(hist, feed.width, 0, 1000, newest) >= 8990);
    try testing.expect(Peak.of(hist, feed.width, 3, 1000, 1300) < 2500);
    const f0 = Peak.of(hist, feed.width, 3, 1300, newest);
    try testing.expect(f0 > 950 and f0 < 1100);
    try testing.expect(Peak.of(hist, feed.width, 4, newest - 1000, newest) < 40);
    try testing.expectEqual(@as(i16, @intCast(@mod(newest - 1, 1000))), hist[@as(usize, @intCast(@mod(newest - 1, cap))) * feed.width + 2]);

    // New corners (a 0–100 Hz low-pass): the past is filtered again, so now the slow sine
    // passes and the fast one is gone, and the offset stays.
    set.items[0].filter.low_hz = 0;
    set.items[0].filter.high_hz = 100;
    try testing.expect(try feed.sync(gpa, &set, 2000, hist, cap));
    try testing.expect(!try feed.sync(gpa, &set, 2000, hist, cap));
    const slow = Peak.of(hist, feed.width, 4, newest - 1000, newest);
    try testing.expect(slow > 2800 and slow < 3100);
    var lo: i32 = 32767;
    var hi: i32 = -32768;
    var k = newest - 1000;
    while (k < newest) : (k += 1) {
        const v: i32 = hist[@as(usize, @intCast(@mod(k, cap))) * feed.width + 3];
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    try testing.expect(lo > 7950 and hi < 8050);
    // The filter carries on from the refiltered state without a step.
    for (0..256) |i| {
        const t = @as(f64, @floatFromInt(newest + @as(i64, @intCast(i)))) / 30000.0;
        block[i * 3 + 0] = @intFromFloat(8000.0 + 1000.0 * @sin(2.0 * std.math.pi * 1000.0 * t));
        block[i * 3 + 1] = 0;
        block[i * 3 + 2] = 0;
    }
    const out = try feed.rows(newest, &block, &.{});
    try testing.expect(out[3] > 7950 and out[3] < 8050);
}

test "rows takes blocks up to max_block, also after sync and restart; a longer one is refused" {
    const gpa = testing.allocator;
    var layout: types.Layout = .{ .sample_rate = 30000, .hw_clock_hz = 50e6 };
    layout.headstages[0] = .{ .slot = 0, .chip = "RHD2132", .num_channels = 4, .first_channel = 0, .has_bno = false };
    layout.num_headstages = 1;
    layout.num_electrodes = 4;
    var set = panels.default(&layout, .scroll);
    const p = &set.items[0];
    p.filter.on = true;
    p.reference.on = true;
    for (0..4) |r| {
        p.reference.ref.set(r, true);
        p.reference.sub.set(r, true);
    }
    const max_block = 300;
    // Less raw history than one refilter of `recent` below would want, more than a block.
    var feed = try Feed.init(gpa, &layout, &set, 2048, max_block);
    defer feed.deinit(gpa);
    const cap = 4096;
    const hist = try gpa.alloc(i16, cap * feed.width);
    defer gpa.free(hist);
    @memset(hist, 0);
    const block = try gpa.alloc(i16, (max_block + 1) * 4);
    defer gpa.free(block);
    for (block, 0..) |*v, i| v.* = @intCast(i % 4000);
    const full = block[0 .. max_block * 4];

    var n: i64 = 0;
    for (0..8) |_| {
        const out = try feed.rows(n, full, &.{});
        try testing.expectEqual(max_block * feed.width, out.len);
        try testing.expectEqualSlices(i16, full[(max_block - 1) * 4 ..][0..4], out[(max_block - 1) * feed.width ..][0..4]);
        n += max_block;
    }
    // One sample too many: refused, and nothing taken from it.
    try testing.expectError(error.BlockTooLong, feed.rows(n, block, &.{}));
    try testing.expectEqual(n, feed.newest);

    // A sync that refilters 2048 samples (more than `max_block`), then full blocks again.
    p.filter.low_hz = 600;
    try testing.expect(try feed.sync(gpa, &set, 4000, hist, cap));
    try testing.expect(feed.mean_buf.len >= 2048);
    for (0..3) |_| {
        const out = try feed.rows(n, full, &.{});
        try testing.expectEqual(max_block * feed.width, out.len);
        n += max_block;
    }
    // Restarted elsewhere (as review does), still full blocks.
    feed.restart();
    n = 1_000_000;
    const out = try feed.rows(n, full, &.{});
    try testing.expectEqual(max_block * feed.width, out.len);
    try testing.expectError(error.BlockTooLong, feed.rows(n + max_block, block, &.{}));
}

test "common average reference: the shared part goes, each channel's own stays" {
    const gpa = testing.allocator;
    var layout: types.Layout = .{ .sample_rate = 30000, .hw_clock_hz = 50e6 };
    layout.headstages[0] = .{ .slot = 0, .chip = "RHD2132", .num_channels = 4, .first_channel = 0, .has_bno = false };
    layout.num_headstages = 1;
    layout.num_electrodes = 4;
    var set = panels.default(&layout, .scroll);
    const p = &set.items[0];
    // Unfiltered, reference = rows 1 to 3, subtracted from rows 1, 2 and 4.
    p.reference.on = true;
    for ([_]usize{ 0, 1, 2 }) |r| p.reference.ref.set(r, true);
    for ([_]usize{ 0, 1, 3 }) |r| p.reference.sub.set(r, true);
    var feed = try Feed.init(gpa, &layout, &set, 2048, 256);
    defer feed.deinit(gpa);
    try testing.expectEqual(4, p.slot);
    try testing.expectEqual(4, p.drawColumn());

    const cap = 2048;
    const hist = try gpa.alloc(i16, cap * feed.width);
    defer gpa.free(hist);
    @memset(hist, 0);
    // Every channel: a shared 50 Hz wave of 3000, plus its own constant (100 * its number).
    var block: [256 * 4]i16 = undefined;
    var n: i64 = 0;
    while (n < 1024) : (n += 256) {
        for (0..256) |i| {
            const t = @as(f64, @floatFromInt(n + @as(i64, @intCast(i)))) / 30000.0;
            const common: f64 = 3000.0 * @sin(2.0 * std.math.pi * 50.0 * t);
            for (0..4) |c| block[i * 4 + c] = @intFromFloat(common + 100.0 * @as(f64, @floatFromInt(c + 1)));
        }
        const out = try feed.rows(n, &block, &.{});
        for (0..256) |i| {
            const pos: usize = @intCast(@mod(n + @as(i64, @intCast(i)), cap));
            @memcpy(hist[pos * feed.width ..][0..feed.width], out[i * feed.width ..][0..feed.width]);
        }
    }
    // The mean of rows 1 to 3 is the wave + 200. Rows 1, 2 and 4 lose it: -100, 0, +200,
    // steady. Row 3 is not in the subtract set and keeps the wave. The acquired columns
    // are untouched.
    var k: usize = 100;
    while (k < 1024) : (k += 97) {
        const row = hist[k * feed.width ..][0..feed.width];
        try testing.expect(@abs(@as(i32, row[4]) + 100) <= 1);
        try testing.expect(@abs(@as(i32, row[5])) <= 1);
        try testing.expect(@abs(@as(i32, row[7]) - 200) <= 1);
        try testing.expectEqual(row[2], row[6]);
    }
    // Taking row 3 out of the reference changes the past too: the mean is then the wave
    // + 150.
    p.reference.ref.set(2, false);
    try testing.expect(try feed.sync(gpa, &set, 1024, hist, cap));
    k = 100;
    while (k < 1024) : (k += 97) {
        const row = hist[k * feed.width ..][0..feed.width];
        try testing.expect(@abs(@as(i32, row[4]) + 50) <= 1);
        try testing.expect(@abs(@as(i32, row[7]) - 250) <= 1);
    }
    // Off: the slot passes the channels as they are.
    p.setCar(false);
    try testing.expect(try feed.sync(gpa, &set, 1024, hist, cap));
    const row = hist[500 * feed.width ..][0..feed.width];
    try testing.expectEqualSlices(i16, row[0..4], row[4..8]);
}

test "one panel: some rows filtered, some as they are, some hidden" {
    const gpa = testing.allocator;
    var layout: types.Layout = .{ .sample_rate = 30000, .hw_clock_hz = 50e6 };
    layout.headstages[0] = .{ .slot = 0, .chip = "RHD2132", .num_channels = 4, .first_channel = 0, .has_bno = false };
    layout.num_headstages = 1;
    layout.num_electrodes = 4;
    var set = panels.default(&layout, .scroll);
    const p = &set.items[0];
    // Rows 1 and 2 through 300 Hz to 6 kHz, row 3 hidden, row 4 as it is.
    p.filter.on = true;
    p.per_row.raw.set(3, true);
    p.per_row.hidden.set(2, true);
    var feed = try Feed.init(gpa, &layout, &set, 4096, 256);
    defer feed.deinit(gpa);
    try testing.expectEqual(3, p.shownRows());

    const cap = 4096;
    const hist = try gpa.alloc(i16, cap * feed.width);
    defer gpa.free(hist);
    @memset(hist, 0);
    // Every channel: a slow 5 Hz wave of 4000 on an offset of 1000 * its number.
    var block: [256 * 4]i16 = undefined;
    var n: i64 = 0;
    while (n < 3072) : (n += 256) {
        for (0..256) |i| {
            const t = @as(f64, @floatFromInt(n + @as(i64, @intCast(i)))) / 30000.0;
            for (0..4) |c| block[i * 4 + c] = @intFromFloat(4000.0 * @sin(2.0 * std.math.pi * 5.0 * t) +
                1000.0 * @as(f64, @floatFromInt(c + 1)));
        }
        const out = try feed.rows(n, &block, &.{});
        for (0..256) |i| {
            const pos: usize = @intCast(@mod(n + @as(i64, @intCast(i)), cap));
            @memcpy(hist[pos * feed.width ..][0..feed.width], out[i * feed.width ..][0..feed.width]);
        }
    }
    // The slot's three columns: rows 1 and 2 without the slow wave and the offset, then
    // row 4 (not row 3) exactly as acquired.
    var k: usize = 1500;
    while (k < 3072) : (k += 131) {
        const row = hist[k * feed.width ..][0..feed.width];
        try testing.expect(@abs(@as(i32, row[4])) < 60 and @abs(@as(i32, row[5])) < 60);
        try testing.expectEqual(row[3], row[6]);
    }
    // Showing row 3 again and taking row 1 out of the filter redoes the past: now four
    // columns, row 1 as acquired, row 2 filtered, row 3 filtered, row 4 as acquired.
    p.per_row.hidden.set(2, false);
    p.per_row.raw.set(0, true);
    try testing.expect(try feed.sync(gpa, &set, 3000, hist, cap));
    k = 1500;
    while (k < 3072) : (k += 131) {
        const row = hist[k * feed.width ..][0..feed.width];
        try testing.expectEqual(row[0], row[4]);
        try testing.expect(@abs(@as(i32, row[5])) < 60 and @abs(@as(i32, row[6])) < 60);
        try testing.expectEqual(row[3], row[7]);
    }
}
