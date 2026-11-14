//! The panels of the neural display: rectangles of one fullscreen surface, each showing a run
//! of channels with its own time base and vertical scale. Laid out from the config file:
//!
//!   [[panel]]
//!   name = "Port B"
//!   source = "B1"                 # a headstage (A1..D2), "electrodes", "aux", "adc" or "ttl"
//!   rect = [0.0, 0.0, 0.5, 1.0]   # x, y, width, height as fractions of the display
//!   span_s = 2.0                  # optional: time across the panel
//!   scale = 400                   # optional: µV per row (V per row for aux and adc)
//!   mode = "sweep"                # optional: see `Mode`; a top-level `mode` sets all panels
//!   trigger = 2                   # optional, with mode = "triggered": the TTL input line
//!   trigger_channel = 5           # or: a slope trigger on this row of the panel (spikes),
//!                                 # at that channel's threshold; holdoff_ms = 0
//!   pre_ms = 10                   # optional: time shown before the trigger (slope: 1)
//!   post_ms = 40                  # optional: and after it (slope: 2)
//!   sweeps = 10                   # optional: how many sweeps are overlaid
//!   lines = [1, 2]                # optional, source "ttl": which input lines (default all 8)
//!   tint = 2                      # optional: shade the panel while this TTL line is high
//!   car = true                    # optional, electrodes: common average reference (below)
//!   car_ref = [1, 2, 3, 5]        # optional: the rows averaged (default: all)
//!   car_subtract = [1, 2, 3, 4]   # optional: the rows it is subtracted from (default: all)
//!   raw_rows = [9, 10, 11, 12]    # optional, with band: rows shown unfiltered all the same
//!   raw_scale = 2000              # optional: µV per row for those rows
//!   hide = [13, 14, 15, 16]       # optional: rows not shown
//!   band = [300, 6000]            # optional, electrodes: show band-passed, corners in Hz
//!                                 # (0 leaves a side out: [10, 0] is a 10 Hz high-pass)
//!
//! With no [[panel]] in the config there is one panel per headstage, side by side.
//!
//! TTL lines can be named, for the lanes' labels and the recording's meta.toml:
//!
//!   [ttl]
//!   line1 = "camera"
//!   line2 = "laser"

const std = @import("std");
const types = @import("types.zig");
const toml = @import("toml.zig");

pub const max_panels = 16;
/// Rows that can have a vertical scale of their own (see `Panel.row_gain`).
pub const max_rows = 256;
/// A TTL lane's low and high levels in the display's sample history are -/+ this.
pub const ttl_level = 1000.0;

/// `ttl`: the digital input lines as square-wave lanes, one row per line.
pub const Kind = enum { electrode, aux, adc, ttl };

/// A set of a panel's rows.
pub const RowSet = struct {
    bits: [max_rows / 64]u64 = @splat(0),

    pub fn has(self: *const RowSet, row: usize) bool {
        return row < max_rows and self.bits[row / 64] >> @intCast(row % 64) & 1 != 0;
    }
    pub fn set(self: *RowSet, row: usize, on: bool) void {
        if (row >= max_rows) return;
        const bit = @as(u64, 1) << @intCast(row % 64);
        if (on) self.bits[row / 64] |= bit else self.bits[row / 64] &= ~bit;
    }
    /// How many of the first `rows` rows are in the set.
    pub fn count(self: *const RowSet, rows: usize) usize {
        var n: usize = 0;
        for (0..@min(rows, max_rows)) |r| n += @intFromBool(self.has(r));
        return n;
    }
    pub fn all(rows: usize) RowSet {
        var s: RowSet = .{};
        for (0..@min(rows, max_rows)) |r| s.set(r, true);
        return s;
    }
    pub fn eql(a: *const RowSet, b: *const RowSet) bool {
        return std.mem.eql(u64, &a.bits, &b.bits);
    }
};

/// How a panel shows time. `scroll` (the default): the newest sample is at the right edge
/// and the traces move left. `sweep`: the traces stand still and a cursor moves left to
/// right, overwriting the previous pass (as oers and the stock LFP viewer draw).
/// `triggered`: the panel shows the stretch of signal around each rising edge of a TTL
/// input line, the last few overlaid with the newest brightest (for opto-tagging: the
/// laser's TTL as the trigger).
pub const Mode = enum { scroll, sweep, triggered };

/// What starts a triggered panel's sweeps: a TTL input line's rising edge, or one of the
/// panel's own channels crossing a level (see slope.zig).
pub const TrigSource = enum { ttl, channel };

pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

/// Where a panel is: position and size as fractions of the display.
pub const Place = struct { x: f64, y: f64, w: f64, h: f64 };

/// Triggered mode: what starts a sweep, and what is shown around it.
pub const Trigger = struct {
    source: TrigSource = .ttl,
    /// The TTL input line (1-based).
    line: u8 = 2,
    /// Slope trigger: the panel row it listens to, and the holdoff after each trigger. Its
    /// level and slope are that channel's detection threshold (thresholds.zig).
    row: u32 = 0,
    holdoff_ms: f64 = 0,
    /// The window around the trigger in ms, and how many sweeps are overlaid.
    pre_ms: f64 = 10,
    post_ms: f64 = 40,
    overlay: u32 = 10,
    /// The window of the trigger source that is not in use (TTL: -10/+40 ms, slope: -1/+2),
    /// swapped in by `setTrigSource`.
    other_pre_ms: f64 = 1,
    other_post_ms: f64 = 2,
};

/// Common average reference (electrodes only; like the filter, never applied to what is
/// recorded): the plain mean of the `ref` rows, sample by sample, is subtracted from the
/// `sub` rows. It is taken from the samples as acquired and subtracted before any filter,
/// which for these (linear) filters is the same as filtering everything alike first.
pub const Reference = struct {
    on: bool = false,
    ref: RowSet = .{},
    sub: RowSet = .{},
};

/// Display filter (electrodes only; never applied to what is recorded): whether the panel
/// shows its channels band-passed, and the band's corners in Hz (0 = that side off).
/// 4th-order Butterworth each side, see `dsp.Band`.
pub const Filter = struct {
    on: bool = false,
    low_hz: f64 = 300,
    high_hz: f64 = 6000,
};

/// What single rows have of their own.
pub const PerRow = struct {
    /// Rows that stay unfiltered when the display filter is on (slow signals beside fast
    /// ones on one headstage), and rows that are not shown at all.
    raw: RowSet = .{},
    hidden: RowSet = .{},
    /// A factor on the panel's `scale` (Ctrl+wheel over a row); 1 = the panel's scale.
    gain: [max_rows]f32 = @splat(1),
};

pub const Panel = struct {
    name_buf: [32]u8 = undefined,
    name_len: usize = 0,
    place: Place,
    kind: Kind,
    /// First channel (index into a sample) and how many: one row each.
    first_ch: u32,
    rows: u32,
    /// Time across the panel, s.
    span_s: f64,
    /// The longest `span_s` may be now (`setSpanLimit`), and the time base to go back to
    /// when that shrinks below it. Not settings: never saved.
    span_limit: f64 = span_max,
    live_span_s: f64 = 2.0,
    /// Units per row: µV for electrodes, V for aux and adc.
    scale: f64,
    mode: Mode = .scroll,
    trigger: Trigger = .{},
    per_row: PerRow = .{},
    reference: Reference = .{},
    filter: Filter = .{},
    /// Source "ttl": the input lines shown, 1-based, one per row.
    ttl_lines: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 },
    /// A TTL line (1-based) whose high state is shown as a tint over the whole panel, or 0.
    tint_line: u8 = 0,
    /// Where the band-passed copy of the panel's channels is in a row of the display's
    /// sample history (set by `feed.Feed.init`).
    slot: u32 = 0,
    /// What the panel shows, in a word for its title (`shortSource`); empty: `shortLabel`
    /// makes one from the kind.
    short: []const u8 = "",
    /// Not shown now (the ADC panels, hidden with `~`). Not saved. Input and drawing skip it;
    /// the feed does not know.
    hidden: bool = false,

    pub fn name(self: *const Panel) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// The panel's title label: "A1", "A" (the port's only headstage), "all", "AUX", "ADC",
    /// "TTL".
    pub fn shortLabel(self: *const Panel) []const u8 {
        if (self.short.len > 0) return self.short;
        return switch (self.kind) {
            .electrode => "all",
            .aux => "AUX",
            .adc => "ADC",
            .ttl => "TTL",
        };
    }

    /// A triggered panel keeps a strip at the top for its title, so that it does not lie over
    /// row 0: a line of text and 10 pixels (0 without a font, or when not triggered).
    pub fn headerPx(self: *const Panel, line_h: f32) u32 {
        if (self.mode != .triggered or line_h <= 0) return 0;
        return @as(u32, @intFromFloat(line_h)) + 10;
    }

    /// The part of `r` (the panel's `pixelRect`) the rows are laid out in: `r` less the
    /// header strip. Everything that maps rows to pixels uses this.
    pub fn bodyRect(self: *const Panel, r: Rect, line_h: f32) Rect {
        const hdr = @min(self.headerPx(line_h), r.h -| 1);
        return .{ .x = r.x, .y = r.y + hdr, .w = r.w, .h = r.h - hdr };
    }

    /// Whether the title should name the panel's scale: some shown row uses it (when every
    /// shown row has a scale of its own, it does not).
    pub fn usesPanelScale(self: *const Panel) bool {
        const shown = self.shownRows();
        if (shown == 0) return true;
        for (0..shown) |k| {
            const row = self.rowOfShown(k) orelse continue;
            if (row >= max_rows or self.per_row.gain[row] == 1) return true;
        }
        return false;
    }

    /// Physical units per stored LSB, in the panel's unit (µV or V).
    pub fn unitsPerLsb(self: *const Panel) f64 {
        return switch (self.kind) {
            .electrode => types.electrode_uv_per_bit,
            .aux => types.aux_v_per_bit,
            .adc => types.adc_v_per_bit,
            .ttl => 1.0,
        };
    }

    /// The reference is on and has something to average.
    pub fn carActive(self: *const Panel) bool {
        return self.reference.on and self.kind == .electrode and self.reference.ref.count(self.rows) > 0;
    }

    /// Turns the reference on or off; turning it on with nothing chosen yet takes every
    /// row for both sets.
    pub fn setCar(self: *Panel, on: bool) void {
        if (self.kind != .electrode) return;
        self.reference.on = on;
        if (on and self.reference.ref.count(self.rows) == 0) {
            self.reference.ref = .all(self.rows);
            self.reference.sub = .all(self.rows);
        }
    }

    /// A number that changes whenever what the panel's slot holds changes, or how wide it
    /// is: the kind, the channels (first and how many), the filter, the rows shown raw or
    /// hidden, the reference, and a TTL panel's lines. For noticing that something made
    /// from it is out of date. Display-only settings (scale, time base, mode, trigger,
    /// place, tint) leave it alone, and so does `slot`, which the feed sets.
    pub fn signalSignature(self: *const Panel) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(&.{@backingInt(self.kind)});
        h.update(std.mem.asBytes(&self.first_ch));
        h.update(std.mem.asBytes(&self.rows));
        if (self.kind == .ttl) h.update(self.ttl_lines[0..@min(self.rows, self.ttl_lines.len)]);
        h.update(std.mem.asBytes(&self.filter.on));
        h.update(std.mem.asBytes(&self.filter.low_hz));
        h.update(std.mem.asBytes(&self.filter.high_hz));
        h.update(std.mem.asBytes(&self.per_row.raw.bits));
        h.update(std.mem.asBytes(&self.per_row.hidden.bits));
        h.update(std.mem.asBytes(&self.reference.on));
        h.update(std.mem.asBytes(&self.reference.ref.bits));
        h.update(std.mem.asBytes(&self.reference.sub.bits));
        return h.final();
    }

    /// Switches between TTL and slope triggering, each with its own window.
    pub fn setTrigSource(self: *Panel, source: TrigSource) void {
        if (source == self.trigger.source or (source == .channel and self.kind != .electrode)) return;
        self.trigger.source = source;
        std.mem.swap(f64, &self.trigger.pre_ms, &self.trigger.other_pre_ms);
        std.mem.swap(f64, &self.trigger.post_ms, &self.trigger.other_post_ms);
    }

    /// The channel the panel's slope trigger listens to, if it has one (whatever the mode).
    pub fn triggerChannel(self: *const Panel) ?u32 {
        if (self.trigger.source != .channel or self.kind != .electrode) return null;
        return self.first_ch + self.trigger.row;
    }

    /// Units per row of one row.
    pub fn rowScale(self: *const Panel, row: usize) f64 {
        return self.scale * (if (row < max_rows) self.per_row.gain[row] else 1.0);
    }

    /// Scales one row alone by `factor`, within the limits of the scale.
    pub fn scaleRow(self: *Panel, row: usize, factor: f64) void {
        if (row >= max_rows or row >= self.rows) return;
        const lim = self.scaleLimits();
        const target = std.math.clamp(self.rowScale(row) * factor, lim[0], lim[1]);
        self.per_row.gain[row] = @floatCast(target / self.scale);
    }

    /// The row at a height given as a fraction of the display, if it is in the panel.
    pub fn rowAt(self: *const Panel, fy: f64) ?usize {
        return self.rowAtBelow(fy, 0);
    }

    /// `rowAt` with the top `header` (a fraction of the display) of the panel not rows: the
    /// header strip of a triggered panel.
    pub fn rowAtBelow(self: *const Panel, fy: f64, header: f64) ?usize {
        const shown = self.shownRows();
        const top = self.place.y + header;
        const h = self.place.h - header;
        if (fy < top or fy >= self.place.y + self.place.h or shown == 0 or h <= 0) return null;
        return self.rowOfShown(@min(
            shown - 1,
            @as(usize, @intFromFloat((fy - top) / h * @as(f64, @floatFromInt(shown)))),
        ));
    }

    /// How many rows are drawn (all of them, less the hidden ones of an electrode panel).
    pub fn shownRows(self: *const Panel) u32 {
        if (self.kind != .electrode) return self.rows;
        return self.rows - @as(u32, @intCast(self.per_row.hidden.count(self.rows)));
    }

    /// The row drawn `k`-th from the top.
    pub fn rowOfShown(self: *const Panel, k: usize) ?usize {
        if (self.kind != .electrode) return if (k < self.rows) k else null;
        var seen: usize = 0;
        for (0..self.rows) |r| {
            if (self.per_row.hidden.has(r)) continue;
            if (seen == k) return r;
            seen += 1;
        }
        return null;
    }

    /// Where `row` is drawn, counted from the top, or null if it is hidden.
    pub fn shownIndex(self: *const Panel, row: usize) ?usize {
        if (row >= self.rows) return null;
        if (self.kind != .electrode) return row;
        if (self.per_row.hidden.has(row)) return null;
        var k: usize = 0;
        for (0..row) |r| k += @intFromBool(!self.per_row.hidden.has(r));
        return k;
    }

    /// Whether `row` is shown through the display filter.
    pub fn rowFiltered(self: *const Panel, row: usize) bool {
        return self.filter.on and self.kind == .electrode and !self.per_row.raw.has(row);
    }

    /// The first history column the panel draws: its slot (electrodes: what is shown of
    /// its channels, filtered and referenced as set; TTL: its lanes) or its channels.
    pub fn drawColumn(self: *const Panel) u32 {
        return if (self.kind == .electrode or self.kind == .ttl) self.slot else self.first_ch;
    }

    /// The corners offered when stepping with keys (0 = that side off).
    pub const low_corners = [_]f64{ 0, 1, 3, 10, 30, 100, 300, 600, 1000 };
    pub const high_corners = [_]f64{ 100, 300, 1000, 3000, 6000, 10000, 0 };

    /// Moves the low (`high` false) or high corner one step up or down its list, keeping
    /// the high corner above the low one.
    pub fn stepCorner(self: *Panel, high: bool, up: bool) void {
        const list: []const f64 = if (high) &high_corners else &low_corners;
        const cur = if (high) self.filter.high_hz else self.filter.low_hz;
        // "Off" is the bottom of the low list and the top of the high list.
        const rank = struct {
            fn f(v: f64, is_high: bool) f64 {
                return if (v == 0 and is_high) std.math.inf(f64) else v;
            }
        }.f;
        var next = cur;
        if (up) {
            for (list) |v| {
                if (rank(v, high) > rank(cur, high)) {
                    next = v;
                    break;
                }
            }
        } else {
            for (list) |v| {
                if (rank(v, high) < rank(cur, high)) next = v;
            }
        }
        if (high) {
            if (next != 0 and next <= self.filter.low_hz) return;
            self.filter.high_hz = next;
        } else {
            if (self.filter.high_hz != 0 and next >= self.filter.high_hz) return;
            self.filter.low_hz = next;
        }
    }

    pub fn unit(self: *const Panel) []const u8 {
        return switch (self.kind) {
            .electrode => "uV",
            .ttl => "",
            else => "V",
        };
    }

    pub const span_min = 0.05;
    /// The longest time base, in scroll and in sweep. In sweep mode a column can be up to
    /// two spans old; time bases this long are drawn from the history's buckets
    /// (`decimate.zig`), which reach back twice `span_max` and more.
    pub const span_max = 30.0;
    /// The longest time base in review of a recording, where long stretches are drawn from
    /// the overview (`overview.zig`): two hours.
    pub const review_span_max = 7200.0;

    pub fn scaleLimits(self: *const Panel) [2]f64 {
        return switch (self.kind) {
            .electrode => .{ 5.0, 20000.0 },
            .ttl => .{ ttl_level * 2.2, ttl_level * 20 },
            else => .{ 0.001, 20.0 },
        };
    }

    pub fn defaultScale(kind: Kind) f64 {
        return switch (kind) {
            .electrode => 400.0,
            // AUX is stored about its 1.2255 V mid-point and spans ±1.2 V; the ADCs span ±5 V.
            .aux => 1.0,
            .adc => 5.0,
            // A lane's swing (2 * ttl_level) is 0.6 of its row.
            .ttl => ttl_level * 2 / 0.6,
        };
    }

    /// The longest time base there is to show changed (`span_max` live; in review of a
    /// recording up to its length). A time base longer than the new limit goes back to the
    /// one the panel had before it went beyond the live limit.
    pub fn setSpanLimit(self: *Panel, limit: f64) void {
        if (self.span_s <= span_max) self.live_span_s = self.span_s;
        self.span_limit = @max(limit, span_max);
        if (self.span_s > self.span_limit) self.span_s = if (self.span_limit <= span_max) self.live_span_s else self.span_limit;
    }

    pub fn clamp(self: *Panel) void {
        const lim = self.scaleLimits();
        self.span_s = std.math.clamp(self.span_s, span_min, self.span_limit);
        self.scale = std.math.clamp(self.scale, lim[0], lim[1]);
        self.trigger.pre_ms = std.math.clamp(self.trigger.pre_ms, 0, 1000);
        self.trigger.post_ms = std.math.clamp(self.trigger.post_ms, 0.2, 2000);
        self.trigger.row = @min(self.trigger.row, self.rows -| 1);
        self.trigger.holdoff_ms = std.math.clamp(self.trigger.holdoff_ms, 0, 1000);
        self.trigger.overlay = std.math.clamp(self.trigger.overlay, 1, @import("sweeps.zig").max_sweeps);
        self.trigger.line = std.math.clamp(self.trigger.line, 1, 8);
    }

    /// The panel's rectangle in pixels on a display of `width` x `height`. Neighbouring
    /// panels share edges exactly (both round the same fraction).
    pub fn pixelRect(self: *const Panel, width: u32, height: u32) Rect {
        const fw: f64 = @floatFromInt(width);
        const fh: f64 = @floatFromInt(height);
        const x0: u32 = @intFromFloat(@round(self.place.x * fw));
        const y0: u32 = @intFromFloat(@round(self.place.y * fh));
        const x1: u32 = @intFromFloat(@round((self.place.x + self.place.w) * fw));
        const y1: u32 = @intFromFloat(@round((self.place.y + self.place.h) * fh));
        return .{ .x = x0, .y = y0, .w = @max(x1, x0 + 1) - x0, .h = @max(y1, y0 + 1) - y0 };
    }

    fn setName(self: *Panel, text: []const u8) void {
        self.name_len = @min(text.len, self.name_buf.len);
        @memcpy(self.name_buf[0..self.name_len], text[0..self.name_len]);
    }
};

pub const Set = struct {
    items: [max_panels]Panel = undefined,
    len: usize = 0,
    /// Names of the TTL input lines from the config's [ttl] table ("" = not named).
    ttl_name_buf: [8][24]u8 = undefined,
    ttl_name_len: [8]usize = @splat(0),

    pub fn ttlName(self: *const Set, line: usize) []const u8 {
        if (line < 1 or line > 8) return "";
        return self.ttl_name_buf[line - 1][0..self.ttl_name_len[line - 1]];
    }

    fn readTtlNames(self: *Set, doc: toml.Document) void {
        for (0..8) |i| {
            var key_buf: [8]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "line{d}", .{i + 1}) catch continue;
            const name = doc.string("ttl", 0, key) orelse continue;
            self.ttl_name_len[i] = @min(name.len, self.ttl_name_buf[i].len);
            @memcpy(self.ttl_name_buf[i][0..self.ttl_name_len[i]], name[0..self.ttl_name_len[i]]);
        }
    }

    pub fn slice(self: *Set) []Panel {
        return self.items[0..self.len];
    }

    /// The panel under a point given as fractions of the display; the last one listed wins
    /// where panels overlap (it is drawn on top).
    pub fn at(self: *const Set, fx: f64, fy: f64) ?usize {
        var i = self.len;
        while (i > 0) {
            i -= 1;
            const p = &self.items[i];
            if (p.hidden) continue;
            if (fx >= p.place.x and fx < p.place.x + p.place.w and fy >= p.place.y and fy < p.place.y + p.place.h) return i;
        }
        return null;
    }
};

/// Sets every panel's place from `original` and, with `hide`, hides the ADC panels and
/// stretches each other panel that borders one (an edge shared, within 1e-4, and its extent
/// along that edge within the hidden panel's) over it, on all four sides. Returns false,
/// changing nothing, when there is no ADC panel. `original` and `set` hold the same panels.
pub fn hideAdc(set: *Set, original: *const Set, hide: bool) bool {
    var any = false;
    for (original.items[0..original.len]) |p| any = any or p.kind == .adc;
    if (!any) return false;
    const tol = 1e-4;
    for (set.items[0..set.len], original.items[0..set.len]) |*p, o| {
        p.place = o.place;
        p.hidden = hide and o.kind == .adc;
    }
    if (!hide) return true;
    for (original.items[0..original.len]) |h| {
        if (h.kind != .adc) continue;
        const hp = h.place;
        for (set.items[0..set.len]) |*q| {
            if (q.hidden) continue;
            const qp = q.place;
            const x_within = qp.x >= hp.x - tol and qp.x + qp.w <= hp.x + hp.w + tol;
            const y_within = qp.y >= hp.y - tol and qp.y + qp.h <= hp.y + hp.h + tol;
            if (x_within and @abs(qp.y + qp.h - hp.y) < tol) {
                q.place.h = hp.y + hp.h - qp.y; // above it
            } else if (x_within and @abs(qp.y - (hp.y + hp.h)) < tol) {
                q.place.y = hp.y; // below it
                q.place.h = qp.y + qp.h - hp.y;
            } else if (y_within and @abs(qp.x + qp.w - hp.x) < tol) {
                q.place.w = hp.x + hp.w - qp.x; // left of it
            } else if (y_within and @abs(qp.x - (hp.x + hp.w)) < tol) {
                q.place.x = hp.x; // right of it
                q.place.w = qp.x + qp.w - hp.x;
            }
        }
    }
    return true;
}

pub const Error = error{BadPanel};

/// A slope trigger's level, whether it followed the noise, and its slope were a panel's
/// settings once; they are the trigger channel's threshold now (thresholds.zig). A config
/// or view file that has them is read all the same, without them.
pub const retired_keys = [_][]const u8{ "level_uv", "level_auto", "slope" };

/// What `fromConfig` or `applyViews` found wrong, for the caller's message. The caller
/// owns it and passes a pointer.
pub const Diagnostics = struct {
    buf: [200]u8 = undefined,
    len: usize = 0,
    /// Set when a table had one of `retired_keys` (which is not an error): for the caller
    /// to say once that they are no longer used.
    retired: bool = false,

    /// After `error.BadPanel`, what was wrong with the config or the view file.
    pub fn message(self: *const Diagnostics) []const u8 {
        return self.buf[0..self.len];
    }

    fn fail(self: *Diagnostics, comptime fmt: []const u8, args: anytype) Error {
        const text = std.fmt.bufPrint(&self.buf, fmt, args) catch blk: {
            const fallback = "bad panel";
            @memcpy(self.buf[0..fallback.len], fallback);
            break :blk self.buf[0..fallback.len];
        };
        self.len = text.len;
        return error.BadPanel;
    }
};

const Source = struct { kind: Kind, first: usize, rows: usize };

/// The short label for a panel's title: a panel whose channels are within one headstage is
/// named for it ("A1"), or for its port ("A") when the layout has no second headstage on
/// that port; otherwise "all" for electrodes, "AUX", "ADC", "TTL". Static text.
pub fn shortSource(layout: *const types.Layout, kind: Kind, first: usize, rows: usize) []const u8 {
    switch (kind) {
        .aux => return "AUX",
        .adc => return "ADC",
        .ttl => return "TTL",
        .electrode => {},
    }
    for (layout.headstageSlice()) |h| {
        if (rows == 0 or first < h.first_channel or first + rows > h.first_channel + h.num_channels) continue;
        const name = types.headstage_names[h.slot];
        for (layout.headstageSlice()) |o| {
            if (o.slot != h.slot and types.headstage_names[o.slot][0] == name[0]) return name;
        }
        return name[0..1];
    }
    return "all";
}

fn resolve(source: []const u8, layout: *const types.Layout) ?Source {
    if (std.ascii.eqlIgnoreCase(source, "electrodes")) return .{ .kind = .electrode, .first = 0, .rows = layout.num_electrodes };
    if (std.ascii.eqlIgnoreCase(source, "aux")) return .{ .kind = .aux, .first = layout.num_electrodes, .rows = layout.num_aux };
    if (std.ascii.eqlIgnoreCase(source, "adc")) return .{
        .kind = .adc,
        .first = layout.num_electrodes + layout.num_aux,
        .rows = layout.num_adc,
    };
    if (std.ascii.eqlIgnoreCase(source, "ttl")) return .{ .kind = .ttl, .first = 0, .rows = 8 };
    for (layout.headstageSlice()) |h| {
        if (std.ascii.eqlIgnoreCase(source, types.headstage_names[h.slot])) return .{
            .kind = .electrode,
            .first = h.first_channel,
            .rows = h.num_channels,
        };
    }
    return null;
}

/// One panel per headstage, side by side in headstage order, each in `mode` (the config's
/// top-level `mode`, when `fromConfig` makes them).
pub fn default(layout: *const types.Layout, mode: Mode) Set {
    var set: Set = .{};
    const n = @min(layout.num_headstages, max_panels);
    for (layout.headstageSlice()[0..n], 0..) |h, i| {
        var p: Panel = .{
            .place = .{
                .x = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n)),
                .y = 0,
                .w = 1.0 / @as(f64, @floatFromInt(n)),
                .h = 1,
            },
            .kind = .electrode,
            .first_ch = @intCast(h.first_channel),
            .rows = @intCast(h.num_channels),
            .span_s = 2.0,
            .scale = Panel.defaultScale(.electrode),
            .mode = mode,
        };
        p.setName(types.headstage_names[h.slot]);
        p.short = shortSource(layout, .electrode, p.first_ch, p.rows);
        set.items[i] = p;
    }
    set.len = n;
    return set;
}

fn parseMode(value: ?toml.Value, what: []const u8, n: usize, diag: *Diagnostics) Error!?Mode {
    const v = value orelse return null;
    if (v == .string) {
        if (std.meta.stringToEnum(Mode, v.string)) |m| return m;
    }
    return if (n == 0)
        diag.fail("{s} must be \"scroll\", \"sweep\" or \"triggered\"", .{what})
    else
        diag.fail("{s} {d}: mode must be \"scroll\", \"sweep\" or \"triggered\"", .{ what, n });
}

/// The rows a list key of table `table`'s `i`-th element names (numbered from 1 in the
/// file), or null if the key is not there. A value that is not a list of numbers names no
/// rows. Only electrode panels take these keys.
fn rowSetFrom(doc: toml.Document, table: []const u8, i: usize, key: []const u8, p: *const Panel, diag: *Diagnostics) Error!?RowSet {
    const v = doc.get(table, i, key) orelse return null;
    const list: []const f64 = if (v == .numbers) v.numbers else &.{};
    if (p.kind != .electrode) return diag.fail("panel {d}: {s} is for electrode panels", .{ i + 1, key });
    var rows: RowSet = .{};
    for (list) |n| {
        if (n < 1 or n > @as(f64, @floatFromInt(p.rows)) or n != @floor(n)) return diag.fail(
            "panel {d}: {s} lists rows of the panel, 1 to {d}",
            .{ i + 1, key, p.rows },
        );
        rows.set(@intFromFloat(n - 1), true);
    }
    return rows;
}

/// Applies the settings keys of table `table`'s `i`-th element to a panel: the keys a
/// `[[panel]]` of the config and a `[[view]]` of the view file share (everything but the
/// panel's source, place and name).
fn applyKeys(p: *Panel, doc: toml.Document, table: []const u8, i: usize, diag: *Diagnostics) Error!void {
    if (doc.number(table, i, "span_s")) |v| p.span_s = v;
    if (doc.number(table, i, "scale")) |v| p.scale = v;
    if (try parseMode(doc.get(table, i, "mode"), "panel", i + 1, diag)) |m| p.mode = m;
    if (doc.string(table, i, "trigger_source")) |v| {
        if (std.mem.eql(u8, v, "ttl"))
            p.setTrigSource(.ttl)
        else if (std.mem.eql(u8, v, "spikes"))
            p.setTrigSource(.channel)
        else
            return diag.fail("panel {d}: trigger_source must be \"ttl\" or \"spikes\"", .{i + 1});
    }
    if (doc.number(table, i, "tint")) |v| {
        if (v < 1 or v > 8 or v != @floor(v)) return diag.fail("panel {d}: tint is a TTL input line, 1 to 8", .{i + 1});
        p.tint_line = @intFromFloat(v);
    }
    if (doc.number(table, i, "trigger")) |v| {
        if (v < 1 or v > 8 or v != @floor(v)) return diag.fail("panel {d}: trigger is a TTL input line, 1 to 8", .{i + 1});
        p.trigger.line = @intFromFloat(v);
    }
    if (doc.number(table, i, "trigger_channel")) |v| {
        if (p.kind != .electrode) return diag.fail("panel {d}: trigger_channel is for electrode panels", .{i + 1});
        if (v < 1 or v > @as(f64, @floatFromInt(p.rows)) or v != @floor(v)) return diag.fail(
            "panel {d}: trigger_channel is a row of the panel, 1 to {d}",
            .{ i + 1, p.rows },
        );
        p.setTrigSource(.channel);
        p.trigger.row = @intFromFloat(v - 1);
    }
    // Keys an earlier version wrote: accepted, whatever their value, and not used.
    for (retired_keys) |key| {
        if (doc.get(table, i, key) != null) diag.retired = true;
    }
    if (doc.number(table, i, "holdoff_ms")) |v| p.trigger.holdoff_ms = v;
    if (doc.number(table, i, "pre_ms")) |v| p.trigger.pre_ms = v;
    if (doc.number(table, i, "post_ms")) |v| p.trigger.post_ms = v;
    if (doc.number(table, i, "sweeps")) |v| p.trigger.overlay = @intFromFloat(std.math.clamp(v, 1, 1000));
    if (doc.boolean(table, i, "car")) |on| {
        if (on and p.kind != .electrode) return diag.fail("panel {d}: car is for electrode panels", .{i + 1});
        p.reference.on = on;
        p.reference.ref = .all(p.rows);
        p.reference.sub = .all(p.rows);
    }
    if (try rowSetFrom(doc, table, i, "car_ref", p, diag)) |rows| {
        p.reference.ref = rows;
        // Naming rows turns the reference on unless `car = false` says otherwise, and
        // without `car` or `car_subtract` it is subtracted from every row.
        if (doc.boolean(table, i, "car") == null) p.reference.on = true;
        if (doc.get(table, i, "car_subtract") == null and doc.boolean(table, i, "car") == null) p.reference.sub = .all(p.rows);
    }
    if (try rowSetFrom(doc, table, i, "car_subtract", p, diag)) |rows| {
        p.reference.sub = rows;
        // The same the other way round: without `car` or `car_ref`, every row is averaged.
        if (doc.boolean(table, i, "car") == null) p.reference.on = true;
        if (doc.get(table, i, "car_ref") == null and doc.boolean(table, i, "car") == null) p.reference.ref = .all(p.rows);
    }
    if (try rowSetFrom(doc, table, i, "raw_rows", p, diag)) |rows| p.per_row.raw = rows;
    if (try rowSetFrom(doc, table, i, "hide", p, diag)) |rows| p.per_row.hidden = rows;
    if (doc.number(table, i, "raw_scale")) |v| {
        // The raw rows' own scale, as a factor on the panel's.
        const lim = p.scaleLimits();
        for (0..@min(p.rows, max_rows)) |r| {
            if (p.per_row.raw.has(r)) p.per_row.gain[r] = @floatCast(std.math.clamp(v, lim[0], lim[1]) / p.scale);
        }
    }
    if (doc.get(table, i, "band")) |v| {
        const band: []const f64 = if (v == .numbers) v.numbers else &.{};
        if (band.len != 2 or band[0] < 0 or band[1] < 0 or (band[1] != 0 and band[1] <= band[0]))
            return diag.fail("panel {d}: band needs [low, high] in Hz, low below high (0 leaves a side out)", .{i + 1});
        if (p.kind != .electrode) return diag.fail("panel {d}: band is for electrodes; aux and adc are drawn as they are", .{i + 1});
        p.filter.on = true;
        p.filter.low_hz = band[0];
        p.filter.high_hz = band[1];
    }
    if (doc.boolean(table, i, "filtered")) |on| p.filter.on = on and p.kind == .electrode;
    if (doc.numbers(table, i, "row_scale")) |list| {
        // Every row's own scale, in the panel's unit, in order.
        const lim = p.scaleLimits();
        for (list, 0..) |v, r| {
            if (r < @min(p.rows, max_rows)) p.per_row.gain[r] = @floatCast(std.math.clamp(v, lim[0], lim[1]) / p.scale);
        }
    }
}

/// The panels of the config (`[[panel]]` tables), or the default layout if it has none.
/// After `error.BadPanel`, `diag` says what was wrong.
pub fn fromConfig(doc: toml.Document, layout: *const types.Layout, diag: *Diagnostics) Error!Set {
    const count = doc.count("panel");
    if (count == 0) {
        var set = default(layout, (try parseMode(doc.get("", 0, "mode"), "mode", 0, diag)) orelse .scroll);
        set.readTtlNames(doc);
        return set;
    }
    if (count > max_panels) return diag.fail("{d} panels; at most {d}", .{ count, max_panels });
    var set: Set = .{};
    set.readTtlNames(doc);
    const all_mode = try parseMode(doc.get("", 0, "mode"), "mode", 0, diag);
    for (0..count) |i| {
        const source = doc.string("panel", i, "source") orelse return diag.fail(
            "panel {d}: no source (a headstage such as \"A1\", \"electrodes\", \"aux\", \"adc\" or \"ttl\")",
            .{i + 1},
        );
        const src = resolve(source, layout) orelse return diag.fail(
            "panel {d}: source \"{s}\" is not a connected headstage, \"electrodes\", \"aux\", \"adc\" or \"ttl\"",
            .{ i + 1, source },
        );
        if (src.rows == 0) return diag.fail("panel {d}: source \"{s}\" has no channels (aux and adc must be acquired)", .{ i + 1, source });
        const rect = doc.numbers("panel", i, "rect") orelse return diag.fail("panel {d}: no rect = [x, y, width, height]", .{i + 1});
        if (rect.len != 4) return diag.fail("panel {d}: rect needs 4 numbers, has {d}", .{ i + 1, rect.len });
        if (rect[0] < 0 or rect[1] < 0 or rect[2] <= 0 or rect[3] <= 0 or rect[0] + rect[2] > 1.0001 or rect[1] + rect[3] > 1.0001)
            return diag.fail(
                "panel {d}: rect [{d}, {d}, {d}, {d}] is not inside the display (fractions 0..1)",
                .{ i + 1, rect[0], rect[1], rect[2], rect[3] },
            );
        var p: Panel = .{
            .place = .{
                .x = rect[0],
                .y = rect[1],
                .w = @min(rect[2], 1.0 - rect[0]),
                .h = @min(rect[3], 1.0 - rect[1]),
            },
            .kind = src.kind,
            .first_ch = @intCast(src.first),
            .rows = @intCast(src.rows),
            .span_s = 2.0,
            .scale = Panel.defaultScale(src.kind),
            .mode = all_mode orelse .scroll,
        };
        if (doc.get("panel", i, "lines")) |v| {
            const lines: []const f64 = if (v == .numbers) v.numbers else &.{};
            if (src.kind != .ttl) return diag.fail("panel {d}: lines is for source \"ttl\"", .{i + 1});
            if (lines.len < 1 or lines.len > 8) return diag.fail("panel {d}: lines needs 1 to 8 TTL line numbers", .{i + 1});
            for (lines, 0..) |l, k| {
                if (l < 1 or l > 8 or l != @floor(l)) return diag.fail("panel {d}: lines are TTL input lines, 1 to 8", .{i + 1});
                p.ttl_lines[k] = @intFromFloat(l);
            }
            p.rows = @intCast(lines.len);
        }
        try applyKeys(&p, doc, "panel", i, diag);
        p.setName(doc.string("panel", i, "name") orelse source);
        p.short = shortSource(layout, src.kind, src.first, src.rows);
        p.clamp();
        set.items[i] = p;
    }
    set.len = count;
    return set;
}

const testing = std.testing;

fn testLayout() types.Layout {
    var l: types.Layout = .{ .sample_rate = 30000, .hw_clock_hz = 50e6 };
    l.headstages[0] = .{ .slot = 0, .chip = "RHD2132", .num_channels = 16, .first_channel = 0, .has_bno = false };
    l.headstages[1] = .{ .slot = 2, .chip = "RHD2216", .num_channels = 16, .first_channel = 16, .has_bno = false };
    l.num_headstages = 2;
    l.num_electrodes = 32;
    l.num_aux = 6;
    l.num_adc = 8;
    return l;
}

test "default layout: one panel per headstage, side by side" {
    const l = testLayout();
    var set = default(&l, .scroll);
    try testing.expectEqual(2, set.len);
    try testing.expectEqualStrings("A1", set.items[0].name());
    try testing.expectEqualStrings("B1", set.items[1].name());
    try testing.expectEqual(16, set.items[1].first_ch);
    // The two panels tile a 1921-pixel-wide display without a gap or an overlap.
    const a = set.items[0].pixelRect(1921, 1080);
    const b = set.items[1].pixelRect(1921, 1080);
    try testing.expectEqual(0, a.x);
    try testing.expectEqual(a.x + a.w, b.x);
    try testing.expectEqual(1921, b.x + b.w);
    try testing.expectEqual(0, set.at(0.25, 0.5).?);
    try testing.expectEqual(1, set.at(0.75, 0.5).?);
    try testing.expectEqual(null, set.at(1.5, 0.5));
}

test "panels from the config" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const l = testLayout();
    var diag: Diagnostics = .{};
    const doc = try toml.parse(arena_state.allocator(),
        \\[[panel]]
        \\name = "Port B"
        \\source = "b1"
        \\rect = [0, 0, 0.5, 0.75]
        \\span_s = 0.5
        \\[[panel]]
        \\source = "A1"
        \\rect = [0.5, 0, 0.5, 0.75]
        \\scale = 100000
        \\[[panel]]
        \\source = "adc"
        \\rect = [0, 0.75, 1, 0.25]
    , null);
    var set = try fromConfig(doc, &l, &diag);
    try testing.expectEqual(3, set.len);
    const p = set.slice();
    try testing.expectEqualStrings("Port B", p[0].name());
    try testing.expectEqual(16, p[0].first_ch);
    try testing.expectEqual(0.5, p[0].span_s);
    try testing.expectEqualStrings("A1", p[1].name());
    try testing.expectEqual(20000, p[1].scale); // clamped
    try testing.expectEqual(Kind.adc, p[2].kind);
    try testing.expectEqual(38, p[2].first_ch);
    try testing.expectEqual(8, p[2].rows);
    try testing.expectEqual(5.0, p[2].scale);
    try testing.expectEqualStrings("V", p[2].unit());
    try testing.expectEqual(2, set.at(0.3, 0.9).?);
    try testing.expectEqual(Mode.scroll, p[0].mode);
}

test "band: from the config, and stepped by keys" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const l = testLayout();
    var diag: Diagnostics = .{};
    var set = try fromConfig(try toml.parse(a,
        \\[[panel]]
        \\source = "A1"
        \\rect = [0, 0, 0.5, 1]
        \\band = [10, 0]
        \\[[panel]]
        \\source = "B1"
        \\rect = [0.5, 0, 0.5, 1]
    , null), &l, &diag);
    const p = &set.items[0];
    try testing.expect(p.filter.on);
    try testing.expectEqual(10, p.filter.low_hz);
    try testing.expectEqual(0, p.filter.high_hz);
    try testing.expect(!set.items[1].filter.on);
    try testing.expectEqual(300, set.items[1].filter.low_hz);
    p.stepCorner(false, true);
    try testing.expectEqual(30, p.filter.low_hz);
    p.stepCorner(true, false); // from off down to the top of the list
    try testing.expectEqual(10000, p.filter.high_hz);
    p.filter.high_hz = 100;
    p.stepCorner(false, true); // 100 would meet the high corner: refused
    try testing.expectEqual(30, p.filter.low_hz);
    p.stepCorner(true, false); // already the lowest
    try testing.expectEqual(100, p.filter.high_hz);
    p.filter.low_hz = 1;
    p.stepCorner(false, false);
    try testing.expectEqual(0, p.filter.low_hz);
    try testing.expectError(
        error.BadPanel,
        fromConfig(try toml.parse(a, "[[panel]]\nsource = \"A1\"\nrect = [0,0,1,1]\nband = [6000, 300]", null), &l, &diag),
    );
    try testing.expectError(
        error.BadPanel,
        fromConfig(try toml.parse(a, "[[panel]]\nsource = \"adc\"\nrect = [0,0,1,1]\nband = [1, 100]", null), &l, &diag),
    );
    try testing.expect(std.mem.indexOf(u8, diag.message(), "electrodes") != null);
}

test "triggered panels from the config" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const l = testLayout();
    var diag: Diagnostics = .{};
    var set = try fromConfig(try toml.parse(a,
        \\[[panel]]
        \\source = "A1"
        \\rect = [0, 0, 0.5, 1]
        \\mode = "triggered"
        \\trigger = 3
        \\pre_ms = 2
        \\post_ms = 5000
        \\sweeps = 100
        \\[[panel]]
        \\source = "B1"
        \\rect = [0.5, 0, 0.5, 1]
        \\mode = "triggered"
    , null), &l, &diag);
    const p = &set.items[0];
    try testing.expectEqual(Mode.triggered, p.mode);
    try testing.expectEqual(3, p.trigger.line);
    try testing.expectEqual(2, p.trigger.pre_ms);
    try testing.expectEqual(2000, p.trigger.post_ms); // clamped
    try testing.expectEqual(32, p.trigger.overlay); // clamped
    try testing.expectEqual(2, set.items[1].trigger.line);
    try testing.expectEqual(10, set.items[1].trigger.pre_ms);
    try testing.expectEqual(40, set.items[1].trigger.post_ms);
    try testing.expectError(
        error.BadPanel,
        fromConfig(try toml.parse(a, "[[panel]]\nsource = \"A1\"\nrect = [0,0,1,1]\ntrigger = 9", null), &l, &diag),
    );
}

test "one row scaled on its own" {
    const l = testLayout();
    var set = default(&l, .scroll);
    const p = &set.items[0];
    try testing.expectEqual(0, p.rowAt(0.01).?);
    try testing.expectEqual(15, p.rowAt(0.999).?);
    try testing.expectEqual(8, p.rowAt(0.53).?);
    try testing.expectEqual(null, p.rowAt(1.2));
    p.scaleRow(8, 0.5);
    try testing.expectApproxEqAbs(200.0, p.rowScale(8), 1e-3);
    try testing.expectEqual(400, p.rowScale(7));
    // The panel's scale moves every row, keeping the row's ratio.
    p.scale = 800;
    try testing.expectApproxEqAbs(400.0, p.rowScale(8), 1e-3);
    // Limits apply to the row's own scale.
    p.scaleRow(8, 1e-6);
    try testing.expectApproxEqAbs(5.0, p.rowScale(8), 1e-3);
}

test "TTL lanes, line names and a tint from the config" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const l = testLayout();
    var diag: Diagnostics = .{};
    var set = try fromConfig(try toml.parse(a,
        \\[ttl]
        \\line1 = "camera"
        \\line2 = "laser"
        \\[[panel]]
        \\source = "A1"
        \\rect = [0, 0, 1, 0.8]
        \\tint = 2
        \\[[panel]]
        \\source = "ttl"
        \\rect = [0, 0.8, 1, 0.1]
        \\lines = [2, 1]
        \\[[panel]]
        \\source = "ttl"
        \\rect = [0, 0.9, 1, 0.1]
    , null), &l, &diag);
    try testing.expectEqual(2, set.items[0].tint_line);
    try testing.expectEqual(Kind.ttl, set.items[1].kind);
    try testing.expectEqual(2, set.items[1].rows);
    try testing.expectEqual(2, set.items[1].ttl_lines[0]);
    try testing.expectEqual(1, set.items[1].ttl_lines[1]);
    try testing.expectEqual(8, set.items[2].rows);
    try testing.expectEqualStrings("camera", set.ttlName(1));
    try testing.expectEqualStrings("laser", set.ttlName(2));
    try testing.expectEqualStrings("", set.ttlName(3));
    try testing.expectError(
        error.BadPanel,
        fromConfig(try toml.parse(a, "[[panel]]\nsource = \"ttl\"\nrect = [0,0,1,1]\nlines = [0, 9]", null), &l, &diag),
    );
    try testing.expectError(
        error.BadPanel,
        fromConfig(try toml.parse(a, "[[panel]]\nsource = \"A1\"\nrect = [0,0,1,1]\nlines = [1]", null), &l, &diag),
    );
}

test "slope trigger from the config, with its own window" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const l = testLayout();
    var diag: Diagnostics = .{};
    var set = try fromConfig(try toml.parse(a,
        \\[[panel]]
        \\source = "A1"
        \\rect = [0, 0, 1, 1]
        \\mode = "triggered"
        \\trigger_channel = 5
        \\holdoff_ms = 5
        \\post_ms = 3
    , null), &l, &diag);
    const p = &set.items[0];
    try testing.expectEqual(TrigSource.channel, p.trigger.source);
    try testing.expectEqual(4, p.trigger.row);
    try testing.expectEqual(5, p.trigger.holdoff_ms);
    try testing.expect(!diag.retired);
    try testing.expectEqual(1, p.trigger.pre_ms);
    try testing.expectEqual(3, p.trigger.post_ms);
    // Back to TTL: its own window returns, and the slope's is kept for next time.
    p.setTrigSource(.ttl);
    try testing.expectEqual(10, p.trigger.pre_ms);
    try testing.expectEqual(40, p.trigger.post_ms);
    p.setTrigSource(.channel);
    try testing.expectEqual(3, p.trigger.post_ms);
    try testing.expectError(
        error.BadPanel,
        fromConfig(try toml.parse(a, "[[panel]]\nsource = \"A1\"\nrect = [0,0,1,1]\ntrigger_channel = 99", null), &l, &diag),
    );
    try testing.expectError(
        error.BadPanel,
        fromConfig(try toml.parse(a, "[[panel]]\nsource = \"adc\"\nrect = [0,0,1,1]\ntrigger_channel = 1", null), &l, &diag),
    );
}

test "common average reference from the config" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const l = testLayout();
    var diag: Diagnostics = .{};
    var set = try fromConfig(try toml.parse(a,
        \\[[panel]]
        \\source = "A1"
        \\rect = [0, 0, 0.5, 1]
        \\car = true
        \\[[panel]]
        \\source = "B1"
        \\rect = [0.5, 0, 0.5, 1]
        \\car_ref = [1, 2, 3, 16]
        \\car_subtract = [5, 6]
    , null), &l, &diag);
    const p = &set.items[0];
    try testing.expect(p.carActive());
    try testing.expectEqual(16, p.reference.ref.count(p.rows));
    try testing.expectEqual(16, p.reference.sub.count(p.rows));
    const q = &set.items[1];
    try testing.expect(q.carActive());
    try testing.expectEqual(4, q.reference.ref.count(q.rows));
    try testing.expect(q.reference.ref.has(15) and !q.reference.ref.has(3));
    try testing.expect(q.reference.sub.has(4) and q.reference.sub.has(5) and !q.reference.sub.has(0));
    // An electrode panel draws its slot.
    q.slot = 77;
    try testing.expectEqual(77, q.drawColumn());
    q.setCar(false);
    try testing.expect(!q.carActive());
    // Turning it on with nothing chosen takes every row.
    var fresh = default(&l, .scroll);
    fresh.items[0].setCar(true);
    try testing.expectEqual(16, fresh.items[0].reference.ref.count(16));
    try testing.expectError(
        error.BadPanel,
        fromConfig(try toml.parse(a, "[[panel]]\nsource = \"A1\"\nrect = [0,0,1,1]\ncar_ref = [0, 40]", null), &l, &diag),
    );
    try testing.expectError(
        error.BadPanel,
        fromConfig(try toml.parse(a, "[[panel]]\nsource = \"adc\"\nrect = [0,0,1,1]\ncar = true", null), &l, &diag),
    );
}

test "rows shown raw beside filtered ones, and hidden rows" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const l = testLayout();
    var diag: Diagnostics = .{};
    var set = try fromConfig(try toml.parse(a,
        \\[[panel]]
        \\source = "B1"
        \\rect = [0, 0.25, 1, 0.5]
        \\scale = 400
        \\band = [300, 6000]
        \\raw_rows = [9, 10, 11, 12]
        \\raw_scale = 2000
        \\hide = [13, 14, 15, 16]
    , null), &l, &diag);
    const p = &set.items[0];
    try testing.expectEqual(12, p.shownRows());
    try testing.expect(p.rowFiltered(0) and p.rowFiltered(7) and !p.rowFiltered(8) and !p.rowFiltered(11));
    try testing.expectApproxEqAbs(2000.0, p.rowScale(8), 1e-3);
    try testing.expectEqual(400, p.rowScale(0));
    try testing.expectEqual(11, p.rowOfShown(11).?);
    try testing.expectEqual(null, p.rowOfShown(12));
    try testing.expectEqual(null, p.shownIndex(13));
    // The pointer: the panel is the middle half of the display, 12 rows.
    try testing.expectEqual(0, p.rowAt(0.26).?);
    try testing.expectEqual(11, p.rowAt(0.74).?);
    // Hiding a row in the middle moves the ones below it up.
    p.per_row.hidden.set(2, true);
    try testing.expectEqual(11, p.shownRows());
    try testing.expectEqual(3, p.rowOfShown(2).?);
    try testing.expectEqual(2, p.shownIndex(3).?);
    try testing.expectError(
        error.BadPanel,
        fromConfig(try toml.parse(a, "[[panel]]\nsource = \"adc\"\nrect = [0,0,1,1]\nhide = [1]", null), &l, &diag),
    );
}

test "a row list naming a row the panel does not have is explained" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const l = testLayout();
    var diag: Diagnostics = .{};
    inline for (.{ "car_ref", "car_subtract", "raw_rows", "hide" }) |key| {
        const text = "[[panel]]\nsource = \"A1\"\nrect = [0,0,1,1]\n[[panel]]\nsource = \"B1\"\nrect = [0,0,1,1]\n" ++ key ++ " = [3, 17]";
        try testing.expectError(error.BadPanel, fromConfig(try toml.parse(a, text, null), &l, &diag));
        try testing.expectEqualStrings("panel 2: " ++ key ++ " lists rows of the panel, 1 to 16", diag.message());
    }
}

test "sweep mode: per panel or for all, with the same longest time base" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const l = testLayout();
    var diag: Diagnostics = .{};
    var set = try fromConfig(try toml.parse(a,
        \\mode = "sweep"
        \\[[panel]]
        \\source = "A1"
        \\rect = [0, 0, 0.5, 1]
        \\span_s = 18
        \\[[panel]]
        \\source = "B1"
        \\rect = [0.5, 0, 0.5, 1]
        \\mode = "scroll"
        \\span_s = 18
    , null), &l, &diag);
    try testing.expectEqual(Mode.sweep, set.items[0].mode);
    try testing.expectEqual(18, set.items[0].span_s);
    try testing.expectEqual(Mode.scroll, set.items[1].mode);
    try testing.expectEqual(18, set.items[1].span_s);
    set = try fromConfig(try toml.parse(a, "mode = \"sweep\"", null), &l, &diag);
    try testing.expectEqual(Mode.sweep, set.items[0].mode);
    try testing.expectError(
        error.BadPanel,
        fromConfig(try toml.parse(a, "[[panel]]\nsource = \"A1\"\nrect = [0,0,1,1]\nmode = \"wipe\"", null), &l, &diag),
    );
    try testing.expect(std.mem.indexOf(u8, diag.message(), "sweep") != null);
}

test "config mistakes are explained" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var l = testLayout();
    var diag: Diagnostics = .{};
    try testing.expectError(error.BadPanel, fromConfig(try toml.parse(a, "[[panel]]\nsource = \"C1\"\nrect = [0,0,1,1]", null), &l, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "C1") != null);
    try testing.expectError(
        error.BadPanel,
        fromConfig(try toml.parse(a, "[[panel]]\nsource = \"A1\"\nrect = [0.6,0,0.5,1]", null), &l, &diag),
    );
    try testing.expectError(error.BadPanel, fromConfig(try toml.parse(a, "[[panel]]\nsource = \"A1\"", null), &l, &diag));
    l.num_adc = 0;
    try testing.expectError(
        error.BadPanel,
        fromConfig(try toml.parse(a, "[[panel]]\nsource = \"adc\"\nrect = [0,0,1,1]", null), &l, &diag),
    );
    try testing.expect(std.mem.indexOf(u8, diag.message(), "acquired") != null);
}

/// Applies a view file (`[[view]]` tables, each naming a panel) on top of the panels from
/// the config: the settings last saved from the control window. A view whose panel is
/// not there any more is skipped. Returns how many were applied. After `error.BadPanel`,
/// `diag` says what was wrong.
pub fn applyViews(set: *Set, doc: toml.Document, diag: *Diagnostics) Error!usize {
    var applied: usize = 0;
    for (0..doc.count("view")) |i| {
        const name = doc.string("view", i, "name") orelse continue;
        for (set.slice()) |*p| {
            if (!std.mem.eql(u8, p.name(), name)) continue;
            // A view saved for another shape of the panel (other rows) does not fit.
            if (doc.number("view", i, "rows")) |rows| {
                if (rows != @as(f64, @floatFromInt(p.rows))) break;
            }
            try applyKeys(p, doc, "view", i, diag);
            p.clamp();
            applied += 1;
            break;
        }
    }
    return applied;
}

fn writeRows(w: *std.Io.Writer, key: []const u8, rows: *const RowSet, n: usize) !void {
    try w.print("{s} = [", .{key});
    var first = true;
    for (0..@min(n, max_rows)) |r| {
        if (!rows.has(r)) continue;
        try w.print("{s}{d}", .{ if (first) "" else ", ", r + 1 });
        first = false;
    }
    try w.writeAll("]\n");
}

/// Writes the panels' settings as a view file.
pub fn renderViews(w: *std.Io.Writer, set: *const Set) !void {
    try w.writeAll("# dimna view settings, written by \"Save view\" in the control window and applied on top\n# of config.toml at launch (panels are matched by name). Delete the file to go back to\n# the config's own settings.\n");
    for (set.items[0..set.len]) |*p| {
        try w.print(
            "\n[[view]]\nname = \"{s}\"\nrows = {d}\nspan_s = {d}\nscale = {d}\nmode = \"{t}\"\n",
            .{ p.name(), p.rows, p.span_s, p.scale, p.mode },
        );
        if (p.tint_line != 0) try w.print("tint = {d}\n", .{p.tint_line});
        try w.print("trigger = {d}\nsweeps = {d}\n", .{ p.trigger.line, p.trigger.overlay });
        if (p.kind == .electrode) {
            try w.print("trigger_source = \"{s}\"\n", .{if (p.trigger.source == .channel) "spikes" else "ttl"});
            if (p.trigger.source == .channel) try w.print("trigger_channel = {d}\n", .{p.trigger.row + 1});
            try w.print("holdoff_ms = {d}\n", .{p.trigger.holdoff_ms});
        }
        try w.print("pre_ms = {d}\npost_ms = {d}\n", .{ p.trigger.pre_ms, p.trigger.post_ms });
        if (p.kind == .electrode) {
            try w.print("band = [{d}, {d}]\nfiltered = {}\n", .{ p.filter.low_hz, p.filter.high_hz, p.filter.on });
            try writeRows(w, "raw_rows", &p.per_row.raw, p.rows);
            try writeRows(w, "hide", &p.per_row.hidden, p.rows);
            try w.print("car = {}\n", .{p.reference.on});
            try writeRows(w, "car_ref", &p.reference.ref, p.rows);
            try writeRows(w, "car_subtract", &p.reference.sub, p.rows);
        }
        var own = false;
        for (0..@min(p.rows, max_rows)) |r| own = own or p.per_row.gain[r] != 1;
        if (own) {
            try w.writeAll("row_scale = [");
            for (0..@min(p.rows, max_rows)) |r| try w.print("{s}{d}", .{ if (r == 0) "" else ", ", p.rowScale(r) });
            try w.writeAll("]\n");
        }
    }
}

test "a view file brings back what the control window had set" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const l = testLayout();
    var diag: Diagnostics = .{};
    const config =
        \\[[panel]]
        \\name = "Port A"
        \\source = "A1"
        \\rect = [0, 0, 0.5, 1]
        \\[[panel]]
        \\name = "Port B"
        \\source = "B1"
        \\rect = [0.5, 0, 0.5, 1]
        \\hide = [16]
        \\[[panel]]
        \\name = "ADC"
        \\source = "adc"
        \\rect = [0, 0.9, 1, 0.1]
    ;
    var set = try fromConfig(try toml.parse(a, config, null), &l, &diag);
    // What a session might do in the control window.
    const pa = &set.items[0];
    pa.mode = .triggered;
    pa.setTrigSource(.channel);
    pa.trigger.row = 4;
    pa.trigger.holdoff_ms = 20;
    pa.trigger.post_ms = 3.5;
    pa.span_s = 0.5;
    const pb = &set.items[1];
    pb.scale = 250;
    pb.filter.on = true;
    pb.filter.low_hz = 10;
    pb.filter.high_hz = 0;
    pb.per_row.raw.set(8, true);
    pb.per_row.hidden = .{}; // row 16 shown again, although the config hides it
    pb.per_row.hidden.set(12, true);
    pb.setCar(true);
    pb.reference.ref.set(0, false);
    pb.scaleRow(8, 4.0);
    set.items[2].scale = 2.5;
    set.items[2].tint_line = 2;

    var buf: [16 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try renderViews(&w, &set);
    // A fresh launch: the config, then the view file on top.
    var again = try fromConfig(try toml.parse(a, config, null), &l, &diag);
    try testing.expectEqual(3, try applyViews(&again, try toml.parse(a, w.buffered(), null), &diag));
    const qa = &again.items[0];
    try testing.expectEqual(Mode.triggered, qa.mode);
    try testing.expectEqual(TrigSource.channel, qa.trigger.source);
    try testing.expectEqual(4, qa.trigger.row);
    try testing.expectEqual(20, qa.trigger.holdoff_ms);
    try testing.expectEqual(3.5, qa.trigger.post_ms);
    // The keys that are no longer panel settings are not written.
    for (retired_keys) |key| try testing.expect(std.mem.indexOf(u8, w.buffered(), key) == null);
    try testing.expect(!diag.retired);
    try testing.expectEqual(0.5, qa.span_s);
    const qb = &again.items[1];
    try testing.expectEqual(250, qb.scale);
    try testing.expect(qb.filter.on and qb.filter.low_hz == 10 and qb.filter.high_hz == 0);
    try testing.expect(qb.per_row.raw.has(8) and !qb.per_row.raw.has(7));
    try testing.expect(qb.per_row.hidden.has(12) and !qb.per_row.hidden.has(15));
    try testing.expect(qb.reference.on and !qb.reference.ref.has(0) and qb.reference.ref.has(1) and qb.reference.sub.has(0));
    try testing.expectApproxEqAbs(1000.0, qb.rowScale(8), 0.01);
    try testing.expectEqual(250, qb.rowScale(7));
    try testing.expectEqual(2.5, again.items[2].scale);
    try testing.expectEqual(2, again.items[2].tint_line);
    // Saving again gives the same file: nothing is lost on the way.
    var buf2: [16 * 1024]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    try renderViews(&w2, &again);
    try testing.expectEqualStrings(w.buffered(), w2.buffered());
    // A view for a panel that is gone, or of another size, is skipped.
    try testing.expectEqual(0, try applyViews(
        &again,
        try toml.parse(a, "[[view]]\nname = \"Port C\"\nscale = 1\n[[view]]\nname = \"Port A\"\nrows = 32\nscale = 1", null),
        &diag,
    ));
}

test "a view file of the version before, with level_uv, level_auto and slope, is read without an error" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const l = testLayout();
    var diag: Diagnostics = .{};
    var set = try fromConfig(try toml.parse(a, "[[panel]]\nname = \"Port A\"\nsource = \"A1\"\nrect = [0, 0, 1, 1]", null), &l, &diag);
    // As that version's `renderViews` wrote a slope-triggered electrode panel, and a TTL
    // panel that never wrote them.
    const old =
        \\# dimna view settings, written by "Save view" in the control window and applied on top
        \\# of config.toml at launch (panels are matched by name). Delete the file to go back to
        \\# the config's own settings.
        \\
        \\[[view]]
        \\name = "Port A"
        \\rows = 16
        \\span_s = 0.5
        \\scale = 250
        \\mode = "triggered"
        \\trigger = 2
        \\sweeps = 10
        \\trigger_source = "spikes"
        \\trigger_channel = 5
        \\level_uv = -75
        \\level_auto = false
        \\slope = "rising"
        \\holdoff_ms = 2
        \\pre_ms = 1
        \\post_ms = 3.5
        \\band = [300, 6000]
        \\filtered = true
        \\raw_rows = []
        \\hide = []
        \\car = false
        \\car_ref = []
        \\car_subtract = []
        \\
        \\[tiles]
        \\port = "all"
        \\range_uv = [0, 0]
    ;
    try testing.expectEqual(1, try applyViews(&set, try toml.parse(a, old, null), &diag));
    try testing.expect(diag.retired);
    const p = &set.items[0];
    try testing.expectEqual(Mode.triggered, p.mode);
    try testing.expectEqual(TrigSource.channel, p.trigger.source);
    try testing.expectEqual(4, p.trigger.row);
    try testing.expectEqual(2, p.trigger.holdoff_ms);
    try testing.expectEqual(3.5, p.trigger.post_ms);
    try testing.expectEqual(250, p.scale);
    // Whatever their value: a slope that was never valid is no longer an error either.
    diag = .{};
    _ = try applyViews(&set, try toml.parse(a, "[[view]]\nname = \"Port A\"\nslope = \"up\"\nlevel_auto = 3", null), &diag);
    try testing.expect(diag.retired);
    // Without them, nothing to say.
    diag = .{};
    _ = try applyViews(&set, try toml.parse(a, "[[view]]\nname = \"Port A\"\nholdoff_ms = 3", null), &diag);
    try testing.expect(!diag.retired);
}

test "two parses with different errors each report their own message" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const l = testLayout();
    // The texts `makeDisplay` logs after "config: " and "view file: ".
    var config_diag: Diagnostics = .{};
    var view_diag: Diagnostics = .{};
    try testing.expectError(
        error.BadPanel,
        fromConfig(try toml.parse(a, "[[panel]]\nsource = \"A1\"\nrect = [0,0,1,1]\ntrigger = 9", null), &l, &config_diag),
    );
    var set = try fromConfig(try toml.parse(a, "[[panel]]\nname = \"P\"\nsource = \"A1\"\nrect = [0,0,1,1]", null), &l, &view_diag);
    try testing.expectError(
        error.BadPanel,
        applyViews(&set, try toml.parse(a, "[[view]]\nname = \"P\"\ntrigger_source = \"laser\"", null), &view_diag),
    );
    try testing.expectEqualStrings("panel 1: trigger is a TTL input line, 1 to 8", config_diag.message());
    try testing.expectEqualStrings("panel 1: trigger_source must be \"ttl\" or \"spikes\"", view_diag.message());
    // The top-level mode reaches the default panels through the call, not a global: one
    // config's mode does not carry over to the next.
    var diag: Diagnostics = .{};
    try testing.expectEqual(Mode.sweep, (try fromConfig(try toml.parse(a, "mode = \"sweep\"", null), &l, &diag)).items[1].mode);
    try testing.expectEqual(Mode.scroll, (try fromConfig(try toml.parse(a, "", null), &l, &diag)).items[1].mode);
    // A message too long for the buffer says only "bad panel".
    try testing.expectError(
        error.BadPanel,
        fromConfig(try toml.parse(a, "[[panel]]\nsource = \"" ++ &@as([200]u8, @splat('x')) ++ "\"\nrect = [0,0,1,1]", null), &l, &diag),
    );
    try testing.expectEqualStrings("bad panel", diag.message());
}

test "signalSignature follows what decides a slot, and nothing display-only" {
    const l = testLayout();
    var set = default(&l, .scroll);
    // A TTL panel beside the two electrode panels.
    set.items[2] = set.items[0];
    set.items[2].kind = .ttl;
    set.items[2].first_ch = 0;
    set.items[2].rows = 2;
    set.items[2].ttl_lines[0] = 1;
    set.items[2].ttl_lines[1] = 4;
    set.len = 3;
    const base = set;
    const sig = struct {
        fn f(s: *const Set, i: usize) u64 {
            return s.items[i].signalSignature();
        }
    }.f;
    // What decides a slot's width or contents: each changes the signature.
    var s = base;
    s.items[0].rows = 12; // row count
    try testing.expect(sig(&s, 0) != sig(&base, 0));
    s = base;
    s.items[0].kind = .adc; // kind (an electrode panel has a slot, an ADC panel none)
    try testing.expect(sig(&s, 0) != sig(&base, 0));
    s = base;
    s.items[0].first_ch = 16; // which channels
    try testing.expect(sig(&s, 0) != sig(&base, 0));
    s = base;
    s.items[2].ttl_lines[1] = 5; // a TTL panel's line
    try testing.expect(sig(&s, 2) != sig(&base, 2));
    s = base;
    s.items[2].rows = 3; // a TTL panel's lane count
    s.items[2].ttl_lines[2] = 3;
    try testing.expect(sig(&s, 2) != sig(&base, 2));
    s = base;
    s.items[0].filter.on = true;
    try testing.expect(sig(&s, 0) != sig(&base, 0));
    s = base;
    s.items[0].per_row.hidden.set(3, true);
    try testing.expect(sig(&s, 0) != sig(&base, 0));
    s = base;
    s.items[0].setCar(true);
    try testing.expect(sig(&s, 0) != sig(&base, 0));
    // A TTL panel's lines past its lane count are not shown: no change.
    s = base;
    s.items[2].ttl_lines[5] = 1;
    try testing.expectEqual(sig(&base, 2), sig(&s, 2));
    // Display-only: scale, time base, mode, a row's gain, the trigger, place, tint, name,
    // and the slot the feed sets.
    for (0..3) |i| {
        s = base;
        const p = &s.items[i];
        p.scale *= 3;
        p.span_s = 17;
        p.mode = .sweep;
        p.per_row.gain[1] = 4;
        p.trigger.line = 5;
        p.trigger.pre_ms = 3;
        p.place.x = 0.3;
        p.tint_line = 2;
        p.slot = 99;
        p.setName("renamed");
        try testing.expectEqual(sig(&base, i), sig(&s, i));
        p.mode = .triggered;
        try testing.expectEqual(sig(&base, i), sig(&s, i));
    }
}

fn plainPanel(kind: Kind, x: f64, y: f64, w: f64, h: f64) Panel {
    return .{ .place = .{ .x = x, .y = y, .w = w, .h = h }, .kind = kind, .first_ch = 0, .rows = 8, .span_s = 2, .scale = Panel.defaultScale(kind) };
}

test "short label: the headstage, or its port when it is the port's only one; all, AUX, ADC, TTL" {
    var l = testLayout();
    // A1 and B1 alone on their ports: "A" and "B".
    var set = default(&l, .scroll);
    try testing.expectEqualStrings("A", set.items[0].shortLabel());
    try testing.expectEqualStrings("B", set.items[1].shortLabel());
    // A second headstage on port A makes the first "A1" (and the second "A2"); B stays "B".
    l.headstages[2] = .{ .slot = 1, .chip = "RHD2216", .num_channels = 16, .first_channel = 32, .has_bno = false };
    l.num_headstages = 3;
    l.num_electrodes = 48;
    var diag: Diagnostics = .{};
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    set = try fromConfig(try toml.parse(arena_state.allocator(),
        \\[[panel]]
        \\source = "A1"
        \\rect = [0, 0, 0.5, 0.5]
        \\[[panel]]
        \\source = "A2"
        \\rect = [0.5, 0, 0.5, 0.5]
        \\[[panel]]
        \\source = "B1"
        \\name = "something else"
        \\rect = [0, 0.5, 0.5, 0.5]
        \\[[panel]]
        \\source = "electrodes"
        \\rect = [0.5, 0.5, 0.5, 0.25]
        \\[[panel]]
        \\source = "adc"
        \\rect = [0.5, 0.75, 0.25, 0.25]
        \\[[panel]]
        \\source = "aux"
        \\rect = [0.75, 0.75, 0.25, 0.25]
        \\[[panel]]
        \\source = "ttl"
        \\rect = [0, 0, 0.1, 0.1]
    , null), &l, &diag);
    const want = [_][]const u8{ "A1", "A2", "B", "all", "ADC", "AUX", "TTL" };
    for (want, set.items[0..set.len]) |w, p| try testing.expectEqualStrings(w, p.shortLabel());
    // The name of the config is still the name.
    try testing.expectEqualStrings("something else", set.items[2].name());
}

test "the scale is named unless every shown row has its own" {
    var p = plainPanel(.electrode, 0, 0, 1, 1);
    p.rows = 4;
    try testing.expect(p.usesPanelScale());
    for (0..4) |r| p.per_row.gain[r] = 2;
    try testing.expect(!p.usesPanelScale());
    // One row back on the panel's scale: named again.
    p.per_row.gain[2] = 1;
    try testing.expect(p.usesPanelScale());
    // ... unless that row is hidden.
    p.per_row.hidden.set(2, true);
    try testing.expect(!p.usesPanelScale());
}

test "a triggered panel's rows start below the header strip, in pixels and for the pointer" {
    var p = plainPanel(.electrode, 0, 0.5, 1, 0.5);
    p.rows = 10;
    const r = p.pixelRect(1000, 800);
    try testing.expectEqual(400, r.y);
    // Scrolling: no strip, whatever the font.
    try testing.expectEqual(0, p.headerPx(16));
    try testing.expectEqual(r, p.bodyRect(r, 16));
    p.mode = .triggered;
    try testing.expectEqual(26, p.headerPx(16));
    try testing.expectEqual(0, p.headerPx(0));
    const b = p.bodyRect(r, 16);
    try testing.expectEqual(426, b.y);
    try testing.expectEqual(374, b.h);
    try testing.expectEqual(r.y + r.h, b.y + b.h);
    // Row 0 begins where the strip ends: a pointer in the strip is on no row, just below it
    // on row 0, and the last pixel on row 9.
    const hdr = 26.0 / 800.0;
    try testing.expectEqual(null, p.rowAtBelow(425.0 / 800.0, hdr));
    try testing.expectEqual(0, p.rowAtBelow(427.0 / 800.0, hdr).?);
    try testing.expectEqual(9, p.rowAtBelow(799.0 / 800.0, hdr).?);
    // Row 1 starts one row height (37.4 px) below the strip.
    try testing.expectEqual(0, p.rowAtBelow((426.0 + 37.0) / 800.0, hdr).?);
    try testing.expectEqual(1, p.rowAtBelow((426.0 + 38.0) / 800.0, hdr).?);
}

test "hiding the ADC panels: the panels that border one and lie within its extent grow over it" {
    // The owner's layout.
    var set: Set = .{};
    set.items[0] = plainPanel(.electrode, 0, 0, 0.5, 0.75);
    set.items[1] = plainPanel(.electrode, 0.5, 0, 0.5, 0.75);
    set.items[2] = plainPanel(.adc, 0, 0.75, 1, 0.25);
    set.len = 3;
    const original = set;
    try testing.expect(hideAdc(&set, &original, true));
    try testing.expectEqual(1.0, set.items[0].place.h);
    try testing.expectEqual(1.0, set.items[1].place.h);
    try testing.expectEqual(0.0, set.items[0].place.y);
    try testing.expectEqual(0.5, set.items[1].place.x);
    try testing.expect(set.items[2].hidden and !set.items[0].hidden);
    // The hidden panel is not under the pointer; the one that grew is.
    try testing.expectEqual(1, set.at(0.7, 0.9).?);
    // Shown again: every place as it was.
    try testing.expect(hideAdc(&set, &original, false));
    for (0..3) |i| {
        try testing.expectEqual(original.items[i].place, set.items[i].place);
        try testing.expect(!set.items[i].hidden);
    }
    try testing.expectEqual(2, set.at(0.7, 0.9).?);
}

test "hiding the ADC panels: a neighbour that does not span the edge stays, and the four sides" {
    var set: Set = .{};
    // Above the ADC panel but wider than it: stays. To its right, within its height: grows
    // left over it. Below it: grows up. Left of it: grows right.
    set.items[0] = plainPanel(.adc, 0.4, 0.4, 0.2, 0.2);
    set.items[1] = plainPanel(.electrode, 0.0, 0.0, 1.0, 0.4); // above, wider
    set.items[2] = plainPanel(.electrode, 0.6, 0.4, 0.4, 0.2); // right
    set.items[3] = plainPanel(.electrode, 0.4, 0.6, 0.2, 0.4); // below
    set.items[4] = plainPanel(.electrode, 0.0, 0.4, 0.4, 0.2); // left
    set.items[5] = plainPanel(.electrode, 0.6, 0.0, 0.4, 0.4); // touches only at a corner
    set.len = 6;
    const original = set;
    try testing.expect(hideAdc(&set, &original, true));
    try testing.expectEqual(original.items[1].place, set.items[1].place);
    try testing.expectEqual(original.items[5].place, set.items[5].place);
    const right = set.items[2].place;
    try testing.expectApproxEqAbs(0.4, right.x, 1e-9);
    try testing.expectApproxEqAbs(0.6, right.w, 1e-9);
    const below = set.items[3].place;
    try testing.expectApproxEqAbs(0.4, below.y, 1e-9);
    try testing.expectApproxEqAbs(0.6, below.h, 1e-9);
    const left = set.items[4].place;
    try testing.expectApproxEqAbs(0.0, left.x, 1e-9);
    try testing.expectApproxEqAbs(0.6, left.w, 1e-9);
    // An edge that is off by more than the tolerance is not shared.
    set = original;
    set.items[2].place.x = 0.6002;
    const off = set;
    try testing.expect(hideAdc(&set, &off, true));
    try testing.expectEqual(off.items[2].place, set.items[2].place);
    // A tiny error is.
    set.items[2].place.x = 0.60001;
    const near = set;
    try testing.expect(hideAdc(&set, &near, true));
    try testing.expectApproxEqAbs(0.4, set.items[2].place.x, 1e-9);
}

test "hiding the ADC panels with none changes nothing" {
    var set: Set = .{};
    set.items[0] = plainPanel(.electrode, 0, 0, 1, 1);
    set.len = 1;
    const original = set;
    try testing.expect(!hideAdc(&set, &original, true));
    try testing.expect(!set.items[0].hidden);
}
