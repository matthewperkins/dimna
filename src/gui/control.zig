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
const dimna = @import("dimna");
const panels = dimna.panels;
const ControlView = dimna.control_view.ControlView;
const Window = @import("window_wayland.zig").Window;
const gpu_mod = @import("gpu.zig");
const font = @import("font.zig");
const ui_mod = @import("ui.zig");
const theme = @import("theme.zig");
const Env = @import("env.zig").Env;
const Status = @import("display.zig").Status;
const format = @import("format.zig");
const i18n = @import("i18n.zig");
const Atomic = std.atomic.Value;
const log = std.log.scoped(.control);

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
    /// The same, from a message of the catalogue.
    pub fn say(self: *RecStatus, comptime id: i18n.Id, args: anytype) void {
        self.note_len = i18n.fmt(&self.note_buf, id, args).len;
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

/// `scroll`: move by the samples queued with it (`ReviewSession.queueScroll`; the display's wheel).
pub const ReviewAction = enum { toggle, back, forward, page_back, page_forward, start, live, scroll };

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
    settings: dimna.audio.Settings = .{},
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
    settings: dimna.types.Settings = .{},
    /// What the chips actually do for the requested values (they offer steps).
    lower_actual: f64 = 0,
    upper_actual: f64 = 0,
    dsp_actual: f64 = 0,
    /// Sample rate and half-channel choices made but not applied yet (they restart
    /// acquisition); equal to `settings` when there are none.
    pending: dimna.types.Settings = .{},
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
    /// The same, from a message of the catalogue.
    pub fn say(self: *BoardStatus, comptime id: i18n.Id, args: anytype) void {
        self.note_len = i18n.fmt(&self.note_buf, id, args).len;
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
    changes: dimna.board_config.Diff = .{},
    /// The config file the settings would be saved to.
    path_buf: [200]u8 = undefined,
    path_len: usize = 0,
};

/// A display mode's name, as the buttons and the summary show it.
pub fn modeText(m: panels.Mode) []const u8 {
    return switch (m) {
        .scroll => i18n.text(.mode_scroll),
        .sweep => i18n.text(.mode_sweep),
        .triggered => i18n.text(.mode_triggered),
    };
}

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
    /// One step up (true) or down through the holdoff values.
    trig_holdoff: bool,
    overlay: u32,
    reset,
};

/// A change to the detection thresholds (thresholds.zig), which the display owns.
pub const ThresholdEdit = union(enum) {
    /// The global sigmas, one step up (true) or down.
    sigmas: bool,
    /// Multiply a channel's fixed threshold (one that follows the noise is latched first).
    scale: struct { channel: u32, factor: f32 },
    /// Fix a channel's threshold at `uv` µV (its sign the slope; 0: back to the noise).
    set: struct { channel: u32, uv: f32 },
    /// Back to the noise.
    follow: u32,
    /// Change the sign, so the slope (one that follows the noise is latched first).
    flip: u32,
};

/// What a click in the control window asks for, by who carries it out. The display's loop
/// switches on this once (main.zig), so a new case does not compile until it is handled.
pub const Edit = union(enum) {
    /// A change to one panel (the display's own settings).
    panel: struct { index: usize, action: PanelAction },
    threshold: ThresholdEdit,
    audio: AudioAction,
    board: BoardAction,
    /// Start (true) or stop a recording.
    record: bool,
    /// Stamp this preset note (1 to 9) now.
    note_preset: u8,
    /// The user has seen the alarm banner.
    acknowledge,
    /// Write the panels' settings to the view file.
    save_view,
    /// Which sections of the control window are open now (saved with the view).
    control_view: ControlView,
    quit_answer: QuitAnswer,
    quit,
};

pub const Snapshot = struct {
    set: panels.Set = .{},
    /// The detection thresholds, and what the tile window last reported as in use.
    thresholds: dimna.thresholds.Thresholds = .{},
    reported: dimna.thresholds.Reported = .{},
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
    snap: dimna.published.Published(Snapshot) = .{},
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
    env: *const Env,
    /// Which sections are open at start (from the view file); read once by the control
    /// thread, which reports every change as `Edit.control_view`.
    view: ControlView = .{},
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
    // A class too long for the buffer gives the usual one.
    var class_buf: [64]u8 = undefined;
    const class = std.fmt.bufPrintSentinel(&class_buf, "{s}-control", .{cfg.env.app_id}, 0) catch "dimna-control";
    try win.init("dimna control", class, cfg.env.key_debug);
    defer win.deinit();
    var gpu = try gpu_mod.Gpu.init(gpa, .{ .display = win.display, .surface = win.surface }, .fifo, cfg.display_gpu);
    defer gpu.deinit();
    var face = try font.Font.init(gpa, std.mem.sliceTo(&cfg.font_buf, 0), cfg.font_px);
    defer face.deinit(gpa);
    const max_vertices = 24 * 1024;
    const vertices = try gpa.alloc(font.Vertex, max_vertices);
    defer gpa.free(vertices);
    try gpu.createText(face.atlas, font.atlas_size, max_vertices);
    gpu.textFont(&face);
    var batch: font.Batch = .{ .font = &face, .vertices = vertices };

    var snap: Snapshot = .{};
    var seen: u32 = 0;
    var dirty = true;
    var clicks: u32 = 0;
    var wheel: f64 = 0;
    var last_x: f64 = -1;
    var last_y: f64 = -1;
    var tag: u64 = 0;
    // Which sections are open: at start, as the view file says.
    var view: ControlView = cfg.view;
    // Mirrored for a language read right to left (the language is set before this thread).
    const rtl = i18n.rightToLeft(i18n.current);
    // For tests: "SECONDS:X,Y;..." clicks at those pixels of this window.
    var script: []const u8 = cfg.env.control_clicks;
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

        if (win.resized or gpu.unsized()) {
            try gpu.resize(win.width, win.height);
            win.resized = false;
        }
        var ui: ui_mod.Ui = .begin(
            &batch,
            @floatFromInt(gpu.pixelSize().width),
            @floatCast(in.pointer_x),
            @floatCast(in.pointer_y),
            clicks > 0,
            @floatCast(wheel),
            rtl,
        );
        build(&ui, cfg, &snap, shared, &view);
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
    return @as(f64, @floatFromInt(dimna.clock.nowNs())) / 1e9;
}

/// Describes the whole window for this frame and queues what was clicked. The order of the
/// calls (and of the `ui.*` calls in each) is the layout. A click on a section's heading
/// opens or closes it in `view`, and the display thread is told (it saves `view`).
fn build(ui: *ui_mod.Ui, cfg: *const Config, snap: *const Snapshot, shared: *Shared, view: *ControlView) void {
    _ = cfg;
    const before = view.*;
    defer if (!view.eql(&before)) shared.push(.{ .control_view = view.* });
    titleSection(ui, snap, shared);
    if (snap.quit_prompt.active) {
        // Quitting with board settings that differ from the config: nothing else is shown.
        quitPrompt(ui, &snap.quit_prompt, shared);
        return;
    }
    statusSection(ui, snap, shared);
    recordSection(ui, &snap.rec, shared);
    notesSection(ui, &snap.notes, shared, &view.notes);
    audioSection(ui, &snap.audio, shared, &view.audio);
    thresholdSection(ui, &snap.thresholds, shared);
    boardSection(ui, &snap.board, snap.rec.state, shared, &view.headstages);
    for (snap.set.items[0..snap.set.len], 0..) |*p, i| panelSection(ui, p, i, snap, shared, view);
    ui.text(i18n.text(.hint_keys), theme.text_dim);
}

/// Multiplies the scale or the time base, one stepper click.
const step_up = 1.25;

/// Where a section's summary starts, after its heading.
const summary_column = 128;

/// A section's heading, which a click opens or closes (in `open`), then its summary line.
/// True if the section is open.
fn sectionHeading(ui: *ui_mod.Ui, label: []const u8, open: *bool, summary: []const u8) bool {
    if (ui.heading(label, open.*)) open.* = !open.*;
    ui.column(summary_column);
    ui.text(summary, theme.text_dim);
    ui.newline();
    return open.*;
}

/// The name, the source, and the alarm (or a warning).
fn titleSection(ui: *ui_mod.Ui, snap: *const Snapshot, shared: *Shared) void {
    ui.text("dimna", theme.text_bright);
    ui.text(snap.about_buf[0..snap.about_len], theme.text_dim);
    ui.newline();
    if (snap.status.alarm_len > 0) {
        // The same alarm as across the display, until acknowledged.
        ui.fill(0, ui.y - 2, ui.width, ui.rowHeight() + 2, theme.alarm_bar);
        ui.text(snap.status.alarm(), theme.text_bright);
        ui.alignEnd(130, &.{i18n.text(.btn_acknowledge)});
        if (ui.button(i18n.text(.btn_acknowledge), false)) shared.push(.acknowledge);
        ui.newline();
    } else if (snap.status.warning_len > 0) {
        ui.text(snap.status.warning(), theme.text_warn);
        ui.newline();
    }
}

/// Shown instead of everything below the title when quitting with changed board settings.
fn quitPrompt(ui: *ui_mod.Ui, q: *const QuitPrompt, shared: *Shared) void {
    ui.separator();
    ui.text(i18n.text(.quit_heading), theme.text_bright);
    ui.newline();
    for (0..q.changes.count) |i| {
        ui.space(16);
        ui.text(q.changes.line(i), theme.text_warn);
        ui.newline();
    }
    ui.text(q.path_buf[0..q.path_len], theme.text_dim);
    ui.newline();
    if (ui.button(i18n.text(.btn_save_and_quit), true)) shared.push(.{ .quit_answer = .save });
    if (ui.button(i18n.text(.btn_quit_without_saving), false)) shared.push(.{ .quit_answer = .discard });
    if (ui.button(i18n.text(.btn_cancel), false)) shared.push(.{ .quit_answer = .cancel });
}

/// The display's latency and losses, and Save view / Quit.
fn statusSection(ui: *ui_mod.Ui, snap: *const Snapshot, shared: *Shared) void {
    var buf: [160]u8 = undefined;
    const st = snap.status;
    if (st.valid) {
        ui.text(
            i18n.fmt(&buf, .status_display, .{ .ms = st.latency_ms, .fps = st.fps, .seconds = snap.seconds }),
            theme.text_dim,
        );
    } else ui.text(i18n.text(.status_starting), theme.text_dim);
    if (st.lost > 0) ui.text(i18n.count(&buf, "status_display_skipped", st.lost, .{ .blocks = st.lost }), theme.text_warn);
    if (snap.ring_overflow > 0) ui.text(i18n.fmt(&buf, .status_ring_overflow, .{ .count = snap.ring_overflow }), theme.text_warn);
    ui.alignEnd(170, &.{ i18n.text(.btn_save_view), i18n.text(.btn_quit) });
    // Lit while the panels' settings differ from what is saved.
    if (ui.button(i18n.text(.btn_save_view), snap.view_unsaved)) shared.push(.save_view);
    if (ui.button(i18n.text(.btn_quit), false)) shared.push(.quit);
    ui.newline();
    ui.separator();
}

/// Recording.
fn recordSection(ui: *ui_mod.Ui, rec: *const RecStatus, shared: *Shared) void {
    var buf: [160]u8 = undefined;
    switch (rec.state) {
        .idle, .failed => if (ui.button(i18n.text(.btn_record), false)) shared.push(.{ .record = true }),
        .recording => if (ui.button(i18n.text(.btn_stop_recording), true)) shared.push(.{ .record = false }),
        .stopping => ui.text(i18n.text(.rec_finishing), theme.text_dim),
    }
    if (rec.state == .recording or rec.state == .stopping) {
        var clock_buf: [16]u8 = undefined;
        ui.text(
            i18n.fmt(&buf, .rec_status, .{
                .clock = fmtClock(&clock_buf, rec.seconds),
                .gb = @as(f64, @floatFromInt(rec.bytes)) / 1e9,
                .msamples = @as(f64, @floatFromInt(rec.samples)) / 1e6,
            }),
            theme.text_rec,
        );
        if (rec.behind_s > 1.0) ui.text(i18n.fmt(&buf, .rec_disk_behind, .{ .behind = rec.behind_s }), theme.text_warn);
        if (rec.gaps > 0) ui.text(i18n.count(&buf, "rec_gaps", rec.gaps, .{ .gaps = rec.gaps }), theme.text_warn);
    } else if (rec.state == .failed) {
        ui.text(i18n.text(.rec_failed), theme.text_warn);
    } else ui.text(i18n.text(.rec_idle), theme.text_dim);
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

/// Notes: how many presets and the newest note; open, the presets as buttons and the
/// newest notes.
fn notesSection(ui: *ui_mod.Ui, nt: *const NotesStatus, shared: *Shared, open: *bool) void {
    var buf: [160]u8 = undefined;
    if (!sectionHeading(ui, i18n.text(.section_notes), open, notesSummary(&buf, nt))) return ui.separator();
    ui.column(64);
    var any_preset = false;
    for (&nt.presets, 1..) |*pr, n| {
        if (pr.len == 0) continue;
        any_preset = true;
        if (ui.button(format.fmt(&buf, "{d} {s}", .{ n, pr.buf[0..pr.len] }), false))
            shared.push(.{ .note_preset = @intCast(n) });
    }
    if (!any_preset) ui.text(i18n.text(.notes_hint), theme.text_dim);
    if (nt.editing) ui.text(i18n.text(.notes_typing), theme.text_warn);
    if (nt.num_drafts > 0) ui.text(i18n.count(&buf, "notes_drafts", nt.num_drafts, .{ .count = nt.num_drafts }), theme.text_dim);
    ui.newline();
    for (nt.recent[0..nt.num_recent]) |*line| {
        var clock_buf: [16]u8 = undefined;
        ui.space(16);
        ui.text(format.fmt(&buf, "{s}  {s}", .{ fmtClock(&clock_buf, line.seconds), line.buf[0..line.len] }), theme.text_dim);
        ui.newline();
    }
    ui.separator();
}

/// "2 presets   last note 1:02:05  cell 3".
fn notesSummary(buf: []u8, nt: *const NotesStatus) []const u8 {
    var presets: usize = 0;
    for (&nt.presets) |*pr| presets += @intFromBool(pr.len > 0);
    var presets_buf: [48]u8 = undefined;
    const counted = i18n.count(&presets_buf, "presets", presets, .{ .count = presets });
    if (nt.num_recent == 0) return i18n.fmt(buf, .notes_summary_empty, .{ .presets = counted });
    var clock_buf: [16]u8 = undefined;
    const last = &nt.recent[0];
    return i18n.fmt(buf, .notes_summary_last, .{
        .presets = counted,
        .clock = fmtClock(&clock_buf, last.seconds),
        .text = last.buf[0..last.len],
    });
}

/// The audio monitor: on or off, volume, what is listened to, latency; open, its controls.
fn audioSection(ui: *ui_mod.Ui, au: *const AudioStatus, shared: *Shared, open: *bool) void {
    var buf: [160]u8 = undefined;
    if (!sectionHeading(ui, i18n.text(.section_audio), open, audioSummary(&buf, au))) return ui.separator();
    ui.column(64);
    if (ui.button(i18n.text(.toggle_on), au.settings.enabled) and !au.settings.enabled) shared.push(.{ .audio = .{ .enabled = true } });
    if (ui.button(i18n.text(.toggle_off), !au.settings.enabled) and au.settings.enabled) shared.push(.{ .audio = .{ .enabled = false } });
    if (ui.button(i18n.text(.btn_mute), au.settings.mute)) shared.push(.{ .audio = .{ .mute = !au.settings.mute } });
    const dvol = ui.stepper(i18n.text(.label_volume), format.fmt(&buf, "{d:.0} dB", .{au.settings.volume_db}), 60);
    if (dvol != 0) shared.push(.{ .audio = .{ .volume = dvol > 0 } });
    // "plain" is the linear reference chain, for comparing by ear.
    if (ui.button(i18n.text(.btn_shaped), !au.settings.reference) and au.settings.reference)
        shared.push(.{ .audio = .{ .reference = false } });
    if (ui.button(i18n.text(.btn_plain), au.settings.reference) and !au.settings.reference)
        shared.push(.{ .audio = .{ .reference = true } });
    if (ui.button(i18n.text(.label_car), au.car)) shared.push(.{ .audio = .{ .car = !au.car } });
    if (ui.button(i18n.text(.btn_recalibrate), false)) shared.push(.{ .audio = .recalibrate });
    ui.newline();
    if (!au.running) {
        ui.text(i18n.text(.audio_no_output), theme.text_dim);
    } else if (au.settings.enabled) {
        ui.text(
            i18n.fmt(
                &buf,
                .audio_listening,
                .{ .what = if (au.listen_len > 0) au.listen_buf[0..au.listen_len] else i18n.text(.audio_listening_nothing) },
            ),
            theme.text_dim,
        );
        if (au.listen_len > 0) {
            if (au.sigma_uv > 0)
                ui.text(i18n.fmt(&buf, .audio_noise_held, .{ .sigma = au.sigma_uv }), theme.text_dim)
            else
                ui.text(i18n.text(.audio_measuring), theme.text_warn);
            ui.text(format.fmt(&buf, "{d:.0} ms", .{au.latency_ms}), theme.text_dim);
        }
        if (au.underruns > 0) ui.text(i18n.count(&buf, "audio_gaps", au.underruns, .{ .count = au.underruns }), theme.text_dim);
    } else ui.text(i18n.text(.toggle_off), theme.text_dim);
    ui.newline();
    ui.separator();
}

/// "on, muted   -6 dB   listening to A1-5   9 ms".
fn audioSummary(buf: []u8, au: *const AudioStatus) []const u8 {
    if (!au.running) return i18n.text(.audio_no_output);
    const muted = if (au.settings.mute) i18n.text(.audio_muted) else "";
    const db = au.settings.volume_db;
    if (!au.settings.enabled) return i18n.fmt(buf, .audio_summary_off, .{ .muted = muted, .db = db });
    if (au.listen_len == 0) return i18n.fmt(buf, .audio_summary_nothing, .{ .muted = muted, .db = db });
    const listen = au.listen_buf[0..au.listen_len];
    return i18n.fmt(buf, .audio_summary_on, .{ .muted = muted, .db = db, .what = listen, .ms = au.latency_ms });
}

/// The spike detection threshold of every channel that follows the noise: how many sigmas
/// below zero. One line, always shown: there is nothing more to open.
fn thresholdSection(ui: *ui_mod.Ui, th: *const dimna.thresholds.Thresholds, shared: *Shared) void {
    var buf: [32]u8 = undefined;
    // Where a heading's text starts, though this one does not open.
    ui.space(9);
    ui.text(i18n.text(.section_spikes), theme.text_bright);
    ui.column(summary_column);
    const ds = ui.stepper(i18n.text(.label_threshold), format.fmt(&buf, "{d} σ", .{th.sigmas}), 60);
    if (ds != 0) shared.push(.{ .threshold = .{ .sigmas = ds > 0 } });
    ui.text(i18n.text(.hint_below_zero), theme.text_dim);
    ui.newline();
    ui.separator();
}

/// The headstage chips: these change what is recorded. The amplifier band and the DSP
/// apply without a gap; the sample rate and half-channel mode need a restart, which waits
/// while `rec` records.
fn boardSection(ui: *ui_mod.Ui, bd: *const BoardStatus, rec: RecStatus.State, shared: *Shared, open: *bool) void {
    var buf: [160]u8 = undefined;
    // Open by itself while "Apply" or "Save as default" matters; a click then does nothing.
    const forced = bd.restartPending() or bd.unsaved;
    if (ui.heading(i18n.text(.section_headstages), open.* or forced) and !forced) open.* = !open.*;
    ui.column(summary_column);
    ui.text(boardSummary(&buf, bd), theme.text_dim);
    if (forced) ui.text(if (bd.restartPending()) i18n.text(.board_restart_pending) else i18n.text(.board_not_saved), theme.text_warn);
    ui.newline();
    if (open.* or forced) boardControls(ui, bd, rec, shared);
    // Shown open or closed: it answers a click (Save view, Save as default).
    if (bd.note_len > 0) {
        ui.text(bd.note_buf[0..bd.note_len], theme.text_warn);
        ui.newline();
    }
    ui.separator();
}

/// "30000 Hz   0.58 Hz–7.60 kHz   DSP off   A1 16 of 32": the settings in use.
fn boardSummary(buf: []u8, bd: *const BoardStatus) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var lo_buf: [24]u8 = undefined;
    var hi_buf: [24]u8 = undefined;
    // Cut where the buffer ends (the writer keeps what fit).
    i18n.print(&w, .board_summary_head, .{
        .rate = bd.settings.sample_rate,
        .lower = fmtHz(&lo_buf, bd.lower_actual),
        .upper = fmtHz(&hi_buf, bd.upper_actual),
    }) catch {};
    if (bd.settings.dsp_enabled)
        i18n.print(&w, .board_summary_dsp_on, .{ .cutoff = fmtHz(&lo_buf, bd.dsp_actual) }) catch {}
    else
        w.writeAll(i18n.text(.toggle_off)) catch {};
    for (bd.headstages[0..bd.num_headstages]) |h| {
        if (h.rhd2132 and bd.settings.rhd2132_16ch[h.slot])
            i18n.print(&w, .board_summary_half, .{ .headstage = dimna.types.headstage_names[h.slot] }) catch {};
    }
    return w.buffered();
}

/// The headstages' settings, each with its controls.
fn boardControls(ui: *ui_mod.Ui, bd: *const BoardStatus, rec: RecStatus.State, shared: *Shared) void {
    var buf: [160]u8 = undefined;
    var hz_buf: [24]u8 = undefined;
    ui.text(i18n.text(.board_these_change), theme.text_dim);
    ui.newline();
    ui.text(i18n.text(.label_amplifier_band), theme.text_dim);
    ui.column(120);
    const dlo = ui.stepper(i18n.text(.label_low), fmtHz(&hz_buf, bd.lower_actual), 80);
    if (dlo != 0) shared.push(.{ .board = .{ .lower = dlo > 0 } });
    const dhi = ui.stepper(i18n.text(.label_high), fmtHz(&hz_buf, bd.upper_actual), 80);
    if (dhi != 0) shared.push(.{ .board = .{ .upper = dhi > 0 } });
    ui.newline();
    ui.text(i18n.text(.label_dsp_highpass), theme.text_dim);
    ui.column(120);
    if (ui.button(i18n.text(.toggle_off), !bd.settings.dsp_enabled) and bd.settings.dsp_enabled) shared.push(.{ .board = .{ .dsp = false } });
    if (ui.button(i18n.text(.toggle_on), bd.settings.dsp_enabled) and !bd.settings.dsp_enabled) shared.push(.{ .board = .{ .dsp = true } });
    if (bd.settings.dsp_enabled) {
        ui.space(14);
        const dc = ui.stepper(i18n.text(.label_cutoff), fmtHz(&hz_buf, bd.dsp_actual), 80);
        if (dc != 0) shared.push(.{ .board = .{ .dsp_cutoff = dc > 0 } });
    }
    ui.newline();
    // Sample rate and half-channel mode change the shape of the data: chosen here, then
    // applied together by restarting acquisition (not while recording).
    ui.text(i18n.text(.label_sample_rate), theme.text_dim);
    ui.column(120);
    const dr = ui.stepper("", format.fmt(&buf, "{d} Hz", .{bd.pending.sample_rate}), 80);
    if (dr != 0) shared.push(.{ .board = .{ .rate = dr > 0 } });
    for (bd.headstages[0..bd.num_headstages]) |h| {
        if (!h.rhd2132) continue;
        const half = bd.pending.rhd2132_16ch[h.slot];
        ui.text(dimna.types.headstage_names[h.slot], theme.text_dim);
        if (ui.button(i18n.text(.btn_32_ch), !half) and half) shared.push(.{ .board = .{ .half = h.slot } });
        if (ui.button(i18n.text(.btn_16_of_32), half) and !half) shared.push(.{ .board = .{ .half = h.slot } });
        ui.space(8);
    }
    ui.newline();
    if (bd.restartPending()) {
        if (rec == .idle or rec == .failed) {
            if (ui.button(i18n.text(.btn_apply), true)) shared.push(.{ .board = .apply });
        } else ui.text(i18n.text(.board_apply_after_stop), theme.text_warn);
        ui.newline();
    }
    if (bd.unsaved) {
        if (ui.button(i18n.text(.btn_save_default), false)) shared.push(.{ .board = .save });
        ui.text(i18n.text(.board_differs), theme.text_dim);
        ui.newline();
    }
}

/// One panel `i` of the display: its name and a summary; open, every setting of it.
fn panelSection(ui: *ui_mod.Ui, p: *const panels.Panel, i: usize, snap: *const Snapshot, shared: *Shared, view: *ControlView) void {
    var buf: [160]u8 = undefined;
    if (ui.heading(p.name(), view.panelOpen(p.name()))) view.setPanel(p.name(), !view.panelOpen(p.name()));
    const open = view.panelOpen(p.name());
    ui.column(summary_column);
    ui.text(panelSummary(&buf, p), theme.text_dim);
    if (open) {
        ui.alignEnd(78, &.{i18n.text(.btn_reset)});
        if (ui.button(i18n.text(.btn_reset), false)) shared.push(.{ .panel = .{ .index = i, .action = .reset } });
    }
    ui.newline();
    if (open) {
        panelView(ui, p, i, shared);
        if (p.kind == .electrode) {
            panelFilter(ui, p, i, shared);
            panelCar(ui, p, i, shared);
        }
        if (p.mode == .triggered) panelTrigger(ui, p, i, snap, shared);
    }
    ui.separator();
}

/// "triggered   -1.0 / +2.0 ms   50 µV/row   band 300–6000 Hz   CAR   on spikes, row 5".
fn panelSummary(buf: []u8, p: *const panels.Panel) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var value_buf: [48]u8 = undefined;
    // Cut where the buffer ends (the writer keeps what fit).
    const time_text = if (p.mode == .triggered)
        format.fmt(&value_buf, "-{d:.1} / +{d:.1} ms", .{ p.trigger.pre_ms, p.trigger.post_ms })
    else
        format.fmtSpan(&value_buf, p.span_s);
    w.print("{s}   {s}", .{ modeText(p.mode), time_text }) catch {};
    if (p.kind != .ttl) i18n.print(&w, .title_per_row, .{ .scale = format.fmtScale(&value_buf, p.kind, p.scale) }) catch {};
    if (p.kind == .electrode) {
        const f = p.filter;
        if (!f.on) {
            w.writeAll(i18n.text(.title_raw)) catch {};
        } else if (f.low_hz > 0 and f.high_hz > 0) {
            i18n.print(&w, .summary_band_range, .{ .low = f.low_hz, .high = f.high_hz }) catch {};
        } else if (f.high_hz > 0) {
            i18n.print(&w, .summary_band_below, .{ .high = f.high_hz }) catch {};
        } else if (f.low_hz > 0) {
            i18n.print(&w, .summary_band_above, .{ .low = f.low_hz }) catch {};
        } else w.writeAll(i18n.text(.summary_band_none)) catch {};
        if (p.reference.on) w.writeAll(i18n.text(.title_car)) catch {};
    }
    if (p.mode == .triggered) {
        if (p.trigger.source == .ttl) {
            i18n.print(&w, .summary_on_ttl, .{ .line = p.trigger.line }) catch {};
        } else i18n.print(&w, .summary_on_spikes, .{ .row = p.trigger.row + 1 }) catch {};
    }
    return w.buffered();
}

/// The panel's mode, time base and scale.
fn panelView(ui: *ui_mod.Ui, p: *const panels.Panel, i: usize, shared: *Shared) void {
    var buf: [160]u8 = undefined;
    ui.text(i18n.text(.label_view), theme.text_dim);
    ui.column(64);
    inline for (.{ panels.Mode.scroll, panels.Mode.sweep, panels.Mode.triggered }) |m| {
        if (ui.button(modeText(m), p.mode == m) and p.mode != m) shared.push(.{ .panel = .{ .index = i, .action = .{ .mode = m } } });
    }
    ui.space(14);
    var value_buf: [48]u8 = undefined;
    const time_text = if (p.mode == .triggered)
        format.fmt(&value_buf, "-{d:.1} / +{d:.1} ms", .{ p.trigger.pre_ms, p.trigger.post_ms })
    else
        format.fmtSpan(&value_buf, p.span_s);
    const dt = ui.stepper(if (p.mode == .triggered) i18n.text(.label_window) else i18n.text(.label_time), time_text, 130);
    if (dt != 0) shared.push(.{ .panel = .{ .index = i, .action = .{ .zoom = if (dt > 0) step_up else 1.0 / step_up } } });
    if (p.kind != .ttl) {
        var scale_buf: [32]u8 = undefined;
        const ds = ui.stepper(i18n.text(.label_scale), i18n.fmt(&buf, .stepper_per_row, .{ .scale = format.fmtScale(&scale_buf, p.kind, p.scale) }), 110);
        if (ds != 0) shared.push(.{ .panel = .{ .index = i, .action = .{ .scale = if (ds > 0) step_up else 1.0 / step_up } } });
    }
    ui.newline();
}

/// An electrode panel's display filter: raw or band, its corners, and row by row which
/// rows are shown and (filter on) which go through the filter.
fn panelFilter(ui: *ui_mod.Ui, p: *const panels.Panel, i: usize, shared: *Shared) void {
    var value_buf: [48]u8 = undefined;
    ui.text(i18n.text(.label_filter), theme.text_dim);
    ui.column(64);
    if (ui.button(i18n.text(.btn_raw), !p.filter.on) and p.filter.on) shared.push(.{ .panel = .{ .index = i, .action = .{ .filter = false } } });
    if (ui.button(i18n.text(.btn_band), p.filter.on) and !p.filter.on) shared.push(.{ .panel = .{ .index = i, .action = .{ .filter = true } } });
    if (p.filter.on) {
        ui.space(14);
        const lo = ui.stepper(i18n.text(.label_low), if (p.filter.low_hz > 0) format.fmt(&value_buf, "{d} Hz", .{p.filter.low_hz}) else i18n.text(.toggle_off), 80);
        if (lo != 0) shared.push(.{ .panel = .{ .index = i, .action = .{ .corner = .{ .high = false, .up = lo > 0 } } } });
        const hi = ui.stepper(i18n.text(.label_high), if (p.filter.high_hz > 0) format.fmt(&value_buf, "{d} Hz", .{p.filter.high_hz}) else i18n.text(.toggle_off), 80);
        if (hi != 0) shared.push(.{ .panel = .{ .index = i, .action = .{ .corner = .{ .high = true, .up = hi > 0 } } } });
    }
    ui.newline();
    // Row by row: which are shown, and (filter on) which go through the filter.
    inline for (.{ i18n.Id.label_rows_shown, i18n.Id.label_filtered }, .{ true, false }) |label_id, is_shown| {
        const label = i18n.text(label_id);
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
    ui.text(i18n.text(.label_car), theme.text_dim);
    ui.column(64);
    if (ui.button(i18n.text(.toggle_off), !p.reference.on) and p.reference.on) shared.push(.{ .panel = .{ .index = i, .action = .{ .car = false } } });
    if (ui.button(i18n.text(.toggle_on), p.reference.on) and !p.reference.on) shared.push(.{ .panel = .{ .index = i, .action = .{ .car = true } } });
    if (p.reference.on) {
        ui.newline();
        inline for (.{ i18n.Id.label_average_of, i18n.Id.label_subtract_from }, .{ true, false }) |label_id, is_ref| {
            const label = i18n.text(label_id);
            const rows = if (is_ref) &p.reference.ref else &p.reference.sub;
            ui.text(label, theme.text_dim);
            ui.column(104);
            const saved_indent = ui.indent;
            ui.indent = 104;
            if (ui.button(i18n.text(.btn_all), false))
                shared.push(.{ .panel = .{ .index = i, .action = if (is_ref) .{ .car_ref_all = true } else .{ .car_sub_all = true } } });
            if (ui.button(i18n.text(.btn_none), false))
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

/// A triggered panel's trigger: a TTL line, or (electrodes) a crossing of a row's channel's
/// threshold: its level, which a stepper scales, and its slope, which the falling / rising
/// pair flips.
fn panelTrigger(ui: *ui_mod.Ui, p: *const panels.Panel, i: usize, snap: *const Snapshot, shared: *Shared) void {
    var value_buf: [48]u8 = undefined;
    ui.text(i18n.text(.label_trigger), theme.text_dim);
    ui.column(64);
    if (p.kind == .electrode) {
        if (ui.button(i18n.text(.btn_ttl), p.trigger.source == .ttl) and p.trigger.source != .ttl)
            shared.push(.{ .panel = .{ .index = i, .action = .{ .trig_source = .ttl } } });
        if (ui.button(i18n.text(.btn_spikes), p.trigger.source == .channel) and p.trigger.source != .channel)
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
        const dw = ui.stepper("", i18n.fmt(&value_buf, .trigger_row_value, .{ .row = p.trigger.row + 1 }), 60);
        if (dw != 0) shared.push(.{ .panel = .{ .index = i, .action = .{ .trig_row = dw } } });
        // The trigger channel's threshold, if known (it is latched once known); until then
        // it follows the noise, falling.
        const ch = p.first_ch + p.trigger.row;
        const uv = snap.thresholds.known(&snap.reported, ch);
        const rising = if (uv) |v| v > 0 else false;
        if (ui.button(i18n.text(.slope_falling), !rising) and rising) shared.push(.{ .threshold = .{ .flip = ch } });
        if (ui.button(i18n.text(.slope_rising), rising) and !rising) shared.push(.{ .threshold = .{ .flip = ch } });
        ui.newline();
        ui.text(i18n.text(.label_level), theme.text_dim);
        ui.column(64);
        // "+" makes the level larger in size, whichever its sign.
        const level_text = if (uv) |v|
            format.fmt(&value_buf, "{d:.0} µV", .{v})
        else
            format.fmt(&value_buf, "{d} σ", .{snap.thresholds.sigmas});
        const dv = ui.stepper("", level_text, 70);
        if (dv != 0) shared.push(.{ .threshold = .{ .scale = .{ .channel = ch, .factor = if (dv > 0) 1.15 else 1.0 / 1.15 } } });
        const dh = ui.stepper(i18n.text(.label_holdoff), format.fmt(&value_buf, "{d} ms", .{p.trigger.holdoff_ms}), 60);
        if (dh != 0) shared.push(.{ .panel = .{ .index = i, .action = .{ .trig_holdoff = dh > 0 } } });
    }
    const dn = ui.stepper(i18n.text(.label_overlaid), i18n.count(&value_buf, "stepper_sweeps", p.trigger.overlay, .{ .count = p.trigger.overlay }), 90);
    if (dn != 0)
        shared.push(.{ .panel = .{ .index = i, .action = .{
            .overlay = @intCast(std.math.clamp(@as(i32, @intCast(p.trigger.overlay)) + dn, 1, dimna.sweeps.max_sweeps)),
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
// Set DIMNA_CONTROL_LAYOUT_OUT to a path to write what this run produced there.

var layout_atlas: [1]u8 = .{0};

fn layoutFont() font.Font {
    var f: font.Font = .{ .atlas = &layout_atlas, .px = 14, .ascent = 12, .line_height = 16 };
    for (&f.glyphs, 0..) |*g, k| g.* = .{ .x = @intCast(8 + k), .y = 8, .w = 1, .h = 1, .top = 12, .advance = 8 };
    return f;
}

/// The code point of glyph `k` of `layoutFont` (as `font.Font.glyph` numbers them).
fn layoutCodepoint(k: usize) u21 {
    const extra = [_]u21{ 0x03C3, 0x2013, 0x2192, 0x266A, 0x25B8, 0x25BE };
    return if (k < 224) @intCast(32 + k) else extra[k - 224];
}

const LayoutRig = struct {
    face: font.Font,
    vertices: []font.Vertex,
    batch: font.Batch = undefined,
    shared: Shared = .{},
    cfg: Config = undefined,
    /// The sections open at the start of every frame, and after it (a click on a heading
    /// changes it).
    start_view: ControlView = .{},
    view: ControlView = .{},
    /// Mirrored, as for a language read right to left.
    rtl: bool = false,
    /// The window's width.
    width: f32 = 800,

    fn frame(self: *LayoutRig, snap: *const Snapshot, mx: f32, my: f32, clicked: bool) ui_mod.Ui {
        self.batch = .{ .font = &self.face, .vertices = self.vertices };
        self.shared = .{};
        self.view = self.start_view;
        var ui: ui_mod.Ui = .begin(&self.batch, self.width, mx, my, clicked, 0, self.rtl);
        build(&ui, &self.cfg, snap, &self.shared, &self.view);
        return ui;
    }
};

/// The sections a frozen state has open, for `snap`'s panels.
fn layoutView(open: LayoutOpen, snap: *const Snapshot) ControlView {
    var v: ControlView = .{ .notes = open.all or open.notes, .audio = open.all or open.audio, .headstages = open.all or open.headstages };
    if (open.all) {
        for (snap.set.items[0..snap.set.len]) |*p| v.setPanel(p.name(), true);
    } else for (open.panels) |name| v.setPanel(name, true);
    return v;
}

/// " notes audio [Port A]": what is open.
fn writeView(w: *std.Io.Writer, v: *const ControlView) !void {
    if (v.notes) try w.writeAll(" notes");
    if (v.audio) try w.writeAll(" audio");
    if (v.headstages) try w.writeAll(" headstages");
    try w.writeAll(" [");
    for (0..v.num_panels) |k| try w.print("{s}{s}", .{ if (k > 0) ", " else "", v.name(k) });
    try w.writeAll("]");
}

/// " -> edit" for each edit queued; returns the last view queued, if any.
fn writeEdits(w: *std.Io.Writer, shared: *Shared) !?ControlView {
    // A panel edit is written flat, so its action is not nested too deeply to print.
    var queued_view: ?ControlView = null;
    while (shared.pop()) |e| switch (e) {
        .panel => |pe| try w.print(" -> panel {d} {any}", .{ pe.index, pe.action }),
        .control_view => |cv| {
            queued_view = cv;
            try w.writeAll(" -> control_view:");
            try writeView(w, &cv);
        },
        else => try w.print(" -> {any}", .{e}),
    };
    return queued_view;
}

fn writeLayout(w: *std.Io.Writer, rig: *LayoutRig, name: []const u8, snap: *const Snapshot, open: LayoutOpen) !void {
    rig.start_view = layoutView(open, snap);
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
            const queued_view = try writeEdits(w, &rig.shared);
            // A heading opens or closes its section, and the display thread is told what is
            // open now; nothing else tells it.
            if (rig.view.eql(&rig.start_view)) {
                try testing.expect(queued_view == null);
            } else try testing.expect(queued_view != null and queued_view.?.eql(&rig.view));
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

/// Which sections a frozen state has open.
const LayoutOpen = struct {
    all: bool = false,
    notes: bool = false,
    audio: bool = false,
    headstages: bool = false,
    /// The panels open, by name.
    panels: []const []const u8 = &.{},
};

const LayoutState = struct { name: []const u8, open: LayoutOpen };

const layout_states = [_]LayoutState{
    .{ .name = "not recording, all open", .open = .{ .all = true } },
    .{ .name = "recording, all open", .open = .{ .all = true } },
    .{ .name = "review active, all open", .open = .{ .all = true } },
    .{ .name = "quit prompt, all open", .open = .{ .all = true } },
    .{ .name = "restart pending, all open", .open = .{ .all = true } },
    .{ .name = "two panels: slope trigger, reference; all open", .open = .{ .all = true } },
    .{ .name = "alarm, all open", .open = .{ .all = true } },
    .{ .name = "other panels, all open", .open = .{ .all = true } },
    .{ .name = "notes open", .open = .{ .notes = true } },
    .{ .name = "audio open", .open = .{ .audio = true } },
    .{ .name = "headstages open", .open = .{ .headstages = true } },
    .{ .name = "Port B open of two panels", .open = .{ .panels = &.{"Port B"} } },
    .{ .name = "all closed", .open = .{} },
    .{ .name = "all closed, recording: Headstages open by itself", .open = .{} },
    .{ .name = "all closed, Headstages open by itself: restart pending", .open = .{} },
    .{ .name = "all closed, Headstages open by itself: settings not the config file's", .open = .{} },
    .{ .name = "AUX open of four panels", .open = .{ .panels = &.{"AUX"} } },
    .{ .name = "panel summaries: triggered, filtered, TTL", .open = .{} },
};

/// The snapshots the layout is frozen for (one per `layout_states`), written into `out`.
fn layoutSnapshots(out: []Snapshot) void {
    out[0] = layoutBase();
    stateSnapshots(out, &out[0]);
    panelSnapshots(out, &out[0]);
    // One section open at a time.
    out[8] = out[0];
    out[9] = out[0];
    out[10] = out[0];
    out[11] = out[5];
    // Closed: the summaries; Headstages kept open by a restart pending (while recording,
    // and not) and by settings that differ from the config file.
    out[12] = out[0];
    out[13] = out[1];
    out[14] = out[4];
    out[15] = out[0];
    out[15].board.unsaved = true;
    out[15].board.setNote("view saved to {s}", .{"/home/user/.config/dimna/views.toml"});
    out[16] = out[7];
    out[17] = summarySnapshot(&out[0]);
}

/// Panels whose summaries say the most: triggered on a row's spikes and filtered;
/// filtered with one corner and the reference on; triggered on a TTL line. Audio off and
/// muted; no notes, one preset; a headstage in half-channel mode, the DSP off.
fn summarySnapshot(base: *const Snapshot) Snapshot {
    var s = base.*;
    var a = layoutPanel("Port A", .electrode, 32);
    a.mode = .triggered;
    a.trigger.source = .channel;
    a.trigger.row = 4;
    a.trigger.pre_ms = 1;
    a.trigger.post_ms = 2;
    a.filter.on = true;
    var b = layoutPanel("Port B", .electrode, 16);
    b.filter.on = true;
    b.filter.low_hz = 0;
    b.setCar(true);
    var t = layoutPanel("TTL", .ttl, 8);
    t.mode = .triggered;
    t.trigger.line = 3;
    s.set.items[0] = a;
    s.set.items[1] = b;
    s.set.items[2] = t;
    s.set.len = 3;
    s.audio.settings.enabled = false;
    s.audio.settings.mute = true;
    s.notes.num_recent = 0;
    s.notes.presets[3].len = 0;
    s.board.settings.dsp_enabled = false;
    s.board.settings.rhd2132_16ch[0] = true;
    s.board.pending = s.board.settings;
    return s;
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
    setText(&s.quit_prompt.path_buf, &s.quit_prompt.path_len, "/home/user/.config/dimna/dimna.toml");
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
    s.thresholds.set(4, -62);
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

    // Other panels: a slope trigger at a fixed level, rising; AUX, ADC and a TTL panel
    // triggered on TTL; the status not yet valid; the recording finishing.
    s = base.*;
    s.status = .{};
    s.rec.state = .stopping;
    var t = layoutPanel("TTL", .ttl, 8);
    t.mode = .triggered;
    var e = layoutPanel("Port C", .electrode, 4);
    e.mode = .triggered;
    e.trigger.source = .channel;
    s.thresholds.set(0, 48.4);
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

/// The frozen layout of every state in `layout_states`, as text (owned by the caller);
/// with `rtl`, mirrored.
fn layoutText(gpa: std.mem.Allocator, rtl: bool) ![]u8 {
    const no_env: Env = .{};
    const rig = try createRig(gpa, &no_env);
    defer destroyRig(gpa, rig);
    rig.rtl = rtl;
    const snaps = try gpa.alloc(Snapshot, layout_states.len);
    defer gpa.free(snaps);
    layoutSnapshots(snaps);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (layout_states, snaps) |state, *snap| try writeLayout(&out.writer, rig, state.name, snap, state.open);
    return out.toOwnedSlice();
}

/// Writes `got` to the path in the environment variable `env_name`, if it is set.
fn writeIfAsked(env_name: [*:0]const u8, got: []const u8) !void {
    const path = std.c.getenv(env_name) orelse return;
    const file = try std.Io.Dir.cwd().createFile(testing.io, std.mem.span(path), .{});
    defer file.close(testing.io);
    try file.writeStreamingAll(testing.io, got);
}

test "the control window's layout is unchanged" {
    const got = try layoutText(testing.allocator, false);
    defer testing.allocator.free(got);
    try writeIfAsked("DIMNA_CONTROL_LAYOUT_OUT", got);
    try testing.expectEqualStrings(@embedFile("testdata/control_layout.txt"), got);
}

// The mirrored layout (a language read right to left), frozen as a record in
// `testdata/control_layout_rtl.txt` (DIMNA_CONTROL_LAYOUT_RTL_OUT writes this run's). The
// test after it is the proof that it is the mirror of the one above.
test "the control window's mirrored layout is unchanged" {
    const got = try layoutText(testing.allocator, true);
    defer testing.allocator.free(got);
    try writeIfAsked("DIMNA_CONTROL_LAYOUT_RTL_OUT", got);
    try testing.expectEqualStrings(@embedFile("testdata/control_layout_rtl.txt"), got);
}

/// A rectangle, or a run of glyphs (same row and colour, 8 pixels apart), of a frame drawn
/// with `layoutFont`: quads `first`..`first + n` of it.
const LayoutItem = struct {
    glyphs: bool,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    colour: font.Colour,
    first: usize,
    n: usize,
};

/// The glyph number in `layoutFont` of a quad (its atlas position), or null for a rectangle.
fn layoutGlyph(v: font.Vertex) ?usize {
    const u = v.uv[0] * font.atlas_size;
    return if (u < 8) null else @intFromFloat(u - 8);
}

/// The rectangles and runs of glyphs of `verts`, in the order drawn.
fn layoutItems(gpa: std.mem.Allocator, verts: []const font.Vertex) ![]LayoutItem {
    var items: std.ArrayList(LayoutItem) = .empty;
    errdefer items.deinit(gpa);
    const quads = verts.len / 6;
    var q: usize = 0;
    while (q < quads) {
        const v = verts[q * 6 ..][0..6];
        var item: LayoutItem = .{
            .glyphs = false,
            .x = v[0].pos[0],
            .y = v[0].pos[1],
            .w = v[2].pos[0] - v[0].pos[0],
            .h = v[2].pos[1] - v[0].pos[1],
            .colour = v[0].colour,
            .first = q,
            .n = 1,
        };
        if (layoutGlyph(v[0]) != null) {
            item.glyphs = true;
            item.n = 0;
            while (q + item.n < quads) : (item.n += 1) {
                const g = verts[(q + item.n) * 6 ..][0..6];
                if (layoutGlyph(g[0]) == null or g[0].pos[0] != item.x + 8 * @as(f32, @floatFromInt(item.n)) or
                    g[0].pos[1] != item.y or !std.mem.eql(u8, &g[0].colour, &item.colour)) break;
            }
            item.w = 8 * @as(f32, @floatFromInt(item.n));
        }
        try items.append(gpa, item);
        q += item.n;
    }
    return items.toOwnedSlice(gpa);
}

/// A rig for `layoutFont` frames, made with `gpa` (`destroyRig` frees it).
fn createRig(gpa: std.mem.Allocator, no_env: *const Env) !*LayoutRig {
    const vertices = try gpa.alloc(font.Vertex, 6 * 8192);
    errdefer gpa.free(vertices);
    const rig = try gpa.create(LayoutRig);
    rig.* = .{ .face = layoutFont(), .vertices = vertices };
    rig.cfg = .{ .gpa = gpa, .shared = &rig.shared, .display_gpu = undefined, .env = no_env };
    return rig;
}

fn destroyRig(gpa: std.mem.Allocator, rig: *LayoutRig) void {
    gpa.free(rig.vertices);
    gpa.destroy(rig);
}

// ---- Fit check (opt-in: DIMNA_FIT_CHECK=1) ----
//
// Every frozen state of the layout, in every language, with the real font (fontconfig's
// "sans-serif" at 14 px, or DIMNA_FIT_FONT; Persian and Chinese from its fallbacks) at
// DIMNA_FIT_WIDTH (800) pixels. Per language: how much taller the window gets than in
// English (more rows wrapped), every text or box that runs past the right edge, and every
// message cut to its buffer. It prints a report and fails only on a cut or an overrun.

test "fit check: every language's texts fit the control window" {
    const flag = std.c.getenv("DIMNA_FIT_CHECK") orelse return error.SkipZigTest;
    _ = flag;
    const gpa = testing.allocator;
    const width: f32 = if (std.c.getenv("DIMNA_FIT_WIDTH")) |w| try std.fmt.parseFloat(f32, std.mem.span(w)) else 800;
    const family: [:0]const u8 = if (std.c.getenv("DIMNA_FIT_FONT")) |f| std.mem.span(f) else "sans-serif";
    const no_env: Env = .{};
    const snaps = try gpa.alloc(Snapshot, layout_states.len);
    defer gpa.free(snaps);
    layoutSnapshots(snaps);
    const saved_lang = i18n.current;
    defer i18n.current = saved_lang;
    const shape = @import("shape.zig");
    const saved_rtl = shape.start_rtl;
    defer shape.start_rtl = saved_rtl;

    var english_h: [layout_states.len]f32 = undefined;
    var problems: usize = 0;
    for (std.enums.values(i18n.Language)) |lang| {
        i18n.current = lang;
        shape.start_rtl = i18n.rightToLeft(lang);
        var face = try font.Font.init(gpa, family, 14);
        defer face.deinit(gpa);
        const rig = try createRig(gpa, &no_env);
        defer destroyRig(gpa, rig);
        rig.face = face;
        rig.rtl = i18n.rightToLeft(lang);
        rig.width = width;
        i18n.cuts_len = 0;
        var tallest: f32 = 0;
        var worst_grow: f32 = 0;
        var worst_state: []const u8 = "";
        std.debug.print("== {t}\n", .{lang});
        for (layout_states, snaps, 0..) |state, *snap, k| {
            rig.start_view = layoutView(state.open, snap);
            const ui = rig.frame(snap, -1, -1, false);
            try testing.expect(rig.batch.len + 6 <= rig.vertices.len);
            const h = ui.y;
            tallest = @max(tallest, h);
            if (lang == .en) english_h[k] = h;
            if (h - english_h[k] > worst_grow) {
                worst_grow = h - english_h[k];
                worst_state = state.name;
            }
            // Past an edge: any quad (mirrored: past the left edge).
            var q: usize = 0;
            var reported: usize = 0;
            while (q < rig.batch.len / 6) : (q += 1) {
                const v = rig.vertices[q * 6 ..][0..6];
                const x0 = v[0].pos[0];
                const x1 = v[2].pos[0];
                if (x1 > width + 0.5 or x0 < -0.5) {
                    if (reported < 3) std.debug.print("   {s}: past the edge at y {d}: x {d:.0}..{d:.0}\n", .{ state.name, v[0].pos[1], x0, x1 });
                    reported += 1;
                }
            }
            if (reported > 0) problems += 1;
        }
        const rows = worst_grow / (@round(rig.face.line_height) + 12);
        std.debug.print("   most growth over English: {d:.0} px ({d:.1} rows) in \"{s}\"; tallest state {d:.0} px\n", .{ worst_grow, rows, worst_state, tallest });
        // The key summary over the display (two columns of keys and what they do), about as
        // `display.helpPanel` lays it out: the ordinary font throughout, so roughly.
        const key_help = @import("display.zig").key_help;
        var key_w: [2]f32 = @splat(0);
        var what_w: [2]f32 = @splat(0);
        for (key_help) |kh| {
            const col = @backingInt(kh.window);
            key_w[col] = @max(key_w[col], face.width(i18n.textOf(kh.key)));
            what_w[col] = @max(what_w[col], face.width(i18n.textOf(kh.what)));
        }
        const sp = face.width("  ");
        std.debug.print("   key summary about {d:.0} px wide\n", .{key_w[0] + what_w[0] + key_w[1] + what_w[1] + 2 * sp + 2 * face.width("  ") + 24});
        for (i18n.cuts[0..i18n.cuts_len]) |c| std.debug.print("   cut to its buffer: {s}\n", .{c});
        problems += i18n.cuts_len;
    }
    try testing.expectEqual(0, problems);
}

test "mirrored, every rectangle and text of the control window is the mirror of its unmirrored one, and does the same" {
    const gpa = testing.allocator;
    const no_env: Env = .{};
    const rig = try createRig(gpa, &no_env);
    defer destroyRig(gpa, rig);
    const snaps = try gpa.alloc(Snapshot, layout_states.len);
    defer gpa.free(snaps);
    layoutSnapshots(snaps);
    const width = 800;
    const closed_triangle = 224 + 4; // ▸ in `layoutFont`
    const missing = '?' - 32; // ◂, which `layoutFont` does not have
    var turned: usize = 0;
    var rects: usize = 0;
    var runs: usize = 0;
    for (layout_states, snaps) |state, *snap| {
        errdefer std.debug.print("in state \"{s}\"\n", .{state.name});
        rig.start_view = layoutView(state.open, snap);
        var frames: [2][]font.Vertex = undefined;
        var items: [2][]LayoutItem = undefined;
        for (0..2) |k| {
            rig.rtl = k == 1;
            _ = rig.frame(snap, -1, -1, false);
            try testing.expect(rig.batch.len + 6 <= rig.vertices.len);
            frames[k] = try gpa.dupe(font.Vertex, rig.vertices[0..rig.batch.len]);
            items[k] = try layoutItems(gpa, frames[k]);
        }
        defer for (frames, items) |f, it| {
            gpa.free(f);
            gpa.free(it);
        };
        try testing.expectEqual(frames[0].len, frames[1].len);
        try testing.expectEqual(items[0].len, items[1].len);
        for (items[0], items[1]) |a, b| {
            try testing.expectEqual(a.glyphs, b.glyphs);
            try testing.expectEqual(width - a.x - a.w, b.x);
            try testing.expectEqual(a.y, b.y);
            try testing.expectEqual(a.w, b.w);
            try testing.expectEqual(a.h, b.h);
            try testing.expectEqual(a.colour, b.colour);
            try testing.expectEqual(a.n, b.n);
            if (a.glyphs) {
                runs += 1;
                // The same text, but for a closed heading's triangle, which turns.
                for (0..a.n) |j| {
                    const ga = layoutGlyph(frames[0][(a.first + j) * 6]).?;
                    const gb = layoutGlyph(frames[1][(b.first + j) * 6]).?;
                    if (j == 0 and ga == closed_triangle) {
                        try testing.expectEqual(missing, gb);
                        turned += 1;
                    } else try testing.expectEqual(ga, gb);
                }
                continue;
            }
            rects += 1;
            // A click in the middle of the mirrored rectangle does what one in the middle
            // of the rectangle does.
            var edits: [2][1024]u8 = undefined;
            var lens: [2]usize = undefined;
            for (0..2) |k| {
                rig.rtl = k == 1;
                const r = if (k == 0) a else b;
                _ = rig.frame(snap, r.x + r.w / 2, r.y + r.h / 2, true);
                var w: std.Io.Writer = .fixed(&edits[k]);
                _ = try writeEdits(&w, &rig.shared);
                lens[k] = w.buffered().len;
            }
            try testing.expectEqualStrings(edits[0][0..lens[0]], edits[1][0..lens[1]]);
        }
    }
    std.debug.print("mirrored layout: {d} rectangles, {d} runs of text, {d} triangles turned\n", .{ rects, runs, turned });
    try testing.expect(turned > 10);
    try testing.expect(rects > 500 and runs > 500);
}

test "mirrored, a click where a button is drawn is that button's, and one where it would be unmirrored is not" {
    const gpa = testing.allocator;
    const no_env: Env = .{};
    const rig = try createRig(gpa, &no_env);
    defer destroyRig(gpa, rig);
    const snap = layoutBase();
    // "Record" is at x 12..78, y 102..126 unmirrored (control_layout.txt); mirrored, at
    // 722..788. Its middle: x 45 unmirrored, 755 mirrored.
    const Case = struct { rtl: bool, x: f32, record: bool };
    for ([_]Case{
        .{ .rtl = false, .x = 45, .record = true },
        .{ .rtl = false, .x = 755, .record = false },
        .{ .rtl = true, .x = 755, .record = true },
        .{ .rtl = true, .x = 45, .record = false },
        // The edges: a drawn box takes in its left edge, not its right.
        .{ .rtl = true, .x = 722, .record = true },
        .{ .rtl = true, .x = 787.9, .record = true },
        .{ .rtl = true, .x = 788, .record = false },
        .{ .rtl = true, .x = 721.9, .record = false },
    }) |c| {
        errdefer std.debug.print("case {any}\n", .{c});
        rig.rtl = c.rtl;
        _ = rig.frame(&snap, c.x, 114, true);
        var got_record = false;
        while (rig.shared.pop()) |e| switch (e) {
            .record => |on| got_record = on,
            else => return error.UnexpectedEdit,
        };
        try testing.expectEqual(c.record, got_record);
    }
}

test "which sections are open is saved with the view, but is not by itself something to ask about" {
    const session = @import("session.zig");
    const gpa = testing.allocator;
    const io = testing.io;
    var set: panels.Set = .{};
    set.items[0] = layoutPanel("Port A", .electrode, 6);
    set.len = 1;
    const tiles: dimna.tile_view.TileView = .{};
    const thresholds: dimna.thresholds.Thresholds = .{};
    const layout: dimna.types.Layout = .{ .sample_rate = 30000, .hw_clock_hz = 50e6, .num_electrodes = 6 };
    var open: ControlView = .{};
    const view: session.ViewFile.View = .{ .set = &set, .tiles = &tiles, .thresholds = &thresholds, .layout = &layout, .control = &open };
    var view_file = try session.ViewFile.init(gpa, view);
    defer view_file.deinit(gpa);
    try testing.expect(!view_file.unsaved(view));
    // Opening sections is not a change to be asked about on quitting ...
    open.setPanel("Port A", true);
    open.audio = true;
    try testing.expect(!view_file.unsaved(view));
    // ... but a change to a panel is, with sections open or not.
    set.items[0].span_s = 0.5;
    try testing.expect(view_file.unsaved(view));
    // Saving writes the [control] table after the others, and then nothing is unsaved.
    var path_buf: [96]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, "/tmp/dimna-control-view-test-{d}", .{dimna.os.getpid()});
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var file_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&file_buf, "{s}/views.toml", .{dir});
    try view_file.save(io, path, view);
    try testing.expect(!view_file.unsaved(view));
    const written = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(written);
    const want = "\n[thresholds]\nsigmas = 4.5\nfixed_uv = [0, 0, 0, 0, 0, 0]\n" ++
        "\n[control]\nnotes = false\naudio = true\nheadstages = false\npanels = \"Port A\"\n";
    try testing.expect(std.mem.endsWith(u8, written, want));
    open = .{};
    try testing.expect(!view_file.unsaved(view));
}
