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
const Status = control.Status;
const notes_mod = @import("notes.zig");
const tiles_mod = @import("tiles.zig");
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

/// What triggers a panel's sweeps: "TTL2", or "row 5 falling -62 µV".
pub fn trigText(buf: []u8, p: *const Panel) []const u8 {
    return if (p.trigger.source == .ttl)
        format.fmt(buf, "TTL{d}", .{p.trigger.line})
    else
        format.fmt(buf, "row {d} {s} {d:.0} µV", .{
            p.trigger.row + 1, if (p.trigger.rising) "rising" else "falling", p.trigger.level_now_uv,
        });
}

/// How many recent samples to filter again when a panel's corners change: what its window
/// can show (two passes in sweep mode), and a second more.
pub fn refilterSamples(set: *const panels_mod.Set, fs: f64) usize {
    var longest: f64 = 0;
    for (set.items[0..set.len]) |*p| longest = @max(longest, if (p.mode == .sweep) 2 * p.span_s else p.span_s);
    return @intFromFloat((longest + 1.0) * fs);
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
    /// The panel that wheel, pinch and keys act on.
    target: usize = 0,
    /// Set by a test script (`panel=`, `pointer=`); then it overrides the pointer.
    scripted_target: ?usize = null,
    /// Where the pointer is, as a fraction of the display's height (for the row under it).
    pointer_fy: f64 = 0,
    scripted_pointer: bool = false,
    /// The triggers of each panel's TTL line (used by panels in triggered mode).
    triggers: [panels_mod.max_panels]oez.sweeps.Triggers = @splat(.{}),

    /// Set by `a` (and the control window's button): the alarm banner has been seen.
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
            .listening = self.audio.channels,
            .num_listening = if (self.audio.enabled) self.audio.num_channels else 0,
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

    /// A click on an electrode row: listen to that channel alone, or with Ctrl add it to
    /// (or take it out of) what is listened to.
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
            const channel = p.trigger.source == .channel and p.kind == .electrode;
            const made_from: u64 = if (channel) 0x100 + @as(u64, p.trigger.row) else p.trigger.line;
            if (self.trig_made_from[i] != made_from) {
                self.trig_made_from[i] = made_from;
                t.reset(p.trigger.line);
                self.slopes[i] = null;
            }
            if (channel) {
                const want: oez.slope.Settings = .{
                    .rising = p.trigger.rising,
                    .auto = p.trigger.auto,
                    .level = p.trigger.level_uv / oez.types.electrode_uv_per_bit,
                    .holdoff_ms = p.trigger.holdoff_ms,
                };
                if (self.slopes[i] == null) self.slopes[i] = .init(fs, want);
                const sl = &self.slopes[i].?;
                sl.settings = want;
                // With the panel's reference, if the trigger's row is one it applies to.
                var ref: [oez.audio.max_car_ref]u32 = undefined;
                const nref = self.carChannels(p.first_ch + p.trigger.row, &ref);
                sl.feed(first, samples, nch, p.first_ch + p.trigger.row, ref[0..nref], t);
                p.trigger.level_now_uv = sl.level() * oez.types.electrode_uv_per_bit;
            } else t.feed(first, words);
            if (p.tint_line == 0) continue;
            if (pl.line != p.tint_line) pl.reset(p.tint_line);
            pl.feed(first, words);
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
            .trig_rising => |on| {
                // The fixed level changes side with the slope.
                if (on != p.trigger.rising) p.trigger.level_uv = -p.trigger.level_uv;
                p.trigger.rising = on;
            },
            .trig_auto => |on| {
                // Going to a fixed level starts from where the level is now.
                if (!on and p.trigger.auto and p.trigger.level_now_uv != 0) p.trigger.level_uv = @round(p.trigger.level_now_uv);
                p.trigger.auto = on;
            },
            .trig_level => |f| p.trigger.level_uv = if (@abs(p.trigger.level_uv * f) < 5)
                (if (p.trigger.level_uv < 0) -5.0 else 5.0)
            else
                p.trigger.level_uv * f,
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
                'a' => self.acknowledged = true,
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
        // A click on an electrode row listens to it (Ctrl: adds or removes it).
        if (in.clicks > 0 and p.kind == .electrode) {
            if (p.rowAt(self.pointer_fy)) |row| self.listenClick(p.first_ch + @as(u32, @intCast(row)), in.ctrl);
        }
        // A click on a row of a spike-triggered panel moves the trigger to that row.
        if (in.clicks > 0 and p.mode == .triggered and p.trigger.source == .channel) {
            if (p.rowAt(self.pointer_fy)) |row| p.trigger.row = @intCast(row);
        }
        p.clamp();
        return quit;
    }

    /// What to draw: each panel's traces, then dividers and a bar marking the target panel,
    /// and into `batch` the text: each panel's title (name, time base, scale per row), its
    /// row labels, and the status read-out in the bottom right corner.
    pub fn frame(
        self: *const Display,
        gpu: *const Gpu,
        layout: *const oez.types.Layout,
        newest: i64,
        review: ?ReviewView,
        status: Status,
        notes: *const notes_mod.Notes,
        batch: *font.Batch,
        draws: *[max_draws]gpu_mod.PanelDraw,
        fills: *[max_fills]gpu_mod.Fill,
    ) struct { draws: []const gpu_mod.PanelDraw, fills: []const gpu_mod.Fill, text: []const font.Vertex } {
        const width = gpu.extent.width;
        const height = gpu.extent.height;
        const nch = gpu.nch;
        const fs = layout.sample_rate;
        var nf: usize = 0;
        var nd: usize = 0;
        batch.clear();
        const line_h = @round(batch.font.line_height);
        for (self.set.items[0..self.set.len], 0..) |*p, i| {
            const r = p.pixelRect(width, height);
            // Sweep: a whole number of samples per pass, so the picture stands still.
            const span: f64 = if (p.mode == .sweep) @max(1, @round(p.span_s * fs)) else p.span_s * fs;
            // In review a panel shows a fixed stretch that ends at the review position
            // (triggered panels stay live: their sweeps are about now).
            const in_review = review != null and p.mode != .triggered;
            const t_end: i64 = if (in_review) review.?.end else newest;
            const sweeping = p.mode == .sweep and !in_review;
            const phase: f64 = if (sweeping) @floatFromInt(@mod(t_end, @as(i64, @intFromFloat(span)))) else -1;
            const px: f32 = @floatFromInt(r.x);
            const py: f32 = @floatFromInt(r.y);
            const shown = p.shownRows();
            var params: gpu_mod.TraceParams = .{
                .nch = @intCast(nch),
                .cap_mask = @intCast(gpu.hist_cap - 1),
                .newest = @truncate(@as(u64, @bitCast(t_end))),
                .first_ch = p.drawColumn(),
                .cols = r.w,
                .rows = shown,
                .span = @floatCast(span),
                .lsb_per_row = @floatCast(p.scale / p.unitsPerLsb()),
                .half_px = 1.5 / @as(f32, @floatFromInt(r.h)),
                .phase = @floatCast(phase),
                .gain_base = @intCast(i * gpu_mod.max_rows),
            };
            // The rows' own scales, for the shader, in the order the rows are drawn.
            if (gpu.row_gains.len >= (i + 1) * gpu_mod.max_rows) {
                const gains = gpu.row_gains[i * gpu_mod.max_rows ..][0..gpu_mod.max_rows];
                for (0..@min(shown, gpu_mod.max_rows)) |k| gains[k] = p.per_row.gain[p.rowOfShown(k) orelse k];
            }
            const rect: gpu_mod.PixelRect = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
            var shown_sweeps: usize = 0;
            if (p.mode == .triggered) {
                // One draw per sweep, oldest first and dimmest, the newest on top.
                const trig = &self.triggers[i];
                const pre: i64 = @intFromFloat(@round(p.trigger.pre_ms * 1e-3 * fs));
                const post: i64 = @max(1, @as(i64, @intFromFloat(@round(p.trigger.post_ms * 1e-3 * fs))));
                const window: f64 = @floatFromInt(pre + post);
                // Sweeps whose samples the history may no longer hold are left out.
                const keep: i64 = @as(i64, @intCast(gpu.hist_cap)) - @as(i64, @intFromFloat(fs));
                var k: usize = @min(p.trigger.overlay, trig.len);
                while (k > 0) {
                    k -= 1;
                    const s = trig.recent(k).?;
                    if (newest - (s.t0 - pre) > keep) continue;
                    const end = s.t0 + post;
                    const future: f64 = @floatFromInt(@max(0, end - newest));
                    if (window - future < 2 * window / @as(f64, @floatFromInt(r.w)) + 2) continue;
                    params.newest = @truncate(@as(u64, @bitCast(end)));
                    params.span = @floatCast(window);
                    params.phase = -1;
                    params.future = @floatCast(future);
                    params.gain = if (k == 0) 1.0 else 0.6 - 0.4 * @as(f32, @floatFromInt(k - 1)) /
                        @as(f32, @floatFromInt(@max(1, p.trigger.overlay -| 2)));
                    if (nd < draws.len) {
                        draws[nd] = .{ .rect = rect, .params = params };
                        nd += 1;
                        shown_sweeps += 1;
                    }
                }
                // Over the traces: when the trigger line was high in the newest sweep
                // (the laser), and a line at the trigger.
                const w: f32 = @floatFromInt(r.w);
                const x0 = px + w * @as(f32, @floatFromInt(pre)) / @as(f32, @floatCast(window));
                if (p.trigger.source == .channel) {
                    // The level, as a line across the trigger's row (in the row's own
                    // scale: it sits on the trace when the panel shows the spike band).
                    const row_h = @as(f32, @floatFromInt(r.h)) / @as(f32, @floatFromInt(@max(shown, 1)));
                    const centre = py + (@as(f32, @floatFromInt(p.shownIndex(p.trigger.row) orelse 0)) + 0.5) * row_h;
                    const dy: f32 = @floatCast(std.math.clamp(p.trigger.level_now_uv / p.rowScale(p.trigger.row), -1.5, 1.5));
                    var x = px;
                    if (p.shownIndex(p.trigger.row) != null)
                        while (x < px + w) : (x += 12) batch.rect(x, @round(centre - dy * row_h), 6, 1, theme.trigger_level);
                } else if (trig.recent(0)) |s| {
                    const until = @min(s.fall orelse newest, s.t0 + post);
                    const x1 = px + w * @as(f32, @floatFromInt(until - s.t0 + pre)) / @as(f32, @floatCast(window));
                    if (shown_sweeps > 0 and x1 > x0) batch.rect(x0, py, x1 - x0, @floatFromInt(r.h), theme.tint_pulse);
                }
                batch.rect(@round(x0), py, 1, @floatFromInt(r.h), theme.trigger_line);
            } else if (nd < draws.len and !(in_review and !review.?.ready)) {
                draws[nd] = .{ .rect = rect, .params = params, .review = in_review and review.?.from_file };
                nd += 1;
            }
            if (p.mode != .triggered and span >= 1) {
                // Notes: a line where each was stamped, with its text beside it.
                const w: f64 = @floatFromInt(r.w);
                const span_i: i64 = @intFromFloat(span);
                const pass_start: i64 = if (sweeping) t_end - @as(i64, @intFromFloat(phase)) else t_end - span_i;
                var k: usize = 0;
                while (notes.recentNote(k)) |note| : (k += 1) {
                    const at = note.sample;
                    if (at < pass_start - span_i) break;
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
                        _ = batch.label(x + 5, py + line_h + 12, notes_mod.prefix(note.text(), 40), theme.heard);
                }
            }
            if (p.tint_line != 0 and p.mode != .triggered and span >= 1) {
                // A tint over the panel wherever its tint line was high. Scrolling: time
                // runs to the newest sample at the right edge. Sweep: this pass left of the cursor,
                // the previous pass right of it.
                const pulses = &self.pulses[i];
                const w: f64 = @floatFromInt(r.w);
                const span_i: i64 = @intFromFloat(span);
                const pass_start: i64 = if (sweeping) t_end - @as(i64, @intFromFloat(phase)) else t_end - span_i;
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
            if (sweeping) {
                // The cursor: a line where the newest sample is, and a blank stretch ahead.
                const cx: u32 = @min(r.w - 1, @as(u32, @intFromFloat(phase / span * @as(f64, @floatFromInt(r.w)))));
                fills[nf] = .{ .rect = .{ .x = r.x + cx, .y = r.y, .w = @min(10, r.w - cx), .h = r.h }, .colour = theme.background };
                fills[nf + 1] = .{ .rect = .{ .x = r.x + cx, .y = r.y, .w = 1, .h = r.h }, .colour = theme.sweep_cursor };
                nf += 2;
            }
            // A line along the left and top edges that are not the display's own.
            if (r.x > 0) {
                fills[nf] = .{ .rect = .{ .x = r.x, .y = r.y, .w = 1, .h = r.h }, .colour = theme.panel_divider };
                nf += 1;
            }
            if (r.y > 0) {
                fills[nf] = .{ .rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = 1 }, .colour = theme.panel_divider };
                nf += 1;
            }
            if (line_h <= 0) continue;
            // Title, top left.
            const title_y = py + 6;
            var span_buf: [24]u8 = undefined;
            var scale_buf: [24]u8 = undefined;
            var title_buf: [128]u8 = undefined;
            var band_buf: [48]u8 = undefined;
            var trig_buf: [48]u8 = undefined;
            const title = if (p.mode == .triggered)
                format.fmt(&title_buf, "{s}   {s}   -{d:.1}/+{d:.1} ms   {s}/row{s}   {d} sweeps{s}", .{
                    p.name(),
                    trigText(&trig_buf, p),
                    p.trigger.pre_ms,
                    p.trigger.post_ms,
                    fmtScale(&scale_buf, p.kind, p.scale),
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
                format.fmt(&title_buf, "{s}   {s}   {s}/row{s}{s}", .{
                    p.name(),
                    fmtSpan(&span_buf, p.span_s),
                    fmtScale(&scale_buf, p.kind, p.scale),
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
            if (p.mode == .triggered) {
                // The time axis along the bottom: the ends of the window and the trigger.
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
            // Row labels down the left edge, thinned when rows are shorter than a line.
            if (shown == 0) continue;
            const row_h = @as(f32, @floatFromInt(r.h)) / @as(f32, @floatFromInt(shown));
            const step: u32 = @max(1, @as(u32, @intFromFloat(@ceil((line_h + 3) / row_h))));
            var k: u32 = 0;
            while (k < shown) : (k += step) {
                // The `k`-th row drawn is panel row `row` (hidden rows are left out).
                const row: u32 = @intCast(p.rowOfShown(k) orelse continue);
                const y = py + (@as(f32, @floatFromInt(k)) + 0.5) * row_h - 0.5 * line_h;
                if (p.kind != .ttl and y < title_y + line_h + 3) continue;
                var label_buf: [16]u8 = undefined;
                // The rows listened to stand out.
                const heard = p.kind == .electrode and self.audio.enabled and self.listening(p.first_ch + row);
                var after = batch.label(
                    px + 5,
                    y,
                    rowLabel(&label_buf, p, row, layout, &self.set),
                    if (heard) theme.heard else theme.text_dim,
                );
                // In a filtered panel, the rows shown as they are say so.
                if (p.filter.on and p.kind == .electrode and !p.rowFiltered(row)) after = batch.label(after + 4, y, "raw", theme.text_dim);
                // A row with a scale of its own says so.
                if (row < panels_mod.max_rows and p.per_row.gain[row] != 1) {
                    var own_buf: [24]u8 = undefined;
                    _ = batch.label(after + 4, y, fmtScale(&own_buf, p.kind, p.rowScale(row)), theme.row_scale_text);
                }
            }
        }
        if (line_h > 0 and (status.alarm_len > 0 or status.warning_len > 0)) {
            // Samples are being lost, or the recording has failed: a bar across the whole
            // display that stays until it is acknowledged. A warning (the disk falling
            // behind) is amber and goes when its cause does.
            const is_alarm = status.alarm_len > 0;
            const text = if (is_alarm) status.alarm() else status.warning();
            const bar_h = 2 * line_h + 14;
            const bar_y = if (review != null) line_h + 18 else 0;
            batch.rect(0, bar_y, @floatFromInt(width), bar_h, if (is_alarm) theme.alarm_bar else theme.warning_bar);
            const tw = batch.font.width(text);
            _ = batch.text((@as(f32, @floatFromInt(width)) - tw) / 2, bar_y + 5, text, theme.bar_text);
            if (is_alarm) {
                const hint = "press a to acknowledge";
                _ = batch.text(
                    (@as(f32, @floatFromInt(width)) - batch.font.width(hint)) / 2,
                    bar_y + line_h + 7,
                    hint,
                    theme.alarm_hint_text,
                );
            }
        }
        if (review) |v| {
            if (line_h > 0) {
                // Unmistakable: this is not what the electrodes see now.
                var buf: [120]u8 = undefined;
                var clock_buf: [16]u8 = undefined;
                const text = std.fmt.bufPrint(
                    &buf,
                    "REVIEW   {d:.1} s behind live   at {s}{s}   End = live",
                    .{
                        v.behind_s,
                        control.fmtClock(&clock_buf, @as(f64, @floatFromInt(v.end)) / layout.sample_rate),
                        if (v.ready) "" else "   (reading)",
                    },
                ) catch "REVIEW";
                const tw = batch.font.width(text);
                const x = (@as(f32, @floatFromInt(width)) - tw) / 2;
                batch.rect(x - 10, 4, tw + 20, line_h + 10, theme.warning_bar);
                _ = batch.text(x, 9, text, theme.review_badge_text);
            }
        }
        if (notes.editing and line_h > 0) {
            // The note being typed, bottom left, with when it is stamped.
            var buf: [notes_mod.max_text + 64]u8 = undefined;
            var clock_buf: [16]u8 = undefined;
            const text = std.fmt.bufPrint(
                &buf,
                "note at {s}:  {s}_",
                .{ control.fmtClock(&clock_buf, @as(f64, @floatFromInt(notes.draft.sample)) / layout.sample_rate), notes.draft.text() },
            ) catch "note";
            _ = batch.label(10, @as(f32, @floatFromInt(height)) - 2 * line_h - 14, text, theme.note_draft_text);
        }
        if (status.valid and line_h > 0) {
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
        if (self.set.len > 1) {
            const r = self.set.items[self.target].pixelRect(width, height);
            fills[nf] = .{ .rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = 3 }, .colour = theme.target_bar };
            nf += 1;
        }
        return .{ .draws = draws[0..nd], .fills = fills[0..nf], .text = batch.vertices[0..batch.len] };
    }
};

/// The panels for this run: from the config, or one per headstage.
pub fn makeDisplay(args: Args, layout: *const oez.types.Layout) ?Display {
    var diag: panels_mod.Diagnostics = .{};
    var set = panels_mod.fromConfig(args.doc, layout, &diag) catch {
        log.err("config: {s}", .{diag.message()});
        return null;
    };
    const applied = panels_mod.applyViews(&set, args.views_doc, &diag) catch blk: {
        log.warn("view file: {s}; the rest of it is ignored", .{diag.message()});
        break :blk 0;
    };
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
