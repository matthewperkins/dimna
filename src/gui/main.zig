//! oez: the GUI. One window of live traces for now.
//!
//!   oez [--sim 32,16] [--16ch A1,B1] [--aux] [--adc] [--driver usb|d3xx] [--seconds S]
//!       [--present auto|mailbox|immediate|fifo] [--margin-ms MS] [--script STEPS]
//!       [--monitor DP-2] [--tearing] [--free MS]
//!
//! --direct DP-2 drives that monitor itself, with no compositor: frames are flipped by oez at
//!   each refresh. It works only where nothing else drives the monitor: from a text console
//!   (Ctrl+Alt+F3), with a DRM lease, or on a graphics card of its own. There is no window and
//!   no input in this mode yet: it runs for --seconds (default 20) or until Ctrl+C, and
//!   --script changes the panels. Margin 1.5 ms unless --margin-ms.
//! --monitor makes the window fullscreen on that monitor (the neural display).
//! --tearing asks the compositor to show each frame at once, mid-scan, instead of at the
//!   refresh; implies --present immediate and --free 2. The lowest latency under a compositor:
//!   1.6 ms from a sample's arrival to the flip (measured, Hyprland 0.57.2), and since a new
//!   frame is flipped every 3 ms, every scan line shows data at most a few ms old (with
//!   refresh-locked frames the bottom of the screen is a whole refresh staler than the top).
//!   Hyprland tears only when all of these hold:
//!     general.allow_tearing = true                     (config)
//!     the window is fullscreen                          (--monitor)
//!     the window asks for it (done here) or has a window rule `immediate = true`
//!     cursor.no_hardware_cursors = 1                    (config: no tearing while a hardware
//!                                                        cursor is visible on that monitor)
//!   `hyprctl monitors` shows activelyTearing and tearingBlockedBy. ("next frame is not torn"
//!   is listed whenever a frame is not being torn at that instant; it is not a blocker.)
//! --free MS draws whenever new samples have arrived, at most every MS milliseconds, instead
//!   of once per refresh just before it.
//!
//! --script feeds synthetic input for tests, as "SECONDS:STEP;SECONDS:STEP;...", where STEP is
//! wheel=N, hwheel=N, cwheel=N (Ctrl+wheel; axis units, 15 = one click), pointer=FX,FY, click, cclick, type=TEXT, enter, esc, tab, backspace, space, left, right, pgup, pgdn, home, end, pinch=F (scale factor), or keys such as
//! "]]==" (any of [ ] - = r m f t 1-8 , . ' q; ';' separates steps, so the high corner can only be
//! stepped up by script). It goes through the same path as real input.
//!
//! Without --sim it opens the board. Controls:
//!   wheel / two-finger scroll      Y scale (µV per row)
//!   Ctrl+wheel                     Y scale of the row under the pointer alone
//!   Shift+wheel, sideways scroll   time base
//!   touchpad pinch                 time base
//!   - =   [ ]                      Y scale, time base by keys;  r resets;  q or Esc quits
//!   m                              scroll <-> sweep (traces stand still, a cursor moves across)
//!   t                              triggered sweeps on/off: the signal around each rising edge of
//!                                  a TTL input line, the last few overlaid; 1-8 pick the line;
//!                                  s switches to spikes on the row under the pointer (a slope
//!                                  trigger; click another row to move it) and back,
//!                                  [ ] and Shift+wheel zoom the window around the trigger
//!   Space                          freeze: look at what just went by. Then, or at once:
//!   Left / Right, PgUp / PgDn      go back and forth (a tenth of the window, a whole window)
//!   Home / End                     the start of the recording / back to live
//!                                  (scroll-back review: from the recording's file while
//!                                  recording, else the last half minute)
//!   /                              type a note (Enter saves, Esc drops, Tab keeps it as a draft);
//!                                  ` stamps a draft; 1-9 stamp the config's preset notes
//!   a                              acknowledge an alarm (the red bar: samples lost, or the
//!                                  recording failed)
//!   click a row                    listen to that channel (Ctrl+click adds or removes one)
//!   f                              display filter on/off (electrode panels): raw <-> band-pass
//!   , .   ; '                      the band's low corner, high corner: down, up
//!
//! The display reads the acquisition ring with a lossy reader, so it can never hold
//! acquisition back. Once a second it logs the frame rate and the sample-to-screen latency:
//! the time from a sample's block reaching the ring to the frame showing it being presented
//! (from Wayland presentation feedback).
//!
//! Frame timing (measured on Hyprland 0.57, NVIDIA, 60 Hz). Each frame is drawn `margin`
//! before the next refresh, predicted from the presentation timestamps:
//!
//!   composited window        the compositor shows, one refresh later, what was committed
//!                            before a refresh: 20.2 ms (32.7 ms if drawn right after the
//!                            frame callback instead)
//!   fullscreen, direct scanout   the buffer goes to the screen at that refresh: 3.5 ms
//!
//! Direct scanout has two stable states. While the output is idle when a commit arrives,
//! Hyprland flips it at once and it is on screen at the refresh aimed at. After a disturbance
//! (a flip still pending when the commit arrives), every commit waits for the previous flip
//! and is shown a refresh later, indefinitely. Leaving one refresh out lets the output go idle
//! again, so (fullscreen only) after 8 frames in a row a refresh late, one frame is skipped;
//! the wait before the next skip doubles each time (250 ms to 8 s) and resets after 2 s of
//! frames on time. The losses that remain come from the compositor's side (unverified guess:
//! it is busy drawing the other monitor when the commit arrives; only owning the display
//! would remove them).
//!
//! The margin is 3 ms. It widens only while frames keep landing late (judged against the
//! best latency of the last seconds, so it works in either regime) and then returns;
//! --margin-ms fixes it. Direct scanout needs Hyprland's render.direct_scanout = 1, or = 2
//! (only surfaces declared as game content, which oez does) and a fullscreen window
//! (--monitor, or `monitor` in the config file). Free-running (--free) without tearing
//! queues frames under direct scanout (33.6 ms).
//!
//! A second window, the control window (class "oez-control"), shows the run's status and
//! every panel's settings with buttons; see control.zig. --no-control or control = false in
//! the config leaves it out.
//!
//! Config file: $XDG_CONFIG_HOME/oez/config.toml (default ~/.config/oez); command-line options
//! win. Top-level keys: monitor = "DP-2", tearing = true, free_ms = 2, margin_ms = 3,
//! font = "sans-serif" (a fontconfig name), font_px = 14, record_dir = "~/oez-recordings"
//! (a session folder per recording beneath it; Record is in the control window). Panels:
//! one [[panel]] table each (see src/panels.zig), for example
//!
//!   [[panel]]
//!   name = "Port B"
//!   source = "B1"                 # a headstage, "electrodes", "aux" or "adc"
//!   rect = [0.0, 0.0, 0.5, 1.0]   # x, y, width, height as fractions of the display
//!   span_s = 2.0
//!   scale = 400                   # µV per row (V per row for aux and adc)
//!
//! Without any, there is one panel per headstage, side by side. Wheel, pinch and keys act on
//! the panel under the pointer (marked by a bar along its top).

const std = @import("std");
const oez = @import("oez");
const Window = @import("window.zig").Window;
const gpu_mod = @import("gpu.zig");
const Gpu = gpu_mod.Gpu;
const font = @import("font.zig");
const format = @import("format.zig");
const fmtSpan = format.fmtSpan;
const fmtScale = format.fmtScale;
const control = @import("control.zig");
const audio_out = @import("audio_out.zig");
const notes_mod = @import("notes.zig");
const tiles_mod = @import("tiles.zig");
const Status = control.Status;
const Io = std.Io;
const log = std.log.scoped(.oez);
const args_mod = @import("args.zig");
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
const runDirect = @import("direct.zig").runDirect;
const session = @import("session.zig");
const Pacer = @import("pacing.zig").Pacer;

pub const std_options: std.Options = .{ .log_level = .info };

const Input = @import("window.zig").Input;
const panels_mod = oez.panels;
const Panel = panels_mod.Panel;

/// Blocks in the acquisition ring: 30 s of signal, which is how far the recorder may fall
/// behind (a stalled disk) before samples are lost. The display holds nothing back.
fn ringSlots(fs: f64, block_samples: usize) usize {
    // OEZ_TEST_RING_SECONDS shortens it, for testing what happens when it fills.
    const seconds: f64 = if (std.c.getenv("OEZ_TEST_RING_SECONDS")) |v| (std.fmt.parseFloat(f64, std.mem.span(v)) catch 30.0) else 30.0;
    return @intFromFloat(@ceil(seconds * fs / @as(f64, @floatFromInt(block_samples))));
}

/// Gives a stopped source new settings.
fn applyToSource(source: oez.source.Source, settings: oez.types.Settings) !void {
    switch (source) {
        .board => |b| try b.applySettings(settings),
        .sim => |s| try s.applySettings(settings),
    }
}

fn nowNs(io: Io) i128 {
    return Io.Clock.awake.now(io).nanoseconds;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len == 2 and std.mem.eql(u8, argv[1], "--lease-probe")) return @import("lease_probe.zig").run();
    // The config file, if there is one.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = if (init.environ_map.get("XDG_CONFIG_HOME")) |x|
        std.fmt.bufPrint(&path_buf, "{s}/oez/config.toml", .{x}) catch ""
    else
        std.fmt.bufPrint(&path_buf, "{s}/.config/oez/config.toml", .{init.environ_map.get("HOME") orelse ""}) catch "";
    const config_text: []const u8 = Io.Dir.cwd().readFileAlloc(io, config_path, init.arena.allocator(), .limited(1 << 16)) catch "";
    if (config_text.len > 0) log.info("config: {s}", .{config_path});
    const doc = oez.toml.parse(init.arena.allocator(), config_text) catch {
        log.err("{s}: syntax error on line {d}", .{ config_path, oez.toml.error_line });
        return 2;
    };
    var args = parseArgs(argv, doc) catch return 2;
    // The view file sits beside the config.
    var views_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const views_path = std.fmt.bufPrint(&views_path_buf, "{s}/views.toml", .{std.fs.path.dirname(config_path) orelse "."}) catch "";
    const views_text: []const u8 = Io.Dir.cwd().readFileAlloc(io, views_path, init.arena.allocator(), .limited(1 << 18)) catch "";
    if (views_text.len > 0) {
        if (oez.toml.parse(init.arena.allocator(), views_text)) |vd| {
            args.views_doc = vd;
        } else |_| log.warn("{s}: syntax error on line {d}; the view file is ignored", .{ views_path, oez.toml.error_line });
    }

    // ---- the source: simulator or board ----
    var board: ?oez.board.Board = null;
    defer if (board) |*b| b.close();
    var sim: ?oez.sim.Sim = null;
    defer if (sim) |*sm| sm.deinit();
    const source: oez.source.Source = if (args.num_sim > 0) blk: {
        sim = try oez.sim.Sim.init(gpa, io, args.sim[0..args.num_sim]);
        try sim.?.applySettings(args.settings);
        log.info("simulated board: {d} headstages, {d} units", .{ args.num_sim, sim.?.units.len });
        break :blk .{ .sim = &sim.? };
    } else blk: {
        var dirbuf: [std.fs.max_path_bytes:0]u8 = undefined;
        if (args.driver == .d3xx) _ = oez.oni.configureDriverSearch(io, init.environ_map, &dirbuf);
        if (!oez.acquisition.lockMemory()) log.warn("mlockall failed; pages may be swapped out", .{});
        board = oez.board.Board.open(io, args.driver) catch |e| {
            log.err("could not open the board: {t} (liboni: {s})", .{ e, oez.oni.errorStr(oez.oni.lastError()) });
            return 1;
        };
        try board.?.applySettings(args.settings);
        break :blk .{ .board = &board.? };
    };
    // These change when acquisition is restarted with another rate or channel set.
    var layout = source.layout();
    var nch = layout.numChannels();
    var fs = layout.sample_rate;
    var bs = source.settings().block_samples;
    log.info("{d} channels ({d} electrode) at {d} Hz", .{ nch, layout.num_electrodes, fs });

    // ---- acquisition into the ring ----
    // 30 s of blocks: what the recorder may fall behind (a stalled disk) before samples are
    // lost. The display reads it without holding anything back.
    var ring = try oez.ring.BlockRing.init(gpa, ringSlots(fs, bs), nch, bs);
    defer ring.deinit(gpa);
    var health: oez.types.Health = .{};
    // What of the loss counters the user has acknowledged (the alarm shows the rest).
    var alarms: session.Alarms = .{};
    var acq: oez.acquisition.Acquisition = .{ .io = io, .source = source, .ring = &ring, .health = &health, .scratch = try .init(gpa, nch, bs) };
    defer acq.scratch.deinit(gpa);
    var reader = oez.ring.LossyReader.init(&ring);
    var blk = try oez.types.Block.init(gpa, nch, bs);
    defer blk.deinit(gpa);

    if (args.direct.len > 0) return runDirect(io, gpa, args, layout, &acq, &reader, &blk);

    // ---- window and renderer ----
    var win: Window = undefined;
    // OEZ_APP_ID gives test runs a window class of their own (so compositor rules for the
    // real display do not apply to them).
    try win.init("oEZ", if (std.c.getenv("OEZ_APP_ID")) |v| std.mem.span(v) else "oez");
    defer win.deinit();
    const fullscreen = args.monitor.len > 0;
    if (fullscreen) {
        if (win.fullscreenOn(args.monitor)) {
            log.info("fullscreen on {s}", .{args.monitor});
        } else {
            log.err("no monitor named '{s}'; there are:", .{args.monitor});
            for (win.outputs[0..win.num_outputs]) |*o| log.err("  {s}", .{o.name()});
            return 2;
        }
    }
    _ = win.declareLowLatency();
    if (args.tearing and !win.preferTearing()) log.warn("the compositor has no tearing control; frames will wait for the refresh", .{});
    var gpu = try Gpu.init(gpa, .{ .wayland = .{ .display = win.display, .surface = win.surface } }, args.present, null);
    defer gpu.deinit();
    var notes = notes_mod.Notes.init(args.doc);
    defer notes.deinit();
    var display = makeDisplay(args, &layout) orelse return 2;
    // The longest time base plus a margin, so new samples never overwrite what is drawn.
    var history_samples: usize = @intFromFloat((Panel.span_max + 2.0) * fs);
    var feed = try oez.feed.Feed.init(gpa, &layout, &display.set, history_samples);
    defer feed.deinit(gpa);
    display.initial = display.set;
    try gpu.createHistory(feed.width, history_samples);
    var draws: [max_draws]gpu_mod.PanelDraw = undefined;
    var fills: [max_fills]gpu_mod.Fill = undefined;
    var text: Text = .{};
    text.init(gpa, &gpu, args);
    defer text.deinit(gpa);
    var batch = text.batch();
    var status: Status = .{};

    try acq.start();
    defer acq.join();

    // The control window, on its own thread (see control.zig).
    var shared: control.Shared = .{};
    var control_cfg: control.Config = .{ .gpa = gpa, .shared = &shared, .display_gpu = &gpu, .font_px = args.font_px };
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
    recording.setRoot(args.record_dir);
    // However the loop ends, a recording in progress is closed properly.
    defer recording.deinit();
    var rec_published_ns: i128 = 0;
    var view_file = try session.ViewFile.init(gpa, &display.set);
    defer view_file.deinit(gpa);
    var review: session.ReviewSession = .{};
    defer review.deinit();
    // The audio monitor (its own threads, see audio_out.zig).
    var audio_shared: audio_out.Shared = .{};
    display.audio.volume_db = args.volume_db;
    display.listenToFirst();
    audio_shared.publish(&display.audio);
    var audio_dev: ?*audio_out.AudioOut = if (args.audio) audio_out.AudioOut.start(gpa, &audio_shared, &ring, fs, nch, bs) else null;
    defer if (audio_dev) |a| a.stop();

    // The spike tiles (their own window and thread, see tiles.zig).
    var tiles_shared: tiles_mod.Shared = .{};
    tiles_shared.publish(&display.tileConfig());
    var tiles_win: ?*tiles_mod.Tiles = if (args.tiles) tiles_mod.Tiles.start(gpa, &tiles_shared, &ring, &layout, bs, &gpu, args.font, args.font_px) else null;
    defer if (tiles_win) |t| t.stop();
    var tiles_published_ns: i128 = 0;

    // Board settings as the control window changes them, and the question on quitting.
    var board_ctl: session.BoardControl = .init(acq.requested, config_path);

    var newest: i64 = 0;
    var newest_acquired_ns: i128 = 0;
    // When to draw, and how the frames landed (see pacing.zig).
    var pacer: Pacer = .init(args.margin_ms, args.free_ms, fullscreen);
    // Diagnostics only: time the GPU per frame (it delays presenting, see gpu.zig).
    gpu.wait_render = pacer.debug;
    var script_pos: usize = 0;
    const t_start = nowNs(io);
    var next_report: i128 = t_start + std.time.ns_per_s;
    var title_buf: [160]u8 = undefined;

    while (!win.closed and !acq.done.load(.acquire)) {
        // Wake for events, for new samples (every 2 ms), or when the frame is due.
        const wait_ms = pacer.waitMs(nowNs(io));
        try win.pump(wait_ms);

        // New samples into the GPU's history.
        while (reader.next(&blk)) {
            if (blk.len == 0) continue;
            gpu.writeSamples(blk.first_sample, try feed.rows(gpa, blk.first_sample, blk.samples(), blk.ttl[0..blk.len]));
            display.feedBlock(blk.first_sample, blk.samples(), nch, fs, blk.ttl[0..blk.len]);
            newest = blk.first_sample + @as(i64, @intCast(blk.len));
            newest_acquired_ns = blk.acquired_ns;
        }

        var input = win.takeInput();
        if (args.script.len > 0) runScript(args.script, &script_pos, @as(f64, @floatFromInt(nowNs(io) - t_start)) / 1e9, &input, &display);
        // Input goes to the panel under the pointer.
        display.pointAt(input.pointer_x / @as(f64, @floatFromInt(@max(win.width, 1))), input.pointer_y / @as(f64, @floatFromInt(@max(win.height, 1))));
        // Notes first: while one is being typed, every key is its text. "Now" is the
        // newest sample acquired plus the time since.
        const note_stamp: i64 = newest + if (newest_acquired_ns != 0) @as(i64, @intFromFloat(@as(f64, @floatFromInt(nowNs(io) - newest_acquired_ns)) * 1e-9 * fs)) else 0;
        notes.handle(&input, note_stamp, recording.sessionPath());
        // Review keys (what is left of them after a note took its own).
        for (input.keys[0..input.num_keys]) |k| {
            const cmd: control.ReviewAction = switch (k) {
                .space => .toggle,
                .left => .back,
                .right => .forward,
                .page_up => .page_back,
                .page_down => .page_forward,
                .home => .start,
                .end => .live,
                else => continue,
            };
            review.queue(cmd);
        }
        // Quitting (q or Esc here, Quit in the control window) asks first if the board
        // settings were changed; a second request quits.
        var quit = display.applyInput(input);
        var quit_answer: ?control.QuitAnswer = null;
        // What was clicked in the control window.
        while (shared.pop()) |e| {
            if (e.action == .quit_answer) quit_answer = e.action.quit_answer;
            if (e.action == .review) review.queue(e.action.review);
            if (e.action == .save_view) {
                if (view_file.save(io, views_path, &display.set)) |_| {
                    board_ctl.status.setNote("view saved to {s}", .{views_path});
                } else |err| board_ctl.status.setNote("could not save {s}: {t}", .{ views_path, err });
            }
            if (e.action == .note_preset) notes.stampPreset(e.action.note_preset, note_stamp, recording.sessionPath());
            if (display.applyEdit(e)) quit = true;
            snap_dirty = true;
            if (e.action == .board) board_ctl.edit(e.action.board, &acq, fs, recording.active(), io, gpa, config_path);
            if (e.action == .record) {
                if (e.action.record and !recording.active()) {
                    // Review of an earlier recording ends where a new one begins.
                    review.active = false;
                    alarms.seen.gaps = 0;
                    if (!recording.start(gpa, io, &ring, .{
                        .layout = layout,
                        .settings = source.settings(),
                        .gateware = if (board) |b| b.fw else @splat(0),
                        .board_id = if (board) |b| b.device_id else 0,
                        .cable_delay = if (board) |b| b.cable_delay else @splat(0),
                        .board_kind = if (board != null) "Open Ephys acquisition board (ECP5, FT600, ONI)" else "simulated",
                        .session = true,
                        .ttl_names = names: {
                            var names: [8][]const u8 = undefined;
                            for (&names, 1..) |*n, line| n.* = display.set.ttlName(line);
                            break :names names;
                        },
                    }, &acq.events, nowNs(io))) alarms.recording_failed = true;
                } else if (!e.action.record) recording.requestStop();
            }
        }
        if (review.step(.{ .gpa = gpa, .gpu = &gpu, .layout = &layout, .set = &display.set, .target = display.target, .newest = newest, .rec = recording.recorder })) snap_dirty = true;
        // Notes saved this turn go into the recording, if there is one.
        for (notes.fresh[0..notes.num_fresh]) |*note| {
            recording.note(note.sample, note.text());
        }
        notes.num_fresh = 0;
        if (notes.dirty) {
            notes.dirty = false;
            snap_dirty = true;
        }
        // A click on a spike tile listens to its channel, as a click on a row does.
        while (tiles_shared.clicks.pop()) |c| display.listenClick(c.channel, c.add);
        if (tiles_win != null and nowNs(io) - tiles_published_ns > 200 * std.time.ns_per_ms) {
            tiles_published_ns = nowNs(io);
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
                    if (view_file.unsaved(&display.set)) {
                        if (view_file.save(io, views_path, &display.set)) |_| {
                            log.info("view saved to {s}", .{views_path});
                        } else |err| {
                            board_ctl.status.setNote("could not save {s}: {t}", .{ views_path, err });
                            view_ok = false;
                        }
                    }
                    if (board_ok and view_ok) break;
                    board_ctl.quit_prompt.active = false;
                },
                .discard => break,
                .cancel => board_ctl.quit_prompt.active = false,
            };
            snap_dirty = true;
        }
        if (quit) {
            if (!board_ctl.askBeforeQuit(&acq.requested, view_file.unsaved(&display.set), control_thread != null and !shared.closed.load(.acquire))) break;
            snap_dirty = true;
        }
        // Sample rate or channel set: stop, reconfigure the board, and start again with
        // everything that depends on the shape of the data rebuilt.
        if (board_ctl.restart_asked) {
            board_ctl.restart_asked = false;
            snap_dirty = true;
            if (recording.active()) {
                board_ctl.status.setNote("stop the recording first: this changes the shape of the data", .{});
            } else {
                // Review looks into a history that is about to be replaced.
                review.drop();
                // The tiles and the audio threads read the ring that is about to be replaced.
                if (tiles_win) |t| t.stop();
                tiles_win = null;
                if (audio_dev) |a| a.stop();
                audio_dev = null;
                acq.join();
                const before = source.settings();
                applyToSource(source, board_ctl.pending) catch |err| {
                    log.err("the board refused the new settings ({t}); going back", .{err});
                    board_ctl.status.setNote("the board refused the new settings: {t}", .{err});
                    board_ctl.pending = before;
                    try applyToSource(source, before);
                };
                layout = source.layout();
                nch = layout.numChannels();
                fs = layout.sample_rate;
                bs = source.settings().block_samples;
                log.info("restarted: {d} channels ({d} electrode) at {d} Hz", .{ nch, layout.num_electrodes, fs });
                // New first, then swap, so a failure leaves nothing half torn down.
                const new_ring = try oez.ring.BlockRing.init(gpa, ringSlots(fs, bs), nch, bs);
                ring.deinit(gpa);
                ring = new_ring;
                const new_scratch = try oez.types.Block.init(gpa, nch, bs);
                acq.scratch.deinit(gpa);
                acq = .{ .io = io, .source = source, .ring = &ring, .health = &health, .scratch = new_scratch };
                const new_blk = try oez.types.Block.init(gpa, nch, bs);
                blk.deinit(gpa);
                blk = new_blk;
                reader = oez.ring.LossyReader.init(&ring);
                // The panels again from the config (their sources may have moved), keeping
                // what was set by hand where the panels still correspond.
                const old_set = display.set;
                const old_audio = display.audio;
                var new_display = makeDisplay(args, &layout) orelse Display.init(panels_mod.default(&layout));
                session.carryOver(&new_display.set, &old_set);
                history_samples = @intFromFloat((Panel.span_max + 2.0) * fs);
                const new_feed = try oez.feed.Feed.init(gpa, &layout, &new_display.set, history_samples);
                feed.deinit(gpa);
                feed = new_feed;
                const config_set = new_display.initial;
                new_display.initial = new_display.set;
                // `r` goes back to the config's values, with the new slots.
                for (new_display.initial.slice(), config_set.items[0..config_set.len], new_display.set.items[0..new_display.set.len]) |*i, *c, *p| {
                    i.* = c.*;
                    i.slot = p.slot;
                }
                display = new_display;
                try gpu.createHistory(feed.width, history_samples);
                newest = 0;
                newest_acquired_ns = 0;
                pacer.drawn_newest = 0;
                try acq.start();
                board_ctl.pending = acq.requested;
                // Channel numbers mean something else now.
                new_display_audio: {
                    display.audio = old_audio;
                    display.listenToFirst();
                    audio_shared.publish(&display.audio);
                    break :new_display_audio;
                }
                if (args.audio) audio_dev = audio_out.AudioOut.start(gpa, &audio_shared, &ring, fs, nch, bs);
                if (args.tiles) tiles_win = tiles_mod.Tiles.start(gpa, &tiles_shared, &ring, &layout, bs, &gpu, args.font, args.font_px);
            }
        }
        // The recorder has finished (asked to, or because writing failed).
        if (recording.poll(fs)) |ended| {
            snap_dirty = true;
            if (ended == .failed) alarms.recording_failed = true;
        }
        // While recording, the control window's counts move four times a second.
        if ((recording.active() or review.active) and nowNs(io) - rec_published_ns > 250 * std.time.ns_per_ms) {
            rec_published_ns = nowNs(io);
            snap_dirty = true;
        }
        // Alarms: anything that means samples are not being kept.
        if (alarms.update(&status, .{
            .overflow = acq.ring_overflow.load(.monotonic),
            .dropped = health.dropped_samples.load(.monotonic),
            .gaps = recording.gaps(),
        }, recording.behind(bs, fs), &display.acknowledged)) snap_dirty = true;
        audio_shared.alarm.store(status.alarm_len > 0, .monotonic);
        status.recording = recording.active();
        status.rec_seconds = recording.seconds(nowNs(io));
        if (input.num_keys > 0 or input.scroll_x != 0 or input.scroll_y != 0 or input.pinch != 1 or display.target != snap_target) snap_dirty = true;
        if (snap_dirty and control_thread != null) {
            snap_dirty = false;
            snap_target = display.target;
            shared.publish(&.{
                .set = display.set,
                .target = display.target,
                .status = status,
                .ring_overflow = acq.ring_overflow.load(.monotonic),
                .seconds = @as(f64, @floatFromInt(nowNs(io) - t_start)) / 1e9,
                .quit_prompt = board_ctl.quit_prompt,
                .review = review.status(newest, fs),
                .view_unsaved = view_file.unsaved(&display.set),
                .notes = session.notesStatus(&notes, fs),
                .audio = session.audioStatus(&display, &audio_shared, &layout),
                .about_buf = about: {
                    var b: [160]u8 = undefined;
                    _ = std.fmt.bufPrint(&b, "{s}   {d} channels ({d} electrode) at {d} Hz", .{ if (sim != null) "simulated board" else "Open Ephys acquisition board", nch, layout.num_electrodes, fs }) catch "";
                    break :about b;
                },
                .about_len = std.fmt.count("{s}   {d} channels ({d} electrode) at {d} Hz", .{ if (sim != null) "simulated board" else "Open Ephys acquisition board", nch, layout.num_electrodes, fs }),
                .board = board_ctl.statusNow(&acq.requested, &layout),
                .rec = recording.statusNow(nowNs(io), bs, fs),
            });
        }
        // A panel's corners changed: filter its recent past again.
        if (gpu.hist_cap > 0) _ = try feed.sync(gpa, &display.set, refilterSamples(&display.set, fs), gpu.hist, gpu.hist_cap);

        for (win.takePresented()) |p| pacer.presented(p, nowNs(io), win.presentation_clock);

        const now = nowNs(io);
        if (pacer.due(now, win.frame_ready, newest)) {
            if (win.resized or gpu.swapchain == .null) {
                try gpu.resize(win.width, win.height);
                win.resized = false;
                pacer.n_resize += 1;
            }
            const fr = display.frame(&gpu, &layout, newest, review.view(newest, fs), status, &notes, &batch, &draws, &fills);
            const Ctx = struct { win: *Window, tag: u64 };
            const result = try gpu.draw(fr.draws, fr.fills, fr.text, Ctx{ .win = &win, .tag = pacer.begin(newest_acquired_ns) }, struct {
                fn f(c: Ctx) void {
                    c.win.beforePresent(c.tag);
                }
            }.f);
            pacer.end(now, nowNs(io), result, newest, if (gpu.wait_render) @as(f64, @floatFromInt(gpu.last_render_ns)) / 1e6 else null);
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
                secs,        r.frames,                           r.avg_ms,           r.min_ms,  r.max_ms,
                r.on_time,   r.late,                             r.skips,            r.margin_ms, r.refresh_ms,
                reader.lost, acq.ring_overflow.load(.monotonic), display.target + 1, tp.span_s, tp.scale,
                gpu.extent.width, gpu.extent.height,
            });
            status.valid = r.valid;
            status.latency_ms = r.avg_ms;
            status.fps = r.frames;
            status.lost = reader.lost;
            snap_dirty = true;
            if (audio_dev != null) log.info("  audio: {d:.1} ms (queue {d:.1}, device {d:.1}, margin {d:.1}; longest wait for a block {d:.1}, oldest block {d:.1}), gaps {d}, dropped {d}, noise {d:.1} uV{s}", .{
                @as(f64, @floatFromInt(audio_shared.latency_us.load(.monotonic))) / 1000.0,
                @as(f64, @floatFromInt(audio_shared.queue_us.load(.monotonic))) / 1000.0,
                @as(f64, @floatFromInt(audio_shared.device_us.load(.monotonic))) / 1000.0,
                @as(f64, @floatFromInt(audio_shared.margin_us.load(.monotonic))) / 1000.0,
                @as(f64, @floatFromInt(audio_shared.max_block_gap_us.swap(0, .monotonic))) / 1000.0,
                @as(f64, @floatFromInt(audio_shared.max_block_age_us.swap(0, .monotonic))) / 1000.0,
                audio_shared.underruns.load(.monotonic),
                audio_shared.dropped.load(.monotonic),
                @as(f64, @floatFromInt(audio_shared.held_sigma_c.load(.monotonic))) / 100.0 * oez.types.electrode_uv_per_bit,
                if (audio_shared.held_sigma_c.load(.monotonic) == 0) " (measuring)" else " held",
            });
            if (std.c.getenv("OEZ_NO_TITLE") == null) {
                if (std.fmt.bufPrintSentinel(&title_buf, "oEZ   {s}: {d:.2} s  {d:.1} {s}/row   latency {d:.1} ms   {d} fps", .{ tp.name(), tp.span_s, tp.scale, tp.unit(), r.avg_ms, r.frames }, 0)) |t| win.setTitle(t) else |_| {}
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
