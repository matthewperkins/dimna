//! A real-time simulated acquisition board producing plausible extracellular data, for
//! developing and testing without hardware. Port of oers `crates/rhythm/src/sim_board.rs`:
//! per-channel noise and 1/f-like LFP, shared 7 Hz theta and 50 Hz hum, units with
//! theta-modulated bursty firing that spread to neighbouring channels, an optional
//! common-mode artefact (30 ms every 1.7 s), a slow sine on AUX, a 1 Hz sine on ADC 1, and
//! TTL line 1 pulsing 10 ms every second with line 2 a 2 Hz square wave.

const std = @import("std");
const types = @import("types.zig");
const Board = @import("board.zig").Board;
const Block = types.Block;
const Health = types.Health;
const Settings = types.Settings;
const Layout = types.Layout;
const Io = std.Io;
const pi = std.math.pi;

/// The board clock the simulator pretends to have (as the real board's).
const sim_clock_hz: f64 = 50_000_000.0;

const Rng = struct {
    s: u64,

    fn nextU64(self: *Rng) u64 {
        // xorshift64*
        var x = self.s;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.s = x;
        return x *% 0x2545F4914F6CDD1D;
    }
    fn uniform(self: *Rng) f64 {
        return @as(f64, @floatFromInt(self.nextU64() >> 11)) * (1.0 / @as(f64, @floatFromInt(@as(u64, 1) << 53)));
    }
    /// Irwin-Hall(4) approximation: cheap and good enough for noise.
    fn gauss(self: *Rng) f64 {
        return (self.uniform() + self.uniform() + self.uniform() + self.uniform() - 2.0) * 1.7320508;
    }
};

const max_template = 64;

const Unit = struct {
    channel: usize,
    rate_hz: f64,
    amplitude_uv: f64,
    /// Waveform at the sampling rate, peak-normalised.
    template: [max_template]f32,
    template_len: usize,
    refractory: usize,
    next_spike_in: usize,
    burstiness: f64,
};

const Active = struct { channel: usize, unit: usize, pos: usize, gain: f32 };

pub const Sim = struct {
    gpa: std.mem.Allocator,
    io: Io,
    settings: Settings = .{},
    /// For tests: the next this many live commands (`live`, `setAmpLive`) are refused.
    refuse_live: u32 = 0,
    /// Channels of each simulated headstage (32 = RHD2132, 16 = RHD2216, 64 = RHD2164).
    headstage_channels: [8]usize = @splat(0),
    num_headstages: usize,
    sample_rate: f64 = 30000.0,
    nch: usize = 0,
    rng: Rng = .{ .s = 0x9E3779B97F4A7C15 },
    units: []Unit = &.{},
    active: [4096]Active = undefined,
    num_active: usize = 0,
    lfp_state: []f64 = &.{},
    /// The common-mode test artefact.
    artefact: bool = true,
    /// For testing the alarms: at this second of signal, deliver nothing for `stall_s`
    /// (the samples come late, all at once, as from a board's buffer) or fail with a read
    /// error. Null: never.
    stall_at_s: ?f64 = null,
    stall_s: f64 = 0,
    fail_at_s: ?f64 = null,
    /// How many runs fail at `fail_at_s` (each run counts from its own start): the first
    /// `fail_times` after `fail_at_s` is set; later runs go on.
    fail_times: u32 = 1,
    /// For testing the reopen after a read error: the next `reopen_absent` calls to `reopen`
    /// report the board gone, then the next `reopen_failures` fail outright.
    reopen_absent: u32 = 0,
    reopen_failures: u32 = 0,
    /// Calls to `reopen` so far.
    reopens: u32 = 0,
    sample: i64 = 0,
    t0: Io.Timestamp = .zero,
    health: ?*Health = null,
    running: bool = false,
    ttl_out: u16 = 0,

    pub fn init(gpa: std.mem.Allocator, io: Io, headstage_channels: []const usize) !Sim {
        std.debug.assert(headstage_channels.len >= 1 and headstage_channels.len <= 8);
        var s: Sim = .{ .gpa = gpa, .io = io, .num_headstages = headstage_channels.len };
        @memcpy(s.headstage_channels[0..headstage_channels.len], headstage_channels);
        try s.rebuild();
        return s;
    }

    pub fn deinit(self: *Sim) void {
        self.gpa.free(self.units);
        self.gpa.free(self.lfp_state);
    }

    /// Channels of simulated headstage `i`, honouring the RHD2132 16-channel option.
    fn hsChannels(self: *const Sim, i: usize) usize {
        const n = self.headstage_channels[i];
        return if (n == 32 and self.settings.rhd2132_16ch[i]) 16 else n;
    }

    fn electrodes(self: *const Sim) usize {
        var n: usize = 0;
        for (0..self.num_headstages) |i| n += self.hsChannels(i);
        return n;
    }

    fn spikeTemplate(fs: f64, width_ms: f64, asym: f64, out: *[max_template]f32) usize {
        const n = @min(@as(usize, @intFromFloat(fs * 2.0e-3)), max_template);
        const tc = 0.4e-3;
        const w = width_ms * 1e-3;
        for (0..n) |i| {
            const t = @as(f64, @floatFromInt(i)) / fs - tc;
            const a = t / (0.25 * w);
            const b = (t - 0.45 * w) / (0.45 * w);
            out[i] = @floatCast(-@exp(-a * a) + asym * @exp(-b * b));
        }
        return n;
    }

    fn rebuild(self: *Sim) !void {
        const fs: f64 = @floatFromInt(self.settings.sample_rate);
        self.sample_rate = fs;
        const ne = self.electrodes();
        self.nch = ne + @as(usize, if (self.settings.acquire_aux) 3 * self.num_headstages else 0) +
            @as(usize, if (self.settings.acquire_adc) 8 else 0);
        var list: std.ArrayList(Unit) = .empty;
        errdefer list.deinit(self.gpa);
        var r: Rng = .{ .s = 42 };
        for (0..ne) |ch| {
            // About 60 % of channels carry 1-3 units.
            if (r.uniform() < 0.6) {
                const count = 1 + @as(usize, @intFromFloat(r.uniform() * 2.5));
                for (0..count) |_| {
                    const a = r.uniform();
                    const amp = 50.0 + 250.0 * a * a;
                    const q = r.uniform();
                    var u: Unit = .{
                        .channel = ch,
                        .rate_hz = 1.0 + 20.0 * q * q,
                        .amplitude_uv = amp,
                        .template = undefined,
                        .template_len = 0,
                        .refractory = @intFromFloat(fs * 2.0e-3),
                        .next_spike_in = 0,
                        .burstiness = 0,
                    };
                    const width = 0.5 + 0.7 * r.uniform();
                    const asym = 0.2 + 0.5 * r.uniform();
                    u.template_len = spikeTemplate(fs, width, asym, &u.template);
                    u.next_spike_in = @intFromFloat(r.uniform() * fs);
                    u.burstiness = r.uniform() * 0.3;
                    try list.append(self.gpa, u);
                }
            }
        }
        const lfp = try self.gpa.alloc(f64, ne);
        @memset(lfp, 0);
        self.gpa.free(self.units);
        self.gpa.free(self.lfp_state);
        self.units = try list.toOwnedSlice(self.gpa);
        self.lfp_state = lfp;
        self.num_active = 0;
    }

    pub fn applySettings(self: *Sim, new: Settings) !void {
        if (self.running) return error.Busy;
        self.settings = new;
        try self.rebuild();
    }

    pub fn layout(self: *const Sim) Layout {
        var l: Layout = .{ .sample_rate = self.sample_rate, .hw_clock_hz = sim_clock_hz };
        var first: usize = 0;
        for (0..self.num_headstages) |i| {
            const n = self.hsChannels(i);
            l.headstages[i] = .{
                .slot = i,
                .chip = if (self.headstage_channels[i] == 64) "RHD2164" else if (self.headstage_channels[i] == 16) "RHD2216" else "RHD2132",
                .num_channels = n,
                .first_channel = first,
                .has_bno = false,
            };
            first += n;
        }
        l.num_headstages = self.num_headstages;
        l.num_electrodes = first;
        l.num_aux = if (self.settings.acquire_aux) 3 * self.num_headstages else 0;
        l.num_adc = if (self.settings.acquire_adc) 8 else 0;
        return l;
    }

    pub fn numChannels(self: *const Sim) usize {
        return self.nch;
    }

    pub fn start(self: *Sim, health: *Health) void {
        health.reset();
        self.health = health;
        self.sample = 0;
        self.num_active = 0;
        self.t0 = Io.Clock.awake.now(self.io);
        self.running = true;
    }

    pub fn stop(self: *Sim) void {
        self.running = false;
    }

    /// The board's `reopen`, simulated: stopped, given `settings` again, ready to `start`.
    /// `reopen_absent` and `reopen_failures` make it fail first.
    pub fn reopen(self: *Sim, settings: Settings) !void {
        self.reopens += 1;
        self.running = false;
        if (self.reopen_absent > 0) {
            self.reopen_absent -= 1;
            return error.BoardAbsent;
        }
        if (self.reopen_failures > 0) {
            self.reopen_failures -= 1;
            return error.SimulatedOpenError;
        }
        try self.applySettings(settings);
    }

    fn generateSample(self: *Sim, blk: *Block) void {
        const fs = self.sample_rate;
        const ne = self.lfp_state.len;
        const t = @as(f64, @floatFromInt(self.sample)) / fs;
        // Spike scheduling.
        for (self.units, 0..) |*u, ui| {
            if (u.next_spike_in == 0) {
                const g: f32 = @floatCast(1.0 + 0.08 * self.rng.gauss());
                const spread = [_]struct { d: isize, att: f32 }{
                    .{ .d = 0, .att = 1.0 },
                    .{ .d = -1, .att = 0.45 },
                    .{ .d = 1, .att = 0.45 },
                    .{ .d = 2, .att = 0.15 },
                    .{ .d = -2, .att = 0.15 },
                };
                for (spread) |sp| {
                    const c = @as(isize, @intCast(u.channel)) + sp.d;
                    if (c >= 0 and c < ne and self.num_active < self.active.len) {
                        self.active[self.num_active] = .{ .channel = @intCast(c), .unit = ui, .pos = 0, .gain = g * sp.att };
                        self.num_active += 1;
                    }
                }
                // Theta-modulated Poisson process with refractoriness and bursts.
                const rate = u.rate_hz * (1.0 + 0.6 * @sin(2.0 * pi * 7.0 * t));
                const isi = if (self.rng.uniform() < u.burstiness)
                    fs * (0.003 + 0.004 * self.rng.uniform())
                else
                    -@log(@max(self.rng.uniform(), 1e-12)) * fs / @max(rate, 0.1);
                u.next_spike_in = @max(@as(usize, @intFromFloat(@min(isi, 1e9))), u.refractory);
            } else {
                u.next_spike_in -= 1;
            }
        }
        const theta = @sin(2.0 * pi * 7.0 * t);
        const hum = @sin(2.0 * pi * 50.0 * t);
        const artefact = if (self.artefact and @mod(t, 1.7) < 0.03) 40.0 * self.rng.gauss() else 0.0;
        const row = blk.data[blk.len * blk.num_channels ..][0..blk.num_channels];
        const uv = types.electrode_uv_per_bit;
        for (0..ne) |ch| {
            // 1/f-ish LFP: leaky integrated noise, plus the shared theta.
            const s = &self.lfp_state[ch];
            s.* = s.* * 0.9995 + self.rng.gauss() * 1.5;
            const v = 8.0 * self.rng.gauss() + s.* + 60.0 * theta + 4.0 * hum + artefact;
            row[ch] = toI16(v / uv);
        }
        var i: usize = 0;
        while (i < self.num_active) {
            const a = self.active[i];
            const u = &self.units[a.unit];
            const v = @as(f64, u.template[a.pos]) * a.gain * u.amplitude_uv / uv;
            row[a.channel] = toI16(@as(f64, @floatFromInt(row[a.channel])) + v);
            if (a.pos + 1 >= u.template_len) {
                self.num_active -= 1;
                self.active[i] = self.active[self.num_active];
            } else {
                self.active[i].pos += 1;
                i += 1;
            }
        }
        var ch = ne;
        if (self.settings.acquire_aux) {
            for (0..3 * self.num_headstages) |k| {
                const a = 0.5 * @sin(2.0 * pi * 0.5 * t + @as(f64, @floatFromInt(k)));
                row[ch] = toI16(a / types.aux_v_per_bit);
                ch += 1;
            }
        }
        if (self.settings.acquire_adc) {
            for (0..8) |k| {
                const v = if (k == 0) 2.5 * @sin(2.0 * pi * t) else 0.0;
                row[ch] = toI16(v / types.adc_v_per_bit);
                ch += 1;
            }
        }
        // TTL line 1: 10 ms pulse every second; line 2: square wave, 2 Hz.
        const ph = @mod(self.sample, @as(i64, @intFromFloat(fs)));
        var ttl: u16 = @intFromBool(ph < @as(i64, @intFromFloat(fs * 0.01)));
        ttl |= @as(u16, @intCast(@mod(@as(i64, @intFromFloat(t * 4.0)), 2))) << 1;
        blk.ttl[blk.len] = ttl;
        blk.hw_time[blk.len] = @intFromFloat(@round(@as(f64, @floatFromInt(self.sample)) * sim_clock_hz / fs));
        blk.len += 1;
        self.sample += 1;
    }

    fn toI16(v: f64) i16 {
        return @intFromFloat(std.math.clamp(v, -32768.0, 32767.0));
    }

    /// Fills `blk`, then sleeps until its last sample is due in real time.
    pub fn readBlock(self: *Sim, blk: *Block) (Io.Cancelable || error{SimulatedReadError})!void {
        blk.clear();
        std.debug.assert(blk.num_channels == self.nch);
        const at_s = @as(f64, @floatFromInt(self.sample)) / self.sample_rate;
        if (self.fail_at_s) |f| if (at_s >= f and self.fail_times > 0) {
            self.fail_times -= 1;
            return error.SimulatedReadError;
        };
        if (self.stall_at_s) |s| if (at_s >= s) {
            self.stall_at_s = null;
            try self.io.sleep(.fromNanoseconds(@intFromFloat(self.stall_s * 1e9)), .awake);
        };
        blk.first_sample = self.sample;
        const n = @min(@max(self.settings.block_samples, 1), blk.capacity);
        for (0..n) |_| self.generateSample(blk);
        const due_ns: i96 = @intFromFloat(@as(f64, @floatFromInt(self.sample)) / self.sample_rate * 1e9);
        const elapsed = self.t0.untilNow(self.io, .awake).nanoseconds;
        if (due_ns > elapsed) try self.io.sleep(.fromNanoseconds(due_ns - elapsed), .awake);
        if (self.health) |h| {
            h.add(&h.samples, n);
            h.add(&h.frames, n);
        }
    }

    /// A live command: kept in `settings` as the board keeps it (`Board.live`), so that
    /// whatever reads the source's settings sees the same on both. `refuse_live` makes the
    /// next commands fail, for tests.
    pub fn live(self: *Sim, cmd: types.LiveCommand) !void {
        if (self.refuse_live > 0) {
            self.refuse_live -= 1;
            return error.SimulatedRefusal;
        }
        switch (cmd) {
            .set_ttl_out => |w| self.ttl_out = w,
            .dac_route => {},
            .set_leds => |on| self.settings.leds = on,
            .set_dac_hpf => |h| {
                self.settings.dac_hpf_enabled = h.enabled;
                self.settings.dac_hpf_hz = h.hz;
            },
            .set_noise_slicer => |n| self.settings.noise_slicer = n,
            .set_ttl_mode => |on| self.settings.ttl_output_mode = on,
            .set_fast_ttl_settle => |ch| self.settings.fast_ttl_settle = ch,
            .set_clock_divider => |d| self.settings.clock_divider = d,
        }
    }

    /// The board's gap-free amplifier change, simulated: kept in `settings` (the simulated
    /// signal does not change with the band).
    pub fn setAmpLive(self: *Sim, a: Board.AmpSettings) !void {
        if (self.refuse_live > 0) {
            self.refuse_live -= 1;
            return error.SimulatedRefusal;
        }
        self.settings.lower_bandwidth = a.lower_bandwidth;
        self.settings.upper_bandwidth = a.upper_bandwidth;
        self.settings.dsp_enabled = a.dsp_enabled;
        self.settings.dsp_cutoff = a.dsp_cutoff;
        self.settings.fast_settle = a.fast_settle;
    }
};

const testing = std.testing;

test "simulator fills blocks with contiguous, plausible data" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var sim = try Sim.init(testing.allocator, threaded.io(), &.{ 32, 16 });
    defer sim.deinit();
    var st: Settings = .{};
    st.acquire_adc = true;
    st.rhd2132_16ch[0] = true;
    try sim.applySettings(st);
    try testing.expectEqual(16 + 16 + 8, sim.numChannels());
    const l = sim.layout();
    try testing.expectEqual(32, l.num_electrodes);
    try testing.expectEqual(16, l.headstages[1].first_channel);
    var h: Health = .{};
    var b = try Block.init(testing.allocator, sim.numChannels(), 32);
    defer b.deinit(testing.allocator);
    sim.start(&h);
    var sum_sq: f64 = 0;
    var count: f64 = 0;
    for (0..40) |k| {
        try sim.readBlock(&b);
        try testing.expectEqual(@as(i64, @intCast(k * 32)), b.first_sample);
        try testing.expectEqual(32, b.len);
        for (0..b.len) |s| {
            const v = @as(f64, @floatFromInt(b.sample(s)[3])) * types.electrode_uv_per_bit;
            sum_sq += v * v;
            count += 1;
        }
    }
    // Noise plus LFP plus theta: tens of microvolts RMS, not zero and not railed.
    const rms = @sqrt(sum_sq / count);
    try testing.expect(rms > 5.0 and rms < 500.0);
    try testing.expectEqual(1280, h.samples.load(.monotonic));
    // TTL line 1 is high only for the first 10 ms of each second; this block is at 41 ms.
    try testing.expectEqual(0, b.ttl[0] & 1);
}
