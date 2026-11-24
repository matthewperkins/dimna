//! Finding font files with fontconfig: the Linux backend of `fontfind.zig`, which says what
//! the callers rely on. Moved here unchanged from `font.zig` (`findFont`, `anyFontHas`)
//! and `shape.zig` (`Engine.match` and the configuration the engine kept).

const std = @import("std");
const c = @import("gui_c");

/// Whether some installed font has every one of `cps` (fontconfig's font list filtered by
/// character set; `fc-match` would not do: it always answers with something).
pub fn anyFontHas(cps: []const u32) bool {
    const pat = c.FcPatternCreate() orelse return false;
    defer c.FcPatternDestroy(pat);
    const cs = c.FcCharSetCreate() orelse return false;
    defer c.FcCharSetDestroy(cs);
    for (cps) |cp| _ = c.FcCharSetAddChar(cs, cp);
    _ = c.FcPatternAddCharSet(pat, "charset", cs);
    const os = c.FcObjectSetCreate() orelse return false;
    defer c.FcObjectSetDestroy(os);
    _ = c.FcObjectSetAdd(os, "file");
    const set = c.FcFontList(null, pat, os) orelse return false;
    defer c.FcFontSetDestroy(set);
    return set.*.nfont > 0;
}

pub fn findFont(family: [:0]const u8, buf: *[std.fs.max_path_bytes:0]u8) ![:0]const u8 {
    const cfg = c.FcInitLoadConfigAndFonts() orelse return error.Fontconfig;
    defer c.FcConfigDestroy(cfg);
    const pattern = c.FcNameParse(family.ptr) orelse return error.Fontconfig;
    defer c.FcPatternDestroy(pattern);
    _ = c.FcConfigSubstitute(cfg, pattern, c.FcMatchPattern);
    c.FcDefaultSubstitute(pattern);
    var result: c.FcResult = c.FcResultNoMatch;
    const match = c.FcFontMatch(cfg, pattern, &result) orelse return error.FontNotFound;
    defer c.FcPatternDestroy(match);
    var file: [*c]c.FcChar8 = null;
    if (c.FcPatternGetString(match, c.FC_FILE, 0, &file) != c.FcResultMatch or file == null) return error.FontNotFound;
    return std.fmt.bufPrintSentinel(buf, "{s}", .{std.mem.span(@as([*:0]const u8, @ptrCast(file)))}, 0) catch error.FontNotFound;
}

pub const Match = struct { path: [:0]const u8, index: c_int };

/// fontconfig's configuration, loaded once and kept (null if it could not be loaded:
/// then nothing matches).
pub const Matcher = struct {
    cfg: ?*c.FcConfig,

    pub fn init() Matcher {
        return .{ .cfg = c.FcInitLoadConfigAndFonts() };
    }

    pub fn deinit(self: *Matcher) void {
        if (self.cfg) |cfg| c.FcConfigDestroy(cfg);
    }

    /// The font fontconfig picks for `pattern`; with `family`, only if it is that family
    /// (fontconfig always offers something).
    pub fn match(self: *Matcher, pattern_text: [:0]const u8, family: ?[]const u8, buf: *[std.fs.max_path_bytes:0]u8) ?Match {
        const cfg = self.cfg orelse return null;
        const pattern = c.FcNameParse(pattern_text.ptr) orelse return null;
        defer c.FcPatternDestroy(pattern);
        _ = c.FcConfigSubstitute(cfg, pattern, c.FcMatchPattern);
        c.FcDefaultSubstitute(pattern);
        var result: c.FcResult = c.FcResultNoMatch;
        const m = c.FcFontMatch(cfg, pattern, &result) orelse return null;
        defer c.FcPatternDestroy(m);
        if (family) |want| {
            var found = false;
            var k: c_int = 0;
            while (true) : (k += 1) {
                var name: [*c]c.FcChar8 = null;
                if (c.FcPatternGetString(m, c.FC_FAMILY, k, &name) != c.FcResultMatch or name == null) break;
                if (std.ascii.eqlIgnoreCase(std.mem.span(@as([*:0]const u8, @ptrCast(name))), want)) found = true;
            }
            if (!found) return null;
        }
        var file: [*c]c.FcChar8 = null;
        if (c.FcPatternGetString(m, c.FC_FILE, 0, &file) != c.FcResultMatch or file == null) return null;
        var index: c_int = 0;
        if (c.FcPatternGetInteger(m, c.FC_INDEX, 0, &index) != c.FcResultMatch) index = 0;
        const path = std.fmt.bufPrintSentinel(buf, "{s}", .{std.mem.span(@as([*:0]const u8, @ptrCast(file)))}, 0) catch return null;
        return .{ .path = path, .index = index };
    }
};
