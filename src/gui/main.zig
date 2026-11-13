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

pub const std_options: std.Options = .{ .log_level = .info };

const Args = struct {
    seconds: f64 = 0,
    settings: oez.types.Settings = .{},
    driver: oez.board.Driver = .usb,
    sim: [8]usize = @splat(0),
    num_sim: usize = 0,
    present: gpu_mod.PresentMode = .auto,
    /// Fixed margin before the refresh at which to draw; negative = adapt.
    margin_ms: f64 = -1,
    script: []const u8 = "",
    monitor: []const u8 = "",
    /// Connector of a monitor to drive directly, with no compositor.
    direct: []const u8 = "",
    tearing: bool = false,
    /// Where recordings go: one session folder per recording beneath it.
    record_dir: []const u8 = "~/oez-recordings",
    /// The spike tiles (a third window).
    tiles: bool = true,
    /// The spike audio monitor.
    audio: bool = true,
    volume_db: f64 = -6,
    /// The control window (a second, ordinary window with the panels' settings).
    control: bool = true,
    /// All panels in sweep mode (see `panels.Mode`).
    sweep: bool = false,
    /// Free-running: least interval between frames in ms; negative = paced to the refresh.
    free_ms: f64 = -1,
    /// Font for labels: a fontconfig name and a size in pixels.
    font: []const u8 = "sans-serif",
    font_px: u32 = 14,
    /// The view file (panel settings saved from the control window), applied on top of the
    /// config's panels.
    views_doc: oez.toml.Document = .{ .entries = &.{} },
    /// The parsed config file (panels are read from it once the channel layout is known).
    doc: oez.toml.Document = .{ .entries = &.{} },
};

const Input = @import("window.zig").Input;
const panels_mod = oez.panels;
const Panel = panels_mod.Panel;

/// Adds the script steps that are due at `elapsed_s` to `in`. `pos` is the script cursor.
/// `panel=N` (1-based) and `pointer=FX,FY` (fractions of the display) choose the panel that
/// input goes to, as moving the pointer would.
fn runScript(script: []const u8, pos: *usize, elapsed_s: f64, in: *Input, display: *Display) void {
    while (pos.* < script.len) {
        const rest = script[pos.*..];
        const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        const step = rest[0..end];
        const colon = std.mem.indexOfScalar(u8, step, ':') orelse {
            pos.* += @min(end + 1, rest.len);
            continue;
        };
        const at = std.fmt.parseFloat(f64, step[0..colon]) catch 0;
        if (at > elapsed_s) return;
        const what = step[colon + 1 ..];
        if (std.mem.startsWith(u8, what, "cwheel=")) {
            // Ctrl+wheel.
            in.scroll_y += std.fmt.parseFloat(f64, what[7..]) catch 0;
            in.ctrl = true;
        } else if (std.mem.startsWith(u8, what, "wheel=")) {
            in.scroll_y += std.fmt.parseFloat(f64, what[6..]) catch 0;
        } else if (std.mem.startsWith(u8, what, "hwheel=")) {
            in.scroll_x += std.fmt.parseFloat(f64, what[7..]) catch 0;
        } else if (std.mem.startsWith(u8, what, "pinch=")) {
            in.pinch *= std.fmt.parseFloat(f64, what[6..]) catch 1;
        } else if (std.mem.startsWith(u8, what, "panel=")) {
            const n = std.fmt.parseInt(usize, what[6..], 10) catch 1;
            display.scripted_target = std.math.clamp(n, 1, @max(display.set.len, 1)) - 1;
        } else if (std.mem.startsWith(u8, what, "type=")) {
            // Text as typed (for notes).
            const t = what[5..];
            const n = @min(t.len, in.text.len - in.text_len);
            @memcpy(in.text[in.text_len..][0..n], t[0..n]);
            in.text_len += n;
        } else if (std.mem.eql(u8, what, "enter") or std.mem.eql(u8, what, "esc") or std.mem.eql(u8, what, "tab") or std.mem.eql(u8, what, "backspace")) {
            if (in.num_keys < in.keys.len) {
                in.keys[in.num_keys] = if (what[0] == 'e' and what[1] == 'n') .enter else if (what[0] == 'e') .escape else if (what[0] == 't') .tab else .backspace;
                in.num_keys += 1;
            }
        } else if (std.mem.eql(u8, what, "space") or std.mem.eql(u8, what, "home") or std.mem.eql(u8, what, "end") or std.mem.eql(u8, what, "pgup") or std.mem.eql(u8, what, "pgdn") or std.mem.eql(u8, what, "left") or std.mem.eql(u8, what, "right")) {
            if (in.num_keys < in.keys.len) {
                in.keys[in.num_keys] = switch (what[0]) {
                    's' => .space,
                    'h' => .home,
                    'e' => .end,
                    'l' => .left,
                    'r' => .right,
                    else => if (what[2] == 'u') .page_up else .page_down,
                };
                in.num_keys += 1;
            }
        } else if (std.mem.eql(u8, what, "click")) {
            in.clicks += 1;
        } else if (std.mem.eql(u8, what, "cclick")) {
            // Ctrl+click.
            in.clicks += 1;
            in.ctrl = true;
        } else if (std.mem.startsWith(u8, what, "pointer=")) {
            var it = std.mem.tokenizeScalar(u8, what[8..], ',');
            const fx = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            const fy = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
            if (display.set.at(fx, fy)) |i| display.scripted_target = i;
            display.pointer_fy = fy;
            display.scripted_pointer = true;
        } else for (what) |ch| {
            if (in.num_keys == in.keys.len) break;
            in.keys[in.num_keys] = switch (ch) {
                '[' => .left_bracket,
                ']' => .right_bracket,
                '-' => .minus,
                '=' => .equal,
                'r' => .r,
                'm' => .m,
                'f' => .f,
                't' => .t,
                's' => .s,
                'a' => .a,
                '/' => .slash,
                '`' => .grave,
                '\\' => .backslash,
                '9' => @enumFromInt(ch),
                '1'...'8' => @enumFromInt(ch),
                ',' => .comma,
                '.' => .dot,
                '\'' => .apostrophe,
                'q' => .q,
                else => continue,
            };
            in.num_keys += 1;
        }
        pos.* += @min(end + 1, rest.len);
    }
}

/// Applies the config file's top-level keys to `a`. (`[[panel]]` tables are read later.)
fn applyConfig(a: *Args, doc: oez.toml.Document) void {
    a.doc = doc;
    for (doc.entries) |e| {
        if (e.table.len != 0) {
            if (!std.mem.eql(u8, e.table, "panel") and !std.mem.eql(u8, e.table, "board") and !std.mem.eql(u8, e.table, "ttl") and !std.mem.eql(u8, e.table, "notes")) log.warn("config line {d}: unknown table [{s}]", .{ e.line, e.table });
            continue;
        }
        if (std.mem.eql(u8, e.key, "monitor") and e.value == .string) {
            a.monitor = e.value.string;
        } else if (std.mem.eql(u8, e.key, "margin_ms") and e.value == .number) {
            a.margin_ms = e.value.number;
        } else if (std.mem.eql(u8, e.key, "free_ms") and e.value == .number) {
            a.free_ms = e.value.number;
        } else if (std.mem.eql(u8, e.key, "font") and e.value == .string) {
            a.font = e.value.string;
        } else if (std.mem.eql(u8, e.key, "font_px") and e.value == .number and e.value.number >= 6 and e.value.number <= 64) {
            a.font_px = @intFromFloat(e.value.number);
        } else if (std.mem.eql(u8, e.key, "tiles") and e.value == .boolean) {
            a.tiles = e.value.boolean;
        } else if (std.mem.eql(u8, e.key, "audio") and e.value == .boolean) {
            a.audio = e.value.boolean;
        } else if (std.mem.eql(u8, e.key, "volume_db") and e.value == .number) {
            a.volume_db = std.math.clamp(e.value.number, -60, 12);
        } else if (std.mem.eql(u8, e.key, "record_dir") and e.value == .string) {
            a.record_dir = e.value.string;
        } else if (std.mem.eql(u8, e.key, "control") and e.value == .boolean) {
            a.control = e.value.boolean;
        } else if (std.mem.eql(u8, e.key, "mode")) {
            // Read with the panels.
        } else if (std.mem.eql(u8, e.key, "tearing") and e.value == .boolean) {
            a.tearing = e.value.boolean;
            if (a.tearing) a.present = .immediate;
        } else log.warn("config line {d}: unknown key '{s}' or wrong type", .{ e.line, e.key });
    }
}

fn parseArgs(args: []const [:0]const u8, doc: oez.toml.Document) !Args {
    var a: Args = .{};
    applyConfig(&a, doc);
    // The [board] table; command-line options below win over it.
    oez.board_config.read(doc, &a.settings) catch {
        log.err("config: {s}", .{oez.board_config.error_message});
        return error.BadArgs;
    };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const next = struct {
            fn f(list: []const [:0]const u8, idx: *usize, name: []const u8) ![]const u8 {
                idx.* += 1;
                if (idx.* >= list.len) {
                    log.err("{s} needs a value", .{name});
                    return error.BadArgs;
                }
                return list[idx.*];
            }
        }.f;
        if (std.mem.eql(u8, arg, "--seconds")) {
            a.seconds = try std.fmt.parseFloat(f64, try next(args, &i, arg));
        } else if (std.mem.eql(u8, arg, "--direct")) {
            a.direct = try next(args, &i, arg);
            if (a.seconds == 0) a.seconds = 20;
        } else if (std.mem.eql(u8, arg, "--monitor")) {
            a.monitor = try next(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--tearing")) {
            a.tearing = true;
            a.present = .immediate;
        } else if (std.mem.eql(u8, arg, "--no-tiles")) {
            a.tiles = false;
        } else if (std.mem.eql(u8, arg, "--no-audio")) {
            a.audio = false;
        } else if (std.mem.eql(u8, arg, "--no-control")) {
            a.control = false;
        } else if (std.mem.eql(u8, arg, "--sweep")) {
            a.sweep = true;
        } else if (std.mem.eql(u8, arg, "--free")) {
            a.free_ms = try std.fmt.parseFloat(f64, try next(args, &i, arg));
        } else if (std.mem.eql(u8, arg, "--script")) {
            a.script = try next(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--margin-ms")) {
            a.margin_ms = try std.fmt.parseFloat(f64, try next(args, &i, arg));
        } else if (std.mem.eql(u8, arg, "--aux")) {
            a.settings.acquire_aux = true;
        } else if (std.mem.eql(u8, arg, "--adc")) {
            a.settings.acquire_adc = true;
        } else if (std.mem.eql(u8, arg, "--driver")) {
            const name = try next(args, &i, arg);
            a.driver = std.meta.stringToEnum(oez.board.Driver, name) orelse {
                log.err("--driver: '{s}' is not usb or d3xx", .{name});
                return error.BadArgs;
            };
        } else if (std.mem.eql(u8, arg, "--present")) {
            const name = try next(args, &i, arg);
            a.present = std.meta.stringToEnum(gpu_mod.PresentMode, name) orelse {
                log.err("--present: '{s}' is not auto, mailbox, immediate or fifo", .{name});
                return error.BadArgs;
            };
        } else if (std.mem.eql(u8, arg, "--sim")) {
            var it = std.mem.tokenizeScalar(u8, try next(args, &i, arg), ',');
            while (it.next()) |n| {
                const ch = std.fmt.parseInt(usize, n, 10) catch 0;
                if ((ch != 16 and ch != 32 and ch != 64) or a.num_sim == a.sim.len) {
                    log.err("--sim: give up to 8 headstages of 16, 32 or 64 channels, e.g. 32,16", .{});
                    return error.BadArgs;
                }
                a.sim[a.num_sim] = ch;
                a.num_sim += 1;
            }
        } else if (std.mem.eql(u8, arg, "--16ch")) {
            var it = std.mem.tokenizeScalar(u8, try next(args, &i, arg), ',');
            while (it.next()) |name| {
                const slot = for (oez.types.headstage_names, 0..) |n, k| {
                    if (std.ascii.eqlIgnoreCase(n, name)) break k;
                } else {
                    log.err("--16ch: unknown headstage slot '{s}' (use A1..D2)", .{name});
                    return error.BadArgs;
                };
                a.settings.rhd2132_16ch[slot] = true;
            }
        } else {
            log.err("unknown argument '{s}'", .{arg});
            return error.BadArgs;
        }
    }
    // Tearing shows frames as they are presented, so draw as samples arrive.
    if (a.tearing and a.free_ms < 0) a.free_ms = 2;
    return a;
}

const max_text_vertices = 24 * 1024;
/// Per panel: two dividers, the target bar, and the sweep cursor's two.
const max_fills = 5 * panels_mod.max_panels;
/// One draw per panel, or per overlaid sweep of a triggered panel.
const max_draws = panels_mod.max_panels * oez.sweeps.max_sweeps;

/// The display filter for a panel's title: "   300-6000 Hz", "   > 10 Hz", "   < 300 Hz",
/// or nothing when the panel shows its channels as they are.
fn fmtBand(buf: []u8, p: *const Panel) []const u8 {
    if (p.kind != .electrode) return "";
    if (!p.filtered) return if (p.carActive()) "   CAR" else "";
    const lo = p.band_low_hz;
    const hi = p.band_high_hz;
    const car: []const u8 = if (p.carActive()) "   CAR" else "";
    return (if (lo > 0 and hi > 0)
        std.fmt.bufPrint(buf, "   {d}-{d} Hz{s}", .{ lo, hi, car })
    else if (lo > 0)
        std.fmt.bufPrint(buf, "   > {d} Hz{s}", .{ lo, car })
    else if (hi > 0)
        std.fmt.bufPrint(buf, "   < {d} Hz{s}", .{ hi, car })
    else
        std.fmt.bufPrint(buf, "   filter: no corners{s}", .{car})) catch "";
}

/// An electrode channel by headstage and number ("A1-5"), or "ch 37" if it is not one.
fn channelName(buf: []u8, layout: *const oez.types.Layout, ch: u32) []const u8 {
    for (layout.headstageSlice()) |h| {
        if (ch >= h.first_channel and ch < h.first_channel + h.num_channels)
            return std.fmt.bufPrint(buf, "{s}-{d}", .{ oez.types.headstage_names[h.slot], ch - h.first_channel + 1 }) catch "";
    }
    return std.fmt.bufPrint(buf, "ch {d}", .{ch + 1}) catch "";
}

/// The display in scroll-back review: where it is looking.
const ReviewView = struct {
    /// The sample at the right edge of every panel in review.
    end: i64,
    /// Drawn from the review history (the recording's file) instead of the live one.
    from_file: bool,
    /// The stretch needed is there to draw.
    ready: bool,
    behind_s: f64,
};

/// What triggers a panel's sweeps: "TTL2", or "row 5 falling -62 µV".
fn trigText(buf: []u8, p: *const Panel) []const u8 {
    return (if (p.trig_source == .ttl)
        std.fmt.bufPrint(buf, "TTL{d}", .{p.trig_line})
    else
        std.fmt.bufPrint(buf, "row {d} {s} {d:.0} µV", .{ p.trig_row + 1, if (p.trig_rising) "rising" else "falling", p.trig_level_now_uv })) catch "";
}

/// How many recent samples to filter again when a panel's corners change: what its window
/// can show (two passes in sweep mode), and a second more.
fn refilterSamples(set: *const panels_mod.Set, fs: f64) usize {
    var longest: f64 = 0;
    for (set.items[0..set.len]) |*p| longest = @max(longest, if (p.mode == .sweep) 2 * p.span_s else p.span_s);
    return @intFromFloat((longest + 1.0) * fs);
}

/// The label of one row: the electrode's number on its headstage (with the headstage's name
/// when the panel spans more than one), or AUXn / ADCn.
fn rowLabel(buf: []u8, p: *const Panel, row: u32, layout: *const oez.types.Layout, set: *const panels_mod.Set) []const u8 {
    const ch = p.first_ch + row;
    switch (p.kind) {
        .ttl => {
            const line = p.ttl_lines[@min(row, 7)];
            const name = set.ttlName(line);
            return if (name.len > 0) name else std.fmt.bufPrint(buf, "TTL{d}", .{line}) catch "";
        },
        .electrode => {
            for (layout.headstageSlice()) |h| {
                if (ch < h.first_channel or ch >= h.first_channel + h.num_channels) continue;
                const n = ch - h.first_channel + 1;
                const within = p.first_ch >= h.first_channel and p.first_ch + p.rows <= h.first_channel + h.num_channels;
                return (if (within) std.fmt.bufPrint(buf, "{d}", .{n}) else std.fmt.bufPrint(buf, "{s}-{d}", .{ oez.types.headstage_names[h.slot], n })) catch "";
            }
            return std.fmt.bufPrint(buf, "{d}", .{ch + 1}) catch "";
        },
        .aux => return std.fmt.bufPrint(buf, "AUX{d}", .{row + 1}) catch "",
        .adc => return std.fmt.bufPrint(buf, "ADC{d}", .{row + 1}) catch "",
    }
}

/// The panels of the display, and which one input goes to.
const Display = struct {
    set: panels_mod.Set,
    /// The panels as configured, for `r` (reset).
    initial: panels_mod.Set,
    /// The panel that wheel, pinch and keys act on.
    target: usize = 0,
    /// Set by a test script (`panel=`, `pointer=`); then it overrides the pointer.
    scripted_target: ?usize = null,
    /// Where the pointer is, as a fraction of the display's height (for the row under it).
    pointer_fy: f64 = 0,
    scripted_pointer: bool = false,
    /// The triggers of each panel's TTL line (used by panels in triggered mode).
    triggers: [panels_mod.max_panels]oez.sweeps.Triggers = @splat(.{}),

    /// Set by `a` (and the control window's button): the alarm banner has been seen.
    acknowledged: bool = false,
    /// The audio monitor's settings (which channels, volume, ...); `audio_dirty` when they
    /// have changed and the audio threads are to be told.
    audio: oez.audio.Settings = .{},
    audio_dirty: bool = true,
    audio_recalibrate: bool = false,
    /// The sound takes the panels' common average references.
    audio_car: bool = true,

    /// The pulses of each panel's tint line (see `Panel.tint_line`).
    pulses: [panels_mod.max_panels]oez.sweeps.Pulses = @splat(.{}),
    /// The slope trigger of each panel that triggers on one of its channels, and what its
    /// trigger list was made from (a change of source, line or row starts it afresh).
    slopes: [panels_mod.max_panels]?oez.slope.Slope = @splat(null),
    trig_made_from: [panels_mod.max_panels]u64 = @splat(0),

    /// The channels whose mean is the reference for `channel`: those of the first panel
    /// that has its reference on and `channel` among the rows it subtracts from. Fills
    /// `out` (as many as fit) and returns how many.
    fn carChannels(self: *const Display, channel: u32, out: []u32) usize {
        for (self.set.items[0..self.set.len]) |*p| {
            if (!p.carActive() or channel < p.first_ch or channel >= p.first_ch + p.rows) continue;
            if (!p.car_sub.has(channel - p.first_ch)) continue;
            var n: usize = 0;
            for (0..p.rows) |r| {
                if (!p.car_ref.has(r) or n == out.len) continue;
                out[n] = p.first_ch + @as(u32, @intCast(r));
                n += 1;
            }
            return n;
        }
        return 0;
    }

    /// What the spike tiles need to know: the channels listened to, and the panels'
    /// common average references (a channel takes the first panel's that subtracts from
    /// it).
    fn tileConfig(self: *const Display) tiles_mod.Config {
        var cfg: tiles_mod.Config = .{ .listening = self.audio.channels, .num_listening = if (self.audio.enabled) self.audio.num_channels else 0 };
        for (self.set.items[0..self.set.len], 0..) |*p, g| {
            if (!p.carActive() or g >= oez.spikes.Car.max_groups) continue;
            var n: usize = 0;
            for (0..p.rows) |r| {
                if (!p.car_ref.has(r) or n == oez.spikes.Car.max_ref) continue;
                cfg.car.ref[g][n] = p.first_ch + @as(u32, @intCast(r));
                n += 1;
            }
            cfg.car.ref_len[g] = @intCast(n);
            for (0..p.rows) |r| {
                const ch = p.first_ch + r;
                if (p.car_sub.has(r) and ch < cfg.car.group_of.len and cfg.car.group_of[ch] < 0) cfg.car.group_of[ch] = @intCast(g);
            }
            cfg.use_car = true;
        }
        return cfg;
    }

    /// Brings the audio's references in line with the panels'. A change is a different
    /// signal, so the noise is measured again.
    fn refreshAudioCar(self: *Display) void {
        const a = &self.audio;
        for (a.channelSlice(), 0..) |ch, k| {
            var ref: [oez.audio.max_car_ref]u32 = undefined;
            const n = if (self.audio_car) self.carChannels(ch, &ref) else 0;
            if (n == a.car_len[k] and std.mem.eql(u32, ref[0..n], a.car_ref[k][0..n])) continue;
            a.car_len[k] = @intCast(n);
            @memcpy(a.car_ref[k][0..n], ref[0..n]);
            self.audio_dirty = true;
            self.audio_recalibrate = true;
        }
    }

    /// Listens to the first row of the first electrode panel.
    fn listenToFirst(self: *Display) void {
        self.audio.num_channels = 0;
        for (self.set.items[0..self.set.len]) |*p| {
            if (p.kind != .electrode or p.rows == 0) continue;
            self.audio.channels[0] = p.first_ch;
            self.audio.num_channels = 1;
            break;
        }
        self.audio_dirty = true;
    }

    fn listening(self: *const Display, channel: u32) bool {
        return std.mem.indexOfScalar(u32, self.audio.channelSlice(), channel) != null;
    }

    /// A click on an electrode row: listen to that channel alone, or with Ctrl add it to
    /// (or take it out of) what is listened to.
    fn listenClick(self: *Display, channel: u32, add: bool) void {
        const a = &self.audio;
        if (!add) {
            a.channels[0] = channel;
            a.num_channels = 1;
        } else if (std.mem.indexOfScalar(u32, a.channelSlice(), channel)) |at| {
            for (at..a.num_channels - 1) |k| a.channels[k] = a.channels[k + 1];
            a.num_channels -= 1;
        } else if (a.num_channels < a.channels.len) {
            a.channels[a.num_channels] = channel;
            a.num_channels += 1;
        }
        self.audio_dirty = true;
    }

    /// Looks for triggers in a block that starts at sample `first`: `samples` (`nch`
    /// interleaved, as acquired) for slope triggers, the digital `words` for TTL edges.
    fn feedBlock(self: *Display, first: i64, samples: []const i16, nch: usize, fs: f64, words: []const u16) void {
        for (self.set.items[0..self.set.len], self.triggers[0..self.set.len], self.pulses[0..self.set.len], 0..) |*p, *t, *pl, i| {
            const channel = p.trig_source == .channel and p.kind == .electrode;
            const made_from: u64 = if (channel) 0x100 + @as(u64, p.trig_row) else p.trig_line;
            if (self.trig_made_from[i] != made_from) {
                self.trig_made_from[i] = made_from;
                t.reset(p.trig_line);
                self.slopes[i] = null;
            }
            if (channel) {
                const want: oez.slope.Settings = .{
                    .rising = p.trig_rising,
                    .auto = p.trig_auto,
                    .level = p.trig_level_uv / oez.types.electrode_uv_per_bit,
                    .holdoff_ms = p.trig_holdoff_ms,
                };
                if (self.slopes[i] == null) self.slopes[i] = .init(fs, want);
                const sl = &self.slopes[i].?;
                sl.settings = want;
                // With the panel's reference, if the trigger's row is one it applies to.
                var ref: [oez.audio.max_car_ref]u32 = undefined;
                const nref = self.carChannels(p.first_ch + p.trig_row, &ref);
                sl.feed(first, samples, nch, p.first_ch + p.trig_row, ref[0..nref], t);
                p.trig_level_now_uv = sl.level() * oez.types.electrode_uv_per_bit;
            } else t.feed(first, words);
            if (p.tint_line == 0) continue;
            if (pl.line != p.tint_line) pl.reset(p.tint_line);
            pl.feed(first, words);
        }
    }

    fn init(set: panels_mod.Set) Display {
        return .{ .set = set, .initial = set };
    }

    /// Points input at the panel under the pointer (fractions of the display).
    fn pointAt(self: *Display, fx: f64, fy: f64) void {
        if (!self.scripted_pointer) self.pointer_fy = fy;
        if (self.scripted_target) |t| {
            self.target = t;
        } else if (self.set.at(fx, fy)) |t| self.target = t;
    }

    /// Puts a panel's settings back to what the config gave it.
    fn reset(self: *Display, index: usize) void {
        const p = &self.set.items[index];
        const was = &self.initial.items[index];
        // `initial` holds the config's values with this run's slots.
        p.* = was.*;
    }

    /// Applies an edit from the control window. True means quit.
    fn applyEdit(self: *Display, edit: control.Edit) bool {
        if (edit.action == .quit) return true;
        if (edit.action == .acknowledge) {
            self.acknowledged = true;
            return false;
        }
        if (edit.action == .audio) {
            switch (edit.action.audio) {
                .enabled => |on| self.audio.enabled = on,
                .mute => |on| self.audio.mute = on,
                .volume => |up| self.audio.volume_db = std.math.clamp(self.audio.volume_db + (if (up) @as(f64, 2) else -2), -60, 12),
                .reference => |on| self.audio.reference = on,
                .car => |on| self.audio_car = on,
                .recalibrate => self.audio_recalibrate = true,
            }
            self.audio_dirty = true;
            return false;
        }
        if (edit.action == .record or edit.action == .board or edit.action == .quit_answer or edit.action == .note_preset or edit.action == .save_view or edit.action == .review or edit.panel >= self.set.len) return false;
        const p = &self.set.items[edit.panel];
        switch (edit.action) {
            .scale => |f| p.scale *= f,
            .zoom => |f| if (p.mode == .triggered) {
                p.pre_ms *= f;
                p.post_ms *= f;
            } else {
                p.span_s *= f;
            },
            .mode => |m| p.mode = m,
            .filter => |on| p.filtered = on and p.kind == .electrode,
            .corner => |c| p.stepCorner(c.high, c.up),
            .trig_line => |l| p.trig_line = l,
            .row_hidden => |row| p.hidden.set(row, !p.hidden.has(row)),
            .row_raw => |row| p.raw_rows.set(row, !p.raw_rows.has(row)),
            .car => |on| p.setCar(on),
            .car_ref_row => |r| p.car_ref.set(r, !p.car_ref.has(r)),
            .car_sub_row => |r| p.car_sub.set(r, !p.car_sub.has(r)),
            .car_ref_all => |on| p.car_ref = if (on) .all(p.rows) else .{},
            .car_sub_all => |on| p.car_sub = if (on) .all(p.rows) else .{},
            .trig_source => |s| p.setTrigSource(s),
            .trig_row => |d| p.trig_row = @intCast(std.math.clamp(@as(i64, p.trig_row) + d, 0, @as(i64, p.rows) - 1)),
            .trig_rising => |on| {
                // The fixed level changes side with the slope.
                if (on != p.trig_rising) p.trig_level_uv = -p.trig_level_uv;
                p.trig_rising = on;
            },
            .trig_auto => |on| {
                // Going to a fixed level starts from where the level is now.
                if (!on and p.trig_auto and p.trig_level_now_uv != 0) p.trig_level_uv = @round(p.trig_level_now_uv);
                p.trig_auto = on;
            },
            .trig_level => |f| p.trig_level_uv = if (@abs(p.trig_level_uv * f) < 5) (if (p.trig_level_uv < 0) -5.0 else 5.0) else p.trig_level_uv * f,
            .trig_holdoff => |up| p.trig_holdoff_ms = oez.board_config.step(f64, &.{ 0, 1, 2, 5, 10, 20, 50, 100, 200, 500 }, p.trig_holdoff_ms, up),
            .overlay => |n| p.overlay = n,
            .reset => self.reset(edit.panel),
            .quit, .record, .board, .quit_answer, .audio, .note_preset, .save_view, .review, .acknowledge => {},
        }
        p.clamp();
        return false;
    }

    /// Applies what the user did to the target panel. True means quit.
    fn applyInput(self: *Display, in: Input) bool {
        if (self.scripted_target) |t| self.target = t;
        var quit = false;
        for (in.keys[0..in.num_keys]) |k| {
            if (k == .escape or k == .q) quit = true;
        }
        if (self.set.len == 0) return quit;
        const p = &self.set.items[self.target];
        // One wheel click (about 15 units) changes a scale by 15 %.
        const per_unit = 0.0093;
        var sx = in.scroll_x;
        var sy = in.scroll_y;
        if (in.shift) {
            sx += sy;
            sy = 0;
        }
        if (sy != 0) {
            // Ctrl: the row under the pointer alone.
            if (in.ctrl) {
                if (p.rowAt(self.pointer_fy)) |row| p.scaleRow(row, @exp(sy * per_unit));
            } else p.scale *= @exp(sy * per_unit);
        }
        // The time base; in triggered mode, the window around the trigger.
        var zoom: f64 = 1;
        if (sx != 0) zoom *= @exp(sx * per_unit);
        // Fingers apart = zoom in = less time across the panel.
        if (in.pinch != 1 and in.pinch > 0) zoom /= in.pinch;
        for (in.keys[0..in.num_keys]) |k| switch (k) {
            .left_bracket => zoom *= 1.25,
            .right_bracket => zoom /= 1.25,
            else => {},
        };
        if (p.mode == .triggered) {
            p.pre_ms *= zoom;
            p.post_ms *= zoom;
        } else p.span_s *= zoom;
        for (in.keys[0..in.num_keys]) |k| switch (k) {
            .minus => p.scale *= 1.25,
            .equal => p.scale /= 1.25,
            .r => self.reset(self.target),
            .f => p.filtered = p.kind == .electrode and !p.filtered,
            .comma => if (p.filtered) p.stepCorner(false, false),
            .dot => if (p.filtered) p.stepCorner(false, true),
            .semicolon => if (p.filtered) p.stepCorner(true, false),
            .apostrophe => if (p.filtered) p.stepCorner(true, true),
            .m => p.mode = if (p.mode == .scroll) .sweep else .scroll,
            .a => self.acknowledged = true,
            // Triggered mode: s switches between a TTL line and spikes on the row under
            // the pointer.
            .s => if (p.mode == .triggered) {
                if (p.trig_source == .ttl) {
                    p.setTrigSource(.channel);
                    if (p.rowAt(self.pointer_fy)) |row| p.trig_row = @intCast(row);
                } else p.setTrigSource(.ttl);
            },
            .t => p.mode = if (p.mode == .triggered) .scroll else .triggered,
            else => if (p.mode == .triggered and p.trig_source == .ttl and @intFromEnum(k) >= '1' and @intFromEnum(k) <= '8') {
                p.trig_line = @intCast(@intFromEnum(k) - '0');
            },
        };
        // A click on an electrode row listens to it (Ctrl: adds or removes it).
        if (in.clicks > 0 and p.kind == .electrode) {
            if (p.rowAt(self.pointer_fy)) |row| self.listenClick(p.first_ch + @as(u32, @intCast(row)), in.ctrl);
        }
        // A click on a row of a spike-triggered panel moves the trigger to that row.
        if (in.clicks > 0 and p.mode == .triggered and p.trig_source == .channel) {
            if (p.rowAt(self.pointer_fy)) |row| p.trig_row = @intCast(row);
        }
        p.clamp();
        return quit;
    }

    /// What to draw: each panel's traces, then dividers and a bar marking the target panel,
    /// and into `batch` the text: each panel's title (name, time base, scale per row), its
    /// row labels, and the status read-out in the bottom right corner.
    fn frame(self: *const Display, gpu: *const Gpu, layout: *const oez.types.Layout, newest: i64, review: ?ReviewView, status: Status, notes: *const notes_mod.Notes, batch: *font.Batch, draws: *[max_draws]gpu_mod.PanelDraw, fills: *[max_fills]gpu_mod.Fill) struct { draws: []const gpu_mod.PanelDraw, fills: []const gpu_mod.Fill, text: []const font.Vertex } {
        const width = gpu.extent.width;
        const height = gpu.extent.height;
        const nch = gpu.nch;
        const fs = layout.sample_rate;
        var nf: usize = 0;
        var nd: usize = 0;
        batch.clear();
        const line_h = @round(batch.font.line_height);
        const bright: font.Colour = .{ 225, 230, 240, 255 };
        const dim: font.Colour = .{ 150, 160, 178, 255 };
        for (self.set.items[0..self.set.len], 0..) |*p, i| {
            const r = p.pixelRect(width, height);
            // Sweep: a whole number of samples per pass, so the picture stands still.
            const span: f64 = if (p.mode == .sweep) @max(1, @round(p.span_s * fs)) else p.span_s * fs;
            // In review a panel shows a fixed stretch that ends at the review position
            // (triggered panels stay live: their sweeps are about now).
            const in_review = review != null and p.mode != .triggered;
            const t_end: i64 = if (in_review) review.?.end else newest;
            const sweeping = p.mode == .sweep and !in_review;
            const phase: f64 = if (sweeping) @floatFromInt(@mod(t_end, @as(i64, @intFromFloat(span)))) else -1;
            const px: f32 = @floatFromInt(r.x);
            const py: f32 = @floatFromInt(r.y);
            const shown = p.shownRows();
            var params: gpu_mod.TraceParams = .{
                .nch = @intCast(nch),
                .cap_mask = @intCast(gpu.hist_cap - 1),
                .newest = @truncate(@as(u64, @bitCast(t_end))),
                .first_ch = p.drawColumn(),
                .cols = r.w,
                .rows = shown,
                .span = @floatCast(span),
                .lsb_per_row = @floatCast(p.scale / p.unitsPerLsb()),
                .half_px = 1.5 / @as(f32, @floatFromInt(r.h)),
                .phase = @floatCast(phase),
                .gain_base = @intCast(i * gpu_mod.max_rows),
            };
            // The rows' own scales, for the shader, in the order the rows are drawn.
            if (gpu.row_gains.len >= (i + 1) * gpu_mod.max_rows) {
                const gains = gpu.row_gains[i * gpu_mod.max_rows ..][0..gpu_mod.max_rows];
                for (0..@min(shown, gpu_mod.max_rows)) |k| gains[k] = p.row_gain[p.rowOfShown(k) orelse k];
            }
            const rect: gpu_mod.PixelRect = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
            var shown_sweeps: usize = 0;
            if (p.mode == .triggered) {
                // One draw per sweep, oldest first and dimmest, the newest on top.
                const trig = &self.triggers[i];
                const pre: i64 = @intFromFloat(@round(p.pre_ms * 1e-3 * fs));
                const post: i64 = @max(1, @as(i64, @intFromFloat(@round(p.post_ms * 1e-3 * fs))));
                const window: f64 = @floatFromInt(pre + post);
                // Sweeps whose samples the history may no longer hold are left out.
                const keep: i64 = @as(i64, @intCast(gpu.hist_cap)) - @as(i64, @intFromFloat(fs));
                var k: usize = @min(p.overlay, trig.len);
                while (k > 0) {
                    k -= 1;
                    const s = trig.recent(k).?;
                    if (newest - (s.t0 - pre) > keep) continue;
                    const end = s.t0 + post;
                    const future: f64 = @floatFromInt(@max(0, end - newest));
                    if (window - future < 2 * window / @as(f64, @floatFromInt(r.w)) + 2) continue;
                    params.newest = @truncate(@as(u64, @bitCast(end)));
                    params.span = @floatCast(window);
                    params.phase = -1;
                    params.future = @floatCast(future);
                    params.gain = if (k == 0) 1.0 else 0.6 - 0.4 * @as(f32, @floatFromInt(k - 1)) / @as(f32, @floatFromInt(@max(1, p.overlay -| 2)));
                    if (nd < draws.len) {
                        draws[nd] = .{ .rect = rect, .params = params };
                        nd += 1;
                        shown_sweeps += 1;
                    }
                }
                // Over the traces: when the trigger line was high in the newest sweep
                // (the laser), and a line at the trigger.
                const w: f32 = @floatFromInt(r.w);
                const x0 = px + w * @as(f32, @floatFromInt(pre)) / @as(f32, @floatCast(window));
                if (p.trig_source == .channel) {
                    // The level, as a line across the trigger's row (in the row's own
                    // scale: it sits on the trace when the panel shows the spike band).
                    const row_h = @as(f32, @floatFromInt(r.h)) / @as(f32, @floatFromInt(@max(shown, 1)));
                    const centre = py + (@as(f32, @floatFromInt(p.shownIndex(p.trig_row) orelse 0)) + 0.5) * row_h;
                    const dy: f32 = @floatCast(std.math.clamp(p.trig_level_now_uv / p.rowScale(p.trig_row), -1.5, 1.5));
                    var x = px;
                    if (p.shownIndex(p.trig_row) != null) while (x < px + w) : (x += 12) batch.rect(x, @round(centre - dy * row_h), 6, 1, .{ 255, 205, 120, 200 });
                } else if (trig.recent(0)) |s| {
                    const until = @min(s.fall orelse newest, s.t0 + post);
                    const x1 = px + w * @as(f32, @floatFromInt(until - s.t0 + pre)) / @as(f32, @floatCast(window));
                    if (shown_sweeps > 0 and x1 > x0) batch.rect(x0, py, x1 - x0, @floatFromInt(r.h), .{ 90, 150, 255, 34 });
                }
                batch.rect(@round(x0), py, 1, @floatFromInt(r.h), .{ 200, 210, 230, 150 });
            } else if (nd < draws.len and !(in_review and !review.?.ready)) {
                draws[nd] = .{ .rect = rect, .params = params, .review = in_review and review.?.from_file };
                nd += 1;
            }
            if (p.mode != .triggered and span >= 1) {
                // Notes: a line where each was stamped, with its text beside it.
                const w: f64 = @floatFromInt(r.w);
                const span_i: i64 = @intFromFloat(span);
                const pass_start: i64 = if (sweeping) t_end - @as(i64, @intFromFloat(phase)) else t_end - span_i;
                var k: usize = 0;
                while (notes.recentNote(k)) |note| : (k += 1) {
                    const at = note.sample;
                    if (at < pass_start - span_i) break;
                    // This pass (or, scrolling, the window); else the previous pass, where
                    // the cursor has not yet gone over it.
                    const from: i64 = if (at >= pass_start) pass_start else if (sweeping and at >= pass_start - span_i + (t_end - pass_start)) pass_start - span_i else continue;
                    if (at > t_end) continue;
                    const x = px + @as(f32, @floatCast(w * @as(f64, @floatFromInt(at - from)) / span));
                    batch.rect(@round(x), py, 1, @floatFromInt(r.h), .{ 255, 205, 120, 190 });
                    if (line_h > 0 and x + 60 < px + @as(f32, @floatCast(w))) _ = batch.label(x + 5, py + line_h + 12, note.text()[0..@min(note.len, 40)], .{ 255, 225, 150, 255 });
                }
            }
            if (p.tint_line != 0 and p.mode != .triggered and span >= 1) {
                // A tint over the panel wherever its tint line was high. Scrolling: time
                // runs to the newest sample at the right edge. Sweep: this pass left of the cursor,
                // the previous pass right of it.
                const pulses = &self.pulses[i];
                const w: f64 = @floatFromInt(r.w);
                const tint: font.Colour = .{ 90, 150, 255, 30 };
                const span_i: i64 = @intFromFloat(span);
                const pass_start: i64 = if (sweeping) t_end - @as(i64, @intFromFloat(phase)) else t_end - span_i;
                var k: usize = 0;
                while (pulses.recent(k)) |pulse| : (k += 1) {
                    const t0 = pulse.t0;
                    const t1 = pulse.fall orelse t_end;
                    if (t1 < t_end - 2 * span_i) break;
                    // The stretch of the pulse in this pass (or, scrolling, in the window).
                    const a0 = @max(t0, pass_start);
                    const a1 = @min(t1, t_end);
                    if (a1 > a0) batch.rect(px + @as(f32, @floatCast(w * @as(f64, @floatFromInt(a0 - pass_start)) / span)), py, @floatCast(@max(1.0, w * @as(f64, @floatFromInt(a1 - a0)) / span)), @floatFromInt(r.h), tint);
                    if (p.mode != .sweep) continue;
                    // And in the previous pass, as far as the cursor has not overwritten it.
                    const prev = pass_start - span_i;
                    const b0 = @max(t0, prev + (t_end - pass_start));
                    const b1 = @min(t1, pass_start);
                    if (b1 > b0) batch.rect(px + @as(f32, @floatCast(w * @as(f64, @floatFromInt(b0 - prev)) / span)), py, @floatCast(@max(1.0, w * @as(f64, @floatFromInt(b1 - b0)) / span)), @floatFromInt(r.h), tint);
                }
            }
            if (sweeping) {
                // The cursor: a line where the newest sample is, and a blank stretch ahead.
                const cx: u32 = @min(r.w - 1, @as(u32, @intFromFloat(phase / span * @as(f64, @floatFromInt(r.w)))));
                fills[nf] = .{ .rect = .{ .x = r.x + cx, .y = r.y, .w = @min(10, r.w - cx), .h = r.h }, .colour = .{ 0.04, 0.045, 0.055, 1.0 } };
                fills[nf + 1] = .{ .rect = .{ .x = r.x + cx, .y = r.y, .w = 1, .h = r.h }, .colour = .{ 0.45, 0.48, 0.55, 1.0 } };
                nf += 2;
            }
            // A line along the left and top edges that are not the display's own.
            const grey: [4]f32 = .{ 0.22, 0.24, 0.28, 1.0 };
            if (r.x > 0) {
                fills[nf] = .{ .rect = .{ .x = r.x, .y = r.y, .w = 1, .h = r.h }, .colour = grey };
                nf += 1;
            }
            if (r.y > 0) {
                fills[nf] = .{ .rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = 1 }, .colour = grey };
                nf += 1;
            }
            if (line_h <= 0) continue;
            // Title, top left.
            const title_y = py + 6;
            var span_buf: [24]u8 = undefined;
            var scale_buf: [24]u8 = undefined;
            var title_buf: [128]u8 = undefined;
            var band_buf: [48]u8 = undefined;
            var trig_buf: [48]u8 = undefined;
            const title = if (p.mode == .triggered)
                std.fmt.bufPrint(&title_buf, "{s}   {s}   -{d:.1}/+{d:.1} ms   {s}/row{s}   {d} sweeps{s}", .{ p.name(), trigText(&trig_buf, p), p.pre_ms, p.post_ms, fmtScale(&scale_buf, p), fmtBand(&band_buf, p), shown_sweeps, if (shown_sweeps == 0) " (waiting for a trigger)" else "" }) catch ""
            else
if (p.kind == .ttl)
                std.fmt.bufPrint(&title_buf, "{s}   {s}{s}", .{ p.name(), fmtSpan(&span_buf, p.span_s), if (in_review) "   review" else if (p.mode == .sweep) "   sweep" else "" }) catch ""
            else
                std.fmt.bufPrint(&title_buf, "{s}   {s}   {s}/row{s}{s}", .{ p.name(), fmtSpan(&span_buf, p.span_s), fmtScale(&scale_buf, p), fmtBand(&band_buf, p), if (in_review) "   review" else if (p.mode == .sweep) "   sweep" else "" }) catch "";
            // A lane strip is short: its title goes to the right, clear of the lane labels.
            _ = batch.label(if (p.kind == .ttl) px + @as(f32, @floatFromInt(r.w)) - batch.font.width(title) - 8 else px + 8, title_y, title, bright);
            if (p.mode == .triggered) {
                // The time axis along the bottom: the ends of the window and the trigger.
                const bottom = py + @as(f32, @floatFromInt(r.h)) - line_h - 4;
                const w: f32 = @floatFromInt(r.w);
                var t_buf: [24]u8 = undefined;
                const right = std.fmt.bufPrint(&t_buf, "+{d:.1} ms", .{p.post_ms}) catch "";
                _ = batch.label(px + w - batch.font.width(right) - 8, bottom, right, dim);
                if (p.pre_ms > 0) {
                    _ = batch.label(px + w * @as(f32, @floatCast(p.pre_ms / (p.pre_ms + p.post_ms))) + 4, bottom, "0", dim);
                    var l_buf: [24]u8 = undefined;
                    const left = std.fmt.bufPrint(&l_buf, "-{d:.1} ms", .{p.pre_ms}) catch "";
                    // Only where it fits between the row labels and the trigger line.
                    if (px + 48 + batch.font.width(left) + 8 < px + w * @as(f32, @floatCast(p.pre_ms / (p.pre_ms + p.post_ms)))) _ = batch.label(px + 48, bottom, left, dim);
                }
            }
            // Row labels down the left edge, thinned when rows are shorter than a line.
            if (shown == 0) continue;
            const row_h = @as(f32, @floatFromInt(r.h)) / @as(f32, @floatFromInt(shown));
            const step: u32 = @max(1, @as(u32, @intFromFloat(@ceil((line_h + 3) / row_h))));
            var k: u32 = 0;
            while (k < shown) : (k += step) {
                // The `k`-th row drawn is panel row `row` (hidden rows are left out).
                const row: u32 = @intCast(p.rowOfShown(k) orelse continue);
                const y = py + (@as(f32, @floatFromInt(k)) + 0.5) * row_h - 0.5 * line_h;
                if (p.kind != .ttl and y < title_y + line_h + 3) continue;
                var label_buf: [16]u8 = undefined;
                // The rows listened to stand out.
                const heard = p.kind == .electrode and self.audio.enabled and self.listening(p.first_ch + row);
                var after = batch.label(px + 5, y, rowLabel(&label_buf, p, row, layout, &self.set), if (heard) .{ 255, 225, 120, 255 } else dim);
                // In a filtered panel, the rows shown as they are say so.
                if (p.filtered and p.kind == .electrode and !p.rowFiltered(row)) after = batch.label(after + 4, y, "raw", dim);
                // A row with a scale of its own says so.
                if (row < panels_mod.max_rows and p.row_gain[row] != 1) {
                    var own: Panel = p.*;
                    own.scale = p.rowScale(row);
                    var own_buf: [24]u8 = undefined;
                    _ = batch.label(after + 4, y, fmtScale(&own_buf, &own), .{ 255, 205, 120, 255 });
                }
            }
        }
        if (line_h > 0 and (status.alarm_len > 0 or status.warning_len > 0)) {
            // Samples are being lost, or the recording has failed: a bar across the whole
            // display that stays until it is acknowledged. A warning (the disk falling
            // behind) is amber and goes when its cause does.
            const is_alarm = status.alarm_len > 0;
            const text = if (is_alarm) status.alarm() else status.warning();
            const bar_h = 2 * line_h + 14;
            const bar_y = if (review != null) line_h + 18 else 0;
            batch.rect(0, bar_y, @floatFromInt(width), bar_h, if (is_alarm) .{ 190, 25, 25, 245 } else .{ 150, 100, 10, 235 });
            const tw = batch.font.width(text);
            _ = batch.text((@as(f32, @floatFromInt(width)) - tw) / 2, bar_y + 5, text, .{ 255, 255, 255, 255 });
            if (is_alarm) {
                const hint = "press a to acknowledge";
                _ = batch.text((@as(f32, @floatFromInt(width)) - batch.font.width(hint)) / 2, bar_y + line_h + 7, hint, .{ 255, 210, 210, 255 });
            }
        }
        if (review) |v| {
            if (line_h > 0) {
                // Unmistakable: this is not what the electrodes see now.
                var buf: [120]u8 = undefined;
                var clock_buf: [16]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "REVIEW   {d:.1} s behind live   at {s}{s}   End = live", .{ v.behind_s, control.fmtClock(&clock_buf, @as(f64, @floatFromInt(v.end)) / layout.sample_rate), if (v.ready) "" else "   (reading)" }) catch "REVIEW";
                const tw = batch.font.width(text);
                const x = (@as(f32, @floatFromInt(width)) - tw) / 2;
                batch.rect(x - 10, 4, tw + 20, line_h + 10, .{ 150, 90, 10, 235 });
                _ = batch.text(x, 9, text, .{ 255, 240, 200, 255 });
            }
        }
        if (notes.editing and line_h > 0) {
            // The note being typed, bottom left, with when it is stamped.
            var buf: [notes_mod.max_text + 64]u8 = undefined;
            var clock_buf: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "note at {s}:  {s}_", .{ control.fmtClock(&clock_buf, @as(f64, @floatFromInt(notes.draft.sample)) / layout.sample_rate), notes.draft.text() }) catch "note";
            _ = batch.label(10, @as(f32, @floatFromInt(height)) - 2 * line_h - 14, text, .{ 255, 235, 170, 255 });
        }
        if (status.valid and line_h > 0) {
            var buf: [96]u8 = undefined;
            const text = (if (status.lost > 0)
                std.fmt.bufPrint(&buf, "{d:.1} ms   {d} fps   display skipped {d} blocks", .{ status.latency_ms, status.fps, status.lost })
            else
                std.fmt.bufPrint(&buf, "{d:.1} ms   {d} fps", .{ status.latency_ms, status.fps })) catch "";
            const w = batch.font.width(text);
            const x = @as(f32, @floatFromInt(width)) - w - 8;
            const y = @as(f32, @floatFromInt(height)) - line_h - 6;
            _ = batch.label(x, y, text, if (status.lost > 0) .{ 255, 190, 90, 255 } else dim);
            if (status.recording) {
                var clock_buf: [16]u8 = undefined;
                var rec_buf: [32]u8 = undefined;
                const rec_text = std.fmt.bufPrint(&rec_buf, "REC {s}", .{control.fmtClock(&clock_buf, status.rec_seconds)}) catch "REC";
                _ = batch.label(x - batch.font.width(rec_text) - 14, y, rec_text, .{ 255, 96, 96, 255 });
            }
        }
        if (self.set.len > 1) {
            const r = self.set.items[self.target].pixelRect(width, height);
            fills[nf] = .{ .rect = .{ .x = r.x, .y = r.y, .w = r.w, .h = 3 }, .colour = .{ 0.30, 0.55, 0.95, 1.0 } };
            nf += 1;
        }
        return .{ .draws = draws[0..nd], .fills = fills[0..nf], .text = batch.vertices[0..batch.len] };
    }
};

/// The panels for this run: from the config, or one per headstage.
fn makeDisplay(args: Args, layout: *const oez.types.Layout) ?Display {
    var set = panels_mod.fromConfig(args.doc, layout) catch {
        log.err("config: {s}", .{panels_mod.error_message});
        return null;
    };
    const applied = panels_mod.applyViews(&set, args.views_doc) catch blk: {
        log.warn("view file: {s}; the rest of it is ignored", .{panels_mod.error_message});
        break :blk 0;
    };
    if (applied > 0) log.info("view file: settings for {d} panels", .{applied});
    if (args.sweep) for (set.slice()) |*p| {
        p.mode = .sweep;
        p.clamp();
    };
    for (set.items[0..set.len], 0..) |*p, i| log.info("panel {d} \"{s}\": {d} {t} channels from channel {d}, {d:.2} s, {d} {s}/row", .{ i + 1, p.name(), p.rows, p.kind, p.first_ch + 1, p.span_s, p.scale, p.unit() });
    return .init(set);
}

/// Blocks in the acquisition ring: 30 s of signal, which is how far the recorder may fall
/// behind (a stalled disk) before samples are lost. The display holds nothing back.
fn ringSlots(fs: f64, block_samples: usize) usize {
    // OEZ_TEST_RING_SECONDS shortens it, for testing what happens when it fills.
    const seconds: f64 = if (std.c.getenv("OEZ_TEST_RING_SECONDS")) |v| (std.fmt.parseFloat(f64, std.mem.span(v)) catch 30.0) else 30.0;
    return @intFromFloat(@ceil(seconds * fs / @as(f64, @floatFromInt(block_samples))));
}

/// The panels' settings as the text of a view file, in `buf`; null if it does not fit.
fn renderViews(buf: []u8, set: *const panels_mod.Set) ?[]const u8 {
    var w: Io.Writer = .fixed(buf);
    panels_mod.renderViews(&w, set) catch return null;
    return w.buffered();
}

/// Writes `text` to the file at `path`: beside it under a temporary name, synced, then
/// renamed over it, so the file is never seen half written.
fn writeAtomic(io: Io, path: []const u8, text: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    const name = std.fs.path.basename(path);
    try Io.Dir.cwd().createDirPath(io, dir_path);
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    var tmp_buf: [80]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, ".{s}.tmp", .{name});
    var f = try dir.createFile(io, tmp, .{});
    {
        errdefer f.close(io);
        try f.writeStreamingAll(io, text);
        try f.sync(io);
    }
    f.close(io);
    try Io.Dir.rename(dir, tmp, dir, name, io);
}

/// Gives a stopped source new settings.
fn applyToSource(source: oez.source.Source, settings: oez.types.Settings) !void {
    switch (source) {
        .board => |b| try b.applySettings(settings),
        .sim => |s| try s.applySettings(settings),
    }
}

/// Writes `settings` into the config file's [board] table, leaving the rest of the file
/// as it is (a new file if there is none). Written beside the file and renamed over it.
fn saveBoard(io: Io, gpa: std.mem.Allocator, config_path: []const u8, settings: *const oez.types.Settings) !void {
    const dir_path = std.fs.path.dirname(config_path) orelse ".";
    const name = std.fs.path.basename(config_path);
    try Io.Dir.cwd().createDirPath(io, dir_path);
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    const old: []const u8 = dir.readFileAlloc(io, name, gpa, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => try gpa.dupe(u8, ""),
        else => return e,
    };
    defer gpa.free(old);
    var table_buf: [512]u8 = undefined;
    const new = try oez.board_config.replaceTable(gpa, old, oez.board_config.render(&table_buf, settings));
    defer gpa.free(new);
    var tmp_buf: [80]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, ".{s}.tmp", .{name});
    var f = try dir.createFile(io, tmp, .{});
    {
        errdefer f.close(io);
        try f.writeStreamingAll(io, new);
        try f.sync(io);
    }
    f.close(io);
    try Io.Dir.rename(dir, tmp, dir, name, io);
}

/// Text for the display: the font from the config, its atlas on the GPU, and the batch that
/// each frame's quads go into. Without a usable font the display runs without text.
const Text = struct {
    font: font.Font = .{ .atlas = &.{}, .px = 0 },
    vertices: []font.Vertex = &.{},

    fn init(self: *Text, gpa: std.mem.Allocator, gpu: *Gpu, args: Args) void {
        var name_buf: [128]u8 = undefined;
        const family = std.fmt.bufPrintSentinel(&name_buf, "{s}", .{args.font}, 0) catch "sans-serif";
        const f = font.Font.init(gpa, family, args.font_px) catch |e| {
            log.warn("no font '{s}' ({t}): the display has no text", .{ args.font, e });
            return;
        };
        self.font = f;
        const vertices = gpa.alloc(font.Vertex, max_text_vertices) catch return;
        gpu.createText(f.atlas, font.atlas_size, max_text_vertices) catch |e| {
            log.warn("text setup failed ({t}): the display has no text", .{e});
            gpa.free(vertices);
            return;
        };
        self.vertices = vertices;
    }

    fn deinit(self: *Text, gpa: std.mem.Allocator) void {
        gpa.free(self.vertices);
        if (self.font.atlas.len > 0) self.font.deinit(gpa);
    }

    fn batch(self: *const Text) font.Batch {
        return .{ .font = &self.font, .vertices = self.vertices };
    }
};

/// The display loop when oez drives the monitor itself (--direct). One frame is in flight at
/// a time: draw `margin` before a refresh, wait until that frame is on screen, repeat. The
/// time a frame reached the screen comes from vkWaitForPresentKHR.
fn runDirect(io: Io, gpa: std.mem.Allocator, args: Args, layout: oez.types.Layout, acq: *oez.acquisition.Acquisition, reader: *oez.ring.LossyReader, blk: *oez.types.Block) !u8 {
    const fs = layout.sample_rate;
    var gpu = Gpu.init(gpa, .{ .direct = args.direct }, .fifo, null) catch |e| {
        log.err("direct display on {s} failed: {t}", .{ args.direct, e });
        return 1;
    };
    defer gpu.deinit();
    gpu.wait_render = true;
    var notes = notes_mod.Notes.init(args.doc);
    defer notes.deinit();
    var display = makeDisplay(args, &layout) orelse return 2;
    const history_samples: usize = @intFromFloat((Panel.span_max + 2.0) * fs);
    var feed = try oez.feed.Feed.init(gpa, &layout, &display.set, history_samples);
    defer feed.deinit(gpa);
    display.initial = display.set;
    try gpu.createHistory(feed.width, history_samples);
    try gpu.resize(0, 0);
    const period: i128 = gpu.refresh_period_ns;
    const margin_ms: f64 = if (args.margin_ms >= 0) args.margin_ms else 1.5;
    const margin: i128 = @intFromFloat(margin_ms * 1e6);
    log.info("{d}x{d}, refresh {d:.3} ms, drawing {d:.2} ms before each refresh", .{ gpu.extent.width, gpu.extent.height, @as(f64, @floatFromInt(period)) / 1e6, margin_ms });

    try acq.start();
    defer acq.join();

    var draws: [max_draws]gpu_mod.PanelDraw = undefined;
    var fills: [max_fills]gpu_mod.Fill = undefined;
    var text: Text = .{};
    text.init(gpa, &gpu, args);
    defer text.deinit(gpa);
    var batch = text.batch();
    var status: Status = .{};
    var newest: i64 = 0;
    var newest_acquired_ns: i128 = 0;
    var in_flight: u64 = 0; // present id awaited, 0 = none
    var in_flight_acquired: i128 = 0;
    var in_flight_since: i128 = 0;
    var draw_at: i128 = 0;
    var last_flip: i128 = 0;
    var script_pos: usize = 0;

    const t_start = nowNs(io);
    var next_report: i128 = t_start + std.time.ns_per_s;
    var frames: u64 = 0;
    var lat_sum: f64 = 0;
    var lat_min: f64 = std.math.inf(f64);
    var lat_max: f64 = 0;
    var missed: u64 = 0; // refreshes that passed without a new frame
    var render_sum: f64 = 0; // GPU time per frame, ms
    var render_max: f64 = 0;
    var worst_render: f64 = 0;
    var total_frames: u64 = 0;
    var total_missed: u64 = 0;
    var total_lat: f64 = 0;
    var worst: f64 = 0;

    while (!acq.done.load(.acquire)) {
        while (reader.next(blk)) {
            if (blk.len == 0) continue;
            gpu.writeSamples(blk.first_sample, try feed.rows(gpa, blk.first_sample, blk.samples(), blk.ttl[0..blk.len]));
            display.feedBlock(blk.first_sample, blk.samples(), layout.numChannels(), fs, blk.ttl[0..blk.len]);
            newest = blk.first_sample + @as(i64, @intCast(blk.len));
            newest_acquired_ns = blk.acquired_ns;
        }
        var input: Input = .{};
        if (args.script.len > 0) runScript(args.script, &script_pos, @as(f64, @floatFromInt(nowNs(io) - t_start)) / 1e9, &input, &display);
        if (display.applyInput(input)) break;
        // A panel's corners changed: filter its recent past again.
        if (gpu.hist_cap > 0) _ = try feed.sync(gpa, &display.set, refilterSamples(&display.set, fs), gpu.hist, gpu.hist_cap);

        var now = nowNs(io);
        if (in_flight != 0) {
            // Blocks for up to 1 ms, which also paces this loop.
            if (try gpu.waitPresented(in_flight, std.time.ns_per_ms)) {
                now = nowNs(io);
                const ms = @as(f64, @floatFromInt(now - in_flight_acquired)) / 1e6;
                lat_sum += ms;
                lat_min = @min(lat_min, ms);
                lat_max = @max(lat_max, ms);
                frames += 1;
                if (last_flip != 0 and now - last_flip > period + @divTrunc(period, 2)) missed += @intCast(@divTrunc(now - last_flip + @divTrunc(period, 2), period) - 1);
                last_flip = now;
                // Finished (not just started) `margin` before the next refresh.
                draw_at = now + period - margin - gpu.renderEstimateNs();
                in_flight = 0;
            } else if (now - in_flight_since > 2 * std.time.ns_per_s) {
                log.err("a frame was not shown within 2 s; giving up", .{});
                return 1;
            }
        } else if (newest > 0 and now >= draw_at) {
            const fr = display.frame(&gpu, &layout, newest, null, status, &notes, &batch, &draws, &fills);
            const result = try gpu.draw(fr.draws, fr.fills, fr.text, {}, struct {
                fn f(_: void) void {}
            }.f);
            switch (result) {
                .presented => {
                    in_flight = gpu.present_id;
                    in_flight_acquired = newest_acquired_ns;
                    in_flight_since = now;
                    const r = @as(f64, @floatFromInt(gpu.last_render_ns)) / 1e6;
                    render_sum += r;
                    render_max = @max(render_max, r);
                },
                .out_of_date => try gpu.resize(0, 0),
                .busy => {},
            }
        } else {
            const wait = std.math.clamp(draw_at - now, 0, std.time.ns_per_ms);
            if (wait > 0) io.sleep(.fromNanoseconds(@intCast(wait)), .awake) catch {};
        }

        if (now >= next_report) {
            const secs = @as(f64, @floatFromInt(now - t_start)) / 1e9;
            log.info("t={d:.0}s {d} fps, latency ms avg {d:.2} min {d:.2} max {d:.2}, refreshes without a new frame {d}, GPU ms per frame avg {d:.2} max {d:.2}, display lost {d} blocks, ring overflow {d}", .{
                secs, frames, if (frames > 0) lat_sum / @as(f64, @floatFromInt(frames)) else 0, if (frames > 0) lat_min else 0, lat_max, missed, if (frames > 0) render_sum / @as(f64, @floatFromInt(frames)) else 0, render_max, reader.lost, acq.ring_overflow.load(.monotonic),
            });
            status = .{ .valid = frames > 0, .latency_ms = if (frames > 0) lat_sum / @as(f64, @floatFromInt(frames)) else 0, .fps = frames, .lost = reader.lost };
            if (secs > 1.5) worst_render = @max(worst_render, render_max);
            render_sum = 0;
            render_max = 0;
            if (secs > 1.5) {
                total_frames += frames;
                total_missed += missed;
                total_lat += lat_sum;
                worst = @max(worst, lat_max);
            }
            frames = 0;
            lat_sum = 0;
            lat_min = std.math.inf(f64);
            lat_max = 0;
            missed = 0;
            next_report += std.time.ns_per_s;
        }
        if (args.seconds > 0 and @as(f64, @floatFromInt(now - t_start)) >= args.seconds * 1e9) break;
    }
    if (total_frames > 0) log.info("direct on {s}, margin {d:.2} ms: {d} frames, latency avg {d:.2} ms, worst {d:.2} ms, refreshes without a new frame {d}, slowest GPU frame {d:.2} ms", .{ args.direct, margin_ms, total_frames, total_lat / @as(f64, @floatFromInt(total_frames)), worst, total_missed, worst_render });
    if (acq.done.load(.acquire)) {
        log.err("acquisition ended early: {t}", .{acq.failure orelse error.Unknown});
        return 1;
    }
    return 0;
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
    var alarm_seen: struct { overflow: u64 = 0, dropped: u64 = 0, gaps: u64 = 0 } = .{};
    var rec_failed_alarm = false;
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
    var record_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const record_dir: []const u8 = if (std.mem.startsWith(u8, args.record_dir, "~/"))
        (std.fmt.bufPrint(&record_dir_buf, "{s}/{s}", .{ if (std.c.getenv("HOME")) |h| std.mem.span(h) else ".", args.record_dir[2..] }) catch args.record_dir)
    else
        args.record_dir;
    var rec: ?*oez.record.Recorder = null;
    var rec_start_ns: i128 = 0;
    var rec_published_ns: i128 = 0;
    var rec_status: control.RecStatus = .{};
    // The panels' settings as a view file: as they are now, and as last saved (at launch:
    // as loaded), to tell whether there is something to save.
    const view_now = try gpa.alloc(u8, 96 * 1024);
    defer gpa.free(view_now);
    const view_saved = try gpa.alloc(u8, 96 * 1024);
    defer gpa.free(view_saved);
    var view_saved_len: usize = 0;
    if (renderViews(view_saved, &display.set)) |rendered| view_saved_len = rendered.len;
    // Scroll-back review (see review.zig): where the display is looking when it is not
    // looking at now. From the recording's file while there is one; else a freeze of the
    // last seconds the live history still holds.
    var rv: ?oez.review.Review = null;
    defer if (rv) |*r| r.deinit();
    var reviewing = false;
    var review_from_file = false;
    var review_ready = false;
    // The right edge asked for, and the one drawn (the last the history was ready for).
    var view_end: i64 = 0;
    var shown_end: i64 = 0;
    var review_first: i64 = 0;
    var review_file_end: i64 = 0;
    var review_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var review_dir_len: usize = 0;
    var review_cmds: [16]control.ReviewAction = undefined;
    // Notes on their way into the recording (display thread to recorder thread).
    var note_queue: oez.events.EventQueue = .{};
    var board_status: control.BoardStatus = .{};
    // Board settings: what the config (and command line) gave at launch, to tell whether
    // they were changed; and the rate and channel choices waiting for a restart.
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

    var saved_settings = acq.requested;
    var pending = acq.requested;
    var restart_asked = false;
    var quit_prompt: control.QuitPrompt = .{};
    {
        const n = @min(config_path.len, quit_prompt.path_buf.len);
        @memcpy(quit_prompt.path_buf[0..n], config_path[0..n]);
        quit_prompt.path_len = n;
    }
    // However the loop ends, a recording in progress is closed properly.
    defer if (rec) |r| {
        const sum = r.finish();
        if (sum.failure) |err| log.err("recording failed: {t}", .{err});
    };

    var newest: i64 = 0;
    var newest_acquired_ns: i128 = 0;
    // Acquisition time of the newest sample drawn in each frame, by frame tag.
    var frame_acquired: [64]i128 = @splat(0);
    // Per-frame timing, to explain frames that land late (logged with OEZ_FRAME_DEBUG=1).
    const FrameTiming = struct { wake_late_ms: f64 = 0, draw_ms: f64 = 0, before_refresh_ms: f64 = 0, callback_to_draw_ms: f64 = 0, target_ns: i128 = 0 };
    var frame_timing: [64]FrameTiming = @splat(.{});
    const frame_debug = std.c.getenv("OEZ_FRAME_DEBUG") != null;
    // OEZ_FRAME_DEBUG=2: one line per presented frame.
    const frame_trace = if (std.c.getenv("OEZ_FRAME_DEBUG")) |v| v[0] == '2' else false;
    var ready_seen_ns: i128 = 0;
    var target_refresh_ns: i128 = 0;
    var frame_tag: u64 = 0;
    // Frame pacing: the last presentation time and refresh period, the margin before the
    // next refresh at which to draw, and when the pending frame is due.
    var last_present_ns: i128 = 0;
    var margin_ms: f64 = if (args.margin_ms >= 0) args.margin_ms else 3.0;
    var draw_at: i128 = 0;
    var misses: u64 = 0;
    var misses_this_second: u32 = 0;
    // The best latency of the last seconds: what a frame that lands on time achieves.
    var best_ms: f64 = std.math.inf(f64);
    var best_age: u32 = 0;
    var clock_checked = false;
    // Recovery of immediate presentation (see the header): skip one frame when frames keep
    // landing a refresh after the one aimed at, and back off if that does not help.
    var skip_frame = false;
    var skips: u64 = 0;
    const skip_backoff_min: i128 = 250 * std.time.ns_per_ms;
    var skip_backoff_ns: i128 = skip_backoff_min;
    var last_skip_ns: i128 = 0;
    var late_run: u32 = 0; // consecutive frames presented a refresh after the one aimed at
    var good_run: u32 = 0;
    var on_time_frames: u64 = 0; // this second
    var late_frames_now: u64 = 0;
    var clean_seconds: u32 = 0;

    // Diagnostics only: time the GPU per frame (it delays presenting, see gpu.zig).
    gpu.wait_render = frame_debug;
    var render_sum: f64 = 0;
    var render_max: f64 = 0;
    var render_n: f64 = 0;
    var n_out_of_date: u64 = 0;
    var n_busy: u64 = 0;
    var n_resize: u64 = 0;
    var drawn_newest: i64 = 0;
    var last_draw_ns: i128 = 0;
    var script_pos: usize = 0;
    const t_start = nowNs(io);
    var next_report: i128 = t_start + std.time.ns_per_s;
    var frames: u64 = 0;
    var lat_sum: f64 = 0;
    var lat_min: f64 = std.math.inf(f64);
    var lat_max: f64 = 0;
    var lat_n: f64 = 0;
    var refresh_ns: u32 = 0;
    var title_buf: [160]u8 = undefined;

    while (!win.closed and !acq.done.load(.acquire)) {
        // Wake for events, for new samples (every 2 ms), or when the frame is due.
        const wait_ms: i32 = if (draw_at != 0) @intCast(std.math.clamp(@divFloor(draw_at - nowNs(io), std.time.ns_per_ms), 0, 2)) else 2;
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
        notes.handle(&input, note_stamp, if (rec != null) rec_status.path() else "");
        // Review keys (what is left of them after a note took its own).
        var num_review_cmds: usize = 0;
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
            if (num_review_cmds < review_cmds.len) {
                review_cmds[num_review_cmds] = cmd;
                num_review_cmds += 1;
            }
        }
        // Quitting (q or Esc here, Quit in the control window) asks first if the board
        // settings were changed; a second request quits.
        var quit = display.applyInput(input);
        var quit_answer: ?control.QuitAnswer = null;
        // What was clicked in the control window.
        while (shared.pop()) |e| {
            if (e.action == .quit_answer) quit_answer = e.action.quit_answer;
            if (e.action == .review and num_review_cmds < review_cmds.len) {
                review_cmds[num_review_cmds] = e.action.review;
                num_review_cmds += 1;
            }
            if (e.action == .save_view) {
                if (renderViews(view_now, &display.set)) |rendered| {
                    if (writeAtomic(io, views_path, rendered)) |_| {
                        @memcpy(view_saved[0..rendered.len], rendered);
                        view_saved_len = rendered.len;
                        board_status.setNote("view saved to {s}", .{views_path});
                    } else |err| board_status.setNote("could not save {s}: {t}", .{ views_path, err });
                } else board_status.setNote("the view is too large to save", .{});
            }
            if (e.action == .note_preset) notes.stampPreset(e.action.note_preset, note_stamp, if (rec != null) rec_status.path() else "");
            if (display.applyEdit(e)) quit = true;
            snap_dirty = true;
            if (e.action == .board) {
                // Headstage filters: applied without a gap, also while recording (the
                // change is then written to the recording's events).
                var want = acq.requested;
                const bc = oez.board_config;
                board_status.note_len = 0;
                switch (e.action.board) {
                    .dsp => |on| want.dsp_enabled = on,
                    .dsp_cutoff => |up| want.dsp_cutoff = bc.stepDsp(fs, want.dsp_cutoff, up),
                    .lower => |up| want.lower_bandwidth = bc.step(f64, &bc.lower_steps, want.lower_bandwidth, up),
                    .upper => |up| want.upper_bandwidth = bc.step(f64, &bc.upper_steps, want.upper_bandwidth, up),
                    .rate => |up| pending.sample_rate = bc.step(u32, &bc.sample_rates, pending.sample_rate, up),
                    .half => |slot| if (slot < pending.rhd2132_16ch.len) {
                        pending.rhd2132_16ch[slot] = !pending.rhd2132_16ch[slot];
                    },
                    .apply => restart_asked = true,
                    .save => if (saveBoard(io, gpa, config_path, &acq.requested)) |_| {
                        saved_settings = acq.requested;
                        board_status.setNote("saved to {s}", .{config_path});
                    } else |err| board_status.setNote("could not save to {s}: {t}", .{ config_path, err }),
                }
                if (want.lower_bandwidth >= want.upper_bandwidth) {
                    board_status.setNote("the band's lower edge must stay below its upper edge", .{});
                } else if (acq.applySettings(want, rec != null)) |_| {
                    // The live values carry over into what a restart will apply.
                    const rate = pending.sample_rate;
                    const half = pending.rhd2132_16ch;
                    pending = want;
                    pending.sample_rate = rate;
                    pending.rhd2132_16ch = half;
                } else |err| {
                    board_status.setNote("not applied: {t}", .{err});
                }
            }
            if (e.action == .record) {
                if (e.action.record and rec == null) {
                    // Review of an earlier recording ends where a new one begins.
                    reviewing = false;
                    // Changes applied before this recording are not its events.
                    while (acq.events.pop()) |_| {}
                    while (note_queue.pop()) |_| {}
                    if (oez.record.Recorder.create(gpa, io, &ring, record_dir, .{
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
                    })) |r| {
                        r.events_in = &acq.events;
                        r.notes_in = &note_queue;
                        // For testing the alarms: make the recorder fail or stall.
                        if (std.c.getenv("OEZ_TEST_RECORD_FAIL_AFTER")) |v| r.test_fail_after = std.fmt.parseInt(u64, std.mem.span(v), 10) catch null;
                        if (std.c.getenv("OEZ_TEST_RECORD_STALL")) |v| {
                            var it = std.mem.tokenizeScalar(u8, std.mem.span(v), ',');
                            r.test_stall_after = std.fmt.parseInt(u64, it.next() orelse "", 10) catch null;
                            r.test_stall_ms = std.fmt.parseInt(u32, it.next() orelse "", 10) catch 0;
                        }
                        alarm_seen.gaps = 0;
                        if (r.start()) |_| {
                            rec = r;
                            rec_start_ns = nowNs(io);
                            rec_status = .{ .state = .recording };
                            // The session folder is the parent of ephys/.
                            const session = std.fs.path.dirname(r.path) orelse r.path;
                            rec_status.path_len = @min(session.len, rec_status.path_buf.len);
                            @memcpy(rec_status.path_buf[0..rec_status.path_len], session[0..rec_status.path_len]);
                        } else |err| {
                            _ = r.finish();
                            rec_status.state = .failed;
                            rec_status.setNote("could not start the recorder: {t}", .{err});
                            rec_failed_alarm = true;
                        }
                    } else |err| {
                        rec_status.state = .failed;
                        rec_status.setNote("could not create a recording under {s}: {t}", .{ record_dir, err });
                        rec_failed_alarm = true;
                        log.err("could not create a recording under {s}: {t}", .{ record_dir, err });
                    }
                } else if (!e.action.record) {
                    if (rec) |r| {
                        if (rec_status.state == .recording) {
                            r.requestStop();
                            rec_status.state = .stopping;
                        }
                    }
                }
            }
        }
        // ---- scroll-back review ----
        {
            // The longest stretch a panel in review shows, and one step of the keys.
            var longest: i64 = 0;
            for (display.set.items[0..display.set.len]) |*p| {
                if (p.mode != .triggered) longest = @max(longest, @as(i64, @intFromFloat(@ceil(p.span_s * fs))) + 2);
            }
            if (longest == 0) longest = @intFromFloat(2 * fs);
            const tp = &display.set.items[display.target];
            const window: i64 = if (tp.mode != .triggered) @intFromFloat(tp.span_s * fs) else longest;
            for (review_cmds[0..num_review_cmds]) |cmd| {
                snap_dirty = true;
                if (cmd == .live or (cmd == .toggle and reviewing)) {
                    reviewing = false;
                    continue;
                }
                if (!reviewing) {
                    // Enter where the display is now. From the file if one is being written.
                    reviewing = true;
                    view_end = newest;
                    shown_end = newest;
                    review_ready = false;
                    review_from_file = false;
                    if (rec) |r| {
                        const first = r.first_sample_shared.load(.acquire);
                        if (first != std.math.minInt(i64)) from_file: {
                            if (rv == null) {
                                gpu.createReview() catch |err| {
                                    log.warn("no memory for the review history ({t}); review is limited to the last seconds", .{err});
                                    break :from_file;
                                };
                                rv = oez.review.Review.init(gpa, &layout, &display.set, gpu.rev, gpu.hist_cap) catch break :from_file;
                            }
                            if (!rv.?.isOpen() or !std.mem.eql(u8, review_dir_buf[0..review_dir_len], r.path)) {
                                rv.?.open(r.path, first) catch |err| {
                                    log.warn("review cannot read the recording ({t}); limited to the last seconds", .{err});
                                    break :from_file;
                                };
                                review_dir_len = @min(r.path.len, review_dir_buf.len);
                                @memcpy(review_dir_buf[0..review_dir_len], r.path[0..review_dir_len]);
                            }
                            review_first = first;
                            review_from_file = true;
                        }
                    }
                }
                switch (cmd) {
                    .back => view_end -= @max(1, @divTrunc(window, 10)),
                    .forward => view_end += @max(1, @divTrunc(window, 10)),
                    .page_back => view_end -= @max(1, @divTrunc(window * 9, 10)),
                    .page_forward => view_end += @max(1, @divTrunc(window * 9, 10)),
                    .start => view_end = std.math.minInt(i64) / 2,
                    .toggle, .live => {},
                }
            }
            if (reviewing and review_from_file) {
                const r = &rv.?;
                // The file grows while the recording runs.
                if (rec) |live_rec| review_file_end = review_first + @as(i64, @intCast(live_rec.stats.samples.load(.monotonic)));
                view_end = std.math.clamp(view_end, @min(review_first + longest, review_file_end), review_file_end);
                var ok = true;
                r.follow(&display.set) catch {
                    ok = false;
                };
                // A bounded amount per turn of the loop: a long jump fills over a few frames.
                const covered = if (ok) r.fill(view_end - longest, view_end, review_file_end, 30000) catch |err| blk: {
                    log.warn("review stopped: {t}", .{err});
                    ok = false;
                    break :blk false;
                } else false;
                if (!ok) {
                    reviewing = false;
                } else {
                    if (covered) shown_end = view_end;
                    review_ready = r.holds(shown_end - longest, shown_end, review_file_end);
                }
            } else if (reviewing) {
                // The live history: a freeze, for as long as the samples are still there.
                const oldest = newest - @as(i64, @intCast(gpu.hist_cap)) + @as(i64, @intFromFloat(fs));
                view_end = @min(view_end, newest);
                if (view_end - longest < oldest) view_end = oldest + longest;
                if (view_end >= newest and newest - oldest <= longest) reviewing = false;
                shown_end = view_end;
                review_ready = true;
            }
        }
        // Notes saved this turn go into the recording, if there is one.
        for (notes.fresh[0..notes.num_fresh]) |*note| {
            if (rec != null) _ = note_queue.push(.init(note.sample, "note", "{s}", .{note.text()}));
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
            if (quit_prompt.active) switch (answer) {
                .save => {
                    // Whichever of the two changed.
                    var failed = false;
                    var lines: [12][64]u8 = undefined;
                    var lens: [12]usize = undefined;
                    if (oez.board_config.diff(&saved_settings, &acq.requested, &lines, &lens) > 0) {
                        if (saveBoard(io, gpa, config_path, &acq.requested)) |_| {
                            log.info("board settings saved to {s}", .{config_path});
                        } else |err| {
                            board_status.setNote("could not save to {s}: {t}", .{ config_path, err });
                            failed = true;
                        }
                    }
                    if (renderViews(view_now, &display.set)) |rendered| {
                        if (!std.mem.eql(u8, rendered, view_saved[0..view_saved_len])) {
                            if (writeAtomic(io, views_path, rendered)) |_| {
                                log.info("view saved to {s}", .{views_path});
                            } else |err| {
                                board_status.setNote("could not save {s}: {t}", .{ views_path, err });
                                failed = true;
                            }
                        }
                    }
                    if (!failed) break;
                    quit_prompt.active = false;
                },
                .discard => break,
                .cancel => quit_prompt.active = false,
            };
            snap_dirty = true;
        }
        if (quit) {
            var changed = oez.board_config.diff(&saved_settings, &acq.requested, &quit_prompt.lines, &quit_prompt.lens);
            // And the panels' settings, as one line.
            if (renderViews(view_now, &display.set)) |rendered| {
                if (!std.mem.eql(u8, rendered, view_saved[0..view_saved_len]) and changed < quit_prompt.lines.len) {
                    const line: []const u8 = std.fmt.bufPrint(&quit_prompt.lines[changed], "panel views (saved to views.toml)", .{}) catch "";
                    quit_prompt.lens[changed] = line.len;
                    changed += 1;
                }
            }
            if (changed > 0 and !quit_prompt.active and control_thread != null and !shared.closed.load(.acquire)) {
                quit_prompt.active = true;
                quit_prompt.count = changed;
                snap_dirty = true;
            } else break;
        }
        // Sample rate or channel set: stop, reconfigure the board, and start again with
        // everything that depends on the shape of the data rebuilt.
        if (restart_asked) {
            restart_asked = false;
            snap_dirty = true;
            if (rec != null) {
                board_status.setNote("stop the recording first: this changes the shape of the data", .{});
            } else {
                // Review looks into a history that is about to be replaced.
                reviewing = false;
                if (rv) |*r| r.deinit();
                rv = null;
                review_dir_len = 0;
                // The tiles and the audio threads read the ring that is about to be replaced.
                if (tiles_win) |t| t.stop();
                tiles_win = null;
                if (audio_dev) |a| a.stop();
                audio_dev = null;
                acq.join();
                const before = source.settings();
                applyToSource(source, pending) catch |err| {
                    log.err("the board refused the new settings ({t}); going back", .{err});
                    board_status.setNote("the board refused the new settings: {t}", .{err});
                    pending = before;
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
                if (new_display.set.len == old_set.len) {
                    for (new_display.set.slice(), old_set.items[0..old_set.len]) |*p, *o| {
                        if (p.kind != o.kind) continue;
                        p.span_s = o.span_s;
                        p.scale = o.scale;
                        p.mode = o.mode;
                        p.filtered = o.filtered;
                        p.band_low_hz = o.band_low_hz;
                        p.band_high_hz = o.band_high_hz;
                        if (p.rows == o.rows) {
                            p.raw_rows = o.raw_rows;
                            p.hidden = o.hidden;
                            p.row_gain = o.row_gain;
                            p.car = o.car;
                            p.car_ref = o.car_ref;
                            p.car_sub = o.car_sub;
                        }
                        p.trig_line = o.trig_line;
                        p.trig_source = o.trig_source;
                        p.trig_row = @min(o.trig_row, p.rows -| 1);
                        p.trig_rising = o.trig_rising;
                        p.trig_auto = o.trig_auto;
                        p.trig_level_uv = o.trig_level_uv;
                        p.trig_holdoff_ms = o.trig_holdoff_ms;
                        p.other_pre_ms = o.other_pre_ms;
                        p.other_post_ms = o.other_post_ms;
                        p.pre_ms = o.pre_ms;
                        p.post_ms = o.post_ms;
                        p.overlay = o.overlay;
                    }
                }
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
                drawn_newest = 0;
                try acq.start();
                pending = acq.requested;
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
        // The recorder has finished (asked to, or because writing failed): close it.
        if (rec) |r| {
            if (r.done.load(.acquire)) {
                const sum = r.finish();
                rec = null;
                snap_dirty = true;
                rec_status.samples = sum.samples;
                rec_status.gaps = sum.gaps;
                if (sum.failure) |err| {
                    rec_status.state = .failed;
                    rec_status.setNote("recording failed: {t}; what was written before is intact", .{err});
                    rec_failed_alarm = true;
                } else {
                    rec_status.state = .idle;
                    var clock_buf: [16]u8 = undefined;
                    rec_status.setNote("last recording: {s}, {d} samples, {d} gaps", .{ control.fmtClock(&clock_buf, @as(f64, @floatFromInt(sum.samples)) / fs), sum.samples, sum.gaps });
                }
            }
        }
        // While recording, the control window's counts move four times a second.
        if ((rec != null or reviewing) and nowNs(io) - rec_published_ns > 250 * std.time.ns_per_ms) {
            rec_published_ns = nowNs(io);
            snap_dirty = true;
        }
        // ---- alarms: anything that means samples are not being kept ----
        {
            const overflow = acq.ring_overflow.load(.monotonic);
            const dropped = health.dropped_samples.load(.monotonic);
            const gaps: u64 = if (rec) |r| r.stats.gaps.load(.monotonic) else 0;
            if (display.acknowledged) {
                display.acknowledged = false;
                alarm_seen = .{ .overflow = overflow, .dropped = dropped, .gaps = gaps };
                rec_failed_alarm = false;
            }
            var w: Io.Writer = .fixed(&status.alarm_buf);
            if (rec_failed_alarm) w.writeAll("RECORDING FAILED: nothing is being recorded") catch {};
            if (overflow > alarm_seen.overflow) w.print("{s}{d} BLOCKS LOST: the disk fell 30 s behind", .{ if (w.buffered().len > 0) "   |   " else "", overflow - alarm_seen.overflow }) catch {};
            if (dropped > alarm_seen.dropped) w.print("{s}THE BOARD DROPPED {d} SAMPLES", .{ if (w.buffered().len > 0) "   |   " else "", dropped - alarm_seen.dropped }) catch {};
            if (gaps > alarm_seen.gaps) w.print("{s}THE RECORDING HAS {d} GAPS", .{ if (w.buffered().len > 0) "   |   " else "", gaps - alarm_seen.gaps }) catch {};
            const alarm_len = w.buffered().len;
            // Not yet lost, but on the way: the recorder is far behind acquisition.
            var ww: Io.Writer = .fixed(&status.warning_buf);
            if (rec) |r| {
                const behind = @as(f64, @floatFromInt(r.backlog() * bs)) / fs;
                if (behind > 5) ww.print("the disk is {d:.0} s behind (samples are lost at 30 s)", .{behind}) catch {};
            }
            if (alarm_len != status.alarm_len or ww.buffered().len != status.warning_len) snap_dirty = true;
            status.alarm_len = alarm_len;
            status.warning_len = ww.buffered().len;
            audio_shared.alarm.store(alarm_len > 0, .monotonic);
        }
        status.recording = rec != null;
        if (rec != null) status.rec_seconds = @as(f64, @floatFromInt(nowNs(io) - rec_start_ns)) / 1e9;
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
                .quit_prompt = quit_prompt,
                .review = .{
                    .active = reviewing,
                    .behind_s = @as(f64, @floatFromInt(newest - shown_end)) / fs,
                    .at_s = @as(f64, @floatFromInt(shown_end)) / fs,
                    .from_file = review_from_file,
                    .loading = reviewing and !review_ready,
                },
                .view_unsaved = if (renderViews(view_now, &display.set)) |rendered| !std.mem.eql(u8, rendered, view_saved[0..view_saved_len]) else false,
                .notes = blk: {
                    var st: control.NotesStatus = .{ .editing = notes.editing, .num_drafts = notes.num_drafts, .total = notes.total };
                    for (&st.recent, 0..) |*line, k| {
                        const note = notes.recentNote(k) orelse break;
                        line.seconds = @as(f64, @floatFromInt(note.sample)) / fs;
                        line.len = @min(note.len, line.buf.len);
                        @memcpy(line.buf[0..line.len], note.buf[0..line.len]);
                        st.num_recent = k + 1;
                    }
                    for (&st.presets, &notes.presets) |*line, *pr| {
                        line.len = @min(pr.len, 20);
                        @memcpy(line.buf[0..line.len], pr.buf[0..line.len]);
                    }
                    break :blk st;
                },
                .audio = blk: {
                    var st: control.AudioStatus = .{
                        .settings = display.audio,
                        .running = audio_shared.running.load(.acquire),
                        .sigma_uv = @as(f64, @floatFromInt(audio_shared.held_sigma_c.load(.monotonic))) / 100.0 * oez.types.electrode_uv_per_bit,
                        .latency_ms = @as(f64, @floatFromInt(audio_shared.latency_us.load(.monotonic))) / 1000.0,
                        .underruns = audio_shared.underruns.load(.monotonic),
                        .dropped = audio_shared.dropped.load(.monotonic),
                        .car = display.audio_car,
                    };
                    var w: Io.Writer = .fixed(&st.listen_buf);
                    for (display.audio.channelSlice(), 0..) |ch, k| {
                        var name_buf: [16]u8 = undefined;
                        w.print("{s}{s}", .{ if (k > 0) ", " else "", channelName(&name_buf, &layout, ch) }) catch break;
                    }
                    st.listen_len = w.buffered().len;
                    break :blk st;
                },
                .about_buf = about: {
                    var b: [160]u8 = undefined;
                    _ = std.fmt.bufPrint(&b, "{s}   {d} channels ({d} electrode) at {d} Hz", .{ if (sim != null) "simulated board" else "Open Ephys acquisition board", nch, layout.num_electrodes, fs }) catch "";
                    break :about b;
                },
                .about_len = std.fmt.count("{s}   {d} channels ({d} electrode) at {d} Hz", .{ if (sim != null) "simulated board" else "Open Ephys acquisition board", nch, layout.num_electrodes, fs }),
                .board = blk: {
                    // What the chips do for the values asked for.
                    var reg = oez.registers.Rhd2000Registers.init(fs);
                    board_status.settings = acq.requested;
                    board_status.lower_actual = reg.setLowerBandwidth(acq.requested.lower_bandwidth);
                    board_status.upper_actual = reg.setUpperBandwidth(acq.requested.upper_bandwidth);
                    board_status.dsp_actual = reg.setDspCutoffFreq(acq.requested.dsp_cutoff);
                    board_status.pending = pending;
                    var lines: [12][64]u8 = undefined;
                    var lens: [12]usize = undefined;
                    board_status.unsaved = oez.board_config.diff(&saved_settings, &acq.requested, &lines, &lens) > 0;
                    board_status.num_headstages = 0;
                    for (layout.headstageSlice()) |h| {
                        board_status.headstages[board_status.num_headstages] = .{ .slot = @intCast(h.slot), .rhd2132 = std.mem.eql(u8, h.chip, "RHD2132") };
                        board_status.num_headstages += 1;
                    }
                    break :blk board_status;
                },
                .rec = blk: {
                    if (rec) |r| {
                        rec_status.seconds = status.rec_seconds;
                        rec_status.samples = r.stats.samples.load(.monotonic);
                        rec_status.bytes = r.stats.bytes.load(.monotonic);
                        rec_status.gaps = r.stats.gaps.load(.monotonic);
                        rec_status.behind_s = @as(f64, @floatFromInt(r.backlog() * bs)) / fs;
                    }
                    break :blk rec_status;
                },
            });
        }
        // A panel's corners changed: filter its recent past again.
        if (gpu.hist_cap > 0) _ = try feed.sync(gpa, &display.set, refilterSamples(&display.set, fs), gpu.hist, gpu.hist_cap);

        for (win.takePresented()) |p| {
            const acquired = frame_acquired[p.tag % frame_acquired.len];
            if (acquired != 0) {
                const ms = @as(f64, @floatFromInt(p.time_ns - acquired)) / 1e6;
                lat_sum += ms;
                lat_min = @min(lat_min, ms);
                lat_max = @max(lat_max, ms);
                lat_n += 1;
                {
                    // Did it reach the screen at the refresh aimed at, or a refresh later?
                    const ft = frame_timing[p.tag % frame_timing.len];
                    if (ft.target_ns != 0 and p.refresh_ns > 0) {
                        if (p.time_ns - ft.target_ns > p.refresh_ns / 2) {
                            late_run += 1;
                            good_run = 0;
                            late_frames_now += 1;
                        } else {
                            late_run = 0;
                            good_run += 1;
                            on_time_frames += 1;
                            // Two seconds of frames on time: the next loss is a new event.
                            if (good_run >= 120) skip_backoff_ns = skip_backoff_min;
                        }
                        // Recovery (see the header). Only a fullscreen window can be scanned
                        // out directly, so only then is there something to recover.
                        const t_now = nowNs(io);
                        if (fullscreen and late_run >= 8 and t_now - last_skip_ns >= skip_backoff_ns) {
                            skip_frame = true;
                            last_skip_ns = t_now;
                            skip_backoff_ns = @min(skip_backoff_ns * 2, 8 * std.time.ns_per_s);
                            late_run = 0;
                        }
                    }
                }
                if (frame_trace) {
                    const ft = frame_timing[p.tag % frame_timing.len];
                    std.debug.print("frame {d} lat {d:.2} before {d:.2} cb {d:.2} shown {d:.2}\n", .{ p.tag, ms, ft.before_refresh_ms, ft.callback_to_draw_ms, if (ft.target_ns != 0) @as(f64, @floatFromInt(p.time_ns - ft.target_ns)) / 1e6 else 0 });
                }
                // Landed a refresh later than frames have been landing: it was drawn too
                // close to the deadline (or the desktop was busy).
                const refresh_ms = @as(f64, @floatFromInt(p.refresh_ns)) / 1e6;
                best_ms = @min(best_ms, ms);
                if (refresh_ms > 0 and ms > best_ms + 0.6 * refresh_ms) {
                    const ft = frame_timing[p.tag % frame_timing.len];
                    if (frame_debug) log.info("late frame {d}: latency {d:.1} ms; woke {d:.2} ms after its time, draw took {d:.2} ms, committed {d:.2} ms before the refresh aimed at, {d:.2} ms after the frame callback; presented {d:.2} ms after that refresh", .{ p.tag, ms, ft.wake_late_ms, ft.draw_ms, ft.before_refresh_ms, ft.callback_to_draw_ms, if (ft.target_ns != 0) @as(f64, @floatFromInt(p.time_ns - ft.target_ns)) / 1e6 else 0 });
                    misses += 1;
                    misses_this_second += 1;
                }
            }
            refresh_ns = p.refresh_ns;
            last_present_ns = p.time_ns;
            if (!clock_checked) {
                clock_checked = true;
                if (win.presentation_clock != 1) log.warn("presentation clock is {d}, not CLOCK_MONOTONIC: latency figures will be off", .{win.presentation_clock});
            }
        }

        const now = nowNs(io);
        if (win.frame_ready and draw_at == 0) {
            ready_seen_ns = now;
            target_refresh_ns = 0;
            // The next refresh after now, less the margin. Without presentation feedback
            // (or before the first), draw at once.
            draw_at = now;
            // (`last_present_ns` can be slightly ahead of now: the compositor reports a flip it
            // has just queued. The arithmetic below handles that; drawing at once instead
            // would put two commits in one refresh and knock direct scanout into queueing.)
            if (refresh_ns > 0 and last_present_ns > 0) {
                const period: i128 = refresh_ns;
                const next_refresh = last_present_ns + (@divFloor(now - last_present_ns, period) + 1) * period;
                const at = next_refresh - @as(i128, @intFromFloat(margin_ms * 1e6));
                // Already inside the margin: this refresh is lost anyway, so aim at the next.
                draw_at = if (at >= now) at else at + period;
                target_refresh_ns = if (at >= now) next_refresh else next_refresh + period;
            }
        }
        const free = args.free_ms >= 0;
        var due = if (free)
            newest != drawn_newest and @as(f64, @floatFromInt(now - last_draw_ns)) >= args.free_ms * 1e6
        else
            win.frame_ready and draw_at != 0 and now >= draw_at;
        if (due and skip_frame and !free and refresh_ns > 0) {
            // Leave this refresh out: with nothing committed the output goes idle, and the
            // next commit is taken at once again.
            skip_frame = false;
            skips += 1;
            draw_at += refresh_ns;
            if (target_refresh_ns != 0) target_refresh_ns += refresh_ns;
            due = false;
        }
        if (due and newest > 0) {
            if (win.resized or gpu.swapchain == .null) {
                try gpu.resize(win.width, win.height);
                win.resized = false;
                n_resize += 1;
            }
            const fr = display.frame(&gpu, &layout, newest, if (reviewing) ReviewView{ .end = shown_end, .from_file = review_from_file, .ready = review_ready, .behind_s = @as(f64, @floatFromInt(newest - shown_end)) / fs } else null, status, &notes, &batch, &draws, &fills);
            frame_tag += 1;
            frame_acquired[frame_tag % frame_acquired.len] = newest_acquired_ns;
            const Ctx = struct { win: *Window, tag: u64 };
            const result = try gpu.draw(fr.draws, fr.fills, fr.text, Ctx{ .win = &win, .tag = frame_tag }, struct {
                fn f(c: Ctx) void {
                    c.win.beforePresent(c.tag);
                }
            }.f);
            const done = nowNs(io);
            if (gpu.wait_render) {
                const r = @as(f64, @floatFromInt(gpu.last_render_ns)) / 1e6;
                render_sum += r;
                render_max = @max(render_max, r);
                render_n += 1;
            }
            frame_timing[frame_tag % frame_timing.len] = .{
                .wake_late_ms = @as(f64, @floatFromInt(now - draw_at)) / 1e6,
                .draw_ms = @as(f64, @floatFromInt(done - now)) / 1e6,
                .before_refresh_ms = if (target_refresh_ns != 0) @as(f64, @floatFromInt(target_refresh_ns - done)) / 1e6 else 0,
                .callback_to_draw_ms = @as(f64, @floatFromInt(now - ready_seen_ns)) / 1e6,
                .target_ns = target_refresh_ns,
            };
            switch (result) {
                .presented => {
                    frames += 1;
                    drawn_newest = newest;
                    last_draw_ns = now;
                },
                .out_of_date => {
                    win.resized = true;
                    win.frame_ready = true;
                    n_out_of_date += 1;
                },
                .busy => {
                    win.frame_ready = true;
                    n_busy += 1;
                },
            }
            draw_at = 0;
        }

        if (now >= next_report) {
            const secs = @as(f64, @floatFromInt(now - t_start)) / 1e9;
            const avg = if (lat_n > 0) lat_sum / lat_n else 0;
            const tp = &display.set.items[display.target];
            log.info("t={d:.0}s {d} fps, latency ms avg {d:.1} min {d:.1} max {d:.1}, at the refresh aimed at {d}, a refresh later {d}, recovery skips {d}, margin {d:.1} ms, refresh {d:.2} ms, display lost {d} blocks, ring overflow {d}, panel {d} span {d:.2} s scale {d:.1}, {d}x{d}", .{
                secs,            frames, avg,       if (lat_n > 0) lat_min else 0,             lat_max,
                on_time_frames,  late_frames_now, skips, margin_ms,                            @as(f64, @floatFromInt(refresh_ns)) / 1e6,
                reader.lost,     acq.ring_overflow.load(.monotonic), display.target + 1, tp.span_s, tp.scale, gpu.extent.width,
                gpu.extent.height,
            });
            status.valid = lat_n > 0;
            status.latency_ms = avg;
            status.fps = frames;
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
            on_time_frames = 0;
            late_frames_now = 0;
            if (frame_debug) {
                log.info("  GPU time per frame: avg {d:.2} ms, max {d:.2} ms; draw results so far: out of date {d}, busy {d}, swapchain rebuilds {d}", .{ if (render_n > 0) render_sum / render_n else 0, render_max, n_out_of_date, n_busy, n_resize });
                render_sum = 0;
                render_max = 0;
                render_n = 0;
            }
            const refresh_ms_now = @as(f64, @floatFromInt(refresh_ns)) / 1e6;
            // A change of regime moves every frame by a refresh: that is not lateness.
            if (lat_n > 0 and refresh_ms_now > 0 and @abs(lat_min - best_ms) > 0.6 * refresh_ms_now) {
                best_ms = lat_min;
                misses_this_second = 0;
            }
            // Adapt the margin to sustained lateness only. A few late frames now and then come
            // from the desktop (a window moved, a resize), and a wider margin would not have
            // saved them: widen when at least 5 frames in a second were late, and return
            // towards 3 ms after 3 clean seconds.
            // (Not fullscreen: there, frames a refresh late are a lost direct-scanout state,
            // which a wider margin does not prevent and the skip above recovers.)
            if (args.margin_ms < 0 and !fullscreen) {
                const refresh_ms = @as(f64, @floatFromInt(refresh_ns)) / 1e6;
                if (misses_this_second >= 5) {
                    margin_ms = @min(margin_ms + 0.5, @max(3.0, 0.5 * refresh_ms));
                    clean_seconds = 0;
                } else if (misses_this_second == 0) {
                    clean_seconds += 1;
                    if (clean_seconds >= 3 and margin_ms > 3.0) {
                        margin_ms = @max(3.0, margin_ms - 0.5);
                        clean_seconds = 0;
                    }
                } else clean_seconds = 0;
            }
            misses_this_second = 0;
            // Forget the best now and then, so a change of regime (direct scanout lost to
            // an overlapping window, say) is not counted as lateness for ever.
            best_age += 1;
            if (best_age >= 5) {
                best_age = 0;
                best_ms = if (lat_n > 0) lat_min else std.math.inf(f64);
            }
            if (std.c.getenv("OEZ_NO_TITLE") == null) {
                if (std.fmt.bufPrintSentinel(&title_buf, "oEZ   {s}: {d:.2} s  {d:.1} {s}/row   latency {d:.1} ms   {d} fps", .{ tp.name(), tp.span_s, tp.scale, tp.unit(), avg, frames }, 0)) |t| win.setTitle(t) else |_| {}
            }
            frames = 0;
            lat_sum = 0;
            lat_min = std.math.inf(f64);
            lat_max = 0;
            lat_n = 0;
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
