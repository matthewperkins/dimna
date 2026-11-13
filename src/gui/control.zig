//! The control window: an ordinary window (meant for the other monitor) with the status of
//! the run and the settings of every panel of the neural display.
//!
//! It runs on a thread of its own with its own Wayland connection and its own Vulkan
//! instance, so nothing it does (a slow frame, a resize, the compositor holding its frames
//! back) can delay the neural display. The two sides share no lock:
//!
//!   display -> control: a snapshot of the panels and the status (`Shared.publish`, a
//!   `Published` value, see published.zig);
//!   control -> display: a small queue of edits (`Shared.push` / `pop`), applied by the
//!   display thread between frames, exactly as key presses are.

const std = @import("std");
const oez = @import("oez");
const panels = oez.panels;
const Window = @import("window.zig").Window;
const gpu_mod = @import("gpu.zig");
const font = @import("font.zig");
const ui_mod = @import("ui.zig");
const theme = @import("theme.zig");
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
        self.note_len = format.fmt(&self.note_buf, fmt, args).len;
    }
};

/// Scroll-back review, as the control window shows it.
pub const ReviewStatus = struct {
    active: bool = false,
    /// How far the view's right edge is behind the newest sample, and where it is in the
    /// run, in seconds.
    behind_s: f64 = 0,
    at_s: f64 = 0,
    /// Reading from the recording's file (else: the last seconds the display holds).
    from_file: bool = false,
    loading: bool = false,
};

pub const ReviewAction = enum { toggle, back, forward, page_back, page_forward, start, live };

/// Notes, as the control window shows them.
pub const NotesStatus = struct {
    pub const Line = struct {
        seconds: f64 = 0,
        buf: [72]u8 = undefined,
        len: usize = 0,
    };
    /// A note is being typed on the display.
    editing: bool = false,
    num_drafts: usize = 0,
    total: u64 = 0,
    /// The newest notes, newest first.
    recent: [3]Line = @splat(.{}),
    num_recent: usize = 0,
    /// The presets' texts (cut), "" where there is none.
    presets: [9]Line = @splat(.{}),
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
        return self.pending.sample_rate != self.settings.sample_rate or
            !std.mem.eql(bool, &self.pending.rhd2132_16ch, &self.settings.rhd2132_16ch);
    }

    pub fn setNote(self: *BoardStatus, comptime fmt: []const u8, args: anytype) void {
        self.note_len = format.fmt(&self.note_buf, fmt, args).len;
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
    changes: oez.board_config.Diff = .{},
    /// The config file the settings would be saved to.
    path_buf: [200]u8 = undefined,
    path_len: usize = 0,
};

/// "0.58 Hz", "300 Hz", "7.60 kHz".
pub fn fmtHz(buf: []u8, hz: f64) []const u8 {
    return if (hz >= 1000)
        format.fmt(buf, "{d:.2} kHz", .{hz / 1000})
    else if (hz >= 100)
        format.fmt(buf, "{d:.0} Hz", .{hz})
    else
        format.fmt(buf, "{d:.2} Hz", .{hz});
}

/// "1:05" or "1:02:03".
pub fn fmtClock(buf: []u8, seconds: f64) []const u8 {
    const s: u64 = @intFromFloat(@max(0, seconds));
    return if (s >= 3600)
        format.fmt(buf, "{d}:{d:0>2}:{d:0>2}", .{ s / 3600, s / 60 % 60, s % 60 })
    else
        format.fmt(buf, "{d}:{d:0>2}", .{ s / 60, s % 60 });
}

/// A change to one panel, asked for by the control window.
pub const PanelAction = union(enum) {
    /// Multiply the scale per row.
    scale: f64,
    /// Multiply the time base (triggered mode: the window around the trigger).
    zoom: f64,
    mode: panels.Mode,
    filter: bool,
    corner: struct { high: bool, up: bool },
    trig_line: u8,
    /// Show or hide a row; show a row as it is although the panel's filter is on.
    row_hidden: usize,
    row_raw: usize,
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
};

/// What a click in the control window asks for, by who carries it out. The display's loop
/// switches on this once (main.zig), so a new case does not compile until it is handled.
pub const Edit = union(enum) {
    /// A change to one panel (the display's own settings).
    panel: struct { index: usize, action: PanelAction },
    audio: AudioAction,
    board: BoardAction,
    /// Start (true) or stop a recording.
    record: bool,
    review: ReviewAction,
    /// Stamp this preset note (1 to 9) now.
    note_preset: u8,
    /// The user has seen the alarm banner.
    acknowledge,
    /// Write the panels' settings to the view file.
    save_view,
    quit_answer: QuitAnswer,
    quit,
};

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
    notes: NotesStatus = .{},
    review: ReviewStatus = .{},
    /// The panels' settings differ from the view file (or, with none, from launch).
    view_unsaved: bool = false,
    quit_prompt: QuitPrompt = .{},
    /// One line about the source ("Open Ephys acquisition board   56 channels at 30000 Hz").
    about_buf: [160]u8 = undefined,
    about_len: usize = 0,
};

pub const Shared = struct {
    snap: oez.published.Published(Snapshot) = .{},
    edits: [64]Edit = undefined,
    head: Atomic(usize) = .init(0),
    tail: Atomic(usize) = .init(0),
    /// Set by the display thread to end the control thread.
    stop: Atomic(bool) = .init(false),
    /// Set by the control thread when its window is gone.
    closed: Atomic(bool) = .init(false),

    /// Display thread: makes `snap` the current snapshot.
    pub fn publish(self: *Shared, snap: *const Snapshot) void {
        self.snap.publish(snap);
    }

    /// Control thread: copies the current snapshot into `out` if it is newer than `seen`
    /// (which is updated). False if there is nothing new.
    pub fn read(self: *Shared, out: *Snapshot, seen: *u32) bool {
        return self.snap.read(out, seen);
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
    // OEZ_APP_ID gives test runs a window class of their own (one too long for the buffer
    // gives the usual class).
    var class_buf: [64]u8 = undefined;
    const class = std.fmt.bufPrintSentinel(
        &class_buf,
        "{s}-control",
        .{if (std.c.getenv("OEZ_APP_ID")) |v| std.mem.span(v) else "oez"},
        0,
    ) catch "oez-control";
    try win.init("oEZ control", class);
    defer win.deinit();
    var gpu = try gpu_mod.Gpu.init(gpa, .{ .display = win.display, .surface = win.surface }, .fifo, cfg.display_gpu);
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
            // A number that does not parse reads as 0 (a test script's mistake).
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
        var ui: ui_mod.Ui = .begin(
            &batch,
            @floatFromInt(gpu.extent.width),
            @floatCast(in.pointer_x),
            @floatCast(in.pointer_y),
            clicks > 0,
            @floatCast(wheel),
        );
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
    return @as(f64, @floatFromInt(oez.clock.nowNs())) / 1e9;
}

/// Describes the whole window for this frame and queues what was clicked. The order of the
/// calls (and of the `ui.*` calls in each) is the layout.
fn build(ui: *ui_mod.Ui, cfg: *const Config, snap: *const Snapshot, shared: *Shared) void {
    _ = cfg;
    titleSection(ui, snap, shared);
    if (snap.quit_prompt.active) {
        // Quitting with board settings that differ from the config: nothing else is shown.
        quitPrompt(ui, &snap.quit_prompt, shared);
        return;
    }
    statusSection(ui, snap, shared);
    recordSection(ui, &snap.rec, shared);
    reviewSection(ui, &snap.review, shared);
    notesSection(ui, &snap.notes, shared);
    audioSection(ui, &snap.audio, shared);
    boardSection(ui, &snap.board, snap.rec.state, shared);
    for (snap.set.items[0..snap.set.len], 0..) |*p, i| panelSection(ui, p, i, shared);
    ui.text("On the display: wheel = scale, Ctrl+wheel = one row, Shift+wheel = time,", theme.text_dim);
    ui.newline();
    ui.text("keys  - =  [ ]  m  t  f  , .  ; '  r  q", theme.text_dim);
}

/// Multiplies the scale or the time base, one stepper click.
const step_up = 1.25;

/// The name, the source, and the alarm (or a warning).
fn titleSection(ui: *ui_mod.Ui, snap: *const Snapshot, shared: *Shared) void {
    ui.text("oEZ", theme.text_bright);
    ui.text(snap.about_buf[0..snap.about_len], theme.text_dim);
    ui.newline();
    if (snap.status.alarm_len > 0) {
        // The same alarm as across the display, until acknowledged.
        ui.batch.rect(0, ui.y - 2, ui.width, ui.rowHeight() + 2, theme.alarm_bar);
        ui.text(snap.status.alarm(), theme.text_bright);
        ui.x = @max(ui.x, ui.width - 130);
        if (ui.button("Acknowledge", false)) shared.push(.acknowledge);
        ui.newline();
    } else if (snap.status.warning_len > 0) {
        ui.text(snap.status.warning(), theme.text_warn);
        ui.newline();
    }
}

/// Shown instead of everything below the title when quitting with changed board settings.
fn quitPrompt(ui: *ui_mod.Ui, q: *const QuitPrompt, shared: *Shared) void {
    ui.separator();
    ui.text("Settings changed since they were last saved:", theme.text_bright);
    ui.newline();
    for (0..q.changes.count) |i| {
        ui.space(16);
        ui.text(q.changes.line(i), theme.text_warn);
        ui.newline();
    }
    ui.text(q.path_buf[0..q.path_len], theme.text_dim);
    ui.newline();
    if (ui.button("Save as default and quit", true)) shared.push(.{ .quit_answer = .save });
    if (ui.button("Quit without saving", false)) shared.push(.{ .quit_answer = .discard });
    if (ui.button("Cancel", false)) shared.push(.{ .quit_answer = .cancel });
}

/// The display's latency and losses, and Save view / Quit.
fn statusSection(ui: *ui_mod.Ui, snap: *const Snapshot, shared: *Shared) void {
    var buf: [160]u8 = undefined;
    const st = snap.status;
    if (st.valid) {
        ui.text(
            format.fmt(&buf, "display {d:.1} ms   {d} fps   running {d:.0} s", .{ st.latency_ms, st.fps, snap.seconds }),
            theme.text_dim,
        );
    } else ui.text("starting", theme.text_dim);
    if (st.lost > 0) ui.text(format.fmt(&buf, "display skipped {d} blocks", .{st.lost}), theme.text_warn);
    if (snap.ring_overflow > 0) ui.text(format.fmt(&buf, "ACQUISITION RING OVERFLOW {d}", .{snap.ring_overflow}), theme.text_warn);
    ui.x = @max(ui.x, ui.width - 170);
    // Lit while the panels' settings differ from what is saved.
    if (ui.button("Save view", snap.view_unsaved)) shared.push(.save_view);
    if (ui.button("Quit", false)) shared.push(.quit);
    ui.newline();
    ui.separator();
}

/// Recording.
fn recordSection(ui: *ui_mod.Ui, rec: *const RecStatus, shared: *Shared) void {
    var buf: [160]u8 = undefined;
    switch (rec.state) {
        .idle, .failed => if (ui.button("Record", false)) shared.push(.{ .record = true }),
        .recording => if (ui.button("Stop recording", true)) shared.push(.{ .record = false }),
        .stopping => ui.text("finishing the recording", theme.text_dim),
    }
    if (rec.state == .recording or rec.state == .stopping) {
        var clock_buf: [16]u8 = undefined;
        ui.text(
            format.fmt(&buf, "REC {s}   {d:.2} GB   {d:.1} M samples", .{
                fmtClock(&clock_buf, rec.seconds),
                @as(f64, @floatFromInt(rec.bytes)) / 1e9,
                @as(f64, @floatFromInt(rec.samples)) / 1e6,
            }),
            theme.text_rec,
        );
        if (rec.behind_s > 1.0) ui.text(format.fmt(&buf, "disk is {d:.1} s behind", .{rec.behind_s}), theme.text_warn);
        if (rec.gaps > 0) ui.text(format.fmt(&buf, "{d} gaps", .{rec.gaps}), theme.text_warn);
    } else if (rec.state == .failed) {
        ui.text("RECORDING FAILED", theme.text_warn);
    } else ui.text("not recording", theme.text_dim);
    ui.newline();
    if (rec.note_len > 0) {
        ui.text(rec.note(), if (rec.state == .failed) theme.text_warn else theme.text_dim);
        ui.newline();
    }
    if (rec.path_len > 0) {
        ui.text(rec.path(), theme.text_dim);
        ui.newline();
    }
    ui.separator();
}

/// Scroll-back review.
fn reviewSection(ui: *ui_mod.Ui, rv: *const ReviewStatus, shared: *Shared) void {
    var buf: [160]u8 = undefined;
    ui.text("Review", theme.text_bright);
    ui.column(64);
    if (ui.button("start", false)) shared.push(.{ .review = .start });
    if (ui.button("<< window", false)) shared.push(.{ .review = .page_back });
    if (ui.button("<", false)) shared.push(.{ .review = .back });
    if (ui.button(if (rv.active) "frozen" else "freeze", rv.active)) shared.push(.{ .review = .toggle });
    if (ui.button(">", false)) shared.push(.{ .review = .forward });
    if (ui.button("window >>", false)) shared.push(.{ .review = .page_forward });
    if (ui.button("LIVE", !rv.active) and rv.active) shared.push(.{ .review = .live });
    if (rv.active) {
        var c1: [16]u8 = undefined;
        ui.text(
            format.fmt(&buf, "{d:.1} s behind, at {s}{s}{s}", .{
                rv.behind_s,
                fmtClock(&c1, rv.at_s),
                if (rv.from_file) "" else " (last seconds only: not recording)",
                if (rv.loading) " ..." else "",
            }),
            theme.text_warn,
        );
    }
    ui.newline();
    ui.separator();
}

/// Notes: the presets as buttons, and the newest notes.
fn notesSection(ui: *ui_mod.Ui, nt: *const NotesStatus, shared: *Shared) void {
    var buf: [160]u8 = undefined;
    ui.text("Notes", theme.text_bright);
    ui.column(64);
    var any_preset = false;
    for (&nt.presets, 1..) |*pr, n| {
        if (pr.len == 0) continue;
        any_preset = true;
        if (ui.button(format.fmt(&buf, "{d} {s}", .{ n, pr.buf[0..pr.len] }), false))
            shared.push(.{ .note_preset = @intCast(n) });
    }
    if (!any_preset) ui.text("on the display: / types a note, Enter saves it", theme.text_dim);
    if (nt.editing) ui.text("typing a note", theme.text_warn);
    if (nt.num_drafts > 0) ui.text(format.fmt(&buf, "{d} drafts (` stamps one)", .{nt.num_drafts}), theme.text_dim);
    ui.newline();
    for (nt.recent[0..nt.num_recent]) |*line| {
        var clock_buf: [16]u8 = undefined;
        ui.space(16);
        ui.text(format.fmt(&buf, "{s}  {s}", .{ fmtClock(&clock_buf, line.seconds), line.buf[0..line.len] }), theme.text_dim);
        ui.newline();
    }
    ui.separator();
}

/// The audio monitor.
fn audioSection(ui: *ui_mod.Ui, au: *const AudioStatus, shared: *Shared) void {
    var buf: [160]u8 = undefined;
    ui.text("Audio", theme.text_bright);
    ui.column(64);
    if (ui.button("on", au.settings.enabled) and !au.settings.enabled) shared.push(.{ .audio = .{ .enabled = true } });
    if (ui.button("off", !au.settings.enabled) and au.settings.enabled) shared.push(.{ .audio = .{ .enabled = false } });
    if (ui.button("mute", au.settings.mute)) shared.push(.{ .audio = .{ .mute = !au.settings.mute } });
    const dvol = ui.stepper("volume", format.fmt(&buf, "{d:.0} dB", .{au.settings.volume_db}), 60);
    if (dvol != 0) shared.push(.{ .audio = .{ .volume = dvol > 0 } });
    // "plain" is the linear reference chain, for comparing by ear.
    if (ui.button("shaped", !au.settings.reference) and au.settings.reference)
        shared.push(.{ .audio = .{ .reference = false } });
    if (ui.button("plain", au.settings.reference) and !au.settings.reference)
        shared.push(.{ .audio = .{ .reference = true } });
    if (ui.button("CAR", au.car)) shared.push(.{ .audio = .{ .car = !au.car } });
    if (ui.button("recalibrate", false)) shared.push(.{ .audio = .recalibrate });
    ui.newline();
    if (!au.running) {
        ui.text("no audio output", theme.text_dim);
    } else if (au.settings.enabled) {
        ui.text(
            format.fmt(
                &buf,
                "listening to {s}",
                .{if (au.listen_len > 0) au.listen_buf[0..au.listen_len] else "nothing (click a row on the display)"},
            ),
            theme.text_dim,
        );
        if (au.listen_len > 0) {
            if (au.sigma_uv > 0)
                ui.text(format.fmt(&buf, "noise {d:.1} µV, held", .{au.sigma_uv}), theme.text_dim)
            else
                ui.text("measuring the noise (3 s)", theme.text_warn);
            ui.text(format.fmt(&buf, "{d:.0} ms", .{au.latency_ms}), theme.text_dim);
        }
        if (au.underruns > 0) ui.text(format.fmt(&buf, "{d} gaps in the sound", .{au.underruns}), theme.text_dim);
    } else ui.text("off", theme.text_dim);
    ui.newline();
    ui.separator();
}

/// The headstage chips: these change what is recorded. The amplifier band and the DSP
/// apply without a gap; the sample rate and half-channel mode need a restart, which waits
/// while `rec` records.
fn boardSection(ui: *ui_mod.Ui, bd: *const BoardStatus, rec: RecStatus.State, shared: *Shared) void {
    var buf: [160]u8 = undefined;
    var hz_buf: [24]u8 = undefined;
    ui.text("Headstages", theme.text_bright);
    ui.text("(these change what is recorded)", theme.text_dim);
    ui.newline();
    ui.text("amplifier band", theme.text_dim);
    ui.column(120);
    const dlo = ui.stepper("from", fmtHz(&hz_buf, bd.lower_actual), 80);
    if (dlo != 0) shared.push(.{ .board = .{ .lower = dlo > 0 } });
    const dhi = ui.stepper("to", fmtHz(&hz_buf, bd.upper_actual), 80);
    if (dhi != 0) shared.push(.{ .board = .{ .upper = dhi > 0 } });
    ui.newline();
    ui.text("DSP high-pass", theme.text_dim);
    ui.column(120);
    if (ui.button("off", !bd.settings.dsp_enabled) and bd.settings.dsp_enabled) shared.push(.{ .board = .{ .dsp = false } });
    if (ui.button("on", bd.settings.dsp_enabled) and !bd.settings.dsp_enabled) shared.push(.{ .board = .{ .dsp = true } });
    if (bd.settings.dsp_enabled) {
        ui.space(14);
        const dc = ui.stepper("cutoff", fmtHz(&hz_buf, bd.dsp_actual), 80);
        if (dc != 0) shared.push(.{ .board = .{ .dsp_cutoff = dc > 0 } });
    }
    ui.newline();
    // Sample rate and half-channel mode change the shape of the data: chosen here, then
    // applied together by restarting acquisition (not while recording).
    ui.text("sample rate", theme.text_dim);
    ui.column(120);
    const dr = ui.stepper("", format.fmt(&buf, "{d} Hz", .{bd.pending.sample_rate}), 80);
    if (dr != 0) shared.push(.{ .board = .{ .rate = dr > 0 } });
    for (bd.headstages[0..bd.num_headstages]) |h| {
        if (!h.rhd2132) continue;
        const half = bd.pending.rhd2132_16ch[h.slot];
        ui.text(oez.types.headstage_names[h.slot], theme.text_dim);
        if (ui.button("32 ch", !half) and half) shared.push(.{ .board = .{ .half = h.slot } });
        if (ui.button("16 of 32", half) and !half) shared.push(.{ .board = .{ .half = h.slot } });
        ui.space(8);
    }
    ui.newline();
    if (bd.restartPending()) {
        if (rec == .idle or rec == .failed) {
            if (ui.button("Apply (restarts acquisition)", true)) shared.push(.{ .board = .apply });
        } else ui.text("sample rate and channels can change once the recording is stopped", theme.text_warn);
        ui.newline();
    }
    if (bd.unsaved) {
        if (ui.button("Save as default", false)) shared.push(.{ .board = .save });
        ui.text("these settings differ from the config file", theme.text_dim);
        ui.newline();
    }
    if (bd.note_len > 0) {
        ui.text(bd.note_buf[0..bd.note_len], theme.text_warn);
        ui.newline();
    }
    ui.separator();
}

/// One panel `i` of the display: what it shows and every setting of it.
fn panelSection(ui: *ui_mod.Ui, p: *const panels.Panel, i: usize, shared: *Shared) void {
    panelView(ui, p, i, shared);
    if (p.kind == .electrode) {
        panelFilter(ui, p, i, shared);
        panelCar(ui, p, i, shared);
    }
    if (p.mode == .triggered) panelTrigger(ui, p, i, shared);
    ui.separator();
}

/// The panel's name and what it shows, reset; its mode, time base and scale.
fn panelView(ui: *ui_mod.Ui, p: *const panels.Panel, i: usize, shared: *Shared) void {
    var buf: [160]u8 = undefined;
    // Name, and what the panel shows.
    ui.text(p.name(), theme.text_bright);
    ui.text(format.fmt(&buf, "{d} {s} channels", .{ p.rows, switch (p.kind) {
        .electrode => "electrode",
        .aux => "AUX",
        .adc => "ADC",
        .ttl => "TTL",
    } }), theme.text_dim);
    ui.x = @max(ui.x, ui.width - 78);
    if (ui.button("reset", false)) shared.push(.{ .panel = .{ .index = i, .action = .reset } });
    ui.newline();

    ui.text("view", theme.text_dim);
    ui.column(64);
    inline for (.{ panels.Mode.scroll, panels.Mode.sweep, panels.Mode.triggered }) |m| {
        if (ui.button(@tagName(m), p.mode == m) and p.mode != m) shared.push(.{ .panel = .{ .index = i, .action = .{ .mode = m } } });
    }
    ui.space(14);
    var value_buf: [48]u8 = undefined;
    const time_text = if (p.mode == .triggered)
        format.fmt(&value_buf, "-{d:.1} / +{d:.1} ms", .{ p.trigger.pre_ms, p.trigger.post_ms })
    else
        format.fmtSpan(&value_buf, p.span_s);
    const dt = ui.stepper(if (p.mode == .triggered) "window" else "time", time_text, 130);
    if (dt != 0) shared.push(.{ .panel = .{ .index = i, .action = .{ .zoom = if (dt > 0) step_up else 1.0 / step_up } } });
    if (p.kind != .ttl) {
        var scale_buf: [32]u8 = undefined;
        const ds = ui.stepper("scale", format.fmt(&buf, "{s}/row", .{format.fmtScale(&scale_buf, p.kind, p.scale)}), 110);
        if (ds != 0) shared.push(.{ .panel = .{ .index = i, .action = .{ .scale = if (ds > 0) step_up else 1.0 / step_up } } });
    }
    ui.newline();
}

/// An electrode panel's display filter: raw or band, its corners, and row by row which
/// rows are shown and (filter on) which go through the filter.
fn panelFilter(ui: *ui_mod.Ui, p: *const panels.Panel, i: usize, shared: *Shared) void {
    var value_buf: [48]u8 = undefined;
    ui.text("filter", theme.text_dim);
    ui.column(64);
    if (ui.button("raw", !p.filter.on) and p.filter.on) shared.push(.{ .panel = .{ .index = i, .action = .{ .filter = false } } });
    if (ui.button("band", p.filter.on) and !p.filter.on) shared.push(.{ .panel = .{ .index = i, .action = .{ .filter = true } } });
    if (p.filter.on) {
        ui.space(14);
        const lo = ui.stepper("from", if (p.filter.low_hz > 0) format.fmt(&value_buf, "{d} Hz", .{p.filter.low_hz}) else "off", 80);
        if (lo != 0) shared.push(.{ .panel = .{ .index = i, .action = .{ .corner = .{ .high = false, .up = lo > 0 } } } });
        const hi = ui.stepper("to", if (p.filter.high_hz > 0) format.fmt(&value_buf, "{d} Hz", .{p.filter.high_hz}) else "off", 80);
        if (hi != 0) shared.push(.{ .panel = .{ .index = i, .action = .{ .corner = .{ .high = true, .up = hi > 0 } } } });
    }
    ui.newline();
    // Row by row: which are shown, and (filter on) which go through the filter.
    inline for (.{ "rows shown", "filtered" }, .{ true, false }) |label, is_shown| {
        if (is_shown or p.filter.on) {
            ui.text(label, theme.text_dim);
            ui.column(104);
            const saved_indent = ui.indent;
            ui.indent = 104;
            for (0..@min(p.rows, panels.max_rows)) |r| {
                var nb: [8]u8 = undefined;
                const on = if (is_shown) !p.per_row.hidden.has(r) else !p.per_row.raw.has(r);
                if (ui.chip(format.fmt(&nb, "{d}", .{r + 1}), on))
                    shared.push(.{ .panel = .{ .index = i, .action = if (is_shown) .{ .row_hidden = r } else .{ .row_raw = r } } });
            }
            ui.indent = saved_indent;
            ui.newline();
        }
    }
}

/// An electrode panel's common average reference: which rows are averaged, which lose
/// the average.
fn panelCar(ui: *ui_mod.Ui, p: *const panels.Panel, i: usize, shared: *Shared) void {
    ui.text("CAR", theme.text_dim);
    ui.column(64);
    if (ui.button("off", !p.reference.on) and p.reference.on) shared.push(.{ .panel = .{ .index = i, .action = .{ .car = false } } });
    if (ui.button("on", p.reference.on) and !p.reference.on) shared.push(.{ .panel = .{ .index = i, .action = .{ .car = true } } });
    if (p.reference.on) {
        ui.newline();
        inline for (.{ "average of", "subtract from" }, .{ true, false }) |label, is_ref| {
            const rows = if (is_ref) &p.reference.ref else &p.reference.sub;
            ui.text(label, theme.text_dim);
            ui.column(104);
            const saved_indent = ui.indent;
            ui.indent = 104;
            if (ui.button("all", false))
                shared.push(.{ .panel = .{ .index = i, .action = if (is_ref) .{ .car_ref_all = true } else .{ .car_sub_all = true } } });
            if (ui.button("none", false))
                shared.push(.{ .panel = .{ .index = i, .action = if (is_ref) .{ .car_ref_all = false } else .{ .car_sub_all = false } } });
            ui.space(6);
            for (0..@min(p.rows, panels.max_rows)) |r| {
                var nb: [8]u8 = undefined;
                if (ui.chip(format.fmt(&nb, "{d}", .{r + 1}), rows.has(r)))
                    shared.push(.{ .panel = .{ .index = i, .action = if (is_ref) .{ .car_ref_row = r } else .{ .car_sub_row = r } } });
            }
            ui.indent = saved_indent;
            ui.newline();
        }
    } else ui.newline();
}

/// A triggered panel's trigger: a TTL line, or (electrodes) a level crossing on a row.
fn panelTrigger(ui: *ui_mod.Ui, p: *const panels.Panel, i: usize, shared: *Shared) void {
    var value_buf: [48]u8 = undefined;
    ui.text("trigger", theme.text_dim);
    ui.column(64);
    if (p.kind == .electrode) {
        if (ui.button("TTL", p.trigger.source == .ttl) and p.trigger.source != .ttl)
            shared.push(.{ .panel = .{ .index = i, .action = .{ .trig_source = .ttl } } });
        if (ui.button("spikes", p.trigger.source == .channel) and p.trigger.source != .channel)
            shared.push(.{ .panel = .{ .index = i, .action = .{ .trig_source = .channel } } });
        ui.space(8);
    }
    if (p.trigger.source == .ttl) {
        const dl = ui.stepper("", format.fmt(&value_buf, "TTL {d}", .{p.trigger.line}), 60);
        if (dl != 0)
            shared.push(.{ .panel = .{ .index = i, .action = .{
                .trig_line = @intCast(std.math.clamp(@as(i32, p.trigger.line) + dl, 1, 8)),
            } } });
    } else {
        const dw = ui.stepper("", format.fmt(&value_buf, "row {d}", .{p.trigger.row + 1}), 60);
        if (dw != 0) shared.push(.{ .panel = .{ .index = i, .action = .{ .trig_row = dw } } });
        if (ui.button("falling", !p.trigger.rising) and p.trigger.rising)
            shared.push(.{ .panel = .{ .index = i, .action = .{ .trig_rising = false } } });
        if (ui.button("rising", p.trigger.rising) and !p.trigger.rising)
            shared.push(.{ .panel = .{ .index = i, .action = .{ .trig_rising = true } } });
        ui.newline();
        ui.text("level", theme.text_dim);
        ui.column(64);
        if (ui.button("follows noise", p.trigger.auto) and !p.trigger.auto)
            shared.push(.{ .panel = .{ .index = i, .action = .{ .trig_auto = true } } });
        if (ui.button("fixed", !p.trigger.auto) and p.trigger.auto)
            shared.push(.{ .panel = .{ .index = i, .action = .{ .trig_auto = false } } });
        if (p.trigger.auto) {
            ui.text(format.fmt(&value_buf, "{d:.0} µV", .{p.trigger.level_now_uv}), theme.text_bright);
        } else {
            // "+" makes the level larger in size, whichever its sign.
            const dv = ui.stepper("", format.fmt(&value_buf, "{d:.0} µV", .{p.trigger.level_uv}), 70);
            if (dv != 0) shared.push(.{ .panel = .{ .index = i, .action = .{ .trig_level = if (dv > 0) 1.15 else 1.0 / 1.15 } } });
        }
        const dh = ui.stepper("holdoff", format.fmt(&value_buf, "{d} ms", .{p.trigger.holdoff_ms}), 60);
        if (dh != 0) shared.push(.{ .panel = .{ .index = i, .action = .{ .trig_holdoff = dh > 0 } } });
    }
    const dn = ui.stepper("overlaid", format.fmt(&value_buf, "{d} sweeps", .{p.trigger.overlay}), 90);
    if (dn != 0)
        shared.push(.{ .panel = .{ .index = i, .action = .{
            .overlay = @intCast(std.math.clamp(@as(i32, @intCast(p.trigger.overlay)) + dn, 1, oez.sweeps.max_sweeps)),
        } } });
    ui.newline();
}

const testing = std.testing;

test "edits queue and snapshots cross between the two sides" {
    var shared: Shared = .{};
    try testing.expectEqual(null, shared.pop());
    shared.push(.{ .panel = .{ .index = 2, .action = .{ .scale = 1.25 } } });
    shared.push(.quit);
    try testing.expectEqual(2, shared.pop().?.panel.index);
    try testing.expect(shared.pop().? == .quit);
    try testing.expectEqual(null, shared.pop());
    // A full queue drops the newest instead of overwriting.
    for (0..200) |i| shared.push(.{ .panel = .{ .index = i, .action = .reset } });
    var n: usize = 0;
    while (shared.pop()) |e| : (n += 1) try testing.expectEqual(n, e.panel.index);
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

// ---- The layout, frozen ----
//
// `build` is immediate-mode: the order of its `ui.*` calls is the layout. This test runs
// it for a set of snapshots with a hand-made font (no FreeType, no GPU) in which every
// character is 8 pixels wide and is drawn as a 1x1 quad whose atlas position names the
// character, so the batch holds every rectangle and every glyph in the order drawn. Each
// is written out as text (glyphs merged into runs of text), with the edits that a click
// in the middle of each rectangle queues, and compared with `testdata/control_layout.txt`.
// Set OEZ_CONTROL_LAYOUT_OUT to a path to write what this run produced there.

var layout_atlas: [1]u8 = .{0};

fn layoutFont() font.Font {
    var f: font.Font = .{ .atlas = &layout_atlas, .px = 14, .ascent = 12, .line_height = 16 };
    for (&f.glyphs, 0..) |*g, k| g.* = .{ .x = @intCast(8 + k), .y = 8, .w = 1, .h = 1, .top = 12, .advance = 8 };
    return f;
}

/// The code point of glyph `k` of `layoutFont` (as `font.Font.glyph` numbers them).
fn layoutCodepoint(k: usize) u21 {
    const extra = [_]u21{ 0x03C3, 0x2013, 0x2192, 0x266A };
    return if (k < 224) @intCast(32 + k) else extra[k - 224];
}

const LayoutRig = struct {
    face: font.Font,
    vertices: []font.Vertex,
    batch: font.Batch = undefined,
    shared: Shared = .{},
    cfg: Config = undefined,

    fn frame(self: *LayoutRig, snap: *const Snapshot, mx: f32, my: f32, clicked: bool) ui_mod.Ui {
        self.batch = .{ .font = &self.face, .vertices = self.vertices };
        self.shared = .{};
        var ui: ui_mod.Ui = .begin(&self.batch, 800, mx, my, clicked, 0);
        build(&ui, &self.cfg, snap, &self.shared);
        return ui;
    }
};

fn writeLayout(w: *std.Io.Writer, rig: *LayoutRig, name: []const u8, snap: *const Snapshot) !void {
    const ui = rig.frame(snap, -1, -1, false);
    const quads = rig.batch.len / 6;
    // A full batch drops quads silently: the comparison would then miss them.
    try testing.expect(rig.batch.len + 6 <= rig.vertices.len);
    // Copied, as the click frames below reuse the batch.
    const verts = try testing.allocator.dupe(font.Vertex, rig.vertices[0..rig.batch.len]);
    defer testing.allocator.free(verts);
    try w.print("== {s}: {d} quads, ends at x {d} y {d}\n", .{ name, quads, ui.x, ui.y });
    var q: usize = 0;
    while (q < quads) {
        const v = verts[q * 6 ..][0..6];
        const x = v[0].pos[0];
        const y = v[0].pos[1];
        const col = v[0].colour;
        const u = v[0].uv[0] * font.atlas_size;
        if (u < 8) {
            const rw = v[2].pos[0] - x;
            const rh = v[2].pos[1] - y;
            try w.print("rect {d} {d} {d} {d} {any}", .{ x, y, rw, rh, col });
            _ = rig.frame(snap, x + rw / 2, y + rh / 2, true);
            // A panel edit is written flat, so its action is not nested too deeply to print.
            while (rig.shared.pop()) |e| switch (e) {
                .panel => |pe| try w.print(" -> panel {d} {any}", .{ pe.index, pe.action }),
                else => try w.print(" -> {any}", .{e}),
            };
            try w.writeByte('\n');
            q += 1;
            continue;
        }
        // A run of glyphs: same row and colour, 8 pixels apart.
        try w.print("text {d} {d} {any} \"", .{ x, y, col });
        var next_x = x;
        while (q < quads) : (q += 1) {
            const g = verts[q * 6 ..][0..6];
            const gu = g[0].uv[0] * font.atlas_size;
            if (gu < 8 or g[0].pos[0] != next_x or g[0].pos[1] != y or !std.mem.eql(u8, &g[0].colour, &col)) break;
            var utf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(layoutCodepoint(@intFromFloat(gu - 8)), &utf) catch unreachable;
            try w.writeAll(utf[0..n]);
            next_x += 8;
        }
        try w.writeAll("\"\n");
    }
}

fn setText(buf: []u8, len: *usize, s: []const u8) void {
    @memcpy(buf[0..s.len], s);
    len.* = s.len;
}

fn layoutPanel(name: []const u8, kind: panels.Kind, rows: u32) panels.Panel {
    var p: panels.Panel = .{
        .place = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .kind = kind,
        .first_ch = 0,
        .rows = rows,
        .span_s = 2,
        .scale = panels.Panel.defaultScale(kind),
    };
    setText(&p.name_buf, &p.name_len, name);
    return p;
}

/// The snapshots the layout is frozen for, written into `out`; returns their names.
fn layoutSnapshots(out: []Snapshot) []const []const u8 {
    const names = &[_][]const u8{
        "not recording",
        "recording",
        "review active",
        "quit prompt",
        "restart pending",
        "two panels: slope trigger, reference",
        "alarm",
        "other panels",
    };
    out[0] = layoutBase();
    stateSnapshots(out, &out[0]);
    panelSnapshots(out, &out[0]);
    return names;
}

fn layoutBase() Snapshot {
    // Not recording: a status line, notes, audio listening, a warning, one small panel.
    var base: Snapshot = .{};
    setText(&base.about_buf, &base.about_len, "Simulator   40 channels at 30000 Hz");
    base.status = .{ .valid = true, .latency_ms = 4.25, .fps = 144, .lost = 3 };
    setText(&base.status.warning_buf, &base.status.warning_len, "disk nearly full");
    base.seconds = 125.4;
    base.board.lower_actual = 0.58;
    base.board.upper_actual = 7603.2;
    base.board.dsp_actual = 1.17;
    base.board.headstages[0] = .{ .slot = 0, .rhd2132 = true };
    base.board.headstages[1] = .{ .slot = 2, .rhd2132 = false };
    base.board.num_headstages = 2;
    base.board.pending = base.board.settings;
    base.audio.running = true;
    setText(&base.audio.listen_buf, &base.audio.listen_len, "A1-5, B1-3");
    base.audio.sigma_uv = 7.36;
    base.audio.latency_ms = 9.4;
    base.audio.underruns = 2;
    setText(&base.notes.presets[0].buf, &base.notes.presets[0].len, "laser on");
    setText(&base.notes.presets[3].buf, &base.notes.presets[3].len, "µ-stim");
    base.notes.num_drafts = 2;
    base.notes.recent[0] = .{ .seconds = 3725 };
    setText(&base.notes.recent[0].buf, &base.notes.recent[0].len, "cell 3, 2100 µm");
    base.notes.recent[1] = .{ .seconds = 61 };
    setText(&base.notes.recent[1].buf, &base.notes.recent[1].len, "moved");
    base.notes.num_recent = 2;
    base.view_unsaved = true;
    base.set.items[0] = layoutPanel("Port A", .electrode, 6);
    base.set.len = 1;
    return base;
}

/// Snapshots 1 to 4 and 6: the states of the sections above the panels.
fn stateSnapshots(out: []Snapshot, base: *const Snapshot) void {
    // Recording, with the disk behind, gaps, a note, a path, the DSP on, a restart that
    // has to wait, a ring overflow; audio measuring the noise; a note being typed.
    var s = base.*;
    s.rec = .{ .state = .recording, .seconds = 3661, .samples = 109_830_000, .bytes = 13_200_000_000, .behind_s = 2.5, .gaps = 1 };
    s.rec.setNote("started at {s}", .{"12:00"});
    setText(&s.rec.path_buf, &s.rec.path_len, "/data/2026-11-12_12-00-00");
    s.ring_overflow = 7;
    s.board.settings.dsp_enabled = true;
    s.board.pending.sample_rate = 20000;
    s.board.unsaved = true;
    s.audio.sigma_uv = 0;
    s.notes.editing = true;
    out[1] = s;

    // Review active, from the recording's file, loading; audio off, muted, plain; the
    // last recording failed; no notes.
    s = base.*;
    s.review = .{ .active = true, .behind_s = 12.5, .at_s = 75, .from_file = true, .loading = true };
    s.audio.settings.reference = true;
    s.audio.settings.enabled = false;
    s.audio.settings.mute = true;
    s.rec.state = .failed;
    s.rec.setNote("cannot create {s}", .{"/data"});
    s.notes = .{};
    out[2] = s;

    // The quit prompt.
    s = base.*;
    s.quit_prompt.active = true;
    for (0..3) |k| s.quit_prompt.changes.add("setting {d} changed", .{k});
    setText(&s.quit_prompt.path_buf, &s.quit_prompt.path_len, "/home/user/.config/oez/oez.toml");
    out[3] = s;

    // A restart pending (half-channel mode), not recording; a board note; review of the
    // last seconds; no audio device.
    s = base.*;
    s.board.pending.rhd2132_16ch[0] = true;
    s.board.setNote("cannot set {s}", .{"10 kHz"});
    s.review = .{ .active = true, .behind_s = 1.5, .at_s = 30 };
    s.audio.running = false;
    out[4] = s;

    // An alarm (the warning is not shown with it).
    s = base.*;
    setText(&s.status.alarm_buf, &s.status.alarm_len, "RECORDING STOPPED: disk full");
    out[6] = s;
}

/// Snapshots 5 and 7: panels of every kind and setting.
fn panelSnapshots(out: []Snapshot, base: *const Snapshot) void {
    // Two electrode panels: one triggered on a slope with a fixed level, filtered, some
    // rows raw and hidden; one with the reference on and a band with its low side off.
    var s = base.*;
    s.status.warning_len = 0;
    var a = layoutPanel("Port A", .electrode, 32);
    a.mode = .triggered;
    a.trigger.source = .channel;
    a.trigger.row = 4;
    a.trigger.auto = false;
    a.trigger.level_uv = -62;
    a.trigger.holdoff_ms = 2;
    a.trigger.pre_ms = 1;
    a.trigger.post_ms = 2;
    a.filter.on = true;
    a.per_row.raw.set(3, true);
    a.per_row.hidden.set(7, true);
    s.set.items[0] = a;
    var b = layoutPanel("Port B", .electrode, 16);
    b.setCar(true);
    b.reference.ref.set(2, false);
    b.filter.on = true;
    b.filter.low_hz = 0;
    b.scale = 1500;
    b.span_s = 0.5;
    b.mode = .sweep;
    s.set.items[1] = b;
    s.set.len = 2;
    s.audio.listen_len = 0;
    out[5] = s;

    // Other panels: a slope trigger whose level follows the noise, rising; AUX, ADC and a
    // TTL panel triggered on TTL; the status not yet valid; the recording finishing.
    s = base.*;
    s.status = .{};
    s.rec.state = .stopping;
    var t = layoutPanel("TTL", .ttl, 8);
    t.mode = .triggered;
    var e = layoutPanel("Port C", .electrode, 4);
    e.mode = .triggered;
    e.trigger.source = .channel;
    e.trigger.rising = true;
    e.trigger.level_now_uv = -48.4;
    s.set.items[0] = e;
    s.set.items[1] = layoutPanel("AUX", .aux, 3);
    s.set.items[2] = layoutPanel("ADC", .adc, 8);
    s.set.items[2].scale = 0.25;
    s.set.items[3] = t;
    s.set.len = 4;
    s.audio.listen_len = 0;
    s.board.settings.dsp_enabled = true;
    out[7] = s;
}

test "the control window's layout is unchanged" {
    const gpa = testing.allocator;
    const vertices = try gpa.alloc(font.Vertex, 6 * 8192);
    defer gpa.free(vertices);
    const rig = try gpa.create(LayoutRig);
    defer gpa.destroy(rig);
    rig.* = .{ .face = layoutFont(), .vertices = vertices };
    rig.cfg = .{ .gpa = gpa, .shared = &rig.shared, .display_gpu = undefined };
    const snaps = try gpa.alloc(Snapshot, 8);
    defer gpa.free(snaps);
    const names = layoutSnapshots(snaps);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (names, snaps) |name, *snap| try writeLayout(&out.writer, rig, name, snap);
    const got = out.written();
    if (std.c.getenv("OEZ_CONTROL_LAYOUT_OUT")) |path| {
        const file = try std.Io.Dir.cwd().createFile(testing.io, std.mem.span(path), .{});
        defer file.close(testing.io);
        try file.writeStreamingAll(testing.io, got);
    }
    try testing.expectEqualStrings(@embedFile("testdata/control_layout.txt"), got);
}
