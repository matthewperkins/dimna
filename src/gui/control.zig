//! The control window: an ordinary window (meant for the other monitor) with the status of
//! the run and the settings of every panel of the neural display.
//!
//! It runs on a thread of its own with its own Wayland connection and its own Vulkan
//! instance, so nothing it does (a slow frame, a resize, the compositor holding its frames
//! back) can delay the neural display. The two sides share no lock:
//!
//!   display -> control: a snapshot of the panels and the status (`Shared.publish`, read
//!   with a sequence check: the reader retries if the writer was in the middle);
//!   control -> display: a small queue of edits (`Shared.push` / `pop`), applied by the
//!   display thread between frames, exactly as key presses are.

const std = @import("std");
const oez = @import("oez");
const panels = oez.panels;
const Window = @import("window.zig").Window;
const gpu_mod = @import("gpu.zig");
const font = @import("font.zig");
const ui_mod = @import("ui.zig");
const format = @import("format.zig");
const Atomic = std.atomic.Value;
const log = std.log.scoped(.control);

/// What the display's corner read-out and the control window show; refreshed once a second.
pub const Status = struct {
    valid: bool = false,
    latency_ms: f64 = 0,
    fps: u64 = 0,
    /// Blocks the display missed (the recording does not depend on these).
    lost: u64 = 0,
    recording: bool = false,
    rec_seconds: f64 = 0,
};

/// The recording, as the control window shows it.
pub const RecStatus = struct {
    pub const State = enum { idle, recording, stopping, failed };
    state: State = .idle,
    seconds: f64 = 0,
    samples: u64 = 0,
    bytes: u64 = 0,
    /// How far the recorder is behind acquisition, in seconds of signal.
    behind_s: f64 = 0,
    gaps: u64 = 0,
    /// The session folder (while recording, and of the last recording afterwards).
    path_buf: [200]u8 = undefined,
    path_len: usize = 0,
    /// Why the last attempt failed, or how the last recording ended.
    note_buf: [160]u8 = undefined,
    note_len: usize = 0,

    pub fn path(self: *const RecStatus) []const u8 {
        return self.path_buf[0..self.path_len];
    }
    pub fn note(self: *const RecStatus) []const u8 {
        return self.note_buf[0..self.note_len];
    }
    pub fn setNote(self: *RecStatus, comptime fmt: []const u8, args: anytype) void {
        const text: []const u8 = std.fmt.bufPrint(&self.note_buf, fmt, args) catch "";
        self.note_len = text.len;
    }
};

/// The audio monitor, as the control window shows it.
pub const AudioStatus = struct {
    settings: oez.audio.Settings = .{},
    /// A device is open and both audio threads run.
    running: bool = false,
    /// The held noise sigma of the first channel in µV; 0 while it is measured.
    sigma_uv: f64 = 0,
    latency_ms: f64 = 0,
    underruns: u64 = 0,
    dropped: u64 = 0,
    /// The channels listened to, as text ("A1-5, B1-3").
    listen_buf: [96]u8 = undefined,
    listen_len: usize = 0,
    /// The sound takes the panels' common average references (when they have one).
    car: bool = true,
};

pub const AudioAction = union(enum) {
    enabled: bool,
    mute: bool,
    /// Louder (true) or quieter, 2 dB a step.
    volume: bool,
    reference: bool,
    /// Whether the sound takes the panels' common average references.
    car: bool,
    recalibrate,
};

/// The board's settings, as the control window shows them.
pub const BoardStatus = struct {
    settings: oez.types.Settings = .{},
    /// What the chips actually do for the requested values (they offer steps).
    lower_actual: f64 = 0,
    upper_actual: f64 = 0,
    dsp_actual: f64 = 0,
    /// Sample rate and half-channel choices made but not applied yet (they restart
    /// acquisition); equal to `settings` when there are none.
    pending: oez.types.Settings = .{},
    /// The connected headstages, for the half-channel choice.
    headstages: [8]Headstage = undefined,
    num_headstages: usize = 0,
    /// The settings in use differ from the config file's.
    unsaved: bool = false,
    /// Why the last change was not made.
    note_buf: [120]u8 = undefined,
    note_len: usize = 0,

    pub const Headstage = struct { slot: u8, rhd2132: bool };

    pub fn restartPending(self: *const BoardStatus) bool {
        return self.pending.sample_rate != self.settings.sample_rate or !std.mem.eql(bool, &self.pending.rhd2132_16ch, &self.settings.rhd2132_16ch);
    }

    pub fn setNote(self: *BoardStatus, comptime fmt: []const u8, args: anytype) void {
        const text: []const u8 = std.fmt.bufPrint(&self.note_buf, fmt, args) catch "";
        self.note_len = text.len;
    }
};

/// A change to the board's settings.
pub const BoardAction = union(enum) {
    dsp: bool,
    /// One step up (true) or down through the values offered.
    dsp_cutoff: bool,
    lower: bool,
    upper: bool,
    /// Choices that need a restart: collected, then applied together with `apply`.
    rate: bool,
    /// Toggle half-channel mode of the headstage in this slot.
    half: u8,
    apply,
    /// Write the settings in use to the config file's [board] table.
    save,
};

/// The answer to "the board settings changed; save them?" on quitting.
pub const QuitAnswer = enum { save, discard, cancel };

/// Shown instead of the controls when quitting with changed board settings.
pub const QuitPrompt = struct {
    active: bool = false,
    lines: [12][64]u8 = undefined,
    lens: [12]usize = @splat(0),
    count: usize = 0,
    /// The config file the settings would be saved to.
    path_buf: [200]u8 = undefined,
    path_len: usize = 0,
};

/// "0.58 Hz", "300 Hz", "7.60 kHz".
pub fn fmtHz(buf: []u8, hz: f64) []const u8 {
    return (if (hz >= 1000) std.fmt.bufPrint(buf, "{d:.2} kHz", .{hz / 1000}) else if (hz >= 100) std.fmt.bufPrint(buf, "{d:.0} Hz", .{hz}) else std.fmt.bufPrint(buf, "{d:.2} Hz", .{hz})) catch "";
}

/// "1:05" or "1:02:03".
pub fn fmtClock(buf: []u8, seconds: f64) []const u8 {
    const s: u64 = @intFromFloat(@max(0, seconds));
    return (if (s >= 3600) std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ s / 3600, s / 60 % 60, s % 60 }) else std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ s / 60, s % 60 })) catch "";
}

/// A change to one panel, asked for by the control window.
pub const Action = union(enum) {
    /// Multiply the scale per row.
    scale: f64,
    /// Multiply the time base (triggered mode: the window around the trigger).
    zoom: f64,
    mode: panels.Mode,
    filter: bool,
    corner: struct { high: bool, up: bool },
    trig_line: u8,
    /// The common average reference: on or off, one row in or out of a set, or a whole
    /// set at once (all rows, or none).
    car: bool,
    car_ref_row: usize,
    car_sub_row: usize,
    car_ref_all: bool,
    car_sub_all: bool,
    trig_source: panels.TrigSource,
    /// Move the slope trigger to the next (+1) or previous row.
    trig_row: i32,
    trig_rising: bool,
    /// The level follows the noise (true) or is fixed.
    trig_auto: bool,
    /// Multiply the fixed level.
    trig_level: f64,
    /// One step up (true) or down through the holdoff values.
    trig_holdoff: bool,
    overlay: u32,
    reset,
    /// Start (true) or stop a recording.
    record: bool,
    board: BoardAction,
    audio: AudioAction,
    quit_answer: QuitAnswer,
    quit,
};

pub const Edit = struct { panel: usize = 0, action: Action };

pub const Snapshot = struct {
    set: panels.Set = .{},
    /// The panel that keys and the wheel act on, on the display.
    target: usize = 0,
    status: Status = .{},
    ring_overflow: u64 = 0,
    seconds: f64 = 0,
    rec: RecStatus = .{},
    board: BoardStatus = .{},
    audio: AudioStatus = .{},
    quit_prompt: QuitPrompt = .{},
    /// One line about the source ("Open Ephys acquisition board   56 channels at 30000 Hz").
    about_buf: [160]u8 = undefined,
    about_len: usize = 0,
};

pub const Shared = struct {
    seq: Atomic(u32) = .init(0),
    snap: Snapshot = .{},
    edits: [64]Edit = undefined,
    head: Atomic(usize) = .init(0),
    tail: Atomic(usize) = .init(0),
    /// Set by the display thread to end the control thread.
    stop: Atomic(bool) = .init(false),
    /// Set by the control thread when its window is gone.
    closed: Atomic(bool) = .init(false),

    /// Display thread: makes `snap` the current snapshot.
    pub fn publish(self: *Shared, snap: *const Snapshot) void {
        _ = self.seq.fetchAdd(1, .acq_rel); // odd: being written
        self.snap = snap.*;
        _ = self.seq.fetchAdd(1, .release);
    }

    /// Control thread: copies the current snapshot into `out` if it is newer than `seen`
    /// (which is updated). False if there is nothing new.
    pub fn read(self: *Shared, out: *Snapshot, seen: *u32) bool {
        var tries: usize = 0;
        while (tries < 100) : (tries += 1) {
            const before = self.seq.load(.acquire);
            if (before == seen.*) return false;
            if (before & 1 != 0) {
                std.atomic.spinLoopHint();
                continue;
            }
            const copy = self.snap;
            if (self.seq.load(.acquire) != before) continue;
            out.* = copy;
            seen.* = before;
            return true;
        }
        return false;
    }

    /// Control thread: queues an edit (dropped if the display has not taken the last 63).
    pub fn push(self: *Shared, edit: Edit) void {
        const t = self.tail.load(.monotonic);
        if (t -% self.head.load(.acquire) >= self.edits.len - 1) return;
        self.edits[t % self.edits.len] = edit;
        self.tail.store(t +% 1, .release);
    }

    /// Display thread: the next queued edit.
    pub fn pop(self: *Shared) ?Edit {
        const h = self.head.load(.monotonic);
        if (h == self.tail.load(.acquire)) return null;
        const e = self.edits[h % self.edits.len];
        self.head.store(h +% 1, .release);
        return e;
    }
};

pub const Config = struct {
    gpa: std.mem.Allocator,
    shared: *Shared,
    /// The display's renderer, whose Vulkan instance the control window shares.
    display_gpu: *const gpu_mod.Gpu,
    font_buf: [128:0]u8 = @splat(0),
    font_px: u32 = 14,
};

pub fn spawn(cfg: *Config) ?std.Thread {
    return std.Thread.spawn(.{}, run, .{cfg}) catch |e| {
        log.warn("no control window: {t}", .{e});
        return null;
    };
}

fn run(cfg: *Config) void {
    defer cfg.shared.closed.store(true, .release);
    loop(cfg) catch |e| log.warn("the control window stopped: {t} (the display and its keys carry on)", .{e});
}

fn loop(cfg: *Config) !void {
    const gpa = cfg.gpa;
    const shared = cfg.shared;
    var win: Window = undefined;
    try win.init("oEZ control", "oez-control");
    defer win.deinit();
    var gpu = try gpu_mod.Gpu.init(gpa, .{ .wayland = .{ .display = win.display, .surface = win.surface } }, .fifo, cfg.display_gpu);
    defer gpu.deinit();
    var face = try font.Font.init(gpa, std.mem.sliceTo(&cfg.font_buf, 0), cfg.font_px);
    defer face.deinit(gpa);
    const max_vertices = 24 * 1024;
    const vertices = try gpa.alloc(font.Vertex, max_vertices);
    defer gpa.free(vertices);
    try gpu.createText(face.atlas, font.atlas_size, max_vertices);
    var batch: font.Batch = .{ .font = &face, .vertices = vertices };

    var snap: Snapshot = .{};
    var seen: u32 = 0;
    var dirty = true;
    var clicks: u32 = 0;
    var wheel: f64 = 0;
    var last_x: f64 = -1;
    var last_y: f64 = -1;
    var tag: u64 = 0;
    // For tests: OEZ_CONTROL_CLICKS="SECONDS:X,Y;..." clicks at those pixels of this window.
    var script: []const u8 = if (std.c.getenv("OEZ_CONTROL_CLICKS")) |v| std.mem.span(v) else "";
    const t_start = nowSeconds();
    while (!shared.stop.load(.acquire) and !win.closed) {
        try win.pump(if (dirty or script.len > 0) 20 else 100);
        var in = win.takeInput();
        if (script.len > 0) {
            const end = std.mem.indexOfScalar(u8, script, ';') orelse script.len;
            var it = std.mem.tokenizeAny(u8, script[0..end], ":,");
            const at = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            if (nowSeconds() - t_start >= at) {
                in.pointer_x = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
                in.pointer_y = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
                in.clicks += 1;
                script = script[@min(end + 1, script.len)..];
            }
        }
        _ = win.takePresented();
        clicks += in.clicks;
        wheel += in.scroll_y;
        if (in.clicks > 0 or in.scroll_y != 0 or in.pointer_x != last_x or in.pointer_y != last_y) dirty = true;
        last_x = in.pointer_x;
        last_y = in.pointer_y;
        if (shared.read(&snap, &seen)) dirty = true;
        if (win.resized) dirty = true;
        if (!dirty or !win.frame_ready) continue;

        if (win.resized or gpu.swapchain == .null) {
            try gpu.resize(win.width, win.height);
            win.resized = false;
        }
        var ui: ui_mod.Ui = .begin(&batch, @floatFromInt(gpu.extent.width), @floatCast(in.pointer_x), @floatCast(in.pointer_y), clicks > 0, @floatCast(wheel));
        build(&ui, cfg, &snap, shared);
        clicks = 0;
        wheel = 0;
        tag += 1;
        const Ctx = struct { win: *Window, tag: u64 };
        const result = try gpu.draw(&.{}, &.{}, batch.vertices[0..batch.len], Ctx{ .win = &win, .tag = tag }, struct {
            fn f(c: Ctx) void {
                c.win.beforePresent(c.tag);
            }
        }.f);
        switch (result) {
            .presented => dirty = false,
            .out_of_date => win.resized = true,
            .busy => {},
        }
    }
    if (win.closed) log.info("control window closed; the display and its keys carry on", .{});
}

fn nowSeconds() f64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) / 1e9;
}

/// Describes the whole window for this frame and queues what was clicked.
fn build(ui: *ui_mod.Ui, cfg: *const Config, snap: *const Snapshot, shared: *Shared) void {
    var buf: [160]u8 = undefined;
    const step_up = 1.25;
    _ = cfg;

    ui.text("oEZ", ui_mod.text_bright);
    ui.text(snap.about_buf[0..snap.about_len], ui_mod.text_dim);
    ui.newline();

    if (snap.quit_prompt.active) {
        // Quitting with board settings that differ from the config: nothing else is shown.
        const q = &snap.quit_prompt;
        ui.separator();
        ui.text("The board settings differ from the config file:", ui_mod.text_bright);
        ui.newline();
        for (q.lines[0..q.count], q.lens[0..q.count]) |*line, len| {
            ui.space(16);
            ui.text(line[0..len], ui_mod.text_warn);
            ui.newline();
        }
        ui.text(q.path_buf[0..q.path_len], ui_mod.text_dim);
        ui.newline();
        if (ui.button("Save as default and quit", true)) shared.push(.{ .action = .{ .quit_answer = .save } });
        if (ui.button("Quit without saving", false)) shared.push(.{ .action = .{ .quit_answer = .discard } });
        if (ui.button("Cancel", false)) shared.push(.{ .action = .{ .quit_answer = .cancel } });
        return;
    }

    const st = snap.status;
    if (st.valid) {
        ui.text(std.fmt.bufPrint(&buf, "display {d:.1} ms   {d} fps   running {d:.0} s", .{ st.latency_ms, st.fps, snap.seconds }) catch "", ui_mod.text_dim);
    } else ui.text("starting", ui_mod.text_dim);
    if (st.lost > 0) ui.text(std.fmt.bufPrint(&buf, "display skipped {d} blocks", .{st.lost}) catch "", ui_mod.text_warn);
    if (snap.ring_overflow > 0) ui.text(std.fmt.bufPrint(&buf, "ACQUISITION RING OVERFLOW {d}", .{snap.ring_overflow}) catch "", ui_mod.text_warn);
    ui.x = @max(ui.x, ui.width - 70);
    if (ui.button("Quit", false)) shared.push(.{ .action = .quit });
    ui.newline();
    ui.separator();

    // Recording.
    const rec = &snap.rec;
    switch (rec.state) {
        .idle, .failed => if (ui.button("Record", false)) shared.push(.{ .action = .{ .record = true } }),
        .recording => if (ui.button("Stop recording", true)) shared.push(.{ .action = .{ .record = false } }),
        .stopping => ui.text("finishing the recording", ui_mod.text_dim),
    }
    if (rec.state == .recording or rec.state == .stopping) {
        var clock_buf: [16]u8 = undefined;
        ui.text(std.fmt.bufPrint(&buf, "REC {s}   {d:.2} GB   {d:.1} M samples", .{ fmtClock(&clock_buf, rec.seconds), @as(f64, @floatFromInt(rec.bytes)) / 1e9, @as(f64, @floatFromInt(rec.samples)) / 1e6 }) catch "", ui_mod.text_rec);
        if (rec.behind_s > 1.0) ui.text(std.fmt.bufPrint(&buf, "disk is {d:.1} s behind", .{rec.behind_s}) catch "", ui_mod.text_warn);
        if (rec.gaps > 0) ui.text(std.fmt.bufPrint(&buf, "{d} gaps", .{rec.gaps}) catch "", ui_mod.text_warn);
    } else if (rec.state == .failed) {
        ui.text("RECORDING FAILED", ui_mod.text_warn);
    } else ui.text("not recording", ui_mod.text_dim);
    ui.newline();
    if (rec.note_len > 0) {
        ui.text(rec.note(), if (rec.state == .failed) ui_mod.text_warn else ui_mod.text_dim);
        ui.newline();
    }
    if (rec.path_len > 0) {
        ui.text(rec.path(), ui_mod.text_dim);
        ui.newline();
    }
    ui.separator();

    // The audio monitor.
    const au = &snap.audio;
    ui.text("Audio", ui_mod.text_bright);
    ui.column(64);
    if (ui.button("on", au.settings.enabled) and !au.settings.enabled) shared.push(.{ .action = .{ .audio = .{ .enabled = true } } });
    if (ui.button("off", !au.settings.enabled) and au.settings.enabled) shared.push(.{ .action = .{ .audio = .{ .enabled = false } } });
    if (ui.button("mute", au.settings.mute)) shared.push(.{ .action = .{ .audio = .{ .mute = !au.settings.mute } } });
    const dvol = ui.stepper("volume", std.fmt.bufPrint(&buf, "{d:.0} dB", .{au.settings.volume_db}) catch "", 60);
    if (dvol != 0) shared.push(.{ .action = .{ .audio = .{ .volume = dvol > 0 } } });
    // "plain" is the linear reference chain, for comparing by ear.
    if (ui.button("shaped", !au.settings.reference) and au.settings.reference) shared.push(.{ .action = .{ .audio = .{ .reference = false } } });
    if (ui.button("plain", au.settings.reference) and !au.settings.reference) shared.push(.{ .action = .{ .audio = .{ .reference = true } } });
    if (ui.button("CAR", au.car)) shared.push(.{ .action = .{ .audio = .{ .car = !au.car } } });
    if (ui.button("recalibrate", false)) shared.push(.{ .action = .{ .audio = .recalibrate } });
    ui.newline();
    if (!au.running) {
        ui.text("no audio output", ui_mod.text_dim);
    } else if (au.settings.enabled) {
        ui.text(std.fmt.bufPrint(&buf, "listening to {s}", .{if (au.listen_len > 0) au.listen_buf[0..au.listen_len] else "nothing (click a row on the display)"}) catch "", ui_mod.text_dim);
        if (au.listen_len > 0) {
            if (au.sigma_uv > 0)
                ui.text(std.fmt.bufPrint(&buf, "noise {d:.1} µV, held", .{au.sigma_uv}) catch "", ui_mod.text_dim)
            else
                ui.text("measuring the noise (3 s)", ui_mod.text_warn);
            ui.text(std.fmt.bufPrint(&buf, "{d:.0} ms", .{au.latency_ms}) catch "", ui_mod.text_dim);
        }
        if (au.underruns > 0) ui.text(std.fmt.bufPrint(&buf, "{d} gaps in the sound", .{au.underruns}) catch "", ui_mod.text_dim);
    } else ui.text("off", ui_mod.text_dim);
    ui.newline();
    ui.separator();

    // The headstage chips: these change what is recorded. Both apply without a gap.
    const bd = &snap.board;
    var hz_buf: [24]u8 = undefined;
    ui.text("Headstages", ui_mod.text_bright);
    ui.text("(these change what is recorded)", ui_mod.text_dim);
    ui.newline();
    ui.text("amplifier band", ui_mod.text_dim);
    ui.column(120);
    const dlo = ui.stepper("from", fmtHz(&hz_buf, bd.lower_actual), 80);
    if (dlo != 0) shared.push(.{ .action = .{ .board = .{ .lower = dlo > 0 } } });
    const dhi = ui.stepper("to", fmtHz(&hz_buf, bd.upper_actual), 80);
    if (dhi != 0) shared.push(.{ .action = .{ .board = .{ .upper = dhi > 0 } } });
    ui.newline();
    ui.text("DSP high-pass", ui_mod.text_dim);
    ui.column(120);
    if (ui.button("off", !bd.settings.dsp_enabled) and bd.settings.dsp_enabled) shared.push(.{ .action = .{ .board = .{ .dsp = false } } });
    if (ui.button("on", bd.settings.dsp_enabled) and !bd.settings.dsp_enabled) shared.push(.{ .action = .{ .board = .{ .dsp = true } } });
    if (bd.settings.dsp_enabled) {
        ui.space(14);
        const dc = ui.stepper("cutoff", fmtHz(&hz_buf, bd.dsp_actual), 80);
        if (dc != 0) shared.push(.{ .action = .{ .board = .{ .dsp_cutoff = dc > 0 } } });
    }
    ui.newline();
    // Sample rate and half-channel mode change the shape of the data: chosen here, then
    // applied together by restarting acquisition (not while recording).
    ui.text("sample rate", ui_mod.text_dim);
    ui.column(120);
    const dr = ui.stepper("", std.fmt.bufPrint(&buf, "{d} Hz", .{bd.pending.sample_rate}) catch "", 80);
    if (dr != 0) shared.push(.{ .action = .{ .board = .{ .rate = dr > 0 } } });
    for (bd.headstages[0..bd.num_headstages]) |h| {
        if (!h.rhd2132) continue;
        const half = bd.pending.rhd2132_16ch[h.slot];
        ui.text(oez.types.headstage_names[h.slot], ui_mod.text_dim);
        if (ui.button("32 ch", !half) and half) shared.push(.{ .action = .{ .board = .{ .half = h.slot } } });
        if (ui.button("16 of 32", half) and !half) shared.push(.{ .action = .{ .board = .{ .half = h.slot } } });
        ui.space(8);
    }
    ui.newline();
    if (bd.restartPending()) {
        if (rec.state == .idle or rec.state == .failed) {
            if (ui.button("Apply (restarts acquisition)", true)) shared.push(.{ .action = .{ .board = .apply } });
        } else ui.text("sample rate and channels can change once the recording is stopped", ui_mod.text_warn);
        ui.newline();
    }
    if (bd.unsaved) {
        if (ui.button("Save as default", false)) shared.push(.{ .action = .{ .board = .save } });
        ui.text("these settings differ from the config file", ui_mod.text_dim);
        ui.newline();
    }
    if (bd.note_len > 0) {
        ui.text(bd.note_buf[0..bd.note_len], ui_mod.text_warn);
        ui.newline();
    }
    ui.separator();

    for (snap.set.items[0..snap.set.len], 0..) |*p, i| {
        // Name, and what the panel shows.
        ui.text(p.name(), ui_mod.text_bright);
        ui.text(std.fmt.bufPrint(&buf, "{d} {s} channels", .{ p.rows, switch (p.kind) {
            .electrode => "electrode",
            .aux => "AUX",
            .adc => "ADC",
            .ttl => "TTL",
        } }) catch "", ui_mod.text_dim);
        ui.x = @max(ui.x, ui.width - 78);
        if (ui.button("reset", false)) shared.push(.{ .panel = i, .action = .reset });
        ui.newline();

        ui.text("view", ui_mod.text_dim);
        ui.column(64);
        inline for (.{ panels.Mode.scroll, panels.Mode.sweep, panels.Mode.triggered }) |m| {
            if (ui.button(@tagName(m), p.mode == m) and p.mode != m) shared.push(.{ .panel = i, .action = .{ .mode = m } });
        }
        ui.space(14);
        var value_buf: [48]u8 = undefined;
        const time_text = if (p.mode == .triggered)
            std.fmt.bufPrint(&value_buf, "-{d:.1} / +{d:.1} ms", .{ p.pre_ms, p.post_ms }) catch ""
        else
            format.fmtSpan(&value_buf, p.span_s);
        const dt = ui.stepper(if (p.mode == .triggered) "window" else "time", time_text, 130);
        if (dt != 0) shared.push(.{ .panel = i, .action = .{ .zoom = if (dt > 0) step_up else 1.0 / step_up } });
        if (p.kind != .ttl) {
            var scale_buf: [32]u8 = undefined;
            const ds = ui.stepper("scale", std.fmt.bufPrint(&buf, "{s}/row", .{format.fmtScale(&scale_buf, p)}) catch "", 110);
            if (ds != 0) shared.push(.{ .panel = i, .action = .{ .scale = if (ds > 0) step_up else 1.0 / step_up } });
        }
        ui.newline();

        if (p.kind == .electrode) {
            ui.text("filter", ui_mod.text_dim);
            ui.column(64);
            if (ui.button("raw", !p.filtered) and p.filtered) shared.push(.{ .panel = i, .action = .{ .filter = false } });
            if (ui.button("band", p.filtered) and !p.filtered) shared.push(.{ .panel = i, .action = .{ .filter = true } });
            if (p.filtered) {
                ui.space(14);
                const lo = ui.stepper("from", if (p.band_low_hz > 0) std.fmt.bufPrint(&value_buf, "{d} Hz", .{p.band_low_hz}) catch "" else "off", 80);
                if (lo != 0) shared.push(.{ .panel = i, .action = .{ .corner = .{ .high = false, .up = lo > 0 } } });
                const hi = ui.stepper("to", if (p.band_high_hz > 0) std.fmt.bufPrint(&value_buf, "{d} Hz", .{p.band_high_hz}) catch "" else "off", 80);
                if (hi != 0) shared.push(.{ .panel = i, .action = .{ .corner = .{ .high = true, .up = hi > 0 } } });
            }
            ui.newline();
            // Common average reference: which rows are averaged, which lose the average.
            ui.text("CAR", ui_mod.text_dim);
            ui.column(64);
            if (ui.button("off", !p.car) and p.car) shared.push(.{ .panel = i, .action = .{ .car = false } });
            if (ui.button("on", p.car) and !p.car) shared.push(.{ .panel = i, .action = .{ .car = true } });
            if (p.car) {
                ui.newline();
                inline for (.{ "average of", "subtract from" }, .{ true, false }) |label, is_ref| {
                    const rows = if (is_ref) &p.car_ref else &p.car_sub;
                    ui.text(label, ui_mod.text_dim);
                    ui.column(104);
                    const saved_indent = ui.indent;
                    ui.indent = 104;
                    if (ui.button("all", false)) shared.push(.{ .panel = i, .action = if (is_ref) .{ .car_ref_all = true } else .{ .car_sub_all = true } });
                    if (ui.button("none", false)) shared.push(.{ .panel = i, .action = if (is_ref) .{ .car_ref_all = false } else .{ .car_sub_all = false } });
                    ui.space(6);
                    for (0..@min(p.rows, panels.max_rows)) |r| {
                        var nb: [8]u8 = undefined;
                        if (ui.chip(std.fmt.bufPrint(&nb, "{d}", .{r + 1}) catch "", rows.has(r))) shared.push(.{ .panel = i, .action = if (is_ref) .{ .car_ref_row = r } else .{ .car_sub_row = r } });
                    }
                    ui.indent = saved_indent;
                    ui.newline();
                }
            } else ui.newline();
        }
        if (p.mode == .triggered) {
            ui.text("trigger", ui_mod.text_dim);
            ui.column(64);
            if (p.kind == .electrode) {
                if (ui.button("TTL", p.trig_source == .ttl) and p.trig_source != .ttl) shared.push(.{ .panel = i, .action = .{ .trig_source = .ttl } });
                if (ui.button("spikes", p.trig_source == .channel) and p.trig_source != .channel) shared.push(.{ .panel = i, .action = .{ .trig_source = .channel } });
                ui.space(8);
            }
            if (p.trig_source == .ttl) {
                const dl = ui.stepper("", std.fmt.bufPrint(&value_buf, "TTL {d}", .{p.trig_line}) catch "", 60);
                if (dl != 0) shared.push(.{ .panel = i, .action = .{ .trig_line = @intCast(std.math.clamp(@as(i32, p.trig_line) + dl, 1, 8)) } });
            } else {
                const dw = ui.stepper("", std.fmt.bufPrint(&value_buf, "row {d}", .{p.trig_row + 1}) catch "", 60);
                if (dw != 0) shared.push(.{ .panel = i, .action = .{ .trig_row = dw } });
                if (ui.button("falling", !p.trig_rising) and p.trig_rising) shared.push(.{ .panel = i, .action = .{ .trig_rising = false } });
                if (ui.button("rising", p.trig_rising) and !p.trig_rising) shared.push(.{ .panel = i, .action = .{ .trig_rising = true } });
                ui.newline();
                ui.text("level", ui_mod.text_dim);
                ui.column(64);
                if (ui.button("follows noise", p.trig_auto) and !p.trig_auto) shared.push(.{ .panel = i, .action = .{ .trig_auto = true } });
                if (ui.button("fixed", !p.trig_auto) and p.trig_auto) shared.push(.{ .panel = i, .action = .{ .trig_auto = false } });
                if (p.trig_auto) {
                    ui.text(std.fmt.bufPrint(&value_buf, "{d:.0} µV", .{p.trig_level_now_uv}) catch "", ui_mod.text_bright);
                } else {
                    // "+" makes the level larger in size, whichever its sign.
                    const dv = ui.stepper("", std.fmt.bufPrint(&value_buf, "{d:.0} µV", .{p.trig_level_uv}) catch "", 70);
                    if (dv != 0) shared.push(.{ .panel = i, .action = .{ .trig_level = if (dv > 0) 1.15 else 1.0 / 1.15 } });
                }
                const dh = ui.stepper("holdoff", std.fmt.bufPrint(&value_buf, "{d} ms", .{p.trig_holdoff_ms}) catch "", 60);
                if (dh != 0) shared.push(.{ .panel = i, .action = .{ .trig_holdoff = dh > 0 } });
            }
            const dn = ui.stepper("overlaid", std.fmt.bufPrint(&value_buf, "{d} sweeps", .{p.overlay}) catch "", 90);
            if (dn != 0) shared.push(.{ .panel = i, .action = .{ .overlay = @intCast(std.math.clamp(@as(i32, @intCast(p.overlay)) + dn, 1, oez.sweeps.max_sweeps)) } });
            ui.newline();
        }
        ui.separator();
    }
    ui.text("On the display: wheel = scale, Ctrl+wheel = one row, Shift+wheel = time,", ui_mod.text_dim);
    ui.newline();
    ui.text("keys  - =  [ ]  m  t  f  , .  ; '  r  q", ui_mod.text_dim);
}

const testing = std.testing;

test "edits queue and snapshots cross between the two sides" {
    var shared: Shared = .{};
    try testing.expectEqual(null, shared.pop());
    shared.push(.{ .panel = 2, .action = .{ .scale = 1.25 } });
    shared.push(.{ .action = .quit });
    try testing.expectEqual(2, shared.pop().?.panel);
    try testing.expect(shared.pop().?.action == .quit);
    try testing.expectEqual(null, shared.pop());
    // A full queue drops the newest instead of overwriting.
    for (0..200) |i| shared.push(.{ .panel = i, .action = .reset });
    var n: usize = 0;
    while (shared.pop()) |e| : (n += 1) try testing.expectEqual(n, e.panel);
    try testing.expectEqual(63, n);

    var out: Snapshot = .{};
    var seen: u32 = 0;
    try testing.expect(!shared.read(&out, &seen));
    var snap: Snapshot = .{ .target = 3 };
    snap.status.fps = 300;
    shared.publish(&snap);
    try testing.expect(shared.read(&out, &seen));
    try testing.expectEqual(3, out.target);
    try testing.expectEqual(300, out.status.fps);
    try testing.expect(!shared.read(&out, &seen));
}
