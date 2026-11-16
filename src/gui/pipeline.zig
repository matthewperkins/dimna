//! Everything whose shape follows the source's channel layout: the acquisition ring, the
//! acquisition thread, the display's reader and block, the feed that prepares rows for the
//! GPU, the panels, the GPU's sample history, and the two consumers that read the ring on
//! threads of their own (the audio monitor and the spike tiles).
//!
//! It is put together by one function, `assemble`, at start-up and again whenever
//! acquisition is restarted with another sample rate or channel set, so the two cannot
//! come to differ. `assemble` makes every new part before it lets go of an old one: if
//! something cannot be made, what was there is still whole.
//!
//! A `Pipeline` must stay where it is once `init` has run: the acquisition thread, the
//! audio monitor and the tiles hold pointers into it.

const std = @import("std");
const dimna = @import("dimna");
const gpu_mod = @import("gpu.zig");
const audio_out = @import("audio_out.zig");
const tiles_mod = @import("tiles.zig");
const display_mod = @import("display.zig");
const session = @import("session.zig");
const Args = @import("args.zig").Args;
const Env = @import("env.zig").Env;
const Display = display_mod.Display;
const Panel = dimna.panels.Panel;
const Io = std.Io;
const log = std.log.scoped(.dimna);

pub const Pipeline = struct {
    // For the whole run.
    gpa: std.mem.Allocator,
    io: Io,
    source: dimna.source.Source,
    args: *const Args,
    env: *const Env,
    gpu: *gpu_mod.Gpu,
    health: *dimna.types.Health,
    audio_shared: *audio_out.Shared,
    tiles_shared: *tiles_mod.Shared,

    // Made by `assemble`; these change when acquisition is restarted.
    layout: dimna.types.Layout = undefined,
    /// Channels per sample, the sample rate, and samples per block.
    nch: usize = 0,
    fs: f64 = 0,
    bs: usize = 0,
    /// 30 s of blocks: what the recorder may fall behind (a stalled disk) before samples
    /// are lost. The display reads it without holding anything back.
    ring: dimna.ring.BlockRing = undefined,
    acq: dimna.acquisition.Acquisition = undefined,
    reader: dimna.ring.LossyReader = undefined,
    blk: dimna.types.Block = undefined,
    display: Display = undefined,
    feed: dimna.feed.Feed = undefined,
    assembled: bool = false,

    // The threads, between `run` and `halt`.
    running: bool = false,
    audio_dev: ?*audio_out.AudioOut = null,
    tiles_win: ?*tiles_mod.Tiles = null,

    /// Puts the pipeline together for the source as it is configured now, the display with
    /// `thresholds`. Starts nothing. `error.BadPanels`: the config's panels do not fit the
    /// source (already reported).
    pub fn init(self: *Pipeline, thresholds: dimna.thresholds.Thresholds) !void {
        var audio: dimna.audio.Settings = .{};
        audio.volume_db = self.args.volume_db;
        try self.assemble(null, audio, thresholds, true);
    }

    /// Stops the threads and frees everything.
    pub fn deinit(self: *Pipeline) void {
        self.halt();
        if (!self.assembled) return;
        self.feed.deinit(self.gpa);
        self.blk.deinit(self.gpa);
        self.acq.scratch.deinit(self.gpa);
        self.ring.deinit(self.gpa);
        self.assembled = false;
    }

    /// Starts acquisition, then the audio monitor and the tiles (if they are wanted).
    pub fn run(self: *Pipeline) !void {
        try self.acq.start();
        self.running = true;
        if (self.args.audio)
            self.audio_dev = audio_out.AudioOut.start(self.gpa, self.audio_shared, &self.ring, self.fs, self.nch, self.bs, .{ .output = self.args.audio_output });
        if (self.args.tiles) self.tiles_win = tiles_mod.Tiles.start(
            self.gpa,
            self.tiles_shared,
            &self.ring,
            &self.layout,
            self.bs,
            self.gpu,
            self.args.font,
            self.args.font_px,
            self.env,
        );
    }

    /// Stops the tiles and the audio monitor (they read the ring), then acquisition.
    pub fn halt(self: *Pipeline) void {
        if (self.tiles_win) |t| t.stop();
        self.tiles_win = null;
        if (self.audio_dev) |a| a.stop();
        self.audio_dev = null;
        if (self.running) self.acq.join();
        self.running = false;
    }

    /// Stops acquisition, gives the source `settings` (another sample rate or channel
    /// set), and starts again with everything that depends on the shape of the data made
    /// anew. If the source refuses the settings it is put back as it was, and the error is
    /// returned as a value: acquisition is running again either way. An error returned as
    /// an error means it is not.
    pub fn restart(self: *Pipeline, settings: dimna.types.Settings) !?anyerror {
        self.halt();
        const before = self.source.settings();
        var refused: ?anyerror = null;
        applyToSource(self.source, settings) catch |err| {
            log.err("the board refused the new settings ({t}); going back", .{err});
            refused = err;
            try applyToSource(self.source, before);
        };
        // The panels again from the config (their sources may have moved), keeping what
        // was set by hand where the panels still correspond. Channel numbers mean
        // something else now, so the sound goes back to the first channel. The thresholds
        // are kept as they are, channel by channel (as the tile window's view is).
        const old_set = self.display.set;
        try self.assemble(&old_set, self.display.audio, self.display.thresholds, false);
        log.info("restarted: {d} channels ({d} electrode) at {d} Hz", .{ self.nch, self.layout.num_electrodes, self.fs });
        try self.run();
        return refused;
    }

    /// Makes every part for the source's present layout, then replaces the old ones.
    /// `carry`: the panels as they were, whose hand-set values are kept where the new
    /// panels correspond. `strict`: panels that do not fit the source are an error
    /// (start-up); otherwise the default panels take their place (a restart must go on).
    /// `thresholds`: the detection thresholds the new display starts with.
    fn assemble(
        self: *Pipeline,
        carry: ?*const dimna.panels.Set,
        audio: dimna.audio.Settings,
        thresholds: dimna.thresholds.Thresholds,
        strict: bool,
    ) !void {
        const gpa = self.gpa;
        const layout = self.source.layout();
        const nch = layout.numChannels();
        const fs = layout.sample_rate;
        const bs = self.source.settings().block_samples;

        var ring = try dimna.ring.BlockRing.init(gpa, ringSlots(fs, bs, self.env.ring_seconds), nch, bs);
        errdefer ring.deinit(gpa);
        var scratch = try dimna.types.Block.init(gpa, nch, bs);
        errdefer scratch.deinit(gpa);
        var blk = try dimna.types.Block.init(gpa, nch, bs);
        errdefer blk.deinit(gpa);
        var display = display_mod.makeDisplay(self.args.*, &layout) orelse
            if (strict) return error.BadPanels else Display.init(dimna.panels.default(&layout, .scroll));
        if (carry) |old| session.carryOver(&display.set, old);
        // The longest time base plus a margin, so new samples never overwrite what is drawn.
        // A sweep shows two passes: the buckets, and the feed's raw copy for refiltering,
        // hold twice that. The samples themselves are only read at short time bases and
        // by triggered sweeps: 8 s of them is the least that will do.
        const history_samples: usize = @intFromFloat((Panel.span_max + 2.0) * fs);
        const sweep_samples: usize = @intFromFloat((2.0 * Panel.span_max + 2.0) * fs);
        const least_samples: usize = @intFromFloat(8.0 * fs);
        var feed = try dimna.feed.Feed.init(gpa, &layout, &display.set, sweep_samples, bs);
        errdefer feed.deinit(gpa);
        // `r` goes back to the config's values, in the slots the feed has just given out.
        const config_set = display.initial;
        display.initial = display.set;
        for (display.initial.slice(), config_set.items[0..config_set.len], display.set.items[0..display.set.len]) |*i, *c, *p| {
            i.* = c.*;
            i.slot = p.slot;
        }
        try self.gpu.createHistory(feed.width, history_samples, least_samples, sweep_samples);
        feed.dec = &self.gpu.dec;

        // Everything is made: let go of the old parts and take the new.
        if (self.assembled) {
            self.feed.deinit(gpa);
            self.blk.deinit(gpa);
            self.acq.scratch.deinit(gpa);
            self.ring.deinit(gpa);
        }
        self.layout = layout;
        self.nch = nch;
        self.fs = fs;
        self.bs = bs;
        self.ring = ring;
        self.acq = .{ .io = self.io, .source = self.source, .ring = &self.ring, .health = self.health, .scratch = scratch };
        self.blk = blk;
        self.reader = dimna.ring.LossyReader.init(&self.ring);
        self.feed = feed;
        self.display = display;
        self.assembled = true;

        self.display.audio = audio;
        self.display.thresholds = thresholds;
        self.display.listenToFirst();
        self.audio_shared.publish(&self.display.audio);
        self.tiles_shared.publish(&self.display.tileConfig());
    }
};

/// Blocks in the acquisition ring: `seconds` of signal (`Env.ring_seconds`: 30 unless a
/// test shortens it), which is how far the recorder may fall behind before samples are
/// lost.
fn ringSlots(fs: f64, block_samples: usize, seconds: f64) usize {
    return @intFromFloat(@ceil(seconds * fs / @as(f64, @floatFromInt(block_samples))));
}

/// Gives a stopped source new settings.
fn applyToSource(source: dimna.source.Source, settings: dimna.types.Settings) !void {
    switch (source) {
        .board => |b| try b.applySettings(settings),
        .sim => |s| try s.applySettings(settings),
    }
}
