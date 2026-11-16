//! Text beyond the font's fixed glyphs (`font.zig`). Every such string is split by which
//! font has its characters (the primary font, then the named fallbacks, then whatever
//! fontconfig offers for the character), and its glyphs are rasterised into the atlas the
//! first time they are drawn. Latin Extended, Chinese and the like need nothing more: one
//! glyph per code point, left to right, as the fixed glyphs are laid out.
//!
//! A string with a character of a right-to-left or joined script (Persian, Hebrew, the
//! Indic scripts; combining marks) is also shaped: FriBidi puts its runs in visual order and
//! HarfBuzz shapes each piece. Neither library is linked: both are loaded with dlopen the
//! first time such a string is drawn (`libs`). Without them that text is laid out unshaped,
//! left to right, and one line in the log says so.
//!
//! The result is kept in a cache of laid-out strings, so a label drawn every frame is laid
//! out once.
//!
//! The paragraph direction of a shaped string is a setting of the engine (`Engine.rtl`),
//! chosen at start-up from the language (`start_rtl`). In a language read right to left,
//! every string with a right-to-left letter is laid out right to left, whatever comes first
//! ("{source} ..." with a Latin name first, a number first). Otherwise the direction is
//! that of the string's first strong letter (taken before the isolation below, which would
//! hide the Latin letters from FriBidi's own rule). Numbers and
//! Latin text inside right-to-left text ("فیلتر 300-6000 Hz") are kept together as one
//! left-to-right block: each stretch from a Latin letter or a digit to the last Latin letter
//! or digit before the next right-to-left letter is isolated (as if between U+2066 and
//! U+2069). Plain Unicode bidi would otherwise turn the digits after an Arabic-script letter
//! into Arabic numbers and draw "300-6000" as "6000-300".

const std = @import("std");
const builtin = @import("builtin");
const c = @import("gui_c");
const font = @import("font.zig");
const fontfind = @import("fontfind.zig");
const log = std.log.scoped(.font);

/// Fonts one engine may hold: the primary, the named fallbacks, and those found for single
/// characters.
pub const max_faces = 8;
/// Laid-out strings kept (least recently used out).
pub const cache_entries = 2048;
const no_face: u8 = 0xff;

/// The paragraph direction of the engines made from now on (`Engine.rtl`). Set once at
/// start-up, from the language, before any font is made.
pub var start_rtl: bool = false;

/// The fallbacks tried, in order, for characters the primary font lacks. In each group the
/// first one installed is used.
const named_fallbacks = [_]struct { what: []const u8, families: []const [:0]const u8 }{
    // fontconfig's default for zh may be the JP face of the same collection, so SC is named.
    .{ .what = "Simplified Chinese", .families = &.{"Noto Sans CJK SC"} },
    .{ .what = "Persian/Arabic", .families = &.{ "Vazirmatn", "Noto Sans Arabic" } },
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

/// FriBidiCharType values (fribidi-bidi-types.h: the masks combined as there).
const bidi = struct {
    const L: u32 = 0x110;
    const R: u32 = 0x111;
    const AL: u32 = 0x113;
    const EN: u32 = 0x220;
    const ES: u32 = 0x10420;
    const ET: u32 = 0x20420;
    const NSM: u32 = 0x80020;
    const BS: u32 = 0x202840;
    /// FRIBIDI_PAR_ON: the direction from the first strong character.
    const par_on: u32 = 0x40;
    /// FRIBIDI_PAR_LTR and FRIBIDI_PAR_RTL (the types of L and R).
    const par_ltr: u32 = L;
    const par_rtl: u32 = R;
};

const FriBidi = struct {
    fribidi_get_bidi_types: *const fn ([*]const u32, c_int, [*]u32) callconv(.c) void,
    fribidi_get_bracket_types: *const fn ([*]const u32, c_int, [*]const u32, [*]u32) callconv(.c) void,
    fribidi_get_par_embedding_levels_ex: *const fn ([*]const u32, [*]const u32, c_int, *u32, [*]i8) callconv(.c) i8,
    fribidi_reorder_line: *const fn (u32, [*]const u32, c_int, c_int, u32, [*]i8, ?[*]u32, ?[*]c_int) callconv(.c) i8,
};

pub const Libs = struct { hb: HarfBuzz, fb: FriBidi };

/// The file names HarfBuzz and FriBidi are opened by on this system, tried in order (the
/// first that opens is used). A system with no names here draws that text unshaped.
const harfbuzz_names: []const [:0]const u8 = switch (builtin.os.tag) {
    .linux => &.{"libharfbuzz.so.0"},
    else => &.{},
};
const fribidi_names: []const [:0]const u8 = switch (builtin.os.tag) {
    .linux => &.{"libfribidi.so.0"},
    else => &.{},
};

/// 0: not tried, 1: loading, 2: loaded, 3: missing.
var libs_state: std.atomic.Value(u8) = .init(0);
var libs_value: Libs = undefined;

/// HarfBuzz and FriBidi, loaded the first time this is called (from any thread); null if
/// either library or one of its functions is missing (logged once).
pub fn libs() ?*const Libs {
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

/// True for a code point that has to be shaped: right-to-left and joined scripts, the
/// Indic and South-East Asian ones, combining marks, joiners and bidi controls.
fn needsShaping(cp: u32) bool {
    return (cp >= 0x0300 and cp <= 0x036F) or // combining diacritical marks
        (cp >= 0x0483 and cp <= 0x0489) or
        (cp >= 0x0590 and cp <= 0x109F) or // Hebrew, Arabic, Syriac, ..., Indic, Thai, Tibetan, Myanmar
        (cp >= 0x1700 and cp <= 0x18AF) or // Philippine scripts, Khmer, Mongolian
        (cp >= 0x1A00 and cp <= 0x1CFF) or
        (cp >= 0x1DC0 and cp <= 0x1DFF) or
        (cp >= 0x200C and cp <= 0x200F) or // joiners, directional marks
        (cp >= 0x202A and cp <= 0x202E) or
        (cp >= 0x2066 and cp <= 0x2069) or
        (cp >= 0x20D0 and cp <= 0x20FF) or
        (cp >= 0xA800 and cp <= 0xABFF) or
        (cp >= 0xFB1D and cp <= 0xFDFF) or // Hebrew and Arabic presentation forms
        (cp >= 0xFE00 and cp <= 0xFE0F) or
        (cp >= 0xFE20 and cp <= 0xFE2F) or
        (cp >= 0xFE70 and cp <= 0xFEFF) or
        (cp >= 0x10800 and cp <= 0x11FFF) or
        (cp >= 0x1E800 and cp <= 0x1EFFF);
}

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

// ---- The engine ----

/// A glyph placed in a laid-out string: `x` pixels right of the string's origin (the pen
/// plus HarfBuzz's offset), `y` pixels above its baseline.
pub const Placed = struct {
    g: font.Glyph,
    x: i32,
    y: i32,
    /// Which font (index into `Engine.faces`) and which glyph of it.
    face: u8,
    gid: u32,
};

pub const Shaped = struct {
    glyphs: []const Placed,
    /// Pixels from the origin to the pen after the last glyph.
    width: f32,
};

const Face = struct {
    ft: c.FT_Face,
    /// Made the first time this font shapes something.
    hb: ?*HbFont = null,
    /// Pixels from the top of one line to the next, at the size it is set to.
    line_height: f32,
};

pub const Engine = struct {
    gpa: std.mem.Allocator,
    lib: c.FT_Library,
    /// The font lookup the fallbacks are found with, kept for the engine's life.
    matcher: fontfind.Matcher,
    faces: [max_faces]Face = undefined,
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
    /// Rasterised glyphs by (font, glyph index).
    glyphs: std.AutoHashMapUnmanaged(u64, font.Glyph) = .empty,
    /// Characters none of the named fonts has: the font fontconfig found for each
    /// (`no_face`: none).
    best: std.AutoHashMapUnmanaged(u21, u8) = .empty,
    /// Where the next glyph goes in the atlas.
    pen: font.Font.Pen,
    /// Rows of the atlas changed since `takeDirty`: [first, end).
    dirty: ?[2]u32 = null,
    /// The atlas had no room for a glyph (logged once).
    full: bool = false,
    full_warnings: u32 = 0,
    /// The primary font's missing glyph, drawn for a glyph that does not fit.
    notdef: font.Glyph = .{},
    /// Strings laid out (cache misses), and of them shaped: for tests and the benchmark.
    shape_calls: usize = 0,
    shaped_calls: usize = 0,
    /// False: never shape (tests of the path taken without HarfBuzz and FriBidi).
    allow_shaping: bool = true,
    /// A string with a right-to-left letter is laid out with a right-to-left paragraph
    /// direction (the language is read right to left); false: the direction of its first
    /// strong letter. Fixed when the engine is made (`start_rtl`), as the cache holds
    /// strings laid out with it.
    rtl: bool,
    /// HarfBuzz's buffer, made the first time something is shaped.
    buf: ?*HbBuffer = null,
    cache: Cache = .{},
    // Scratch, reused from string to string.
    raw: std.ArrayList(u32) = .empty,
    raw_types: std.ArrayList(u32) = .empty,
    text: std.ArrayList(u32) = .empty,
    marks: std.ArrayList(bool) = .empty,
    types: std.ArrayList(u32) = .empty,
    brackets: std.ArrayList(u32) = .empty,
    levels: std.ArrayList(i8) = .empty,
    runs: std.ArrayList(Run) = .empty,
    order: std.ArrayList(u32) = .empty,
    items: std.ArrayList(Item) = .empty,
    out: std.ArrayList(Placed) = .empty,

    const Run = struct { start: u32, end: u32, level: i8 };
    const Item = struct { start: u32, end: u32, face: u8 };

    /// Takes `lib` and `primary` (set to the font's size) on success; on failure the caller
    /// still owns them. `f`: the font whose atlas and fixed glyphs this engine extends.
    pub fn create(gpa: std.mem.Allocator, lib: c.FT_Library, primary: c.FT_Face, f: *const font.Font) !*Engine {
        const self = try gpa.create(Engine);
        self.* = .{
            .gpa = gpa,
            .lib = lib,
            .matcher = .init(),
            .line_height = f.line_height,
            .pen = f.pen,
            .rtl = start_rtl,
        };
        self.faces[0] = .{ .ft = primary, .line_height = f.line_height };
        self.nfaces = 1;
        if (capRatio(primary)) |r| self.cap_px = r * @as(f32, @floatFromInt(f.px));
        // The fixed glyphs the primary font drew are the same glyphs by index.
        for (f.glyphs, 0..) |g, k| {
            if (g.advance <= 0) continue;
            const gid = c.FT_Get_Char_Index(primary, font.Font.codepointAt(k));
            if (gid == 0) continue;
            self.glyphs.put(gpa, key(0, gid), g) catch {};
        }
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
        self.notdef = self.glyph(f.atlas, 0, 0);
        return self;
    }

    pub fn destroy(self: *Engine) void {
        const gpa = self.gpa;
        self.cache.deinit(gpa);
        // hb objects exist only if the libraries were loaded.
        const l: ?*const Libs = if (libs_state.load(.acquire) == 2) &libs_value else null;
        for (self.faces[0..self.nfaces]) |face| {
            if (face.hb) |hb| l.?.hb.hb_font_destroy(hb);
            _ = c.FT_Done_Face(face.ft);
        }
        if (self.buf) |buf| l.?.hb.hb_buffer_destroy(buf);
        _ = c.FT_Done_FreeType(self.lib);
        self.matcher.deinit();
        self.glyphs.deinit(gpa);
        self.best.deinit(gpa);
        inline for (.{ "raw", "raw_types", "text", "marks", "types", "brackets", "levels", "runs", "order", "items", "out" }) |name| {
            @field(self, name).deinit(gpa);
        }
        gpa.destroy(self);
    }

    /// The rows of the atlas changed since the last call, if any: [first, end).
    pub fn takeDirty(self: *Engine) ?[2]u32 {
        defer self.dirty = null;
        return self.dirty;
    }

    /// `bytes` laid out, from the cache or now (its new glyphs drawn into `atlas`). Valid
    /// until the next call. Null if that failed (out of memory).
    pub fn layout(self: *Engine, atlas: []u8, bytes: []const u8) ?Shaped {
        if (self.cache.get(bytes)) |e| return .{ .glyphs = e.glyphs, .width = e.width };
        self.shape_calls += 1;
        self.out.clearRetainingCapacity();
        self.raw.clearRetainingCapacity();
        var it: font.Codepoints = .{ .bytes = bytes };
        while (it.next()) |cp| self.raw.append(self.gpa, cp) catch return null;
        const complex = for (self.raw.items) |cp| {
            if (needsShaping(cp)) break true;
        } else false;
        const shaped: ?f32 = if (complex and self.allow_shaping) if (libs()) |l| self.shape(l, atlas) catch null else null else null;
        const width = shaped orelse blk: {
            self.out.clearRetainingCapacity();
            break :blk self.simple(atlas) catch return null;
        };
        const glyphs = self.gpa.dupe(Placed, self.out.items) catch return null;
        const e = self.cache.put(self.gpa, bytes, glyphs, width) catch {
            self.gpa.free(glyphs);
            return null;
        };
        return .{ .glyphs = e.glyphs, .width = e.width };
    }

    fn key(face: u8, gid: u32) u64 {
        return @as(u64, face) << 32 | gid;
    }

    /// Glyph `gid` of font `face`, rasterised into `atlas` the first time.
    fn glyph(self: *Engine, atlas: []u8, face: u8, gid: u32) font.Glyph {
        const k = key(face, gid);
        if (self.glyphs.get(k)) |g| return g;
        const g = self.render(atlas, face, gid) catch font.Glyph{};
        self.glyphs.put(self.gpa, k, g) catch {};
        return g;
    }

    /// Rasterises a glyph into the atlas. One that does not fit is the missing glyph with
    /// its own advance (the first such is logged).
    fn render(self: *Engine, atlas: []u8, face_i: u8, gid: u32) error{NoGlyph}!font.Glyph {
        const face = self.faces[face_i].ft;
        if (c.FT_Load_Glyph(face, gid, c.FT_LOAD_RENDER) != 0) return error.NoGlyph;
        const slot = face.*.glyph;
        const bm = slot.*.bitmap;
        var g: font.Glyph = .{
            .left = @intCast(slot.*.bitmap_left),
            .top = @intCast(slot.*.bitmap_top),
            .advance = @as(f32, @floatFromInt(slot.*.advance.x)) / 64.0,
        };
        const w: usize = bm.width;
        const h: usize = bm.rows;
        // Nothing to draw (a space), or not coverage (a colour bitmap): no room taken.
        if (w == 0 or h == 0 or bm.pixel_mode != c.FT_PIXEL_MODE_GRAY) return g;
        const at = (if (self.full) null else self.pen.fit(w, h)) orelse {
            if (!self.full) {
                self.full_warnings += 1;
                log.warn("font atlas full: glyphs not yet drawn are drawn as the missing glyph", .{});
            }
            self.full = true;
            var missing = self.notdef;
            missing.advance = g.advance;
            return missing;
        };
        for (0..h) |row| {
            const src: [*]const u8 = bm.buffer + row * @as(usize, @intCast(bm.pitch));
            @memcpy(atlas[(at[1] + row) * font.atlas_size + at[0] ..][0..w], src[0..w]);
        }
        g.x = @intCast(at[0]);
        g.y = @intCast(at[1]);
        g.w = @intCast(w);
        g.h = @intCast(h);
        const rows: [2]u32 = .{ @intCast(at[1]), @intCast(at[1] + h) };
        self.dirty = if (self.dirty) |d| .{ @min(d[0], rows[0]), @max(d[1], rows[1]) } else rows;
        return g;
    }

    /// Loads face `index` of `path`, scaled to the primary's line height, as the next font.
    /// Its index in `faces`, or null (no room, cannot load, not scalable).
    fn addFace(self: *Engine, path: [:0]const u8, index: c_int) ?u8 {
        if (self.nfaces >= max_faces) return null;
        var ft: c.FT_Face = null;
        if (c.FT_New_Face(self.lib, path.ptr, index, &ft) != 0) return null;
        const lh = (if (self.cap_px) |cap| scaleToCapHeight(ft, cap) else null) orelse scaleToLineHeight(ft, self.line_height) orelse {
            _ = c.FT_Done_Face(ft);
            return null;
        };
        const at = self.nfaces;
        self.faces[at] = .{ .ft = ft, .line_height = lh };
        self.nfaces += 1;
        return at;
    }

    fn covers(self: *const Engine, face: u8, cp: u32) bool {
        return c.FT_Get_Char_Index(self.faces[face].ft, cp) != 0;
    }

    /// Which font draws `cp`, after a character drawn with `current`.
    fn faceFor(self: *Engine, cp: u32, current: ?u8) u8 {
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
    fn findFor(self: *Engine, cp: u32) u8 {
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

    /// Lays out `self.raw` into `self.out` without shaping: one glyph per code point, from
    /// the font that has it, left to right, each advance rounded as the fixed glyphs' are.
    fn simple(self: *Engine, atlas: []u8) !f32 {
        var pen: i32 = 0;
        var current: ?u8 = null;
        for (self.raw.items) |cp| {
            const f = self.faceFor(cp, current);
            current = f;
            const gid = c.FT_Get_Char_Index(self.faces[f].ft, cp);
            const g = self.glyph(atlas, f, gid);
            try self.out.append(self.gpa, .{ .g = g, .x = pen, .y = 0, .face = f, .gid = gid });
            pen += @intFromFloat(@round(g.advance));
        }
        return @floatFromInt(pen);
    }

    /// Shapes `self.raw` into `self.out` with FriBidi and HarfBuzz; returns the width.
    fn shape(self: *Engine, l: *const Libs, atlas: []u8) !f32 {
        const gpa = self.gpa;
        self.shaped_calls += 1;
        const raw = self.raw.items;
        if (raw.len == 0) return 0;
        try self.raw_types.resize(gpa, raw.len);
        l.fb.fribidi_get_bidi_types(raw.ptr, @intCast(raw.len), self.raw_types.items.ptr);
        var base = paragraphDirection(self.raw_types.items, self.rtl);
        try isolateLtr(gpa, raw, self.raw_types.items, &self.text, &self.marks);

        const text = self.text.items;
        const n: c_int = @intCast(text.len);
        try self.types.resize(gpa, text.len);
        try self.brackets.resize(gpa, text.len);
        try self.levels.resize(gpa, text.len);
        l.fb.fribidi_get_bidi_types(text.ptr, n, self.types.items.ptr);
        l.fb.fribidi_get_bracket_types(text.ptr, n, self.types.items.ptr, self.brackets.items.ptr);
        if (l.fb.fribidi_get_par_embedding_levels_ex(self.types.items.ptr, self.brackets.items.ptr, n, &base, self.levels.items.ptr) == 0) return error.Bidi;
        // Rule L1 (trailing white space to the paragraph's level); the order is done below.
        if (l.fb.fribidi_reorder_line(0, self.types.items.ptr, n, 0, base, self.levels.items.ptr, null, null) == 0) return error.Bidi;

        try runsOf(gpa, self.levels.items, self.marks.items, &self.runs);
        try visualOrder(gpa, self.runs.items, &self.order);

        var pen: i32 = 0;
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
                pen = try self.shapeItem(l, atlas, item, rtl, pen);
            }
        }
        return @floatFromInt(pen);
    }

    /// Shapes one piece of one run with its font, appends its glyphs at `pen`; returns the
    /// pen after it.
    fn shapeItem(self: *Engine, l: *const Libs, atlas: []u8, item: Item, rtl: bool, pen_in: i32) !i32 {
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
        const face = &self.faces[item.face];
        const hb_font = face.hb orelse blk: {
            const f = hb.hb_ft_font_create_referenced(face.ft) orelse return error.HarfBuzz;
            // Hinted advances, as FreeType gives the fixed glyphs.
            hb.hb_ft_font_set_load_flags(f, c.FT_LOAD_DEFAULT);
            face.hb = f;
            break :blk f;
        };
        const text = self.text.items;
        hb.hb_buffer_clear_contents(buf);
        hb.hb_buffer_add_codepoints(buf, text.ptr, @intCast(text.len), item.start, @intCast(item.end - item.start));
        hb.hb_buffer_set_direction(buf, if (rtl) hb_direction_rtl else hb_direction_ltr);
        hb.hb_buffer_guess_segment_properties(buf);
        hb.hb_shape(hb_font, buf, null, 0);
        var count: c_uint = 0;
        const infos = hb.hb_buffer_get_glyph_infos(buf, &count) orelse return pen_in;
        const positions = hb.hb_buffer_get_glyph_positions(buf, &count) orelse return pen_in;
        var pen = pen_in;
        for (infos[0..count], positions[0..count]) |info, pos| {
            const g = self.glyph(atlas, item.face, info.codepoint);
            try self.out.append(self.gpa, .{
                .g = g,
                .x = pen + round26(pos.x_offset),
                .y = round26(pos.y_offset),
                .face = item.face,
                .gid = info.codepoint,
            });
            pen += round26(pos.x_advance);
        }
        return pen;
    }
};

/// 26.6 fixed point to whole pixels, as the fixed glyphs' advances are rounded.
fn round26(v: i32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(v)) / 64.0));
}

/// Sets `ft` to the size at which its line height is nearest `target` pixels (within a
/// pixel where FreeType's rounding allows). The line height it got; null if the font cannot
/// be scaled.
/// The height of `ft`'s capital H, or of its alef where it has no Latin (an Arabic-script
/// font: alef stands as tall as a capital), as a fraction of its em; null if it has
/// neither or is not scalable.
fn capRatio(ft: c.FT_Face) ?f32 {
    if (ft.*.face_flags & c.FT_FACE_FLAG_SCALABLE == 0 or ft.*.units_per_EM == 0) return null;
    for ([_]u32{ 'H', 0x0627 }) |cp| {
        if (c.FT_Get_Char_Index(ft, cp) == 0) continue;
        if (c.FT_Load_Char(ft, cp, c.FT_LOAD_NO_SCALE) != 0) continue;
        const h: f32 = @floatFromInt(ft.*.glyph.*.metrics.height);
        if (h <= 0) continue;
        return h / @as(f32, @floatFromInt(ft.*.units_per_EM));
    }
    return null;
}

/// Sets `ft`'s size so that its capitals (`capRatio`) are `cap_px` pixels tall; its line
/// height at that size, or null (no capital to measure: the caller matches line heights).
/// A font whose line is taller than the primary's for its letters (Arabic-script fonts
/// leave room for vowel marks) is then not shrunk to fit the primary's line.
fn scaleToCapHeight(ft: c.FT_Face, cap_px: f32) ?f32 {
    const r = capRatio(ft) orelse return null;
    const size: c.FT_F26Dot6 = @intFromFloat(@round(cap_px / r * 64.0));
    if (size <= 0 or c.FT_Set_Char_Size(ft, 0, size, 72, 72) != 0) return null;
    return @as(f32, @floatFromInt(ft.*.size.*.metrics.height)) / 64.0;
}

fn scaleToLineHeight(ft: c.FT_Face, target: f32) ?f32 {
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
        const lh = @as(f32, @floatFromInt(ft.*.size.*.metrics.height)) / 64.0;
        const err = lh - target;
        if (@abs(err) < @abs(best_err)) {
            best_err = err;
            best_size = size;
        }
        if (@abs(err) <= 0.5) break;
        size += if (err > 0) -16 else 16;
    }
    if (c.FT_Set_Char_Size(ft, 0, best_size, 72, 72) != 0) return null;
    return @as(f32, @floatFromInt(ft.*.size.*.metrics.height)) / 64.0;
}

/// FriBidi's paragraph direction for a string of bidi types `types`: right to left if `rtl`
/// and it has a right-to-left letter; else that of its first strong letter (rule P2, but on
/// the string as given: explicit isolates in it are not skipped); FRIBIDI_PAR_ON if it has
/// none.
fn paragraphDirection(types: []const u32, rtl: bool) u32 {
    if (rtl) for (types) |t| {
        if (t == bidi.R or t == bidi.AL) return bidi.par_rtl;
    };
    for (types) |t| {
        if (t == bidi.L) return bidi.par_ltr;
        if (t == bidi.R or t == bidi.AL) return bidi.par_rtl;
    }
    return bidi.par_on;
}

const lri: u32 = 0x2066;
const pdi: u32 = 0x2069;

/// `raw` (bidi types `types`) into `text`, with each stretch of Latin letters and digits in
/// a string that has right-to-left letters isolated left to right (between LRI and PDI,
/// flagged in `marks`, and not drawn). A stretch starts at a letter of type L, a digit
/// (EN), or a sign before a digit, and ends at the last L or EN (or a % and the like, or a
/// mark, right after one) before the next right-to-left letter.
fn isolateLtr(gpa: std.mem.Allocator, raw: []const u32, types: []const u32, text: *std.ArrayList(u32), marks: *std.ArrayList(bool)) !void {
    text.clearRetainingCapacity();
    marks.clearRetainingCapacity();
    const rtl = for (types) |t| {
        if (t == bidi.R or t == bidi.AL) break true;
    } else false;
    var i: usize = 0;
    while (i < raw.len) {
        const t = types[i];
        const strong = t == bidi.L or t == bidi.EN;
        const sign = (t == bidi.ES or t == bidi.ET) and i + 1 < raw.len and types[i + 1] == bidi.EN;
        if (!rtl or !(strong or sign)) {
            try text.append(gpa, raw[i]);
            try marks.append(gpa, false);
            i += 1;
            continue;
        }
        var end = i + 1;
        var j = i + 1;
        while (j < raw.len) : (j += 1) {
            const tj = types[j];
            if (tj == bidi.R or tj == bidi.AL or tj == bidi.BS) break;
            if (tj == bidi.L or tj == bidi.EN or ((tj == bidi.ET or tj == bidi.NSM) and j == end)) end = j + 1;
        }
        try text.append(gpa, lri);
        try marks.append(gpa, true);
        for (raw[i..end]) |cp| {
            try text.append(gpa, cp);
            try marks.append(gpa, false);
        }
        try text.append(gpa, pdi);
        try marks.append(gpa, true);
        i = end;
    }
}

/// Runs of one level, in logical order, leaving out the characters flagged in `marks`.
fn runsOf(gpa: std.mem.Allocator, levels: []const i8, marks: []const bool, runs: *std.ArrayList(Engine.Run)) !void {
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
fn visualOrder(gpa: std.mem.Allocator, runs: []const Engine.Run, order: *std.ArrayList(u32)) !void {
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

/// Laid-out strings by their bytes, the least recently used dropped past `cap`.
pub const Cache = struct {
    const none = std.math.maxInt(u32);
    const Entry = struct { key: []u8, glyphs: []Placed, width: f32, prev: u32, next: u32 };

    entries: std.ArrayList(Entry) = .empty,
    map: std.StringHashMapUnmanaged(u32) = .empty,
    /// Most and least recently used.
    head: u32 = none,
    tail: u32 = none,
    cap: u32 = cache_entries,

    fn deinit(self: *Cache, gpa: std.mem.Allocator) void {
        for (self.entries.items) |e| {
            gpa.free(e.key);
            gpa.free(e.glyphs);
        }
        self.entries.deinit(gpa);
        self.map.deinit(gpa);
    }

    pub fn contains(self: *const Cache, bytes: []const u8) bool {
        return self.map.contains(bytes);
    }

    fn unlink(self: *Cache, i: u32) void {
        const e = &self.entries.items[i];
        if (e.prev != none) self.entries.items[e.prev].next = e.next else self.head = e.next;
        if (e.next != none) self.entries.items[e.next].prev = e.prev else self.tail = e.prev;
        e.prev = none;
        e.next = none;
    }

    fn pushFront(self: *Cache, i: u32) void {
        const e = &self.entries.items[i];
        e.prev = none;
        e.next = self.head;
        if (self.head != none) self.entries.items[self.head].prev = i;
        self.head = i;
        if (self.tail == none) self.tail = i;
    }

    fn get(self: *Cache, bytes: []const u8) ?*const Entry {
        const i = self.map.get(bytes) orelse return null;
        if (self.head != i) {
            self.unlink(i);
            self.pushFront(i);
        }
        return &self.entries.items[i];
    }

    /// Adds `bytes` (copied) with `glyphs` (owned from now on).
    fn put(self: *Cache, gpa: std.mem.Allocator, bytes: []const u8, glyphs: []Placed, width: f32) !*const Entry {
        const owned = try gpa.dupe(u8, bytes);
        errdefer gpa.free(owned);
        try self.map.ensureUnusedCapacity(gpa, 1);
        var i: u32 = undefined;
        if (self.entries.items.len < self.cap) {
            try self.entries.append(gpa, .{ .key = owned, .glyphs = glyphs, .width = width, .prev = none, .next = none });
            i = @intCast(self.entries.items.len - 1);
        } else {
            i = self.tail;
            self.unlink(i);
            const old = &self.entries.items[i];
            _ = self.map.remove(old.key);
            gpa.free(old.key);
            gpa.free(old.glyphs);
            old.* = .{ .key = owned, .glyphs = glyphs, .width = width, .prev = none, .next = none };
        }
        self.map.putAssumeCapacity(owned, i);
        self.pushFront(i);
        return &self.entries.items[i];
    }
};

// ---- Tests ----
//
// These load real fonts through fontconfig, and HarfBuzz and FriBidi where a test needs
// them (no window, no GPU). A test whose font or library is not installed is skipped, and
// says so.

const testing = std.testing;

/// The primary font for the tests: Lato, as the rig has, at 14 px.
fn testFont() !font.Font {
    var f = try font.Font.init(testing.allocator, "Lato", 14);
    errdefer f.deinit(testing.allocator);
    if (f.engine == null) return skipBecause("no engine for the font");
    return f;
}

fn skipBecause(comptime why: []const u8) error{SkipZigTest} {
    std.debug.print("skipped: " ++ why ++ "\n", .{});
    return error.SkipZigTest;
}

fn needLibs() !*const Libs {
    return libs() orelse skipBecause("HarfBuzz or FriBidi not installed");
}

/// The named fallback that has `cp`, or null.
fn fallbackFor(e: *const Engine, cp: u32) ?u8 {
    for (1..e.named) |k| if (e.covers(@intCast(k), cp)) return @intCast(k);
    return null;
}

/// A copy of what `bytes` lays out to (the engine's result lives until its next layout).
fn shapedCopy(f: *const font.Font, bytes: []const u8) ![]Placed {
    const s = f.engine.?.layout(f.atlas, bytes) orelse return error.ShapingFailed;
    return testing.allocator.dupe(Placed, s.glyphs);
}

/// True if some pixel of glyph `g` in the atlas has coverage.
fn inked(atlas: []const u8, g: font.Glyph) bool {
    if (g.w == 0 or g.h == 0) return false;
    for (0..g.h) |row| {
        for (atlas[(g.y + row) * font.atlas_size + g.x ..][0..g.w]) |px| if (px > 0) return true;
    }
    return false;
}

test "the bidi types declared here are FriBidi's" {
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
    try testing.expect(load(One, &.{ "libdimna-no-such-library.so.0", harfbuzz_names[0] }, &one));
}

test "Latin and digits inside right-to-left text are isolated as one block; nothing else is" {
    const l = try needLibs();
    const gpa = testing.allocator;
    var text: std.ArrayList(u32) = .empty;
    defer text.deinit(gpa);
    var marks: std.ArrayList(bool) = .empty;
    defer marks.deinit(gpa);
    const Case = struct { in: []const u8, out: []const u8 };
    // `<` and `>` stand for the isolate marks put in.
    const cases = [_]Case{
        .{ .in = "\u{641}\u{6cc} 300-6000 Hz", .out = "\u{641}\u{6cc} <300-6000 Hz>" },
        .{ .in = "\u{641} (-10 ms) \u{641}", .out = "\u{641} (<-10 ms>) \u{641}" },
        .{ .in = "\u{641} 50% \u{641} 2", .out = "\u{641} <50%> \u{641} <2>" },
        // Left-to-right text alone, or with no right-to-left letter: untouched.
        .{ .in = "300-6000 Hz", .out = "300-6000 Hz" },
        .{ .in = "\u{9608}\u{503c} 300-6000 Hz", .out = "\u{9608}\u{503c} 300-6000 Hz" },
    };
    for (cases) |case| {
        var raw: std.ArrayList(u32) = .empty;
        defer raw.deinit(gpa);
        var it: font.Codepoints = .{ .bytes = case.in };
        while (it.next()) |cp| try raw.append(gpa, cp);
        const types = try gpa.alloc(u32, raw.items.len);
        defer gpa.free(types);
        l.fb.fribidi_get_bidi_types(raw.items.ptr, @intCast(raw.items.len), types.ptr);
        try isolateLtr(gpa, raw.items, types, &text, &marks);
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(gpa);
        for (text.items, marks.items) |cp, m| {
            var b: [4]u8 = undefined;
            const shown: u21 = if (!m) @intCast(cp) else if (cp == lri) '<' else '>';
            const n = try std.unicode.utf8Encode(shown, &b);
            try got.appendSlice(gpa, b[0..n]);
        }
        try testing.expectEqualStrings(case.out, got.items);
    }
}

test "runs are put in visual order by rule L2" {
    const gpa = testing.allocator;
    var runs: std.ArrayList(Engine.Run) = .empty;
    defer runs.deinit(gpa);
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(gpa);
    // Levels 1 1 2 _ 2 1 0 0, an isolate mark between the 2s.
    const levels = [_]i8{ 1, 1, 2, 2, 2, 1, 0, 0 };
    const marks = [_]bool{ false, false, false, true, false, false, false, false };
    try runsOf(gpa, &levels, &marks, &runs);
    try testing.expectEqual(5, runs.items.len);
    try testing.expectEqual(Engine.Run{ .start = 0, .end = 2, .level = 1 }, runs.items[0]);
    try testing.expectEqual(Engine.Run{ .start = 2, .end = 3, .level = 2 }, runs.items[1]);
    try testing.expectEqual(Engine.Run{ .start = 4, .end = 5, .level = 2 }, runs.items[2]);
    try visualOrder(gpa, runs.items, &order);
    // Level 2 first: [1 2] -> [2 1]; then level >= 1: [0 2 1 3] -> [3 1 2 0]; level 0 stays.
    try testing.expectEqualSlices(u32, &.{ 3, 1, 2, 0, 4 }, order.items);
    // No odd level: as they are.
    const ltr = [_]i8{ 0, 0, 2, 2 };
    try runsOf(gpa, &ltr, &.{ false, false, false, false }, &runs);
    try visualOrder(gpa, runs.items, &order);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, order.items);
}

test "Persian: the letters of a word are joined, not their isolated forms" {
    _ = try needLibs();
    var f = try testFont();
    defer f.deinit(testing.allocator);
    const ar = fallbackFor(f.engine.?, 0x0633) orelse return skipBecause("no Persian/Arabic font installed");
    // سلام: seen, lam, alef, meem. Lam and alef join as lam-alef (one glyph or two, as the
    // font has it); meem follows alef, which does not join to the left, so meem is rightly
    // isolated and not checked.
    const word = try shapedCopy(&f, "\u{633}\u{644}\u{627}\u{645}");
    defer testing.allocator.free(word);
    try testing.expect(word.len == 3 or word.len == 4);
    for (word) |p| try testing.expectEqual(ar, p.face);
    for ([_][]const u8{ "\u{633}", "\u{644}", "\u{627}" }) |letter| {
        const alone = try shapedCopy(&f, letter);
        defer testing.allocator.free(alone);
        try testing.expectEqual(1, alone.len);
        for (word) |p| try testing.expect(p.gid != alone[0].gid);
    }
    // Right to left: the glyphs come in visual order, seen (logically first) rightmost.
    try testing.expect(word[word.len - 1].x > word[0].x);
}

test "Persian: lam-alef is one glyph in a font that has the ligature" {
    _ = try needLibs();
    // DejaVu Sans has a one-glyph lam-alef; as the primary font it draws Arabic itself.
    var f = try font.Font.init(testing.allocator, "DejaVu Sans", 14);
    defer f.deinit(testing.allocator);
    const e = f.engine orelse return skipBecause("no engine for the font");
    if (!e.covers(0, 0x644)) return skipBecause("DejaVu Sans not installed");
    const la = try shapedCopy(&f, "\u{644}\u{627}");
    defer testing.allocator.free(la);
    try testing.expectEqual(1, la.len);
    try testing.expectEqual(0, la[0].face);
    try testing.expect(la[0].gid != 0);
    try testing.expect(la[0].gid != c.FT_Get_Char_Index(e.faces[0].ft, 0x644));
    try testing.expect(la[0].gid != c.FT_Get_Char_Index(e.faces[0].ft, 0x627));
}

test "Persian: lam-alef takes its own forms in a font that draws it as two glyphs" {
    _ = try needLibs();
    var f = try testFont();
    defer f.deinit(testing.allocator);
    const ar = fallbackFor(f.engine.?, 0x0644) orelse return skipBecause("no Persian/Arabic font installed");
    const la = try shapedCopy(&f, "\u{644}\u{627}");
    defer testing.allocator.free(la);
    // Lam before meem (لم) and alef after beh (با): their ordinary joined forms.
    const lm = try shapedCopy(&f, "\u{644}\u{645}");
    defer testing.allocator.free(lm);
    const ba = try shapedCopy(&f, "\u{628}\u{627}");
    defer testing.allocator.free(ba);
    try testing.expect(la.len == 1 or la.len == 2);
    for (la) |p| {
        try testing.expectEqual(ar, p.face);
        for ([_]u32{ 0x644, 0x627 }) |cp| try testing.expect(p.gid != c.FT_Get_Char_Index(f.engine.?.faces[ar].ft, cp));
        for (lm) |q| try testing.expect(p.gid != q.gid);
        for (ba) |q| try testing.expect(p.gid != q.gid);
    }
}

test "Persian with a range in Hz: the Latin and the digits are one left-to-right block" {
    _ = try needLibs();
    var f = try testFont();
    defer f.deinit(testing.allocator);
    const ar = fallbackFor(f.engine.?, 0x0641) orelse return skipBecause("no Persian/Arabic font installed");
    // فیلتر 300-6000 Hz
    const all = try shapedCopy(&f, "\u{641}\u{6cc}\u{644}\u{62a}\u{631} 300-6000 Hz");
    defer testing.allocator.free(all);
    const latin = try shapedCopy(&f, "300-6000 Hz");
    defer testing.allocator.free(latin);
    // The primary font's glyphs are "300-6000 Hz" as drawn alone, in the same order and
    // spacing, leftmost; the Persian word is to their right.
    var block: std.ArrayList(Placed) = .empty;
    defer block.deinit(testing.allocator);
    var first: ?usize = null;
    for (all, 0..) |p, k| {
        if (p.face != 0) continue;
        if (first == null) first = k;
        try block.append(testing.allocator, p);
    }
    try testing.expectEqual(latin.len, block.items.len);
    try testing.expectEqual(0, first.?);
    for (latin, block.items) |want, got| {
        try testing.expectEqual(want.gid, got.gid);
        try testing.expectEqual(want.x - latin[0].x, got.x - block.items[0].x);
    }
    const right_of_block = block.items[block.items.len - 1].x;
    var persian: usize = 0;
    for (all[block.items.len..]) |p| {
        if (p.face != ar) continue;
        persian += 1;
        try testing.expect(p.x > right_of_block);
    }
    try testing.expect(persian >= 4);
}

test "without shaping, Persian is drawn letter by letter, left to right, from its font" {
    var f = try testFont();
    defer f.deinit(testing.allocator);
    const e = f.engine.?;
    const ar = fallbackFor(e, 0x0633) orelse return skipBecause("no Persian/Arabic font installed");
    e.allow_shaping = false;
    const word = try shapedCopy(&f, "\u{633}\u{644}\u{627}\u{645}");
    defer testing.allocator.free(word);
    try testing.expectEqual(4, word.len);
    for (word, [_]u32{ 0x633, 0x644, 0x627, 0x645 }, 0..) |p, cp, k| {
        try testing.expectEqual(ar, p.face);
        try testing.expectEqual(c.FT_Get_Char_Index(e.faces[ar].ft, cp), p.gid);
        if (k > 0) try testing.expect(p.x > word[k - 1].x);
    }
    try testing.expectEqual(0, e.shaped_calls);
}

test "Chinese: 阈值 is two glyphs from the CJK font, drawn, its capitals as tall as the primary's" {
    var f = try testFont();
    defer f.deinit(testing.allocator);
    const e = f.engine.?;
    const cjk = fallbackFor(e, 0x9608) orelse return skipBecause("no Noto Sans CJK SC installed");
    const glyphs = try shapedCopy(&f, "阈值");
    defer testing.allocator.free(glyphs);
    try testing.expectEqual(2, glyphs.len);
    for (glyphs) |p| {
        try testing.expectEqual(cjk, p.face);
        try testing.expect(p.gid != 0);
        try testing.expect(inked(f.atlas, p.g));
    }
    try testing.expect(glyphs[1].x > glyphs[0].x);
    // Its capitals as tall as the primary's (to a pixel), not its line as high.
    if (e.cap_px) |cap| {
        try testing.expect(@abs(capRatio(e.faces[cjk].ft).? * @as(f32, @floatFromInt(e.faces[cjk].ft.*.size.*.metrics.y_ppem)) - cap) <= 1);
    }
    // Chinese needs no shaping (nor HarfBuzz or FriBidi).
    try testing.expectEqual(0, e.shaped_calls);
    // Drawn through the batch: two quads, ending where the width says.
    var vertices: [6 * 4]font.Vertex = undefined;
    var batch: font.Batch = .{ .font = &f, .vertices = &vertices };
    const end = batch.text(10, 0, "阈值", .{ 255, 255, 255, 255 });
    try testing.expectEqual(12, batch.len);
    try testing.expectEqual(10 + f.width("阈值"), end);
}

test "Polish: ł is drawn from the primary font" {
    var f = try testFont();
    defer f.deinit(testing.allocator);
    const gid = c.FT_Get_Char_Index(f.engine.?.faces[0].ft, 0x142);
    if (gid == 0) return skipBecause("the primary font has no ł");
    const glyphs = try shapedCopy(&f, "ł");
    defer testing.allocator.free(glyphs);
    try testing.expectEqual(1, glyphs.len);
    try testing.expectEqual(0, glyphs[0].face);
    try testing.expectEqual(gid, glyphs[0].gid);
    try testing.expect(inked(f.atlas, glyphs[0].g));
}

test "strings of the fixed glyphs are not laid out again, and are drawn as without the engine" {
    var f = try testFont();
    defer f.deinit(testing.allocator);
    const e = f.engine.?;
    var plain = f;
    plain.engine = null;
    const label = "A   2.00 s   400\u{b5}V/row   300\u{2013}6000 Hz   \u{3c3} \u{2192}";
    try testing.expectEqual(plain.width(label), f.width(label));
    var with_engine: [6 * 64]font.Vertex = undefined;
    var without: [6 * 64]font.Vertex = undefined;
    var b1: font.Batch = .{ .font = &f, .vertices = &with_engine };
    var b2: font.Batch = .{ .font = &plain, .vertices = &without };
    try testing.expectEqual(b2.text(3.4, 7.6, label, .{ 1, 2, 3, 4 }), b1.text(3.4, 7.6, label, .{ 1, 2, 3, 4 }));
    try testing.expect(b1.len > 6 * 20);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(without[0..b2.len]), std.mem.sliceAsBytes(with_engine[0..b1.len]));
    try testing.expectEqual(0, e.shape_calls);
}

test "the cache: a string is laid out once, and the least recently used is dropped past the bound" {
    var f = try testFont();
    defer f.deinit(testing.allocator);
    const e = f.engine.?;
    e.cache.cap = 2;
    var vertices: [6 * 16]font.Vertex = undefined;
    var batch: font.Batch = .{ .font = &f, .vertices = &vertices };
    _ = f.width("a \u{142}");
    try testing.expectEqual(1, e.shape_calls);
    _ = batch.text(0, 0, "a \u{142}", .{ 255, 255, 255, 255 });
    _ = f.width("a \u{142}");
    try testing.expectEqual(1, e.shape_calls);
    _ = f.width("b \u{142}");
    try testing.expectEqual(2, e.shape_calls);
    // "a" used last: "b" is the one dropped for "c".
    _ = f.width("a \u{142}");
    _ = f.width("c \u{142}");
    try testing.expectEqual(3, e.shape_calls);
    try testing.expect(e.cache.contains("a \u{142}"));
    try testing.expect(!e.cache.contains("b \u{142}"));
    try testing.expect(e.cache.contains("c \u{142}"));
    _ = f.width("b \u{142}");
    try testing.expectEqual(4, e.shape_calls);
    try testing.expect(!e.cache.contains("a \u{142}"));
}

test "the atlas: new glyphs mark their rows; when it is full, one warning and the missing glyph" {
    var f = try testFont();
    defer f.deinit(testing.allocator);
    const e = f.engine.?;
    _ = f.takeDirty();
    try testing.expectEqual(null, f.takeDirty());
    const one = try shapedCopy(&f, "\u{142}");
    defer testing.allocator.free(one);
    const g = one[0].g;
    try testing.expect(g.h > 0);
    try testing.expectEqual([2]u32{ g.y, g.y + g.h }, f.takeDirty().?);
    try testing.expectEqual(null, f.takeDirty());
    // Already drawn: no rows.
    _ = e.layout(f.atlas, "\u{142}\u{142}") orelse return error.ShapingFailed;
    try testing.expectEqual(null, f.takeDirty());
    // Nearly full: the next glyph has no room.
    e.pen = .{ .x = 1, .y = font.atlas_size - 3, .shelf_h = 0 };
    for ([_][]const u8{ "\u{141}", "\u{15a}", "\u{179}" }) |s| {
        const got = try shapedCopy(&f, s);
        defer testing.allocator.free(got);
        const m = got[0].g;
        try testing.expectEqual([4]u16{ e.notdef.x, e.notdef.y, e.notdef.w, e.notdef.h }, [4]u16{ m.x, m.y, m.w, m.h });
        try testing.expect(m.advance > 0);
    }
    try testing.expect(e.full);
    try testing.expectEqual(1, e.full_warnings);
    try testing.expectEqual(null, f.takeDirty());
    // Glyphs drawn before still are.
    const again = try shapedCopy(&f, "\u{142}");
    defer testing.allocator.free(again);
    try testing.expectEqual(g, again[0].g);
}

test "the paragraph direction: right to left with a right-to-left letter when the language is; else the first strong letter's" {
    const Case = struct { types: []const u32, rtl: bool, want: u32 };
    const L = bidi.L;
    const R = bidi.R;
    const AL = bidi.AL;
    const EN = bidi.EN;
    const WS: u32 = 0x800; // FRIBIDI_TYPE_WS: neither strong nor a letter
    for ([_]Case{
        // "Simulator فیلتر": Latin first.
        .{ .types = &.{ L, L, WS, AL, AL }, .rtl = true, .want = bidi.par_rtl },
        .{ .types = &.{ L, L, WS, AL, AL }, .rtl = false, .want = bidi.par_ltr },
        // A number first, then Persian: the Persian is the first strong letter either way.
        .{ .types = &.{ EN, WS, AL }, .rtl = true, .want = bidi.par_rtl },
        .{ .types = &.{ EN, WS, AL }, .rtl = false, .want = bidi.par_rtl },
        .{ .types = &.{ AL, WS, L }, .rtl = false, .want = bidi.par_rtl },
        .{ .types = &.{ R, L }, .rtl = true, .want = bidi.par_rtl },
        // No right-to-left letter: as the first strong letter says, setting or not.
        .{ .types = &.{ EN, WS, L }, .rtl = true, .want = bidi.par_ltr },
        .{ .types = &.{ EN, WS }, .rtl = true, .want = bidi.par_on },
        .{ .types = &.{}, .rtl = false, .want = bidi.par_on },
    }) |case| try testing.expectEqual(case.want, paragraphDirection(case.types, case.rtl));
}

test "a font made after the start-up direction is set lays out with it; one made before keeps its own" {
    var before = try testFont();
    defer before.deinit(testing.allocator);
    start_rtl = true;
    defer start_rtl = false;
    var after = try testFont();
    defer after.deinit(testing.allocator);
    try testing.expect(!before.engine.?.rtl);
    try testing.expect(after.engine.?.rtl);
}

/// The test font with the paragraph direction set (before anything is laid out, so the
/// cache holds nothing laid out otherwise).
fn testFontDirection(rtl: bool) !font.Font {
    var f = try testFont();
    f.engine.?.rtl = rtl;
    return f;
}

/// Where the glyphs of the primary font (Latin, digits) and of font `ar` (Persian) are: the
/// smallest and largest x of each.
const Spans = struct {
    latin: [2]i32 = .{ std.math.maxInt(i32), std.math.minInt(i32) },
    persian: [2]i32 = .{ std.math.maxInt(i32), std.math.minInt(i32) },
    persian_glyphs: usize = 0,

    fn of(glyphs: []const Placed, ar: u8) Spans {
        var s: Spans = .{};
        for (glyphs) |p| {
            const span = if (p.face == 0) &s.latin else if (p.face == ar) &s.persian else continue;
            span[0] = @min(span[0], p.x);
            span[1] = @max(span[1], p.x);
            if (p.face == ar) s.persian_glyphs += 1;
        }
        return s;
    }
};

test "Persian read right to left: a Latin name first is on the right, a Persian word first is too" {
    _ = try needLibs();
    var f = try testFontDirection(true);
    defer f.deinit(testing.allocator);
    var ltr = try testFontDirection(false);
    defer ltr.deinit(testing.allocator);
    const e = f.engine.?;
    const ar = fallbackFor(e, 0x0641) orelse return skipBecause("no Persian/Arabic font installed");
    const filter = "\u{641}\u{6cc}\u{644}\u{62a}\u{631}"; // فیلتر
    // "{source} فیلتر", formatted with a Latin value first.
    var buf: [64]u8 = undefined;
    const sourced = try std.fmt.bufPrint(&buf, "{s} {s}", .{ "Simulator", filter });

    const got = try shapedCopy(&f, sourced);
    defer testing.allocator.free(got);
    const s = Spans.of(got, ar);
    try testing.expect(s.persian_glyphs >= 4);
    // Right to left: the Persian word (logically last) leftmost, the name rightmost.
    try testing.expect(s.persian[1] < s.latin[0]);
    // The name itself left to right, its letters in order: as laid out alone.
    const name = try shapedCopy(&f, "Simulator");
    defer testing.allocator.free(name);
    const space = c.FT_Get_Char_Index(e.faces[0].ft, ' ');
    var k: usize = 0;
    var last_x: i32 = std.math.minInt(i32);
    for (got) |p| {
        if (p.face != 0 or p.gid == space) continue;
        try testing.expect(k < name.len);
        try testing.expectEqual(name[k].gid, p.gid);
        try testing.expect(p.x > last_x);
        last_x = p.x;
        k += 1;
    }
    try testing.expectEqual(name.len, k);

    // Not read right to left (another language), the first strong letter decides: the name
    // first, on the left.
    const other = try shapedCopy(&ltr, sourced);
    defer testing.allocator.free(other);
    const o = Spans.of(other, ar);
    try testing.expect(o.latin[1] < o.persian[0]);

    // A number first ("12 فیلتر"): right to left in both, the number on the right.
    for ([_]*font.Font{ &f, &ltr }) |which| {
        const numbered = try shapedCopy(which, "12 " ++ filter);
        defer testing.allocator.free(numbered);
        const n = Spans.of(numbered, ar);
        try testing.expect(n.persian[1] < n.latin[0]);
    }

    // فیلتر 300-6000 Hz: the range one left-to-right block on the left, in its order.
    const hz = try shapedCopy(&f, filter ++ " 300-6000 Hz");
    defer testing.allocator.free(hz);
    const latin = try shapedCopy(&f, "300-6000 Hz");
    defer testing.allocator.free(latin);
    const h = Spans.of(hz, ar);
    try testing.expect(h.latin[1] < h.persian[0]);
    k = 0;
    for (hz) |p| {
        if (p.face != 0) continue;
        try testing.expect(k < latin.len);
        try testing.expectEqual(latin[k].gid, p.gid);
        try testing.expectEqual(latin[k].x - latin[0].x, p.x - h.latin[0]);
        k += 1;
    }
    try testing.expectEqual(latin.len, k);
}

test "Persian read right to left: a string with no right-to-left letter is laid out as before" {
    var f = try testFontDirection(true);
    defer f.deinit(testing.allocator);
    const e = f.engine.?;
    var plain = f;
    plain.engine = null;
    // Latin-1: the fixed glyphs, never laid out by the engine, the same quads.
    const label = "A   2.00 s   400\u{b5}V/row   300\u{2013}6000 Hz";
    var with_engine: [6 * 64]font.Vertex = undefined;
    var without: [6 * 64]font.Vertex = undefined;
    var b1: font.Batch = .{ .font = &f, .vertices = &with_engine };
    var b2: font.Batch = .{ .font = &plain, .vertices = &without };
    try testing.expectEqual(b2.text(3, 7, label, .{ 1, 2, 3, 4 }), b1.text(3, 7, label, .{ 1, 2, 3, 4 }));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(without[0..b2.len]), std.mem.sliceAsBytes(with_engine[0..b1.len]));
    try testing.expectEqual(0, e.shape_calls);
    // Beyond Latin-1 but no right-to-left letter: unshaped, left to right.
    const glyphs = try shapedCopy(&f, "\u{142}\u{f3}d\u{17a} 300 Hz");
    defer testing.allocator.free(glyphs);
    try testing.expectEqual(11, glyphs.len);
    for (glyphs[1..], glyphs[0 .. glyphs.len - 1]) |p, before| try testing.expect(p.x > before.x);
    try testing.expectEqual(0, e.shaped_calls);
}

fn cpuNs() u64 {
    // CLOCK_THREAD_CPUTIME_ID on Linux.
    return @intCast(std.Io.Clock.cpu_thread.now(testing.io).nanoseconds);
}

// The cost of a frame of text, and how many CJK glyphs fit. Not part of the usual run: set
// DIMNA_TEXT_BENCH=1 (best with `zig build test --release=safe`).
test "benchmark: a frame of text on the fast and the shaped paths; CJK glyphs that fit" {
    if (std.c.getenv("DIMNA_TEXT_BENCH") == null) return error.SkipZigTest;
    const gpa = testing.allocator;
    var f = try testFont();
    defer f.deinit(gpa);
    const e = f.engine.?;
    const n_labels = 200;
    const vertices = try gpa.alloc(font.Vertex, 6 * 64 * n_labels);
    defer gpa.free(vertices);
    var batch: font.Batch = .{ .font = &f, .vertices = vertices };

    var storage: [3][n_labels][160]u8 = undefined;
    var labels: [3][n_labels][]const u8 = undefined;
    for (0..n_labels) |k| {
        // Latin-1 only, 37-43 characters.
        labels[0][k] = try std.fmt.bufPrint(&storage[0][k], "A{d}   {d}.{d:0>2} s   {d}\u{b5}V/row   300-6000 Hz", .{ k % 8, k % 20, k % 100, 50 * (k % 16) });
        // Persian (shaped, about 30 characters) and Chinese (fallback, about 30), every one
        // different.
        labels[1][k] = if (k % 2 == 0)
            try std.fmt.bufPrint(&storage[1][k], "\u{641}\u{6cc}\u{644}\u{62a}\u{631} {d}-6000 Hz \u{6a9}\u{627}\u{646}\u{627}\u{644} {d}", .{ 100 + k, k })
        else
            try std.fmt.bufPrint(&storage[1][k], "\u{901a}\u{9053} {d} \u{9608}\u{503c} {d} \u{5fae}\u{4f0f} \u{6ee4}\u{6ce2}\u{5668} 300-6000 Hz", .{ k, k * 3 });
        // The same with other numbers: glyphs all drawn already, the strings not laid out.
        labels[2][k] = if (k % 2 == 0)
            try std.fmt.bufPrint(&storage[2][k], "\u{641}\u{6cc}\u{644}\u{62a}\u{631} {d}-6000 Hz \u{6a9}\u{627}\u{646}\u{627}\u{644} {d}", .{ 500 + k, k + 1 })
        else
            try std.fmt.bufPrint(&storage[2][k], "\u{901a}\u{9053} {d} \u{9608}\u{503c} {d} \u{5fae}\u{4f0f} \u{6ee4}\u{6ce2}\u{5668} 300-6000 Hz", .{ k + 7, k * 3 + 1 });
    }
    const Frame = struct {
        fn run(b: *font.Batch, set: []const []const u8) u64 {
            const t0 = cpuNs();
            b.clear();
            for (set, 0..) |s, k| _ = b.text(0, @floatFromInt(k), s, .{ 255, 255, 255, 255 });
            return cpuNs() - t0;
        }
    };
    const reps = 200;
    var fast: u64 = 0;
    for (0..reps) |_| fast += Frame.run(&batch, &labels[0]);
    const first = Frame.run(&batch, &labels[1]);
    const glyphs_drawn = e.glyphs.count();
    const miss = Frame.run(&batch, &labels[2]);
    var cached: u64 = 0;
    for (0..reps) |_| cached += Frame.run(&batch, &labels[1]);
    std.debug.print(
        \\text frame, {d} labels (shaping libraries loaded: {}):
        \\  fast path            {d:.3} ms
        \\  shaped, first frame  {d:.3} ms (laying out and rasterizing; {d} glyphs in the map)
        \\  shaped, cache miss   {d:.3} ms (glyphs already drawn)
        \\  shaped, cached       {d:.3} ms
        \\
    , .{
        n_labels,
        libs() != null,
        @as(f64, @floatFromInt(fast)) / reps / 1e6,
        @as(f64, @floatFromInt(first)) / 1e6,
        glyphs_drawn,
        @as(f64, @floatFromInt(miss)) / 1e6,
        @as(f64, @floatFromInt(cached)) / reps / 1e6,
    });

    // Fill the rest of the atlas with CJK ideographs, 32 to a string.
    const cjk = fallbackFor(e, 0x4e00) orelse return;
    // CJK Unified Ideographs, then Extension A, then Extension B, until the atlas is full.
    const ranges = [_][2]u21{ .{ 0x4e00, 0x9fa0 }, .{ 0x3400, 0x4dc0 }, .{ 0x20000, 0x2a6e0 } };
    var cp: u21 = 0;
    var buf: [32 * 4]u8 = undefined;
    for (ranges) |r| {
        cp = r[0];
        while (!e.full and cp < r[1]) {
            var len: usize = 0;
            for (0..32) |_| {
                len += try std.unicode.utf8Encode(cp, buf[len..]);
                cp += 1;
            }
            _ = e.layout(f.atlas, buf[0..len]);
        }
    }
    var fit: usize = 0;
    var it = e.glyphs.iterator();
    while (it.next()) |kv| {
        if (kv.key_ptr.* >> 32 == cjk and kv.value_ptr.w > 0 and kv.value_ptr.y < font.atlas_size - 1) fit += 1;
    }
    std.debug.print("CJK glyphs in the atlas when it filled: {d} (full: {}, up to U+{X})\n", .{ fit, e.full, cp });
}

test "Persian: alef stands as tall as the primary's capitals, not shrunk to its line height" {
    var f = try testFont();
    defer f.deinit(testing.allocator);
    const e = f.engine.?;
    const ar = fallbackFor(e, 0x0627) orelse return skipBecause("no Persian/Arabic font installed");
    const cap = e.cap_px orelse return skipBecause("the primary font has no capital H");
    const face = e.faces[ar].ft;
    const alef_px = capRatio(face).? * @as(f32, @floatFromInt(face.*.size.*.metrics.x_ppem));
    try testing.expect(@abs(alef_px - cap) <= 1);
    // Noto Sans Arabic's line is far taller than the primary's for the same letters, so
    // matching lines would have drawn alef at little more than half the height.
    try testing.expect(e.faces[ar].line_height > f.line_height);
}
