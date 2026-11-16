//! The neural display: its panels, what the user's input does to them, and what is drawn
//! each frame (traces, overlays, labels, badges).

const std = @import("std");
const dimna = @import("dimna");
const gpu_mod = @import("gpu_vulkan.zig");
const Gpu = gpu_mod.Gpu;
const font = @import("font.zig");
const theme = @import("theme.zig");
const format = @import("format.zig");
const i18n = @import("i18n.zig");
const fmtSpan = format.fmtSpan;
const fmtScale = format.fmtScale;
const control = @import("control.zig");
const notes_mod = @import("notes.zig");
const tiles_mod = @import("tiles.zig");
const tile_link = @import("tile_link.zig");
const Args = @import("args.zig").Args;
const Input = @import("window.zig").Input;
const Cursor = @import("window.zig").Cursor;
const Key = @import("window.zig").Key;
const panels_mod = dimna.panels;
const Panel = panels_mod.Panel;
const log = std.log.scoped(.dimna);

pub const max_text_vertices = 24 * 1024;

/// Per panel: two dividers, the target bar, and the sweep cursor's two.
pub const max_fills = 5 * panels_mod.max_panels;

/// One draw per panel, or per overlaid sweep of a triggered panel.
pub const max_draws = panels_mod.max_panels * dimna.sweeps.max_sweeps;

/// The display filter for a panel's title: "   300-6000 Hz", "   > 10 Hz", "   < 300 Hz",
/// or nothing when the panel shows its channels as they are.
pub fn fmtBand(buf: []u8, p: *const Panel) []const u8 {
    if (p.kind != .electrode) return "";
    if (!p.filter.on) return if (p.carActive()) i18n.text(.title_car) else "";
    const lo = p.filter.low_hz;
    const hi = p.filter.high_hz;
    const car: []const u8 = if (p.carActive()) i18n.text(.title_car) else "";
    return if (lo > 0 and hi > 0)
        i18n.fmt(buf, .title_band_range, .{ .low = lo, .high = hi, .car = car })
    else if (lo > 0)
        i18n.fmt(buf, .title_band_above, .{ .low = lo, .car = car })
    else if (hi > 0)
        i18n.fmt(buf, .title_band_below, .{ .high = hi, .car = car })
    else
        i18n.fmt(buf, .title_band_none, .{ .car = car });
}

/// An electrode channel by headstage and number ("A1-5"), or "ch 37" if it is not one.
pub fn channelName(buf: []u8, layout: *const dimna.types.Layout, ch: u32) []const u8 {
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
    /// Samples the review history holds; 0: as the live one.
    rev_cap: usize = 0,
    /// Buckets the decimated history holds (a power of two); 0: none.
    dec_cap: usize = 0,
    row_gains: []f32,

    pub fn of(gpu: *const Gpu) Surface {
        return .{
            .width = gpu.extent.width,
            .height = gpu.extent.height,
            .nch = gpu.nch,
            .hist_cap = gpu.hist_cap,
            .rev_cap = gpu.rev_cap,
            .dec_cap = gpu.dec.cap,
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
    /// A notice over the display while it lasts (`Notice.shown`).
    notice: ?*const Notice = null,

    pub fn alarm(self: *const Status) []const u8 {
        return self.alarm_buf[0..self.alarm_len];
    }
    pub fn warning(self: *const Status) []const u8 {
        return self.warning_buf[0..self.warning_len];
    }
};

/// A message over the display for its first seconds (where the colour scheme came from),
/// two lines, then gone by itself.
pub const Notice = struct {
    line1_buf: [200]u8 = undefined,
    line1_len: usize = 0,
    line2_buf: [200]u8 = undefined,
    line2_len: usize = 0,
    /// When it goes (ns, the main loop's clock); 0: from the first frame that asks.
    until_ns: i128 = 0,

    /// How long it stays.
    pub const seconds = 8;

    pub fn set(self: *Notice, comptime f1: []const u8, a1: anytype, comptime f2: []const u8, a2: anytype) void {
        self.line1_len = format.fmt(&self.line1_buf, f1, a1).len;
        self.line2_len = format.fmt(&self.line2_buf, f2, a2).len;
    }

    /// The same, from two messages of the catalogue.
    pub fn say(self: *Notice, comptime id1: i18n.Id, a1: anytype, comptime id2: i18n.Id, a2: anytype) void {
        self.line1_len = i18n.fmt(&self.line1_buf, id1, a1).len;
        self.line2_len = i18n.fmt(&self.line2_buf, id2, a2).len;
    }

    pub fn line1(self: *const Notice) []const u8 {
        return self.line1_buf[0..self.line1_len];
    }
    pub fn line2(self: *const Notice) []const u8 {
        return self.line2_buf[0..self.line2_len];
    }

    /// Whether it is up at `now_ns`; the first call starts its time.
    pub fn shown(self: *Notice, now_ns: i128) bool {
        if (self.line1_len == 0) return false;
        if (self.until_ns == 0) self.until_ns = now_ns + seconds * 1_000_000_000;
        return now_ns < self.until_ns;
    }
};

/// The display in scroll-back review: where it is looking.
pub const ReviewView = struct {
    /// The sample at the right edge of every panel in review.
    end: i64,
    /// Drawn from the review history (the recording's file) instead of the live one.
    from_file: bool,
    /// The stretch needed is there to draw (for the panels drawn from samples).
    ready: bool,
    behind_s: f64,
    /// Panels (bit i: panel i) whose stretch is so long that it is drawn from the
    /// overview's pixel columns (`Gpu.rev_cols`), and those of them that are there to draw.
    columns: u32 = 0,
    columns_ready: u32 = 0,
};

/// What triggers a panel's sweeps: "TTL2", or "row 5 falling -62 µV" (the trigger channel's
/// threshold `uv`, its sign the slope), or before that is known "row 5 falling 4.5 σ".
pub fn trigText(buf: []u8, p: *const Panel, uv: ?f32, sigmas: f32) []const u8 {
    if (p.trigger.source == .ttl) return format.fmt(buf, "TTL{d}", .{p.trigger.line});
    const v = uv orelse return i18n.fmt(buf, .trigger_row_sigmas, .{ .row = p.trigger.row + 1, .slope = i18n.text(.slope_falling), .sigmas = sigmas });
    return i18n.fmt(buf, .trigger_row_level, .{
        .row = p.trigger.row + 1,
        .slope = if (v > 0) i18n.text(.slope_rising) else i18n.text(.slope_falling),
        .uv = v,
    });
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

/// Whether panel `p` is filtered with about the detector's band (`threshold_low_hz`).
pub fn bandIsDetectors(p: *const Panel) bool {
    const lo = p.filter.low_hz;
    const hi = p.filter.high_hz;
    return p.filter.on and lo >= threshold_low_hz[0] and lo <= threshold_low_hz[1] and
        hi >= threshold_high_hz[0] and hi <= threshold_high_hz[1];
}

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

/// The inverse of `levelPixelY`: the value (in the panel's unit) at the centre of pixel row
/// `y` on panel row `row` of `p`, drawn in `r`, so that `levelPixelY` of it is `y` again;
/// null if the row is hidden. Beyond ±1.5 rows from the row's centre, the value there (as
/// `levelPixelY` clamps).
pub fn levelAtPixelY(p: *const Panel, r: panels_mod.Rect, row: usize, y: f32) ?f64 {
    const k = p.shownIndex(row) orelse return null;
    const row_h = @as(f64, @floatFromInt(r.h)) / @as(f64, @floatFromInt(@max(p.shownRows(), 1)));
    const centre = @as(f64, @floatFromInt(r.y)) + (@as(f64, @floatFromInt(k)) + 0.5) * row_h;
    const d = std.math.clamp((centre - (@floor(@as(f64, y)) + 0.5)) / row_h, -1.5, 1.5);
    return d * p.rowScale(row);
}

/// A threshold line drawn on a panel: whose threshold, on which of its rows, at which pixel
/// row, and whether it is drawn dashed (a triggered panel's trigger row) or solid (the
/// focused row).
pub const ThresholdLine = struct { ch: u32, row: usize, y: f32, dashed: bool };

/// The threshold lines of one panel, at most two (one per channel).
pub const ThresholdLines = struct {
    items: [2]ThresholdLine = undefined,
    len: usize = 0,

    pub fn slice(self: *const ThresholdLines) []const ThresholdLine {
        return self.items[0..self.len];
    }
};

/// What one turn's input asks of review (`Display.reviewActions`): one action per key, and
/// samples to move by for the wheel (0: none), after the keys.
pub const ReviewActions = struct {
    items: [@typeInfo(@FieldType(Input, "keys")).array.len]control.ReviewAction = undefined,
    len: usize = 0,
    scroll: i64 = 0,

    pub fn slice(self: *const ReviewActions) []const control.ReviewAction {
        return self.items[0..self.len];
    }
};

/// How near (in pixel rows) the pointer must be to a threshold line to take hold of it.
pub const grab_px = 4;

/// A threshold line being dragged: in panel `panel`, channel `ch` on row `row`. `from_y` is
/// the pixel row it was taken at; nothing changes until the pointer has left it.
pub const Drag = struct { panel: usize, ch: u32, row: usize, from_y: f32, moved: bool = false };

/// One line of the key summary (`?`): in which window, the key or mouse action, what it
/// does (messages of the catalogue). ASCII texts are drawn in the fixed-width font
/// (`helpText`).
pub const KeyHelp = struct { window: enum { display, tiles }, key: i18n.Id, what: i18n.Id };

/// The key summary, the one place it is written: the display's keys (they agree with
/// `args.usage`, a test checks) and the spike-tile window's (tiles.zig).
pub const key_help = [_]KeyHelp{
    .{ .window = .display, .key = .key_wheel, .what = .help_y_scale_uv },
    .{ .window = .display, .key = .key_ctrl_wheel, .what = .help_y_scale_row },
    .{ .window = .display, .key = .key_shift_wheel, .what = .help_back_forward_review },
    .{ .window = .display, .key = .key_sideways_scroll, .what = .help_same_as_shift_wheel },
    .{ .window = .display, .key = .key_alt_wheel, .what = .help_time_base_window },
    .{ .window = .display, .key = .key_touchpad_pinch, .what = .help_time_base },
    .{ .window = .display, .key = .key_minus_equals, .what = .help_y_scale },
    .{ .window = .display, .key = .key_brackets, .what = .help_time_base },
    .{ .window = .display, .key = .key_r, .what = .help_panel_as_configured },
    .{ .window = .display, .key = .key_m, .what = .help_scrolling_sweep },
    .{ .window = .display, .key = .key_f, .what = .help_filter_toggle },
    .{ .window = .display, .key = .key_comma_period, .what = .help_low_corner },
    .{ .window = .display, .key = .key_semicolon_quote, .what = .help_high_corner },
    .{ .window = .display, .key = .key_t, .what = .help_triggered_toggle },
    .{ .window = .display, .key = .key_1_8, .what = .help_triggered_line },
    .{ .window = .display, .key = .key_s, .what = .help_triggered_source },
    .{ .window = .display, .key = .key_left_click_row, .what = .help_focus_trigger },
    .{ .window = .display, .key = .key_right_click_row, .what = .help_listen_alone },
    .{ .window = .display, .key = .key_ctrl_right_click, .what = .help_sound_add_take },
    .{ .window = .display, .key = .key_middle_click, .what = .help_no_focus },
    .{ .window = .display, .key = .key_drag_red_line, .what = .help_threshold_fixed_uv },
    .{ .window = .display, .key = .key_n, .what = .help_threshold_fixed_noise },
    .{ .window = .display, .key = .key_space, .what = .help_freeze },
    .{ .window = .display, .key = .key_left_right, .what = .help_back_forward_tenth },
    .{ .window = .display, .key = .key_pgup_pgdn, .what = .help_back_forward_window },
    .{ .window = .display, .key = .key_home_end, .what = .help_start_live },
    .{ .window = .display, .key = .key_l, .what = .help_back_to_live },
    .{ .window = .display, .key = .key_slash, .what = .help_type_note },
    .{ .window = .display, .key = .key_backtick, .what = .help_stamp_draft },
    .{ .window = .display, .key = .key_1_9, .what = .help_stamp_preset },
    .{ .window = .display, .key = .key_tilde, .what = .help_adc_toggle },
    .{ .window = .display, .key = .key_shift_a, .what = .help_acknowledge },
    .{ .window = .display, .key = .key_question, .what = .help_these_keys },
    .{ .window = .display, .key = .key_q_or_esc, .what = .help_quit },
    .{ .window = .tiles, .key = .key_wheel, .what = .help_tiles_scale_shown },
    .{ .window = .tiles, .key = .key_ctrl_wheel, .what = .help_tiles_scale_one },
    .{ .window = .tiles, .key = .key_ctrl_shift_wheel, .what = .help_tiles_threshold },
    .{ .window = .tiles, .key = .key_r, .what = .help_tiles_common_range },
    .{ .window = .tiles, .key = .key_a, .what = .help_tiles_own_range },
    .{ .window = .tiles, .key = .key_u, .what = .help_undo_scale },
    .{ .window = .tiles, .key = .key_shift_u, .what = .help_redo_scale },
    .{ .window = .tiles, .key = .key_n, .what = .help_threshold_fixed_noise },
    .{ .window = .tiles, .key = .key_left_click, .what = .help_focus_channel },
    .{ .window = .tiles, .key = .key_right_click, .what = .help_listen_alone },
    .{ .window = .tiles, .key = .key_ctrl_right_click, .what = .help_sound_add_take },
    .{ .window = .tiles, .key = .key_middle_click, .what = .help_no_focus },
    .{ .window = .tiles, .key = .key_drag_the_red_line, .what = .help_threshold_fixed_uv },
    .{ .window = .tiles, .key = .key_the_chips, .what = .help_tiles_chips },
};

/// The label of one row: the electrode's number on its headstage (with the headstage's name
/// when the panel spans more than one), or AUXn / ADCn.
pub fn rowLabel(buf: []u8, p: *const Panel, row: u32, layout: *const dimna.types.Layout, set: *const panels_mod.Set) []const u8 {
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
    thresholds: dimna.thresholds.Thresholds = .{},
    reported: dimna.thresholds.Reported = .{},
    /// Set when `thresholds` changed (the control window is to be told).
    thresholds_changed: bool = false,
    /// The panel that wheel, pinch and keys act on.
    target: usize = 0,
    /// Set by a test script (`panel=`, `pointer=`); then it overrides the pointer.
    scripted_target: ?usize = null,
    /// Where the pointer is, as fractions of the display's width and height (for the row
    /// under it, and whether it is over the panel input goes to).
    pointer_fy: f64 = 0,
    pointer_fx: f64 = 0,
    /// The pointer is over the display's window (for hover tips).
    pointer_inside: bool = false,
    scripted_pointer: bool = false,
    /// A test script holds the left button down (`press` until `release`).
    scripted_left: bool = false,
    /// The display's size in pixels when it was last drawn: where input finds the lines
    /// drawn (0 before the first frame).
    size: [2]u32 = .{ 0, 0 },
    /// The font's line height when it was last drawn (0 before, and without a font): the
    /// header strip of a triggered panel is made from it (`Panel.bodyRect`).
    line_h: f32 = 0,
    /// The ADC panels are hidden (`~`), and the panels beside them stretched over them. Not
    /// saved.
    adc_hidden: bool = false,
    /// What the pointer is to look like (over a threshold line: a hand); the loop sets it
    /// on the window once per turn.
    cursor: Cursor = .default,
    /// A threshold line being dragged with the left button.
    drag: ?Drag = null,
    /// The key summary is shown over the display (`?`; `?` or Esc hides it).
    help: bool = false,
    /// Per panel: the channel it triggers on (in triggered mode, on a channel) as last
    /// seen, and whether it still owes that channel a latch (see `updateLatches`).
    trig_on: [panels_mod.max_panels]?u32 = @splat(null),
    owes_latch: [panels_mod.max_panels]bool = @splat(false),
    /// The triggers of each panel's TTL line (used by panels in triggered mode).
    triggers: [panels_mod.max_panels]dimna.sweeps.Triggers = @splat(.{}),

    /// Set by Shift+a (and the control window's button): the alarm banner has been seen.
    acknowledged: bool = false,
    /// The audio monitor's settings (which channels, volume, ...); `audio_dirty` when they
    /// have changed and the audio threads are to be told.
    audio: dimna.audio.Settings = .{},
    audio_dirty: bool = true,
    audio_recalibrate: bool = false,
    /// The sound takes the panels' common average references.
    audio_car: bool = true,

    /// The pulses of each panel's tint line (see `Panel.tint_line`).
    pulses: [panels_mod.max_panels]dimna.sweeps.Pulses = @splat(.{}),
    /// The slope trigger of each panel that triggers on one of its channels, and what its
    /// trigger list was made from (a change of source, line or row starts it afresh).
    slopes: [panels_mod.max_panels]?dimna.slope.Slope = @splat(null),
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
            if (!p.carActive() or g >= dimna.spikes.Car.max_groups) continue;
            var n: usize = 0;
            for (0..p.rows) |r| {
                if (!p.reference.ref.has(r) or n == dimna.spikes.Car.max_ref) continue;
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
            var ref: [dimna.audio.max_car_ref]u32 = undefined;
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
        if (ch >= dimna.thresholds.max) return;
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
        // A latch owed is paid as soon as the tile window has reported (and at start-up, a
        // panel the config has triggering on a channel begins to owe one).
        self.updateLatches();
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
    /// A panel that owes its channel a latch (`updateLatches`) and has no report to latch
    /// at fixes it at the trigger's own level once it has seen a second of signal.
    fn feedSlope(self: *Display, i: usize, ch: u32, first: i64, samples: []const i16, nch: usize, fs: f64) void {
        const p = &self.set.items[i];
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
        var ref: [dimna.audio.max_car_ref]u32 = undefined;
        const nref = self.carChannels(ch, &ref);
        sl.feed(first, samples, nch, ch, ref[0..nref], &self.triggers[i]);
        if (self.owes_latch[i] and !self.thresholds.isFixed(ch) and sl.seen >= @as(u64, @intFromFloat(fs))) {
            // Following the noise, the level is below zero; anything else is no estimate.
            const level_uv = sl.level() * dimna.types.electrode_uv_per_bit;
            if (level_uv < 0) {
                self.setThreshold(ch, level_uv);
                self.owes_latch[i] = false;
            }
        }
    }

    /// What the slope trigger on channel `ch` is to do: trigger at its fixed threshold (the
    /// sign the slope), or follow the noise as a threshold that is not fixed does.
    fn slopeSettings(self: *const Display, ch: u32, holdoff_ms: f64) dimna.slope.Settings {
        if (!self.thresholds.isFixed(ch)) return .{ .auto = true, .auto_sigmas = self.thresholds.sigmas, .holdoff_ms = holdoff_ms };
        const uv = self.thresholds.fixed_uv[ch];
        return .{ .rising = uv > 0, .auto = false, .level = uv / dimna.types.electrode_uv_per_bit, .holdoff_ms = holdoff_ms };
    }

    /// If channel `ch`'s threshold follows the noise and the tile window has reported what
    /// it is, fixes it there.
    fn latch(self: *Display, ch: u32) void {
        if (self.thresholds.isFixed(ch)) return;
        const uv = self.reported.get(ch) orelse return;
        self.setThreshold(ch, uv);
    }

    /// Latching once: a panel that begins to trigger on a channel (into triggered mode, onto
    /// a channel source, onto another row, or at start-up with a config that has it so)
    /// owes that channel a latch, paid at once if a value is known (the threshold fixed
    /// where the tile window reported it), else as soon as one is (a report, or the slope
    /// trigger's own level after a second: `feedSlope`); a channel already fixed owes
    /// nothing. Paid, the channel is left as the user sets it: put back to following the
    /// noise, it triggers at `sigmas` x sigma and is not latched again until the panel
    /// begins anew. Runs after input, after a control-window edit and with every block.
    fn updateLatches(self: *Display) void {
        for (self.set.items[0..self.set.len], 0..) |*p, i| {
            const on: ?u32 = if (p.mode == .triggered) p.triggerChannel() else null;
            if (on != self.trig_on[i]) {
                self.trig_on[i] = on;
                self.owes_latch[i] = on != null;
            }
            if (!self.owes_latch[i]) continue;
            self.latch(on.?);
            if (self.thresholds.isFixed(on.?)) self.owes_latch[i] = false;
        }
    }

    /// `n`: channel `ch`'s threshold from fixed to following the noise, or from following
    /// the noise to fixed at its present value (nothing if that is not known).
    pub fn toggleFollow(self: *Display, ch: u32) void {
        if (self.thresholds.isFixed(ch)) self.setThreshold(ch, 0) else self.latch(ch);
    }

    /// A change to the thresholds, from the control window (or a request of the tile
    /// window's). Scaling or flipping one that follows the noise latches it first.
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
            .follow => |ch| self.setThreshold(ch, 0),
        }
    }

    pub fn init(set: panels_mod.Set) Display {
        return .{ .set = set, .initial = set };
    }

    /// Points input at the panel under the pointer (fractions of the display).
    pub fn pointAt(self: *Display, fx: f64, fy: f64) void {
        if (!self.scripted_pointer) {
            self.pointer_fy = fy;
            self.pointer_fx = fx;
        }
        // A drag keeps the panel it began in.
        if (self.drag != null) return;
        if (self.scripted_target) |t| {
            self.target = t;
        } else if (self.set.at(fx, fy)) |t| self.target = t;
    }

    /// Puts a panel's settings back to what the config gave it.
    pub fn reset(self: *Display, index: usize) void {
        const p = &self.set.items[index];
        const was = &self.initial.items[index];
        // `initial` holds the config's values with this run's slots. Where the panel is
        // follows the ADC panels being shown or hidden, not the settings.
        const place = p.place;
        const hidden = p.hidden;
        p.* = was.*;
        p.place = place;
        p.hidden = hidden;
    }

    /// `~`: hides the ADC panels (the panels beside them grow over them), or shows them
    /// again. Nothing without an ADC panel. The panels' places change, and with them their
    /// pixel rectangles: everything sized to a panel (the review's overview columns, the
    /// trace draws) is made from `pixelRect` each turn or frame, as after a window resize.
    pub fn toggleAdc(self: *Display) void {
        if (!panels_mod.hideAdc(&self.set, &self.initial, !self.adc_hidden)) return;
        self.adc_hidden = !self.adc_hidden;
        if (self.target < self.set.len and self.set.items[self.target].hidden) {
            for (self.set.items[0..self.set.len], 0..) |p, i| {
                if (!p.hidden) {
                    self.target = i;
                    break;
                }
            }
        }
        if (self.drag != null) self.drag = null;
    }

    /// The panel's rows are laid out in this part of its pixel rectangle.
    fn bodyRect(self: *const Display, p: *const Panel) panels_mod.Rect {
        return p.bodyRect(p.pixelRect(self.size[0], self.size[1]), self.line_h);
    }

    /// The row of `p` under the pointer, if any.
    fn rowAtPointer(self: *const Display, p: *const Panel) ?usize {
        const height: f64 = @floatFromInt(self.size[1]);
        const header = if (height > 0) @as(f64, @floatFromInt(p.headerPx(self.line_h))) / height else 0;
        return p.rowAtBelow(self.pointer_fy, header);
    }

    /// `~` (Shift+` in a US layout): which key typed it is read from what the keys typed
    /// (`in.text`), as `helpKey` does for `?`; the ` keys that typed a ~ are removed, so
    /// that they do not also stamp a note. Without a keymap (no text), ` with Shift held is
    /// the ~. Call it before the notes take their keys, and not while a note is being typed.
    pub fn adcKey(self: *Display, in: *Input) void {
        var typed: [16]u8 = undefined;
        var n_typed: usize = 0;
        var asked: usize = 0;
        for (in.text[0..in.text_len]) |c| {
            if (c != '`' and c != '~') continue;
            asked += @intFromBool(c == '~');
            if (n_typed < typed.len) typed[n_typed] = c;
            n_typed += 1;
        }
        const no_text = in.text_len == 0;
        var kept: usize = 0;
        var tick: usize = 0;
        for (in.keys[0..in.num_keys]) |k| {
            if (k.is('`')) {
                defer tick += 1;
                const is_tilde = if (no_text) in.shift else tick < typed.len and tick < n_typed and typed[tick] == '~';
                if (is_tilde) {
                    if (no_text) asked += 1;
                    continue;
                }
            }
            in.keys[kept] = k;
            kept += 1;
        }
        in.num_keys = kept;
        if (asked % 2 == 1) self.toggleAdc();
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
            .trig_holdoff => |up| p.trigger.holdoff_ms = dimna.board_config.step(
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
        self.updateLatches();
    }

    /// Applies what the user did to the target panel. True means quit.
    pub fn applyInput(self: *Display, in_given: Input) bool {
        if (self.drag == null) {
            if (self.scripted_target) |t| self.target = t;
        }
        var quit = false;
        for (in_given.keys[0..in_given.num_keys]) |k| {
            // Esc with the key summary up hides it, and does not quit.
            if (k.isNamed(.escape) and self.help) {
                self.help = false;
            } else if (k.isNamed(.escape) or k.is('q')) quit = true;
        }
        if (self.set.len == 0) return quit;
        var in = in_given;
        // A press on a threshold line, and what follows it while the button is held, are
        // the line's: no focus, no trigger moved.
        if (self.dragInput(in)) in.clicks = 0;
        const p = &self.set.items[self.target];
        self.wheel(p, in);
        for (in.keys[0..in.num_keys]) |k| self.key(p, k, in.shift);
        // On an electrode row a left click focuses its channel, a right click listens to it
        // (Ctrl: adds or removes it). A middle click anywhere clears the focus.
        if (p.kind == .electrode) {
            if (self.rowAtPointer(p)) |row| {
                const channel = p.first_ch + @as(u32, @intCast(row));
                if (in.clicks > 0) self.setFocus(channel);
                if (in.right_clicks > 0) self.listenClick(channel, in.ctrl);
            }
        }
        if (in.middle_clicks > 0) self.setFocus(null);
        // A click on a row of a spike-triggered panel moves the trigger to that row.
        if (in.clicks > 0 and p.mode == .triggered and p.trigger.source == .channel) {
            if (self.rowAtPointer(p)) |row| p.trigger.row = @intCast(row);
        }
        p.clamp();
        // A panel that has begun to trigger on a channel (s, t, r, or that click).
        self.updateLatches();
        return quit;
    }

    /// The wheel, pinch and `[` `]` on panel `p` (the target): the wheel its scale (Ctrl: the
    /// row under the pointer alone), Alt+wheel its time base (in triggered mode, the window
    /// around the trigger), as pinch and the keys do. Shift+wheel and a scroll that is
    /// mostly sideways move through time instead (`reviewScroll`).
    fn wheel(self: *Display, p: *Panel, in: Input) void {
        // One wheel click (about 15 units) changes a scale by 15 %.
        const per_unit = 0.0093;
        const sy = in.scroll_y;
        const sideways = @abs(in.scroll_x) > @abs(sy);
        if (sy != 0 and !in.alt and !in.shift and !sideways) {
            if (in.ctrl) {
                if (self.rowAtPointer(p)) |row| p.scaleRow(row, @exp(sy * per_unit));
            } else p.scale *= @exp(sy * per_unit);
        }
        var zoom: f64 = 1;
        if (in.alt) zoom *= @exp((in.scroll_x + sy) * per_unit);
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
    }

    /// What key `k` does to panel `p` (the target); `shift` held.
    fn key(self: *Display, p: *Panel, k: Key, shift: bool) void {
        switch (k) {
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
                'a' => if (shift) {
                    self.acknowledged = true;
                },
                // Triggered mode: s switches between a TTL line and spikes on the row under
                // the pointer.
                's' => if (p.mode == .triggered) {
                    if (p.trigger.source == .ttl) {
                        p.setTrigSource(.channel);
                        if (self.rowAtPointer(p)) |row| p.trigger.row = @intCast(row);
                    } else p.setTrigSource(.ttl);
                },
                't' => p.mode = if (p.mode == .triggered) .scroll else .triggered,
                // The threshold of the electrode row under the pointer: fixed <-> following
                // the noise.
                'n' => if (p.kind == .electrode) {
                    if (self.rowAtPointer(p)) |row| self.toggleFollow(p.first_ch + @as(u32, @intCast(row)));
                },
                // Triggered on a TTL line: the digits pick the line.
                '1'...'8' => if (p.mode == .triggered and p.trigger.source == .ttl) {
                    p.trigger.line = c - '0';
                },
                else => {},
            },
        }
    }

    /// `?` shows or hides the key summary, and is taken out of `in` so that it does not also
    /// start a note (a note begins at `/`, and `?` is Shift+/ on a US layout). Call it before
    /// the notes take their keys, and not while a note is being typed (then `?` is text).
    ///
    /// Which key is `?` is read from what the keys typed (`in.text`): xkbcommon gives it
    /// with the modifiers held when each key went down, in the layout in use. `in.shift` is
    /// the modifiers' state when the input was taken, which a quick Shift+/ may have left
    /// already, and `keys` hold the unshifted symbol (`/`). Only without a keymap (no text
    /// at all) is `/` with Shift held taken for `?`. The `/` keys that typed a `?` (paired
    /// in order with the `/` and `?` typed) are removed.
    pub fn helpKey(self: *Display, in: *Input) void {
        var typed: [16]u8 = undefined;
        var n_typed: usize = 0;
        var asked: usize = 0;
        for (in.text[0..in.text_len]) |c| {
            if (c != '/' and c != '?') continue;
            asked += @intFromBool(c == '?');
            if (n_typed < typed.len) typed[n_typed] = c;
            n_typed += 1;
        }
        const no_text = in.text_len == 0;
        var kept: usize = 0;
        var slash: usize = 0;
        for (in.keys[0..in.num_keys]) |k| {
            if (k.is('/')) {
                defer slash += 1;
                const is_help = if (no_text) in.shift else slash < typed.len and slash < n_typed and typed[slash] == '?';
                if (is_help) {
                    if (no_text) asked += 1;
                    continue;
                }
            }
            in.keys[kept] = k;
            kept += 1;
        }
        in.num_keys = kept;
        if (asked % 2 == 1) self.help = !self.help;
    }

    /// What this turn's input asks of scroll-back review: the keys (Space, Left / Right,
    /// PgUp / PgDn, Home, End, and `l` back to live) and the wheel (`reviewScroll`), in that
    /// order. `fs`: the sample rate.
    pub fn reviewActions(self: *const Display, in: *const Input, fs: f64) ReviewActions {
        var out: ReviewActions = .{};
        for (in.keys[0..in.num_keys]) |k| {
            out.items[out.len] = switch (k) {
                .char => |c| switch (c) {
                    ' ' => .toggle,
                    'l' => .live,
                    else => continue,
                },
                .named => |n| switch (n) {
                    .left => .back,
                    .right => .forward,
                    .page_up => .page_back,
                    .page_down => .page_forward,
                    .home => .start,
                    .end => .live,
                    else => continue,
                },
            };
            out.len += 1;
        }
        out.scroll = self.reviewScroll(in, fs);
        return out;
    }

    /// Shift+wheel, or a scroll that is mostly sideways (without Alt): samples to move the
    /// review position by (negative: back), a tenth of the target panel's time base per
    /// wheel click of 15 axis units (proportionally for a touchpad). Wheel up and scrolling
    /// left go back. A triggered panel's step is that of the longest panel that is not
    /// triggered (as `ReviewSession.step` takes its keys' steps).
    pub fn reviewScroll(self: *const Display, in: *const Input, fs: f64) i64 {
        if (in.alt or self.set.len == 0) return 0;
        const amount = if (in.shift)
            in.scroll_x + in.scroll_y
        else if (@abs(in.scroll_x) > @abs(in.scroll_y)) in.scroll_x else 0;
        if (amount == 0) return 0;
        const tp = &self.set.items[@min(self.scripted_target orelse self.target, self.set.len - 1)];
        var window_s: f64 = if (tp.mode != .triggered) tp.span_s else 0;
        if (window_s == 0) {
            for (self.set.items[0..self.set.len]) |*p| {
                if (p.mode != .triggered) window_s = @max(window_s, p.span_s);
            }
        }
        if (window_s == 0) window_s = 2;
        return @intFromFloat(@round(amount / 15 * 0.1 * window_s * fs));
    }

    /// The threshold lines under the pointer: a hand over one (within `grab_px` pixel rows,
    /// inside the panel input goes to), a press there takes hold of it, moving drags it
    /// (the threshold fixed at the value under the pointer), releasing lets go. True if the
    /// left button's press this turn was the line's.
    fn dragInput(self: *Display, in: Input) bool {
        const py: f32 = @floatCast(self.pointer_fy * @as(f64, @floatFromInt(self.size[1])));
        if (self.drag) |*d| {
            if (in.left_down) {
                self.dragTo(d, py);
                self.cursor = .grabbing;
                return true;
            }
            self.drag = null;
        }
        const line = self.lineAtPointer(py);
        self.cursor = if (line != null) .grab else .default;
        const l = line orelse return false;
        if (in.clicks == 0) return false;
        // Pressed and let go within one turn: a click on the line, which does nothing.
        if (in.left_down) {
            self.drag = .{ .panel = self.target, .ch = l.ch, .row = l.row, .from_y = @floor(py) };
            self.cursor = .grabbing;
        }
        return true;
    }

    /// The dragged threshold follows the pointer at pixel height `py`: fixed at the value
    /// under it (`levelAtPixelY`), clamped as `Thresholds.set` clamps. Crossing the row's
    /// centre changes the sign (the slope). Nothing until the pointer leaves the pixel row
    /// the line was taken at.
    fn dragTo(self: *Display, d: *Drag, py: f32) void {
        if (!d.moved and @floor(py) == d.from_y) return;
        d.moved = true;
        if (d.panel >= self.set.len) return;
        const p = &self.set.items[d.panel];
        const r = self.bodyRect(p);
        var uv = levelAtPixelY(p, r, d.row, @floor(py)) orelse return;
        // Exactly on the centre: the smallest threshold on the side it was (0 would put it
        // back to following the noise).
        if (uv == 0) uv = std.math.copysign(@as(f64, dimna.thresholds.min_uv), @as(f64, self.thresholdUv(d.ch) orelse -1));
        self.setThreshold(d.ch, uv);
    }

    /// The threshold line under the pointer (at pixel height `py`), if there is one within
    /// `grab_px` pixel rows, in the panel input goes to, with the pointer inside it (the
    /// nearest, if both of its lines are).
    fn lineAtPointer(self: *const Display, py: f32) ?ThresholdLine {
        if (self.size[1] == 0 or self.target >= self.set.len) return null;
        if (self.set.at(self.pointer_fx, self.pointer_fy) != self.target) return null;
        const p = &self.set.items[self.target];
        const lines = self.panelLines(p, self.bodyRect(p));
        var best: ?ThresholdLine = null;
        for (lines.slice()) |l| {
            const dist = @abs(@floor(py) - l.y);
            if (dist > grab_px) continue;
            if (best) |b| {
                if (@abs(@floor(py) - b.y) <= dist) continue;
            }
            best = l;
        }
        return best;
    }

    /// The threshold lines panel `p` draws in `r`: a triggered panel's trigger channel's
    /// threshold across the trigger's row, dashed, once known; the focused channel's across
    /// its row, solid, where the row shows about the detector's band, unless it is the
    /// trigger channel (one line per channel).
    pub fn panelLines(self: *const Display, p: *const Panel, r: panels_mod.Rect) ThresholdLines {
        var out: ThresholdLines = .{};
        if (p.mode == .triggered) if (p.triggerChannel()) |ch| if (self.thresholdUv(ch)) |uv| {
            if (levelPixelY(p, r, p.trigger.row, uv)) |y| {
                out.items[out.len] = .{ .ch = ch, .row = p.trigger.row, .y = y, .dashed = true };
                out.len += 1;
            }
        };
        const row = self.focusedRow(p) orelse return out;
        const ch = self.focus.?;
        if (out.len > 0 and out.items[0].ch == ch) return out;
        const uv = self.thresholdUv(ch) orelse return out;
        if (!showsDetectorBand(p, row)) return out;
        const y = levelPixelY(p, r, row, uv) orelse return out;
        out.items[out.len] = .{ .ch = ch, .row = row, .y = y, .dashed = false };
        out.len += 1;
        return out;
    }

    /// What to draw: each panel's traces, then dividers and a bar marking the target panel,
    /// and into `batch` the text: each panel's title (name, time base, scale per row), its
    /// row labels, and the status read-out in the bottom right corner. Keeps the display's
    /// size (`size`), for input to find what was drawn where.
    pub fn frame(
        self: *Display,
        surface: Surface,
        layout: *const dimna.types.Layout,
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
        self.size = .{ width, height };
        self.line_h = @round(batch.font.line_height);
        batch.clear();
        var o: Output = .{ .draws = draws, .fills = fills, .batch = batch, .line_h = @round(batch.font.line_height) };
        const scene: Scene = .{ .surface = surface, .layout = layout, .newest = newest, .review = review, .notes = notes };
        for (self.set.items[0..self.set.len], 0..) |*p, i| {
            if (!p.hidden) self.drawPanel(&o, &scene, p, i);
        }
        if (o.line_h > 0 and (status.alarm_len > 0 or status.warning_len > 0)) alarmBar(&o, status, review != null, width);
        if (review) |v| {
            if (o.line_h > 0) reviewBadge(&o, v, width, fs);
        }
        if (notes.editing and o.line_h > 0) noteDraft(&o, notes, height, fs);
        if (status.notice) |n| if (o.line_h > 0) noticeBanner(&o, n, width, height);
        if (status.valid and o.line_h > 0) statusReadout(&o, status, width, height);
        if (self.set.len > 1) targetBar(&o, self.set.items[self.target].pixelRect(width, height));
        if (o.band_tip) |p| bandTip(&o, p, self.pointer_fx * @as(f64, @floatFromInt(width)), self.pointer_fy * @as(f64, @floatFromInt(height)), width);
        if (self.help and o.line_h > 0) helpPanel(&o, width, height);
        return .{ .draws = draws[0..o.nd], .fills = fills[0..o.nf], .text = batch.vertices[0..batch.len] };
    }

    /// One panel, from the bottom up: its traces (and, triggered, the marks over them), the
    /// notes, the tint, the sweep cursor, the dividers, then its text.
    fn drawPanel(self: *const Display, o: *Output, scene: *const Scene, p: *const Panel, i: usize) void {
        const fs = scene.layout.sample_rate;
        const r = p.pixelRect(scene.surface.width, scene.surface.height);
        // Where the rows are: the panel's rectangle, less a triggered panel's header strip.
        const body = p.bodyRect(r, o.line_h);
        const t = panelTime(p, i, scene.newest, scene.review, fs);
        const params = traceParams(p, i, body, t, scene.surface);
        setRowGains(scene.surface.row_gains, p, i);
        const rect: gpu_mod.PixelRect = .{ .x = body.x, .y = body.y, .w = body.w, .h = body.h };
        var shown_sweeps: usize = 0;
        if (t.trig) |win| {
            shown_sweeps = self.sweepDraws(o, p, i, rect, params, win, scene.newest, scene.surface.hist_cap, fs);
            self.triggerMarks(o, p, i, body, win, scene.newest, shown_sweeps);
        } else if (o.nd < o.draws.len and !t.waiting) {
            o.draws[o.nd] = .{ .rect = rect, .params = params, .review = t.from_file };
            o.nd += 1;
        }
        self.thresholdLine(o, p, body);
        if (p.mode != .triggered and t.span >= 1) noteMarks(o, r, t, scene.notes);
        if (p.tint_line != 0 and p.mode != .triggered and t.span >= 1) tintPulses(o, p, r, t, &self.pulses[i]);
        if (t.sweeping) sweepCursor(o, r, t);
        dividers(o, r);
        if (o.line_h <= 0) return;
        var trig_buf: [48]u8 = undefined;
        const trig_uv = if (p.triggerChannel()) |ch| self.thresholdUv(ch) else null;
        if (panelTitle(o, p, r, t.in_review, shown_sweeps, trigText(&trig_buf, p, trig_uv, self.thresholds.sigmas))) |hot| {
            const fx: f32 = @floatCast(self.pointer_fx * @as(f64, @floatFromInt(self.size[0])));
            const fy: f32 = @floatCast(self.pointer_fy * @as(f64, @floatFromInt(self.size[1])));
            if (self.pointer_inside and fx >= hot.x and fx < hot.x + hot.w and fy >= hot.y and fy < hot.y + hot.h) o.band_tip = p;
        }
        // In review with nothing to draw yet: say what is being waited for, where the
        // traces would be.
        if (t.waiting) {
            const text = if (t.from_columns) i18n.text(.waiting_overview) else i18n.text(.waiting_reading);
            const x = @as(f32, @floatFromInt(r.x)) + (@as(f32, @floatFromInt(r.w)) - o.batch.font.width(text)) / 2;
            const y = @as(f32, @floatFromInt(r.y)) + (@as(f32, @floatFromInt(r.h)) - o.line_h) / 2;
            _ = o.batch.text(@max(x, @as(f32, @floatFromInt(r.x)) + 4), y, text, theme.text_warn);
        }
        if (p.mode == .triggered) timeAxis(o, p, r);
        self.rowLabels(o, p, body, scene.layout);
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
        const w: f32 = @floatFromInt(r.w);
        const x0 = px + w * @as(f32, @floatFromInt(pre)) / @as(f32, @floatCast(window));
        if (p.trigger.source == .channel) {
            // The level (the trigger channel's threshold, once known), as a dashed line
            // across the trigger's row where a sample of that value is drawn (in the row's
            // own scale: it sits on the trace when the panel shows the spike band).
            for (self.panelLines(p, r).slice()) |l| {
                if (!l.dashed) continue;
                var x = px;
                while (x < px + w) : (x += 12) batch.rect(x, l.y, 6, 1, theme.trigger_level);
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
    /// the row is drawn and shows about the detector's band (`panelLines`; not where the
    /// trigger's dashed line is already that channel's).
    fn thresholdLine(self: *const Display, o: *Output, p: *const Panel, r: panels_mod.Rect) void {
        for (self.panelLines(p, r).slice()) |l| {
            if (!l.dashed) o.batch.rect(@floatFromInt(r.x), l.y, @floatFromInt(r.w), 1, theme.tile_threshold);
        }
    }

    /// The row is in focus or listened to: its label carries a mark, so it is always shown.
    fn rowMarked(self: *const Display, p: *const Panel, row: u32) bool {
        if (p.kind != .electrode) return false;
        return self.focusedRow(p) == row or (self.audio.enabled and self.listening(p.first_ch + row));
    }

    /// Row labels down the left edge, thinned when rows are shorter than a line.
    fn rowLabels(self: *const Display, o: *Output, p: *const Panel, r: panels_mod.Rect, layout: *const dimna.types.Layout) void {
        const batch = o.batch;
        const line_h = o.line_h;
        const px: f32 = @floatFromInt(r.x);
        const py: f32 = @floatFromInt(r.y);
        // Rows are labelled below the title; a triggered panel's `r` is already below it.
        const clear_of_title: f32 = if (p.mode == .triggered) py - 1e6 else py + 6 + line_h + 3;
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
            if (p.kind != .ttl and y < clear_of_title) continue;
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
            if (p.filter.on and p.kind == .electrode and !p.rowFiltered(row)) after = batch.label(after + 4, y, i18n.text(.tag_raw), theme.text_dim);
            // The focused row with a threshold that is not drawn, because the row does not
            // show the detector's band, says so.
            if (focused and self.thresholdUv(p.first_ch + row) != null and !showsDetectorBand(p, row))
                after = batch.label(after + 4, y, i18n.text(.tag_threshold), theme.text_dim);
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
    /// The pointer is over a triggered panel's filter text: the tip to draw, last.
    band_tip: ?*const Panel = null,
};

/// What one frame is drawn from, besides the display's own state.
const Scene = struct {
    surface: Surface,
    layout: *const dimna.types.Layout,
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
    /// And the stretch is long: drawn from the overview's pixel columns.
    from_columns: bool = false,
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
fn panelTime(p: *const Panel, i: usize, newest: i64, review: ?ReviewView, fs: f64) PanelTime {
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
    const bit = @as(u32, 1) << @intCast(i);
    const from_columns = in_review and review.?.from_file and review.?.columns & bit != 0;
    return .{
        .span = span,
        .t_end = t_end,
        .in_review = in_review,
        .from_file = in_review and review.?.from_file,
        .from_columns = from_columns,
        .waiting = in_review and if (from_columns) review.?.columns_ready & bit == 0 else !review.?.ready,
        .sweeping = sweeping,
        .phase = phase,
        .trig = trig,
    };
}

/// The shader's parameters for panel `i`, showing the stretch `t` (a triggered panel's
/// sweeps change some of them).
fn traceParams(p: *const Panel, i: usize, r: panels_mod.Rect, t: PanelTime, surface: Surface) gpu_mod.TraceParams {
    // What is read from the recording's file is in the review history: samples only.
    const cap = if (t.from_file and surface.rev_cap > 0) surface.rev_cap else surface.hist_cap;
    return .{
        .nch = @intCast(surface.nch),
        .cap_mask = @intCast(cap - 1),
        .dec_mask = if (t.from_columns) gpu_mod.from_columns else if (t.from_file or surface.dec_cap == 0) 0 else @intCast(surface.dec_cap - 1),
        // Its pixel columns start at the panel's region; else the sample at the right edge.
        .newest = if (t.from_columns) @intCast(i * gpu_mod.column_region) else @truncate(@as(u64, @bitCast(t.t_end))),
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
fn tintPulses(o: *Output, p: *const Panel, r: panels_mod.Rect, t: PanelTime, pulses: *const dimna.sweeps.Pulses) void {
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

/// The scale for a title, without the unit's space: "400µV", "1.50mV", "2.5V", "250mV".
fn compactScale(buf: []u8, kind: panels_mod.Kind, v: f64) []const u8 {
    var tmp: [24]u8 = undefined;
    if ((kind == .aux or kind == .adc) and v >= 0.9995) {
        var num = format.fmt(&tmp, "{d:.2}", .{v});
        while (num.len > 0 and num[num.len - 1] == '0') num = num[0 .. num.len - 1];
        if (num.len > 0 and num[num.len - 1] == '.') num = num[0 .. num.len - 1];
        return format.fmt(buf, "{s}V", .{num});
    }
    const text = fmtScale(&tmp, kind, v);
    var n: usize = 0;
    for (text) |c| {
        if (c == ' ' or n >= buf.len) continue;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

/// "   400µV/row" for a title; nothing for a TTL panel (no scale), or when every shown row
/// has a scale of its own (the panel's is then used by none).
pub fn fmtTitleScale(buf: []u8, p: *const Panel) []const u8 {
    if (p.kind == .ttl or !p.usesPanelScale()) return "";
    var scale_buf: [24]u8 = undefined;
    return i18n.fmt(buf, .title_per_row, .{ .scale = compactScale(&scale_buf, p.kind, p.scale) });
}

/// A panel's title, top left (a TTL lane strip's and a triggered panel's top right): what it
/// shows (its short label), time base or what triggers it, scale and band.
/// Where on the display a piece of text is (for the pointer).
const HotRect = struct { x: f32, y: f32, w: f32, h: f32 };

/// A triggered electrode panel's title: its filter text (the band, or "raw"), in the
/// warning colour when it is not about the detector's band, and where that text is.
fn triggeredTitle(o: *Output, p: *const Panel, r: panels_mod.Rect, shown_sweeps: usize, trig: []const u8, per_row: []const u8) ?HotRect {
    const batch = o.batch;
    const face = batch.font;
    var head_buf: [128]u8 = undefined;
    var band_buf: [48]u8 = undefined;
    var tail_buf: [64]u8 = undefined;
    const head = format.fmt(&head_buf, "{s}   {s}{s}", .{ p.shortLabel(), trig, per_row });
    const electrode = p.kind == .electrode;
    // The filter text, with the three spaces before it apart (they are not the hot part).
    const band_all = if (!electrode) "" else if (p.filter.on) fmtBand(&band_buf, p) else if (p.carActive()) i18n.text(.title_raw_car) else i18n.text(.title_raw);
    const gap = "   ";
    const band = if (std.mem.startsWith(u8, band_all, gap)) band_all[gap.len..] else band_all;
    const tail = i18n.count(&tail_buf, "title_sweeps", shown_sweeps, .{ .count = shown_sweeps, .waiting = if (shown_sweeps == 0) i18n.text(.title_waiting_for_trigger) else "" });
    const px: f32 = @floatFromInt(r.x);
    const y = @as(f32, @floatFromInt(r.y)) + 6;
    const gap_w = if (band.len > 0) face.width(gap) else 0;
    const total = face.width(head) + gap_w + face.width(band) + face.width(tail);
    // Right-aligned in the strip kept for it; one wider than the panel starts at its left
    // edge and runs off the right, rather than off the left.
    const x = @max(px + @as(f32, @floatFromInt(r.w)) - total - 8, px + 4);
    batch.rect(@round(x) - 3, @round(y) - 1, @round(total) + 6, @round(face.line_height) + 2, theme.label_backing);
    var pen = batch.text(x, y, head, theme.text_bright);
    var hot: ?HotRect = null;
    if (band.len > 0) {
        pen += gap_w;
        const warn = !bandIsDetectors(p);
        const bx = pen;
        pen = batch.text(pen, y, band, if (warn) theme.text_warn else theme.text_bright);
        if (warn) hot = .{ .x = bx, .y = y - 1, .w = pen - bx, .h = face.line_height + 2 };
    }
    _ = batch.text(pen, y, tail, theme.text_bright);
    return hot;
}

/// Over a triggered panel's filter text in the warning colour: why it is that colour.
fn bandTip(o: *Output, p: *const Panel, at_x: f64, at_y: f64, width: u32) void {
    const batch = o.batch;
    const face = batch.font;
    var b1: [96]u8 = undefined;
    var band_buf: [48]u8 = undefined;
    const band = if (p.filter.on) std.mem.trimStart(u8, fmtBand(&band_buf, p), " ") else i18n.text(.tip_band_none);
    const lines = [_][]const u8{
        i18n.fmt(&b1, .tip_band_header, .{ .band = band }),
        i18n.text(.tip_band_line2),
        i18n.text(.tip_band_line3),
    };
    var w: f32 = 0;
    for (lines) |l| w = @max(w, face.width(l));
    const pad: f32 = 8;
    const box_w = w + 2 * pad;
    const box_h = @as(f32, @floatFromInt(lines.len)) * (o.line_h + 2) + 2 * pad;
    const x = std.math.clamp(@as(f32, @floatCast(at_x)) - box_w / 2, 0, @max(0, @as(f32, @floatFromInt(width)) - box_w));
    const y = @as(f32, @floatCast(at_y)) + o.line_h + 4;
    batch.rect(x, y, box_w, box_h, theme.help_backing);
    for (lines, 0..) |l, k| _ = batch.text(x + pad, y + pad + @as(f32, @floatFromInt(k)) * (o.line_h + 2), l, if (k == 0) theme.text_warn else theme.text_bright);
}

/// A panel's title; for a triggered electrode panel, where its warning-coloured filter
/// text is (`triggeredTitle`).
fn panelTitle(o: *Output, p: *const Panel, r: panels_mod.Rect, in_review: bool, shown_sweeps: usize, trig: []const u8) ?HotRect {
    const batch = o.batch;
    const px: f32 = @floatFromInt(r.x);
    const py: f32 = @floatFromInt(r.y);
    const title_y = py + 6;
    var span_buf: [24]u8 = undefined;
    var title_buf: [128]u8 = undefined;
    var band_buf: [48]u8 = undefined;
    var per_row_buf: [40]u8 = undefined;
    var sweeps_buf: [64]u8 = undefined;
    const per_row = fmtTitleScale(&per_row_buf, p);
    if (p.mode == .triggered) return triggeredTitle(o, p, r, shown_sweeps, trig, per_row);
    const title = if (p.mode == .triggered)
        format.fmt(&title_buf, "{s}   {s}{s}{s}{s}", .{
            p.shortLabel(),
            trig,
            per_row,
            fmtBand(&band_buf, p),
            i18n.count(&sweeps_buf, "title_sweeps", shown_sweeps, .{ .count = shown_sweeps, .waiting = if (shown_sweeps == 0) i18n.text(.title_waiting_for_trigger) else "" }),
        })
    else if (p.kind == .ttl)
        format.fmt(&title_buf, "{s}   {s}{s}", .{
            p.shortLabel(),
            fmtSpan(&span_buf, p.span_s),
            if (in_review) i18n.text(.title_review) else if (p.mode == .sweep) i18n.text(.title_sweep) else "",
        })
    else
        format.fmt(&title_buf, "{s}   {s}{s}{s}{s}", .{
            p.shortLabel(),
            fmtSpan(&span_buf, p.span_s),
            per_row,
            fmtBand(&band_buf, p),
            if (in_review) i18n.text(.title_review) else if (p.mode == .sweep) i18n.text(.title_sweep) else "",
        });
    // A lane strip is short: its title goes to the right, clear of the lane labels. A
    // triggered panel's too, in the strip kept for it above the rows.
    const right = p.kind == .ttl or p.mode == .triggered;
    var x = if (right) px + @as(f32, @floatFromInt(r.w)) - batch.font.width(title) - 8 else px + 8;
    // A triggered panel's title wider than the panel starts at its left edge and runs off
    // the right, rather than off the left (where the display's edge would cut its start).
    if (p.mode == .triggered) x = @max(x, px + 4);
    _ = batch.label(x, title_y, title, theme.text_bright);
    return null;
}

const AxisLabel = struct { text: []const u8, x: f32 };

/// The left end of a triggered panel's time axis: "-10.0 ms" between the row labels
/// (`from`) and the trigger line (`trigger_x`) when it fits; else "-10.0"; else at the
/// panel's left edge (`edge`), over the row labels, which is better than not saying it.
fn axisLeft(buf: []u8, face: *const font.Font, edge: f32, from: f32, trigger_x: f32, pre_ms: f64) AxisLabel {
    const long = format.fmt(buf, "-{d:.1} ms", .{pre_ms});
    if (from + face.width(long) + 8 < trigger_x) return .{ .text = long, .x = from };
    const short = long[0 .. long.len - 3];
    if (from + face.width(short) + 8 < trigger_x) return .{ .text = short, .x = from };
    return .{ .text = short, .x = edge };
}

/// A triggered panel's time axis along the bottom: the ends of the window and the trigger,
/// signed as the title used to give the window ("-10.0 ms", "0", "+40.0 ms").
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
        const trigger_x = px + w * @as(f32, @floatCast(p.trigger.pre_ms / (p.trigger.pre_ms + p.trigger.post_ms)));
        _ = batch.label(trigger_x + 4, bottom, "0", theme.text_dim);
        var l_buf: [24]u8 = undefined;
        const left = axisLeft(&l_buf, batch.font, px + 4, px + 48, trigger_x, p.trigger.pre_ms);
        _ = batch.label(left.x, bottom, left.text, theme.text_dim);
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
        const hint = i18n.text(.alarm_hint);
        _ = batch.text(
            (@as(f32, @floatFromInt(width)) - batch.font.width(hint)) / 2,
            bar_y + line_h + 7,
            hint,
            theme.alarm_hint_text,
        );
    }
}

/// A notice: two centred lines on a dark box, a third of the way down the display.
fn noticeBanner(o: *Output, n: *const Notice, width: u32, height: u32) void {
    const batch = o.batch;
    const line_h = o.line_h;
    const w: f32 = @floatFromInt(width);
    const t1 = n.line1();
    const t2 = n.line2();
    const box_w = @min(w, @max(batch.font.width(t1), batch.font.width(t2)) + 32);
    const box_h = 2 * line_h + 20;
    const y = @round(@as(f32, @floatFromInt(height)) / 3);
    batch.rect((w - box_w) / 2, y, box_w, box_h, theme.help_backing);
    _ = batch.text((w - batch.font.width(t1)) / 2, y + 8, t1, theme.text_bright);
    _ = batch.text((w - batch.font.width(t2)) / 2, y + line_h + 12, t2, theme.text_dim);
}

/// In review, top centre. Unmistakable: this is not what the electrodes see now.
fn reviewBadge(o: *Output, v: ReviewView, width: u32, fs: f64) void {
    const batch = o.batch;
    const line_h = o.line_h;
    var buf: [120]u8 = undefined;
    var clock_buf: [16]u8 = undefined;
    const text = i18n.fmt(&buf, .review_badge, .{
        .behind = v.behind_s,
        .clock = control.fmtClock(&clock_buf, @as(f64, @floatFromInt(v.end)) / fs),
        .state = if (!v.ready) i18n.text(.review_reading) else if (v.columns & ~v.columns_ready != 0) i18n.text(.review_building) else "",
    });
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
    const text = i18n.fmt(&buf, .note_draft, .{
        .clock = control.fmtClock(&clock_buf, @as(f64, @floatFromInt(notes.draft.sample)) / fs),
        .text = notes.draft.text(),
    });
    _ = batch.label(10, @as(f32, @floatFromInt(height)) - 2 * line_h - 14, text, theme.note_draft_text);
}

/// The latency, frame rate and display losses in the bottom right corner, and the
/// recording's clock beside them.
fn statusReadout(o: *Output, status: Status, width: u32, height: u32) void {
    const batch = o.batch;
    const line_h = o.line_h;
    var buf: [96]u8 = undefined;
    const text = if (status.lost > 0)
        i18n.count(&buf, "readout_skipped", status.lost, .{ .ms = status.latency_ms, .fps = status.fps, .blocks = status.lost })
    else
        format.fmt(&buf, "{d:.1} ms   {d} fps", .{ status.latency_ms, status.fps });
    const w = batch.font.width(text);
    const x = @as(f32, @floatFromInt(width)) - w - 8;
    const y = @as(f32, @floatFromInt(height)) - line_h - 6;
    _ = batch.label(x, y, text, if (status.lost > 0) theme.text_warn else theme.text_dim);
    if (status.recording) {
        var clock_buf: [16]u8 = undefined;
        var rec_buf: [32]u8 = undefined;
        const rec_text = i18n.fmt(&rec_buf, .readout_rec, .{ .clock = control.fmtClock(&clock_buf, status.rec_seconds) });
        _ = batch.label(x - batch.font.width(rec_text) - 14, y, rec_text, theme.text_rec);
    }
}

/// The key summary (`key_help`) over the middle of the display: the display's keys on the
/// left, the spike-tile window's on the right, each a column of keys and a column of what
/// they do, in the fixed-width font (the ordinary one if there is none). Where the display
/// is too small, it is cut at the right and bottom edges.
fn helpPanel(o: *Output, width: u32, height: u32) void {
    const batch = o.batch;
    const f = batch.font;
    const line_h = o.line_h;
    const pad: f32 = 12;
    const title = i18n.text(.help_title);
    const headings = [2][]const u8{ i18n.text(.help_heading_display), i18n.text(.help_heading_tiles) };
    // Per column: how wide its keys and its descriptions are, and how many lines.
    var key_w: [2]f32 = @splat(0);
    var what_w: [2]f32 = @splat(0);
    var lines: [2]usize = @splat(0);
    for (key_help) |k| {
        const c = @backingInt(k.window);
        key_w[c] = @max(key_w[c], helpWidth(f, i18n.textOf(k.key)));
        what_w[c] = @max(what_w[c], helpWidth(f, i18n.textOf(k.what)), helpWidth(f, headings[c]));
        lines[c] += 1;
    }
    const sp = f.widthMono("  ");
    const col_w = [2]f32{ key_w[0] + sp + what_w[0], key_w[1] + sp + what_w[1] };
    const gap = f.widthMono("    ");
    const w = @max(col_w[0] + gap + col_w[1], helpWidth(f, title)) + 2 * pad;
    const h = @as(f32, @floatFromInt(@max(lines[0], lines[1]) + 3)) * line_h + 2 * pad;
    const x0 = @round(@max(0, (@as(f32, @floatFromInt(width)) - w) / 2));
    const y0 = @round(@max(0, (@as(f32, @floatFromInt(height)) - h) / 2));
    batch.rect(x0, y0, w, h, theme.help_backing);
    _ = helpText(batch, x0 + pad, y0 + pad, title, theme.help_title);
    const col_x = [2]f32{ x0 + pad, x0 + pad + col_w[0] + gap };
    var row: [2]usize = @splat(0);
    for (headings, col_x) |heading, x| _ = helpText(batch, x, y0 + pad + 2 * line_h, heading, theme.help_title);
    for (key_help) |k| {
        const c = @backingInt(k.window);
        const y = y0 + pad + @as(f32, @floatFromInt(row[c] + 3)) * line_h;
        _ = helpText(batch, col_x[c], y, i18n.textOf(k.key), theme.help_key);
        _ = helpText(batch, col_x[c] + key_w[c] + sp, y, i18n.textOf(k.what), theme.help_text);
        row[c] += 1;
    }
}

/// The key summary's text: ASCII in the fixed-width font, so English's columns line up;
/// any other in the ordinary font, which shapes and has every script.
fn helpText(batch: *font.Batch, x: f32, y: f32, string: []const u8, colour: font.Colour) f32 {
    return if (isAscii(string)) batch.textMono(x, y, string, colour) else batch.text(x, y, string, colour);
}

fn helpWidth(f: *const font.Font, string: []const u8) f32 {
    return if (isAscii(string)) f.widthMono(string) else f.width(string);
}

fn isAscii(string: []const u8) bool {
    for (string) |c| if (c >= 0x80) return false;
    return true;
}

/// A bar along the top of the panel that input goes to.
fn targetBar(o: *Output, r: panels_mod.Rect) void {
    o.fills[o.nf] = .{ .rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = 3 }, .colour = theme.target_bar };
    o.nf += 1;
}

/// The panels for this run: from the config, or one per headstage.
pub fn makeDisplay(args: Args, layout: *const dimna.types.Layout) ?Display {
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
        var f = font.Font.init(gpa, family, args.font_px) catch |e| {
            log.warn("no font '{s}' ({t}): the display has no text", .{ args.font, e });
            return;
        };
        // The key summary's fixed-width glyphs, in the same atlas (before it is uploaded).
        f.addMono("monospace") catch |e| log.warn("no fixed-width font ({t}): the key summary uses '{s}'", .{ e, args.font });
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
// DIMNA_DISPLAY_FRAME_OUT to a path to write what this run produced there.

const testing = std.testing;

var frame_atlas: [1]u8 = .{0};

/// The hand-made font (as control.zig's test has it); a line height of 0 is a display
/// without a font. With `mono`, fixed-width glyphs too: 10 pixels wide, at atlas x 8 +
/// `frame_mono_at` + (code point - 32).
fn frameFont(line_height: f32, mono: bool) font.Font {
    var f: font.Font = .{ .atlas = &frame_atlas, .px = 14, .ascent = 12, .line_height = line_height };
    for (&f.glyphs, 0..) |*g, k| g.* = .{ .x = @intCast(8 + k), .y = 8, .w = 1, .h = 1, .top = 12, .advance = 8 };
    if (mono) {
        for (&f.mono, 0..) |*g, k| g.* = .{ .x = @intCast(8 + frame_mono_at + k), .y = 8, .w = 1, .h = 1, .top = 12, .advance = 10 };
        f.has_mono = true;
    }
    return f;
}

const frame_mono_at = 300;

/// The code point of glyph `k` of `frameFont` (as `font.Font.glyph` numbers them, then
/// the fixed-width ones from `frame_mono_at`).
fn frameCodepoint(k: usize) u21 {
    const extra = [_]u21{ 0x03C3, 0x2013, 0x2192, 0x266A };
    if (k >= frame_mono_at) return @intCast(32 + k - frame_mono_at);
    return if (k < 224) @intCast(32 + k) else extra[k - 224];
}

const frame_fs = 30000.0;
/// Columns of the history (as `feed` lays it out, more than the stream's channels).
const frame_nch = 62;
/// The newest sample of every state: 100.4115 s, 12345 samples into a pass of 1 s.
const frame_newest: i64 = 3_012_345;

/// Two headstages (A: 32 channels, B: 16), 6 AUX and 8 ADC channels.
fn frameLayout() dimna.types.Layout {
    var l: dimna.types.Layout = .{ .sample_rate = frame_fs, .hw_clock_hz = 50e6, .num_electrodes = 48, .num_aux = 6, .num_adc = 8 };
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
    const layout = frameLayout();
    p.short = panels_mod.shortSource(&layout, kind, first_ch, rows);
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
    /// The font has fixed-width glyphs.
    mono: bool = false,

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
    "dragging the focused row's line: drawn at the value dragged to",
    "the trigger row in focus: one line, dashed, in the threshold's colour",
    "review entered by Shift+wheel: three clicks back over Port A (5 s): 1.5 s behind",
    "the key summary (?), in the fixed-width font",
    "the key summary (?), without a fixed-width font",
    "review from the file: Port A from the overview's pixel columns, Port B's not there yet",
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
        25 => dragState(st),
        26 => triggerFocusState(st),
        27 => scrolledReviewState(st),
        28, 29 => helpState(st, k == 28),
        30 => {
            reviewState(st, 5);
            st.review.?.columns = 0b11;
            st.review.?.columns_ready = 0b01;
        },
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
    // The sweep panel: row 5 of 32, R = 21.875, centre 120.3125, -50 µV at 400 µV/row 0.125 R
    // below: 123.0469, the pixel row 123. The triggered panel keeps a header strip of the font's
    // 16 + 10 = 26 px: R = 674 / 32 = 21.0625, centre 26 + 5.5 R = 141.84, 0.125 R = 2.63
    // below: 144.47, the pixel row 144.
    st.reportAll(-50);
    st.feed(8, false);
}

/// As state 15 (the line on pixel row 103), the line taken hold of and dragged, the left
/// button still down, to pixel row 130: its centre 130.5 is 28.887 px = 1.2793 R below row
/// 5's centre at 101.6129, at 800 µV/row -1023.4 µV, fixed; the line drawn on 130.
fn dragState(st: *FrameState) void {
    focusLineState(st, 15);
    st.display.size = .{ st.width, st.height };
    st.display.pointAt(0.5, 103.5 / 700.0);
    _ = st.display.applyInput(.{ .clicks = 1, .left_down = true });
    st.display.pointAt(0.5, 130.5 / 700.0);
    _ = st.display.applyInput(.{ .left_down = true });
}

/// Port A triggered on row 4 (channel 4, which has spikes), and channel 4 in focus: the
/// trigger's dashed line alone, where the solid one would be: row 4's centre 4.5 R =
/// 98.4375, -50 µV at 400 µV/row 0.125 R below: 101.17, the pixel row 101.
fn triggerFocusState(st: *FrameState) void {
    var a = focusPanel();
    a.mode = .triggered;
    a.setTrigSource(.channel);
    a.trigger.row = 4;
    st.panels(&.{a});
    st.display.focus = 4;
    st.reportAll(-50);
    st.feed(2, true);
}

/// The panels of the review states, live, and then three clicks of Shift+wheel up over Port
/// A (time base 5 s: 0.5 s a click) through `reviewActions` and `ReviewSession` (frozen:
/// no recording): 45000 samples behind the newest.
fn scrolledReviewState(st: *FrameState) void {
    const session = @import("session.zig");
    reviewState(st, 5);
    var gpu: gpu_mod.Gpu = undefined;
    gpu.hist_cap = st.hist_cap;
    const layout = frameLayout();
    var review: session.ReviewSession = .{};
    review.queueInput(st.display.reviewActions(&.{ .scroll_y = -45, .shift = true }, frame_fs));
    _ = review.step(.{
        .gpa = testing.allocator,
        .gpu = &gpu,
        .layout = &layout,
        .set = &st.display.set,
        .target = st.display.target,
        .newest = frame_newest,
        .rec = null,
    });
    st.review = review.view(frame_newest, frame_fs);
}

/// The key summary over two panels, opened by `?` as typed (Shift+/), on a 1280 x 800
/// display; `mono`: the font has fixed-width glyphs.
fn helpState(st: *FrameState, mono: bool) void {
    st.panels(&.{
        framePanel("Port A", .electrode, 0, 32, .{ .x = 0, .y = 0, .w = 0.5, .h = 1 }),
        framePanel("Port B", .electrode, 32, 16, .{ .x = 0.5, .y = 0, .w = 0.5, .h = 1 }),
    });
    st.width = 1280;
    st.height = 800;
    st.mono = mono;
    var in: Input = .{ .num_keys = 1, .shift = true };
    in.keys[0] = .{ .char = '/' };
    setText(&in.text, &in.text_len, "?");
    st.display.helpKey(&in);
    st.notes.handle(&in, frame_newest, "");
    _ = st.display.applyInput(in);
}

/// Writes the batch's quads as rectangles and runs of text (glyphs on one row, of one
/// colour, 8 pixels apart; "mono": fixed-width glyphs, 10 apart). Returns how many of
/// each; with `w` null, only counts.
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
        const mono = v[0].uv[0] * font.atlas_size - 8 >= frame_mono_at;
        if (w) |out| try out.print("{s} {d} {d} {any} \"", .{ if (mono) "mono" else "text", x, y, col });
        var next_x = x;
        while (q < quads) : (q += 1) {
            const g = verts[q * 6 ..][0..6];
            const gu = g[0].uv[0] * font.atlas_size;
            if (gu < 8 or g[0].pos[0] != next_x or g[0].pos[1] != y or !std.mem.eql(u8, &g[0].colour, &col)) break;
            if ((gu - 8 >= frame_mono_at) != mono) break;
            var utf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(frameCodepoint(@intFromFloat(gu - 8)), &utf) catch unreachable;
            if (w) |out| try out.writeAll(utf[0..n]);
            next_x += if (mono) 10 else 8;
        }
        if (w) |out| try out.writeAll("\"\n");
    }
    return .{ .rects = rects, .runs = runs };
}

/// Runs `frame` on `st` and writes what it returned.
fn writeFrame(w: *std.Io.Writer, name: []const u8, st: *FrameState, gains: []f32, vertices: []font.Vertex) !void {
    const layout = frameLayout();
    const face = frameFont(if (st.no_text) 0 else 16, st.mono);
    var batch: font.Batch = .{ .font = &face, .vertices = vertices };
    var draws: [max_draws]gpu_mod.PanelDraw = undefined;
    var fills: [max_fills]gpu_mod.Fill = undefined;
    @memset(gains, 1);
    const surface: Surface = .{ .width = st.width, .height = st.height, .nch = frame_nch, .hist_cap = st.hist_cap, .dec_cap = 1 << 17, .row_gains = gains };
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
    if (std.c.getenv("DIMNA_DISPLAY_FRAME_OUT")) |path| {
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
    const surface: Surface = .{ .width = 1000, .height = 700, .nch = frame_nch, .hist_cap = 1 << 20, .dec_cap = 1 << 17, .row_gains = &gains };
    const params = traceParams(p, 0, r, panelTime(p, 0, frame_newest, null, frame_fs), surface);
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
        .{ .state = 22, .panel = 0, .row = 5, .uv = -50, .want = 144 },
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
        // And `frame` draws it there, across the panel (its rows: less a triggered panel's
        // header strip, which `frame` learns from the font).
        const quads = try thresholdRects(st, vertices);
        const r = p.bodyRect(p.pixelRect(st.width, st.height), st.display.line_h);
        const line = levelPixelY(p, r, c.row, c.uv).?;
        try testing.expectEqual(c.want, line);
        var found = false;
        for (quads.slice()) |q| found = found or std.meta.eql(q, .{ @floatFromInt(r.x), c.want, @floatFromInt(r.w), 1 });
        try testing.expect(found);
        // A flat trace at that value covers ±0.75 px about the shader's y (`half_px`): the
        // line's pixel centre is among those it lights.
        const y = shaderPixelY(p, r, c.row, c.uv);
        try testing.expect(@abs(line + 0.5 - y) <= 0.5 + 1e-3);
    }
}

test "script steps: press, move and release drag a line; n toggles" {
    const runScript = @import("script.zig").runScript;
    var d = lineDisplay();
    d.pointer_fy = 0;
    const script = "0:pointer=0.25,0.1764;0:press;1:move=0.25,0.2;2:release;3:pointer=0.25,0.0186;3:n";
    var pos: usize = 0;
    var t: f64 = 0;
    while (t < 4) : (t += 1) {
        var in: Input = .{};
        runScript(script, &pos, t, &in, &d);
        if (d.scripted_target) |s| d.target = s;
        _ = d.applyInput(in);
        switch (@as(u32, @intFromFloat(t))) {
            // 0.1764 x 700 = 123.5: on the focused row's line, pressed.
            0 => try testing.expect(d.drag != null and d.drag.?.ch == 5 and in.left_down and in.clicks == 1),
            // Held down without a step saying so; 0.2 x 700 = 140: channel 5 dragged there.
            1 => {
                try testing.expect(in.left_down and in.clicks == 0);
                const p = &d.set.items[0];
                try testing.expectEqual(140, levelPixelY(p, p.pixelRect(1000, 700), 5, d.thresholds.fixed_uv[5]).?);
            },
            2 => try testing.expect(d.drag == null and !in.left_down and !d.scripted_left),
            // Row 0 (13 px down): n fixes channel 0 where it was reported.
            else => try testing.expectEqual(-50, d.thresholds.fixed_uv[0]),
        }
    }
}

/// Input with the keys `keys` (characters, `\x1b` for Esc), typed text `text` and Shift
/// held or not, as the window gives it.
fn typedInput(keys: []const u8, text: []const u8, shift: bool) Input {
    var in: Input = .{ .shift = shift, .num_keys = keys.len };
    for (keys, 0..) |c, k| in.keys[k] = if (c == 0x1b) .{ .named = .escape } else .{ .char = c };
    setText(&in.text, &in.text_len, text);
    return in;
}

/// One turn of the display loop's key handling: the key summary, the notes, the display.
/// True means quit.
fn helpTurn(d: *Display, notes: *notes_mod.Notes, given: Input) bool {
    var in = given;
    if (!notes.editing) d.helpKey(&in);
    notes.handle(&in, 1000, "");
    return d.applyInput(in);
}

test "?: shows and hides the key summary and starts no note; / alone still does; Esc hides it, else quits" {
    var d = clickDisplay(5);
    var notes: notes_mod.Notes = .{};
    // Shift+/ typing "?": shown, no note.
    try testing.expect(!helpTurn(&d, &notes, typedInput("/", "?", true)));
    try testing.expect(d.help and !notes.editing);
    // While it is shown, other keys do what they do: m to sweep.
    _ = helpTurn(&d, &notes, typedInput("m", "m", false));
    try testing.expectEqual(.sweep, d.set.items[0].mode);
    // ? again: hidden.
    _ = helpTurn(&d, &notes, typedInput("/", "?", true));
    try testing.expect(!d.help and !notes.editing);
    // Shown again, then Esc: hidden, and no quitting.
    _ = helpTurn(&d, &notes, typedInput("/", "?", true));
    try testing.expect(!helpTurn(&d, &notes, typedInput("\x1b", "", false)));
    try testing.expect(!d.help);
    // Esc without it: quit. q quits with it shown, too.
    try testing.expect(helpTurn(&d, &notes, typedInput("\x1b", "", false)));
    _ = helpTurn(&d, &notes, typedInput("/", "?", true));
    try testing.expect(helpTurn(&d, &notes, typedInput("q", "q", false)) and d.help);
    d.help = false;
    // Shift is read from the text, not the modifier state: "?" typed with Shift already
    // let go is ?, and "/" typed with Shift still held (as reported) is /.
    _ = helpTurn(&d, &notes, typedInput("/", "?", false));
    try testing.expect(d.help and !notes.editing);
    d.help = false;
    _ = helpTurn(&d, &notes, typedInput("/", "/", true));
    try testing.expect(!d.help and notes.editing);
    // While a note is open, ? is part of it.
    _ = helpTurn(&d, &notes, typedInput("/", "?", true));
    try testing.expect(!d.help);
    try testing.expectEqualStrings("?", notes.draft.text());
    notes.editing = false;
    // / then ? in one turn: a note for the /, the summary for the ?.
    _ = helpTurn(&d, &notes, typedInput("//", "/?", true));
    try testing.expect(d.help and notes.editing);
    notes.editing = false;
    d.help = false;
    // Without a keymap there is no text: / with Shift held is ?.
    _ = helpTurn(&d, &notes, typedInput("/", "", true));
    try testing.expect(d.help and !notes.editing);
    _ = helpTurn(&d, &notes, typedInput("/", "", false));
    try testing.expect(d.help and notes.editing);
}

test "the key summary agrees with the usage text on the display's keys" {
    const usage = @import("args.zig").usage;
    const start = std.mem.indexOf(u8, usage, "\nOn the display").?;
    const end = std.mem.indexOfPos(u8, usage, start + 1, "\n\n") orelse usage.len;
    var lines = std.mem.splitScalar(u8, usage[start + 1 .. end], '\n');
    _ = lines.next();
    // Each line that names a key: two spaces, then the key up to a run of two spaces.
    var k: usize = 0;
    while (lines.next()) |line| {
        if (line.len < 3 or line[2] == ' ') continue;
        const key = line[2 .. std.mem.indexOfPos(u8, line, 2, "  ") orelse line.len];
        while (k < key_help.len and key_help[k].window != .display) k += 1;
        if (k == key_help.len or !std.mem.eql(u8, i18n.textOfIn(.en, key_help[k].key), key)) {
            const has = if (k < key_help.len) i18n.textOfIn(.en, key_help[k].key) else "nothing";
            std.debug.print("usage lists '{s}' where the key summary has '{s}'\n", .{ key, has });
            return error.TestUnexpectedResult;
        }
        k += 1;
    }
    while (k < key_help.len and key_help[k].window != .display) k += 1;
    if (k < key_help.len) {
        std.debug.print("the key summary has '{s}', the usage text does not\n", .{i18n.textOfIn(.en, key_help[k].key)});
        return error.TestUnexpectedResult;
    }
    // The English keys are ASCII, so their column lines up in the fixed-width font.
    for (key_help) |h| {
        for (i18n.textOfIn(.en, h.key)) |c| try testing.expect(c >= 0x20 and c < 0x7f);
    }
}

test "script steps: swheel, awheel and l" {
    const runScript = @import("script.zig").runScript;
    var d = clickDisplay(5);
    var pos: usize = 0;
    var in: Input = .{};
    runScript("0:swheel=-15", &pos, 0, &in, &d);
    try testing.expect(in.shift and !in.alt and in.scroll_y == -15);
    try testing.expectEqual(-6000, d.reviewActions(&in, frame_fs).scroll);
    pos = 0;
    in = .{};
    runScript("0:awheel=30;0:l", &pos, 0, &in, &d);
    try testing.expect(in.alt and !in.shift and in.scroll_y == 30);
    const acts = d.reviewActions(&in, frame_fs);
    try testing.expect(acts.len == 1 and acts.items[0] == .live and acts.scroll == 0);
    // ? is Shift+/ typing "?": the key summary.
    pos = 0;
    in = .{};
    runScript("0:?", &pos, 0, &in, &d);
    try testing.expect(in.shift and in.keys[0].is('/') and std.mem.eql(u8, in.text[0..in.text_len], "?"));
    d.helpKey(&in);
    try testing.expect(d.help and in.num_keys == 0);
}

test "the trigger's dashed line is on the pixel row where the shader draws its level" {
    const st = try testing.allocator.create(FrameState);
    defer testing.allocator.destroy(st);
    // The slope state: Port A's level fixed at -62 µV on row 4; Port B's latched from the
    // noise on row 2 (where the dashes used to be put one pixel row low, at 114).
    frameState(st, 3);
    for ([_][3]f32{ .{ 0, 4, 81 }, .{ 1, 2, 113 } }) |c| {
        const p = &st.display.set.items[@intFromFloat(c[0])];
        const row: usize = @intFromFloat(c[1]);
        const r = p.pixelRect(st.width, st.height);
        const uv = st.display.thresholds.fixed_uv[p.first_ch + row];
        const lines = st.display.panelLines(p, r);
        try testing.expect(lines.len == 1 and lines.items[0].dashed and lines.items[0].y == c[2]);
        try testing.expectEqual(c[2], levelPixelY(p, r, row, uv).?);
        try testing.expect(@abs(c[2] + 0.5 - shaderPixelY(p, r, row, uv)) <= 0.5 + 1e-3);
    }
}

test "a dragged line is drawn where the shader draws a sample of the value it set" {
    const st = try testing.allocator.create(FrameState);
    defer testing.allocator.destroy(st);
    const vertices = try testing.allocator.alloc(font.Vertex, max_text_vertices);
    defer testing.allocator.free(vertices);
    frameState(st, 25);
    const p = &st.display.set.items[0];
    const r = p.pixelRect(st.width, st.height);
    const uv = st.display.thresholds.fixed_uv[5];
    try testing.expectApproxEqAbs(-1023.4, uv, 0.05);
    try testing.expectEqual(130, levelPixelY(p, r, 5, uv).?);
    try testing.expect(@abs(130 + 0.5 - shaderPixelY(p, r, 5, uv)) <= 0.5 + 1e-3);
    const quads = try thresholdRects(st, vertices);
    try testing.expectEqual(1, quads.len);
    try testing.expectEqual([4]f32{ 0, 130, 1000, 1 }, quads.items[0]);
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
fn thresholdRects(st: *FrameState, vertices: []font.Vertex) !ThresholdRects {
    const layout = frameLayout();
    const face = frameFont(16, false);
    var batch: font.Batch = .{ .font = &face, .vertices = vertices };
    var draws: [max_draws]gpu_mod.PanelDraw = undefined;
    var fills: [max_fills]gpu_mod.Fill = undefined;
    var gains: [gpu_mod.max_rows * gpu_mod.max_gain_panels]f32 = undefined;
    const surface: Surface = .{ .width = st.width, .height = st.height, .nch = frame_nch, .hist_cap = st.hist_cap, .dec_cap = 1 << 17, .row_gains = &gains };
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

test "latching: only a panel in triggered mode latches; a trigger channel can be returned to the noise" {
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
    // Back to the noise: allowed while triggered on (the control window's "follow", and
    // the tile window's request with 0), and so is any other channel.
    d.applyThreshold(.{ .follow = 3 });
    try testing.expect(!d.thresholds.isFixed(3));
    d.setThreshold(3, -42);
    d.applyThreshold(.{ .set = .{ .channel = 3, .uv = 0 } });
    try testing.expect(!d.thresholds.isFixed(3));
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

/// The `n` key, over whatever row the pointer is on.
fn keyInput(c: u8) Input {
    var in: Input = .{ .num_keys = 1 };
    in.keys[0] = .{ .char = c };
    return in;
}

test "latching once: a trigger channel put back to the noise stays there until triggering starts anew" {
    var d = triggeredDisplay(7);
    for (0..32) |ch| d.reported.uv[ch] = -40 - @as(f32, @floatFromInt(ch));
    d.reported.len = 32;
    _ = d.applyInput(keyInput('s'));
    try testing.expectEqual(-47, d.thresholds.fixed_uv[7]);
    // n over row 7: back to the noise. Neither input, nor blocks with reports, nor the
    // slope trigger's own second of signal latch it again.
    _ = d.applyInput(keyInput('n'));
    try testing.expect(!d.thresholds.isFixed(7));
    _ = d.applyInput(.{});
    _ = feedNoise(&d, 0, 1.5);
    try testing.expect(!d.thresholds.isFixed(7));
    // It triggers at sigmas x its own sigma, continuously.
    try testing.expect(d.slopes[0].?.settings.auto and d.slopes[0].?.settings.auto_sigmas == 4.5);
    // Starting anew (t out of triggered mode and back): latched again where reported.
    _ = d.applyInput(keyInput('t'));
    try testing.expect(!d.thresholds.isFixed(7));
    d.reported.uv[7] = -52;
    _ = d.applyInput(keyInput('t'));
    try testing.expectEqual(-52, d.thresholds.fixed_uv[7]);
    // The control window's "follow" the same: it stays with the noise.
    d.applyThreshold(.{ .follow = 7 });
    _ = feedNoise(&d, 45000, 0.1);
    try testing.expect(!d.thresholds.isFixed(7));
    // A config that triggers on a channel from the start owes it a latch: paid with the
    // first block that comes with a report.
    var e = triggeredDisplay(0);
    e.set.items[0].setTrigSource(.channel);
    e.set.items[0].trigger.row = 3;
    _ = feedNoise(&e, 0, 0.01);
    try testing.expect(!e.thresholds.isFixed(3) and e.owes_latch[0]);
    e.reported.uv[3] = -61;
    e.reported.len = 32;
    _ = feedNoise(&e, 300, 0.01);
    try testing.expectEqual(-61, e.thresholds.fixed_uv[3]);
    try testing.expect(!e.owes_latch[0]);
    // A channel already fixed when the panel begins owes nothing.
    var f = triggeredDisplay(0);
    f.thresholds.set(3, 75);
    f.applyPanelEdit(0, .{ .trig_source = .channel });
    f.applyPanelEdit(0, .{ .trig_row = 3 });
    try testing.expect(!f.owes_latch[0]);
    f.applyThreshold(.{ .follow = 3 });
    f.reported.uv[3] = -30;
    f.reported.len = 32;
    _ = feedNoise(&f, 0, 0.01);
    try testing.expect(!f.thresholds.isFixed(3));
}

test "n: fixed -> following the noise -> fixed at its present value; nothing without a value or off an electrode row" {
    var d = clickDisplay(5);
    d.reported.uv[5] = -50;
    d.reported.len = 6;
    d.setThreshold(5, 80);
    _ = d.applyInput(keyInput('n'));
    try testing.expect(!d.thresholds.isFixed(5));
    _ = d.applyInput(keyInput('n'));
    try testing.expectEqual(-50, d.thresholds.fixed_uv[5]);
    _ = d.applyInput(keyInput('n'));
    try testing.expect(!d.thresholds.isFixed(5));
    // Row 9: no value known; nothing happens.
    d.pointer_fy = 9.5 / 32.0;
    _ = d.applyInput(keyInput('n'));
    try testing.expect(!d.thresholds.isFixed(9));
    // Over AUX: nothing (channel 48 + row is not an electrode).
    d.target = 1;
    d.setThreshold(5, -70);
    d.pointer_fy = 5.5 / 32.0;
    _ = d.applyInput(keyInput('n'));
    try testing.expectEqual(-70, d.thresholds.fixed_uv[5]);
}

test "the value at a pixel row and the pixel row of a value round-trip" {
    // Rows of every height the stored states have, with hidden rows and own scales.
    var a = framePanel("Port A", .electrode, 0, 32, .{ .x = 0, .y = 0.25, .w = 0.5, .h = 0.7 });
    a.per_row.hidden.set(2, true);
    a.per_row.gain[5] = 2;
    a.per_row.gain[6] = 0.37;
    a.scale = 137;
    for ([_][2]u32{ .{ 1000, 700 }, .{ 320, 180 }, .{ 1920, 1080 }, .{ 777, 333 } }) |size| {
        const r = a.pixelRect(size[0], size[1]);
        for ([_]usize{ 0, 5, 6, 31 }) |row| {
            const top = levelPixelY(&a, r, row, a.rowScale(row) * 1.5).?;
            const bottom = levelPixelY(&a, r, row, -a.rowScale(row) * 1.5).?;
            // Every pixel row within ±1.5 rows: its value is drawn on that row again.
            var y = top;
            while (y <= bottom) : (y += 1) {
                const v = levelAtPixelY(&a, r, row, y).?;
                try testing.expectEqual(y, levelPixelY(&a, r, row, v).?);
            }
            // And a value's pixel row gives back that value to within half a pixel.
            var v: f64 = -1.4 * a.rowScale(row);
            while (v < 1.4 * a.rowScale(row)) : (v += 0.0371 * a.rowScale(row)) {
                const back = levelAtPixelY(&a, r, row, levelPixelY(&a, r, row, v).?).?;
                const half_px = 0.5 * a.rowScale(row) / (@as(f64, @floatFromInt(r.h)) / 31.0);
                try testing.expect(@abs(back - v) <= half_px + 1e-9);
            }
            // Beyond ±1.5 rows: the value at the clamp.
            try testing.expectEqual(1.5 * a.rowScale(row), levelAtPixelY(&a, r, row, top - 30).?);
        }
        // A hidden row has neither.
        try testing.expectEqual(null, levelAtPixelY(&a, r, 2, 100));
    }
}

/// Port A (left half, 1000 x 700 drawn) filtered 300-6000 Hz, triggered on row 9, channel
/// 5 in focus, every channel reported at -50 µV: the focus line on pixel row 123 (as in
/// the stored state 22), the trigger's at 210 (row 9's centre 9.5 R = 207.8125, -50 µV at
/// 400 µV/row 0.125 R below: 210.547).
fn lineDisplay() Display {
    var d = clickDisplay(0);
    const p = &d.set.items[0];
    p.filter.on = true;
    p.mode = .triggered;
    p.setTrigSource(.channel);
    p.trigger.row = 9;
    d.focus = 5;
    for (0..32) |ch| d.reported.uv[ch] = -50;
    d.reported.len = 32;
    d.size = .{ 1000, 700 };
    d.updateLatches();
    return d;
}

/// The pointer at pixel (x, y) of the 1000 x 700 display (the panel under it found as
/// `pointAt` would).
fn pointerAt(d: *Display, x: f64, y: f64) void {
    d.pointAt(x / 1000, (y + 0.5) / 700);
}

test "a threshold line is taken hold of within 4 px, inside its panel, only where one is drawn" {
    var d = lineDisplay();
    const r = d.set.items[0].pixelRect(1000, 700);
    const lines = d.panelLines(&d.set.items[0], r);
    try testing.expectEqual(2, lines.len);
    try testing.expect(lines.items[0].dashed and lines.items[0].ch == 9 and lines.items[0].y == 210);
    try testing.expect(!lines.items[1].dashed and lines.items[1].ch == 5 and lines.items[1].y == 123);
    // Over each line and up to 4 pixel rows from it: a hand; 5 away: not.
    for ([_]f32{ 123, 210 }) |at| {
        for ([_]f32{ -5, -4, 0, 4, 5 }) |off| {
            pointerAt(&d, 250, at + off);
            _ = d.applyInput(.{});
            try testing.expectEqual(if (@abs(off) <= 4) Cursor.grab else Cursor.default, d.cursor);
        }
    }
    // The pointer outside the panel (over AUX, at the same height), with input still
    // going to Port A: nothing.
    d.pointer_fx = 0.6;
    d.pointer_fy = 123.5 / 700.0;
    _ = d.applyInput(.{});
    try testing.expectEqual(Cursor.default, d.cursor);
    // No line where none is drawn: the focused row raw ("thr"), the trigger's level not
    // known (no report, following the noise).
    d = lineDisplay();
    d.set.items[0].per_row.raw.set(5, true);
    d.thresholds.follow(9);
    d.reported.len = 0;
    for ([_]f32{ 123, 210 }) |at| {
        pointerAt(&d, 250, at);
        _ = d.applyInput(.{});
        try testing.expectEqual(Cursor.default, d.cursor);
    }
    // Before anything is drawn the display has no size: nothing to take hold of.
    d = lineDisplay();
    d.size = .{ 0, 0 };
    pointerAt(&d, 250, 123);
    _ = d.applyInput(.{});
    try testing.expectEqual(Cursor.default, d.cursor);
}

test "dragging a threshold line: fixed at the value under the pointer, the sign by the side; no focus, no trigger moved" {
    var d = lineDisplay();
    const p = &d.set.items[0];
    const r = p.pixelRect(1000, 700);
    // Press on the trigger's line (channel 9): the line's, not a click on row 9 (which
    // would focus channel 9).
    pointerAt(&d, 250, 211);
    _ = d.applyInput(.{ .clicks = 1, .left_down = true });
    try testing.expectEqual(Cursor.grabbing, d.cursor);
    try testing.expectEqual(5, d.focus.?);
    try testing.expectEqual(-50, d.thresholds.fixed_uv[9]);
    // Not moved off the pixel row yet: unchanged.
    _ = d.applyInput(.{ .left_down = true });
    try testing.expectEqual(-50, d.thresholds.fixed_uv[9]);
    // Down to 230: below the centre, falling, under the pointer.
    pointerAt(&d, 250, 230);
    _ = d.applyInput(.{ .left_down = true });
    try testing.expectApproxEqAbs(@as(f32, (207.8125 - 230.5) / 21.875 * 400), d.thresholds.fixed_uv[9], 1e-3);
    try testing.expectEqual(230, levelPixelY(p, r, 9, d.thresholds.fixed_uv[9]).?);
    // Up across the centre to 205 (over row 9, with the pointer off the panel's other
    // line): rising.
    pointerAt(&d, 250, 205);
    _ = d.applyInput(.{ .left_down = true });
    try testing.expect(d.thresholds.fixed_uv[9] > 0);
    try testing.expectEqual(205, levelPixelY(p, r, 9, d.thresholds.fixed_uv[9]).?);
    // Through the focused row's line and beyond the panel's other rows: still channel 9's
    // drag, clamped at 1.5 rows.
    pointerAt(&d, 600, 120);
    _ = d.applyInput(.{ .left_down = true, .clicks = 1 });
    try testing.expectEqual(600, d.thresholds.fixed_uv[9]);
    try testing.expectEqual(0, d.target);
    try testing.expect(d.focus.? == 5 and p.trigger.row == 9);
    // Released: the drag ends, the threshold stays; the line is at the clamp (175), and the
    // pointer over it is a hand.
    _ = d.applyInput(.{});
    try testing.expectEqual(null, d.drag);
    try testing.expectEqual(600, d.thresholds.fixed_uv[9]);
    pointerAt(&d, 250, 175);
    _ = d.applyInput(.{});
    try testing.expectEqual(Cursor.grab, d.cursor);
    // The focused row's line: a press there does not move the trigger to row 5.
    pointerAt(&d, 250, 123);
    _ = d.applyInput(.{ .clicks = 1, .left_down = true });
    pointerAt(&d, 250, 130);
    _ = d.applyInput(.{ .left_down = true });
    _ = d.applyInput(.{});
    try testing.expectEqual(9, p.trigger.row);
    try testing.expectEqual(130, levelPixelY(p, r, 5, d.thresholds.fixed_uv[5]).?);
    // Pressed and let go within one turn on a line: nothing at all.
    const was = d.thresholds.fixed_uv[5];
    pointerAt(&d, 250, 132);
    _ = d.applyInput(.{ .clicks = 1 });
    try testing.expect(d.drag == null and d.thresholds.fixed_uv[5] == was and p.trigger.row == 9 and d.focus.? == 5);
    // A click elsewhere does what it did: focus row 12, and the trigger moves there.
    pointerAt(&d, 250, 12.5 * 21.875);
    _ = d.applyInput(.{ .clicks = 1 });
    try testing.expect(d.focus.? == 12 and p.trigger.row == 12);
    // Clamped as Thresholds.set clamps: at 50 µV/row, pixel row 119 (just above row 5's
    // centre at 120.3125) is 1.86 µV, kept at 5 µV, rising; 120 just below, -5 µV.
    d = lineDisplay();
    d.set.items[0].scale = 50;
    pointerAt(&d, 250, levelPixelY(&d.set.items[0], r, 5, -50).?);
    _ = d.applyInput(.{ .clicks = 1, .left_down = true });
    pointerAt(&d, 250, 119);
    _ = d.applyInput(.{ .left_down = true });
    try testing.expectEqual(5, d.thresholds.fixed_uv[5]);
    pointerAt(&d, 250, 120);
    _ = d.applyInput(.{ .left_down = true });
    try testing.expectEqual(-5, d.thresholds.fixed_uv[5]);
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

test "the thresholds are saved with the view; a change of them is something to save" {
    const session = @import("session.zig");
    const files = @import("files.zig");
    const gpa = testing.allocator;
    var d = clickDisplay(0);
    const tiles: dimna.tile_view.TileView = .{};
    const layout = frameLayout();
    const view: session.ViewFile.View = .{ .set = &d.set, .tiles = &tiles, .thresholds = &d.thresholds, .layout = &layout };
    var view_file = try session.ViewFile.init(gpa, view);
    defer view_file.deinit(gpa);
    try testing.expect(!view_file.unsaved(view));
    d.applyThreshold(.{ .sigmas = true });
    try testing.expect(view_file.unsaved(view));
    d.applyThreshold(.{ .sigmas = false });
    try testing.expect(!view_file.unsaved(view));
    d.setThreshold(3, -61.25);
    d.setThreshold(47, 120);
    try testing.expect(view_file.unsaved(view));
    // What is written: the [thresholds] table for the 48 electrodes, which reads back the
    // same, after the panels' views (which read as they did).
    const buf = try gpa.alloc(u8, 96 * 1024);
    defer gpa.free(buf);
    const text = files.renderViews(buf, &d.set, &tiles, &d.thresholds, layout.num_electrodes).?;
    try testing.expect(std.mem.indexOf(u8, text, "\n[thresholds]\nsigmas = 4.5\nfixed_uv = [0, 0, 0, -61.25, 0,") != null);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const doc = try dimna.toml.parse(arena_state.allocator(), text, null);
    try testing.expect(dimna.thresholds.Thresholds.read(doc).eql(&d.thresholds));
    var set = d.set;
    var diag: panels_mod.Diagnostics = .{};
    try testing.expectEqual(2, try panels_mod.applyViews(&set, doc, &diag));
    try testing.expect(!diag.retired);
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

test "the wheel: plain the Y scale, Alt the time base, Shift and sideways move through time" {
    var d = clickDisplay(5);
    const p = &d.set.items[0];
    const grow = @exp(15 * 0.0093);
    // Plain: the scale; nothing for review.
    _ = d.applyInput(.{ .scroll_y = 15 });
    try testing.expectApproxEqRel(400 * grow, p.scale, 1e-9);
    try testing.expectEqual(2, p.span_s);
    try testing.expectEqual(0, d.reviewScroll(&.{ .scroll_y = 15 }, frame_fs));
    // Alt: the time base, either axis; not the scale, not review.
    _ = d.applyInput(.{ .scroll_y = 15, .alt = true });
    try testing.expectApproxEqRel(2 * grow, p.span_s, 1e-9);
    _ = d.applyInput(.{ .scroll_x = -15, .alt = true });
    try testing.expectApproxEqRel(2, p.span_s, 1e-9);
    try testing.expectApproxEqRel(400 * grow, p.scale, 1e-9);
    try testing.expectEqual(0, d.reviewScroll(&.{ .scroll_y = 15, .alt = true }, frame_fs));
    // In triggered mode: the window around the trigger.
    p.mode = .triggered;
    const pre = p.trigger.pre_ms;
    _ = d.applyInput(.{ .scroll_y = -15, .alt = true });
    try testing.expectApproxEqRel(pre / grow, p.trigger.pre_ms, 1e-9);
    p.mode = .scroll;
    // Shift: neither the scale nor the time base, but a tenth of the 2 s time base per
    // click: 6000 samples, back for wheel up; proportionally for less.
    _ = d.applyInput(.{ .scroll_y = -15, .shift = true });
    try testing.expectApproxEqRel(400 * grow, p.scale, 1e-9);
    try testing.expectApproxEqRel(2, p.span_s, 1e-9);
    try testing.expectEqual(-6000, d.reviewScroll(&.{ .scroll_y = -15, .shift = true }, frame_fs));
    try testing.expectEqual(12000, d.reviewScroll(&.{ .scroll_y = 30, .shift = true }, frame_fs));
    try testing.expectEqual(-1000, d.reviewScroll(&.{ .scroll_x = -2.5, .shift = true }, frame_fs));
    // Sideways, mostly: the same, and no scale; mostly vertical: the scale, no review.
    try testing.expectEqual(-3000, d.reviewScroll(&.{ .scroll_x = -7.5, .scroll_y = 1 }, frame_fs));
    _ = d.applyInput(.{ .scroll_x = -7.5, .scroll_y = 1 });
    try testing.expectApproxEqRel(400 * grow, p.scale, 1e-9);
    try testing.expectEqual(0, d.reviewScroll(&.{ .scroll_x = 1, .scroll_y = 7.5 }, frame_fs));
    // Over a triggered panel: the step of the longest panel that is not (here AUX, 2 s,
    // lengthened to 5 s).
    p.mode = .triggered;
    d.set.items[1].span_s = 5;
    try testing.expectEqual(-15000, d.reviewScroll(&.{ .scroll_y = -15, .shift = true }, frame_fs));
}

test "review by the wheel: back from live enters, forward to the live edge leaves; l and the keys" {
    const session = @import("session.zig");
    var d = clickDisplay(5);
    const layout = frameLayout();
    var gpu: gpu_mod.Gpu = undefined;
    gpu.hist_cap = 1 << 22;
    var review: session.ReviewSession = .{};
    defer review.deinit();
    var newest: i64 = 10_000_000;
    const Step = struct {
        fn run(r: *session.ReviewSession, dsp: *const Display, in: Input, g: *gpu_mod.Gpu, l: *const dimna.types.Layout, now: i64) void {
            r.queueInput(dsp.reviewActions(&in, frame_fs));
            const ctx: session.ReviewSession.Context = .{
                .gpa = testing.allocator,
                .gpu = g,
                .layout = l,
                .set = &dsp.set,
                .target = dsp.target,
                .newest = now,
                .rec = null,
            };
            _ = r.step(ctx);
        }
    };
    // Forward while live: nothing; not even entering and leaving again (which, while
    // recording, would open the review reader on the file): the position is untouched.
    Step.run(&review, &d, .{ .scroll_y = 15, .shift = true }, &gpu, &layout, newest);
    try testing.expect(!review.active);
    try testing.expectEqual(0, review.view_end);
    // Back two clicks: in review, 12000 samples (0.4 s) behind.
    Step.run(&review, &d, .{ .scroll_y = -30, .shift = true }, &gpu, &layout, newest);
    try testing.expect(review.active);
    try testing.expectEqual(newest - 12000, review.view(newest, frame_fs).?.end);
    // Sideways forward one click: 6000 behind; still in review.
    Step.run(&review, &d, .{ .scroll_x = 15 }, &gpu, &layout, newest);
    try testing.expectEqual(newest - 6000, review.view(newest, frame_fs).?.end);
    // Time passes (a frozen view stays where it is), forward a click: 3000 behind the
    // newest sample now, not yet live.
    newest += 3000;
    Step.run(&review, &d, .{ .scroll_y = 15, .shift = true }, &gpu, &layout, newest);
    try testing.expect(review.active);
    try testing.expectEqual(newest - 3000, review.view(newest, frame_fs).?.end);
    // Forward to the live edge (past it, here): out of review.
    Step.run(&review, &d, .{ .scroll_y = 15, .shift = true }, &gpu, &layout, newest);
    try testing.expect(!review.active);
    try testing.expectEqual(null, review.view(newest, frame_fs));
    // In again, then l: live.
    Step.run(&review, &d, .{ .scroll_y = -15, .shift = true }, &gpu, &layout, newest);
    try testing.expect(review.active);
    Step.run(&review, &d, keyInput('l'), &gpu, &layout, newest);
    try testing.expect(!review.active);
    // The keys as before: Space freezes, Left steps back, End is live.
    Step.run(&review, &d, keyInput(' '), &gpu, &layout, newest);
    try testing.expect(review.active);
    var in: Input = .{ .num_keys = 2 };
    in.keys[0] = .{ .named = .left };
    in.keys[1] = .{ .char = 'l' };
    const acts = d.reviewActions(&in, frame_fs);
    try testing.expectEqual(2, acts.len);
    try testing.expect(acts.items[0] == .back and acts.items[1] == .live);
    in.keys[0] = .{ .named = .end };
    in.num_keys = 1;
    Step.run(&review, &d, in, &gpu, &layout, newest);
    try testing.expect(!review.active);
    // Alt+wheel never moves through time.
    Step.run(&review, &d, .{ .scroll_y = -15, .alt = true }, &gpu, &layout, newest);
    try testing.expect(!review.active);
}

/// What `frame` writes for `st` (as the stored test does), for the tests to search.
fn frameText(gpa: std.mem.Allocator, st: *FrameState) ![]u8 {
    const vertices = try gpa.alloc(font.Vertex, max_text_vertices);
    defer gpa.free(vertices);
    const gains = try gpa.alloc(f32, gpu_mod.max_rows * gpu_mod.max_gain_panels);
    defer gpa.free(gains);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try writeFrame(&out.writer, "t", st, gains, vertices);
    return out.toOwnedSlice();
}

/// The numbers of the first line of `text` that starts with `prefix` and contains `needle`.
fn lineWith(text: []const u8, prefix: []const u8, needle: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, prefix) and std.mem.indexOf(u8, l, needle) != null) return l;
    }
    return null;
}

test "titles: the short label, the scale without a space, none when every row has its own" {
    var buf: [40]u8 = undefined;
    var p = framePanel("Port A", .electrode, 0, 32, .{ .x = 0, .y = 0, .w = 1, .h = 1 });
    try testing.expectEqualStrings("A", p.shortLabel());
    try testing.expectEqualStrings("   400µV/row", fmtTitleScale(&buf, &p));
    p.scale = 1500;
    try testing.expectEqualStrings("   1.50mV/row", fmtTitleScale(&buf, &p));
    p.scale = 400;
    var adc = framePanel("ADC", .adc, 54, 8, .{ .x = 0, .y = 0, .w = 1, .h = 1 });
    adc.scale = 2.5;
    try testing.expectEqualStrings("   2.5V/row", fmtTitleScale(&buf, &adc));
    adc.scale = 0.25;
    try testing.expectEqualStrings("   250mV/row", fmtTitleScale(&buf, &adc));
    const ttl = framePanel("TTL", .ttl, 0, 8, .{ .x = 0, .y = 0, .w = 1, .h = 1 });
    try testing.expectEqualStrings("", fmtTitleScale(&buf, &ttl));
    // Every shown row with a scale of its own: no scale in the title; one row on the
    // panel's: it is back.
    for (0..32) |r| p.per_row.gain[r] = 2;
    try testing.expectEqualStrings("", fmtTitleScale(&buf, &p));
    p.per_row.gain[7] = 1;
    try testing.expectEqualStrings("   400µV/row", fmtTitleScale(&buf, &p));
    p.per_row.hidden.set(7, true);
    try testing.expectEqualStrings("", fmtTitleScale(&buf, &p));
    // And in what is drawn.
    const st = try testing.allocator.create(FrameState);
    defer testing.allocator.destroy(st);
    frameState(st, 0);
    const text = try frameText(testing.allocator, st);
    defer testing.allocator.free(text);
    try testing.expect(lineWith(text, "text 8 6 ", "\"A   2.00 s   400µV/row   300-6000 Hz   CAR\"") != null);
    try testing.expect(lineWith(text, "text 508 6 ", "\"B   500 ms   400µV/row   CAR\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Port A") == null);
}

test "a triggered panel: the title ends 8 px from the right edge, without the window, above the rows" {
    const st = try testing.allocator.create(FrameState);
    defer testing.allocator.destroy(st);
    frameState(st, 2);
    const text = try frameText(testing.allocator, st);
    defer testing.allocator.free(text);
    // Panel 0 is 600 px wide, at x 0: the title's backing rectangle (3 px each side of the
    // text, which is 8 px per character) ends at 600 - 8 + 3.
    // Drawn in pieces (the filter text may be in another colour); the first starts the title.
    const title = lineWith(text, "text ", "\"A   TTL2   400µV/row\"").?;
    try testing.expect(std.mem.indexOf(u8, text, "-10.0/+40.0") == null);
    var it = std.mem.tokenizeScalar(u8, title, ' ');
    _ = it.next();
    const x = try std.fmt.parseFloat(f32, it.next().?);
    const chars = "A   TTL2   400µV/row   300-6000 Hz   6 sweeps".len - 1; // µ is two bytes
    try testing.expectEqual(600.0 - 8.0, x + 8.0 * @as(f32, @floatFromInt(chars)));
    // The rows are laid out below a strip of a line and 10 px: the draws start at y 26 and
    // end where the panel does; the title (y 6, one line of 16 px) ends above it.
    try testing.expect(lineWith(text, "draw 0 26 600 464 ", "first_ch=7 cols=600 rows=32") != null);
    try testing.expect(std.mem.indexOf(u8, text, "draw 0 0 600 490") == null);
    try testing.expect(6 + 16 < 26);
    // The panel's own row 0 label is drawn, which the title used to cover.
    try testing.expect(lineWith(text, "text 5 25 ", "\"1\"") != null);
}

test "a triggered panel: row 0's centre is the strip lower, and the trigger line starts there" {
    const st = try testing.allocator.create(FrameState);
    defer testing.allocator.destroy(st);
    const vertices = try testing.allocator.alloc(font.Vertex, max_text_vertices);
    defer testing.allocator.free(vertices);
    frameState(st, 2);
    // Scrolling: the unchanged geometry; row 0's centre at 0.5 R of 490/32.
    st.display.set.items[0].mode = .scroll;
    _ = try thresholdRects(st, vertices);
    const p = &st.display.set.items[0];
    const r = p.pixelRect(st.width, st.height);
    const scroll_y = levelPixelY(p, st.display.bodyRect(p), 0, 0).?;
    try testing.expectEqual(@as(f32, 7), scroll_y);
    p.mode = .triggered;
    _ = try thresholdRects(st, vertices);
    const body = st.display.bodyRect(p);
    try testing.expectEqual(r.y + 26, body.y);
    try testing.expectEqual(r.h - 26, body.h);
    // 26 + 0.5 * 464 / 32 = 33.25.
    try testing.expectEqual(@as(f32, 33), levelPixelY(p, body, 0, 0).?);
    // The pointer: the strip is no row; just below it row 0.
    st.display.pointAt(0.3, 25.0 / 700.0);
    try testing.expectEqual(null, st.display.rowAtPointer(p));
    st.display.pointAt(0.3, 27.0 / 700.0);
    try testing.expectEqual(0, st.display.rowAtPointer(p).?);
}

test "a triggered panel's level line is dragged where it is drawn, in the reduced rectangle" {
    const st = try testing.allocator.create(FrameState);
    defer testing.allocator.destroy(st);
    frameState(st, 26);
    const drawn = try frameText(testing.allocator, st);
    try testing.expect(lineWith(drawn, "rect 0 123 6 1 ", "") != null);
    defer testing.allocator.free(drawn);
    const d = &st.display;
    const p = &d.set.items[0];
    try testing.expect(p.mode == .triggered);
    const lines = d.panelLines(p, d.bodyRect(p));
    try testing.expectEqual(1, lines.len);
    const y = lines.items[0].y;
    // The drawn dashed line (from the stored test: pixel row 123) is the one input finds.
    try testing.expectEqual(@as(f32, 123), y);
    d.pointAt(0.5, (y + 0.5) / 700.0);
    const found = d.lineAtPointer(y + 0.5).?;
    try testing.expectEqual(y, found.y);
    // And the level of a row follows the pixel through levelAtPixelY in the same rectangle.
    const uv = levelAtPixelY(p, d.bodyRect(p), found.row, y).?;
    try testing.expectEqual(y, levelPixelY(p, d.bodyRect(p), found.row, uv).?);
}

test "time axis: the left label loses its unit, then goes to the left edge" {
    const face = frameFont(16, false);
    var buf: [24]u8 = undefined;
    // Room: 48 + 8 * 8 + 8 < 200.
    var l = axisLeft(&buf, &face, 4, 48, 200, 10);
    try testing.expectEqualStrings("-10.0 ms", l.text);
    try testing.expectEqual(48, l.x);
    // The trigger at 100: "-10.0 ms" would end at 120; "-10.0" ends at 96 + 8 = 104 > 100
    // too, but at 110 it fits.
    l = axisLeft(&buf, &face, 4, 48, 110, 10);
    try testing.expectEqualStrings("-10.0", l.text);
    try testing.expectEqual(48, l.x);
    // Not even that: at the left edge, still said.
    l = axisLeft(&buf, &face, 4, 48, 90, 10);
    try testing.expectEqualStrings("-10.0", l.text);
    try testing.expectEqual(4, l.x);
    // The window's own number, with its sign.
    l = axisLeft(&buf, &face, 4, 48, 300, 2.5);
    try testing.expectEqualStrings("-2.5 ms", l.text);
}

test "time axis in a frame: -10.0 ms, 0 and +40.0 ms as the title used to give them" {
    const st = try testing.allocator.create(FrameState);
    defer testing.allocator.destroy(st);
    frameState(st, 2);
    const text = try frameText(testing.allocator, st);
    defer testing.allocator.free(text);
    // Panel 0: 600 px, the trigger 120 px in; "-10.0 ms" does not fit before it, so "-10.0".
    try testing.expect(lineWith(text, "text 48 ", "\"-10.0\"") != null);
    try testing.expect(lineWith(text, "text 124 ", "\"0\"") != null);
    try testing.expect(lineWith(text, "text ", "\"+40.0 ms\"") != null);
    // Wider: the unit stays.
    st.display.set.items[0].place.w = 1;
    const wide = try frameText(testing.allocator, st);
    defer testing.allocator.free(wide);
    try testing.expect(lineWith(wide, "text 48 ", "\"-10.0 ms\"") != null);
}

fn adcLayoutState(st: *FrameState) void {
    st.* = .{};
    st.panels(&.{
        framePanel("Port A", .electrode, 0, 32, .{ .x = 0.5, .y = 0, .w = 0.5, .h = 0.75 }),
        framePanel("Port B", .electrode, 32, 16, .{ .x = 0, .y = 0, .w = 0.5, .h = 0.75 }),
        framePanel("ADC", .adc, 54, 8, .{ .x = 0, .y = 0.75, .w = 1, .h = 0.25 }),
    });
}

test "~ hides the ADC panel and the ports grow to the full height; again shows it" {
    const st = try testing.allocator.create(FrameState);
    defer testing.allocator.destroy(st);
    adcLayoutState(st);
    const shown = try frameText(testing.allocator, st);
    defer testing.allocator.free(shown);
    try testing.expect(std.mem.startsWith(u8, shown, "== t: 3 draws"));
    try testing.expect(lineWith(shown, "draw 0 525 1000 175 ", "first_ch=54") != null);
    // With a keymap: the key typed a ~ (Shift+`); the ` that went with it is not left for
    // the notes.
    var in = typedInput("`", "~", true);
    st.display.adcKey(&in);
    try testing.expectEqual(0, in.num_keys);
    try testing.expect(st.display.adc_hidden);
    const hidden = try frameText(testing.allocator, st);
    defer testing.allocator.free(hidden);
    try testing.expect(std.mem.startsWith(u8, hidden, "== t: 2 draws"));
    try testing.expect(lineWith(hidden, "draw 500 0 500 700 ", "first_ch=7 cols=500 rows=32") != null);
    try testing.expect(lineWith(hidden, "draw 0 0 500 700 ", "first_ch=39 cols=500 rows=16") != null);
    try testing.expect(lineWith(hidden, "draw ", "first_ch=54") == null);
    try testing.expect(lineWith(hidden, "text ", "\"ADC") == null);
    // Input no longer reaches the hidden panel.
    st.display.pointAt(0.5, 0.9);
    try testing.expect(st.display.target != 2);
    // Again: as it was, byte for byte.
    in = typedInput("`", "~", true);
    st.display.adcKey(&in);
    try testing.expect(!st.display.adc_hidden);
    const again = try frameText(testing.allocator, st);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(shown, again);
}

test "~: a plain ` is a note's key and does nothing here; without a keymap Shift+` is the ~; no ADC panel, nothing" {
    const st = try testing.allocator.create(FrameState);
    defer testing.allocator.destroy(st);
    adcLayoutState(st);
    var in = typedInput("`", "`", false);
    st.display.adcKey(&in);
    try testing.expectEqual(1, in.num_keys);
    try testing.expect(!st.display.adc_hidden);
    in = typedInput("`", "", true);
    st.display.adcKey(&in);
    try testing.expectEqual(0, in.num_keys);
    try testing.expect(st.display.adc_hidden);
    // The reset key puts the panel's settings back, not its place.
    st.display.target = 0;
    const keys = typedInput("r", "r", false);
    _ = st.display.applyInput(keys);
    try testing.expectEqual(@as(f64, 0.75 + 0.25), st.display.set.items[0].place.h);
    // A display without an ADC panel.
    var d = clickDisplay(5);
    in = typedInput("`", "~", true);
    d.adcKey(&in);
    try testing.expect(!d.adc_hidden);
}

test "~: a neighbour that does not span the ADC panel's edge keeps its size, in the frame" {
    const st = try testing.allocator.create(FrameState);
    defer testing.allocator.destroy(st);
    st.* = .{};
    st.panels(&.{
        framePanel("Port A", .electrode, 0, 32, .{ .x = 0, .y = 0, .w = 1, .h = 0.6 }),
        framePanel("ADC", .adc, 54, 8, .{ .x = 0, .y = 0.6, .w = 0.5, .h = 0.4 }),
        framePanel("Port B", .electrode, 32, 16, .{ .x = 0.5, .y = 0.6, .w = 0.5, .h = 0.4 }),
    });
    st.display.toggleAdc();
    const text = try frameText(testing.allocator, st);
    defer testing.allocator.free(text);
    // A spans more than the ADC panel's width: unchanged. B is beside it: grows left.
    try testing.expect(lineWith(text, "draw 0 0 1000 420 ", "first_ch=7") != null);
    try testing.expect(lineWith(text, "draw 0 420 1000 280 ", "first_ch=39") != null);
}

test "a notice is up from the first frame that asks for its seconds, then gone; an empty one never" {
    var n: Notice = .{};
    try testing.expect(!n.shown(5));
    n.set("colours taken from {s}", .{"x.jpg"}, "edit {s}", .{"~/c.toml"});
    try testing.expectEqualStrings("colours taken from x.jpg", n.line1());
    const t0: i128 = 1_000_000_000_000;
    try testing.expect(n.shown(t0));
    try testing.expect(n.shown(t0 + Notice.seconds * 1_000_000_000 - 1));
    try testing.expect(!n.shown(t0 + Notice.seconds * 1_000_000_000));
}

test "a triggered panel's filter text is in the warning colour unless it is the detector's band" {
    const st = try testing.allocator.create(FrameState);
    defer testing.allocator.destroy(st);
    frameState(st, 2);
    st.display.set.items[0].filter.low_hz = 100;
    st.display.set.items[0].filter.high_hz = 3000;
    const text = try frameText(testing.allocator, st);
    defer testing.allocator.free(text);
    try testing.expect(lineWith(text, "text ", "{ 255, 190, 90, 255 } \"100-3000 Hz\"") != null);
    // The detector's band: in the title's own colour.
    st.display.set.items[0].filter.low_hz = 300;
    st.display.set.items[0].filter.high_hz = 6000;
    const plain = try frameText(testing.allocator, st);
    defer testing.allocator.free(plain);
    try testing.expect(lineWith(plain, "text ", "{ 225, 230, 240, 255 } \"300-6000 Hz   6 sweeps\"") != null);
}

test "over the warning-coloured filter text, a tip says why; not when the pointer is elsewhere or gone" {
    const st = try testing.allocator.create(FrameState);
    defer testing.allocator.destroy(st);
    frameState(st, 2);
    st.display.set.items[0].filter.low_hz = 100;
    st.display.set.items[0].filter.high_hz = 3000;
    const first = try frameText(testing.allocator, st);
    defer testing.allocator.free(first);
    // Where the band text is: its line gives x and y.
    const line = lineWith(first, "text ", "\"100-3000 Hz\"").?;
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next();
    const bx = try std.fmt.parseFloat(f64, it.next().?);
    const by = try std.fmt.parseFloat(f64, it.next().?);
    const tip = "Spike detection and the slope trigger always use 300-6000 Hz,";
    st.display.pointer_fx = (bx + 10) / @as(f64, @floatFromInt(st.width));
    st.display.pointer_fy = (by + 5) / @as(f64, @floatFromInt(st.height));
    st.display.scripted_pointer = true;
    st.display.pointer_inside = true;
    const over = try frameText(testing.allocator, st);
    defer testing.allocator.free(over);
    try testing.expect(std.mem.indexOf(u8, over, tip) != null);
    try testing.expect(std.mem.indexOf(u8, over, "filter: 100-3000 Hz.") != null);
    // The pointer has left the window: no tip.
    st.display.pointer_inside = false;
    const gone = try frameText(testing.allocator, st);
    defer testing.allocator.free(gone);
    try testing.expect(std.mem.indexOf(u8, gone, tip) == null);
    // Over the title but not its filter text: no tip.
    st.display.pointer_inside = true;
    st.display.pointer_fx = (bx - 60) / @as(f64, @floatFromInt(st.width));
    const beside = try frameText(testing.allocator, st);
    defer testing.allocator.free(beside);
    try testing.expect(std.mem.indexOf(u8, beside, tip) == null);
}
