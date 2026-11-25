//! The text backend on FreeType (`text_backend.zig` says what a backend offers): faces and
//! their glyphs from FreeType, font files found by `fontfind`, and bidi and shaping by
//! FriBidi and HarfBuzz. FreeType is linked (on macOS, vendored and static); HarfBuzz and
//! FriBidi are not: both are loaded with dlopen the first time something is to be shaped
//! (`shaping`). Without them, `shaping` is null and one line in the log says so.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("gui_c");
const fontfind = @import("fontfind.zig");
const text_backend = @import("text_backend.zig");
const Coverage = text_backend.Coverage;
const RunGlyph = text_backend.RunGlyph;
const log = std.log.scoped(.font);

// ---- Font lookup: fontfind's, as it is (files FreeType opens) ----

pub const findFont = fontfind.findFont;

// ---- Faces ----

pub const Library = struct {
    ft: c.FT_Library,

    pub fn init() !Library {
        var lib: c.FT_Library = null;
        if (c.FT_Init_FreeType(&lib) != 0) return error.FreeType;
        return .{ .ft = lib };
    }

    pub fn deinit(self: Library) void {
        _ = c.FT_Done_FreeType(self.ft);
    }
};

pub const Face = struct {
    ft: c.FT_Face,
    /// HarfBuzz's font for it, made the first time this face shapes something.
    hb: ?*HbFont = null,

    /// Face `index` of the font file `path`.
    pub fn open(lib: Library, path: [:0]const u8, index: c_int) !Face {
        var ft: c.FT_Face = null;
        if (c.FT_New_Face(lib.ft, path.ptr, index, &ft) != 0) return error.FontNotLoaded;
        return .{ .ft = ft };
    }

    pub fn deinit(self: Face) void {
        // HarfBuzz's font exists only if the libraries were loaded.
        if (self.hb) |hb| libs_value.hb.hb_font_destroy(hb);
        _ = c.FT_Done_Face(self.ft);
    }

    pub fn setPixelSize(self: Face, px: u32) !void {
        if (c.FT_Set_Pixel_Sizes(self.ft, 0, px) != 0) return error.FreeType;
    }

    pub fn ascent(self: Face) f32 {
        return @as(f32, @floatFromInt(self.ft.*.size.*.metrics.ascender)) / 64.0;
    }

    pub fn lineHeight(self: Face) f32 {
        return @as(f32, @floatFromInt(self.ft.*.size.*.metrics.height)) / 64.0;
    }

    pub fn ppem(self: Face) u32 {
        return self.ft.*.size.*.metrics.y_ppem;
    }

    pub fn glyphIndex(self: Face, cp: u32) u32 {
        return c.FT_Get_Char_Index(self.ft, cp);
    }

    /// Hinted and antialiased, as FreeType renders by default.
    pub fn render(self: Face, gid: u32) ?Coverage {
        if (c.FT_Load_Glyph(self.ft, gid, c.FT_LOAD_RENDER) != 0) return null;
        const slot = self.ft.*.glyph;
        const bm = slot.*.bitmap;
        return .{
            .width = bm.width,
            .rows = bm.rows,
            .pitch = bm.pitch,
            .pixels = bm.buffer,
            .left = slot.*.bitmap_left,
            .top = slot.*.bitmap_top,
            .advance = @as(f32, @floatFromInt(slot.*.advance.x)) / 64.0,
            .gray = bm.pixel_mode == c.FT_PIXEL_MODE_GRAY,
        };
    }

    pub fn heightRatio(self: Face, cp: u32) ?f32 {
        const ft = self.ft;
        if (ft.*.face_flags & c.FT_FACE_FLAG_SCALABLE == 0 or ft.*.units_per_EM == 0) return null;
        if (c.FT_Get_Char_Index(ft, cp) == 0) return null;
        if (c.FT_Load_Char(ft, cp, c.FT_LOAD_NO_SCALE) != 0) return null;
        const h: f32 = @floatFromInt(ft.*.glyph.*.metrics.height);
        if (h <= 0) return null;
        return h / @as(f32, @floatFromInt(ft.*.units_per_EM));
    }

    /// The em to the nearest 64th of a pixel.
    pub fn setEmSize(self: Face, em_px: f32) ?f32 {
        const size: c.FT_F26Dot6 = @intFromFloat(@round(em_px * 64.0));
        if (size <= 0 or c.FT_Set_Char_Size(self.ft, 0, size, 72, 72) != 0) return null;
        return self.lineHeight();
    }

    /// Within a pixel where FreeType's rounding of the line height allows: tried in steps of
    /// a quarter of a pixel of em from the size the font's units give.
    pub fn sizeToLineHeight(self: Face, target: f32) ?f32 {
        const ft = self.ft;
        if (ft.*.face_flags & c.FT_FACE_FLAG_SCALABLE == 0) return null;
        const upem: f32 = @floatFromInt(ft.*.units_per_EM);
        var units: f32 = @floatFromInt(ft.*.height);
        if (units <= 0) units = @floatFromInt(@as(i32, ft.*.ascender) - ft.*.descender);
        if (units <= 0 or upem <= 0) return null;
        // Size in 26.6 points at 72 dpi = pixels per em in 26.6.
        var size: c.FT_F26Dot6 = @intFromFloat(@round(target * 64.0 * upem / units));
        var best_size = size;
        var best_err: f32 = std.math.inf(f32);
        for (0..12) |_| {
            if (size <= 0 or c.FT_Set_Char_Size(ft, 0, size, 72, 72) != 0) break;
            const lh = self.lineHeight();
            const err = lh - target;
            if (@abs(err) < @abs(best_err)) {
                best_err = err;
                best_size = size;
            }
            if (@abs(err) <= 0.5) break;
            size += if (err > 0) -16 else 16;
        }
        if (c.FT_Set_Char_Size(ft, 0, best_size, 72, 72) != 0) return null;
        return self.lineHeight();
    }
};

// ---- HarfBuzz and FriBidi, loaded at run time ----

const HbFont = opaque {};
const HbBuffer = opaque {};
/// hb_glyph_info_t and hb_glyph_position_t (hb-buffer.h).
const HbGlyphInfo = extern struct { codepoint: u32, mask: u32, cluster: u32, var1: u32, var2: u32 };
const HbGlyphPosition = extern struct { x_advance: i32, y_advance: i32, x_offset: i32, y_offset: i32, v: u32 };
const hb_direction_ltr: c_uint = 4;
const hb_direction_rtl: c_uint = 5;

/// The functions used, looked up by their field names.
const HarfBuzz = struct {
    hb_ft_font_create_referenced: *const fn (c.FT_Face) callconv(.c) ?*HbFont,
    hb_ft_font_set_load_flags: *const fn (*HbFont, c_int) callconv(.c) void,
    hb_font_destroy: *const fn (*HbFont) callconv(.c) void,
    hb_buffer_create: *const fn () callconv(.c) ?*HbBuffer,
    hb_buffer_allocation_successful: *const fn (*HbBuffer) callconv(.c) c_int,
    hb_buffer_destroy: *const fn (*HbBuffer) callconv(.c) void,
    hb_buffer_clear_contents: *const fn (*HbBuffer) callconv(.c) void,
    hb_buffer_add_codepoints: *const fn (*HbBuffer, [*]const u32, c_int, c_uint, c_int) callconv(.c) void,
    hb_buffer_set_direction: *const fn (*HbBuffer, c_uint) callconv(.c) void,
    hb_buffer_guess_segment_properties: *const fn (*HbBuffer) callconv(.c) void,
    hb_shape: *const fn (*HbFont, *HbBuffer, ?*const anyopaque, c_uint) callconv(.c) void,
    hb_buffer_get_glyph_infos: *const fn (*HbBuffer, *c_uint) callconv(.c) ?[*]HbGlyphInfo,
    hb_buffer_get_glyph_positions: *const fn (*HbBuffer, *c_uint) callconv(.c) ?[*]HbGlyphPosition,
};

const FriBidi = struct {
    fribidi_get_bidi_types: *const fn ([*]const u32, c_int, [*]u32) callconv(.c) void,
    fribidi_get_bracket_types: *const fn ([*]const u32, c_int, [*]const u32, [*]u32) callconv(.c) void,
    fribidi_get_par_embedding_levels_ex: *const fn ([*]const u32, [*]const u32, c_int, *u32, [*]i8) callconv(.c) i8,
    fribidi_reorder_line: *const fn (u32, [*]const u32, c_int, c_int, u32, [*]i8, ?[*]u32, ?[*]c_int) callconv(.c) i8,
};

/// The libraries loaded (`shaping`).
pub const Shaping = struct { hb: HarfBuzz, fb: FriBidi };

/// The file names HarfBuzz and FriBidi are opened by on this system, tried in order (the
/// first that opens is used). A system with no names here draws that text unshaped.
const harfbuzz_names: []const [:0]const u8 = switch (builtin.os.tag) {
    .linux => &.{"libharfbuzz.so.0"},
    // Homebrew's (Apple silicon: /opt/homebrew), then by name (found on dyld's paths).
    .macos => &.{ "/opt/homebrew/lib/libharfbuzz.0.dylib", "libharfbuzz.0.dylib" },
    else => &.{},
};
const fribidi_names: []const [:0]const u8 = switch (builtin.os.tag) {
    .linux => &.{"libfribidi.so.0"},
    .macos => &.{ "/opt/homebrew/lib/libfribidi.0.dylib", "libfribidi.0.dylib" },
    else => &.{},
};

/// 0: not tried, 1: loading, 2: loaded, 3: missing.
var libs_state: std.atomic.Value(u8) = .init(0);
var libs_value: Shaping = undefined;

/// HarfBuzz and FriBidi, loaded the first time this is called (from any thread); null if
/// either library or one of its functions is missing (logged once).
pub fn shaping() ?*const Shaping {
    while (true) switch (libs_state.load(.acquire)) {
        2 => return &libs_value,
        3 => return null,
        1 => std.atomic.spinLoopHint(),
        else => if (libs_state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
            const ok = load(HarfBuzz, harfbuzz_names, &libs_value.hb) and load(FriBidi, fribidi_names, &libs_value.fb);
            libs_state.store(if (ok) 2 else 3, .release);
        },
    };
}

/// Opens the first of `names` that opens (kept open for good) and looks up every function
/// of `T` in it.
fn load(comptime T: type, comptime names: []const [:0]const u8, out: *T) bool {
    const hint = "Persian and other right-to-left or joined scripts are drawn unshaped, left to right (install harfbuzz and fribidi)";
    inline for (names) |name| {
        if (std.DynLib.open(name)) |opened| {
            var lib = opened;
            const info = @typeInfo(T).@"struct";
            inline for (info.field_names, info.field_types) |field, FieldType| {
                @field(out, field) = lib.lookup(FieldType, field) orelse {
                    log.warn(name ++ " has no " ++ field ++ ": " ++ hint, .{});
                    lib.close();
                    return false;
                };
            }
            return true;
        } else |_| {}
    }
    log.warn("cannot load " ++ comptime orList(names) ++ ": " ++ hint, .{});
    return false;
}

/// "a", "a or b", ...: the names of a list, for a message.
fn orList(comptime names: []const [:0]const u8) []const u8 {
    var s: []const u8 = "";
    for (names, 0..) |name, k| s = s ++ (if (k > 0) " or " else "") ++ name;
    return s;
}

// ---- Bidi ----

/// FriBidi's types are the values of `text_backend.bidi` as they are.
pub fn bidiTypes(l: *const Shaping, cps: []const u32, types: []u32) void {
    l.fb.fribidi_get_bidi_types(cps.ptr, @intCast(cps.len), types.ptr);
}

// ---- An engine's fonts, fallbacks and layout ----

/// Fonts one engine may hold: the primary, the named fallbacks, and those found for single
/// characters.
pub const max_faces = 8;
const no_face: u8 = 0xff;

/// The fallbacks tried, in order, for characters the primary font lacks. In each group the
/// first one installed is used.
const named_fallbacks = switch (builtin.os.tag) {
    // What macOS installs by default, in /System/Library/Fonts. Chinese: Hiragino Sans GB (a
    // sans-serif for Simplified Chinese; its regular weight is the collection's first face),
    // then Heiti SC (STHeiti, the second face of its collection). Not PingFang SC, macOS's
    // own Chinese font: the interface's copy (PingFangUI.ttc) has only Apple's `hvgl`
    // outlines, which FreeType cannot read, and the one FreeType reads is a font asset
    // macOS downloads (/System/Library/AssetsV2), not part of the system itself.
    // Persian/Arabic: Geeza Pro (macOS's Arabic-script font of the interface before SF
    // Arabic, which is hidden from lookups by family), then Damascus; both have the Persian
    // letters and digits.
    .macos => [_]struct { what: []const u8, families: []const [:0]const u8 }{
        .{ .what = "Simplified Chinese", .families = &.{ "Hiragino Sans GB", "Heiti SC" } },
        .{ .what = "Persian/Arabic", .families = &.{ "Geeza Pro", "Damascus" } },
    },
    else => [_]struct { what: []const u8, families: []const [:0]const u8 }{
        // fontconfig's default for zh may be the JP face of the same collection, so SC is named.
        .{ .what = "Simplified Chinese", .families = &.{"Noto Sans CJK SC"} },
        .{ .what = "Persian/Arabic", .families = &.{ "Vazirmatn", "Noto Sans Arabic" } },
    },
};

/// Marks, joiners and controls: drawn with the font of the character before them.
fn isMark(cp: u32) bool {
    return (cp >= 0x0300 and cp <= 0x036F) or (cp >= 0x0483 and cp <= 0x0489) or
        (cp >= 0x0591 and cp <= 0x05C7) or (cp >= 0x0610 and cp <= 0x061A) or
        (cp >= 0x064B and cp <= 0x065F) or cp == 0x0670 or (cp >= 0x06D6 and cp <= 0x06ED) or
        (cp >= 0x200B and cp <= 0x200F) or (cp >= 0x202A and cp <= 0x202E) or
        (cp >= 0x2060 and cp <= 0x206F) or (cp >= 0xFE00 and cp <= 0xFE0F) or
        (cp >= 0xFE20 and cp <= 0xFE2F) or cp == 0xFEFF;
}

/// Spaces and punctuation: drawn with the font of the text around them if it has them.
fn isNeutral(cp: u32) bool {
    if (cp < 0x80) return !std.ascii.isAlphanumeric(@intCast(cp));
    return (cp >= 0xA0 and cp <= 0xBF) or (cp >= 0x2000 and cp <= 0x206F) or
        cp == 0x060C or cp == 0x061B or cp == 0x061F or (cp >= 0x066A and cp <= 0x066D) or
        cp == 0x06D4 or (cp >= 0x3000 and cp <= 0x303F) or (cp >= 0xFF00 and cp <= 0xFF0F);
}

/// A run of one bidi level, in logical order: `text[start..end]`.
pub const Run = struct { start: u32, end: u32, level: i8 };

/// The fonts of one engine and the laying out of its strings. Faces are found in this
/// order: the primary, the named fallbacks (`named_fallbacks`, loaded at `init`), then the
/// font the lookup offers for a character none of those has (loaded when first needed).
/// Every fallback is scaled so that its capitals (or alef) stand as tall as the primary's,
/// or, where either has none to measure, so that its line is as high.
pub const Fonts = struct {
    gpa: std.mem.Allocator,
    lib: Library,
    /// The font lookup the fallbacks are found with, kept for the engine's life.
    matcher: fontfind.Matcher,
    faces: [max_faces]FontFace = undefined,
    nfaces: u8 = 0,
    /// `faces[0..named]`: the primary and the named fallbacks; later ones were found for a
    /// single character.
    named: u8 = 0,
    /// The primary's line height (a fallback without a capital letter is scaled to it).
    line_height: f32,
    /// The height of the primary's capitals in pixels, which the fallbacks' capitals (or
    /// alef) are scaled to, so their letters stand as tall as the primary's (null: the
    /// primary has none; line heights are matched instead).
    cap_px: ?f32 = null,
    /// Characters none of the named fonts has: the font fontconfig found for each
    /// (`no_face`: none).
    best: std.AutoHashMapUnmanaged(u21, u8) = .empty,
    /// HarfBuzz's buffer, made the first time something is shaped.
    buf: ?*HbBuffer = null,
    // Scratch, reused from string to string.
    types: std.ArrayList(u32) = .empty,
    brackets: std.ArrayList(u32) = .empty,
    levels: std.ArrayList(i8) = .empty,
    runs: std.ArrayList(Run) = .empty,
    order: std.ArrayList(u32) = .empty,
    items: std.ArrayList(Item) = .empty,

    pub const FontFace = struct {
        face: Face,
        /// Pixels from the top of one line to the next, at the size it is set to.
        line_height: f32,
    };
    const Item = struct { start: u32, end: u32, face: u8 };

    /// Takes `lib` and `primary`, set to `px` pixels with line height `line_height`.
    pub fn init(gpa: std.mem.Allocator, lib: Library, primary: Face, px: u32, line_height: f32) Fonts {
        var self: Fonts = .{
            .gpa = gpa,
            .lib = lib,
            .matcher = .init(),
            .line_height = line_height,
        };
        self.faces[0] = .{ .face = primary, .line_height = line_height };
        self.nfaces = 1;
        if (capRatio(&primary)) |r| self.cap_px = r * @as(f32, @floatFromInt(px));
        for (named_fallbacks) |fb| {
            for (fb.families) |family| {
                var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
                const m = self.matcher.match(family, family, &path_buf) orelse continue;
                if (self.addFace(m.path, m.index)) |at| {
                    log.info("{s}: {s} (face {d}) at {d:.1} px line height", .{ fb.what, m.path, m.index, self.faces[at].line_height });
                    break;
                }
            } else log.warn("no {s} font ({s}): those characters draw as the missing glyph", .{ fb.what, fb.families[fb.families.len - 1] });
        }
        self.named = self.nfaces;
        return self;
    }

    pub fn deinit(self: *Fonts) void {
        const gpa = self.gpa;
        for (self.faces[0..self.nfaces]) |face| face.face.deinit();
        // The buffer exists only if the libraries were loaded.
        if (self.buf) |buf| libs_value.hb.hb_buffer_destroy(buf);
        self.lib.deinit();
        self.matcher.deinit();
        self.best.deinit(gpa);
        inline for (.{ "types", "brackets", "levels", "runs", "order", "items" }) |name| {
            @field(self, name).deinit(gpa);
        }
    }

    pub fn glyphIndex(self: *const Fonts, face: u8, cp: u32) u32 {
        return self.faces[face].face.glyphIndex(cp);
    }

    pub fn covers(self: *const Fonts, face: u8, cp: u32) bool {
        return self.glyphIndex(face, cp) != 0;
    }

    pub fn render(self: *const Fonts, face: u8, gid: u32) ?Coverage {
        return self.faces[face].face.render(gid);
    }

    /// The height of face `k`'s capitals (or alef) in pixels at its size; null if it has
    /// none to measure (for tests: the fallbacks' letters against the primary's).
    pub fn capPx(self: *const Fonts, k: u8) ?f32 {
        const face = &self.faces[k].face;
        return (capRatio(face) orelse return null) * @as(f32, @floatFromInt(face.ppem()));
    }

    /// Loads face `index` of `path`, scaled to the primary, as the next font. Its index in
    /// `faces`, or null (no room, cannot load, not scalable).
    fn addFace(self: *Fonts, path: [:0]const u8, index: c_int) ?u8 {
        if (self.nfaces >= max_faces) return null;
        const face = Face.open(self.lib, path, index) catch return null;
        const lh = (if (self.cap_px) |cap| scaleToCapHeight(&face, cap) else null) orelse face.sizeToLineHeight(self.line_height) orelse {
            face.deinit();
            return null;
        };
        const at = self.nfaces;
        self.faces[at] = .{ .face = face, .line_height = lh };
        self.nfaces += 1;
        return at;
    }

    /// Which font draws `cp`, after a character drawn with `current`.
    fn faceFor(self: *Fonts, cp: u32, current: ?u8) u8 {
        if (current) |f| {
            if (isMark(cp)) return f;
            if (isNeutral(cp) and self.covers(f, cp)) return f;
        }
        for (0..self.named) |k| if (self.covers(@intCast(k), cp)) return @intCast(k);
        const cp21: u21 = std.math.cast(u21, cp) orelse return 0;
        const found = self.best.get(cp21) orelse blk: {
            const f = self.findFor(cp);
            self.best.put(self.gpa, cp21, f) catch {};
            break :blk f;
        };
        return if (found == no_face) 0 else found;
    }

    /// fontconfig's best match for `cp`, loaded if it is not yet; `no_face` if there is
    /// none that has it.
    fn findFor(self: *Fonts, cp: u32) u8 {
        // Already loaded (a font found for another character)?
        for (self.named..self.nfaces) |k| {
            if (self.covers(@intCast(k), cp)) return @intCast(k);
        }
        var want_buf: [48:0]u8 = undefined;
        const want = std.fmt.bufPrintSentinel(&want_buf, "sans-serif:charset={x}", .{cp}, 0) catch return no_face;
        var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        const m = self.matcher.match(want, null, &path_buf) orelse return no_face;
        const at = self.addFace(m.path, m.index) orelse return no_face;
        // Kept if it does not have it after all (it is loaded), but no help with this one.
        if (!self.covers(at, cp)) return no_face;
        log.info("U+{X:0>4} from {s}", .{ cp, m.path });
        return at;
    }

    /// One glyph per code point, from the font that has it, in logical order.
    pub fn mapSimple(self: *Fonts, cps: []const u32, out: *std.ArrayList(text_backend.FaceGlyph)) !void {
        var current: ?u8 = null;
        for (cps) |cp| {
            const f = self.faceFor(cp, current);
            current = f;
            try out.append(self.gpa, .{ .face = f, .gid = self.glyphIndex(f, cp) });
        }
    }

    /// FriBidi's levels, the runs in visual order, each split by font and shaped by
    /// HarfBuzz.
    pub fn layout(self: *Fonts, l: *const Shaping, text: []const u32, marks: []const bool, base_in: u32, out: *std.ArrayList(RunGlyph)) !void {
        const gpa = self.gpa;
        var base = base_in;
        const n: c_int = @intCast(text.len);
        try self.types.resize(gpa, text.len);
        try self.brackets.resize(gpa, text.len);
        try self.levels.resize(gpa, text.len);
        l.fb.fribidi_get_bidi_types(text.ptr, n, self.types.items.ptr);
        l.fb.fribidi_get_bracket_types(text.ptr, n, self.types.items.ptr, self.brackets.items.ptr);
        if (l.fb.fribidi_get_par_embedding_levels_ex(self.types.items.ptr, self.brackets.items.ptr, n, &base, self.levels.items.ptr) == 0) return error.Bidi;
        // Rule L1 (trailing white space to the paragraph's level); the order is done below.
        if (l.fb.fribidi_reorder_line(0, self.types.items.ptr, n, 0, base, self.levels.items.ptr, null, null) == 0) return error.Bidi;

        try runsOf(gpa, self.levels.items, marks, &self.runs);
        try visualOrder(gpa, self.runs.items, &self.order);

        for (self.order.items) |ri| {
            const run = self.runs.items[ri];
            const rtl = run.level & 1 == 1;
            // The run split by font, in logical order.
            self.items.clearRetainingCapacity();
            var current: ?u8 = null;
            var start = run.start;
            for (run.start..run.end) |k| {
                const f = self.faceFor(text[k], current);
                if (current != null and f != current.?) {
                    try self.items.append(gpa, .{ .start = start, .end = @intCast(k), .face = current.? });
                    start = @intCast(k);
                }
                current = f;
            }
            try self.items.append(gpa, .{ .start = start, .end = run.end, .face = current.? });
            // Right to left, the pieces go from the right.
            for (0..self.items.items.len) |j| {
                const item = self.items.items[if (rtl) self.items.items.len - 1 - j else j];
                try self.shapeItem(l, text, item, rtl, out);
            }
        }
    }

    /// Shapes one piece of one run with its font, appends its glyphs to `out`.
    fn shapeItem(self: *Fonts, l: *const Shaping, text: []const u32, item: Item, rtl: bool, out: *std.ArrayList(RunGlyph)) !void {
        const hb = &l.hb;
        const buf = self.buf orelse blk: {
            const b = hb.hb_buffer_create() orelse return error.HarfBuzz;
            if (hb.hb_buffer_allocation_successful(b) == 0) {
                hb.hb_buffer_destroy(b);
                return error.HarfBuzz;
            }
            self.buf = b;
            break :blk b;
        };
        const face = &self.faces[item.face].face;
        const hb_font = face.hb orelse blk: {
            const f = hb.hb_ft_font_create_referenced(face.ft) orelse return error.HarfBuzz;
            // Hinted advances, as FreeType gives the fixed glyphs.
            hb.hb_ft_font_set_load_flags(f, c.FT_LOAD_DEFAULT);
            face.hb = f;
            break :blk f;
        };
        hb.hb_buffer_clear_contents(buf);
        hb.hb_buffer_add_codepoints(buf, text.ptr, @intCast(text.len), item.start, @intCast(item.end - item.start));
        hb.hb_buffer_set_direction(buf, if (rtl) hb_direction_rtl else hb_direction_ltr);
        hb.hb_buffer_guess_segment_properties(buf);
        hb.hb_shape(hb_font, buf, null, 0);
        var count: c_uint = 0;
        const infos = hb.hb_buffer_get_glyph_infos(buf, &count) orelse return;
        const positions = hb.hb_buffer_get_glyph_positions(buf, &count) orelse return;
        for (infos[0..count], positions[0..count]) |info, pos| {
            try out.append(self.gpa, .{
                .face = item.face,
                .gid = info.codepoint,
                .x_offset = px26(pos.x_offset),
                .y_offset = px26(pos.y_offset),
                .x_advance = px26(pos.x_advance),
            });
        }
    }
};

/// 26.6 fixed point to pixels.
fn px26(v: i32) f32 {
    return @as(f32, @floatFromInt(v)) / 64.0;
}

/// The height of `face`'s capital H, or of its alef where it has no Latin (an Arabic-script
/// font: alef stands as tall as a capital), as a fraction of its em; null if it has
/// neither or is not scalable.
fn capRatio(face: *const Face) ?f32 {
    for ([_]u32{ 'H', 0x0627 }) |cp| {
        if (face.heightRatio(cp)) |r| return r;
    }
    return null;
}

/// Sets `face`'s size so that its capitals (`capRatio`) are `cap_px` pixels tall; its line
/// height at that size, or null (no capital to measure: the caller matches line heights).
/// A font whose line is taller than the primary's for its letters (Arabic-script fonts
/// leave room for vowel marks) is then not shrunk to fit the primary's line.
fn scaleToCapHeight(face: *const Face, cap_px: f32) ?f32 {
    const r = capRatio(face) orelse return null;
    return face.setEmSize(cap_px / r);
}

/// Runs of one level, in logical order, leaving out the characters flagged in `marks`.
fn runsOf(gpa: std.mem.Allocator, levels: []const i8, marks: []const bool, runs: *std.ArrayList(Run)) !void {
    runs.clearRetainingCapacity();
    var i: usize = 0;
    while (i < levels.len) {
        if (marks[i]) {
            i += 1;
            continue;
        }
        const start = i;
        const level = levels[i];
        while (i < levels.len and !marks[i] and levels[i] == level) i += 1;
        try runs.append(gpa, .{ .start = @intCast(start), .end = @intCast(i), .level = level });
    }
}

/// The runs' visual order, left to right (rule L2: from the highest level down to the
/// lowest odd one, each stretch of runs at that level or above is reversed).
fn visualOrder(gpa: std.mem.Allocator, runs: []const Run, order: *std.ArrayList(u32)) !void {
    order.clearRetainingCapacity();
    var max: i8 = 0;
    var min_odd: i8 = std.math.maxInt(i8);
    for (runs, 0..) |r, k| {
        try order.append(gpa, @intCast(k));
        max = @max(max, r.level);
        if (r.level & 1 == 1) min_odd = @min(min_odd, r.level);
    }
    if (min_odd == std.math.maxInt(i8)) return;
    const o = order.items;
    var level = max;
    while (level >= min_odd) : (level -= 1) {
        var j: usize = 0;
        while (j < o.len) {
            if (runs[o[j]].level < level) {
                j += 1;
                continue;
            }
            var k = j;
            while (k < o.len and runs[o[k]].level >= level) k += 1;
            std.mem.reverse(u32, o[j..k]);
            j = k;
        }
    }
}

// ---- Tests ----

const testing = std.testing;

fn skipBecause(comptime why: []const u8) error{SkipZigTest} {
    std.debug.print("skipped: " ++ why ++ "\n", .{});
    return error.SkipZigTest;
}

fn needLibs() !*const Shaping {
    return shaping() orelse skipBecause("HarfBuzz or FriBidi not installed");
}

test "the bidi types declared here are FriBidi's" {
    const bidi = text_backend.bidi;
    const l = try needLibs();
    const cps = [_]u32{ 'a', 0x5d0, 0x641, '3', '-', '%', 0x64b, '\n' };
    const want = [_]u32{ bidi.L, bidi.R, bidi.AL, bidi.EN, bidi.ES, bidi.ET, bidi.NSM, bidi.BS };
    var got: [cps.len]u32 = undefined;
    l.fb.fribidi_get_bidi_types(&cps, cps.len, &got);
    try testing.expectEqualSlices(u32, &want, &got);
}

test "a missing library, or a missing function in one, is reported as missing" {
    const One = struct { hb_buffer_create: *const fn () callconv(.c) ?*HbBuffer };
    const Missing = struct { hb_no_such_function: *const fn () callconv(.c) void };
    var one: One = undefined;
    var missing: Missing = undefined;
    try testing.expect(!load(One, &.{"libdimna-no-such-library.so.0"}, &one));
    try testing.expect(!load(Missing, harfbuzz_names, &missing));
    _ = try needLibs();
    try testing.expect(load(One, harfbuzz_names, &one));
    // The names are tried in order: one that does not open is passed over.
    try testing.expect(load(One, &[_][:0]const u8{"libdimna-no-such-library.so.0"} ++ harfbuzz_names, &one));
}

test "runs are put in visual order by rule L2" {
    const gpa = testing.allocator;
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(gpa);
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(gpa);
    // Levels 1 1 2 _ 2 1 0 0, an isolate mark between the 2s.
    const levels = [_]i8{ 1, 1, 2, 2, 2, 1, 0, 0 };
    const marks = [_]bool{ false, false, false, true, false, false, false, false };
    try runsOf(gpa, &levels, &marks, &runs);
    try testing.expectEqual(5, runs.items.len);
    try testing.expectEqual(Run{ .start = 0, .end = 2, .level = 1 }, runs.items[0]);
    try testing.expectEqual(Run{ .start = 2, .end = 3, .level = 2 }, runs.items[1]);
    try testing.expectEqual(Run{ .start = 4, .end = 5, .level = 2 }, runs.items[2]);
    try visualOrder(gpa, runs.items, &order);
    // Level 2 first: [1 2] -> [2 1]; then level >= 1: [0 2 1 3] -> [3 1 2 0]; level 0 stays.
    try testing.expectEqualSlices(u32, &.{ 3, 1, 2, 0, 4 }, order.items);
    // No odd level: as they are.
    const ltr = [_]i8{ 0, 0, 2, 2 };
    try runsOf(gpa, &ltr, &.{ false, false, false, false }, &runs);
    try visualOrder(gpa, runs.items, &order);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, order.items);
}
