//! The neural display: its panels, what the user's input does to them, and what is drawn
//! each frame (traces, overlays, labels, badges).

const std = @import("std");
const oez = @import("oez");
const gpu_mod = @import("gpu.zig");
const Gpu = gpu_mod.Gpu;
const font = @import("font.zig");
const theme = @import("theme.zig");
const format = @import("format.zig");
const fmtSpan = format.fmtSpan;
const fmtScale = format.fmtScale;
const control = @import("control.zig");
const notes_mod = @import("notes.zig");
const tiles_mod = @import("tiles.zig");
const tile_link = @import("tile_link.zig");
const Args = @import("args.zig").Args;
const Input = @import("window.zig").Input;
const panels_mod = oez.panels;
const Panel = panels_mod.Panel;
const log = std.log.scoped(.oez);

pub const max_text_vertices = 24 * 1024;

/// Per panel: two dividers, the target bar, and the sweep cursor's two.
pub const max_fills = 5 * panels_mod.max_panels;

/// One draw per panel, or per overlaid sweep of a triggered panel.
pub const max_draws = panels_mod.max_panels * oez.sweeps.max_sweeps;

/// The display filter for a panel's title: "   300-6000 Hz", "   > 10 Hz", "   < 300 Hz",
/// or nothing when the panel shows its channels as they are.
pub fn fmtBand(buf: []u8, p: *const Panel) []const u8 {
    if (p.kind != .electrode) return "";
    if (!p.filter.on) return if (p.carActive()) "   CAR" else "";
    const lo = p.filter.low_hz;
    const hi = p.filter.high_hz;
    const car: []const u8 = if (p.carActive()) "   CAR" else "";
    return if (lo > 0 and hi > 0)
        format.fmt(buf, "   {d}-{d} Hz{s}", .{ lo, hi, car })
    else if (lo > 0)
        format.fmt(buf, "   > {d} Hz{s}", .{ lo, car })
    else if (hi > 0)
        format.fmt(buf, "   < {d} Hz{s}", .{ hi, car })
    else
        format.fmt(buf, "   filter: no corners{s}", .{car});
}

/// An electrode channel by headstage and number ("A1-5"), or "ch 37" if it is not one.
pub fn channelName(buf: []u8, layout: *const oez.types.Layout, ch: u32) []const u8 {
    return layout.channelName(buf, ch);
}

/// What `Display.frame` needs of the GPU: the display's size in pixels, the shape of the
/// sample history, and where the rows' own scales go (`Gpu.row_gains`, mapped memory that
/// the shader reads; `frame` writes into it).
pub const Surface = struct {
    width: u32,
    height: u32,
    /// Columns of the sample history.
    nch: usize,
    /// Samples the history holds (a power of two).
    hist_cap: usize,
    row_gains: []f32,

    pub fn of(gpu: *const Gpu) Surface {
        return .{
            .width = gpu.extent.width,
            .height = gpu.extent.height,
            .nch = gpu.nch,
            .hist_cap = gpu.hist_cap,
            .row_gains = gpu.row_gains,
        };
    }
};

/// How the display is doing: what its corner read-out and the control window show,
/// refreshed once a second, and the alarm or warning to put across it.
pub const Status = struct {
    valid: bool = false,
    latency_ms: f64 = 0,
    fps: u64 = 0,
    /// Blocks the display missed (the recording does not depend on these).
    lost: u64 = 0,
    recording: bool = false,
    rec_seconds: f64 = 0,
    /// Something is wrong with what is being acquired or recorded (text for a banner
    /// across the display, until acknowledged), or a milder warning.
    alarm_buf: [200]u8 = undefined,
    alarm_len: usize = 0,
    warning_buf: [120]u8 = undefined,
    warning_len: usize = 0,

    pub fn alarm(self: *const Status) []const u8 {
        return self.alarm_buf[0..self.alarm_len];
    }
    pub fn warning(self: *const Status) []const u8 {
        return self.warning_buf[0..self.warning_len];
    }
};

/// The display in scroll-back review: where it is looking.
pub const ReviewView = struct {
    /// The sample at the right edge of every panel in review.
    end: i64,
    /// Drawn from the review history (the recording's file) instead of the live one.
    from_file: bool,
    /// The stretch needed is there to draw.
    ready: bool,
    behind_s: f64,
};

/// What triggers a panel's sweeps: "TTL2", or "row 5 falling -62 µV" (the trigger channel's
/// threshold `uv`, its sign the slope), or before that is known "row 5 falling 4.5 σ".
pub fn trigText(buf: []u8, p: *const Panel, uv: ?f32, sigmas: f32) []const u8 {
    if (p.trigger.source == .ttl) return format.fmt(buf, "TTL{d}", .{p.trigger.line});
    const v = uv orelse return format.fmt(buf, "row {d} falling {d} σ", .{ p.trigger.row + 1, sigmas });
    return format.fmt(buf, "row {d} {s} {d:.0} µV", .{ p.trigger.row + 1, if (v > 0) "rising" else "falling", v });
}

/// How many recent samples to filter again when a panel's corners change: what its window
/// can show (two passes in sweep mode), and a second more.
pub fn refilterSamples(set: *const panels_mod.Set, fs: f64) usize {
    var longest: f64 = 0;
    for (set.items[0..set.len]) |*p| longest = @max(longest, if (p.mode == .sweep) 2 * p.span_s else p.span_s);
    return @intFromFloat((longest + 1.0) * fs);
}

/// The spike detector works on the band 300 Hz to 6 kHz; the focused channel's threshold
/// is drawn on its row only where the row is filtered with corners within these limits
/// (inclusive), so that the line is read against about the signal it was set on.
pub const threshold_low_hz = [2]f64{ 250, 350 };
pub const threshold_high_hz = [2]f64{ 5000, 7000 };

/// Whether `row` of `p` shows about the detector's band (see `threshold_low_hz`).
pub fn showsDetectorBand(p: *const Panel, row: usize) bool {
    const lo = p.filter.low_hz;
    const hi = p.filter.high_hz;
    return p.rowFiltered(row) and lo >= threshold_low_hz[0] and lo <= threshold_low_hz[1] and
        hi >= threshold_high_hz[0] and hi <= threshold_high_hz[1];
}

/// The pixel row (its top edge) of a 1 px line at `value` (in the panel's unit) on panel
/// row `row` of `p`, drawn in `r`; null if the row is hidden. The shader puts a sample of
/// that value at y = r.y + (k + 0.5) * R - d * R, where k is the row's place among the rows
/// drawn, R = r.h / rows drawn and d = value / p.rowScale(row) clamped to ±1.5 rows (the
/// shader's NDC centre and gain, through the viewport). The trace is ±0.75 px about that
/// y; the pixel whose centre is nearest it is floor(y).
pub fn levelPixelY(p: *const Panel, r: panels_mod.Rect, row: usize, value: f64) ?f32 {
    const k = p.shownIndex(row) orelse return null;
    const row_h = @as(f64, @floatFromInt(r.h)) / @as(f64, @floatFromInt(@max(p.shownRows(), 1)));
    const d = std.math.clamp(value / p.rowScale(row), -1.5, 1.5);
    const y = @as(f64, @floatFromInt(r.y)) + (@as(f64, @floatFromInt(k)) + 0.5) * row_h - d * row_h;
    return @floatCast(@floor(y));
}

/// The label of one row: the electrode's number on its headstage (with the headstage's name
/// when the panel spans more than one), or AUXn / ADCn.
pub fn rowLabel(buf: []u8, p: *const Panel, row: u32, layout: *const oez.types.Layout, set: *const panels_mod.Set) []const u8 {
    const ch = p.first_ch + row;
    switch (p.kind) {
        .ttl => {
            const line = p.ttl_lines[@min(row, 7)];
            const name = set.ttlName(line);
            return if (name.len > 0) name else format.fmt(buf, "TTL{d}", .{line});
        },
        .electrode => {
            for (layout.headstageSlice()) |h| {
                if (ch < h.first_channel or ch >= h.first_channel + h.num_channels) continue;
                const n = ch - h.first_channel + 1;
                const within = p.first_ch >= h.first_channel and p.first_ch + p.rows <= h.first_channel + h.num_channels;
                if (!within) return layout.channelName(buf, ch);
                return format.fmt(buf, "{d}", .{n});
            }
            return format.fmt(buf, "{d}", .{ch + 1});
        },
        .aux => return format.fmt(buf, "AUX{d}", .{row + 1}),
        .adc => return format.fmt(buf, "ADC{d}", .{row + 1}),
    }
}

/// The panels of the display, and which one input goes to.
pub const Display = struct {
    set: panels_mod.Set,
    /// The panels as configured, for `r` (reset).
    initial: panels_mod.Set,
    /// The channel in focus (chosen by a click on its tile or its row), if any.
    focus: ?u32 = null,
    /// Every channel's detection threshold (the display's to change; the tile window is
    /// told them), and what the tile window last reported as in use (it knows the noise).
    thresholds: oez.thresholds.Thresholds = .{},
    reported: oez.thresholds.Reported = .{},
    /// Set when `thresholds` changed (the control window is to be told).
    thresholds_changed: bool = false,
    /// The panel that wheel, pinch and keys act on.
    target: usize = 0,
    /// Set by a test script (`panel=`, `pointer=`); then it overrides the pointer.
    scripted_target: ?usize = null,
    /// Where the pointer is, as a fraction of the display's height (for the row under it).
    pointer_fy: f64 = 0,
    scripted_pointer: bool = false,
    /// The triggers of each panel's TTL line (used by panels in triggered mode).
    triggers: [panels_mod.max_panels]oez.sweeps.Triggers = @splat(.{}),

    /// Set by Shift+a (and the control window's button): the alarm banner has been seen.
    acknowledged: bool = false,
    /// The audio monitor's settings (which channels, volume, ...); `audio_dirty` when they
    /// have changed and the audio threads are to be told.
    audio: oez.audio.Settings = .{},
    audio_dirty: bool = true,
    audio_recalibrate: bool = false,
    /// The sound takes the panels' common average references.
    audio_car: bool = true,

    /// The pulses of each panel's tint line (see `Panel.tint_line`).
    pulses: [panels_mod.max_panels]oez.sweeps.Pulses = @splat(.{}),
    /// The slope trigger of each panel that triggers on one of its channels, and what its
    /// trigger list was made from (a change of source, line or row starts it afresh).
    slopes: [panels_mod.max_panels]?oez.slope.Slope = @splat(null),
    trig_made_from: [panels_mod.max_panels]u64 = @splat(0),

    /// The channels whose mean is the reference for `channel`: those of the first panel
    /// that has its reference on and `channel` among the rows it subtracts from. Fills
    /// `out` (as many as fit) and returns how many.
    pub fn carChannels(self: *const Display, channel: u32, out: []u32) usize {
        for (self.set.items[0..self.set.len]) |*p| {
            if (!p.carActive() or channel < p.first_ch or channel >= p.first_ch + p.rows) continue;
            if (!p.reference.sub.has(channel - p.first_ch)) continue;
            var n: usize = 0;
            for (0..p.rows) |r| {
                if (!p.reference.ref.has(r) or n == out.len) continue;
                out[n] = p.first_ch + @as(u32, @intCast(r));
                n += 1;
            }
            return n;
        }
        return 0;
    }

    /// What the spike tiles need to know: the channels listened to, and the panels'
    /// common average references (a channel takes the first panel's that subtracts from
    /// it).
    pub fn tileConfig(self: *const Display) tiles_mod.Config {
        var cfg: tiles_mod.Config = .{
            .focus = self.focus,
            .listening = self.audio.channels,
            .num_listening = if (self.audio.enabled) self.audio.num_channels else 0,
            .thresholds = self.thresholds,
        };
        for (self.set.items[0..self.set.len], 0..) |*p, g| {
            if (!p.carActive() or g >= oez.spikes.Car.max_groups) continue;
            var n: usize = 0;
            for (0..p.rows) |r| {
                if (!p.reference.ref.has(r) or n == oez.spikes.Car.max_ref) continue;
                cfg.car.ref[g][n] = p.first_ch + @as(u32, @intCast(r));
                n += 1;
            }
            cfg.car.ref_len[g] = @intCast(n);
            for (0..p.rows) |r| {
                const ch = p.first_ch + r;
                if (p.reference.sub.has(r) and ch < cfg.car.group_of.len and cfg.car.group_of[ch] < 0) cfg.car.group_of[ch] = @intCast(g);
            }
            cfg.use_car = true;
        }
        return cfg;
    }

    /// Brings the audio's references in line with the panels'. A change is a different
    /// signal, so the noise is measured again.
    pub fn refreshAudioCar(self: *Display) void {
        const a = &self.audio;
        for (a.channelSlice(), 0..) |ch, k| {
            var ref: [oez.audio.max_car_ref]u32 = undefined;
            const n = if (self.audio_car) self.carChannels(ch, &ref) else 0;
            if (n == a.car_len[k] and std.mem.eql(u32, ref[0..n], a.car_ref[k][0..n])) continue;
            a.car_len[k] = @intCast(n);
            @memcpy(a.car_ref[k][0..n], ref[0..n]);
            self.audio_dirty = true;
            self.audio_recalibrate = true;
        }
    }

    /// Listens to the first row of the first electrode panel.
    pub fn listenToFirst(self: *Display) void {
        self.audio.num_channels = 0;
        for (self.set.items[0..self.set.len]) |*p| {
            if (p.kind != .electrode or p.rows == 0) continue;
            self.audio.channels[0] = p.first_ch;
            self.audio.num_channels = 1;
            break;
        }
        self.audio_dirty = true;
    }

    pub fn listening(self: *const Display, channel: u32) bool {
        return std.mem.indexOfScalar(u32, self.audio.channelSlice(), channel) != null;
    }

    /// Puts `channel` in focus (null: nothing).
    pub fn setFocus(self: *Display, channel: ?u32) void {
        self.focus = channel;
    }

    /// Channel `ch`'s detection threshold in µV, if it is known: the fixed value, or else
    /// what the tile window reported. What the threshold line, a slope trigger's level and
    /// the control window show.
    pub fn thresholdUv(self: *const Display, ch: u32) ?f32 {
        return self.thresholds.known(&self.reported, ch);
    }

    /// Fixes channel `ch`'s threshold at `uv` (0: back to the noise).
    pub fn setThreshold(self: *Display, ch: u32, uv: f64) void {
        if (ch >= oez.thresholds.max) return;
        const was = self.thresholds.fixed_uv[ch];
        self.thresholds.set(ch, uv);
        if (self.thresholds.fixed_uv[ch] != was) self.thresholds_changed = true;
    }

    /// What was asked for in the tile window.
    pub fn tileRequest(self: *Display, request: tile_link.Request) void {
        switch (request) {
            .focus => |channel| self.setFocus(channel),
            .unfocus => self.setFocus(null),
            .listen => |l| self.listenClick(l.channel, l.add),
            .threshold => |t| self.applyThreshold(.{ .set = .{ .channel = t.channel, .uv = t.uv } }),
        }
    }

    /// A right click on an electrode row: listen to that channel alone, or with Ctrl add it
    /// to (or take it out of) what is listened to.
    pub fn listenClick(self: *Display, channel: u32, add: bool) void {
        const a = &self.audio;
        if (!add) {
            a.channels[0] = channel;
            a.num_channels = 1;
        } else if (std.mem.indexOfScalar(u32, a.channelSlice(), channel)) |at| {
            for (at..a.num_channels - 1) |k| a.channels[k] = a.channels[k + 1];
            a.num_channels -= 1;
        } else if (a.num_channels < a.channels.len) {
            a.channels[a.num_channels] = channel;
            a.num_channels += 1;
        }
        self.audio_dirty = true;
    }

    /// Looks for triggers in a block that starts at sample `first`: `samples` (`nch`
    /// interleaved, as acquired) for slope triggers, the digital `words` for TTL edges.
    pub fn feedBlock(self: *Display, first: i64, samples: []const i16, nch: usize, fs: f64, words: []const u16) void {
        for (self.set.items[0..self.set.len], self.triggers[0..self.set.len], self.pulses[0..self.set.len], 0..) |*p, *t, *pl, i| {
            const channel = p.triggerChannel();
            const made_from: u64 = if (channel != null) 0x100 + @as(u64, p.trigger.row) else p.trigger.line;
            if (self.trig_made_from[i] != made_from) {
                self.trig_made_from[i] = made_from;
                t.reset(p.trigger.line);
                self.slopes[i] = null;
            }
            if (channel) |ch| self.feedSlope(i, ch, first, samples, nch, fs) else t.feed(first, words);
            if (p.tint_line == 0) continue;
            if (pl.line != p.tint_line) pl.reset(p.tint_line);
            pl.feed(first, words);
        }
    }

    /// Panel `i`'s slope trigger on channel `ch`, fed a block, at that channel's threshold.
    /// A panel in triggered mode latches the threshold: if it follows the noise, it becomes
    /// fixed at what the tile window reported, or failing that at the trigger's own level
    /// once it has seen a second of signal.
    fn feedSlope(self: *Display, i: usize, ch: u32, first: i64, samples: []const i16, nch: usize, fs: f64) void {
        const p = &self.set.items[i];
        const triggering = p.mode == .triggered;
        if (triggering) self.latch(ch);
        const want = self.slopeSettings(ch, p.trigger.holdoff_ms);
        // A threshold that changed sides: the trigger starts afresh, as what it holds (the
        // previous sample and a search, folded for the slope) is the other slope's.
        if (self.slopes[i]) |sl| {
            if (sl.settings.rising != want.rising) self.slopes[i] = null;
        }
        if (self.slopes[i] == null) self.slopes[i] = .init(fs, want);
        const sl = &self.slopes[i].?;
        sl.settings = want;
        // With the panel's reference, if the trigger's row is one it applies to.
        var ref: [oez.audio.max_car_ref]u32 = undefined;
        const nref = self.carChannels(ch, &ref);
        sl.feed(first, samples, nch, ch, ref[0..nref], &self.triggers[i]);
        if (triggering and !self.thresholds.isFixed(ch) and sl.seen >= @as(u64, @intFromFloat(fs))) {
            // Following the noise, the level is below zero; anything else is no estimate.
            const level_uv = sl.level() * oez.types.electrode_uv_per_bit;
            if (level_uv < 0) self.setThreshold(ch, level_uv);
        }
    }

    /// What the slope trigger on channel `ch` is to do: trigger at its fixed threshold (the
    /// sign the slope), or follow the noise as a threshold that is not fixed does.
    fn slopeSettings(self: *const Display, ch: u32, holdoff_ms: f64) oez.slope.Settings {
        if (!self.thresholds.isFixed(ch)) return .{ .auto = true, .auto_sigmas = self.thresholds.sigmas, .holdoff_ms = holdoff_ms };
        const uv = self.thresholds.fixed_uv[ch];
        return .{ .rising = uv > 0, .auto = false, .level = uv / oez.types.electrode_uv_per_bit, .holdoff_ms = holdoff_ms };
    }

    /// If channel `ch`'s threshold follows the noise and the tile window has reported what
    /// it is, fixes it there: a channel that a panel triggers on has a fixed threshold.
    fn latch(self: *Display, ch: u32) void {
        if (self.thresholds.isFixed(ch)) return;
        const uv = self.reported.get(ch) orelse return;
        self.setThreshold(ch, uv);
    }

    /// Latches the threshold of every channel a panel in triggered mode triggers on.
    fn latchTriggered(self: *Display) void {
        for (self.set.items[0..self.set.len]) |*p| {
            if (p.mode != .triggered) continue;
            if (p.triggerChannel()) |ch| self.latch(ch);
        }
    }

    /// A panel in triggered mode triggers on channel `ch`.
    fn triggeredOn(self: *const Display, ch: u32) bool {
        for (self.set.items[0..self.set.len]) |*p| {
            if (p.mode == .triggered and p.triggerChannel() == ch) return true;
        }
        return false;
    }

    /// A change to the thresholds, from the control window (or a request of the tile
    /// window's). A channel a panel triggers on stays fixed: it is not returned to the
    /// noise; scaling or flipping one that follows the noise latches it first.
    pub fn applyThreshold(self: *Display, edit: control.ThresholdEdit) void {
        switch (edit) {
            .sigmas => |up| {
                const was = self.thresholds.sigmas;
                self.thresholds.stepSigmas(up);
                if (self.thresholds.sigmas != was) self.thresholds_changed = true;
            },
            .scale => |s| {
                self.latch(s.channel);
                if (self.thresholds.isFixed(s.channel)) self.setThreshold(s.channel, self.thresholds.fixed_uv[s.channel] * s.factor);
            },
            .flip => |ch| {
                self.latch(ch);
                if (self.thresholds.isFixed(ch)) self.setThreshold(ch, -self.thresholds.fixed_uv[ch]);
            },
            .set => |s| if (s.uv != 0) self.setThreshold(s.channel, s.uv) else self.applyThreshold(.{ .follow = s.channel }),
            .follow => |ch| if (!self.triggeredOn(ch)) self.setThreshold(ch, 0),
        }
    }

    pub fn init(set: panels_mod.Set) Display {
        return .{ .set = set, .initial = set };
    }

    /// Points input at the panel under the pointer (fractions of the display).
    pub fn pointAt(self: *Display, fx: f64, fy: f64) void {
        if (!self.scripted_pointer) self.pointer_fy = fy;
        if (self.scripted_target) |t| {
            self.target = t;
        } else if (self.set.at(fx, fy)) |t| self.target = t;
    }

    /// Puts a panel's settings back to what the config gave it.
    pub fn reset(self: *Display, index: usize) void {
        const p = &self.set.items[index];
        const was = &self.initial.items[index];
        // `initial` holds the config's values with this run's slots.
        p.* = was.*;
    }

    /// A change to the audio monitor's settings, from the control window.
    pub fn applyAudio(self: *Display, action: control.AudioAction) void {
        switch (action) {
            .enabled => |on| self.audio.enabled = on,
            .mute => |on| self.audio.mute = on,
            .volume => |up| self.audio.volume_db = std.math.clamp(self.audio.volume_db + (if (up) @as(f64, 2) else -2), -60, 12),
            .reference => |on| self.audio.reference = on,
            .car => |on| self.audio_car = on,
            .recalibrate => self.audio_recalibrate = true,
        }
        self.audio_dirty = true;
    }

    /// A change to panel `index`, from the control window.
    pub fn applyPanelEdit(self: *Display, index: usize, action: control.PanelAction) void {
        if (index >= self.set.len) return;
        const p = &self.set.items[index];
        switch (action) {
            .scale => |f| p.scale *= f,
            .zoom => |f| if (p.mode == .triggered) {
                p.trigger.pre_ms *= f;
                p.trigger.post_ms *= f;
            } else {
                p.span_s *= f;
            },
            .mode => |m| p.mode = m,
            .filter => |on| p.filter.on = on and p.kind == .electrode,
            .corner => |c| p.stepCorner(c.high, c.up),
            .trig_line => |l| p.trigger.line = l,
            .row_hidden => |row| p.per_row.hidden.set(row, !p.per_row.hidden.has(row)),
            .row_raw => |row| p.per_row.raw.set(row, !p.per_row.raw.has(row)),
            .car => |on| p.setCar(on),
            .car_ref_row => |r| p.reference.ref.set(r, !p.reference.ref.has(r)),
            .car_sub_row => |r| p.reference.sub.set(r, !p.reference.sub.has(r)),
            .car_ref_all => |on| p.reference.ref = if (on) .all(p.rows) else .{},
            .car_sub_all => |on| p.reference.sub = if (on) .all(p.rows) else .{},
            .trig_source => |s| p.setTrigSource(s),
            .trig_row => |d| p.trigger.row = @intCast(std.math.clamp(@as(i64, p.trigger.row) + d, 0, @as(i64, p.rows) - 1)),
            .trig_holdoff => |up| p.trigger.holdoff_ms = oez.board_config.step(
                f64,
                &.{ 0, 1, 2, 5, 10, 20, 50, 100, 200, 500 },
                p.trigger.holdoff_ms,
                up,
            ),
            .overlay => |n| p.trigger.overlay = n,
            .reset => self.reset(index),
        }
        p.clamp();
        // A panel that has begun to trigger on a channel (its mode, source or row).
        self.latchTriggered();
    }

    /// Applies what the user did to the target panel. True means quit.
    pub fn applyInput(self: *Display, in: Input) bool {
        if (self.scripted_target) |t| self.target = t;
        var quit = false;
        for (in.keys[0..in.num_keys]) |k| {
            if (k.isNamed(.escape) or k.is('q')) quit = true;
        }
        if (self.set.len == 0) return quit;
        const p = &self.set.items[self.target];
        // One wheel click (about 15 units) changes a scale by 15 %.
        const per_unit = 0.0093;
        var sx = in.scroll_x;
        var sy = in.scroll_y;
        if (in.shift) {
            sx += sy;
            sy = 0;
        }
        if (sy != 0) {
            // Ctrl: the row under the pointer alone.
            if (in.ctrl) {
                if (p.rowAt(self.pointer_fy)) |row| p.scaleRow(row, @exp(sy * per_unit));
            } else p.scale *= @exp(sy * per_unit);
        }
        // The time base; in triggered mode, the window around the trigger.
        var zoom: f64 = 1;
        if (sx != 0) zoom *= @exp(sx * per_unit);
        // Fingers apart = zoom in = less time across the panel.
        if (in.pinch != 1 and in.pinch > 0) zoom /= in.pinch;
        for (in.keys[0..in.num_keys]) |k| {
            if (k.is('[')) zoom *= 1.25;
            if (k.is(']')) zoom /= 1.25;
        }
        if (p.mode == .triggered) {
            p.trigger.pre_ms *= zoom;
            p.trigger.post_ms *= zoom;
        } else p.span_s *= zoom;
        for (in.keys[0..in.num_keys]) |k| switch (k) {
            .named => {},
            .char => |c| switch (c) {
                '-' => p.scale *= 1.25,
                '=' => p.scale /= 1.25,
                'r' => self.reset(self.target),
                'f' => p.filter.on = p.kind == .electrode and !p.filter.on,
                ',' => if (p.filter.on) p.stepCorner(false, false),
                '.' => if (p.filter.on) p.stepCorner(false, true),
                ';' => if (p.filter.on) p.stepCorner(true, false),
                '\'' => if (p.filter.on) p.stepCorner(true, true),
                'm' => p.mode = if (p.mode == .scroll) .sweep else .scroll,
                // Shift+a; plain a is the tile window's autoscale key.
                'a' => if (in.shift) {
                    self.acknowledged = true;
                },
                // Triggered mode: s switches between a TTL line and spikes on the row under
                // the pointer.
                's' => if (p.mode == .triggered) {
                    if (p.trigger.source == .ttl) {
                        p.setTrigSource(.channel);
                        if (p.rowAt(self.pointer_fy)) |row| p.trigger.row = @intCast(row);
                    } else p.setTrigSource(.ttl);
                },
                't' => p.mode = if (p.mode == .triggered) .scroll else .triggered,
                // Triggered on a TTL line: the digits pick the line.
                '1'...'8' => if (p.mode == .triggered and p.trigger.source == .ttl) {
                    p.trigger.line = c - '0';
                },
                else => {},
            },
        };
        // On an electrode row a left click focuses its channel, a right click listens to it
        // (Ctrl: adds or removes it). A middle click anywhere clears the focus.
        if (p.kind == .electrode) {
            if (p.rowAt(self.pointer_fy)) |row| {
                const channel = p.first_ch + @as(u32, @intCast(row));
                if (in.clicks > 0) self.setFocus(channel);
                if (in.right_clicks > 0) self.listenClick(channel, in.ctrl);
            }
        }
        if (in.middle_clicks > 0) self.setFocus(null);
        // A click on a row of a spike-triggered panel moves the trigger to that row.
        if (in.clicks > 0 and p.mode == .triggered and p.trigger.source == .channel) {
            if (p.rowAt(self.pointer_fy)) |row| p.trigger.row = @intCast(row);
        }
        p.clamp();
        // A panel that has begun to trigger on a channel (s, t, r, or that click).
        self.latchTriggered();
        return quit;
    }

    /// What to draw: each panel's traces, then dividers and a bar marking the target panel,
    /// and into `batch` the text: each panel's title (name, time base, scale per row), its
    /// row labels, and the status read-out in the bottom right corner.
    pub fn frame(
        self: *const Display,
        surface: Surface,
        layout: *const oez.types.Layout,
        newest: i64,
        review: ?ReviewView,
        status: Status,
        notes: *const notes_mod.Notes,
        batch: *font.Batch,
        draws: *[max_draws]gpu_mod.PanelDraw,
        fills: *[max_fills]gpu_mod.Fill,
    ) struct { draws: []const gpu_mod.PanelDraw, fills: []const gpu_mod.Fill, text: []const font.Vertex } {
        const width = surface.width;
        const height = surface.height;
        const fs = layout.sample_rate;
        batch.clear();
        var o: Output = .{ .draws = draws, .fills = fills, .batch = batch, .line_h = @round(batch.font.line_height) };
        const scene: Scene = .{ .surface = surface, .layout = layout, .newest = newest, .review = review, .notes = notes };
        for (self.set.items[0..self.set.len], 0..) |*p, i| self.drawPanel(&o, &scene, p, i);
        if (o.line_h > 0 and (status.alarm_len > 0 or status.warning_len > 0)) alarmBar(&o, status, review != null, width);
        if (review) |v| {
            if (o.line_h > 0) reviewBadge(&o, v, width, fs);
        }
        if (notes.editing and o.line_h > 0) noteDraft(&o, notes, height, fs);
        if (status.valid and o.line_h > 0) statusReadout(&o, status, width, height);
        if (self.set.len > 1) targetBar(&o, self.set.items[self.target].pixelRect(width, height));
        return .{ .draws = draws[0..o.nd], .fills = fills[0..o.nf], .text = batch.vertices[0..batch.len] };
    }

    /// One panel, from the bottom up: its traces (and, triggered, the marks over them), the
    /// notes, the tint, the sweep cursor, the dividers, then its text.
    fn drawPanel(self: *const Display, o: *Output, scene: *const Scene, p: *const Panel, i: usize) void {
        const fs = scene.layout.sample_rate;
        const r = p.pixelRect(scene.surface.width, scene.surface.height);
        const t = panelTime(p, scene.newest, scene.review, fs);
        const params = traceParams(p, i, r, t, scene.surface);
        setRowGains(scene.surface.row_gains, p, i);
        const rect: gpu_mod.PixelRect = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
        var shown_sweeps: usize = 0;
        if (t.trig) |win| {
            shown_sweeps = self.sweepDraws(o, p, i, rect, params, win, scene.newest, scene.surface.hist_cap, fs);
            self.triggerMarks(o, p, i, r, win, scene.newest, shown_sweeps);
        } else if (o.nd < o.draws.len and !t.waiting) {
            o.draws[o.nd] = .{ .rect = rect, .params = params, .review = t.from_file };
            o.nd += 1;
        }
        self.thresholdLine(o, p, r);
        if (p.mode != .triggered and t.span >= 1) noteMarks(o, r, t, scene.notes);
        if (p.tint_line != 0 and p.mode != .triggered and t.span >= 1) tintPulses(o, p, r, t, &self.pulses[i]);
        if (t.sweeping) sweepCursor(o, r, t);
        dividers(o, r);
        if (o.line_h <= 0) return;
        var trig_buf: [48]u8 = undefined;
        const trig_uv = if (p.triggerChannel()) |ch| self.thresholdUv(ch) else null;
        panelTitle(o, p, r, t.in_review, shown_sweeps, trigText(&trig_buf, p, trig_uv, self.thresholds.sigmas));
        if (p.mode == .triggered) timeAxis(o, p, r);
        self.rowLabels(o, p, r, scene.layout);
    }

    /// One draw per sweep of a triggered panel, oldest first and dimmest, the newest on
    /// top. Returns how many were drawn.
    fn sweepDraws(
        self: *const Display,
        o: *Output,
        p: *const Panel,
        i: usize,
        rect: gpu_mod.PixelRect,
        base: gpu_mod.TraceParams,
        win: TrigWindow,
        newest: i64,
        hist_cap: usize,
        fs: f64,
    ) usize {
        const trig = &self.triggers[i];
        const pre = win.pre;
        const post = win.post;
        const window = win.window;
        var params = base;
        var shown_sweeps: usize = 0;
        // Sweeps whose samples the history may no longer hold are left out.
        const keep: i64 = @as(i64, @intCast(hist_cap)) - @as(i64, @intFromFloat(fs));
        var k: usize = @min(p.trigger.overlay, trig.len);
        while (k > 0) {
            k -= 1;
            const s = trig.recent(k).?;
            if (newest - (s.t0 - pre) > keep) continue;
            const end = s.t0 + post;
            const future: f64 = @floatFromInt(@max(0, end - newest));
            if (window - future < 2 * window / @as(f64, @floatFromInt(rect.w)) + 2) continue;
            params.newest = @truncate(@as(u64, @bitCast(end)));
            params.span = @floatCast(window);
            params.phase = -1;
            params.future = @floatCast(future);
            params.gain = if (k == 0) 1.0 else 0.6 - 0.4 * @as(f32, @floatFromInt(k - 1)) /
                @as(f32, @floatFromInt(@max(1, p.trigger.overlay -| 2)));
            if (o.nd < o.draws.len) {
                o.draws[o.nd] = .{ .rect = rect, .params = params };
                o.nd += 1;
                shown_sweeps += 1;
            }
        }
        return shown_sweeps;
    }

    /// Over a triggered panel's traces: the slope trigger's level, or when the trigger line
    /// was high in the newest sweep (the laser); then a line at the trigger.
    fn triggerMarks(
        self: *const Display,
        o: *Output,
        p: *const Panel,
        i: usize,
        r: panels_mod.Rect,
        win: TrigWindow,
        newest: i64,
        shown_sweeps: usize,
    ) void {
        const batch = o.batch;
        const trig = &self.triggers[i];
        const pre = win.pre;
        const post = win.post;
        const window = win.window;
        const px: f32 = @floatFromInt(r.x);
        const py: f32 = @floatFromInt(r.y);
        const shown = p.shownRows();
        const w: f32 = @floatFromInt(r.w);
        const x0 = px + w * @as(f32, @floatFromInt(pre)) / @as(f32, @floatCast(window));
        if (p.trigger.source == .channel) {
            // The level (the trigger channel's threshold, once known), as a line across the
            // trigger's row (in the row's own scale: it sits on the trace when the panel
            // shows the spike band).
            const row_h = @as(f32, @floatFromInt(r.h)) / @as(f32, @floatFromInt(@max(shown, 1)));
            const centre = py + (@as(f32, @floatFromInt(p.shownIndex(p.trigger.row) orelse 0)) + 0.5) * row_h;
            if (self.thresholdUv(p.first_ch + p.trigger.row)) |uv| {
                const dy: f32 = @floatCast(std.math.clamp(uv / p.rowScale(p.trigger.row), -1.5, 1.5));
                var x = px;
                if (p.shownIndex(p.trigger.row) != null)
                    while (x < px + w) : (x += 12) batch.rect(x, @round(centre - dy * row_h), 6, 1, theme.trigger_level);
            }
        } else if (trig.recent(0)) |s| {
            const until = @min(s.fall orelse newest, s.t0 + post);
            const x1 = px + w * @as(f32, @floatFromInt(until - s.t0 + pre)) / @as(f32, @floatCast(window));
            if (shown_sweeps > 0 and x1 > x0) batch.rect(x0, py, x1 - x0, @floatFromInt(r.h), theme.tint_pulse);
        }
        batch.rect(@round(x0), py, 1, @floatFromInt(r.h), theme.trigger_line);
    }

    /// The row of the focused channel in panel `p`, if the panel has it.
    fn focusedRow(self: *const Display, p: *const Panel) ?usize {
        const ch = self.focus orelse return null;
        if (p.kind != .electrode or ch < p.first_ch or ch >= p.first_ch + p.rows) return null;
        return ch - p.first_ch;
    }

    /// The focused channel's detection threshold (if known), as a line across its row where
    /// the row is drawn and shows about the detector's band.
    fn thresholdLine(self: *const Display, o: *Output, p: *const Panel, r: panels_mod.Rect) void {
        const row = self.focusedRow(p) orelse return;
        const uv = self.thresholdUv(self.focus.?) orelse return;
        if (!showsDetectorBand(p, row)) return;
        const y = levelPixelY(p, r, row, uv) orelse return;
        o.batch.rect(@floatFromInt(r.x), y, @floatFromInt(r.w), 1, theme.tile_threshold);
    }

    /// The row is in focus or listened to: its label carries a mark, so it is always shown.
    fn rowMarked(self: *const Display, p: *const Panel, row: u32) bool {
        if (p.kind != .electrode) return false;
        return self.focusedRow(p) == row or (self.audio.enabled and self.listening(p.first_ch + row));
    }

    /// Row labels down the left edge, thinned when rows are shorter than a line.
    fn rowLabels(self: *const Display, o: *Output, p: *const Panel, r: panels_mod.Rect, layout: *const oez.types.Layout) void {
        const batch = o.batch;
        const line_h = o.line_h;
        const px: f32 = @floatFromInt(r.x);
        const py: f32 = @floatFromInt(r.y);
        const title_y = py + 6;
        const shown = p.shownRows();
        if (shown == 0) return;
        const row_h = @as(f32, @floatFromInt(r.h)) / @as(f32, @floatFromInt(shown));
        const step: u32 = @max(1, @as(u32, @intFromFloat(@ceil((line_h + 3) / row_h))));
        var k: u32 = 0;
        while (k < shown) : (k += 1) {
            // The `k`-th row drawn is panel row `row` (hidden rows are left out).
            const row: u32 = @intCast(p.rowOfShown(k) orelse continue);
            // Thinned: every `step`-th row is labelled. A row in focus or listened to is
            // always labelled, and takes the place of the regular labels it would overlap.
            if (!self.rowMarked(p, row)) {
                if (k % step != 0) continue;
                var near = k -| (step - 1);
                const crowded = while (near < @min(shown, k + step)) : (near += 1) {
                    if (p.rowOfShown(near)) |other| {
                        if (self.rowMarked(p, @intCast(other))) break true;
                    }
                } else false;
                if (crowded) continue;
            }
            const y = py + (@as(f32, @floatFromInt(k)) + 0.5) * row_h - 0.5 * line_h;
            if (p.kind != .ttl and y < title_y + line_h + 3) continue;
            var name_buf: [16]u8 = undefined;
            var label_buf: [24]u8 = undefined;
            // The focused row is amber; a row listened to has a note before its label.
            const name = rowLabel(&name_buf, p, row, layout, &self.set);
            const heard = p.kind == .electrode and self.audio.enabled and self.listening(p.first_ch + row);
            const focused = self.focusedRow(p) == row;
            var after = batch.label(
                px + 5,
                y,
                if (heard) format.fmt(&label_buf, "♪ {s}", .{name}) else name,
                if (focused) theme.focus else theme.text_dim,
            );
            // In a filtered panel, the rows shown as they are say so.
            if (p.filter.on and p.kind == .electrode and !p.rowFiltered(row)) after = batch.label(after + 4, y, "raw", theme.text_dim);
            // The focused row with a threshold that is not drawn, because the row does not
            // show the detector's band, says so.
            if (focused and self.thresholdUv(p.first_ch + row) != null and !showsDetectorBand(p, row))
                after = batch.label(after + 4, y, "thr", theme.text_dim);
            // A row with a scale of its own says so.
            if (row < panels_mod.max_rows and p.per_row.gain[row] != 1) {
                var own_buf: [24]u8 = undefined;
                _ = batch.label(after + 4, y, fmtScale(&own_buf, p.kind, p.rowScale(row)), theme.row_scale_text);
            }
        }
    }
};

/// What one frame is drawn into: the trace draws, the fills and the batch of text and
/// rectangles, each in the order drawn (later is on top).
const Output = struct {
    draws: *[max_draws]gpu_mod.PanelDraw,
    fills: *[max_fills]gpu_mod.Fill,
    batch: *font.Batch,
    nd: usize = 0,
    nf: usize = 0,
    /// The font's line height in whole pixels; 0 without a font, and then no text.
    line_h: f32,
};

/// What one frame is drawn from, besides the display's own state.
const Scene = struct {
    surface: Surface,
    layout: *const oez.types.Layout,
    newest: i64,
    review: ?ReviewView,
    notes: *const notes_mod.Notes,
};

/// The window around each trigger of a triggered panel, in samples.
const TrigWindow = struct {
    pre: i64,
    post: i64,
    /// `pre + post`.
    window: f64,
};

/// What stretch of time a panel shows.
const PanelTime = struct {
    /// Samples across the panel (a whole number of them in sweep mode).
    span: f64,
    /// The sample at the right edge (sweep: at the cursor): the review position in review,
    /// else the newest sample.
    t_end: i64,
    /// The panel shows the review stretch.
    in_review: bool,
    /// In review from the recording's file: drawn from the review history.
    from_file: bool,
    /// In review, and the stretch is not there to draw yet.
    waiting: bool,
    /// Sweep mode, live: the cursor runs across the panel.
    sweeping: bool,
    /// Sweeping: samples since the current pass began; else -1.
    phase: f64,
    /// Triggered: the window around each trigger.
    trig: ?TrigWindow,

    /// The first sample of the current pass (sweeping), or at the left edge.
    fn passStart(self: PanelTime) i64 {
        const span_i: i64 = @intFromFloat(self.span);
        return if (self.sweeping) self.t_end - @as(i64, @intFromFloat(self.phase)) else self.t_end - span_i;
    }
};

/// What time panel `p` shows: live or the review stretch, the sweep's pass and phase, the
/// window around a trigger.
fn panelTime(p: *const Panel, newest: i64, review: ?ReviewView, fs: f64) PanelTime {
    // Sweep: a whole number of samples per pass, so the picture stands still.
    const span: f64 = if (p.mode == .sweep) @max(1, @round(p.span_s * fs)) else p.span_s * fs;
    // In review a panel shows a fixed stretch that ends at the review position
    // (triggered panels stay live: their sweeps are about now).
    const in_review = review != null and p.mode != .triggered;
    const t_end: i64 = if (in_review) review.?.end else newest;
    const sweeping = p.mode == .sweep and !in_review;
    const phase: f64 = if (sweeping) @floatFromInt(@mod(t_end, @as(i64, @intFromFloat(span)))) else -1;
    var trig: ?TrigWindow = null;
    if (p.mode == .triggered) {
        const pre: i64 = @intFromFloat(@round(p.trigger.pre_ms * 1e-3 * fs));
        const post: i64 = @max(1, @as(i64, @intFromFloat(@round(p.trigger.post_ms * 1e-3 * fs))));
        trig = .{ .pre = pre, .post = post, .window = @floatFromInt(pre + post) };
    }
    return .{
        .span = span,
        .t_end = t_end,
        .in_review = in_review,
        .from_file = in_review and review.?.from_file,
        .waiting = in_review and !review.?.ready,
        .sweeping = sweeping,
        .phase = phase,
        .trig = trig,
    };
}

/// The shader's parameters for panel `i`, showing the stretch `t` (a triggered panel's
/// sweeps change some of them).
fn traceParams(p: *const Panel, i: usize, r: panels_mod.Rect, t: PanelTime, surface: Surface) gpu_mod.TraceParams {
    return .{
        .nch = @intCast(surface.nch),
        .cap_mask = @intCast(surface.hist_cap - 1),
        .newest = @truncate(@as(u64, @bitCast(t.t_end))),
        .first_ch = p.drawColumn(),
        .cols = r.w,
        .rows = p.shownRows(),
        .span = @floatCast(t.span),
        .lsb_per_row = @floatCast(p.scale / p.unitsPerLsb()),
        .half_px = 1.5 / @as(f32, @floatFromInt(r.h)),
        .phase = @floatCast(t.phase),
        .gain_base = @intCast(i * gpu_mod.max_rows),
    };
}

/// The rows' own scales of panel `i`, for the shader, in the order the rows are drawn.
fn setRowGains(row_gains: []f32, p: *const Panel, i: usize) void {
    const shown = p.shownRows();
    if (row_gains.len >= (i + 1) * gpu_mod.max_rows) {
        const gains = row_gains[i * gpu_mod.max_rows ..][0..gpu_mod.max_rows];
        for (0..@min(shown, gpu_mod.max_rows)) |k| gains[k] = p.per_row.gain[p.rowOfShown(k) orelse k];
    }
}

/// Notes: a line where each was stamped, with its text beside it.
fn noteMarks(o: *Output, r: panels_mod.Rect, t: PanelTime, notes: *const notes_mod.Notes) void {
    const batch = o.batch;
    const line_h = o.line_h;
    const span = t.span;
    const t_end = t.t_end;
    const sweeping = t.sweeping;
    const px: f32 = @floatFromInt(r.x);
    const py: f32 = @floatFromInt(r.y);
    const w: f64 = @floatFromInt(r.w);
    const span_i: i64 = @intFromFloat(span);
    const pass_start: i64 = t.passStart();
    var k: usize = 0;
    while (notes.recentNote(k)) |note| : (k += 1) {
        const at = note.sample;
        // Not `break`: notes are kept in the order they were saved, and a typed note is
        // stamped when it was begun, so an older one can come before a newer.
        if (at < pass_start - span_i) continue;
        // This pass (or, scrolling, the window); else the previous pass, where
        // the cursor has not yet gone over it.
        const from: i64 = if (at >= pass_start)
            pass_start
        else if (sweeping and at >= pass_start - span_i + (t_end - pass_start))
            pass_start - span_i
        else
            continue;
        if (at > t_end) continue;
        const x = px + @as(f32, @floatCast(w * @as(f64, @floatFromInt(at - from)) / span));
        batch.rect(@round(x), py, 1, @floatFromInt(r.h), theme.note_line);
        if (line_h > 0 and x + 60 < px + @as(f32, @floatCast(w)))
            _ = batch.label(x + 5, py + line_h + 12, notes_mod.prefix(note.text(), 40), theme.note_text);
    }
}

/// A tint over the panel wherever its tint line was high. Scrolling: time runs to the
/// newest sample at the right edge. Sweep: this pass left of the cursor, the previous pass
/// right of it.
fn tintPulses(o: *Output, p: *const Panel, r: panels_mod.Rect, t: PanelTime, pulses: *const oez.sweeps.Pulses) void {
    const batch = o.batch;
    const span = t.span;
    const t_end = t.t_end;
    const px: f32 = @floatFromInt(r.x);
    const py: f32 = @floatFromInt(r.y);
    const w: f64 = @floatFromInt(r.w);
    const span_i: i64 = @intFromFloat(span);
    const pass_start: i64 = t.passStart();
    var k: usize = 0;
    while (pulses.recent(k)) |pulse| : (k += 1) {
        const t0 = pulse.t0;
        const t1 = pulse.fall orelse t_end;
        if (t1 < t_end - 2 * span_i) break;
        // The stretch of the pulse in this pass (or, scrolling, in the window).
        const a0 = @max(t0, pass_start);
        const a1 = @min(t1, t_end);
        if (a1 > a0) batch.rect(
            px + @as(f32, @floatCast(w * @as(f64, @floatFromInt(a0 - pass_start)) / span)),
            py,
            @floatCast(@max(1.0, w * @as(f64, @floatFromInt(a1 - a0)) / span)),
            @floatFromInt(r.h),
            theme.tint_pulse,
        );
        if (p.mode != .sweep) continue;
        // And in the previous pass, as far as the cursor has not overwritten it.
        const prev = pass_start - span_i;
        const b0 = @max(t0, prev + (t_end - pass_start));
        const b1 = @min(t1, pass_start);
        if (b1 > b0) batch.rect(
            px + @as(f32, @floatCast(w * @as(f64, @floatFromInt(b0 - prev)) / span)),
            py,
            @floatCast(@max(1.0, w * @as(f64, @floatFromInt(b1 - b0)) / span)),
            @floatFromInt(r.h),
            theme.tint_pulse,
        );
    }
}

/// The sweep's cursor: a line where the newest sample is, and a blank stretch ahead.
fn sweepCursor(o: *Output, r: panels_mod.Rect, t: PanelTime) void {
    const cx: u32 = @min(r.w - 1, @as(u32, @intFromFloat(t.phase / t.span * @as(f64, @floatFromInt(r.w)))));
    o.fills[o.nf] = .{ .rect = .{ .x = r.x + cx, .y = r.y, .w = @min(10, r.w - cx), .h = r.h }, .colour = theme.background };
    o.fills[o.nf + 1] = .{ .rect = .{ .x = r.x + cx, .y = r.y, .w = 1, .h = r.h }, .colour = theme.sweep_cursor };
    o.nf += 2;
}

/// A line along the left and top edges of a panel that are not the display's own.
fn dividers(o: *Output, r: panels_mod.Rect) void {
    if (r.x > 0) {
        o.fills[o.nf] = .{ .rect = .{ .x = r.x, .y = r.y, .w = 1, .h = r.h }, .colour = theme.panel_divider };
        o.nf += 1;
    }
    if (r.y > 0) {
        o.fills[o.nf] = .{ .rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = 1 }, .colour = theme.panel_divider };
        o.nf += 1;
    }
}

/// A panel's title, top left (a TTL lane strip's top right): its name, time base or
/// trigger window (and what triggers it, `trig`), scale and band.
fn panelTitle(o: *Output, p: *const Panel, r: panels_mod.Rect, in_review: bool, shown_sweeps: usize, trig: []const u8) void {
    const batch = o.batch;
    const px: f32 = @floatFromInt(r.x);
    const py: f32 = @floatFromInt(r.y);
    const title_y = py + 6;
    var span_buf: [24]u8 = undefined;
    var scale_buf: [24]u8 = undefined;
    var title_buf: [128]u8 = undefined;
    var band_buf: [48]u8 = undefined;
    // A TTL panel has no scale to name.
    var per_row_buf: [32]u8 = undefined;
    const per_row = if (p.kind == .ttl) "" else format.fmt(&per_row_buf, "   {s}/row", .{fmtScale(&scale_buf, p.kind, p.scale)});
    const title = if (p.mode == .triggered)
        format.fmt(&title_buf, "{s}   {s}   -{d:.1}/+{d:.1} ms{s}{s}   {d} sweeps{s}", .{
            p.name(),
            trig,
            p.trigger.pre_ms,
            p.trigger.post_ms,
            per_row,
            fmtBand(&band_buf, p),
            shown_sweeps,
            if (shown_sweeps == 0) " (waiting for a trigger)" else "",
        })
    else if (p.kind == .ttl)
        format.fmt(&title_buf, "{s}   {s}{s}", .{
            p.name(),
            fmtSpan(&span_buf, p.span_s),
            if (in_review) "   review" else if (p.mode == .sweep) "   sweep" else "",
        })
    else
        format.fmt(&title_buf, "{s}   {s}{s}{s}{s}", .{
            p.name(),
            fmtSpan(&span_buf, p.span_s),
            per_row,
            fmtBand(&band_buf, p),
            if (in_review) "   review" else if (p.mode == .sweep) "   sweep" else "",
        });
    // A lane strip is short: its title goes to the right, clear of the lane labels.
    _ = batch.label(
        if (p.kind == .ttl) px + @as(f32, @floatFromInt(r.w)) - batch.font.width(title) - 8 else px + 8,
        title_y,
        title,
        theme.text_bright,
    );
}

/// A triggered panel's time axis along the bottom: the ends of the window and the trigger.
fn timeAxis(o: *Output, p: *const Panel, r: panels_mod.Rect) void {
    const batch = o.batch;
    const line_h = o.line_h;
    const px: f32 = @floatFromInt(r.x);
    const py: f32 = @floatFromInt(r.y);
    const bottom = py + @as(f32, @floatFromInt(r.h)) - line_h - 4;
    const w: f32 = @floatFromInt(r.w);
    var t_buf: [24]u8 = undefined;
    const right = format.fmt(&t_buf, "+{d:.1} ms", .{p.trigger.post_ms});
    _ = batch.label(px + w - batch.font.width(right) - 8, bottom, right, theme.text_dim);
    if (p.trigger.pre_ms > 0) {
        _ = batch.label(
            px + w * @as(f32, @floatCast(p.trigger.pre_ms / (p.trigger.pre_ms + p.trigger.post_ms))) + 4,
            bottom,
            "0",
            theme.text_dim,
        );
        var l_buf: [24]u8 = undefined;
        const left = format.fmt(&l_buf, "-{d:.1} ms", .{p.trigger.pre_ms});
        // Only where it fits between the row labels and the trigger line.
        if (px + 48 + batch.font.width(left) + 8 <
            px + w * @as(f32, @floatCast(p.trigger.pre_ms / (p.trigger.pre_ms + p.trigger.post_ms))))
            _ = batch.label(px + 48, bottom, left, theme.text_dim);
    }
}

/// Samples are being lost, or the recording has failed: a bar across the whole display
/// that stays until it is acknowledged. A warning (the disk falling behind) is amber and
/// goes when its cause does. Below the review badge when there is one.
fn alarmBar(o: *Output, status: Status, below_badge: bool, width: u32) void {
    const batch = o.batch;
    const line_h = o.line_h;
    const is_alarm = status.alarm_len > 0;
    const text = if (is_alarm) status.alarm() else status.warning();
    const bar_h = 2 * line_h + 14;
    const bar_y = if (below_badge) line_h + 18 else 0;
    batch.rect(0, bar_y, @floatFromInt(width), bar_h, if (is_alarm) theme.alarm_bar else theme.warning_bar);
    const tw = batch.font.width(text);
    _ = batch.text((@as(f32, @floatFromInt(width)) - tw) / 2, bar_y + 5, text, theme.bar_text);
    if (is_alarm) {
        const hint = "press Shift+a to acknowledge";
        _ = batch.text(
            (@as(f32, @floatFromInt(width)) - batch.font.width(hint)) / 2,
            bar_y + line_h + 7,
            hint,
            theme.alarm_hint_text,
        );
    }
}

/// In review, top centre. Unmistakable: this is not what the electrodes see now.
fn reviewBadge(o: *Output, v: ReviewView, width: u32, fs: f64) void {
    const batch = o.batch;
    const line_h = o.line_h;
    var buf: [120]u8 = undefined;
    var clock_buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buf,
        "REVIEW   {d:.1} s behind live   at {s}{s}   End = live",
        .{
            v.behind_s,
            control.fmtClock(&clock_buf, @as(f64, @floatFromInt(v.end)) / fs),
            if (v.ready) "" else "   (reading)",
        },
    ) catch "REVIEW";
    const tw = batch.font.width(text);
    const x = (@as(f32, @floatFromInt(width)) - tw) / 2;
    batch.rect(x - 10, 4, tw + 20, line_h + 10, theme.warning_bar);
    _ = batch.text(x, 9, text, theme.review_badge_text);
}

/// The note being typed, bottom left, with when it is stamped.
fn noteDraft(o: *Output, notes: *const notes_mod.Notes, height: u32, fs: f64) void {
    const batch = o.batch;
    const line_h = o.line_h;
    var buf: [notes_mod.max_text + 64]u8 = undefined;
    var clock_buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buf,
        "note at {s}:  {s}_",
        .{ control.fmtClock(&clock_buf, @as(f64, @floatFromInt(notes.draft.sample)) / fs), notes.draft.text() },
    ) catch "note";
    _ = batch.label(10, @as(f32, @floatFromInt(height)) - 2 * line_h - 14, text, theme.note_draft_text);
}

/// The latency, frame rate and display losses in the bottom right corner, and the
/// recording's clock beside them.
fn statusReadout(o: *Output, status: Status, width: u32, height: u32) void {
    const batch = o.batch;
    const line_h = o.line_h;
    var buf: [96]u8 = undefined;
    const text = if (status.lost > 0)
        format.fmt(&buf, "{d:.1} ms   {d} fps   display skipped {d} blocks", .{ status.latency_ms, status.fps, status.lost })
    else
        format.fmt(&buf, "{d:.1} ms   {d} fps", .{ status.latency_ms, status.fps });
    const w = batch.font.width(text);
    const x = @as(f32, @floatFromInt(width)) - w - 8;
    const y = @as(f32, @floatFromInt(height)) - line_h - 6;
    _ = batch.label(x, y, text, if (status.lost > 0) theme.text_warn else theme.text_dim);
    if (status.recording) {
        var clock_buf: [16]u8 = undefined;
        var rec_buf: [32]u8 = undefined;
        const rec_text = std.fmt.bufPrint(&rec_buf, "REC {s}", .{control.fmtClock(&clock_buf, status.rec_seconds)}) catch "REC";
        _ = batch.label(x - batch.font.width(rec_text) - 14, y, rec_text, theme.text_rec);
    }
}

/// A bar along the top of the panel that input goes to.
fn targetBar(o: *Output, r: panels_mod.Rect) void {
    o.fills[o.nf] = .{ .rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = 3 }, .colour = theme.target_bar };
    o.nf += 1;
}

/// The panels for this run: from the config, or one per headstage.
pub fn makeDisplay(args: Args, layout: *const oez.types.Layout) ?Display {
    var diag: panels_mod.Diagnostics = .{};
    var set = panels_mod.fromConfig(args.doc, layout, &diag) catch {
        log.err("config: {s}", .{diag.message()});
        return null;
    };
    const retired = "level_uv, level_auto and slope are no longer used (a slope trigger is at its channel's threshold)";
    if (diag.retired) log.info("config: {s}", .{retired});
    diag.retired = false;
    const applied = panels_mod.applyViews(&set, args.views_doc, &diag) catch blk: {
        log.warn("view file: {s}; the rest of it is ignored", .{diag.message()});
        break :blk 0;
    };
    if (diag.retired) log.info("view file: {s}", .{retired});
    if (applied > 0) log.info("view file: settings for {d} panels", .{applied});
    if (args.sweep) for (set.slice()) |*p| {
        p.mode = .sweep;
        p.clamp();
    };
    for (set.items[0..set.len], 0..) |*p, i| log.info(
        "panel {d} \"{s}\": {d} {t} channels from channel {d}, {d:.2} s, {d} {s}/row",
        .{ i + 1, p.name(), p.rows, p.kind, p.first_ch + 1, p.span_s, p.scale, p.unit() },
    );
    return .init(set);
}

/// Text for the display: the font from the config, its atlas on the GPU, and the batch that
/// each frame's quads go into. Without a usable font the display runs without text.
pub const Text = struct {
    font: font.Font = .{ .atlas = &.{}, .px = 0 },
    vertices: []font.Vertex = &.{},

    pub fn init(self: *Text, gpa: std.mem.Allocator, gpu: *Gpu, args: Args) void {
        var name_buf: [128]u8 = undefined;
        const family = std.fmt.bufPrintSentinel(&name_buf, "{s}", .{args.font}, 0) catch "sans-serif";
        const f = font.Font.init(gpa, family, args.font_px) catch |e| {
            log.warn("no font '{s}' ({t}): the display has no text", .{ args.font, e });
            return;
        };
        self.font = f;
        const vertices = gpa.alloc(font.Vertex, max_text_vertices) catch return;
        gpu.createText(f.atlas, font.atlas_size, max_text_vertices) catch |e| {
            log.warn("text setup failed ({t}): the display has no text", .{e});
            gpa.free(vertices);
            return;
        };
        self.vertices = vertices;
    }

    pub fn deinit(self: *Text, gpa: std.mem.Allocator) void {
        gpa.free(self.vertices);
        if (self.font.atlas.len > 0) self.font.deinit(gpa);
    }

    pub fn batch(self: *const Text) font.Batch {
        return .{ .font = &self.font, .vertices = self.vertices };
    }
};

// ---- What the display draws, frozen ----
//
// `frame` decides what the experimenter sees. This test runs it on a set of states (panels
// of every kind and mode, sweeps, tint pulses, notes, review, alarms, the status read-out),
// each put into the `Display` through its own functions (`feedBlock` for the triggers and
// pulses, `Notes.handle` for the notes), with the control window's hand-made font: every
// character is 8 pixels wide and drawn as a 1x1 quad whose atlas position names it. It
// writes everything `frame` returns, in order, as text: each trace draw with every field
// of its parameters, the rows' own scales it puts into the gain buffer, each fill, and the
// batch's rectangles and text runs. It is compared with `testdata/display_frame.txt`. Set
// OEZ_DISPLAY_FRAME_OUT to a path to write what this run produced there.

const testing = std.testing;

var frame_atlas: [1]u8 = .{0};

/// The hand-made font (as control.zig's test has it); a line height of 0 is a display
/// without a font.
fn frameFont(line_height: f32) font.Font {
    var f: font.Font = .{ .atlas = &frame_atlas, .px = 14, .ascent = 12, .line_height = line_height };
    for (&f.glyphs, 0..) |*g, k| g.* = .{ .x = @intCast(8 + k), .y = 8, .w = 1, .h = 1, .top = 12, .advance = 8 };
    return f;
}

/// The code point of glyph `k` of `frameFont` (as `font.Font.glyph` numbers them).
fn frameCodepoint(k: usize) u21 {
    const extra = [_]u21{ 0x03C3, 0x2013, 0x2192, 0x266A };
    return if (k < 224) @intCast(32 + k) else extra[k - 224];
}

const frame_fs = 30000.0;
/// Columns of the history (as `feed` lays it out, more than the stream's channels).
const frame_nch = 62;
/// The newest sample of every state: 100.4115 s, 12345 samples into a pass of 1 s.
const frame_newest: i64 = 3_012_345;

/// Two headstages (A: 32 channels, B: 16), 6 AUX and 8 ADC channels.
fn frameLayout() oez.types.Layout {
    var l: oez.types.Layout = .{ .sample_rate = frame_fs, .hw_clock_hz = 50e6, .num_electrodes = 48, .num_aux = 6, .num_adc = 8 };
    l.headstages[0] = .{ .slot = 0, .chip = "RHD2132", .num_channels = 32, .first_channel = 0, .has_bno = false };
    l.headstages[1] = .{ .slot = 2, .chip = "RHD2216", .num_channels = 16, .first_channel = 32, .has_bno = false };
    l.num_headstages = 2;
    return l;
}

fn framePanel(name: []const u8, kind: panels_mod.Kind, first_ch: u32, rows: u32, place: panels_mod.Place) Panel {
    var p: Panel = .{
        .place = place,
        .kind = kind,
        .first_ch = first_ch,
        .rows = rows,
        .span_s = 2,
        .scale = Panel.defaultScale(kind),
        .slot = 7 + first_ch,
    };
    @memcpy(p.name_buf[0..name.len], name);
    p.name_len = name.len;
    return p;
}

fn setText(buf: []u8, len: *usize, s: []const u8) void {
    @memcpy(buf[0..s.len], s);
    len.* = s.len;
}

/// Sample `n` of channel `ch`: hashed noise of ±128 LSB, with negative spikes on channel 4
/// and positive ones on channel 34.
fn frameSample(n: i64, ch: usize) i16 {
    var h: u64 = @as(u64, @bitCast(n)) *% 0x9E3779B97F4A7C15 ^ (@as(u64, ch) +% 1) *% 0xBF58476D1CE4E5B9;
    h ^= h >> 31;
    h *%= 0x94D049BB133111EB;
    h ^= h >> 29;
    var v: i32 = @as(i32, @intCast(h & 0xff)) - 128;
    if (ch == 4 and @mod(n, 2003) < 6) v -= 1500;
    if (ch == 34 and @mod(n, 1999) < 6) v += 1200;
    return @intCast(v);
}

/// TTL line 2: 20 ms high every 200 ms, the last rise 500 samples before the newest (still
/// high). Line 3: high from 2_990_000 to 3_004_000 (across the start of the sweep's pass),
/// 3_006_000 to 3_008_000, and from 3_011_000 on (across the cursor); earlier, a pulse the
/// cursor has gone over (2_975_000 to 2_978_000) and, for review, 0.1 s every second.
/// Line 6: 100 samples every 9000, the last fall 900 samples before the newest. Line 4:
/// never.
fn frameWord(n: i64) u16 {
    var w: u16 = 0;
    if (@mod(n - (frame_newest - 500), 6000) < 600) w |= 1 << 1;
    const tint = (n >= 2_990_000 and n < 3_004_000) or (n >= 3_006_000 and n < 3_008_000) or n >= 3_011_000 or
        (n >= 2_975_000 and n < 2_978_000) or (n < 2_970_000 and @mod(n, 30000) < 3000);
    if (tint) w |= 1 << 2;
    if (@mod(n - (frame_newest - 1000), 9000) < 100) w |= 1 << 5;
    return w;
}

/// One state: the display, and what `frame` is given besides it.
const FrameState = struct {
    display: Display = .init(.{}),
    notes: notes_mod.Notes = .{},
    status: Status = .{},
    review: ?ReviewView = null,
    width: u32 = 1000,
    height: u32 = 700,
    hist_cap: usize = 1 << 20,
    no_text: bool = false,

    fn panels(self: *FrameState, list: []const Panel) void {
        var set: panels_mod.Set = .{};
        for (list, 0..) |p, k| set.items[k] = p;
        set.len = list.len;
        setText(&set.ttl_name_buf[1], &set.ttl_name_len[1], "laser");
        setText(&set.ttl_name_buf[4], &set.ttl_name_len[4], "camera trigger");
        self.display = .init(set);
    }

    /// Feeds the `seconds` before the newest sample to the display, in blocks, as
    /// acquisition would: TTL words always, samples when a panel triggers on a slope.
    fn feed(self: *FrameState, seconds: f64, with_samples: bool) void {
        const block = 256;
        var samples: [block * frame_nch]i16 = undefined;
        var words: [block]u16 = undefined;
        var first: i64 = frame_newest - @as(i64, @intFromFloat(seconds * frame_fs));
        while (first <= frame_newest) : (first += block) {
            const n: usize = @intCast(@min(block, frame_newest - first + 1));
            for (0..n) |k| {
                const s = first + @as(i64, @intCast(k));
                words[k] = frameWord(s);
                if (with_samples) for (0..frame_nch) |ch| {
                    samples[k * frame_nch + ch] = frameSample(s, ch);
                };
            }
            self.display.feedBlock(first, samples[0..if (with_samples) n * frame_nch else 0], frame_nch, frame_fs, words[0..n]);
        }
    }

    /// What the tile window would report: every electrode of `frameLayout` at `uv`.
    fn reportAll(self: *FrameState, uv: f32) void {
        @memset(self.display.reported.uv[0..48], uv);
        self.display.reported.len = 48;
    }

    /// Opens a note at sample `at` and types `text` into it, as the keys would.
    fn typeNote(self: *FrameState, at: i64, text: []const u8) void {
        var in: Input = .{};
        in.keys[0] = .{ .char = '/' };
        in.num_keys = 1;
        setText(&in.text, &in.text_len, "/");
        self.notes.handle(&in, at, "");
        var rest = text;
        while (rest.len > 0) {
            const chunk = notes_mod.prefix(rest, in.text.len);
            in = .{};
            setText(&in.text, &in.text_len, chunk);
            self.notes.handle(&in, at, "");
            rest = rest[chunk.len..];
        }
    }

    /// A note saved at sample `at`.
    fn note(self: *FrameState, at: i64, text: []const u8) void {
        self.typeNote(at, text);
        var in: Input = .{};
        in.keys[0] = .{ .named = .enter };
        in.num_keys = 1;
        self.notes.handle(&in, at, "");
    }
};

const frame_states = [_][]const u8{
    "scrolling: filter, raw, hidden, row scale, reference; AUX, ADC, TTL lanes",
    "sweep: cursor, tint line high across it",
    "triggered on TTL: sweeps, the newest part-filled, pulse shading",
    "triggered on a slope: a fixed level, and one latched from following the noise",
    "notes: this pass, the previous pass, one being typed",
    "review from the file",
    "review from the file, still reading",
    "review frozen, without a file; warning bar",
    "alarm, not acknowledged",
    "alarm acknowledged",
    "warning",
    "heard rows, target bar, latency",
    "lost blocks, recording",
    "small window",
    "no font",
    "focus on a filtered row with a threshold: the line",
    "focus on a raw row, and on a 10 Hz high-pass: tags, no line",
    "focus, no threshold reported",
    "focus and listening on the same channel",
    "focus and listening on different channels",
    "the focused channel in two panels",
    "the focused row hidden",
    "focus in a triggered panel and a sweep panel",
    "focus: a threshold beyond the row's extent, clamped",
    "thinned labels: the focused row and the rows listened to are labelled all the same",
};

/// Puts state `k` of `frame_states` into `st`.
fn frameState(st: *FrameState, k: usize) void {
    st.* = .{};
    switch (k) {
        0 => scrollingState(st),
        1 => sweepState(st),
        2, 14 => ttlTriggeredState(st, k == 14),
        3 => slopeState(st),
        4 => notesState(st),
        5, 6, 7 => reviewState(st, k),
        8, 9, 10 => alarmState(st, k),
        11, 12 => heardState(st, k),
        13 => smallState(st),
        15, 17, 23 => focusLineState(st, k),
        16 => focusTagState(st),
        18, 19 => focusHeardState(st, k),
        20 => focusTwoPanelsState(st),
        21 => focusHiddenState(st),
        22 => focusModesState(st),
        24 => thinnedMarksState(st),
        else => unreachable,
    }
}

fn scrollingState(st: *FrameState) void {
    var a = framePanel("Port A", .electrode, 0, 32, .{ .x = 0, .y = 0, .w = 0.5, .h = 0.55 });
    a.filter.on = true;
    // Rows are labelled every second one here: these are among the labelled.
    a.per_row.raw.set(4, true);
    a.per_row.hidden.set(7, true);
    a.per_row.hidden.set(9, true);
    a.per_row.gain[6] = 2;
    a.per_row.gain[9] = 0.5;
    a.per_row.gain[10] = 0.5;
    a.setCar(true);
    a.reference.ref.set(2, false);
    a.reference.sub.set(0, false);
    var b = framePanel("Port B", .electrode, 32, 16, .{ .x = 0.5, .y = 0, .w = 0.5, .h = 0.55 });
    b.span_s = 0.5;
    b.setCar(true);
    var adc = framePanel("ADC", .adc, 54, 8, .{ .x = 0.3, .y = 0.55, .w = 0.7, .h = 0.2 });
    adc.scale = 2.5;
    var ttl = framePanel("TTL", .ttl, 0, 5, .{ .x = 0, .y = 0.75, .w = 1, .h = 0.25 });
    ttl.ttl_lines = .{ 1, 2, 3, 5, 8, 6, 7, 4 };
    st.panels(&.{ a, b, framePanel("AUX", .aux, 48, 6, .{ .x = 0, .y = 0.55, .w = 0.3, .h = 0.2 }), adc, ttl });
}

fn sweepState(st: *FrameState) void {
    var a = framePanel("Port A", .electrode, 0, 32, .{ .x = 0, .y = 0, .w = 1, .h = 0.6 });
    a.mode = .sweep;
    a.span_s = 1;
    a.tint_line = 3;
    a.filter.on = true;
    a.filter.low_hz = 10;
    a.filter.high_hz = 0;
    var adc = framePanel("ADC", .adc, 54, 8, .{ .x = 0, .y = 0.6, .w = 0.5, .h = 0.4 });
    adc.tint_line = 3;
    var ttl = framePanel("TTL", .ttl, 0, 8, .{ .x = 0.5, .y = 0.6, .w = 0.5, .h = 0.4 });
    ttl.mode = .sweep;
    ttl.span_s = 1;
    st.panels(&.{ a, adc, ttl });
    st.display.target = 1;
    st.feed(3, false);
}

fn ttlTriggeredState(st: *FrameState, no_text: bool) void {
    var a = framePanel("Port A", .electrode, 0, 32, .{ .x = 0, .y = 0, .w = 0.6, .h = 0.7 });
    a.mode = .triggered;
    a.trigger.overlay = 12;
    a.filter.on = true;
    var adc = framePanel("ADC", .adc, 54, 8, .{ .x = 0.6, .y = 0, .w = 0.4, .h = 0.7 });
    adc.mode = .triggered;
    adc.trigger.line = 6;
    adc.trigger.pre_ms = 2;
    adc.trigger.post_ms = 8;
    var ttl = framePanel("TTL", .ttl, 0, 3, .{ .x = 0, .y = 0.7, .w = 1, .h = 0.3 });
    ttl.mode = .triggered;
    ttl.trigger.line = 4;
    st.panels(&.{ a, adc, ttl });
    // The oldest sweeps are no longer in a history this short.
    st.hist_cap = 1 << 16;
    st.no_text = no_text;
    st.feed(8, false);
}

fn slopeState(st: *FrameState) void {
    var a = framePanel("Port A", .electrode, 0, 32, .{ .x = 0, .y = 0, .w = 0.5, .h = 1 });
    a.mode = .triggered;
    a.setTrigSource(.channel);
    a.trigger.row = 4;
    a.trigger.holdoff_ms = 2;
    a.per_row.hidden.set(1, true);
    a.per_row.gain[4] = 1.5;
    a.filter.on = true;
    var b = framePanel("Port B", .electrode, 32, 16, .{ .x = 0.5, .y = 0, .w = 0.5, .h = 1 });
    b.mode = .triggered;
    b.setTrigSource(.channel);
    b.trigger.row = 2;
    b.trigger.overlay = 5;
    st.panels(&.{ a, b });
    // Port A's trigger channel (4) fixed; Port B's (34) follows the noise, without a tile
    // window to report it: the trigger latches it after its first second of signal.
    st.display.thresholds.set(4, -62);
    st.feed(3, true);
}

fn notesState(st: *FrameState) void {
    var a = framePanel("Port A", .electrode, 0, 32, .{ .x = 0, .y = 0, .w = 1, .h = 0.5 });
    a.mode = .sweep;
    a.span_s = 1;
    const b = framePanel("Port B", .electrode, 32, 16, .{ .x = 0, .y = 0.5, .w = 1, .h = 0.5 });
    st.panels(&.{ a, b });
    st.note(2_940_000, "older than the window");
    st.note(2_975_000, "where the cursor has been");
    st.note(2_990_000, "previous pass");
    // Cut at 40 bytes, in the middle of the "µ".
    st.note(3_005_000, "this pass: cell 3 at 2100 um, depth 2.1µm, more");
    st.note(3_012_300, "at the right edge");
    st.note(3_012_400, "after the newest sample");
    st.typeNote(3_012_000, "spike at 2 µm");
}

/// `k`: 5 from the file, 6 from the file and still reading, 7 frozen (without a file).
fn reviewState(st: *FrameState, k: usize) void {
    var a = framePanel("Port A", .electrode, 0, 32, .{ .x = 0, .y = 0, .w = 0.5, .h = 0.6 });
    a.tint_line = 3;
    a.span_s = 5;
    var b = framePanel("Port B", .electrode, 32, 16, .{ .x = 0.5, .y = 0, .w = 0.5, .h = 0.6 });
    b.mode = .sweep;
    b.span_s = 1;
    var c = framePanel("Port A", .electrode, 0, 32, .{ .x = 0, .y = 0.6, .w = 0.7, .h = 0.4 });
    c.mode = .triggered;
    const ttl = framePanel("TTL", .ttl, 0, 8, .{ .x = 0.7, .y = 0.6, .w = 0.3, .h = 0.4 });
    st.panels(&.{ a, b, c, ttl });
    st.feed(20, false);
    const end = frame_newest - 375_000;
    st.note(end - 10_000, "in the review stretch");
    st.note(frame_newest - 1000, "after it");
    st.review = .{ .end = end, .from_file = k != 7, .ready = k != 6, .behind_s = 12.5 };
    if (k == 7) setText(&st.status.warning_buf, &st.status.warning_len, "the disk is falling behind");
}

/// `k`: 8 an alarm (and a warning), 9 the alarm acknowledged, 10 a warning.
fn alarmState(st: *FrameState, k: usize) void {
    st.panels(&.{
        framePanel("Port A", .electrode, 0, 32, .{ .x = 0, .y = 0, .w = 0.5, .h = 1 }),
        framePanel("Port B", .electrode, 32, 16, .{ .x = 0.5, .y = 0, .w = 0.5, .h = 1 }),
    });
    st.status = .{ .valid = true, .latency_ms = 4.25, .fps = 144 };
    if (k != 9) setText(&st.status.warning_buf, &st.status.warning_len, "the disk is falling behind");
    if (k == 8) setText(&st.status.alarm_buf, &st.status.alarm_len, "SAMPLES LOST: 3 blocks");
    // Acknowledged: the alarms (session.zig) take the alarm out of the status.
    st.display.acknowledged = k == 9;
}

/// `k`: 11 rows listened to, 12 not listening, display losses and recording.
fn heardState(st: *FrameState, k: usize) void {
    var aux = framePanel("AUX", .aux, 48, 6, .{ .x = 0.5, .y = 0.5, .w = 0.5, .h = 0.5 });
    aux.mode = .sweep;
    st.panels(&.{
        framePanel("Port A", .electrode, 0, 32, .{ .x = 0, .y = 0, .w = 0.5, .h = 1 }),
        // Across both headstages.
        framePanel("A and B", .electrode, 28, 8, .{ .x = 0.5, .y = 0, .w = 0.5, .h = 0.5 }),
        aux,
    });
    st.display.audio.enabled = k == 11;
    st.display.audio.channels[0] = 5;
    st.display.audio.channels[1] = 30;
    st.display.audio.channels[2] = 33;
    st.display.audio.num_channels = 3;
    st.display.target = 1;
    st.status = .{ .valid = true, .latency_ms = 4.25, .fps = 144 };
    if (k == 12) {
        st.status.lost = 7;
        st.status.recording = true;
        st.status.rec_seconds = 3725.5;
    }
}

fn smallState(st: *FrameState) void {
    var a = framePanel("Port A", .electrode, 0, 32, .{ .x = 0, .y = 0, .w = 0.5, .h = 1 });
    a.mode = .triggered;
    st.panels(&.{
        a,
        framePanel("Port B", .electrode, 32, 16, .{ .x = 0.5, .y = 0, .w = 0.5, .h = 0.5 }),
        framePanel("ADC", .adc, 54, 8, .{ .x = 0.5, .y = 0.5, .w = 0.5, .h = 0.5 }),
    });
    st.width = 320;
    st.height = 180;
    st.status = .{ .valid = true, .latency_ms = 12.5, .fps = 60, .recording = true, .rec_seconds = 61 };
    st.feed(2, false);
}

/// 32 rows in 300 px: every second row is labelled. Row 6 (label "7", a regular label) is
/// left alone; channel 9 (label "10", not a regular one) is in focus; channels 20 and 21
/// (labels "21" and "22") are listened to. The regular labels next to a marked row give way.
fn thinnedMarksState(st: *FrameState) void {
    st.panels(&.{framePanel("Port A", .electrode, 0, 32, .{ .x = 0, .y = 0, .w = 1, .h = 1 })});
    st.width = 600;
    st.height = 300;
    st.display.setFocus(9);
    st.display.audio.enabled = true;
    st.display.audio.channels[0] = 20;
    st.display.audio.channels[1] = 21;
    st.display.audio.num_channels = 2;
    st.feed(2, false);
}

/// Port A over the whole display (1000 x 700), filtered 300-6000 Hz. (The states below
/// put channel 5 in focus after `panels`, which starts the display afresh.)
fn focusPanel() Panel {
    var a = framePanel("Port A", .electrode, 0, 32, .{ .x = 0, .y = 0, .w = 1, .h = 1 });
    a.filter.on = true;
    return a;
}

/// `k`: 15 the line, 17 no threshold reported, 23 a threshold beyond the row's extent.
fn focusLineState(st: *FrameState, k: usize) void {
    var a = focusPanel();
    if (k == 23) {
        // 50 µV/row, -120 µV: 2.4 rows below the centre, clamped to 1.5. Rows of
        // R = 700 / 32 = 21.875 px; row 5's centre at 5.5 R = 120.3125; the line at
        // 120.3125 + 1.5 R = 153.125, the pixel row 153.
        a.scale = 50;
    } else {
        // Row 2 hidden: 31 rows of R = 700 / 31 = 22.5806 px, row 5 the 5th drawn (k = 4),
        // its centre at 4.5 R = 101.6129. Its own scale 2 x 400 = 800 µV/row; -50 µV is
        // 50 / 800 = 0.0625 rows below: 101.6129 + 0.0625 R = 103.0242, the pixel row 103.
        a.per_row.hidden.set(2, true);
        a.per_row.gain[5] = 2;
    }
    st.panels(&.{a});
    st.display.focus = 5;
    switch (k) {
        15 => st.reportAll(-50),
        23 => st.reportAll(-120),
        else => {},
    }
}

fn focusTagState(st: *FrameState) void {
    var a = focusPanel();
    a.place.w = 0.5;
    a.per_row.raw.set(5, true);
    var hp = framePanel("Port A > 10 Hz", .electrode, 0, 32, .{ .x = 0.5, .y = 0, .w = 0.5, .h = 1 });
    hp.filter.on = true;
    hp.filter.low_hz = 10;
    hp.filter.high_hz = 0;
    st.panels(&.{ a, hp });
    st.display.focus = 5;
    st.reportAll(-50);
}

/// `k`: 18 listening to the focused channel, 19 to two others.
fn focusHeardState(st: *FrameState, k: usize) void {
    st.panels(&.{focusPanel()});
    st.display.focus = 5;
    st.reportAll(-50);
    st.display.audio.enabled = true;
    if (k == 18) {
        st.display.audio.channels[0] = 5;
        st.display.audio.num_channels = 1;
    } else {
        st.display.audio.channels[0] = 3;
        st.display.audio.channels[1] = 9;
        st.display.audio.num_channels = 2;
    }
}

fn focusTwoPanelsState(st: *FrameState) void {
    var a = framePanel("Port A", .electrode, 0, 32, .{ .x = 0, .y = 0, .w = 1, .h = 0.5 });
    a.filter.on = true;
    var ab = framePanel("A and B", .electrode, 28, 8, .{ .x = 0, .y = 0.5, .w = 1, .h = 0.5 });
    ab.filter.on = true;
    ab.per_row.gain[2] = 0.5;
    st.panels(&.{ a, ab });
    // Channel 30. In Port A: row 30 of 32, R = 350 / 32 = 10.9375, centre 30.5 R =
    // 333.59375, -80 µV at 400 µV/row 0.2 R below: 335.78125, the pixel row 335. In "A and
    // B": row 2 of 8, R = 43.75, centre 350 + 2.5 R = 459.375, at 200 µV/row 0.4 R below:
    // 476.875, the pixel row 476.
    st.display.focus = 30;
    st.reportAll(-80);
}

fn focusHiddenState(st: *FrameState) void {
    var a = focusPanel();
    a.per_row.hidden.set(5, true);
    st.panels(&.{a});
    st.display.focus = 5;
    st.reportAll(-50);
}

fn focusModesState(st: *FrameState) void {
    var trig = focusPanel();
    trig.place.w = 0.5;
    trig.mode = .triggered;
    var sweep = focusPanel();
    sweep.place.x = 0.5;
    sweep.place.w = 0.5;
    sweep.mode = .sweep;
    sweep.span_s = 1;
    st.panels(&.{ trig, sweep });
    st.display.focus = 5;
    // Both: row 5 of 32, R = 21.875, centre 120.3125, -50 µV at 400 µV/row 0.125 R below:
    // 123.0469, the pixel row 123.
    st.reportAll(-50);
    st.feed(8, false);
}

/// Writes the batch's quads as rectangles and runs of text (glyphs on one row, of one
/// colour, 8 pixels apart). Returns how many of each; with `w` null, only counts.
fn writeQuads(w: ?*std.Io.Writer, verts: []const font.Vertex) !struct { rects: usize, runs: usize } {
    const quads = verts.len / 6;
    var rects: usize = 0;
    var runs: usize = 0;
    var q: usize = 0;
    while (q < quads) {
        const v = verts[q * 6 ..][0..6];
        const x = v[0].pos[0];
        const y = v[0].pos[1];
        const col = v[0].colour;
        if (v[0].uv[0] * font.atlas_size < 8) {
            if (w) |out| try out.print("rect {d} {d} {d} {d} {any}\n", .{ x, y, v[2].pos[0] - x, v[2].pos[1] - y, col });
            rects += 1;
            q += 1;
            continue;
        }
        runs += 1;
        if (w) |out| try out.print("text {d} {d} {any} \"", .{ x, y, col });
        var next_x = x;
        while (q < quads) : (q += 1) {
            const g = verts[q * 6 ..][0..6];
            const gu = g[0].uv[0] * font.atlas_size;
            if (gu < 8 or g[0].pos[0] != next_x or g[0].pos[1] != y or !std.mem.eql(u8, &g[0].colour, &col)) break;
            var utf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(frameCodepoint(@intFromFloat(gu - 8)), &utf) catch unreachable;
            if (w) |out| try out.writeAll(utf[0..n]);
            next_x += 8;
        }
        if (w) |out| try out.writeAll("\"\n");
    }
    return .{ .rects = rects, .runs = runs };
}

/// Runs `frame` on `st` and writes what it returned.
fn writeFrame(w: *std.Io.Writer, name: []const u8, st: *const FrameState, gains: []f32, vertices: []font.Vertex) !void {
    const layout = frameLayout();
    const face = frameFont(if (st.no_text) 0 else 16);
    var batch: font.Batch = .{ .font = &face, .vertices = vertices };
    var draws: [max_draws]gpu_mod.PanelDraw = undefined;
    var fills: [max_fills]gpu_mod.Fill = undefined;
    @memset(gains, 1);
    const surface: Surface = .{ .width = st.width, .height = st.height, .nch = frame_nch, .hist_cap = st.hist_cap, .row_gains = gains };
    const fr = st.display.frame(surface, &layout, frame_newest, st.review, st.status, &st.notes, &batch, &draws, &fills);
    // A full batch drops quads silently: the comparison would then miss them.
    try testing.expect(batch.len + 6 <= vertices.len);
    const counts = try writeQuads(null, fr.text);
    try w.print(
        "== {s}: {d} draws, {d} fills, {d} text runs, {d} rects\n",
        .{ name, fr.draws.len, fr.fills.len, counts.runs, counts.rects },
    );
    for (fr.draws) |d| {
        try w.print("draw {d} {d} {d} {d} review={}", .{ d.rect.x, d.rect.y, d.rect.w, d.rect.h, d.review });
        inline for (@typeInfo(gpu_mod.TraceParams).@"struct".field_names) |f| try w.print(" {s}={d}", .{ f, @field(d.params, f) });
        try w.writeByte('\n');
    }
    // The rows' own scales, where they are not 1.
    for (gains, 0..) |g, k| {
        if (g != 1) try w.print("gain {d} row {d}: {d}\n", .{ k / gpu_mod.max_rows, k % gpu_mod.max_rows, g });
    }
    for (fr.fills) |f| try w.print(
        "fill {d} {d} {d} {d} {d} {d} {d} {d}\n",
        .{ f.rect.x, f.rect.y, f.rect.w, f.rect.h, f.colour[0], f.colour[1], f.colour[2], f.colour[3] },
    );
    _ = try writeQuads(w, fr.text);
}

test "what the display draws is unchanged" {
    const gpa = testing.allocator;
    const vertices = try gpa.alloc(font.Vertex, max_text_vertices);
    defer gpa.free(vertices);
    const gains = try gpa.alloc(f32, gpu_mod.max_rows * gpu_mod.max_gain_panels);
    defer gpa.free(gains);
    const st = try gpa.create(FrameState);
    defer gpa.destroy(st);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (frame_states, 0..) |name, k| {
        frameState(st, k);
        try writeFrame(&out.writer, name, st, gains, vertices);
    }
    const got = out.written();
    if (std.c.getenv("OEZ_DISPLAY_FRAME_OUT")) |path| {
        const file = try std.Io.Dir.cwd().createFile(testing.io, std.mem.span(path), .{});
        defer file.close(testing.io);
        try file.writeStreamingAll(testing.io, got);
    }
    try testing.expectEqualStrings(@embedFile("testdata/display_frame.txt"), got);
}

/// Where the shader puts a sample of `value` (in the panel's unit) on panel row `row`, in
/// pixels: `traces.vert`'s arithmetic, in f32, from the parameters `traceParams` gives it
/// and the gain `setRowGains` writes, through the viewport (the panel's rectangle).
fn shaderPixelY(p: *const Panel, r: panels_mod.Rect, row: usize, value: f64) f32 {
    var gains: [gpu_mod.max_rows]f32 = @splat(1);
    setRowGains(&gains, p, 0);
    const surface: Surface = .{ .width = 1000, .height = 700, .nch = frame_nch, .hist_cap = 1 << 20, .row_gains = &gains };
    const params = traceParams(p, 0, r, panelTime(p, frame_newest, null, frame_fs), surface);
    const k: f32 = @floatFromInt(p.shownIndex(row).?);
    const lsb: f32 = @floatCast(value / p.unitsPerLsb());
    const row_h = 2.0 / @as(f32, @floatFromInt(params.rows));
    const centre = -1.0 + (k + 0.5) * row_h;
    const per_row = params.lsb_per_row * gains[@intFromFloat(k)];
    const y = centre - std.math.clamp(lsb / per_row, -1.5, 1.5) * row_h;
    return @as(f32, @floatFromInt(r.y)) + (y + 1) / 2 * @as(f32, @floatFromInt(r.h));
}

test "the threshold line is on the pixel row where the shader draws a sample of its value" {
    // The states of the stored test that draw a line: panel, row, value, the pixel row
    // computed by hand there.
    const Case = struct { state: usize, panel: usize, row: usize, uv: f64, want: f32 };
    const cases = [_]Case{
        .{ .state = 15, .panel = 0, .row = 5, .uv = -50, .want = 103 },
        .{ .state = 20, .panel = 0, .row = 30, .uv = -80, .want = 335 },
        .{ .state = 20, .panel = 1, .row = 2, .uv = -80, .want = 476 },
        .{ .state = 22, .panel = 0, .row = 5, .uv = -50, .want = 123 },
        .{ .state = 22, .panel = 1, .row = 5, .uv = -50, .want = 123 },
        .{ .state = 23, .panel = 0, .row = 5, .uv = -120, .want = 153 },
    };
    const st = try testing.allocator.create(FrameState);
    defer testing.allocator.destroy(st);
    const vertices = try testing.allocator.alloc(font.Vertex, max_text_vertices);
    defer testing.allocator.free(vertices);
    for (cases) |c| {
        frameState(st, c.state);
        const p = &st.display.set.items[c.panel];
        const r = p.pixelRect(st.width, st.height);
        const line = levelPixelY(p, r, c.row, c.uv).?;
        try testing.expectEqual(c.want, line);
        // And `frame` draws it there, across the panel.
        const quads = try thresholdRects(st, vertices);
        var found = false;
        for (quads.slice()) |q| found = found or std.meta.eql(q, .{ @floatFromInt(r.x), c.want, @floatFromInt(r.w), 1 });
        try testing.expect(found);
        // A flat trace at that value covers ±0.75 px about the shader's y (`half_px`): the
        // line's pixel centre is among those it lights.
        const y = shaderPixelY(p, r, c.row, c.uv);
        try testing.expect(@abs(line + 0.5 - y) <= 0.5 + 1e-3);
    }
}

const ThresholdRects = struct {
    items: [8][4]f32 = undefined,
    len: usize = 0,
    fn slice(self: *const ThresholdRects) []const [4]f32 {
        return self.items[0..self.len];
    }
};

/// The rectangles in the colour of the threshold line that `frame` draws for `st`, as
/// x, y, w, h.
fn thresholdRects(st: *const FrameState, vertices: []font.Vertex) !ThresholdRects {
    const layout = frameLayout();
    const face = frameFont(16);
    var batch: font.Batch = .{ .font = &face, .vertices = vertices };
    var draws: [max_draws]gpu_mod.PanelDraw = undefined;
    var fills: [max_fills]gpu_mod.Fill = undefined;
    var gains: [gpu_mod.max_rows * gpu_mod.max_gain_panels]f32 = undefined;
    const surface: Surface = .{ .width = st.width, .height = st.height, .nch = frame_nch, .hist_cap = st.hist_cap, .row_gains = &gains };
    const fr = st.display.frame(surface, &layout, frame_newest, st.review, st.status, &st.notes, &batch, &draws, &fills);
    var out: ThresholdRects = .{};
    for (0..fr.text.len / 6) |q| {
        const v = fr.text[q * 6 ..][0..6];
        if (!std.mem.eql(u8, &v[0].colour, &theme.tile_threshold)) continue;
        if (out.len == out.items.len) return error.TooManyLines;
        out.items[out.len] = .{ v[0].pos[0], v[0].pos[1], v[2].pos[0] - v[0].pos[0], v[2].pos[1] - v[0].pos[1] };
        out.len += 1;
    }
    return out;
}

test "no threshold line where the plan says there is none" {
    const st = try testing.allocator.create(FrameState);
    defer testing.allocator.destroy(st);
    const vertices = try testing.allocator.alloc(font.Vertex, max_text_vertices);
    defer testing.allocator.free(vertices);
    // A raw row and a 10 Hz high-pass; no threshold reported; the row hidden.
    for ([_]usize{ 16, 17, 21 }) |k| {
        frameState(st, k);
        try testing.expectEqual(0, (try thresholdRects(st, vertices)).len);
    }
    // One per panel that shows the focused row.
    for ([_][2]usize{ .{ 15, 1 }, .{ 20, 2 }, .{ 22, 2 }, .{ 23, 1 } }) |c| {
        frameState(st, c[0]);
        try testing.expectEqual(c[1], (try thresholdRects(st, vertices)).len);
    }
}

/// A display with Port A (32 rows, the whole height) and AUX, the pointer on row `row`.
fn clickDisplay(row: usize) Display {
    var set: panels_mod.Set = .{};
    set.items[0] = framePanel("Port A", .electrode, 0, 32, .{ .x = 0, .y = 0, .w = 0.5, .h = 1 });
    set.items[1] = framePanel("AUX", .aux, 48, 6, .{ .x = 0.5, .y = 0, .w = 0.5, .h = 1 });
    set.len = 2;
    var d: Display = .init(set);
    d.pointer_fy = (@as(f64, @floatFromInt(row)) + 0.5) / 32;
    return d;
}

test "clicks on a row: left focuses, right listens, Ctrl+right adds or removes, middle clears the focus" {
    var d = clickDisplay(5);
    // Left: focus, and what is listened to is left alone.
    _ = d.applyInput(.{ .clicks = 1 });
    try testing.expectEqual(5, d.focus.?);
    try testing.expectEqual(0, d.audio.num_channels);
    d.pointer_fy = 9.5 / 32.0;
    _ = d.applyInput(.{ .clicks = 1 });
    try testing.expectEqual(9, d.focus.?);
    // Right: listen to that channel alone; the focus stays.
    d.pointer_fy = 3.5 / 32.0;
    _ = d.applyInput(.{ .right_clicks = 1 });
    try testing.expectEqualSlices(u32, &.{3}, d.audio.channelSlice());
    try testing.expectEqual(9, d.focus.?);
    // Ctrl+right: added, then taken out again.
    d.pointer_fy = 7.5 / 32.0;
    _ = d.applyInput(.{ .right_clicks = 1, .ctrl = true });
    try testing.expectEqualSlices(u32, &.{ 3, 7 }, d.audio.channelSlice());
    _ = d.applyInput(.{ .right_clicks = 1, .ctrl = true });
    try testing.expectEqualSlices(u32, &.{3}, d.audio.channelSlice());
    // Right alone again: that one only.
    _ = d.applyInput(.{ .right_clicks = 1 });
    try testing.expectEqualSlices(u32, &.{7}, d.audio.channelSlice());
    // Middle, over the AUX panel: the focus is cleared; listening is not changed.
    d.target = 1;
    _ = d.applyInput(.{ .middle_clicks = 1 });
    try testing.expectEqual(null, d.focus);
    try testing.expectEqualSlices(u32, &.{7}, d.audio.channelSlice());
    // A left click on AUX focuses nothing.
    _ = d.applyInput(.{ .clicks = 1 });
    try testing.expectEqual(null, d.focus);
}

test "a channel's threshold: fixed, else as reported; the tile window's request sets it" {
    var d = clickDisplay(0);
    try testing.expectEqual(null, d.thresholdUv(5));
    // What the tile window reports for every electrode: in use, following the noise.
    for (0..32) |ch| d.reported.uv[ch] = -40 - @as(f32, @floatFromInt(ch));
    d.reported.len = 32;
    try testing.expectEqual(-45, d.thresholdUv(5).?);
    try testing.expectEqual(null, d.thresholdUv(40));
    // Asked for in the tile window: fixed, rising; the display's value wins over the report.
    d.tileRequest(.{ .threshold = .{ .channel = 5, .uv = 70 } });
    try testing.expect(d.thresholds_changed);
    try testing.expectEqual(70, d.thresholdUv(5).?);
    try testing.expectEqual(70, d.tileConfig().thresholds.fixed_uv[5]);
    // 0: back to the noise, and the reported value again.
    d.thresholds_changed = false;
    d.tileRequest(.{ .threshold = .{ .channel = 5, .uv = 0 } });
    try testing.expect(d.thresholds_changed);
    try testing.expect(!d.thresholds.isFixed(5));
    try testing.expectEqual(-45, d.thresholdUv(5).?);
    // The same again changes nothing.
    d.thresholds_changed = false;
    d.tileRequest(.{ .threshold = .{ .channel = 5, .uv = 0 } });
    try testing.expect(!d.thresholds_changed);
}

/// Feeds `d` `seconds` of `frameSample` from sample `from` (in blocks of 256, no TTL),
/// as acquisition would. Returns the sample after the last.
fn feedNoise(d: *Display, from: i64, seconds: f64) i64 {
    var samples: [256 * frame_nch]i16 = undefined;
    const words: [256]u16 = @splat(0);
    var first = from;
    const end = from + @as(i64, @intFromFloat(seconds * frame_fs));
    while (first < end) : (first += 256) {
        for (0..256) |k| for (0..frame_nch) |ch| {
            samples[k * frame_nch + ch] = frameSample(first + @as(i64, @intCast(k)), ch);
        };
        d.feedBlock(first, &samples, frame_nch, frame_fs, &words);
    }
    return first;
}

/// `clickDisplay` with Port A in triggered mode (on TTL to begin with).
fn triggeredDisplay(row: usize) Display {
    var d = clickDisplay(row);
    d.set.items[0].mode = .triggered;
    return d;
}

test "latching: a channel a panel starts triggering on is fixed at its reported threshold" {
    var d = triggeredDisplay(7);
    for (0..32) |ch| d.reported.uv[ch] = -40 - @as(f32, @floatFromInt(ch));
    d.reported.len = 32;
    // s over row 7: spikes on row 7; channel 7 is fixed where it was reported.
    var in: Input = .{ .num_keys = 1 };
    in.keys[0] = .{ .char = 's' };
    _ = d.applyInput(in);
    try testing.expectEqual(7, d.set.items[0].triggerChannel().?);
    try testing.expect(d.thresholds.isFixed(7) and d.thresholds_changed);
    try testing.expectEqual(-47, d.thresholds.fixed_uv[7]);
    try testing.expect(!d.thresholds.isFixed(6) and !d.thresholds.isFixed(9));
    // The report moving on does not move it.
    d.reported.uv[7] = -60;
    _ = feedNoise(&d, 0, 0.05);
    try testing.expectEqual(-47, d.thresholds.fixed_uv[7]);
    var buf: [48]u8 = undefined;
    try testing.expectEqualStrings("row 8 falling -47 µV", trigText(&buf, &d.set.items[0], d.thresholdUv(7), 4.5));
    // A fixed one is left alone: a click on row 9 moves the trigger there, and channel 9
    // keeps its rising 80 µV. Channel 7 stays as it was latched.
    d.thresholds.set(9, 80);
    d.pointer_fy = 9.5 / 32.0;
    _ = d.applyInput(.{ .clicks = 1 });
    try testing.expectEqual(9, d.set.items[0].triggerChannel().?);
    try testing.expectEqual(80, d.thresholds.fixed_uv[9]);
    try testing.expectEqual(-47, d.thresholds.fixed_uv[7]);
    try testing.expectEqualStrings("row 10 rising 80 µV", trigText(&buf, &d.set.items[0], d.thresholdUv(9), 4.5));
    // The row stepper in the control window: row 10 to 11, latched at -50.
    d.applyPanelEdit(0, .{ .trig_row = 1 });
    try testing.expectEqual(-50, d.thresholds.fixed_uv[10]);
}

test "latching: without a report, after the trigger's first second of signal" {
    var d = triggeredDisplay(0);
    d.applyPanelEdit(0, .{ .trig_source = .channel });
    d.applyPanelEdit(0, .{ .trig_row = 4 });
    // No tile window has reported: the trigger follows the noise, at 4.5 sigma of its own.
    var next = feedNoise(&d, 0, 0.9);
    try testing.expect(!d.thresholds.isFixed(4));
    try testing.expectEqual(null, d.thresholdUv(4));
    var buf: [48]u8 = undefined;
    try testing.expectEqualStrings("row 5 falling 4.5 σ", trigText(&buf, &d.set.items[0], d.thresholdUv(4), d.thresholds.sigmas));
    const sl = &d.slopes[0].?;
    try testing.expect(sl.settings.auto and sl.settings.auto_sigmas == 4.5 and !sl.settings.rising);
    // Past one second: fixed, at the trigger's level then, below zero.
    next = feedNoise(&d, next, 0.2);
    try testing.expect(d.thresholds.isFixed(4));
    const latched = d.thresholds.fixed_uv[4];
    try testing.expect(latched < -5);
    try testing.expectApproxEqRel(@as(f32, @floatCast(4.5 * sl.sigma() * 0.195)), -latched, 0.05);
    // From then on the trigger is at that fixed level, and so is the tile detector.
    _ = feedNoise(&d, next, 0.1);
    try testing.expect(!d.slopes[0].?.settings.auto);
    try testing.expectApproxEqRel(@as(f64, latched) / 0.195, d.slopes[0].?.settings.level, 1e-6);
    try testing.expectEqual(latched, d.tileConfig().thresholds.fixed_uv[4]);
    // A report arriving before the second is up wins: the same again on row 9 with one.
    var e = triggeredDisplay(0);
    e.applyPanelEdit(0, .{ .trig_source = .channel });
    e.applyPanelEdit(0, .{ .trig_row = 9 });
    _ = feedNoise(&e, 0, 0.3);
    try testing.expect(!e.thresholds.isFixed(9));
    e.reported.uv[9] = -33;
    e.reported.len = 32;
    _ = feedNoise(&e, 9000, 0.01);
    try testing.expectEqual(-33, e.thresholds.fixed_uv[9]);
}

test "latching: only a panel in triggered mode latches; a triggered channel is not returned to the noise" {
    var d = clickDisplay(0);
    d.reported.uv[3] = -42;
    d.reported.len = 32;
    // Spikes on row 4, but the panel scrolls: nothing latched, even after seconds.
    d.applyPanelEdit(0, .{ .trig_source = .channel });
    d.applyPanelEdit(0, .{ .trig_row = 3 });
    _ = feedNoise(&d, 0, 1.5);
    try testing.expect(!d.thresholds.isFixed(3));
    // Into triggered mode (the t key): latched.
    var in: Input = .{ .num_keys = 1 };
    in.keys[0] = .{ .char = 't' };
    _ = d.applyInput(in);
    try testing.expectEqual(-42, d.thresholds.fixed_uv[3]);
    // Back to the noise: refused while triggered on; another channel goes.
    d.applyThreshold(.{ .follow = 3 });
    d.applyThreshold(.{ .set = .{ .channel = 3, .uv = 0 } });
    try testing.expectEqual(-42, d.thresholds.fixed_uv[3]);
    d.thresholds.set(12, -70);
    d.applyThreshold(.{ .follow = 12 });
    try testing.expect(!d.thresholds.isFixed(12));
    // Scaling and flipping: of the fixed value; a channel following the noise is latched
    // first (with a report), and without one nothing happens.
    d.applyThreshold(.{ .scale = .{ .channel = 3, .factor = 2 } });
    try testing.expectEqual(-84, d.thresholds.fixed_uv[3]);
    d.reported.uv[20] = -30;
    d.applyThreshold(.{ .flip = 20 });
    try testing.expectEqual(30, d.thresholds.fixed_uv[20]);
    d.applyThreshold(.{ .scale = .{ .channel = 40, .factor = 2 } });
    try testing.expect(!d.thresholds.isFixed(40));
    // The global sigmas: one step.
    d.applyThreshold(.{ .sigmas = true });
    try testing.expectEqual(5, d.thresholds.sigmas);
}

test "a trigger channel's threshold that changes sides starts the slope trigger afresh" {
    var d = triggeredDisplay(0);
    d.applyPanelEdit(0, .{ .trig_source = .channel });
    d.applyPanelEdit(0, .{ .trig_row = 4 });
    d.thresholds.set(4, -100);
    var next = feedNoise(&d, 0, 0.5);
    const seen = d.slopes[0].?.seen;
    try testing.expect(seen > 10000 and !d.slopes[0].?.settings.rising);
    // Larger, the same side: the same trigger, at the new level.
    d.applyThreshold(.{ .scale = .{ .channel = 4, .factor = 1.5 } });
    next = feedNoise(&d, next, 0.01);
    try testing.expect(d.slopes[0].?.seen > seen);
    try testing.expectApproxEqRel(@as(f64, -150) / 0.195, d.slopes[0].?.settings.level, 1e-6);
    // The other side: a new trigger, rising.
    d.applyThreshold(.{ .flip = 4 });
    _ = feedNoise(&d, next, 0.01);
    try testing.expect(d.slopes[0].?.settings.rising);
    try testing.expect(d.slopes[0].?.seen < 1000);
}

test "Shift+a acknowledges an alarm, a alone does not" {
    var d = clickDisplay(0);
    var in: Input = .{};
    in.keys[0] = .{ .char = 'a' };
    in.num_keys = 1;
    _ = d.applyInput(in);
    try testing.expect(!d.acknowledged);
    in.shift = true;
    _ = d.applyInput(in);
    try testing.expect(d.acknowledged);
}
