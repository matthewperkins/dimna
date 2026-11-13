//! Port of Intan's `Rhd2000Registers`, as used by the Open Ephys ONI acquisition-board plugin
//! (via oers `crates/rhythm/src/registers.rs`). Builds the auxiliary SPI command lists that
//! are uploaded to the FPGA.
//!
//! Deliberately literal: register values and command order are identical to upstream, so the
//! chips are configured exactly as the stock plugin configures them.

const std = @import("std");
const pi = std.math.pi;

pub const max_command_length = 1024;

pub fn cmdConvert(channel: i32) i32 {
    std.debug.assert(channel >= 0 and channel <= 63);
    return channel << 8;
}
pub fn cmdRegRead(reg: i32) i32 {
    std.debug.assert(reg >= 0 and reg <= 63);
    return 0xc000 + (reg << 8);
}
pub fn cmdRegWrite(reg: i32, data: i32) i32 {
    std.debug.assert(reg >= 0 and reg <= 63 and data >= 0 and data <= 255);
    return 0x8000 + (reg << 8) + data;
}
pub const cmd_calibrate: i32 = 0x5500;
pub const cmd_cal_clear: i32 = 0x6a00;

/// A command list, at most `max_command_length` long.
pub const CommandList = struct {
    buf: [max_command_length]i32 = undefined,
    len: usize = 0,

    fn push(self: *CommandList, cmd: i32) void {
        self.buf[self.len] = cmd;
        self.len += 1;
    }
    pub fn slice(self: *const CommandList) []const i32 {
        return self.buf[0..self.len];
    }
};

pub const Rhd2000Registers = struct {
    sample_rate: f64,
    adc_reference_bw: i32 = 3,
    amp_fast_settle: i32 = 0,
    amp_vref_enable: i32 = 1,
    adc_comparator_bias: i32 = 3,
    adc_comparator_select: i32 = 2,
    vdd_sense_enable: i32 = 1,
    adc_buffer_bias: i32 = 0,
    mux_bias: i32 = 0,
    mux_load: i32 = 0,
    temp_s1: i32 = 0,
    temp_s2: i32 = 0,
    temp_en: i32 = 0,
    dig_out_hiz: i32 = 1,
    dig_out: i32 = 0,
    weak_miso: i32 = 1,
    twos_comp: i32 = 0,
    abs_mode: i32 = 0,
    dsp_en: i32 = 1,
    dsp_cutoff_freq_reg: i32 = 0,
    zcheck_dac_power: i32 = 1,
    zcheck_load: i32 = 0,
    zcheck_scale: i32 = 0,
    zcheck_conn_all: i32 = 0,
    zcheck_sel_pol: i32 = 0,
    zcheck_en: i32 = 0,
    zcheck_select: i32 = 0,
    off_chip_rh1: i32 = 0,
    off_chip_rh2: i32 = 0,
    off_chip_rl: i32 = 0,
    adc_aux1_en: i32 = 1,
    adc_aux2_en: i32 = 1,
    adc_aux3_en: i32 = 1,
    rh1_dac1: i32 = 0,
    rh1_dac2: i32 = 0,
    rh2_dac1: i32 = 0,
    rh2_dac2: i32 = 0,
    rl_dac1: i32 = 0,
    rl_dac2: i32 = 0,
    rl_dac3: i32 = 0,
    a_pwr: [64]i32 = @splat(1),

    pub fn init(sample_rate: f64) Rhd2000Registers {
        var r: Rhd2000Registers = .{ .sample_rate = sample_rate };
        r.defineSampleRate(sample_rate);
        _ = r.setDspCutoffFreq(1.0);
        _ = r.setUpperBandwidth(10000.0);
        _ = r.setLowerBandwidth(1.0);
        return r;
    }

    pub fn defineSampleRate(self: *Rhd2000Registers, sr: f64) void {
        self.sample_rate = sr;
        self.mux_load = 0;
        const mb: i32, const ab: i32 = if (sr < 3334.0)
            .{ 40, 32 }
        else if (sr < 4001.0)
            .{ 40, 16 }
        else if (sr < 5001.0)
            .{ 40, 8 }
        else if (sr < 6251.0)
            .{ 32, 8 }
        else if (sr < 8001.0)
            .{ 26, 8 }
        else if (sr < 10001.0)
            .{ 18, 4 }
        else if (sr < 12501.0)
            .{ 16, 3 }
        else if (sr < 15001.0)
            .{ 7, 3 }
        else
            .{ 4, 2 };
        self.mux_bias = mb;
        self.adc_buffer_bias = ab;
    }

    pub fn setFastSettle(self: *Rhd2000Registers, on: bool) void {
        self.amp_fast_settle = @intFromBool(on);
    }
    pub fn setDigOutLow(self: *Rhd2000Registers) void {
        self.dig_out = 0;
        self.dig_out_hiz = 0;
    }
    pub fn enableAux(self: *Rhd2000Registers, on: bool) void {
        const v: i32 = @intFromBool(on);
        self.adc_aux1_en = v;
        self.adc_aux2_en = v;
        self.adc_aux3_en = v;
    }
    pub fn enableDsp(self: *Rhd2000Registers, on: bool) void {
        self.dsp_en = @intFromBool(on);
    }

    fn dspFcutoff(self: *const Rhd2000Registers, n: i32) f64 {
        const x = std.math.pow(f64, 2.0, @floatFromInt(n));
        return self.sample_rate * @log(x / (x - 1.0)) / (2.0 * pi);
    }

    /// Returns the cutoff actually chosen.
    pub fn setDspCutoffFreq(self: *Rhd2000Registers, f: f64) f64 {
        const f1 = self.dspFcutoff(1);
        const f15 = self.dspFcutoff(15);
        if (f > f1) {
            self.dsp_cutoff_freq_reg = 1;
        } else if (f < f15) {
            self.dsp_cutoff_freq_reg = 15;
        } else {
            const lf = @log10(f);
            var best: f64 = 1e7;
            var n: i32 = 1;
            while (n < 16) : (n += 1) {
                const d = @abs(lf - @log10(self.dspFcutoff(n)));
                if (d < best) {
                    best = d;
                    self.dsp_cutoff_freq_reg = n;
                }
            }
        }
        return self.dspFcutoff(self.dsp_cutoff_freq_reg);
    }

    pub fn registerValue(self: *const Rhd2000Registers, reg: i32) i32 {
        const p = &self.a_pwr;
        const byte = struct {
            fn f(a: *const [64]i32, b: usize) i32 {
                var v: i32 = 0;
                for (0..8) |i| v += a[b + i] << @intCast(i);
                return v;
            }
        }.f;
        return switch (reg) {
            0 => (self.adc_reference_bw << 6) + (self.amp_fast_settle << 5) + (self.amp_vref_enable << 4) +
                (self.adc_comparator_bias << 2) + self.adc_comparator_select,
            1 => (self.vdd_sense_enable << 6) + self.adc_buffer_bias,
            2 => self.mux_bias,
            3 => (self.mux_load << 5) + (self.temp_s2 << 4) + (self.temp_s1 << 3) + (self.temp_en << 2) +
                (self.dig_out_hiz << 1) + self.dig_out,
            4 => (self.weak_miso << 7) + (self.twos_comp << 6) + (self.abs_mode << 5) + (self.dsp_en << 4) + self.dsp_cutoff_freq_reg,
            5 => (self.zcheck_dac_power << 6) + (self.zcheck_load << 5) + (self.zcheck_scale << 3) +
                (self.zcheck_conn_all << 2) + (self.zcheck_sel_pol << 1) + self.zcheck_en,
            6 => 128,
            7 => self.zcheck_select,
            8 => (self.off_chip_rh1 << 7) + self.rh1_dac1,
            9 => (self.adc_aux1_en << 7) + self.rh1_dac2,
            10 => (self.off_chip_rh2 << 7) + self.rh2_dac1,
            11 => (self.adc_aux2_en << 7) + self.rh2_dac2,
            12 => (self.off_chip_rl << 7) + self.rl_dac1,
            13 => (self.adc_aux3_en << 7) + (self.rl_dac3 << 6) + self.rl_dac2,
            14 => byte(p, 0),
            // NB: upstream Intan code uses aPwr[0] for bit 0 of register 15 instead of aPwr[8].
            // Reproduced verbatim (all amps are powered in practice).
            15 => (byte(p, 8) & ~@as(i32, 1)) | p[0],
            16 => byte(p, 16),
            17 => byte(p, 24),
            18 => byte(p, 32),
            19 => byte(p, 40),
            20 => byte(p, 48),
            21 => byte(p, 56),
            else => -1,
        };
    }

    fn pow10(x: f64) f64 {
        return std.math.pow(f64, 10.0, x);
    }
    fn rh1FromUpper(f: f64) f64 {
        const l = @log10(f);
        return 0.9730 * pow10(8.0968 - 1.1892 * l + 0.04767 * l * l);
    }
    fn rh2FromUpper(f: f64) f64 {
        const l = @log10(f);
        return 1.0191 * pow10(8.1009 - 1.0821 * l + 0.03383 * l * l);
    }
    fn rlFromLower(f: f64) f64 {
        const l = @log10(f);
        if (f < 4.0) return 1.0061 * pow10(4.9391 - 1.2088 * l + 0.5698 * l * l + 0.1442 * l * l * l);
        return 1.0061 * pow10(4.7351 - 0.5916 * l + 0.08482 * l * l);
    }
    fn quad(a: f64, b: f64, c: f64) f64 {
        return pow10((-b - @sqrt(b * b - 4.0 * a * c)) / (2.0 * a));
    }
    fn upperFromRh1(r: f64) f64 {
        return quad(0.04767, -1.1892, 8.0968 - @log10(r / 0.9730));
    }
    fn upperFromRh2(r: f64) f64 {
        return quad(0.03383, -1.0821, 8.1009 - @log10(r / 1.0191));
    }
    fn lowerFromRl(r_in: f64) f64 {
        const r = @max(r_in, 5100.0);
        if (r < 30000.0) return quad(0.08482, -0.5916, 4.7351 - @log10(r / 1.0061));
        return quad(0.3303, -1.2100, 4.9873 - @log10(r / 1.0061));
    }

    const Fit = struct { d1: i32, d2: i32, actual: f64 };
    fn fitUpper(target: f64, base: f64, step1: f64, step2: f64) Fit {
        var r: Fit = .{ .d1 = 0, .d2 = 0, .actual = base };
        for (0..31) |_| {
            if (r.actual < target - (step2 - step1 / 2.0)) {
                r.actual += step2;
                r.d2 += 1;
            }
        }
        for (0..63) |_| {
            if (r.actual < target - (step1 / 2.0)) {
                r.actual += step1;
                r.d1 += 1;
            }
        }
        return r;
    }

    /// Returns the bandwidth actually chosen.
    pub fn setUpperBandwidth(self: *Rhd2000Registers, f_in: f64) f64 {
        const f = @min(f_in, 30000.0);
        const a = fitUpper(rh1FromUpper(f), 2200.0, 600.0, 29400.0);
        const b = fitUpper(rh2FromUpper(f), 8700.0, 763.0, 38400.0);
        self.rh1_dac1 = a.d1;
        self.rh1_dac2 = a.d2;
        self.rh2_dac1 = b.d1;
        self.rh2_dac2 = b.d2;
        return @sqrt(upperFromRh1(a.actual) * upperFromRh2(b.actual));
    }

    /// Returns the bandwidth actually chosen.
    pub fn setLowerBandwidth(self: *Rhd2000Registers, f_in: f64) f64 {
        const base = 3500.0;
        const step1 = 175.0;
        const step2 = 12700.0;
        const step3 = 3_000_000.0;
        const f = @min(f_in, 1500.0);
        const target = rlFromLower(f);
        self.rl_dac1 = 0;
        self.rl_dac2 = 0;
        self.rl_dac3 = 0;
        var act: f64 = base;
        if (f < 0.15) {
            act += step3;
            self.rl_dac3 += 1;
        }
        for (0..63) |_| {
            if (act < target - (step2 - step1 / 2.0)) {
                act += step2;
                self.rl_dac2 += 1;
            }
        }
        for (0..127) |_| {
            if (act < target - (step1 / 2.0)) {
                act += step1;
                self.rl_dac1 += 1;
            }
        }
        return lowerFromRl(act);
    }

    pub fn commandListRegisterConfig(self: *const Rhd2000Registers, calibrate: bool) CommandList {
        var c: CommandList = .{};
        c.push(cmdRegRead(63));
        c.push(cmdRegRead(63));
        for ([_]i32{ 0, 1, 2, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17 }) |r| c.push(cmdRegWrite(r, self.registerValue(r)));
        for ([_]i32{ 63, 62, 61, 60, 59, 48, 49, 50, 51, 52, 53, 54, 55, 40, 41, 42, 43, 44 }) |r| c.push(cmdRegRead(r));
        var r: i32 = 0;
        while (r <= 17) : (r += 1) c.push(cmdRegRead(r));
        c.push(if (calibrate) cmd_calibrate else cmdRegRead(63));
        r = 18;
        while (r <= 21) : (r += 1) c.push(cmdRegWrite(r, self.registerValue(r)));
        c.push(cmdRegRead(63));
        return c;
    }

    fn pushAux(c: *CommandList) void {
        c.push(cmdConvert(32));
        c.push(cmdConvert(33));
        c.push(cmdConvert(34));
    }

    pub fn commandListTempSensor(self: *Rhd2000Registers) CommandList {
        var c: CommandList = .{};
        self.temp_en = 1;
        pushAux(&c);
        self.temp_s1 = self.temp_en;
        self.temp_s2 = 0;
        c.push(cmdRegWrite(3, self.registerValue(3)));
        pushAux(&c);
        self.temp_s1 = self.temp_en;
        self.temp_s2 = self.temp_en;
        c.push(cmdRegWrite(3, self.registerValue(3)));
        pushAux(&c);
        c.push(cmdConvert(49));
        pushAux(&c);
        self.temp_s1 = 0;
        self.temp_s2 = self.temp_en;
        c.push(cmdRegWrite(3, self.registerValue(3)));
        pushAux(&c);
        c.push(cmdConvert(49));
        pushAux(&c);
        self.temp_s1 = 0;
        self.temp_s2 = 0;
        c.push(cmdRegWrite(3, self.registerValue(3)));
        pushAux(&c);
        c.push(cmdConvert(48));
        for (0..8) |_| {
            pushAux(&c);
            c.push(cmdRegRead(63));
        }
        return c;
    }

    pub fn commandListUpdateDigOut(self: *Rhd2000Registers) CommandList {
        var c: CommandList = .{};
        const w = struct {
            fn f(s: *const Rhd2000Registers, n: usize, cl: *CommandList) void {
                for (0..n) |_| cl.push(cmdRegWrite(3, s.registerValue(3)));
            }
        }.f;
        self.temp_en = 1;
        w(self, 3, &c);
        self.temp_s1 = self.temp_en;
        self.temp_s2 = 0;
        w(self, 4, &c);
        self.temp_s1 = self.temp_en;
        self.temp_s2 = self.temp_en;
        w(self, 8, &c);
        self.temp_s1 = 0;
        self.temp_s2 = self.temp_en;
        w(self, 8, &c);
        self.temp_s1 = 0;
        self.temp_s2 = 0;
        w(self, 5, &c);
        w(self, 32, &c);
        return c;
    }
};

const testing = std.testing;

test "command list lengths match upstream" {
    var r = Rhd2000Registers.init(30000.0);
    try testing.expectEqual(60, r.commandListRegisterConfig(true).len);
    try testing.expectEqual(60, r.commandListTempSensor().len);
    try testing.expectEqual(60, r.commandListUpdateDigOut().len);
}

test "default bandwidths are sane" {
    var r = Rhd2000Registers.init(30000.0);
    const up = r.setUpperBandwidth(7500.0);
    const lo = r.setLowerBandwidth(1.0);
    try testing.expect(@abs(up - 7500.0) / 7500.0 < 0.1);
    try testing.expect(@abs(lo - 1.0) < 0.2);
    const dsp = r.setDspCutoffFreq(0.5);
    try testing.expect(dsp > 0.1 and dsp < 2.0);
}

test "register 0 matches known value" {
    const r = Rhd2000Registers.init(30000.0);
    // adcRefBw=3, fastSettle=0, vref=1, cmpBias=3, cmpSel=2 -> 0b11011110
    try testing.expectEqual(0xDE, r.registerValue(0));
}
