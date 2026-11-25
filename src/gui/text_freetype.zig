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
pub const Matcher = fontfind.Matcher;
pub const Match = fontfind.Match;

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

// ---- Bidi and shaping ----

/// FriBidi's types are the values of `text_backend.bidi` as they are.
pub fn bidiTypes(l: *const Shaping, cps: []const u32, types: []u32) void {
    l.fb.fribidi_get_bidi_types(cps.ptr, @intCast(cps.len), types.ptr);
}

pub const Shaper = struct {
    /// HarfBuzz's buffer, made the first time something is shaped.
    buf: ?*HbBuffer = null,
    // Scratch, reused from string to string.
    types: std.ArrayList(u32) = .empty,
    brackets: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *Shaper, gpa: std.mem.Allocator) void {
        // The buffer exists only if the libraries were loaded.
        if (self.buf) |buf| libs_value.hb.hb_buffer_destroy(buf);
        self.types.deinit(gpa);
        self.brackets.deinit(gpa);
    }

    pub fn embeddingLevels(self: *Shaper, gpa: std.mem.Allocator, l: *const Shaping, text: []const u32, base_in: u32, levels: []i8) !void {
        var base = base_in;
        const n: c_int = @intCast(text.len);
        try self.types.resize(gpa, text.len);
        try self.brackets.resize(gpa, text.len);
        l.fb.fribidi_get_bidi_types(text.ptr, n, self.types.items.ptr);
        l.fb.fribidi_get_bracket_types(text.ptr, n, self.types.items.ptr, self.brackets.items.ptr);
        if (l.fb.fribidi_get_par_embedding_levels_ex(self.types.items.ptr, self.brackets.items.ptr, n, &base, levels.ptr) == 0) return error.Bidi;
        // Rule L1 (trailing white space to the paragraph's level); the order is the caller's.
        if (l.fb.fribidi_reorder_line(0, self.types.items.ptr, n, 0, base, levels.ptr, null, null) == 0) return error.Bidi;
    }

    pub fn shape(self: *Shaper, l: *const Shaping, face: *Face, text: []const u32, start: u32, end: u32, rtl: bool) !Run {
        const hb = &l.hb;
        const buf = self.buf orelse blk: {
            const b = hb.hb_buffer_create() orelse return error.Shaping;
            if (hb.hb_buffer_allocation_successful(b) == 0) {
                hb.hb_buffer_destroy(b);
                return error.Shaping;
            }
            self.buf = b;
            break :blk b;
        };
        const hb_font = face.hb orelse blk: {
            const f = hb.hb_ft_font_create_referenced(face.ft) orelse return error.Shaping;
            // Hinted advances, as FreeType gives the fixed glyphs.
            hb.hb_ft_font_set_load_flags(f, c.FT_LOAD_DEFAULT);
            face.hb = f;
            break :blk f;
        };
        hb.hb_buffer_clear_contents(buf);
        hb.hb_buffer_add_codepoints(buf, text.ptr, @intCast(text.len), start, @intCast(end - start));
        hb.hb_buffer_set_direction(buf, if (rtl) hb_direction_rtl else hb_direction_ltr);
        hb.hb_buffer_guess_segment_properties(buf);
        hb.hb_shape(hb_font, buf, null, 0);
        var count: c_uint = 0;
        const infos = hb.hb_buffer_get_glyph_infos(buf, &count) orelse return .{};
        const positions = hb.hb_buffer_get_glyph_positions(buf, &count) orelse return .{};
        return .{ .infos = infos[0..count], .positions = positions[0..count] };
    }
};

/// The glyphs of a shaped run, in visual order.
pub const Run = struct {
    infos: []const HbGlyphInfo = &.{},
    positions: []const HbGlyphPosition = &.{},
    i: usize = 0,

    pub fn next(self: *Run) ?RunGlyph {
        if (self.i >= self.infos.len) return null;
        defer self.i += 1;
        const info = self.infos[self.i];
        const pos = self.positions[self.i];
        return .{
            .gid = info.codepoint,
            .x_offset = px26(pos.x_offset),
            .y_offset = px26(pos.y_offset),
            .x_advance = px26(pos.x_advance),
        };
    }
};

/// 26.6 fixed point to pixels.
fn px26(v: i32) f32 {
    return @as(f32, @floatFromInt(v)) / 64.0;
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
