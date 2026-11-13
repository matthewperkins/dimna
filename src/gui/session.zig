//! Parts of a running session that each keep their own state between turns of the display
//! loop: scroll-back review, the alarms, and the view file. Each is a struct with what it
//! needs to remember and a method the loop calls every turn; the loop itself only says in
//! which order.

const std = @import("std");
const oez = @import("oez");
const gpu_mod = @import("gpu.zig");
const control = @import("control.zig");
const files = @import("files.zig");
const ReviewView = @import("display.zig").ReviewView;
const panels_mod = oez.panels;
const Io = std.Io;
const log = std.log.scoped(.oez);

/// Scroll-back review (see review.zig): where the display is looking when it is not looking
/// at now. From the recording's file while there is one; else a freeze of the last seconds
/// the live history still holds.
pub const ReviewSession = struct {
    reader: ?oez.review.Review = null,
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
    num_cmds: usize = 0,

    pub const Context = struct {
        gpa: std.mem.Allocator,
        gpu: *gpu_mod.Gpu,
        layout: *const oez.types.Layout,
        set: *const panels_mod.Set,
        /// The panel that keys act on (its time base is the size of a step).
        target: usize,
        newest: i64,
        rec: ?*oez.record.Recorder,
    };

    pub fn deinit(self: *ReviewSession) void {
        if (self.reader) |*r| r.deinit();
        self.reader = null;
    }

    pub fn queue(self: *ReviewSession, cmd: control.ReviewAction) void {
        if (self.num_cmds < self.cmds.len) {
            self.cmds[self.num_cmds] = cmd;
            self.num_cmds += 1;
        }
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
        for (self.cmds[0..self.num_cmds]) |cmd| {
            changed = true;
            if (cmd == .live or (cmd == .toggle and self.active)) {
                self.active = false;
                continue;
            }
            if (!self.active) self.enter(ctx);
            switch (cmd) {
                .back => self.view_end -= @max(1, @divTrunc(window, 10)),
                .forward => self.view_end += @max(1, @divTrunc(window, 10)),
                .page_back => self.view_end -= @max(1, @divTrunc(window * 9, 10)),
                .page_forward => self.view_end += @max(1, @divTrunc(window * 9, 10)),
                .start => self.view_end = std.math.minInt(i64) / 2,
                .toggle, .live => {},
            }
        }
        self.num_cmds = 0;
        if (self.active and self.from_file) {
            const r = &self.reader.?;
            // The file grows while the recording runs.
            if (ctx.rec) |live_rec| self.file_end = self.first + @as(i64, @intCast(live_rec.stats.samples.load(.monotonic)));
            self.view_end = std.math.clamp(self.view_end, @min(self.first + longest, self.file_end), self.file_end);
            var ok = true;
            r.follow(ctx.set) catch |err| {
                log.warn("review stopped: {t}", .{err});
                ok = false;
            };
            // A bounded amount per turn of the loop: a long jump fills over a few frames.
            const covered = if (ok) r.fill(self.view_end - longest, self.view_end, self.file_end, 30000) catch |err| blk: {
                log.warn("review stopped: {t}", .{err});
                ok = false;
                break :blk false;
            } else false;
            if (!ok) {
                self.active = false;
            } else {
                if (covered) self.shown_end = self.view_end;
                self.ready = r.holds(self.shown_end - longest, self.shown_end, self.file_end);
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
            self.reader = oez.review.Review.init(ctx.gpa, ctx.layout, ctx.set, ctx.gpu.rev, ctx.gpu.hist_cap) catch return;
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

    /// What the display draws from, or null when live.
    pub fn view(self: *const ReviewSession, newest: i64, fs: f64) ?ReviewView {
        if (!self.active) return null;
        return .{ .end = self.shown_end, .from_file = self.from_file, .ready = self.ready, .behind_s = @as(f64, @floatFromInt(newest - self.shown_end)) / fs };
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

    pub const Counts = struct {
        /// Blocks dropped because the ring was full (the recorder a whole ring behind).
        overflow: u64 = 0,
        /// Samples the board itself dropped.
        dropped: u64 = 0,
        /// Gaps in the recording in progress.
        gaps: u64 = 0,
    };

    /// Writes the alarm and warning texts into `status`. `behind_s`: how far the recorder
    /// is behind acquisition, if recording. `acknowledged` is cleared when it was set.
    /// True if either text's presence changed.
    pub fn update(self: *Alarms, status: *control.Status, now: Counts, behind_s: ?f64, acknowledged: *bool) bool {
        if (acknowledged.*) {
            acknowledged.* = false;
            self.seen = now;
            self.recording_failed = false;
        }
        var w: Io.Writer = .fixed(&status.alarm_buf);
        const sep = "   |   ";
        if (self.recording_failed) w.writeAll("RECORDING FAILED: nothing is being recorded") catch {};
        if (now.overflow > self.seen.overflow) w.print("{s}{d} BLOCKS LOST: the disk fell 30 s behind", .{ if (w.buffered().len > 0) sep else "", now.overflow - self.seen.overflow }) catch {};
        if (now.dropped > self.seen.dropped) w.print("{s}THE BOARD DROPPED {d} SAMPLES", .{ if (w.buffered().len > 0) sep else "", now.dropped - self.seen.dropped }) catch {};
        if (now.gaps > self.seen.gaps) w.print("{s}THE RECORDING HAS {d} GAPS", .{ if (w.buffered().len > 0) sep else "", now.gaps - self.seen.gaps }) catch {};
        const alarm_len = w.buffered().len;
        // Not yet lost, but on the way: the recorder is far behind acquisition.
        var ww: Io.Writer = .fixed(&status.warning_buf);
        if (behind_s) |behind| {
            if (behind > 5) ww.print("the disk is {d:.0} s behind (samples are lost at 30 s)", .{behind}) catch {};
        }
        const changed = alarm_len != status.alarm_len or ww.buffered().len != status.warning_len;
        status.alarm_len = alarm_len;
        status.warning_len = ww.buffered().len;
        return changed;
    }
};

/// The panels' settings as a view file: as they are now, and as last saved (at launch: as
/// loaded), to tell whether there is something to save.
pub const ViewFile = struct {
    now: []u8,
    saved: []u8,
    saved_len: usize = 0,

    pub fn init(gpa: std.mem.Allocator, set: *const panels_mod.Set) !ViewFile {
        const now = try gpa.alloc(u8, 96 * 1024);
        errdefer gpa.free(now);
        var self: ViewFile = .{ .now = now, .saved = try gpa.alloc(u8, 96 * 1024) };
        if (files.renderViews(self.saved, set)) |rendered| self.saved_len = rendered.len;
        return self;
    }

    pub fn deinit(self: *ViewFile, gpa: std.mem.Allocator) void {
        gpa.free(self.now);
        gpa.free(self.saved);
    }

    /// The panels differ from what was last saved.
    pub fn unsaved(self: *ViewFile, set: *const panels_mod.Set) bool {
        const rendered = files.renderViews(self.now, set) orelse return false;
        return !std.mem.eql(u8, rendered, self.saved[0..self.saved_len]);
    }

    /// Writes the panels' settings to the view file at `path`.
    pub fn save(self: *ViewFile, io: Io, path: []const u8, set: *const panels_mod.Set) !void {
        const rendered = files.renderViews(self.now, set) orelse return error.ViewTooLarge;
        try files.writeAtomic(io, path, rendered);
        @memcpy(self.saved[0..rendered.len], rendered);
        self.saved_len = rendered.len;
    }
};
