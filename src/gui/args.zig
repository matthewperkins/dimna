//! The command line and the top-level keys of the config file.

const std = @import("std");
const builtin = @import("builtin");
const dimna = @import("dimna");
const gpu_mod = @import("gpu.zig");
const audio_out = @import("audio_out.zig");
const log = std.log.scoped(.dimna);

/// On a Mac's screen (two pixels to the point) the default 14 px is 7 points. Unless the
/// config file says what `font_px` is, the display's text (titles, row labels, the key
/// summary) is 20 px there, and the control window's, which is read and clicked, 24 px.
/// The tiles keep `font_px`.
const mac_display_font_px = 20;
const mac_control_font_px = 24;

/// macOS waits for the refresh by default (the owner's choice by eye, 2026-11-16: about 20
/// ms behind, but the scroll is even on a 60 Hz screen); `--tearing` is the quick mode.
const present_default: gpu_mod.PresentMode = if (builtin.os.tag == .macos) .fifo else .auto;

pub const Args = struct {
    seconds: f64 = 0,
    settings: dimna.types.Settings = .{},
    driver: dimna.board.Driver = .usb,
    sim: [8]usize = @splat(0),
    num_sim: usize = 0,
    present: gpu_mod.PresentMode = present_default,
    /// Fixed margin before the refresh at which to draw; negative = adapt.
    margin_ms: f64 = -1,
    script: []const u8 = "",
    monitor: []const u8 = "",
    tearing: bool = false,
    /// An image the GUI's colours are taken from (`scheme_image` in the config; "" = the
    /// built-in colours). Not resolved: see `scheme.resolvePath`.
    scheme_image: []const u8 = "",
    /// `--print-scheme`: print the scheme of this image and exit ("" = no).
    print_scheme: []const u8 = "",
    /// `--swatch`: also write a swatch PNG of it here.
    swatch: []const u8 = "",
    /// Where recordings go: one session folder per recording beneath it.
    record_dir: []const u8 = "~/dimna-recordings",
    /// The spike tiles (a third window).
    tiles: bool = true,
    /// The spike audio monitor.
    audio: bool = true,
    volume_db: f64 = -6,
    /// The sound device's period in frames, a power of two from 16 to 1024 (`audio_period`
    /// in the config). Not the default: PipeWire's quantum is asked to match (main.zig).
    audio_period: u32 = audio_out.default_period,
    /// The control window (a second, ordinary window with the panels' settings).
    control: bool = true,
    /// All panels in sweep mode (see `panels.Mode`).
    sweep: bool = false,
    /// Free-running: least interval between frames in ms; negative = paced to the refresh.
    free_ms: f64 = -1,
    /// The language of the GUI's texts (`language` in the config: "en", "de", ...; "" = from
    /// `LANG`). Not checked here: see `i18n.pick`.
    language: []const u8 = "",
    /// Font for labels: a fontconfig name and a size in pixels.
    font: []const u8 = "sans-serif",
    font_px: u32 = 14,
    /// The config file gave `font_px` (otherwise macOS draws the display's and the control
    /// window's text larger: `displayFontPx`, `controlFontPx`).
    font_px_given: bool = false,
    /// One window's text size, from `display_font_px`, `control_font_px` and `tiles_font_px`
    /// in the config; null: `font_px` (or, without that on macOS, that window's default).
    display_font_px: ?u32 = null,
    control_font_px: ?u32 = null,
    tiles_font_px: ?u32 = null,
    /// The view file (panel settings saved from the control window), applied on top of the
    /// config's panels.
    views_doc: dimna.toml.Document = .{ .entries = &.{} },
    /// The parsed config file (panels are read from it once the channel layout is known).
    doc: dimna.toml.Document = .{ .entries = &.{} },

    /// Each window's text size in pixels: its own key if the config has it; else `font_px`
    /// if the config has that; else the default (14, or on macOS the window's own).
    pub fn displayFontPx(self: *const Args) u32 {
        return self.display_font_px orelse self.sharedFontPx(mac_display_font_px);
    }

    pub fn controlFontPx(self: *const Args) u32 {
        return self.control_font_px orelse self.sharedFontPx(mac_control_font_px);
    }

    pub fn tilesFontPx(self: *const Args) u32 {
        return self.tiles_font_px orelse self.font_px;
    }

    fn sharedFontPx(self: *const Args, mac_default: u32) u32 {
        return if (builtin.os.tag == .macos and !self.font_px_given) mac_default else self.font_px;
    }
};

/// What `dimna --help` prints. Every option `parseArgs` accepts is listed here (a test checks).
pub const usage =
    \\dimna: the dimna display. Without --sim it opens the acquisition board.
    \\
    \\  --sim 32,16         simulate headstages of these channel counts instead of the board
    \\  --16ch A1,B1        these RHD2132 headstages carry 16 electrodes (half-channel mode)
    \\  --aux, --adc        also acquire the auxiliary inputs, the board's ADC inputs
    \\  --driver usb|d3xx   how to reach the FT600: our own USB code (default) or FTDI's D3XX
    \\  --monitor DP-2      fullscreen on that monitor (the neural display)
    \\  --print-scheme IMG  print the colours derived from a JPEG or PNG and exit (no window,
    \\                      no board); with --swatch OUT.png also draw them
    \\  --swatch OUT.png    where --print-scheme writes its swatch
    \\  --tearing           show each frame at once, mid-scan (lowest latency; implies
    \\                      --present immediate and --free 2; see docs/latency.md)
    \\  --free MS           draw whenever new samples have arrived, at most every MS ms
    \\  --margin-ms MS      draw this long before each refresh (default: 3, adapted)
    \\  --present auto|mailbox|immediate|fifo    the Vulkan present mode
    \\  --sweep             all panels as a sweep (traces stand still, a cursor moves across)
    \\  --no-control        no control window
    \\  --no-tiles          no spike-tile window
    \\  --no-audio          no spike audio
    \\  --audio-period N    the sound device's period in frames: 16, 32, ... 1024 (default
    \\                      128); smaller is less latency (docs/tiles-and-audio.md)
    \\  --seconds S         quit after S seconds
    \\  --script STEPS      synthetic input for tests (see src/gui/script.zig)
    \\  --help
    \\
    \\Config file: $XDG_CONFIG_HOME/dimna/config.toml (default ~/.config/dimna); options above
    \\win. docs/display.md has its keys and the [[panel]] tables.
    \\
    \\On the display (? shows these there, with the spike-tile window's):
    \\  wheel                          Y scale (µV per row; also a two-finger scroll)
    \\  Ctrl+wheel                     Y scale of the row under the pointer alone
    \\  Shift+wheel                    back and forth in time: scroll-back review, a tenth of the
    \\                                 time base a click; back from now enters it, forward to now
    \\                                 leaves it (from the recording's file while recording, else
    \\                                 the last half minute)
    \\  sideways scroll                the same as Shift+wheel
    \\  Alt+wheel                      time base (triggered: the window around the trigger)
    \\  touchpad pinch                 time base
    \\  - =                            Y scale
    \\  [ ]                            time base
    \\  r                              the panel as the config has it
    \\  m                              scroll <-> sweep (traces stand still, a cursor moves across)
    \\  f                              display filter on/off (electrode panels): raw <-> band-pass
    \\  , .                            the band's low corner: down, up
    \\  ; '                            the band's high corner: down, up
    \\  t                              triggered sweeps on/off: the signal around each rising edge of
    \\                                 a TTL input line, the last few overlaid
    \\  1-8                            triggered on TTL: the line
    \\  s                              triggered: spikes on the row under the pointer (a slope
    \\                                 trigger at that channel's threshold) <-> TTL
    \\  left-click a row               focus on that channel: an amber label, and its spike
    \\                                 threshold as a red line on its trace (where the row shows
    \\                                 about 300-6000 Hz; else "thr" beside the label); triggered
    \\                                 on spikes, the trigger moves to that row
    \\  right-click a row              listen to that channel alone (♪ before its label)
    \\  Ctrl+right-click               add a channel to what is heard, or take it out
    \\  middle-click                   no channel in focus
    \\  drag a red line                its channel's threshold, fixed at the µV under the pointer
    \\                                 (the pointer is a hand within 4 px of the line; dashed:
    \\                                 the trigger's); across the row's centre it changes sign
    \\  n                              the threshold of the row under the pointer: fixed <->
    \\                                 following the noise (fixed at its present value)
    \\  Space                          freeze: look at what just went by, or back to live
    \\  Left / Right                   back, forward a tenth of the window
    \\  PgUp / PgDn                    back, forward a whole window
    \\  Home / End                     the start of the recording / back to live
    \\  l                              back to live
    \\  /                              type a note (Enter saves, Esc drops, Tab keeps it as a draft)
    \\  `                              stamp the first draft note
    \\  1-9                            stamp the config's preset notes
    \\  ~                              hide / show the ADC panels (the others grow over them)
    \\  Shift+a                        acknowledge an alarm (the red bar: samples lost, or the
    \\                                 recording failed)
    \\  ?                              the keys, over the display (? or Esc closes them)
    \\  Ctrl+Q or Esc                  quit (while recording: asks first)
    \\
;

/// Applies the config file's top-level keys to `a`. (`[[panel]]` tables are read later.)
pub fn applyConfig(a: *Args, doc: dimna.toml.Document) void {
    a.doc = doc;
    for (doc.entries) |e| {
        if (e.table.len != 0) {
            if (!std.mem.eql(u8, e.table, "panel") and !std.mem.eql(u8, e.table, "board") and
                !std.mem.eql(u8, e.table, "ttl") and
                !std.mem.eql(u8, e.table, "notes")) log.warn("config line {d}: unknown table [{s}]", .{ e.line, e.table });
            continue;
        }
        if (std.mem.eql(u8, e.key, "monitor") and e.value == .string) {
            a.monitor = e.value.string;
        } else if (std.mem.eql(u8, e.key, "margin_ms") and e.value == .number) {
            a.margin_ms = e.value.number;
        } else if (std.mem.eql(u8, e.key, "free_ms") and e.value == .number) {
            a.free_ms = e.value.number;
        } else if (std.mem.eql(u8, e.key, "language") and e.value == .string) {
            a.language = e.value.string;
        } else if (std.mem.eql(u8, e.key, "font") and e.value == .string) {
            a.font = e.value.string;
        } else if (std.mem.eql(u8, e.key, "font_px") and e.value == .number and e.value.number >= 6 and e.value.number <= 64) {
            a.font_px = @intFromFloat(e.value.number);
            a.font_px_given = true;
        } else if (std.mem.eql(u8, e.key, "display_font_px") and e.value == .number and e.value.number >= 6 and e.value.number <= 64) {
            a.display_font_px = @intFromFloat(e.value.number);
        } else if (std.mem.eql(u8, e.key, "control_font_px") and e.value == .number and e.value.number >= 6 and e.value.number <= 64) {
            a.control_font_px = @intFromFloat(e.value.number);
        } else if (std.mem.eql(u8, e.key, "tiles_font_px") and e.value == .number and e.value.number >= 6 and e.value.number <= 64) {
            a.tiles_font_px = @intFromFloat(e.value.number);
        } else if (std.mem.eql(u8, e.key, "tiles") and e.value == .boolean) {
            a.tiles = e.value.boolean;
        } else if (std.mem.eql(u8, e.key, "audio") and e.value == .boolean) {
            a.audio = e.value.boolean;
        } else if (std.mem.eql(u8, e.key, "audio_period") and e.value == .number) {
            const n = e.value.number;
            if (n >= 0 and n <= audio_out.max_period and n == @floor(n) and audio_out.validPeriod(@intFromFloat(n))) {
                a.audio_period = @intFromFloat(n);
            } else log.warn("config line {d}: audio_period {d} is not a power of two from 16 to 1024 frames; ignored", .{ e.line, n });
        } else if (std.mem.eql(u8, e.key, "volume_db") and e.value == .number) {
            a.volume_db = std.math.clamp(e.value.number, -60, 12);
        } else if (std.mem.eql(u8, e.key, "record_dir") and e.value == .string) {
            a.record_dir = e.value.string;
        } else if (std.mem.eql(u8, e.key, "control") and e.value == .boolean) {
            a.control = e.value.boolean;
        } else if (std.mem.eql(u8, e.key, "mode")) {
            // Read with the panels.
        } else if (std.mem.eql(u8, e.key, "scheme_image") and e.value == .string) {
            a.scheme_image = e.value.string;
        } else if (std.mem.eql(u8, e.key, "tearing") and e.value == .boolean) {
            a.tearing = e.value.boolean;
            if (a.tearing) a.present = .immediate;
        } else log.warn("config line {d}: unknown key '{s}' or wrong type", .{ e.line, e.key });
    }
}

pub fn parseArgs(args: []const [:0]const u8, doc: dimna.toml.Document) !Args {
    var a: Args = .{};
    applyConfig(&a, doc);
    // The [board] table; command-line options below win over it.
    var board_diag: dimna.board_config.Diagnostics = .{};
    dimna.board_config.read(doc, &a.settings, &board_diag) catch {
        log.err("config: {s}", .{board_diag.message()});
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
        if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return error.Help;
        } else if (std.mem.eql(u8, arg, "--seconds")) {
            a.seconds = try std.fmt.parseFloat(f64, try next(args, &i, arg));
        } else if (std.mem.eql(u8, arg, "--monitor")) {
            a.monitor = try next(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--print-scheme")) {
            a.print_scheme = try next(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--swatch")) {
            a.swatch = try next(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--tearing")) {
            a.tearing = true;
            a.present = .immediate;
        } else if (std.mem.eql(u8, arg, "--no-tiles")) {
            a.tiles = false;
        } else if (std.mem.eql(u8, arg, "--no-audio")) {
            a.audio = false;
        } else if (std.mem.eql(u8, arg, "--audio-period")) {
            const text = try next(args, &i, arg);
            a.audio_period = parsePeriod(text) orelse {
                log.err("--audio-period: '{s}' is not a power of two from 16 to 1024 frames", .{text});
                return error.BadArgs;
            };
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
            a.driver = std.meta.stringToEnum(dimna.board.Driver, name) orelse {
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
                const slot = for (dimna.types.headstage_names, 0..) |n, k| {
                    if (std.ascii.eqlIgnoreCase(n, name)) break k;
                } else {
                    log.err("--16ch: unknown headstage slot '{s}' (use A1..D2)", .{name});
                    return error.BadArgs;
                };
                a.settings.rhd2132_16ch[slot] = true;
            }
        } else {
            log.err("unknown argument '{s}' (dimna --help lists them)", .{arg});
            return error.BadArgs;
        }
    }
    // Tearing shows frames as they are presented, so draw as samples arrive.
    if (a.tearing and a.free_ms < 0) a.free_ms = 2;
    return a;
}

/// `--audio-period`'s value, or null if it is not one `audio_out.validPeriod` accepts.
fn parsePeriod(text: []const u8) ?u32 {
    const n = std.fmt.parseInt(u32, text, 10) catch return null;
    return if (audio_out.validPeriod(n)) n else null;
}

test "audio_period: 128 unless the config or the command line says otherwise; the command line wins; only powers of two from 16 to 1024" {
    var diag: dimna.toml.Diagnostics = .{};
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const none = try parseArgs(&.{"dimna"}, .{ .entries = &.{} });
    try std.testing.expectEqual(128, none.audio_period);
    const doc = try dimna.toml.parse(arena.allocator(), "audio_period = 64\n", &diag);
    try std.testing.expectEqual(64, (try parseArgs(&.{"dimna"}, doc)).audio_period);
    try std.testing.expectEqual(32, (try parseArgs(&.{ "dimna", "--audio-period", "32" }, doc)).audio_period);
    try std.testing.expectEqual(1024, (try parseArgs(&.{ "dimna", "--audio-period", "1024" }, .{ .entries = &.{} })).audio_period);
    // Every power of two in the range, and nothing else up to 4096.
    for (0..4097) |n| {
        const want = n >= 16 and n <= 1024 and std.math.isPowerOfTwo(n);
        var buf: [8]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
        try std.testing.expectEqual(want, parsePeriod(text) != null);
        try std.testing.expectEqual(want, audio_out.validPeriod(n));
    }
    for ([_][]const u8{ "", "abc", "64.0", "-64", " 64", "0x40", "4294967296" }) |text|
        try std.testing.expectEqual(null, parsePeriod(text));
    // The command line refuses what parsePeriod refuses (not run here: it logs an error,
    // which fails a test). The config warns and keeps what it had.
    for ([_][]const u8{ "audio_period = 48\n", "audio_period = 8\n", "audio_period = 2048\n", "audio_period = 64.5\n", "audio_period = -64\n", "audio_period = \"64\"\n" }) |text| {
        const bad = try dimna.toml.parse(arena.allocator(), text, &diag);
        try std.testing.expectEqual(128, (try parseArgs(&.{"dimna"}, bad)).audio_period);
        try std.testing.expectEqual(256, (try parseArgs(&.{ "dimna", "--audio-period", "256" }, bad)).audio_period);
    }
}

test "text sizes: a window's own key, then font_px, then the default" {
    var diag: dimna.toml.Diagnostics = .{};
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const mac = builtin.os.tag == .macos;
    // Nothing given: 14 everywhere, except the display and the control window on macOS.
    const none = try parseArgs(&.{"dimna"}, try dimna.toml.parse(arena.allocator(), "", &diag));
    try std.testing.expectEqual(@as(u32, if (mac) mac_display_font_px else 14), none.displayFontPx());
    try std.testing.expectEqual(@as(u32, if (mac) mac_control_font_px else 14), none.controlFontPx());
    try std.testing.expectEqual(@as(u32, 14), none.tilesFontPx());
    // font_px alone: all three.
    const shared = try parseArgs(&.{"dimna"}, try dimna.toml.parse(arena.allocator(), "font_px = 18\n", &diag));
    try std.testing.expectEqual(@as(u32, 18), shared.displayFontPx());
    try std.testing.expectEqual(@as(u32, 18), shared.controlFontPx());
    try std.testing.expectEqual(@as(u32, 18), shared.tilesFontPx());
    // A window's own key wins over font_px; the others keep font_px.
    const own = try parseArgs(&.{"dimna"}, try dimna.toml.parse(arena.allocator(), "font_px = 18\ndisplay_font_px = 22\ntiles_font_px = 12\n", &diag));
    try std.testing.expectEqual(@as(u32, 22), own.displayFontPx());
    try std.testing.expectEqual(@as(u32, 18), own.controlFontPx());
    try std.testing.expectEqual(@as(u32, 12), own.tilesFontPx());
    // One window's key without font_px: the others keep their defaults. Out of range: ignored.
    const one = try parseArgs(&.{"dimna"}, try dimna.toml.parse(arena.allocator(), "control_font_px = 30\ndisplay_font_px = 200\n", &diag));
    try std.testing.expectEqual(@as(u32, 30), one.controlFontPx());
    try std.testing.expectEqual(@as(u32, if (mac) mac_display_font_px else 14), one.displayFontPx());
    try std.testing.expectEqual(@as(u32, 14), one.tilesFontPx());
}

test "scheme_image is read from the config, and the scheme options from the command line" {
    var diag: dimna.toml.Diagnostics = .{};
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const doc = try dimna.toml.parse(arena.allocator(), "scheme_image = \"~/pics/lab.jpg\"\n", &diag);
    const a = try parseArgs(&.{ "dimna", "--print-scheme", "x.png", "--swatch", "out.png" }, doc);
    try std.testing.expectEqualStrings("~/pics/lab.jpg", a.scheme_image);
    try std.testing.expectEqualStrings("x.png", a.print_scheme);
    try std.testing.expectEqualStrings("out.png", a.swatch);
}

test "language is read from the config" {
    var diag: dimna.toml.Diagnostics = .{};
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const doc = try dimna.toml.parse(arena.allocator(), "language = \"de\"\n", &diag);
    const a = try parseArgs(&.{"dimna"}, doc);
    try std.testing.expectEqualStrings("de", a.language);
    try std.testing.expectEqual(@import("i18n.zig").Language.de, @import("i18n.zig").pick(a.language, "pl_PL.UTF-8"));
    const none = try parseArgs(&.{"dimna"}, .{ .entries = &.{} });
    try std.testing.expectEqualStrings("", none.language);
}

test "the usage text lists every option the parser accepts" {
    const source = @embedFile("args.zig");
    var rest: []const u8 = source;
    var found: usize = 0;
    while (std.mem.indexOf(u8, rest, "eql(u8, arg, \"--")) |at| {
        const name_start = at + "eql(u8, arg, \"".len;
        const name_end = std.mem.indexOfScalarPos(u8, rest, name_start, '"').?;
        const name = rest[name_start..name_end];
        if (std.mem.indexOf(u8, usage, name) == null) {
            std.debug.print("{s} is accepted but not in the usage text\n", .{name});
            return error.TestUnexpectedResult;
        }
        found += 1;
        rest = rest[name_end..];
    }
    try std.testing.expect(found >= 15);
}
