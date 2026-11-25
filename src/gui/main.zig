//! dimna: the GUI's main thread. It owns the neural display (a Wayland window drawn with
//! Vulkan, fullscreen on its own monitor in normal use) and runs the one loop that moves
//! samples from the acquisition ring into the GPU's history, takes input, and draws.
//!
//! Other threads, each started here and each fed by a lock-free snapshot or queue:
//!   acquisition (acquisition.zig)   board or simulator -> ring
//!   recorder (record.zig)           ring -> files; started and stopped from the control window
//!   control window (control.zig)    status and settings with buttons
//!   spike tiles (tiles.zig)         a third window
//!   audio (audio_out.zig)           the spike monitor
//! The display reads the ring with a lossy reader, so it can never hold acquisition or the
//! recorder back.
//!
//! What the loop does each turn is in `runDisplay` below, in order; the state each part keeps
//! between turns is in session.zig (recording, review, alarms, view file, board settings),
//! pacing.zig (when to draw, latency figures) and display.zig (panels, input, drawing).
//!
//! Options: args.zig (`dimna --help`). Keys and the mouse: docs/display.md. The config
//! file ($XDG_CONFIG_HOME/dimna/config.toml; command-line options win) and `[[panel]]`
//! tables: args.zig and src/panels.zig. How frames are paced and what latency was
//! measured: docs/latency.md. Scripted input for tests (--script): script.zig.

const std = @import("std");
const builtin = @import("builtin");
const dimna = @import("dimna");
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const gpu_mod = @import("gpu.zig");
const Gpu = gpu_mod.Gpu;
const font = @import("font.zig");
const fontfind = @import("fontfind.zig");
const format = @import("format.zig");
const i18n = @import("i18n.zig");
const shape = @import("shape.zig");
const fmtSpan = format.fmtSpan;
const fmtScale = format.fmtScale;
const control = @import("control.zig");
const audio_out = @import("audio_out.zig");
const audio_alsa = @import("audio_alsa.zig");
const notes_mod = @import("notes.zig");
const tiles_mod = @import("tiles.zig");
const Status = display_mod.Status;
const Io = std.Io;
const log = std.log.scoped(.dimna);
const args_mod = @import("args.zig");
const scheme = @import("scheme.zig");
const theme = @import("theme.zig");
const Args = args_mod.Args;
const parseArgs = args_mod.parseArgs;
const runScript = @import("script.zig").runScript;
const display_mod = @import("display.zig");
const Display = display_mod.Display;
const Text = display_mod.Text;
const ReviewView = display_mod.ReviewView;
const makeDisplay = display_mod.makeDisplay;
const refilterSamples = display_mod.refilterSamples;
const channelName = display_mod.channelName;
const max_draws = display_mod.max_draws;
const max_fills = display_mod.max_fills;
const files = @import("files.zig");
const renderViews = files.renderViews;
const writeAtomic = files.writeAtomic;
const session = @import("session.zig");
const Pacer = @import("pacing.zig").Pacer;
const Env = @import("env.zig").Env;
const Pipeline = @import("pipeline.zig").Pipeline;
const tile_link = @import("tile_link.zig");

pub const std_options: std.Options = .{ .log_level = .info };

const Input = @import("window.zig").Input;
const panels_mod = dimna.panels;
const Panel = panels_mod.Panel;
/// RAM for the overview of a recording: about 2.3 hours at 72 history columns in full
/// detail; beyond that the finest levels' oldest parts are let go.
const overview_budget = 1_500_000_000;

const nowNs = dimna.clock.nowNs;

/// The C library's (std.c does not declare it): the variable is for a library dimna loads,
/// PipeWire's ALSA plugin, which reads the C library's environment.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// Set by SIGTERM, SIGINT or SIGHUP (a shutdown, Ctrl-C in the terminal, the terminal
/// closed): the loop then ends as if quitting, so a recording in progress is closed
/// properly. Not asked about, unlike Ctrl+Q: whoever sends the signal has decided. The
/// handler is reset by its first signal, so a second one ends dimna at once.
var stop_signal: std.atomic.Value(std.posix.SIG) = .init(@fromBackingInt(@intCast(0)));

fn onStopSignal(sig: std.posix.SIG) callconv(.c) void {
    stop_signal.store(sig, .release);
}

fn catchStopSignals() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onStopSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART | std.posix.SA.RESETHAND,
    };
    for ([_]std.posix.SIG{ .TERM, .INT, .HUP }) |sig| std.posix.sigaction(sig, &act, null);
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    // Everything the environment can change, read once (see env.zig).
    const env = Env.read();
    // The config file, if there is one.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    // Not a label: a path too long for the buffer is "", and the run starts without a
    // config, as if there were none, without saying why.
    const config_path = if (init.environ_map.get("XDG_CONFIG_HOME")) |x|
        std.fmt.bufPrint(&path_buf, "{s}/dimna/config.toml", .{x}) catch ""
    else
        std.fmt.bufPrint(&path_buf, "{s}/.config/dimna/config.toml", .{init.environ_map.get("HOME") orelse ""}) catch "";
    const config_text: []const u8 = Io.Dir.cwd().readFileAlloc(io, config_path, init.arena.allocator(), .limited(1 << 16)) catch "";
    if (config_text.len > 0) log.info("config: {s}", .{config_path});
    var toml_diag: dimna.toml.Diagnostics = .{};
    const doc = dimna.toml.parse(init.arena.allocator(), config_text, &toml_diag) catch {
        log.err("{s}: syntax error on line {d}", .{ config_path, toml_diag.line });
        return 2;
    };
    var args = parseArgs(argv, doc) catch |e| return if (e == error.Help) 0 else 2;
    // PipeWire's quantum to match a period other than the default (audio_alsa.zig,
    // `pipewireLatency`). Here, before any thread is started and before the sound device is
    // opened: setting the environment is not safe once other threads may read it. Linux
    // only: PipeWire has no meaning on macOS.
    if (@import("builtin").os.tag == .linux and args.audio) {
        const existing = init.environ_map.get("PIPEWIRE_LATENCY");
        var latency_buf: [32]u8 = undefined;
        if (audio_alsa.pipewireLatency(&latency_buf, args.audio_period, existing)) |value| {
            if (setenv("PIPEWIRE_LATENCY", value.ptr, 0) == 0) {
                log.info("audio_period {d}: PIPEWIRE_LATENCY={s}", .{ args.audio_period, value });
            } else log.warn("audio_period {d}: could not set PIPEWIRE_LATENCY", .{args.audio_period});
        } else if (existing) |v| if (args.audio_period != audio_out.default_period)
            log.info("audio_period {d}: PIPEWIRE_LATENCY is set already ({s}); left as it is", .{ args.audio_period, v });
    }
    // The language of every text, before any window draws.
    i18n.current = i18n.pick(args.language, init.environ_map.get("LANG") orelse "");
    // `--print-scheme`: derive and print the colours of an image, without a window or the board.
    if (args.print_scheme.len > 0) return scheme.printCommand(io, gpa, args.print_scheme, args.swatch);
    // The view file sits beside the config.
    var views_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    // Not a label: too long a path is "", and the view file is not read, without saying why.
    const views_path = std.fmt.bufPrint(&views_path_buf, "{s}/views.toml", .{std.fs.path.dirname(config_path) orelse "."}) catch "";
    const views_text: []const u8 = Io.Dir.cwd().readFileAlloc(io, views_path, init.arena.allocator(), .limited(1 << 18)) catch "";
    if (views_text.len > 0) {
        if (dimna.toml.parse(init.arena.allocator(), views_text, &toml_diag)) |vd| {
            args.views_doc = vd;
        } else |_| log.warn("{s}: syntax error on line {d}; the view file is ignored", .{ views_path, toml_diag.line });
    }
    // Everything else is the display's, run where this system's windowing wants it (on
    // Linux: here, on the main thread).
    return window_mod.run(runDisplay, .{ init, &env, &args, config_path, views_path });
}

/// The display's work and its exit status: what has to be settled before any window draws
/// (the language, the colour scheme), the source, the display's window, the pipeline and
/// the other windows' threads, the loop, and the teardown in the reverse order. `main`
/// has read the environment, the config, the arguments and the view file.
/// No board could be opened. Started as the Mac app (dimna.app's launcher sets `DIMNA_APP`:
/// there is no terminal, and the reason is only in the log), dimna says so in a dialog and
/// offers its simulator, so that a double-click without a board does not look like an app
/// that fails to start. True: run the simulator instead. Anywhere else: false (the caller
/// ends with status 1, as always).
fn simulateInstead(err: anyerror) bool {
    if (builtin.os.tag != .macos or std.c.getenv("DIMNA_APP") == null) return false;
    var buf: [600]u8 = undefined;
    const text = std.fmt.bufPrintSentinel(&buf,
        \\dimna could not open an Open Ephys acquisition board ({t}).
        \\
        \\Connect the board's USB 3 cable and its power, and close any other program that is using it; then open dimna again.
        \\
        \\Or run the simulator, to try dimna with two simulated headstages and no board. The log is in ~/Library/Logs/dimna/dimna.log.
    , .{err}, 0) catch return false;
    const simulate = window_mod.alert("No acquisition board found", text, "Run the Simulator", "Quit");
    if (simulate) log.info("no board: the simulator was chosen instead", .{});
    return simulate;
}

fn runDisplay(init: std.process.Init, env: *const Env, args: *const Args, config_path: []const u8, views_path: []const u8) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    // The colour scheme, if the config names an image. Before any window or thread draws;
    // any failure is a warning and the built-in colours stay. Either way a banner says so
    // over the display for its first seconds, and where to change it.
    // The language: one this machine cannot show (no font with its script, or for Persian
    // no shaping libraries) falls back to English, and a banner says what to install.
    var language_notice: display_mod.Notice = .{};
    if (i18n.needs(i18n.current)) |n| {
        const has_shaping = !n.shaping or shape.libs() != null;
        if (i18n.missing(i18n.current, fontfind.anyFontHas(n.sample), has_shaping)) |what| {
            log.warn("language {s}: {s} needs {s}; showing English", .{ @tagName(i18n.current), n.name, what });
            i18n.current = .en;
            var where_buf: [std.fs.max_path_bytes]u8 = undefined;
            language_notice.say(.notice_language_missing, .{ .language = n.name, .what = what }, .notice_language_where, .{ .where = files.tildePath(&where_buf, config_path, env.home) });
        }
    }
    // Sentences of a language read right to left are laid out right to left, in every
    // window's font (set before any font is made; the control window mirrors itself).
    shape.start_rtl = i18n.rightToLeft(i18n.current);
    var scheme_notice: display_mod.Notice = .{};
    if (args.scheme_image.len > 0) {
        var spath_buf: [std.fs.max_path_bytes]u8 = undefined;
        var sdiag: scheme.Diagnostics = .{};
        var where_buf: [std.fs.max_path_bytes]u8 = undefined;
        const where = files.tildePath(&where_buf, config_path, env.home);
        if (scheme.resolvePath(&spath_buf, args.scheme_image, env.home, std.fs.path.dirname(config_path) orelse ".")) |spath| {
            if (scheme.loadFile(io, gpa, spath, &sdiag)) |r| {
                theme.apply(r.scheme);
                log.info("colour scheme from {s}", .{spath});
                scheme_notice.say(.notice_colours_from, .{ .name = std.fs.path.basename(spath) }, .notice_colours_change, .{ .where = where });
            } else {
                log.warn("{s}; using the built-in colours", .{sdiag.message()});
                scheme_notice.say(.notice_colours_failed, .{ .reason = sdiag.message() }, .notice_colours_where, .{ .where = where });
            }
        } else log.warn("scheme image '{s}': the path is too long; using the built-in colours", .{args.scheme_image});
    } else if (builtin.os.tag == .macos) {
        // On macOS, with no image named: the colours of dimna's icon (the picture the
        // program carries for the Dock), which is what the owner's Linux rig names as its
        // `scheme_image`, so the two look alike. No banner: nothing was asked for.
        if (scheme.decode(@embedFile("dimna-icon.png"))) |img| {
            defer img.deinit();
            if (scheme.derivePixels(img.rgb, img.w, img.h, 4)) |r| {
                theme.apply(r.scheme);
                log.info("colour scheme from dimna's icon (the default on macOS; scheme_image in the config file changes it)", .{});
            }
        } else |_| {}
    }

    // ---- the source: simulator or board ----
    var board: ?dimna.board.Board = null;
    defer if (board) |*b| b.close();
    var sim: ?dimna.sim.Sim = null;
    defer if (sim) |*sm| sm.deinit();
    // The simulated headstages: those asked for, or, when dimna was started as the Mac app
    // and no board answered, the two the user chose to try it with (`simulateInstead`).
    var sim_spec: []const usize = args.sim[0..args.num_sim];
    if (sim_spec.len == 0) {
        var dirbuf: [std.fs.max_path_bytes:0]u8 = undefined;
        if (args.driver == .d3xx) _ = dimna.oni.configureDriverSearch(io, init.environ_map, &dirbuf);
        if (!dimna.acquisition.lockMemory()) log.warn("mlockall failed; pages may be swapped out", .{});
        if (dimna.board.Board.open(io, args.driver)) |b| {
            board = b;
            try board.?.applySettings(args.settings);
        } else |e| {
            log.err("could not open the board: {t} (liboni: {s})", .{ e, dimna.oni.errorStr(dimna.oni.lastError()) });
            if (!simulateInstead(e)) return 1;
            sim_spec = &.{ 32, 16 };
        }
    }
    const source: dimna.source.Source = if (board) |*b| .{ .board = b } else blk: {
        sim = try dimna.sim.Sim.init(gpa, io, sim_spec);
        try sim.?.applySettings(args.settings);
        sim.?.stall_at_s = env.sim_stall_at;
        sim.?.stall_s = env.sim_stall_s;
        sim.?.fail_at_s = env.sim_fail_at;
        sim.?.fail_times = env.sim_fail_times;
        log.info("simulated board: {d} headstages, {d} units", .{ sim_spec.len, sim.?.units.len });
        break :blk .{ .sim = &sim.? };
    };
    var health: dimna.types.Health = .{};
    // What of the loss counters the user has acknowledged (the alarm shows the rest).
    var alarms: session.Alarms = .{};
    // How long until the recording's disk is full (looked at every 5 s while recording).
    var disk: session.DiskWatch = .{};
    if (env.disk_reserve_gb) |gb| disk.reserve = gb * 1e9;

    // ---- window and renderer ----
    var win: Window = undefined;
    var app_id_buf: [64:0]u8 = @splat(0);
    const app_id = std.fmt.bufPrintSentinel(&app_id_buf, "{s}", .{env.app_id}, 0) catch "dimna";
    try win.init("dimna", app_id, env.key_debug);
    defer win.deinit();
    const fullscreen = args.monitor.len > 0;
    // The camera housing's cut-out in a Mac laptop's screen, which a fullscreen window covers.
    var top_cut: ?[3]f32 = null;
    if (fullscreen) {
        if (win.fullscreenOn(args.monitor)) {
            log.info("fullscreen on {s}", .{args.monitor});
            if (builtin.os.tag == .macos) top_cut = win.topCut();
            if (top_cut) |cut| log.info("the screen's cut-out: {d:.0} to {d:.0} px, {d:.0} px deep; titles keep clear of it", .{ cut[0], cut[1], cut[2] });
        } else {
            log.err("no monitor named '{s}'; there are:", .{args.monitor});
            var i: usize = 0;
            while (win.monitorName(i)) |name| : (i += 1) log.err("  {s}", .{name});
            return 2;
        }
    }
    _ = win.declareLowLatency();
    if (args.tearing and !win.preferTearing()) log.warn("the compositor has no tearing control; frames will wait for the refresh", .{});
    var gpu = try Gpu.init(gpa, win.gpuTarget(), args.present, null);
    defer gpu.deinit();
    var notes = notes_mod.Notes.init(args.doc, env.home, env.state_home);
    defer notes.deinit();

    // ---- the pipeline: ring, acquisition, feed, panels, history, audio and tiles ----
    // Everything that depends on the shape of the data, made here and again at each
    // restart by the same code (see pipeline.zig).
    var audio_shared: audio_out.Shared = .{};
    var tiles_shared: tiles_mod.Shared = .{};
    // The tile window's view (port shown, tile ranges): from the view file at first, then
    // as the tile window reports it; saved with the panels by "Save view".
    var tile_view = dimna.tile_view.TileView.read(args.views_doc);
    tiles_shared.initial_view = tile_view;
    var tile_report_seen: u32 = 0;
    var pl: Pipeline = .{
        .gpa = gpa,
        .io = io,
        .source = source,
        .args = args,
        .env = env,
        .gpu = &gpu,
        .health = &health,
        .audio_shared = &audio_shared,
        .tiles_shared = &tiles_shared,
    };
    // The detection thresholds: from the view file; the display keeps them from then on
    // (and across a restart).
    pl.init(dimna.thresholds.Thresholds.read(args.views_doc)) catch |e| return if (e == error.BadPanels) 2 else e;
    // Stops acquisition, the audio monitor and the tiles, then frees the ring. It runs
    // after the recording below is closed, which reads the ring to its end.
    defer pl.deinit();
    log.info("{d} channels ({d} electrode) at {d} Hz", .{ pl.nch, pl.layout.num_electrodes, pl.fs });
    // The parts the loop uses all the time. They stay at these addresses across a restart;
    // their contents, and pl.fs, pl.nch and pl.bs, change.
    const display = &pl.display;
    if (top_cut) |cut| display.top_cut = .{ .x0 = cut[0], .x1 = cut[1], .bottom = cut[2] };
    const layout = &pl.layout;
    const acq = &pl.acq;
    const ring = &pl.ring;
    const reader = &pl.reader;
    const blk = &pl.blk;
    const feed = &pl.feed;

    var draws: [max_draws]gpu_mod.PanelDraw = undefined;
    var fills: [max_fills]gpu_mod.Fill = undefined;
    var text: Text = .{};
    text.init(gpa, &gpu, args.*);
    defer text.deinit(gpa);
    // Glyphs the display's font draws on demand go to the GPU before the frame that uses them.
    if (text.vertices.len > 0) gpu.textFont(&text.font);
    var batch = text.batch();
    var status: Status = .{};

    try pl.run();

    // The control window, on its own thread (see control.zig).
    var shared: control.Shared = .{};
    var control_cfg: control.Config = .{ .gpa = gpa, .shared = &shared, .display_gpu = &gpu, .font_px = args.controlFontPx(), .env = env };
    // Which of its sections are open: from the view file, then as the control window
    // reports them; saved with the panels by "Save view".
    var control_view = dimna.control_view.ControlView.read(args.views_doc);
    control_cfg.view = control_view;
    var control_thread: ?std.Thread = null;
    if (args.control) {
        const n = @min(args.font.len, control_cfg.font_buf.len);
        @memcpy(control_cfg.font_buf[0..n], args.font[0..n]);
        control_thread = control.spawn(&control_cfg);
    }
    defer if (control_thread) |t| {
        shared.stop.store(true, .release);
        t.join();
    };
    var snap_dirty = true;
    var snap_target: usize = 0;

    // Recording: started and stopped from the control window.
    var recording: session.Recording = .{};
    recording.setRoot(args.record_dir, env.home);
    recording.fault = env.record_test;
    // However the loop ends, a recording in progress is closed properly.
    defer recording.deinit();
    var rec_published_ns: i128 = 0;
    // What "Save view" saves: the panels, the tile window's view, the thresholds and which
    // sections of the control window are open.
    // (Pointers that stay valid; what they point to changes.)
    const view: session.ViewFile.View = .{
        .set = &display.set,
        .tiles = &tile_view,
        .thresholds = &display.thresholds,
        .layout = layout,
        .control = &control_view,
    };
    var view_file = try session.ViewFile.init(gpa, view);
    defer view_file.deinit(gpa);
    var review: session.ReviewSession = .{};
    defer review.deinit();
    // The min/max pyramids of the recording in progress (overview.zig): what review draws
    // long stretches from. Filled from the rows the display makes, and from the file.
    var overview = try dimna.overview.Overview.init(gpa, io, layout, overview_budget);
    defer overview.deinit();
    var overview_turn_ns: i128 = 0;
    var overview_first: i64 = 0;
    var overview_end: i64 = 0;
    var tiles_published_ns: i128 = 0;

    // Board settings as the control window changes them, and the question on quitting.
    var board_ctl: session.BoardControl = .init(acq.requested, config_path);

    var newest: i64 = 0;
    var newest_acquired_ns: i128 = 0;
    // When to draw, and how the frames landed (see pacing.zig).
    var pacer: Pacer = .init(args.margin_ms, args.free_ms, fullscreen, env.frame_debug);
    // Diagnostics only: time the GPU per frame (it delays presenting, see gpu.zig).
    gpu.wait_render = pacer.debug;
    var script_pos: usize = 0;
    var test_record_at = env.record_at;
    const t_start = nowNs();
    var next_report: i128 = t_start + std.time.ns_per_s;
    var title_buf: [160]u8 = undefined;

    // The board going quiet: since when acquisition (re)started, whether a quiet spell is
    // under way, and how many there were.
    var acq_since_ns: i128 = nowNs();
    var quiet = false;
    var quiet_spells: u64 = 0;
    // Asking to quit while recording with no control window: the notice, and until when a
    // second request quits.
    var quit_notice: display_mod.Notice = .{};
    var quit_confirm_until_ns: i128 = 0;
    // When acquisition ends on a read error: the recording in progress is closed with the
    // reason, the board is opened again as `reopen` says, and the recording goes on in a
    // new folder of the same session (docs/plans/reopen-after-read-error.md). If it cannot
    // be, the display runs on and the alarm says so.
    var reopen: dimna.reopen.Reopen = .init(.{}, nowNs());
    // The counts of the runs before the present one (a restart makes the ring and the
    // source's counters anew): what the alarms add to the present ones.
    var carried: session.Alarms.Counts = .{};
    catchStopSignals();
    while (!win.closed) {
        if (@backingInt(stop_signal.load(.acquire)) != 0) {
            log.info("signal {t}: quitting{s}", .{ stop_signal.load(.acquire), if (recording.active()) "; the recording is closed first" else "" });
            break;
        }
        // Wake for events, for new samples (every 2 ms), or when the frame is due.
        const wait_ms = pacer.waitMs(nowNs());
        try win.pump(wait_ms);

        // New samples into the GPU's history.
        while (reader.next(blk)) {
            if (blk.len == 0) continue;
            const rows = try feed.rows(blk.first_sample, blk.samples(), blk.ttl[0..blk.len]);
            gpu.writeSamples(blk.first_sample, rows);
            overview.add(blk.first_sample, rows, blk.ttl[0..blk.len]);
            display.feedBlock(blk.first_sample, blk.samples(), pl.nch, pl.fs, blk.ttl[0..blk.len]);
            newest = blk.first_sample + @as(i64, @intCast(blk.len));
            newest_acquired_ns = blk.acquired_ns;
        }

        var input = win.takeInput();
        if (args.script.len > 0) runScript(args.script, &script_pos, @as(f64, @floatFromInt(nowNs() - t_start)) / 1e9, &input, display);
        // Input goes to the panel under the pointer.
        display.pointAt(
            input.pointer_x / @as(f64, @floatFromInt(@max(win.width, 1))),
            input.pointer_y / @as(f64, @floatFromInt(@max(win.height, 1))),
        );
        // Notes first: while one is being typed, every key is its text. "Now" is the
        // newest sample acquired plus the time since.
        const note_stamp: i64 = newest + if (newest_acquired_ns != 0)
            @as(i64, @intFromFloat(@as(f64, @floatFromInt(nowNs() - newest_acquired_ns)) * 1e-9 * pl.fs))
        else
            0;
        // ? (the key summary) before the notes: it must not start a note as / does.
        display.pointer_inside = input.pointer_inside;
        if (!notes.editing) {
            display.helpKey(&input);
            display.adcKey(&input);
        }
        notes.handle(&input, note_stamp, recording.sessionPath());
        // Review keys (what is left of them after a note took its own), and Shift+wheel.
        review.queueInput(display.reviewActions(&input, pl.fs));
        // Quitting (q or Esc here, Quit in the control window) asks first if the board
        // settings were changed; a second request quits.
        var quit = display.applyInput(input);
        // Closing the display window (its close button, the compositor's close key, Cmd-Q
        // on macOS) asks to quit like Ctrl+Q: the window stays until the answer is to quit.
        if (win.closed) {
            win.closed = false;
            quit = true;
        }
        win.setCursor(display.cursor);
        var quit_answer: ?control.QuitAnswer = null;
        // Whether there is a control window to ask in.
        const can_ask_quit = control_thread != null and !shared.closed.load(.acquire);
        // A test run's recording (DIMNA_TEST_RECORD_AT), as if Record had been clicked.
        if (test_record_at) |at| {
            if (!args.control and @as(f64, @floatFromInt(nowNs() - t_start)) / 1e9 >= at) {
                test_record_at = null;
                shared.push(.{ .record = true });
            }
        }
        // What was clicked in the control window.
        while (shared.pop()) |e| {
            snap_dirty = true;
            switch (e) {
                .panel => |p| display.applyPanelEdit(p.index, p.action),
                .threshold => |t| display.applyThreshold(t),
                .audio => |a| display.applyAudio(a),
                .board => |b| board_ctl.edit(b, acq, pl.fs, recording.active(), io, gpa, config_path),
                .record => |on| {
                    if (on and !recording.active()) {
                        // Review of an earlier recording ends where a new one begins.
                        review.active = false;
                        alarms.seen.gaps = 0;
                        if (!recording.start(gpa, io, ring, recordInfo(layout, source, if (board) |*b| b else null, &display.set), &acq.events, nowNs())) alarms.recording_failed = true;
                    } else if (!on) recording.requestStop();
                },
                .note_preset => |n| notes.stampPreset(n, note_stamp, recording.sessionPath()),
                .acknowledge => display.acknowledged = true,
                .control_view => |v| control_view = v,
                .save_view => if (view_file.save(io, views_path, view)) |_| {
                    board_ctl.status.say(.note_view_saved, .{ .path = views_path });
                } else |err| board_ctl.status.say(.note_cannot_save, .{ .path = views_path, .err = err }),
                .quit_answer => |answer| quit_answer = answer,
                .quit => quit = true,
            }
        }
        // The overview follows the recording: begun with it, kept while its review is open.
        if (nowNs() - overview_turn_ns > 20 * std.time.ns_per_ms) {
            overview_turn_ns = nowNs();
            if (recording.recorder) |r| {
                const first = r.first_sample_shared.load(.acquire);
                if (first != std.math.minInt(i64)) {
                    if (!overview.active() or overview_first != first) {
                        overview_first = first;
                        overview.begin(r.path, first, &display.set, feed.width) catch |err| log.warn("no overview of this recording ({t}): review is limited to short stretches", .{err});
                    }
                    overview_end = first + @as(i64, @intCast(r.stats.samples.load(.monotonic)));
                }
            } else if (overview.active() and !(review.active and review.from_file)) overview.end();
            if (overview.active()) overview.turn(&display.set, feed.width, overview_end, review.wanted(&display.set, pl.fs), (recording.behind(pl.bs, pl.fs) orelse 0) > 0.5);
            // In review of the recording the time base may be as long as the recording
            // (two hours at most); back in the live view it returns to what it was.
            const limit: f64 = if (review.active and review.from_file and overview.active())
                @min(Panel.review_span_max, @as(f64, @floatFromInt(overview_end - overview_first)) / pl.fs)
            else
                Panel.span_max;
            for (display.set.slice()) |*p| p.setSpanLimit(limit);
        }
        if (review.step(.{
            .gpa = gpa,
            .gpu = &gpu,
            .layout = layout,
            .set = &display.set,
            .target = display.target,
            .newest = newest,
            .rec = recording.recorder,
            .overview = &overview,
            .width = gpu.pixelSize().width,
            .height = gpu.pixelSize().height,
        })) snap_dirty = true;
        // Notes saved this turn go into the recording, if there is one.
        for (notes.fresh[0..notes.num_fresh]) |*note| {
            recording.note(note.sample, note.text());
        }
        notes.num_fresh = 0;
        if (notes.dirty) {
            notes.dirty = false;
            snap_dirty = true;
        }
        // What was asked for in the tile window: focus a channel, clear the focus, listen,
        // set a threshold.
        while (tiles_shared.requests.pop()) |request| display.tileRequest(request);
        // What the tile window reports: every electrode's threshold in use, and its view.
        {
            var report: tile_link.Report = undefined;
            if (tiles_shared.report.read(&report, &tile_report_seen)) {
                display.reported = report.thresholds;
                if (!report.view.eql(&tile_view)) {
                    tile_view = report.view;
                    snap_dirty = true;
                }
            }
        }
        if (display.thresholds_changed) {
            display.thresholds_changed = false;
            snap_dirty = true;
        }
        if (pl.tiles_win != null and nowNs() - tiles_published_ns > 200 * std.time.ns_per_ms) {
            tiles_published_ns = nowNs();
            tiles_shared.publish(&display.tileConfig());
        }
        display.refreshAudioCar();
        if (display.audio_dirty) {
            display.audio_dirty = false;
            audio_shared.publish(&display.audio);
            snap_dirty = true;
        }
        if (display.audio_recalibrate) {
            display.audio_recalibrate = false;
            audio_shared.recalibrate.store(true, .release);
        }
        if (quit_answer) |answer| {
            if (board_ctl.quit_prompt.active) switch (answer) {
                .save => {
                    // Whichever of the two changed.
                    const board_ok = board_ctl.saveIfChanged(io, gpa, config_path, &acq.requested);
                    var view_ok = true;
                    if (view_file.unsaved(view)) {
                        if (view_file.save(io, views_path, view)) |_| {
                            log.info("view saved to {s}", .{views_path});
                        } else |err| {
                            board_ctl.status.say(.note_cannot_save, .{ .path = views_path, .err = err });
                            view_ok = false;
                        }
                    }
                    if (board_ok and view_ok) break;
                    board_ctl.quit_prompt.active = false;
                },
                .discard => break,
                .cancel => {
                    board_ctl.quit_prompt.active = false;
                    board_ctl.quit_prompt.recording = false;
                },
                // "Stop recording and quit": the recording is closed as the loop ends
                // (recording.deinit); first the question about unsaved settings, if any.
                .stop_recording => {
                    board_ctl.quit_prompt.active = false;
                    board_ctl.quit_prompt.recording = false;
                    recording.requestStop();
                    if (!board_ctl.askBeforeQuit(&acq.requested, view_file.unsaved(view), can_ask_quit)) break;
                },
            };
            snap_dirty = true;
        }
        if (quit) {
            if (recording.active()) {
                // Never straight out of a recording. With the control window: its prompt,
                // which only its buttons answer (asking again changes nothing). Without
                // one: a notice over the display, and a second request while it is up.
                if (can_ask_quit) {
                    board_ctl.quit_prompt.active = true;
                    board_ctl.quit_prompt.recording = true;
                } else if (nowNs() < quit_confirm_until_ns) {
                    break;
                } else {
                    quit_notice = .{};
                    quit_notice.say(.notice_quit_recording, .{}, .notice_quit_recording_how, .{});
                    quit_confirm_until_ns = nowNs() + display_mod.Notice.seconds * std.time.ns_per_s;
                }
            } else if (!board_ctl.askBeforeQuit(&acq.requested, view_file.unsaved(view), can_ask_quit)) break;
            snap_dirty = true;
        }
        // Sample rate or channel set: stop, reconfigure the board, and start again with
        // everything that depends on the shape of the data made anew (pipeline.zig).
        if (board_ctl.restart_asked) {
            board_ctl.restart_asked = false;
            snap_dirty = true;
            if (recording.active()) {
                board_ctl.status.say(.note_stop_recording_first, .{});
            } else {
                // Review looks into a history that is about to be replaced.
                review.drop();
                overview.end();
                // The tile window starts again: with the view it had.
                tiles_shared.initial_view = tile_view;
                if (try pl.restart(board_ctl.pending)) |refused| {
                    board_ctl.status.say(.note_board_refused, .{ .err = refused });
                }
                // The overview is for the new shape of the data.
                overview.deinit();
                overview = try dimna.overview.Overview.init(gpa, io, layout, overview_budget);
                board_ctl.pending = acq.requested;
                newest = 0;
                newest_acquired_ns = 0;
                pacer.drawn_newest = 0;
                acq_since_ns = nowNs();
                quiet = false;
            }
        }
        // The recorder has finished (asked to, or because writing failed).
        if (recording.poll(pl.fs)) |ended| {
            snap_dirty = true;
            // Nothing left to ask about.
            if (board_ctl.quit_prompt.recording) {
                board_ctl.quit_prompt.active = false;
                board_ctl.quit_prompt.recording = false;
            }
            if (ended == .failed) alarms.recording_failed = true;
        }
        // While recording, the control window's counts move four times a second.
        if ((recording.active() or review.active) and nowNs() - rec_published_ns > 250 * std.time.ns_per_ms) {
            rec_published_ns = nowNs();
            snap_dirty = true;
        }
        // The disk: a statfs every 5 s while recording (microseconds), else forgotten.
        if (recording.active()) {
            const now_s = @as(f64, @floatFromInt(nowNs() - t_start)) / 1e9;
            if (disk.due(now_s)) {
                if (session.freeBytes(recording.sessionPath())) |free| disk.add(now_s, free, recording.written());
            }
        } else if (disk.len > 0) disk.reset();
        // Acquisition ended on a read error: the recording is closed at once (everything
        // acquired is in the ring), and the board opened again when `reopen` says.
        if (acq.done.load(.acquire) and reopen.state == .running) {
            const err = acq.failure orelse error.AcquisitionEnded;
            reopen.ended(err, nowNs());
            recording.closeForRestart(err);
            if (reopen.state == .gave_up) {
                log.err("acquisition stopped ({t}); no attempts left to open the board again", .{err});
            } else log.warn("acquisition stopped ({t}); opening the board again (attempt {d} of {d})", .{ err, reopen.nextAttempt().n, reopen.nextAttempt().of });
            snap_dirty = true;
        }
        // Once the recording has been closed (it reads the ring the reopen replaces). One
        // started with Record while acquisition was down is closed the same way, and goes
        // on in its session once the board is open again.
        if (reopen.due(nowNs()) and recording.recorder != null) recording.closeForRestart(reopen.read_error orelse error.AcquisitionEnded);
        if (reopen.due(nowNs()) and recording.recorder == null) {
            snap_dirty = true;
            const was = reopen.state;
            // The counts that the new ring and the source's start set back to 0.
            const before: session.Alarms.Counts = .{
                .overflow = acq.ring_overflow.load(.monotonic),
                .dropped = health.dropped_samples.load(.monotonic),
            };
            review.drop();
            overview.end();
            tiles_shared.initial_view = tile_view;
            const outcome: anyerror!void = if (pl.reopen(acq.requested)) |_| ok: {
                carried.overflow += before.overflow;
                carried.dropped += before.dropped;
                overview.deinit();
                overview = try dimna.overview.Overview.init(gpa, io, layout, overview_budget);
                board_ctl.pending = acq.requested;
                newest = 0;
                newest_acquired_ns = 0;
                pacer.drawn_newest = 0;
                quiet = false;
                // The recording goes on, attached before acquisition starts, so it has
                // the new run's first block.
                if (recording.resumeIn()) |resume_at| {
                    // Copied: `start` clears what `resumeIn` points into.
                    var prev_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const prev = prev_buf[0..resume_at.continues.path.len];
                    @memcpy(prev, resume_at.continues.path);
                    var text_buf: [std.fs.max_path_bytes + 64]u8 = undefined;
                    var info = recordInfo(layout, source, if (board) |*b| b else null, &display.set);
                    info.continue_in = std.fs.path.dirname(prev) orelse prev;
                    info.continues = .{ .path = prev, .end_sample = resume_at.continues.end_sample, .last_wall_ns = resume_at.continues.last_wall_ns };
                    info.start_text = std.fmt.bufPrint(&text_buf, "after a read error ({t}); continues {s}", .{ reopen.read_error.?, prev }) catch "after a read error";
                    // Its gaps are counted from 0, as at Record.
                    alarms.seen.gaps = 0;
                    if (!recording.start(gpa, io, ring, info, &acq.events, nowNs())) alarms.recording_failed = true;
                }
                pl.run() catch |e| {
                    // As a failed attempt: nothing runs (`run` stopped what it started).
                    acq.failure = e;
                    acq.done.store(true, .release);
                    recording.closeForRestart(e);
                    break :ok e;
                };
                acq_since_ns = nowNs();
                break :ok {};
            } else |e| e;
            reopen.result(outcome, nowNs());
            if (outcome) |_| {
                log.warn("acquisition restarted after a read error ({t}), {d} time(s) so far", .{ reopen.read_error.?, reopen.restarts });
            } else |e| {
                if (e == error.BoardAbsent) {
                    if (was != .absent) log.warn("the board is gone; waiting for it", .{});
                } else if (reopen.state == .gave_up) {
                    log.err("opening the board again failed ({t}); no attempts left", .{e});
                } else log.warn("opening the board again failed ({t}); attempt {d} of {d} next", .{ e, reopen.nextAttempt().n, reopen.nextAttempt().of });
            }
        }
        // The board: how long since the newest block came in (blocks drained above), and
        // whether acquisition has ended on an error.
        const ended: ?anyerror = if (acq.done.load(.acquire)) reopen.read_error orelse (acq.failure orelse error.AcquisitionEnded) else null;
        const stalled_s: f64 = if (ended != null) 0 else @as(f64, @floatFromInt(nowNs() - @max(newest_acquired_ns, acq_since_ns))) / 1e9;
        if (stalled_s >= session.Alarms.stall_s and !quiet) {
            quiet = true;
            quiet_spells += 1;
            log.err("no data from the board for {d:.1} s", .{stalled_s});
        } else if (stalled_s < session.Alarms.stall_s and quiet) {
            quiet = false;
            log.warn("the board is sending data again", .{});
        }
        // Alarms: anything that means samples are not being kept.
        if (alarms.update(&status, .{
            .overflow = carried.overflow + acq.ring_overflow.load(.monotonic),
            .dropped = carried.dropped + health.dropped_samples.load(.monotonic),
            .gaps = recording.gaps(),
            .stalls = quiet_spells,
            .restarts = reopen.restarts,
        }, .{
            .stalled_s = stalled_s,
            .ended = ended,
            .reopening = if (ended != null) session.Alarms.Reopening.from(&reopen, nowNs()) else null,
            .restart_err = reopen.read_error,
            .down_s = @as(f64, @floatFromInt(reopen.down_ns)) / 1e9,
            .recording = recording.active() or recording.resumeIn() != null,
        }, recording.behind(pl.bs, pl.fs), if (recording.active()) disk.left() else null, &display.acknowledged)) snap_dirty = true;
        audio_shared.alarm.store(status.alarm_len > 0, .monotonic);
        status.recording = recording.active();
        // One banner at a time: the language's first, then the colour scheme's.
        status.notice = if (quit_confirm_until_ns > nowNs() and quit_notice.shown(nowNs())) &quit_notice else if (language_notice.shown(nowNs())) &language_notice else if (scheme_notice.shown(nowNs())) &scheme_notice else null;
        status.rec_seconds = recording.seconds(nowNs());
        if (input.num_keys > 0 or input.scroll_x != 0 or input.scroll_y != 0 or input.pinch != 1 or
            display.target != snap_target) snap_dirty = true;
        if (snap_dirty and control_thread != null) {
            snap_dirty = false;
            snap_target = display.target;
            // The line about the source (cut to the buffer, whose rest is not read).
            var about_b: [160]u8 = undefined;
            const about_len = i18n.fmt(&about_b, .about_source, .{
                .source = if (sim != null) i18n.text(.source_simulated) else i18n.text(.source_board),
                .channels = pl.nch,
                .electrodes = layout.num_electrodes,
                .rate = pl.fs,
            }).len;
            shared.publish(&.{
                .set = display.set,
                .thresholds = display.thresholds,
                .reported = display.reported,
                .target = display.target,
                .status = status,
                .ring_overflow = acq.ring_overflow.load(.monotonic),
                .seconds = @as(f64, @floatFromInt(nowNs() - t_start)) / 1e9,
                .quit_prompt = board_ctl.quit_prompt,
                .review = review.status(newest, pl.fs),
                .view_unsaved = view_file.unsaved(view),
                .notes = session.notesStatus(&notes, pl.fs),
                .audio = session.audioStatus(display, &audio_shared, layout),
                .about_buf = about_b,
                .about_len = about_len,
                .board = board_ctl.statusNow(&acq.requested, layout),
                .rec = recording.statusNow(nowNs(), pl.bs, pl.fs),
            });
        }
        // A panel's corners changed: filter its recent past again.
        if (gpu.hist_cap > 0) _ = try feed.sync(gpa, &display.set, refilterSamples(&display.set, pl.fs), gpu.hist, gpu.hist_cap);

        for (win.takePresented()) |p| pacer.presented(p, nowNs(), win.presentsOnNowClock(), win.presentation_clock);

        const now = nowNs();
        if (pacer.due(now, win.frame_ready, newest)) {
            if (win.resized or gpu.unsized()) {
                try gpu.resize(win.width, win.height);
                win.resized = false;
                pacer.n_resize += 1;
            }
            const fr = display.frame(.of(&gpu), layout, newest, review.view(newest, pl.fs), status, &notes, &batch, &draws, &fills);
            const Ctx = struct { win: *Window, tag: u64 };
            const result = try gpu.draw(fr.draws, fr.fills, fr.text, Ctx{ .win = &win, .tag = pacer.begin(newest_acquired_ns) }, struct {
                fn f(c: Ctx) void {
                    c.win.beforePresent(c.tag);
                }
            }.f);
            pacer.end(now, nowNs(), result, newest, if (gpu.wait_render) @as(f64, @floatFromInt(gpu.last_render_ns)) / 1e6 else null);
            switch (result) {
                .presented => {},
                .out_of_date => {
                    win.resized = true;
                    win.frame_ready = true;
                },
                .busy => win.frame_ready = true,
            }
        }

        if (now >= next_report) {
            const secs = @as(f64, @floatFromInt(now - t_start)) / 1e9;
            const r = pacer.second();
            const tp = &display.set.items[display.target];
            log.info("t={d:.0}s {d} fps, latency ms avg {d:.1} min {d:.1} max {d:.1}, at the refresh aimed at {d}, a refresh later {d}, recovery skips {d}, margin {d:.1} ms, refresh {d:.2} ms, display lost {d} blocks, ring overflow {d}, panel {d} span {d:.2} s scale {d:.1}, {d}x{d}", .{
                secs,                  r.frames,                           r.avg_ms,           r.min_ms,    r.max_ms,
                r.on_time,             r.late,                             r.skips,            r.margin_ms, r.refresh_ms,
                reader.lost,           acq.ring_overflow.load(.monotonic), display.target + 1, tp.span_s,   tp.scale,
                gpu.pixelSize().width, gpu.pixelSize().height,
            });
            status.valid = r.valid;
            status.latency_ms = r.avg_ms;
            status.fps = r.frames;
            status.lost = reader.lost;
            snap_dirty = true;
            if (pl.audio_dev != null) log.info("  audio: {d:.1} ms (queue {d:.1}, device {d:.1}, margin {d:.1}; longest wait for a block {d:.1}, oldest block {d:.1}), gaps {d}, dropped {d}, noise {d:.1} uV{s}", .{
                @as(f64, @floatFromInt(audio_shared.latency_us.load(.monotonic))) / 1000.0,
                @as(f64, @floatFromInt(audio_shared.queue_us.load(.monotonic))) / 1000.0,
                @as(f64, @floatFromInt(audio_shared.device_us.load(.monotonic))) / 1000.0,
                @as(f64, @floatFromInt(audio_shared.margin_us.load(.monotonic))) / 1000.0,
                @as(f64, @floatFromInt(audio_shared.max_block_gap_us.swap(0, .monotonic))) / 1000.0,
                @as(f64, @floatFromInt(audio_shared.max_block_age_us.swap(0, .monotonic))) / 1000.0,
                audio_shared.underruns.load(.monotonic),
                audio_shared.dropped.load(.monotonic),
                @as(f64, @floatFromInt(audio_shared.held_sigma_c.load(.monotonic))) / 100.0 * dimna.types.electrode_uv_per_bit,
                if (audio_shared.held_sigma_c.load(.monotonic) == 0) " (measuring)" else " held",
            });
            if (!env.no_title) {
                // Zero-terminated for the window system; the text is cut to leave room.
                const t = i18n.fmt(title_buf[0 .. title_buf.len - 1], .window_title_status, .{
                    .panel = tp.name(),
                    .span = tp.span_s,
                    .scale = tp.scale,
                    .unit = tp.unit(),
                    .ms = r.avg_ms,
                    .fps = r.frames,
                });
                title_buf[t.len] = 0;
                win.setTitle(title_buf[0..t.len :0]);
            }
            next_report += std.time.ns_per_s;
        }
        if (args.seconds > 0 and @as(f64, @floatFromInt(now - t_start)) >= args.seconds * 1e9) break;
    }
    if (acq.done.load(.acquire)) {
        log.err("acquisition ended early: {t}", .{acq.failure orelse error.Unknown});
        return 1;
    }
    return 0;
}

/// What a recording of the source as it is now says about itself (meta.toml).
fn recordInfo(layout: *const dimna.types.Layout, source: dimna.source.Source, board: ?*const dimna.board.Board, set: *const dimna.panels.Set) dimna.record.Info {
    return .{
        .layout = layout.*,
        .settings = source.settings(),
        .gateware = if (board) |b| b.fw else @splat(0),
        .board_id = if (board) |b| b.device_id else 0,
        .cable_delay = if (board) |b| b.cable_delay else @splat(0),
        .board_kind = if (board != null) "Open Ephys acquisition board (ECP5, FT600, ONI)" else "simulated",
        .session = true,
        .ttl_names = names: {
            var names: [8][]const u8 = undefined;
            for (&names, 1..) |*n, line| n.* = set.ttlName(line);
            break :names names;
        },
    };
}
