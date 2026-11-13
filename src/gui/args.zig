//! The command line and the top-level keys of the config file.

const std = @import("std");
const oez = @import("oez");
const gpu_mod = @import("gpu.zig");
const log = std.log.scoped(.oez);

pub const Args = struct {
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

/// What `oez --help` prints. Every option `parseArgs` accepts is listed here (a test checks).
pub const usage =
    \\oez: the oEZ display. Without --sim it opens the acquisition board.
    \\
    \\  --sim 32,16         simulate headstages of these channel counts instead of the board
    \\  --16ch A1,B1        these RHD2132 headstages carry 16 electrodes (half-channel mode)
    \\  --aux, --adc        also acquire the auxiliary inputs, the board's ADC inputs
    \\  --driver usb|d3xx   how to reach the FT600: our own USB code (default) or FTDI's D3XX
    \\  --monitor DP-2      fullscreen on that monitor (the neural display)
    \\  --tearing           show each frame at once, mid-scan (lowest latency; implies
    \\                      --present immediate and --free 2; see docs/latency.md)
    \\  --free MS           draw whenever new samples have arrived, at most every MS ms
    \\  --margin-ms MS      draw this long before each refresh (default: 3, adapted)
    \\  --present auto|mailbox|immediate|fifo    the Vulkan present mode
    \\  --sweep             all panels as a sweep (traces stand still, a cursor moves across)
    \\  --no-control        no control window
    \\  --no-tiles          no spike-tile window
    \\  --no-audio          no spike audio
    \\  --seconds S         quit after S seconds
    \\  --script STEPS      synthetic input for tests (see src/gui/script.zig)
    \\  --help
    \\
    \\Config file: $XDG_CONFIG_HOME/oez/config.toml (default ~/.config/oez); options above
    \\win. See the README for its keys and the [[panel]] tables.
    \\
    \\On the display:
    \\  wheel / two-finger scroll      Y scale (µV per row)
    \\  Ctrl+wheel                     Y scale of the row under the pointer alone
    \\  Shift+wheel, sideways scroll   time base
    \\  touchpad pinch                 time base
    \\  - =   [ ]                      Y scale, time base by keys;  r resets;  q or Esc quits
    \\  m                              scroll <-> sweep (traces stand still, a cursor moves across)
    \\  t                              triggered sweeps on/off: the signal around each rising edge of
    \\                                 a TTL input line, the last few overlaid; 1-8 pick the line;
    \\                                 s switches to spikes on the row under the pointer (a slope
    \\                                 trigger; click another row to move it) and back,
    \\                                 [ ] and Shift+wheel zoom the window around the trigger
    \\  Space                          freeze: look at what just went by. Then, or at once:
    \\  Left / Right, PgUp / PgDn      go back and forth (a tenth of the window, a whole window)
    \\  Home / End                     the start of the recording / back to live
    \\                                 (scroll-back review: from the recording's file while
    \\                                 recording, else the last half minute)
    \\  /                              type a note (Enter saves, Esc drops, Tab keeps it as a draft);
    \\                                 ` stamps a draft; 1-9 stamp the config's preset notes
    \\  a                              acknowledge an alarm (the red bar: samples lost, or the
    \\                                 recording failed)
    \\  click a row                    listen to that channel (Ctrl+click adds or removes one)
    \\  f                              display filter on/off (electrode panels): raw <-> band-pass
    \\  , .   ; '                      the band's low corner, high corner: down, up
    \\
;

/// Applies the config file's top-level keys to `a`. (`[[panel]]` tables are read later.)
pub fn applyConfig(a: *Args, doc: oez.toml.Document) void {
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

pub fn parseArgs(args: []const [:0]const u8, doc: oez.toml.Document) !Args {
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
        if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return error.Help;
        } else if (std.mem.eql(u8, arg, "--seconds")) {
            a.seconds = try std.fmt.parseFloat(f64, try next(args, &i, arg));
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
            log.err("unknown argument '{s}' (oez --help lists them)", .{arg});
            return error.BadArgs;
        }
    }
    // Tearing shows frames as they are presented, so draw as samples arrive.
    if (a.tearing and a.free_ms < 0) a.free_ms = 2;
    return a;
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
