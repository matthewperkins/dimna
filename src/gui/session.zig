//! Parts of a running session that each keep their own state between turns of the display
//! loop: scroll-back review, the alarms, the view file, the recording, and the board's
//! settings. Each is a struct with what it needs to remember and methods the loop calls;
//! the loop itself only says in which order. At the end, what the control window is told
//! about the notes and the sound, and what panels keep across a restart.

const std = @import("std");
const dimna = @import("dimna");
const gpu_mod = @import("gpu.zig");
const control = @import("control.zig");
const i18n = @import("i18n.zig");
const files = @import("files.zig");
const display_mod = @import("display.zig");
const ReviewView = display_mod.ReviewView;
const notes_mod = @import("notes.zig");
const audio_out = @import("audio_out.zig");
const Env = @import("env.zig").Env;
const panels_mod = dimna.panels;
const Io = std.Io;
const log = std.log.scoped(.dimna);

/// Scroll-back review (see review.zig): where the display is looking when it is not looking
/// at now. From the recording's file while there is one; else a freeze of the last seconds
/// the live history still holds.
pub const ReviewSession = struct {
    reader: ?dimna.review.Review = null,
    active: bool = false,
    from_file: bool = false,
    ready: bool = false,
    /// The right edge asked for, and the one drawn (the last the history was ready for).
    view_end: i64 = 0,
    shown_end: i64 = 0,
    /// The file under review: its first sample, and the sample after its last.
    first: i64 = 0,
    file_end: i64 = 0,
    dir_buf: [std.fs.max_path_bytes]u8 = undefined,
    dir_len: usize = 0,
    /// What was asked for (keys, the control window) since the last `step`.
    cmds: [16]control.ReviewAction = undefined,
    /// For each of `cmds` that is `.scroll`: by how many samples (negative: back).
    scroll_by: [16]i64 = undefined,
    num_cmds: usize = 0,
    /// Panels drawn from the overview's pixel columns, and those of them that are there
    /// (bit i: panel i). See `ReviewView`.
    columns: u32 = 0,
    columns_ready: u32 = 0,
    /// What each panel's pixel columns were last made for, and when: made again when the
    /// stretch changes, and a few times a second anyway (the overview fills in).
    made: [panels_mod.max_panels]Made = @splat(.{}),
    pairs: []dimna.pyramid.Pair = &.{},
    pairs_gpa: ?std.mem.Allocator = null,

    const Made = struct { lo: i64 = 0, hi: i64 = 0, cols: u32 = 0, at_ns: i128 = 0, ok: bool = false };
    /// A pixel column of this many samples or more is drawn from the overview.
    const overview_samples_per_column = dimna.pyramid.bucket;

    pub const Context = struct {
        gpa: std.mem.Allocator,
        gpu: *gpu_mod.Gpu,
        layout: *const dimna.types.Layout,
        set: *const panels_mod.Set,
        /// The panel that keys act on (its time base is the size of a step).
        target: usize,
        newest: i64,
        rec: ?*dimna.record.Recorder,
        /// The min/max pyramids of the recording, for stretches too long to read.
        overview: ?*const dimna.overview.Overview = null,
        /// The display's size in pixels (a panel's width decides how it is drawn).
        width: u32 = 0,
        height: u32 = 0,
    };

    pub fn deinit(self: *ReviewSession) void {
        if (self.reader) |*r| r.deinit();
        self.reader = null;
        if (self.pairs_gpa) |gpa| gpa.free(self.pairs);
        self.pairs = &.{};
        self.pairs_gpa = null;
        self.made = @splat(.{});
    }

    /// Makes panel `i`'s pixel columns for the stretch of `span` samples that ends at
    /// `end`, from the overview, into the GPU's review columns. False if the overview
    /// cannot give them (not filled in yet, or that detail has been let go).
    fn makeColumns(self: *ReviewSession, ctx: Context, p: *const panels_mod.Panel, i: usize, cols: u32, span: i64, end: i64) bool {
        const nch = ctx.gpu.nch;
        const rows = p.shownRows();
        if (cols == 0 or cols > gpu_mod.column_region or rows == 0 or rows > gpu_mod.max_rows) return false;
        if (ctx.gpu.rev_cols.len < (i + 1) * gpu_mod.column_region * nch) return false;
        // A stretch that begins before the recording does: the columns before it stay flat.
        const lo_wanted = end - span;
        const skip: u32 = if (lo_wanted >= self.first) 0 else @intCast(@min(
            @as(i64, cols),
            @divFloor((self.first - lo_wanted) * @as(i64, cols) + span - 1, span),
        ));
        const lo = lo_wanted + @divFloor(@as(i64, skip) * span, @as(i64, cols));
        const n = cols - skip;
        const m = &self.made[i];
        const now = dimna.clock.nowNs();
        if (m.lo == lo and m.hi == end and m.cols == cols and now - m.at_ns < 100 * std.time.ns_per_ms) return m.ok;
        m.* = .{ .lo = lo, .hi = end, .cols = cols, .at_ns = now, .ok = false };
        if (n == 0) return false;
        if (self.pairs.len < @as(usize, cols) * rows) {
            const bigger = ctx.gpa.alloc(dimna.pyramid.Pair, @as(usize, gpu_mod.column_region) * gpu_mod.max_rows) catch return false;
            if (self.pairs_gpa) |gpa| gpa.free(self.pairs);
            self.pairs = bigger;
            self.pairs_gpa = ctx.gpa;
        }
        var history_columns: [gpu_mod.max_rows]usize = undefined;
        for (history_columns[0..rows], 0..) |*h, k| h.* = p.drawColumn() + k;
        if (history_columns[rows - 1] >= nch) return false;
        const pairs = self.pairs[0 .. @as(usize, n) * rows];
        if (!ctx.overview.?.columns(lo, end, n, history_columns[0..rows], pairs)) return false;
        const region = ctx.gpu.rev_cols[i * gpu_mod.column_region * nch ..];
        for (0..cols) |c| {
            const out = region[c * nch ..][0..nch];
            for (history_columns[0..rows], 0..) |h, k| {
                const v: dimna.pyramid.Pair = if (c < skip) .{ 0, 0 } else pairs[(c - skip) * rows + k];
                out[h] = @as(u32, @as(u16, @bitCast(v[0]))) | @as(u32, @as(u16, @bitCast(v[1]))) << 16;
            }
        }
        m.ok = true;
        return true;
    }

    pub fn queue(self: *ReviewSession, cmd: control.ReviewAction) void {
        if (self.num_cmds < self.cmds.len) {
            self.cmds[self.num_cmds] = cmd;
            self.scroll_by[self.num_cmds] = 0;
            self.num_cmds += 1;
        }
    }

    /// Queues a move by `n` samples (the display's wheel; negative: back).
    pub fn queueScroll(self: *ReviewSession, n: i64) void {
        if (n == 0) return;
        self.queue(.scroll);
        if (self.num_cmds > 0 and self.cmds[self.num_cmds - 1] == .scroll) self.scroll_by[self.num_cmds - 1] = n;
    }

    /// What the display's input asks for (`Display.reviewActions`), in order.
    pub fn queueInput(self: *ReviewSession, actions: display_mod.ReviewActions) void {
        for (actions.slice()) |cmd| self.queue(cmd);
        self.queueScroll(actions.scroll);
    }

    /// Ends review and lets go of the review history (it is about to be replaced).
    pub fn drop(self: *ReviewSession) void {
        self.active = false;
        self.deinit();
        self.dir_len = 0;
    }

    /// One turn: carries out what was asked for, and brings the review history towards
    /// what the view needs. True if something the control window shows has changed.
    pub fn step(self: *ReviewSession, ctx: Context) bool {
        const fs = ctx.layout.sample_rate;
        const newest = ctx.newest;
        var changed = false;
        // The longest stretch a panel in review shows, and one step of the keys.
        var longest: i64 = 0;
        for (ctx.set.items[0..ctx.set.len]) |*p| {
            if (p.mode != .triggered) longest = @max(longest, @as(i64, @intFromFloat(@ceil(p.span_s * fs))) + 2);
        }
        if (longest == 0) longest = @intFromFloat(2 * fs);
        const tp = &ctx.set.items[ctx.target];
        const window: i64 = if (tp.mode != .triggered) @intFromFloat(tp.span_s * fs) else longest;
        for (self.cmds[0..self.num_cmds], self.scroll_by[0..self.num_cmds]) |cmd, by| {
            changed = true;
            if (cmd == .live or (cmd == .toggle and self.active)) {
                self.active = false;
                continue;
            }
            if (cmd == .scroll) {
                self.scroll(ctx, by);
                continue;
            }
            if (!self.active) self.enter(ctx);
            switch (cmd) {
                .back => self.view_end -= @max(1, @divTrunc(window, 10)),
                .forward => self.view_end += @max(1, @divTrunc(window, 10)),
                .page_back => self.view_end -= @max(1, @divTrunc(window * 9, 10)),
                .page_forward => self.view_end += @max(1, @divTrunc(window * 9, 10)),
                .start => self.view_end = std.math.minInt(i64) / 2,
                .toggle, .live, .scroll => {},
            }
        }
        self.num_cmds = 0;
        if (self.active and self.from_file) {
            const r = &self.reader.?;
            // The file grows while the recording runs.
            if (ctx.rec) |live_rec| self.file_end = self.first + @as(i64, @intCast(live_rec.stats.samples.load(.monotonic)));
            self.view_end = std.math.clamp(self.view_end, @min(self.first + longest, self.file_end), self.file_end);
            // Long stretches come from the overview: a pixel column each. The others, and
            // any the overview cannot give but the review history can hold, from samples.
            const rev_reach: i64 = @as(i64, @intCast(ctx.gpu.rev_cap)) - 2;
            var by_columns: u32 = 0;
            var samples_longest: i64 = 0;
            for (ctx.set.items[0..ctx.set.len], 0..) |*p, i| {
                if (p.mode == .triggered) continue;
                const span: i64 = @intFromFloat(@ceil(p.span_s * fs));
                const cols = p.pixelRect(ctx.width, ctx.height).w;
                const long = ctx.overview != null and ctx.overview.?.active() and span >= overview_samples_per_column * @as(i64, cols);
                if (long and (span + 2 > rev_reach or self.makeColumns(ctx, p, i, cols, span, self.view_end))) {
                    by_columns |= @as(u32, 1) << @intCast(i);
                } else samples_longest = @max(samples_longest, span + 2);
            }
            var ok = true;
            r.follow(ctx.set) catch |err| {
                log.warn("review stopped: {t}", .{err});
                ok = false;
            };
            // A bounded amount per turn of the loop: a long jump fills over a few frames.
            const covered = if (!ok) false else if (samples_longest == 0) true else r.fill(self.view_end - samples_longest, self.view_end, self.file_end, 30000) catch |err| blk: {
                log.warn("review stopped: {t}", .{err});
                ok = false;
                break :blk false;
            };
            if (!ok) {
                self.active = false;
            } else {
                if (covered) self.shown_end = self.view_end;
                self.ready = samples_longest == 0 or r.holds(self.shown_end - samples_longest, self.shown_end, self.file_end);
            }
            // The columns for where the display is shown to be (the samples may lag).
            self.columns = by_columns;
            self.columns_ready = 0;
            for (ctx.set.items[0..ctx.set.len], 0..) |*p, i| {
                const bit = @as(u32, 1) << @intCast(i);
                if (by_columns & bit == 0) continue;
                const span: i64 = @intFromFloat(@ceil(p.span_s * fs));
                if (self.makeColumns(ctx, p, i, p.pixelRect(ctx.width, ctx.height).w, span, self.shown_end)) self.columns_ready |= bit;
            }
        } else if (self.active) {
            // The live history: a freeze, for as long as the samples are still there.
            const oldest = newest - @as(i64, @intCast(ctx.gpu.hist_cap)) + @as(i64, @intFromFloat(fs));
            self.view_end = @min(self.view_end, newest);
            if (self.view_end - longest < oldest) self.view_end = oldest + longest;
            if (self.view_end >= newest and newest - oldest <= longest) self.active = false;
            self.shown_end = self.view_end;
            self.ready = true;
        }
        return changed;
    }

    /// Moves the view by `n` samples (the wheel): back from live enters review; forward to
    /// the live edge (the end of the file being written, or the newest sample) leaves it.
    /// Forward while live does nothing.
    fn scroll(self: *ReviewSession, ctx: Context, n: i64) void {
        if (!self.active) {
            if (n >= 0) return;
            self.enter(ctx);
        }
        self.view_end += n;
        if (n <= 0) return;
        const edge = if (!self.from_file)
            ctx.newest
        else if (ctx.rec) |live_rec|
            self.first + @as(i64, @intCast(live_rec.stats.samples.load(.monotonic)))
        else
            self.file_end;
        if (self.view_end >= edge) self.active = false;
    }

    /// Enters review where the display is now. From the file if one is being written.
    fn enter(self: *ReviewSession, ctx: Context) void {
        self.active = true;
        self.view_end = ctx.newest;
        self.shown_end = ctx.newest;
        self.ready = false;
        self.from_file = false;
        const r = ctx.rec orelse return;
        const first = r.first_sample_shared.load(.acquire);
        if (first == std.math.minInt(i64)) return;
        if (self.reader == null) {
            ctx.gpu.createReview() catch |err| {
                log.warn("no memory for the review history ({t}); review is limited to the last seconds", .{err});
                return;
            };
            // No memory for the reader: review stays on the last seconds (not logged).
            self.reader = dimna.review.Review.init(ctx.gpa, ctx.layout, ctx.set, ctx.gpu.rev, ctx.gpu.rev_cap) catch return;
        }
        if (!self.reader.?.isOpen() or !std.mem.eql(u8, self.dir_buf[0..self.dir_len], r.path)) {
            self.reader.?.open(r.path, first) catch |err| {
                log.warn("review cannot read the recording ({t}); limited to the last seconds", .{err});
                return;
            };
            self.dir_len = @min(r.path.len, self.dir_buf.len);
            @memcpy(self.dir_buf[0..self.dir_len], r.path[0..self.dir_len]);
        }
        self.first = first;
        self.from_file = true;
    }

    /// The stretch of the recording that review is showing, if it is (the overview fills
    /// that in first).
    pub fn wanted(self: *const ReviewSession, set: *const panels_mod.Set, fs: f64) ?dimna.pyramid.Range {
        if (!self.active or !self.from_file) return null;
        var longest: f64 = 0;
        for (set.items[0..set.len]) |*p| {
            if (p.mode != .triggered) longest = @max(longest, p.span_s);
        }
        return .{ .lo = @max(self.first, self.view_end - @as(i64, @intFromFloat(longest * fs))), .hi = self.view_end };
    }

    /// What the display draws from, or null when live.
    pub fn view(self: *const ReviewSession, newest: i64, fs: f64) ?ReviewView {
        if (!self.active) return null;
        return .{
            .end = self.shown_end,
            .from_file = self.from_file,
            .ready = self.ready,
            .behind_s = @as(f64, @floatFromInt(newest - self.shown_end)) / fs,
            .columns = if (self.from_file) self.columns else 0,
            .columns_ready = self.columns_ready,
        };
    }

    pub fn status(self: *const ReviewSession, newest: i64, fs: f64) control.ReviewStatus {
        return .{
            .active = self.active,
            .behind_s = @as(f64, @floatFromInt(newest - self.shown_end)) / fs,
            .at_s = @as(f64, @floatFromInt(self.shown_end)) / fs,
            .from_file = self.from_file,
            .loading = self.active and !self.ready,
        };
    }
};

/// Anything that means samples are not being kept: shown across the display until the
/// user acknowledges it.
pub const Alarms = struct {
    /// What of each count the user has acknowledged; the alarm shows the rest.
    seen: Counts = .{},
    /// A recording failed or could not be started, and that has not been acknowledged.
    recording_failed: bool = false,
    /// Acquisition ended on an error and that was acknowledged (a warning stays).
    ended_seen: bool = false,
    /// The disk filling: the lowest threshold (`disk_alarm_s`) already raised as an alarm
    /// and acknowledged; it is raised again only below the next.
    disk_seen: usize = 0,

    /// Time left on the disk below which there is an alarm (each once, until acknowledged);
    /// below `disk_warn_s` a warning.
    pub const disk_alarm_s = dimna.disk.alarm_s;
    pub const disk_warn_s = dimna.disk.warn_s;

    pub const Counts = struct {
        /// Blocks dropped because the ring was full (the recorder a whole ring behind).
        overflow: u64 = 0,
        /// Samples the board itself dropped.
        dropped: u64 = 0,
        /// Gaps in the recording in progress.
        gaps: u64 = 0,
        /// Times the board went quiet (`Board.stalled_s` reached `stall_s`).
        stalls: u64 = 0,
        /// Times acquisition was restarted after a read error (`dimna.reopen`).
        restarts: u64 = 0,
    };

    /// Whether the board is being read: how long since the last block (while acquiring),
    /// and the error that ended acquisition, if one did.
    pub const Board = struct {
        stalled_s: f64 = 0,
        ended: ?anyerror = null,
        /// While acquisition is down after a read error and the board is being opened
        /// again; null when it is not (running, or given up).
        reopening: ?Reopening = null,
        /// The last read error that led to a restart, the time not acquired over all
        /// restarts, and whether a recording goes on (for the restarted alarm).
        restart_err: ?anyerror = null,
        down_s: f64 = 0,
        recording: bool = false,
    };

    pub const Reopening = struct {
        /// The board is not on the bus: waited for, `seconds` so far. Otherwise the next
        /// attempt (`n` of `of`) is in `seconds`.
        absent: bool,
        seconds: f64,
        n: usize = 0,
        of: usize = 0,

        /// What `r` is doing at `now_ns`, or null (running, or given up).
        pub fn from(r: *const dimna.reopen.Reopen, now_ns: i128) ?Reopening {
            const next = r.nextAttempt();
            return switch (r.state) {
                .waiting => .{ .absent = false, .seconds = @as(f64, @floatFromInt(@max(0, r.due_ns - now_ns))) / 1e9, .n = next.n, .of = next.of },
                .absent => .{ .absent = true, .seconds = @as(f64, @floatFromInt(now_ns - r.stopped_ns)) / 1e9 },
                .running, .gave_up => null,
            };
        }
    };

    /// No block for this long while acquiring: the board has gone quiet (blocks come every
    /// few ms; a USB read waits up to 1 s and then simply tries again, so a silent board
    /// raises no error of its own).
    pub const stall_s = 0.5;

    /// Writes the alarm and warning texts into `status`. `behind_s`: how far the recorder
    /// is behind acquisition, if recording. `acknowledged` is cleared when it was set.
    /// True if either text's presence changed.
    /// `disk`: how long until the recording's disk is full, if known.
    pub fn update(self: *Alarms, status: *display_mod.Status, now: Counts, board: Board, behind_s: ?f64, disk: ?dimna.disk.Left, acknowledged: *bool) bool {
        // The disk thresholds passed: an alarm while one is passed that was not acknowledged.
        var disk_level: usize = 0;
        if (disk) |d| for (disk_alarm_s) |limit| {
            if (d.seconds < limit) disk_level += 1;
        };
        if (acknowledged.*) {
            acknowledged.* = false;
            self.seen = now;
            self.recording_failed = false;
            self.disk_seen = disk_level;
            self.ended_seen = board.ended != null;
        }
        // Running again: the next time it ends is a new alarm.
        if (board.ended == null) self.ended_seen = false;
        // The disk got more room (files deleted, cameras stopped): alarm again next time.
        self.disk_seen = @min(self.disk_seen, disk_level);
        // Here and below: a text too long for its buffer is cut (the writer keeps what fit).
        var w: Io.Writer = .fixed(&status.alarm_buf);
        const sep = "   |   ";
        if (board.ended) |err| if (!self.ended_seen) {
            if (board.reopening) |r| {
                if (r.absent)
                    i18n.print(&w, .alarm_reopen_absent, .{ .err = err, .seconds = r.seconds }) catch {}
                else
                    i18n.print(&w, .alarm_reopen_waiting, .{ .err = err, .seconds = r.seconds, .n = r.n, .of = r.of }) catch {};
            } else i18n.print(&w, .alarm_acquisition_stopped, .{ .err = err }) catch {};
        };
        if (now.restarts > self.seen.restarts) {
            const k = now.restarts - self.seen.restarts;
            w.writeAll(if (w.buffered().len > 0) sep else "") catch {};
            i18n.printCount(&w, "alarm_restarted", k, .{ .times = k, .err = board.restart_err orelse error.Unknown, .lost = board.down_s }) catch {};
            if (board.recording) i18n.print(&w, .alarm_restarted_recording, .{}) catch {};
        }
        if (board.ended == null and board.stalled_s >= stall_s) {
            w.writeAll(if (w.buffered().len > 0) sep else "") catch {};
            i18n.print(&w, .alarm_no_data, .{ .seconds = board.stalled_s }) catch {};
        } else if (now.stalls > self.seen.stalls) {
            const k = now.stalls - self.seen.stalls;
            w.writeAll(if (w.buffered().len > 0) sep else "") catch {};
            i18n.printCount(&w, "alarm_quiet_times", k, .{ .times = k }) catch {};
        }
        if (self.recording_failed) {
            w.writeAll(if (w.buffered().len > 0) sep else "") catch {};
            i18n.print(&w, .alarm_recording_failed, .{}) catch {};
        }
        if (now.overflow > self.seen.overflow) {
            w.writeAll(if (w.buffered().len > 0) sep else "") catch {};
            i18n.printCount(&w, "alarm_blocks_lost", now.overflow - self.seen.overflow, .{ .blocks = now.overflow - self.seen.overflow }) catch {};
        }
        if (now.dropped > self.seen.dropped) {
            w.writeAll(if (w.buffered().len > 0) sep else "") catch {};
            i18n.printCount(&w, "alarm_dropped", now.dropped - self.seen.dropped, .{ .samples = now.dropped - self.seen.dropped }) catch {};
        }
        if (now.gaps > self.seen.gaps) {
            w.writeAll(if (w.buffered().len > 0) sep else "") catch {};
            i18n.printCount(&w, "alarm_gaps", now.gaps - self.seen.gaps, .{ .gaps = now.gaps - self.seen.gaps }) catch {};
        }
        if (disk_level > self.disk_seen) {
            w.writeAll(if (w.buffered().len > 0) sep else "") catch {};
            i18n.print(&w, .alarm_disk_full_in, .{ .left = fmtLeft(disk.?.seconds) }) catch {};
        }
        const alarm_len = w.buffered().len;
        // Not yet lost, but on the way: the recorder is far behind acquisition, or the disk
        // is filling.
        var ww: Io.Writer = .fixed(&status.warning_buf);
        if (board.ended) |err| if (self.ended_seen) {
            if (board.reopening) |r| {
                if (r.absent)
                    i18n.print(&ww, .warn_reopen_absent, .{ .err = err, .seconds = r.seconds }) catch {}
                else
                    i18n.print(&ww, .warn_reopen_waiting, .{ .err = err, .seconds = r.seconds, .n = r.n, .of = r.of }) catch {};
            } else i18n.print(&ww, .warn_acquisition_stopped, .{ .err = err }) catch {};
        };
        if (behind_s) |behind| {
            if (behind > 5) {
                ww.writeAll(if (ww.buffered().len > 0) "   |   " else "") catch {};
                i18n.print(&ww, .warn_disk_behind, .{ .behind = behind }) catch {};
            }
        }
        if (disk) |d| if (d.seconds < disk_warn_s) {
            ww.writeAll(if (ww.buffered().len > 0) "   |   " else "") catch {};
            i18n.print(&ww, .warn_disk_full_in, .{
                .left = fmtLeft(d.seconds),
                .gb = @as(f64, @floatFromInt(d.free_bytes)) / 1e9,
            }) catch {};
        };
        const changed = alarm_len != status.alarm_len or ww.buffered().len != status.warning_len;
        status.alarm_len = alarm_len;
        status.warning_len = ww.buffered().len;
        return changed;
    }
};

/// "about 1 h 50 min", "about 12 min", "about 40 s".
fn fmtLeft(seconds: f64) []const u8 {
    const S = struct {
        threadlocal var buf: [64]u8 = undefined;
    };
    return control.fmtLeft(&S.buf, seconds);
}

/// The panels' settings as a view file: as they are now, and as last saved (at launch: as
/// loaded), to tell whether there is something to save.
pub const ViewFile = struct {
    now: []u8,
    saved: []u8,
    saved_len: usize = 0,

    /// What is saved: the panels' settings, the tile window's view, the detection
    /// thresholds and which sections of the control window are open.
    pub const View = struct {
        set: *const panels_mod.Set,
        tiles: *const dimna.tile_view.TileView,
        thresholds: *const dimna.thresholds.Thresholds,
        /// For how many electrodes there are (a tile and a threshold each); it changes at a
        /// restart.
        layout: *const dimna.types.Layout,
        /// Which sections of the control window are open (none: no `[control]` table).
        control: ?*const dimna.control_view.ControlView = null,

        fn render(self: View, buf: []u8) ?[]const u8 {
            const text = files.renderViews(buf, self.set, self.tiles, self.thresholds, self.layout.num_electrodes) orelse return null;
            const open = self.control orelse return text;
            var w: Io.Writer = .fixed(buf[text.len..]);
            open.render(&w) catch return null;
            return buf[0 .. text.len + w.buffered().len];
        }
    };

    pub fn init(gpa: std.mem.Allocator, view: View) !ViewFile {
        const now = try gpa.alloc(u8, 96 * 1024);
        errdefer gpa.free(now);
        var self: ViewFile = .{ .now = now, .saved = try gpa.alloc(u8, 96 * 1024) };
        if (worthAsking(view).render(self.saved)) |rendered| self.saved_len = rendered.len;
        return self;
    }

    pub fn deinit(self: *ViewFile, gpa: std.mem.Allocator) void {
        gpa.free(self.now);
        gpa.free(self.saved);
    }

    /// The view differs from what was last saved. Which sections of the control window
    /// are open does not count: it is saved with the rest, but opening a section is not a
    /// change worth being asked about on quitting.
    pub fn unsaved(self: *ViewFile, view: View) bool {
        const rendered = worthAsking(view).render(self.now) orelse return false;
        return !std.mem.eql(u8, rendered, self.saved[0..self.saved_len]);
    }

    /// Writes the view to the view file at `path`.
    pub fn save(self: *ViewFile, io: Io, path: []const u8, view: View) !void {
        const rendered = view.render(self.now) orelse return error.ViewTooLarge;
        try files.writeAtomic(io, path, rendered);
        const kept = worthAsking(view).render(self.saved) orelse return error.ViewTooLarge;
        self.saved_len = kept.len;
    }

    /// `view` without what `unsaved` leaves out.
    fn worthAsking(view: View) View {
        var v = view;
        v.control = null;
        return v;
    }
};

/// The recording in progress, if any: started and stopped from the control window while
/// acquisition carries on.
pub const Recording = struct {
    recorder: ?*dimna.record.Recorder = null,
    started_ns: i128 = 0,
    status: control.RecStatus = .{},
    /// Notes on their way into the recording (display thread to recorder thread).
    notes: dimna.events.EventQueue = .{},
    /// Where sessions go.
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root_len: usize = 0,
    /// Faults to make in each recorder started, for testing the alarms (`Env.record_test`).
    fault: Env.RecordTest = .{},
    /// After a recording was closed because acquisition stopped on a read error: its
    /// folder (the next one goes on in the same session, once the board is open again:
    /// `resumeIn`), and where it ended (from its summary); empty when there is none.
    /// Cleared by Stop and by any start.
    resume_buf: [std.fs.max_path_bytes]u8 = undefined,
    resume_len: usize = 0,
    resume_end_sample: i64 = 0,
    resume_last_wall_ns: i64 = 0,

    /// Sets the folder sessions are made under ("~/" is the home folder, `home`).
    pub fn setRoot(self: *Recording, dir: []const u8, home: []const u8) void {
        // A path, not a label: one too long for the buffer is left empty, never cut.
        const text: []const u8 = (if (std.mem.startsWith(u8, dir, "~/"))
            std.fmt.bufPrint(&self.root_buf, "{s}/{s}", .{ home, dir[2..] })
        else
            std.fmt.bufPrint(&self.root_buf, "{s}", .{dir})) catch "";
        self.root_len = text.len;
    }

    pub fn root(self: *const Recording) []const u8 {
        return self.root_buf[0..self.root_len];
    }

    pub fn active(self: *const Recording) bool {
        return self.recorder != null;
    }

    /// The session folder while recording, else "".
    pub fn sessionPath(self: *const Recording) []const u8 {
        return if (self.recorder != null) self.status.path() else "";
    }

    /// Starts a recording of what `ring` carries from now on. `events` are the
    /// acquisition thread's (settings applied while recording). False if it could not
    /// be started: `status` then says why.
    pub fn start(
        self: *Recording,
        gpa: std.mem.Allocator,
        io: Io,
        ring: *dimna.ring.BlockRing,
        info: dimna.record.Info,
        events: *dimna.events.EventQueue,
        now_ns: i128,
    ) bool {
        if (self.recorder != null) return true;
        // `info.continue_in` may point into the buffer: cleared once the recorder is made.
        defer self.resume_len = 0;
        // What happened before this recording is not its events or its notes.
        while (events.pop()) |_| {}
        while (self.notes.pop()) |_| {}
        const r = dimna.record.Recorder.create(gpa, io, ring, self.root(), info) catch |err| {
            self.status.state = .failed;
            self.status.say(.note_cannot_create, .{ .dir = self.root(), .err = err });
            log.err("could not create a recording under {s}: {t}", .{ self.root(), err });
            return false;
        };
        r.events_in = events;
        r.notes_in = &self.notes;
        // For testing the alarms: make the recorder fail or stall.
        r.test_fail_after = self.fault.fail_after;
        r.test_stall_after = self.fault.stall_after;
        r.test_stall_ms = self.fault.stall_ms;
        r.start() catch |err| {
            _ = r.finish();
            self.status.state = .failed;
            self.status.say(.note_cannot_start, .{ .err = err });
            return false;
        };
        self.recorder = r;
        self.started_ns = now_ns;
        self.status = .{ .state = .recording };
        // The session folder is the parent of ephys/.
        const session_dir = std.fs.path.dirname(r.path) orelse r.path;
        self.status.path_len = @min(session_dir.len, self.status.path_buf.len);
        @memcpy(self.status.path_buf[0..self.status.path_len], session_dir[0..self.status.path_len]);
        return true;
    }

    /// Whether there is room on the disk to start a recording: not with less than `reserve`
    /// free (`dimna.disk.startCheck`). False: `status` says why, and nothing is created.
    pub fn roomToStart(self: *Recording, reserve: f64) bool {
        const free = dimna.disk.freeBytesNear(self.root());
        if (dimna.disk.startCheck(free, reserve, null) == .ok) return true;
        const gb = @as(f64, @floatFromInt(free.?)) / 1e9;
        self.status.state = .failed;
        self.status.say(.note_disk_too_full, .{ .gb = gb, .dir = self.root(), .need = reserve / 1e9 });
        log.warn("not recording: {d:.1} GB free under {s}, at least {d:.0} GB needed", .{ gb, self.root(), reserve / 1e9 });
        return false;
    }

    /// Asks the recorder to finish; `poll` reports when it has. A recording waiting to go
    /// on after a read error (`resumeIn`) is not started.
    pub fn requestStop(self: *Recording) void {
        self.resume_len = 0;
        const r = self.recorder orelse return;
        if (self.status.state != .recording) return;
        r.requestStop();
        self.status.state = .stopping;
    }

    /// Acquisition stopped on `err`: the recording is closed (up to the last block
    /// acquired) with the reason in its `[final]`, and the session is kept for the one that
    /// goes on once the board is open again (`resumeIn`). Nothing if not recording, or if
    /// already stopping at the user's request.
    pub fn closeForRestart(self: *Recording, err: anyerror) void {
        const r = self.recorder orelse return;
        if (self.status.state != .recording) return;
        var buf: [128]u8 = undefined;
        r.setStopReason(std.fmt.bufPrint(&buf, "acquisition stopped by a read error ({t})", .{err}) catch "acquisition stopped by a read error");
        self.resume_len = @min(r.path.len, self.resume_buf.len);
        @memcpy(self.resume_buf[0..self.resume_len], r.path[0..self.resume_len]);
        self.resume_end_sample = 0;
        self.resume_last_wall_ns = 0;
        r.requestStop();
        self.status.state = .stopping;
    }

    pub const Resume = struct {
        /// The session folder the next recording goes into (as `ephys_<n>/`).
        session: []const u8,
        /// The recording it continues, for its `[start]`.
        continues: dimna.record.Info.Continues,
    };

    /// Where a recording closed by `closeForRestart` goes on, or null. Points into this
    /// `Recording`: copy before `start`.
    pub fn resumeIn(self: *const Recording) ?Resume {
        if (self.resume_len == 0) return null;
        const prev = self.resume_buf[0..self.resume_len];
        return .{
            .session = std.fs.path.dirname(prev) orelse prev,
            .continues = .{ .path = prev, .end_sample = self.resume_end_sample, .last_wall_ns = self.resume_last_wall_ns },
        };
    }

    pub const Ended = enum { complete, failed };

    /// Closes the recorder once it has finished (asked to, or because writing failed).
    /// Null while there is nothing to report.
    pub fn poll(self: *Recording, fs: f64) ?Ended {
        const r = self.recorder orelse return null;
        if (!r.done.load(.acquire)) return null;
        const sum = r.finish();
        self.recorder = null;
        if (self.resume_len > 0) {
            self.resume_end_sample = sum.end_sample;
            self.resume_last_wall_ns = sum.last_wall_ns;
        }
        self.status.samples = sum.samples;
        self.status.gaps = sum.gaps;
        if (sum.failure) |err| {
            self.status.state = .failed;
            self.status.say(.note_recording_failed, .{ .err = err });
            return .failed;
        }
        self.status.state = .idle;
        var clock_buf: [16]u8 = undefined;
        self.status.say(.note_last_recording, .{
            .length = control.fmtClock(&clock_buf, @as(f64, @floatFromInt(sum.samples)) / fs),
            .samples = sum.samples,
            .gaps = sum.gaps,
        });
        return .complete;
    }

    /// Closes a recording in progress, waiting for it (at exit).
    pub fn deinit(self: *Recording) void {
        const r = self.recorder orelse return;
        const sum = r.finish();
        self.recorder = null;
        if (sum.failure) |err| log.err("recording failed: {t}", .{err});
    }

    /// A note for the recording's events.tsv (dropped if not recording).
    pub fn note(self: *Recording, sample: i64, text: []const u8) void {
        if (self.recorder != null) _ = self.notes.push(.init(sample, "note", "{s}", .{text}));
    }

    pub fn seconds(self: *const Recording, now_ns: i128) f64 {
        return if (self.recorder != null) @as(f64, @floatFromInt(now_ns - self.started_ns)) / 1e9 else 0;
    }

    /// Bytes the recorder has written so far (0 when not recording).
    pub fn written(self: *const Recording) u64 {
        return if (self.recorder) |r| r.stats.bytes.load(.monotonic) else 0;
    }

    /// Gaps in the recording in progress.
    pub fn gaps(self: *const Recording) u64 {
        return if (self.recorder) |r| r.stats.gaps.load(.monotonic) else 0;
    }

    /// How far the recorder is behind acquisition, in seconds of signal.
    pub fn behind(self: *const Recording, block_samples: usize, fs: f64) ?f64 {
        const r = self.recorder orelse return null;
        return @as(f64, @floatFromInt(r.backlog() * block_samples)) / fs;
    }

    /// The status with the running counts filled in, for the control window.
    pub fn statusNow(self: *Recording, now_ns: i128, block_samples: usize, fs: f64) control.RecStatus {
        if (self.recorder) |r| {
            self.status.seconds = self.seconds(now_ns);
            self.status.samples = r.stats.samples.load(.monotonic);
            self.status.bytes = r.stats.bytes.load(.monotonic);
            self.status.gaps = r.stats.gaps.load(.monotonic);
            self.status.behind_s = self.behind(block_samples, fs) orelse 0;
        }
        return self.status;
    }
};

/// The board's settings as the control window changes them: what the config file holds (to
/// tell whether they were changed), the rate and channel choices waiting for a restart, and
/// the question asked before quitting with something unsaved.
pub const BoardControl = struct {
    /// What the config file's [board] table (and the command line) gave, or the last save.
    saved: dimna.types.Settings,
    /// What a restart would apply: the settings in use, with the rate and half-channel
    /// choices made since.
    pending: dimna.types.Settings,
    restart_asked: bool = false,
    status: control.BoardStatus = .{},
    quit_prompt: control.QuitPrompt = .{},

    pub fn init(in_use: dimna.types.Settings, config_path: []const u8) BoardControl {
        var self: BoardControl = .{ .saved = in_use, .pending = in_use };
        const n = @min(config_path.len, self.quit_prompt.path_buf.len);
        @memcpy(self.quit_prompt.path_buf[0..n], config_path[0..n]);
        self.quit_prompt.path_len = n;
        return self;
    }

    /// One change from the control window. Headstage filters are applied at once, without
    /// a gap, also while recording (the change is then written to the recording's events);
    /// the rate and half-channel mode are only collected, for `apply` to restart with.
    pub fn edit(
        self: *BoardControl,
        action: control.BoardAction,
        acq: *dimna.acquisition.Acquisition,
        fs: f64,
        recording: bool,
        io: Io,
        gpa: std.mem.Allocator,
        config_path: []const u8,
    ) void {
        var want = acq.requested;
        const bc = dimna.board_config;
        self.status.note_len = 0;
        switch (action) {
            .dsp => |on| want.dsp_enabled = on,
            .dsp_cutoff => |up| want.dsp_cutoff = bc.stepDsp(fs, want.dsp_cutoff, up),
            .lower => |up| want.lower_bandwidth = bc.step(f64, &bc.lower_steps, want.lower_bandwidth, up),
            .upper => |up| want.upper_bandwidth = bc.step(f64, &bc.upper_steps, want.upper_bandwidth, up),
            .rate => |up| self.pending.sample_rate = bc.step(u32, &bc.sample_rates, self.pending.sample_rate, up),
            .half => |slot| if (slot < self.pending.rhd2132_16ch.len) {
                self.pending.rhd2132_16ch[slot] = !self.pending.rhd2132_16ch[slot];
            },
            .apply => self.restart_asked = true,
            .save => if (files.saveBoard(io, gpa, config_path, &acq.requested)) |_| {
                self.saved = acq.requested;
                self.status.say(.note_saved_to, .{ .path = config_path });
            } else |err| self.status.say(.note_cannot_save_to, .{ .path = config_path, .err = err }),
        }
        if (want.lower_bandwidth >= want.upper_bandwidth) {
            self.status.say(.note_band_edges, .{});
        } else if (acq.applySettings(want, recording)) |_| {
            // The live values carry over into what a restart will apply.
            const rate = self.pending.sample_rate;
            const half = self.pending.rhd2132_16ch;
            self.pending = want;
            self.pending.sample_rate = rate;
            self.pending.rhd2132_16ch = half;
        } else |err| {
            self.status.say(.note_not_applied, .{ .err = err });
        }
    }

    /// The settings in use differ from the config file's.
    pub fn unsaved(self: *const BoardControl, in_use: *const dimna.types.Settings) bool {
        return dimna.board_config.diff(&self.saved, in_use).count > 0;
    }

    /// Answering "save" to the quit prompt: writes the settings in use to the config file if
    /// they differ from it. False if that failed (the note says why).
    pub fn saveIfChanged(
        self: *BoardControl,
        io: Io,
        gpa: std.mem.Allocator,
        config_path: []const u8,
        in_use: *const dimna.types.Settings,
    ) bool {
        if (!self.unsaved(in_use)) return true;
        if (files.saveBoard(io, gpa, config_path, in_use)) |_| {
            log.info("board settings saved to {s}", .{config_path});
            return true;
        } else |err| {
            self.status.say(.note_cannot_save_to, .{ .path = config_path, .err = err });
            return false;
        }
    }

    /// Quitting was asked for. True: there are unsaved changes and the control window now
    /// asks about them (so do not quit yet). False: quit (nothing changed, the question
    /// was already up, or there is no control window to ask in).
    pub fn askBeforeQuit(self: *BoardControl, in_use: *const dimna.types.Settings, view_unsaved: bool, can_ask: bool) bool {
        const prompt = &self.quit_prompt;
        var changes = dimna.board_config.diff(&self.saved, in_use);
        // And the panels' settings, as one line.
        if (view_unsaved) changes.add("{s}", .{i18n.text(.quit_panel_views)});
        if (changes.count == 0 or prompt.active or !can_ask) return false;
        prompt.active = true;
        prompt.changes = changes;
        return true;
    }

    /// For the control window: the settings in use, what the chips do for the values asked
    /// for (they offer steps), and what waits for a restart.
    pub fn statusNow(self: *BoardControl, in_use: *const dimna.types.Settings, layout: *const dimna.types.Layout) control.BoardStatus {
        var reg = dimna.registers.Rhd2000Registers.init(layout.sample_rate);
        const st = &self.status;
        st.settings = in_use.*;
        st.lower_actual = reg.setLowerBandwidth(in_use.lower_bandwidth);
        st.upper_actual = reg.setUpperBandwidth(in_use.upper_bandwidth);
        st.dsp_actual = reg.setDspCutoffFreq(in_use.dsp_cutoff);
        st.pending = self.pending;
        st.unsaved = self.unsaved(in_use);
        st.num_headstages = 0;
        for (layout.headstageSlice()) |h| {
            st.headstages[st.num_headstages] = .{ .slot = @intCast(h.slot), .rhd2132 = std.mem.eql(u8, h.chip, "RHD2132") };
            st.num_headstages += 1;
        }
        return st.*;
    }
};

/// The notes, for the control window: the newest few and the presets' texts.
pub fn notesStatus(notes: *const notes_mod.Notes, fs: f64) control.NotesStatus {
    var st: control.NotesStatus = .{ .editing = notes.editing, .num_drafts = notes.num_drafts, .total = notes.total };
    for (&st.recent, 0..) |*line, k| {
        const note = notes.recentNote(k) orelse break;
        line.seconds = @as(f64, @floatFromInt(note.sample)) / fs;
        line.len = notes_mod.prefix(note.text(), line.buf.len).len;
        @memcpy(line.buf[0..line.len], note.buf[0..line.len]);
        st.num_recent = k + 1;
    }
    for (&st.presets, &notes.presets) |*line, *pr| {
        line.len = notes_mod.prefix(pr.text(), 20).len;
        @memcpy(line.buf[0..line.len], pr.buf[0..line.len]);
    }
    return st;
}

/// The audio monitor, for the control window: its settings, what its threads report, and
/// the channels listened to by name.
pub fn audioStatus(
    display: *const display_mod.Display,
    shared: *const audio_out.Shared,
    layout: *const dimna.types.Layout,
) control.AudioStatus {
    var st: control.AudioStatus = .{
        .settings = display.audio,
        .running = shared.running.load(.acquire),
        .sigma_uv = @as(f64, @floatFromInt(shared.held_sigma_c.load(.monotonic))) / 100.0 * dimna.types.electrode_uv_per_bit,
        .latency_ms = @as(f64, @floatFromInt(shared.latency_us.load(.monotonic))) / 1000.0,
        .underruns = shared.underruns.load(.monotonic),
        .dropped = shared.dropped.load(.monotonic),
        .car = display.audio_car,
    };
    var w: Io.Writer = .fixed(&st.listen_buf);
    for (display.audio.channelSlice(), 0..) |ch, k| {
        var name_buf: [16]u8 = undefined;
        // The list is cut where the buffer ends (the writer keeps what fit).
        w.print("{s}{s}", .{ if (k > 0) ", " else "", display_mod.channelName(&name_buf, layout, ch) }) catch break;
    }
    st.listen_len = w.buffered().len;
    return st;
}

/// After a restart the panels are made again from the config (their sources may have
/// moved). What was set by hand is kept where the panels still correspond: one for one by
/// kind, and the per-row settings only where the row count is the same.
pub fn carryOver(new: *panels_mod.Set, old: *const panels_mod.Set) void {
    if (new.len != old.len) return;
    for (new.slice(), old.items[0..old.len]) |*p, *o| {
        if (p.kind != o.kind) continue;
        p.span_s = o.span_s;
        p.scale = o.scale;
        p.mode = o.mode;
        p.filter.on = o.filter.on;
        p.filter.low_hz = o.filter.low_hz;
        p.filter.high_hz = o.filter.high_hz;
        if (p.rows == o.rows) {
            p.per_row.raw = o.per_row.raw;
            p.per_row.hidden = o.per_row.hidden;
            p.per_row.gain = o.per_row.gain;
            p.reference.on = o.reference.on;
            p.reference.ref = o.reference.ref;
            p.reference.sub = o.reference.sub;
        }
        p.trigger.line = o.trigger.line;
        p.trigger.source = o.trigger.source;
        p.trigger.row = @min(o.trigger.row, p.rows -| 1);
        p.trigger.holdoff_ms = o.trigger.holdoff_ms;
        p.trigger.other_pre_ms = o.trigger.other_pre_ms;
        p.trigger.other_post_ms = o.trigger.other_post_ms;
        p.trigger.pre_ms = o.trigger.pre_ms;
        p.trigger.post_ms = o.trigger.post_ms;
        p.trigger.overlay = o.trigger.overlay;
    }
}

test "disk alarms: a warning under 2 h; an alarm under 2 h, 1 h, 30 min, 5 min and 1 min, each until acknowledged" {
    var a: Alarms = .{};
    var st: display_mod.Status = .{};
    var ack = false;
    const at = struct {
        fn f(s: f64) dimna.disk.Left {
            return .{ .seconds = s, .free_bytes = 20e9 };
        }
    }.f;
    _ = a.update(&st, .{}, .{}, null, at(3 * 3600), &ack);
    try std.testing.expectEqual(@as(usize, 0), st.alarm_len + st.warning_len);
    // Under 2 h: the alarm and the warning; acknowledged, the warning stays.
    _ = a.update(&st, .{}, .{}, null, at(110 * 60), &ack);
    try std.testing.expectEqualStrings("THE DISK IS FULL IN about 1 h 50 min", st.alarm());
    try std.testing.expectEqualStrings("the disk is full in about 1 h 50 min (20.0 GB left)", st.warning());
    ack = true;
    _ = a.update(&st, .{}, .{}, null, at(110 * 60), &ack);
    try std.testing.expectEqual(@as(usize, 0), st.alarm_len);
    try std.testing.expect(st.warning_len > 0);
    // Raised again only below the next: 1 h, then 30 min, 5 min, 1 min.
    _ = a.update(&st, .{}, .{}, null, at(61 * 60), &ack);
    try std.testing.expectEqual(@as(usize, 0), st.alarm_len);
    _ = a.update(&st, .{}, .{}, null, at(50 * 60), &ack);
    try std.testing.expectEqualStrings("THE DISK IS FULL IN about 50 min", st.alarm());
    ack = true;
    _ = a.update(&st, .{}, .{}, null, at(50 * 60), &ack);
    _ = a.update(&st, .{}, .{}, null, at(20 * 60), &ack);
    try std.testing.expectEqualStrings("THE DISK IS FULL IN about 20 min", st.alarm());
    try std.testing.expectEqualStrings("the disk is full in about 20 min (20.0 GB left)", st.warning());
    ack = true;
    _ = a.update(&st, .{}, .{}, null, at(20 * 60), &ack);
    _ = a.update(&st, .{}, .{}, null, at(6 * 60), &ack);
    try std.testing.expectEqual(@as(usize, 0), st.alarm_len);
    _ = a.update(&st, .{}, .{}, null, at(4 * 60), &ack);
    try std.testing.expectEqualStrings("THE DISK IS FULL IN about 4 min", st.alarm());
    ack = true;
    _ = a.update(&st, .{}, .{}, null, at(4 * 60), &ack);
    try std.testing.expectEqual(@as(usize, 0), st.alarm_len);
    try std.testing.expect(st.warning_len > 0);
    _ = a.update(&st, .{}, .{}, null, at(50), &ack);
    try std.testing.expectEqualStrings("THE DISK IS FULL IN about 50 s", st.alarm());
    // Room made (back over 2 h): nothing; and the next fall alarms again.
    ack = true;
    _ = a.update(&st, .{}, .{}, null, at(50), &ack);
    _ = a.update(&st, .{}, .{}, null, at(3 * 3600), &ack);
    try std.testing.expectEqual(@as(usize, 0), st.alarm_len + st.warning_len);
    _ = a.update(&st, .{}, .{}, null, at(4 * 60), &ack);
    try std.testing.expect(st.alarm_len > 0);
    // Not recording: no warning, and the alarm still up until acknowledged.
    _ = a.update(&st, .{}, .{}, null, null, &ack);
    try std.testing.expectEqual(@as(usize, 0), st.warning_len);
    ack = true;
    _ = a.update(&st, .{}, .{}, null, null, &ack);
    try std.testing.expectEqual(@as(usize, 0), st.alarm_len + st.warning_len);
}

test "Record with less free space than the reserve is refused before anything is made, and says why" {
    const dir = "/tmp/dimna-no-such-folder-for-a-test/recordings";
    var r: Recording = .{};
    r.setRoot(dir, "");
    try std.testing.expect(!r.roomToStart(1e18));
    try std.testing.expectEqual(control.RecStatus.State.failed, r.status.state);
    try std.testing.expect(std.mem.startsWith(u8, r.status.note(), "not recording: "));
    try std.testing.expect(std.mem.endsWith(u8, r.status.note(), " GB free under " ++ dir ++ ", at least 1000000000 GB needed"));
    try std.testing.expect(dimna.disk.freeBytes(dir) == null);
    // Room enough: nothing said.
    var s: Recording = .{};
    s.setRoot(dir, "");
    try std.testing.expect(s.roomToStart(0));
    try std.testing.expectEqual(control.RecStatus.State.idle, s.status.state);
    try std.testing.expectEqual(@as(usize, 0), s.status.note_len);
}

test "board alarms: quiet now, quiet before (until acknowledged), and acquisition ended (then a warning)" {
    var a: Alarms = .{};
    var st: display_mod.Status = .{};
    var ack = false;
    _ = a.update(&st, .{}, .{ .stalled_s = 0.1 }, null, null, &ack);
    try std.testing.expectEqual(@as(usize, 0), st.alarm_len);
    _ = a.update(&st, .{ .stalls = 1 }, .{ .stalled_s = 1.2 }, null, null, &ack);
    try std.testing.expectEqualStrings("NO DATA FROM THE BOARD FOR 1.2 s", st.alarm());
    // Data again: the spell stays on the bar until acknowledged.
    _ = a.update(&st, .{ .stalls = 1 }, .{ .stalled_s = 0.01 }, null, null, &ack);
    try std.testing.expectEqualStrings("THE BOARD WENT QUIET ONCE (0.5 s or more without data)", st.alarm());
    ack = true;
    _ = a.update(&st, .{ .stalls = 1 }, .{ .stalled_s = 0.01 }, null, null, &ack);
    try std.testing.expectEqual(@as(usize, 0), st.alarm_len);
    // Acquisition ends: an alarm; acknowledged, a warning that stays.
    _ = a.update(&st, .{ .stalls = 1 }, .{ .ended = error.SimulatedReadError }, null, null, &ack);
    try std.testing.expectEqualStrings("ACQUISITION STOPPED (SimulatedReadError): the board is not being read", st.alarm());
    ack = true;
    _ = a.update(&st, .{ .stalls = 1 }, .{ .ended = error.SimulatedReadError }, null, null, &ack);
    try std.testing.expectEqual(@as(usize, 0), st.alarm_len);
    try std.testing.expectEqualStrings("acquisition stopped (SimulatedReadError): nothing is being read; restart dimna", st.warning());
}

test "board alarms: opening the board again, waiting for it, and the restart (until acknowledged)" {
    var a: Alarms = .{};
    var st: display_mod.Status = .{};
    var ack = false;
    const err = error.OniFailed;
    _ = a.update(&st, .{}, .{ .ended = err, .reopening = .{ .absent = false, .seconds = 4.2, .n = 3, .of = 4 } }, null, null, &ack);
    try std.testing.expectEqualStrings("ACQUISITION STOPPED (OniFailed): opening the board again in 4 s (attempt 3 of 4)", st.alarm());
    _ = a.update(&st, .{}, .{ .ended = err, .reopening = .{ .absent = true, .seconds = 12 } }, null, null, &ack);
    try std.testing.expectEqualStrings("THE BOARD IS GONE (OniFailed): waiting for it to come back (12 s so far)", st.alarm());
    // Acknowledged while waiting: a warning that goes on saying so.
    ack = true;
    _ = a.update(&st, .{}, .{ .ended = err, .reopening = .{ .absent = true, .seconds = 13 } }, null, null, &ack);
    try std.testing.expectEqual(@as(usize, 0), st.alarm_len);
    try std.testing.expectEqualStrings("the board is gone (OniFailed): waiting for it to come back (13 s so far)", st.warning());
    // Running again: an alarm that it happened, until acknowledged.
    _ = a.update(&st, .{ .restarts = 1 }, .{ .restart_err = err, .down_s = 14.04, .recording = true }, null, null, &ack);
    try std.testing.expectEqualStrings("ACQUISITION RESTARTED ONCE after a read error (OniFailed): 14.0 s not acquired; the recording goes on in a new folder", st.alarm());
    try std.testing.expectEqual(@as(usize, 0), st.warning_len);
    // It ends again before that is acknowledged: both, and this end is an alarm again
    // although the last one was acknowledged.
    _ = a.update(&st, .{ .restarts = 1 }, .{ .ended = err, .reopening = .{ .absent = false, .seconds = 1, .n = 2, .of = 4 }, .restart_err = err, .down_s = 14.04 }, null, null, &ack);
    try std.testing.expectEqualStrings("ACQUISITION STOPPED (OniFailed): opening the board again in 1 s (attempt 2 of 4)   |   ACQUISITION RESTARTED ONCE after a read error (OniFailed): 14.0 s not acquired", st.alarm());
    _ = a.update(&st, .{ .restarts = 2 }, .{ .restart_err = err, .down_s = 15 }, null, null, &ack);
    try std.testing.expectEqualStrings("ACQUISITION RESTARTED 2 TIMES after read errors (OniFailed): 15.0 s not acquired", st.alarm());
    ack = true;
    _ = a.update(&st, .{ .restarts = 2 }, .{}, null, null, &ack);
    try std.testing.expectEqual(@as(usize, 0), st.alarm_len);
    // Given up: as before.
    _ = a.update(&st, .{ .restarts = 2 }, .{ .ended = err }, null, null, &ack);
    try std.testing.expectEqualStrings("ACQUISITION STOPPED (OniFailed): the board is not being read", st.alarm());
}

test "Reopening.from: what the reopen is doing, for the alarm" {
    var r: dimna.reopen.Reopen = .init(.{}, 0);
    try std.testing.expectEqual(@as(?Alarms.Reopening, null), Alarms.Reopening.from(&r, 0));
    r.ended(error.OniFailed, 0);
    const w = Alarms.Reopening.from(&r, 100 * std.time.ns_per_ms).?;
    try std.testing.expect(!w.absent);
    try std.testing.expectApproxEqAbs(2.9, w.seconds, 1e-9);
    try std.testing.expectEqual(1, w.n);
    try std.testing.expectEqual(4, w.of);
    r.result(error.BoardAbsent, 3 * std.time.ns_per_s);
    const g = Alarms.Reopening.from(&r, 3 * std.time.ns_per_s).?;
    try std.testing.expect(g.absent);
    try std.testing.expectApproxEqAbs(3.0, g.seconds, 1e-9);
}
