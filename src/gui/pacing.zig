//! When to draw, and how the frames landed.
//!
//! Each frame is drawn `margin` before the next refresh, predicted from the presentation
//! times the compositor reports (or, free-running, whenever new samples have arrived). The
//! same reports say how old the newest sample was when its frame reached the screen (the
//! latency figure) and whether the frame landed at the refresh aimed at or one later. From
//! that the pacer widens the margin while frames keep landing late, and, fullscreen, leaves
//! one frame out to get direct scanout back to presenting at once (see main.zig's header
//! for both).
//!
//! The loop calls, in order: `presented` for each report, `due` to ask whether to draw now,
//! `begin` and `end` around a frame, and `second` once a second for the figures.

const std = @import("std");
const Presented = @import("window.zig").Presented;
const DrawResult = @import("gpu.zig").Gpu.DrawResult;
const log = std.log.scoped(.oez);

const skip_backoff_min: i128 = 250 * std.time.ns_per_ms;

pub const Pacer = struct {
    /// Only a fullscreen window can be scanned out directly.
    fullscreen: bool,
    /// Free-running: draw whenever new samples have arrived, at most this often. Negative:
    /// one frame per refresh, drawn `margin_ms` before it.
    free_ms: f64,
    /// The margin was given (--margin-ms) and is not adapted.
    margin_fixed: bool,
    margin_ms: f64,
    /// OEZ_FRAME_DEBUG=1: explain frames that land late. =2: also one line per frame.
    debug: bool,
    trace: bool,

    /// Acquisition time of the newest sample drawn in each frame, by frame tag.
    frame_acquired: [64]i128 = @splat(0),
    timing: [64]Timing = @splat(.{}),
    tag: u64 = 0,
    /// When the frame callback was seen, and the refresh the pending frame aims at.
    ready_seen_ns: i128 = 0,
    target_refresh_ns: i128 = 0,
    /// The last presentation time and the refresh period, from the compositor.
    last_present_ns: i128 = 0,
    refresh_ns: u32 = 0,
    /// When the pending frame is due; 0: none planned.
    draw_at: i128 = 0,
    /// The newest sample of the last frame presented, and when it was drawn.
    drawn_newest: i64 = 0,
    last_draw_ns: i128 = 0,
    clock_checked: bool = false,

    misses: u64 = 0,
    misses_this_second: u32 = 0,
    /// The best latency of the last seconds: what a frame that lands on time achieves.
    best_ms: f64 = std.math.inf(f64),
    best_age: u32 = 0,
    clean_seconds: u32 = 0,

    // Recovery of immediate presentation: skip one frame when frames keep landing a
    // refresh after the one aimed at, and back off if that does not help.
    skip_frame: bool = false,
    skips: u64 = 0,
    skip_backoff_ns: i128 = skip_backoff_min,
    last_skip_ns: i128 = 0,
    /// Consecutive frames presented a refresh after the one aimed at, and on time.
    late_run: u32 = 0,
    good_run: u32 = 0,

    // This second.
    frames: u64 = 0,
    on_time_frames: u64 = 0,
    late_frames: u64 = 0,
    lat_sum: f64 = 0,
    lat_min: f64 = std.math.inf(f64),
    lat_max: f64 = 0,
    lat_n: f64 = 0,

    // Diagnostics only (with `debug`): GPU time per frame, and how draws ended.
    render_sum: f64 = 0,
    render_max: f64 = 0,
    render_n: f64 = 0,
    n_out_of_date: u64 = 0,
    n_busy: u64 = 0,
    n_resize: u64 = 0,

    /// Per-frame timing, to explain frames that land late.
    const Timing = struct { wake_late_ms: f64 = 0, draw_ms: f64 = 0, before_refresh_ms: f64 = 0, callback_to_draw_ms: f64 = 0, target_ns: i128 = 0 };

    /// The last second's figures.
    pub const Report = struct {
        frames: u64,
        /// Some frame's presentation was reported, so the latency figures mean something.
        valid: bool,
        avg_ms: f64,
        min_ms: f64,
        max_ms: f64,
        on_time: u64,
        late: u64,
        skips: u64,
        margin_ms: f64,
        refresh_ms: f64,
    };

    /// `margin_ms` and `free_ms` as given by the user; negative for "not given".
    pub fn init(margin_ms: f64, free_ms: f64, fullscreen: bool) Pacer {
        const env = std.c.getenv("OEZ_FRAME_DEBUG");
        return .{
            .fullscreen = fullscreen,
            .free_ms = free_ms,
            .margin_fixed = margin_ms >= 0,
            .margin_ms = if (margin_ms >= 0) margin_ms else 3.0,
            .debug = env != null,
            .trace = if (env) |v| v[0] == '2' else false,
        };
    }

    /// How long the loop may sleep: up to 2 ms (new samples), less when a frame is due.
    pub fn waitMs(self: *const Pacer, now: i128) i32 {
        if (self.draw_at == 0) return 2;
        return @intCast(std.math.clamp(@divFloor(self.draw_at - now, std.time.ns_per_ms), 0, 2));
    }

    /// A frame reached the screen. `clock` is the compositor's presentation clock id.
    pub fn presented(self: *Pacer, p: Presented, now: i128, clock: i64) void {
        const acquired = self.frame_acquired[p.tag % self.frame_acquired.len];
        if (acquired != 0) {
            const ms = @as(f64, @floatFromInt(p.time_ns - acquired)) / 1e6;
            self.lat_sum += ms;
            self.lat_min = @min(self.lat_min, ms);
            self.lat_max = @max(self.lat_max, ms);
            self.lat_n += 1;
            const ft = self.timing[p.tag % self.timing.len];
            const after_target_ms = if (ft.target_ns != 0) @as(f64, @floatFromInt(p.time_ns - ft.target_ns)) / 1e6 else 0;
            // Did it reach the screen at the refresh aimed at, or a refresh later?
            if (ft.target_ns != 0 and p.refresh_ns > 0) {
                if (p.time_ns - ft.target_ns > p.refresh_ns / 2) {
                    self.late_run += 1;
                    self.good_run = 0;
                    self.late_frames += 1;
                } else {
                    self.late_run = 0;
                    self.good_run += 1;
                    self.on_time_frames += 1;
                    // Two seconds of frames on time: the next loss is a new event.
                    if (self.good_run >= 120) self.skip_backoff_ns = skip_backoff_min;
                }
                // Recovery (see main.zig's header). Only a fullscreen window can be scanned
                // out directly, so only then is there something to recover.
                if (self.fullscreen and self.late_run >= 8 and now - self.last_skip_ns >= self.skip_backoff_ns) {
                    self.skip_frame = true;
                    self.last_skip_ns = now;
                    self.skip_backoff_ns = @min(self.skip_backoff_ns * 2, 8 * std.time.ns_per_s);
                    self.late_run = 0;
                }
            }
            if (self.trace) {
                std.debug.print("frame {d} lat {d:.2} before {d:.2} cb {d:.2} shown {d:.2}\n", .{ p.tag, ms, ft.before_refresh_ms, ft.callback_to_draw_ms, after_target_ms });
            }
            // Landed a refresh later than frames have been landing: it was drawn too
            // close to the deadline (or the desktop was busy).
            const refresh_ms = @as(f64, @floatFromInt(p.refresh_ns)) / 1e6;
            self.best_ms = @min(self.best_ms, ms);
            if (refresh_ms > 0 and ms > self.best_ms + 0.6 * refresh_ms) {
                if (self.debug) log.info("late frame {d}: latency {d:.1} ms; woke {d:.2} ms after its time, draw took {d:.2} ms, committed {d:.2} ms before the refresh aimed at, {d:.2} ms after the frame callback; presented {d:.2} ms after that refresh", .{ p.tag, ms, ft.wake_late_ms, ft.draw_ms, ft.before_refresh_ms, ft.callback_to_draw_ms, after_target_ms });
                self.misses += 1;
                self.misses_this_second += 1;
            }
        }
        self.refresh_ns = p.refresh_ns;
        self.last_present_ns = p.time_ns;
        if (!self.clock_checked) {
            self.clock_checked = true;
            if (clock != 1) log.warn("presentation clock is {d}, not CLOCK_MONOTONIC: latency figures will be off", .{clock});
        }
    }

    /// Whether to draw a frame now. `frame_ready`: the compositor has asked for one.
    /// `newest`: the sample after the last one received (0: none yet, nothing to draw).
    pub fn due(self: *Pacer, now: i128, frame_ready: bool, newest: i64) bool {
        if (frame_ready and self.draw_at == 0) {
            self.ready_seen_ns = now;
            self.target_refresh_ns = 0;
            // The next refresh after now, less the margin. Without presentation feedback
            // (or before the first), draw at once.
            self.draw_at = now;
            // (`last_present_ns` can be slightly ahead of now: the compositor reports a flip it
            // has just queued. The arithmetic below handles that; drawing at once instead
            // would put two commits in one refresh and knock direct scanout into queueing.)
            if (self.refresh_ns > 0 and self.last_present_ns > 0) {
                const period: i128 = self.refresh_ns;
                const next_refresh = self.last_present_ns + (@divFloor(now - self.last_present_ns, period) + 1) * period;
                const at = next_refresh - @as(i128, @intFromFloat(self.margin_ms * 1e6));
                // Already inside the margin: this refresh is lost anyway, so aim at the next.
                self.draw_at = if (at >= now) at else at + period;
                self.target_refresh_ns = if (at >= now) next_refresh else next_refresh + period;
            }
        }
        const free = self.free_ms >= 0;
        const time = if (free)
            newest != self.drawn_newest and @as(f64, @floatFromInt(now - self.last_draw_ns)) >= self.free_ms * 1e6
        else
            frame_ready and self.draw_at != 0 and now >= self.draw_at;
        if (!time) return false;
        if (self.skip_frame and !free and self.refresh_ns > 0) {
            // Leave this refresh out: with nothing committed the output goes idle, and the
            // next commit is taken at once again.
            self.skip_frame = false;
            self.skips += 1;
            self.draw_at += self.refresh_ns;
            if (self.target_refresh_ns != 0) self.target_refresh_ns += self.refresh_ns;
            return false;
        }
        return newest > 0;
    }

    /// A frame is about to be drawn; returns its tag (for `Window.beforePresent`).
    /// `acquired_ns`: when the newest sample it shows was acquired.
    pub fn begin(self: *Pacer, acquired_ns: i128) u64 {
        self.tag += 1;
        self.frame_acquired[self.tag % self.frame_acquired.len] = acquired_ns;
        return self.tag;
    }

    /// The frame begun at `now` was handed over at `done`. `render_ms`: the GPU's time for
    /// it, when that is being measured.
    pub fn end(self: *Pacer, now: i128, done: i128, result: DrawResult, newest: i64, render_ms: ?f64) void {
        if (render_ms) |r| {
            self.render_sum += r;
            self.render_max = @max(self.render_max, r);
            self.render_n += 1;
        }
        self.timing[self.tag % self.timing.len] = .{
            .wake_late_ms = @as(f64, @floatFromInt(now - self.draw_at)) / 1e6,
            .draw_ms = @as(f64, @floatFromInt(done - now)) / 1e6,
            .before_refresh_ms = if (self.target_refresh_ns != 0) @as(f64, @floatFromInt(self.target_refresh_ns - done)) / 1e6 else 0,
            .callback_to_draw_ms = @as(f64, @floatFromInt(now - self.ready_seen_ns)) / 1e6,
            .target_ns = self.target_refresh_ns,
        };
        switch (result) {
            .presented => {
                self.frames += 1;
                self.drawn_newest = newest;
                self.last_draw_ns = now;
            },
            .out_of_date => self.n_out_of_date += 1,
            .busy => self.n_busy += 1,
        }
        self.draw_at = 0;
    }

    /// Once a second: the second's figures, and the margin adapted to them.
    pub fn second(self: *Pacer) Report {
        const refresh_ms = @as(f64, @floatFromInt(self.refresh_ns)) / 1e6;
        const report: Report = .{
            .frames = self.frames,
            .valid = self.lat_n > 0,
            .avg_ms = if (self.lat_n > 0) self.lat_sum / self.lat_n else 0,
            .min_ms = if (self.lat_n > 0) self.lat_min else 0,
            .max_ms = self.lat_max,
            .on_time = self.on_time_frames,
            .late = self.late_frames,
            .skips = self.skips,
            .margin_ms = self.margin_ms,
            .refresh_ms = refresh_ms,
        };
        self.on_time_frames = 0;
        self.late_frames = 0;
        if (self.debug) {
            log.info("  GPU time per frame: avg {d:.2} ms, max {d:.2} ms; draw results so far: out of date {d}, busy {d}, swapchain rebuilds {d}", .{ if (self.render_n > 0) self.render_sum / self.render_n else 0, self.render_max, self.n_out_of_date, self.n_busy, self.n_resize });
            self.render_sum = 0;
            self.render_max = 0;
            self.render_n = 0;
        }
        // A change of regime moves every frame by a refresh: that is not lateness.
        if (self.lat_n > 0 and refresh_ms > 0 and @abs(self.lat_min - self.best_ms) > 0.6 * refresh_ms) {
            self.best_ms = self.lat_min;
            self.misses_this_second = 0;
        }
        // Adapt the margin to sustained lateness only. A few late frames now and then come
        // from the desktop (a window moved, a resize), and a wider margin would not have
        // saved them: widen when at least 5 frames in a second were late, and return
        // towards 3 ms after 3 clean seconds.
        // (Not fullscreen: there, frames a refresh late are a lost direct-scanout state,
        // which a wider margin does not prevent and the skip recovers.)
        if (!self.margin_fixed and !self.fullscreen) {
            if (self.misses_this_second >= 5) {
                self.margin_ms = @min(self.margin_ms + 0.5, @max(3.0, 0.5 * refresh_ms));
                self.clean_seconds = 0;
            } else if (self.misses_this_second == 0) {
                self.clean_seconds += 1;
                if (self.clean_seconds >= 3 and self.margin_ms > 3.0) {
                    self.margin_ms = @max(3.0, self.margin_ms - 0.5);
                    self.clean_seconds = 0;
                }
            } else self.clean_seconds = 0;
        }
        self.misses_this_second = 0;
        // Forget the best now and then, so a change of regime (direct scanout lost to
        // an overlapping window, say) is not counted as lateness for ever.
        self.best_age += 1;
        if (self.best_age >= 5) {
            self.best_age = 0;
            self.best_ms = if (self.lat_n > 0) self.lat_min else std.math.inf(f64);
        }
        self.frames = 0;
        self.lat_sum = 0;
        self.lat_min = std.math.inf(f64);
        self.lat_max = 0;
        self.lat_n = 0;
        return report;
    }
};
