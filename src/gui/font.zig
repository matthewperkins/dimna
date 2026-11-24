//! Text for the display: one font at one pixel size, rasterized by FreeType into a
//! single-channel atlas, and laid out as textured quads. Latin-1 and a few symbols are
//! rasterized at startup (the fixed glyphs); a string made only of those is laid out as it
//! always was: one glyph per code point, left to right, no kerning. Any other string is
//! shaped (`shape.zig`: bidi, font fallback, HarfBuzz), its glyphs rasterized into the atlas
//! the first time they are drawn. A second, fixed-width set of ASCII glyphs can be added to
//! the same atlas (`addMono`), for text laid out in columns (`Batch.textMono`, never shaped).
//!
//! The atlas's top-left corner holds a block of full coverage, so solid rectangles go
//! through the same pipeline as text (`Batch.rect`).

const std = @import("std");
const c = @import("gui_c");
const theme = @import("theme.zig");
const shape = @import("shape.zig");
const fontfind = @import("fontfind.zig");
const log = std.log.scoped(.font);

/// Pixels each side; room for the fixed glyphs and a few thousand drawn on demand.
pub const atlas_size = 2048;
const first_cp = 32;
const last_cp = 255;
/// A few characters beyond Latin-1 that labels use: sigma, en dash, right arrow, a note,
/// and the small triangles before a heading that opens (closed) or closes (open).
const extra_cps = [_]u21{ 0x03C3, 0x2013, 0x2192, 0x266A, 0x25B8, 0x25BE };
const white_block = 4;
/// The fixed-width glyphs: printable ASCII.
const mono_first = 32;
const mono_last = 126;

pub const Vertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    colour: [4]u8,
};

pub const Colour = [4]u8;

pub const Glyph = struct {
    // Position in the atlas, pixels.
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,
    // Offset of the bitmap from the pen position (y down from the baseline's top).
    left: i16 = 0,
    top: i16 = 0,
    advance: f32 = 0,
};

pub const Font = struct {
    /// Coverage, `atlas_size` x `atlas_size`.
    atlas: []u8,
    glyphs: [last_cp - first_cp + 1 + extra_cps.len]Glyph = @splat(.{}),
    /// Pixels from the top of a line to its baseline, and the line height.
    ascent: f32 = 0,
    line_height: f32 = 0,
    px: u32,
    /// The fixed-width glyphs (`addMono`), printable ASCII; `has_mono` once they are all in
    /// the atlas. Without them, fixed-width text is drawn with the glyphs above.
    mono: [mono_last - mono_first + 1]Glyph = @splat(.{}),
    has_mono: bool = false,
    /// Where the next glyph goes in the atlas.
    pen: Pen = .{},
    /// Shaping, font fallback and glyphs on demand; null (a font made by hand, or one
    /// HarfBuzz could not take) draws only the fixed glyphs, anything else as "?".
    engine: ?*shape.Engine = null,

    /// Loads the font fontconfig picks for `family` (e.g. "sans-serif", "monospace",
    /// "Lato") at `px` pixels.
    pub fn init(gpa: std.mem.Allocator, family: [:0]const u8, px: u32) !Font {
        var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        const path = try fontfind.findFont(family, &path_buf);

        var lib: c.FT_Library = null;
        if (c.FT_Init_FreeType(&lib) != 0) return error.FreeType;
        var face: c.FT_Face = null;
        if (c.FT_New_Face(lib, path.ptr, 0, &face) != 0) {
            _ = c.FT_Done_FreeType(lib);
            log.err("cannot load font {s}", .{path});
            return error.FontNotLoaded;
        }
        // Both are closed here unless the shaping engine takes them.
        var owned = true;
        defer if (owned) {
            _ = c.FT_Done_Face(face);
            _ = c.FT_Done_FreeType(lib);
        };
        if (c.FT_Set_Pixel_Sizes(face, 0, px) != 0) return error.FreeType;

        const atlas = try gpa.alloc(u8, atlas_size * atlas_size);
        errdefer gpa.free(atlas);
        @memset(atlas, 0);
        for (0..white_block) |y| @memset(atlas[y * atlas_size ..][0..white_block], 255);

        const metrics = face.*.size.*.metrics;
        var font: Font = .{
            .atlas = atlas,
            .px = px,
            .ascent = @as(f32, @floatFromInt(metrics.ascender)) / 64.0,
            .line_height = @as(f32, @floatFromInt(metrics.height)) / 64.0,
        };
        // Shelf packing, one pixel of padding around each glyph.
        var pen: Pen = .{};
        var index: usize = 0;
        while (index < font.glyphs.len) : (index += 1) {
            // A character the font lacks stays empty for now.
            if (!font.place(face, codepointAt(index), index, &pen)) continue;
        }
        // The few characters beyond Latin-1 that the font lacks (the note that marks a
        // channel listened to, say) are taken from whatever font fontconfig offers for
        // that character. One still missing is drawn as "?".
        for (extra_cps, last_cp - first_cp + 1..) |cp, at| {
            if (font.glyphs[at].advance > 0) continue;
            var want_buf: [48:0]u8 = undefined;
            const want = std.fmt.bufPrintSentinel(&want_buf, "sans-serif:charset={x}", .{cp}, 0) catch continue;
            var other_buf: [std.fs.max_path_bytes:0]u8 = undefined;
            const other_path = fontfind.findFont(want, &other_buf) catch continue;
            var other: c.FT_Face = null;
            if (c.FT_New_Face(lib, other_path.ptr, 0, &other) != 0) continue;
            defer _ = c.FT_Done_Face(other);
            if (c.FT_Set_Pixel_Sizes(other, 0, px) != 0) continue;
            if (font.place(other, cp, at, &pen)) log.info("U+{X:0>4} from {s}", .{ cp, other_path });
        }
        font.pen = pen;
        log.info("font {s} at {d} px", .{ path, px });
        font.engine = shape.Engine.create(gpa, lib, face, &font) catch |e| blk: {
            log.warn("no text shaping ({t}): characters beyond Latin-1 draw as '?'", .{e});
            break :blk null;
        };
        if (font.engine != null) owned = false;
        return font;
    }

    /// Adds the printable ASCII of the font fontconfig picks for `family` ("monospace") at
    /// the same pixel size, into the same atlas after the glyphs there (upload the atlas
    /// after this). All or nothing: if the atlas has no room for all of them, none is used
    /// (`error.AtlasFull`; `has_mono` stays false) and fixed-width text is drawn with the
    /// ordinary glyphs. A character the face lacks is drawn with the ordinary glyph.
    pub fn addMono(self: *Font, family: [:0]const u8) !void {
        var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        const path = try fontfind.findFont(family, &path_buf);
        var lib: c.FT_Library = null;
        if (c.FT_Init_FreeType(&lib) != 0) return error.FreeType;
        defer _ = c.FT_Done_FreeType(lib);
        var face: c.FT_Face = null;
        if (c.FT_New_Face(lib, path.ptr, 0, &face) != 0) return error.FontNotLoaded;
        defer _ = c.FT_Done_Face(face);
        if (c.FT_Set_Pixel_Sizes(face, 0, self.px) != 0) return error.FreeType;
        var pen = if (self.engine) |e| e.pen else self.pen;
        var glyphs: @TypeOf(self.mono) = @splat(.{});
        for (&glyphs, mono_first..) |*g, cp| {
            g.* = self.render(face, @intCast(cp), &pen) catch |e| switch (e) {
                error.NoGlyph => continue,
                error.AtlasFull => return e,
            };
        }
        self.mono = glyphs;
        self.has_mono = true;
        self.pen = pen;
        if (self.engine) |e| e.pen = pen;
        log.info("fixed-width font {s} at {d} px", .{ path, self.px });
    }

    pub fn deinit(self: *Font, gpa: std.mem.Allocator) void {
        if (self.engine) |e| e.destroy();
        self.engine = null;
        gpa.free(self.atlas);
    }

    /// The rows of the atlas that glyphs drawn on demand changed since the last call
    /// ([first, end)), for the GPU's copy to be brought up to date before it draws them.
    pub fn takeDirty(self: *const Font) ?[2]u32 {
        const e = self.engine orelse return null;
        return e.takeDirty();
    }

    /// `text` shaped, if it is not one for the fixed glyphs alone (and the font can shape).
    fn shaped(self: *const Font, text: []const u8) ?shape.Shaped {
        const e = self.engine orelse return null;
        if (!self.needsShaping(text)) return null;
        return e.layout(self.atlas, text);
    }

    /// False if every code point of `text` is drawn by the fixed glyphs as it always was:
    /// Latin-1 (and below), and the extra symbols the font found.
    fn needsShaping(self: *const Font, text: []const u8) bool {
        for (text) |b| {
            if (b >= 0x80) break;
        } else return false;
        var it: Codepoints = .{ .bytes = text };
        while (it.next()) |cp| {
            if (cp <= last_cp) continue;
            for (extra_cps, last_cp - first_cp + 1..) |extra, at| {
                if (extra == cp and self.glyphs[at].advance > 0) break;
            } else return true;
        }
        return false;
    }

    /// Where the next glyph goes in the atlas.
    pub const Pen = struct {
        x: usize = white_block + 1,
        y: usize = 1,
        shelf_h: usize = white_block,

        /// Where a glyph of `w` x `h` pixels goes (shelf packing, one pixel of padding),
        /// the pen moved on past it; null if the atlas has no room left for it.
        pub fn fit(pen: *Pen, w: usize, h: usize) ?[2]usize {
            if (pen.x + w + 1 > atlas_size) {
                pen.x = 1;
                pen.y += pen.shelf_h + 1;
                pen.shelf_h = 0;
            }
            if (pen.y + h + 1 > atlas_size) return null;
            const at: [2]usize = .{ pen.x, pen.y };
            pen.x += w + 1;
            pen.shelf_h = @max(pen.shelf_h, h);
            return at;
        }
    };

    /// The code point of glyph slot `index`.
    pub fn codepointAt(index: usize) u32 {
        return if (index <= last_cp - first_cp) @intCast(first_cp + index) else extra_cps[index - (last_cp - first_cp + 1)];
    }

    /// Renders `cp` from `face` into the atlas as glyph slot `index`. False if the face
    /// has no such character, or the atlas is full.
    fn place(self: *Font, face: c.FT_Face, cp: u32, index: usize, pen: *Pen) bool {
        self.glyphs[index] = self.render(face, cp, pen) catch |e| {
            if (e == error.AtlasFull) log.warn("font atlas full at code point {d}; it and later glyphs are missing", .{cp});
            return false;
        };
        return true;
    }

    /// Renders `cp` from `face` into the atlas at `pen` (moved on past it).
    fn render(self: *Font, face: c.FT_Face, cp: u32, pen: *Pen) error{ NoGlyph, AtlasFull }!Glyph {
        if (c.FT_Get_Char_Index(face, cp) == 0) return error.NoGlyph;
        if (c.FT_Load_Char(face, cp, c.FT_LOAD_RENDER) != 0) return error.NoGlyph;
        const slot = face.*.glyph;
        const bm = slot.*.bitmap;
        const w: usize = bm.width;
        const h: usize = bm.rows;
        const at = pen.fit(w, h) orelse return error.AtlasFull;
        for (0..h) |row| {
            const src: [*]const u8 = bm.buffer + row * @as(usize, @intCast(bm.pitch));
            @memcpy(self.atlas[(at[1] + row) * atlas_size + at[0] ..][0..w], src[0..w]);
        }
        return .{
            .x = @intCast(at[0]),
            .y = @intCast(at[1]),
            .w = @intCast(w),
            .h = @intCast(h),
            .left = @intCast(slot.*.bitmap_left),
            .top = @intCast(slot.*.bitmap_top),
            .advance = @as(f32, @floatFromInt(slot.*.advance.x)) / 64.0,
        };
    }

    /// The glyph for `cp`: with `mono`, the fixed-width one if there is one.
    fn glyphOf(self: *const Font, cp: u21, mono: bool) *const Glyph {
        if (mono and self.has_mono and cp >= mono_first and cp <= mono_last) {
            const g = &self.mono[cp - mono_first];
            if (g.advance > 0) return g;
        }
        return self.glyph(cp);
    }

    fn glyph(self: *const Font, cp: u21) *const Glyph {
        if (cp >= first_cp and cp <= last_cp) return &self.glyphs[cp - first_cp];
        for (extra_cps, 0..) |extra, k| {
            const g = &self.glyphs[last_cp - first_cp + 1 + k];
            if (extra == cp and g.advance > 0) return g;
        }
        return &self.glyphs['?' - first_cp];
    }

    /// Width of `text` (UTF-8) in pixels.
    pub fn width(self: *const Font, text: []const u8) f32 {
        return self.widthOf(text, false);
    }

    /// Width of `text` drawn with `Batch.textMono`, in pixels.
    pub fn widthMono(self: *const Font, text: []const u8) f32 {
        return self.widthOf(text, true);
    }

    fn widthOf(self: *const Font, text: []const u8, mono: bool) f32 {
        if (!mono) if (self.shaped(text)) |s| return s.width;
        var w: f32 = 0;
        var it: Codepoints = .{ .bytes = text };
        while (it.next()) |cp| w += self.glyphOf(cp, mono).advance;
        return w;
    }
};

/// The code points of text that should be UTF-8 but may not be (a note cut in the middle
/// of a character, a file name). A byte that does not begin a valid sequence comes out as
/// U+FFFD, and nothing is read past the end: drawing text must never be what stops the
/// program. (`std.unicode.Utf8Iterator` assumes valid input and reads out of bounds on a
/// cut sequence.)
pub const Codepoints = struct {
    bytes: []const u8,
    i: usize = 0,

    pub fn next(self: *Codepoints) ?u21 {
        if (self.i >= self.bytes.len) return null;
        const n = std.unicode.utf8ByteSequenceLength(self.bytes[self.i]) catch {
            self.i += 1;
            return 0xFFFD;
        };
        if (self.i + n > self.bytes.len) {
            self.i = self.bytes.len;
            return 0xFFFD;
        }
        const cp = std.unicode.utf8Decode(self.bytes[self.i..][0..n]) catch {
            self.i += 1;
            return 0xFFFD;
        };
        self.i += n;
        return cp;
    }
};

/// Quads for one frame's text and rectangles, in pixel coordinates.
pub const Batch = struct {
    font: *const Font,
    vertices: []Vertex,
    len: usize = 0,

    pub fn clear(self: *Batch) void {
        self.len = 0;
    }

    fn quad(self: *Batch, x0: f32, y0: f32, x1: f32, y1: f32, uv0: [2]f32, uv1: [2]f32, colour: Colour) void {
        if (self.len + 6 > self.vertices.len) return;
        const v = self.vertices[self.len..][0..6];
        v[0] = .{ .pos = .{ x0, y0 }, .uv = .{ uv0[0], uv0[1] }, .colour = colour };
        v[1] = .{ .pos = .{ x1, y0 }, .uv = .{ uv1[0], uv0[1] }, .colour = colour };
        v[2] = .{ .pos = .{ x1, y1 }, .uv = .{ uv1[0], uv1[1] }, .colour = colour };
        v[3] = v[0];
        v[4] = v[2];
        v[5] = .{ .pos = .{ x0, y1 }, .uv = .{ uv0[0], uv1[1] }, .colour = colour };
        self.len += 6;
    }

    /// A straight line from (x0, y0) to (x1, y1), `width` pixels thick.
    pub fn line(self: *Batch, x0: f32, y0: f32, x1: f32, y1: f32, width: f32, colour: Colour) void {
        if (self.len + 6 > self.vertices.len) return;
        const dx = x1 - x0;
        const dy = y1 - y0;
        const length = @sqrt(dx * dx + dy * dy);
        if (length < 1e-4) return;
        // Half the width, across the line.
        const nx = -dy / length * width * 0.5;
        const ny = dx / length * width * 0.5;
        const t = (@as(f32, white_block) / 2.0) / atlas_size;
        const v = self.vertices[self.len..][0..6];
        v[0] = .{ .pos = .{ x0 + nx, y0 + ny }, .uv = .{ t, t }, .colour = colour };
        v[1] = .{ .pos = .{ x1 + nx, y1 + ny }, .uv = .{ t, t }, .colour = colour };
        v[2] = .{ .pos = .{ x1 - nx, y1 - ny }, .uv = .{ t, t }, .colour = colour };
        v[3] = v[0];
        v[4] = v[2];
        v[5] = .{ .pos = .{ x0 - nx, y0 - ny }, .uv = .{ t, t }, .colour = colour };
        self.len += 6;
    }

    /// A solid rectangle.
    pub fn rect(self: *Batch, x: f32, y: f32, w: f32, h: f32, colour: Colour) void {
        const t = (@as(f32, white_block) / 2.0) / atlas_size;
        self.quad(x, y, x + w, y + h, .{ t, t }, .{ t, t }, colour);
    }

    /// Draws `text` (UTF-8) with its top-left corner at (x, y), snapped to whole pixels.
    /// Returns the x after the last glyph.
    pub fn text(self: *Batch, x: f32, y: f32, string: []const u8, colour: Colour) f32 {
        return self.textWith(x, y, string, colour, false);
    }

    /// As `text`, with the fixed-width glyphs (`Font.addMono`) where there are any.
    pub fn textMono(self: *Batch, x: f32, y: f32, string: []const u8, colour: Colour) f32 {
        return self.textWith(x, y, string, colour, true);
    }

    fn textWith(self: *Batch, x: f32, y: f32, string: []const u8, colour: Colour, mono: bool) f32 {
        if (!mono) if (self.font.shaped(string)) |s| return self.textShaped(x, y, s, colour);
        var pen = @round(x);
        const baseline = @round(y) + @round(self.font.ascent);
        var it: Codepoints = .{ .bytes = string };
        while (it.next()) |cp| {
            const g = self.font.glyphOf(cp, mono);
            if (g.w > 0 and g.h > 0) {
                self.glyphQuad(pen + @as(f32, @floatFromInt(g.left)), baseline - @as(f32, @floatFromInt(g.top)), g.*, colour);
            }
            pen += @round(g.advance);
        }
        return pen;
    }

    /// A shaped string's glyphs, the origin and baseline snapped as in `textWith`.
    fn textShaped(self: *Batch, x: f32, y: f32, s: shape.Shaped, colour: Colour) f32 {
        const origin = @round(x);
        const baseline = @round(y) + @round(self.font.ascent);
        for (s.glyphs) |p| {
            if (p.g.w == 0 or p.g.h == 0) continue;
            self.glyphQuad(origin + @as(f32, @floatFromInt(p.x + p.g.left)), baseline - @as(f32, @floatFromInt(p.y + p.g.top)), p.g, colour);
        }
        return origin + s.width;
    }

    /// Glyph `g` with its bitmap's top-left corner at (gx, gy).
    fn glyphQuad(self: *Batch, gx: f32, gy: f32, g: Glyph, colour: Colour) void {
        const s: f32 = atlas_size;
        self.quad(
            gx,
            gy,
            gx + @as(f32, @floatFromInt(g.w)),
            gy + @as(f32, @floatFromInt(g.h)),
            .{ @as(f32, @floatFromInt(g.x)) / s, @as(f32, @floatFromInt(g.y)) / s },
            .{ @as(f32, @floatFromInt(g.x + g.w)) / s, @as(f32, @floatFromInt(g.y + g.h)) / s },
            colour,
        );
    }

    /// Text on a dark backing, so it stays readable over traces. Returns the x after it.
    pub fn label(self: *Batch, x: f32, y: f32, string: []const u8, colour: Colour) f32 {
        const w = self.font.width(string);
        self.rect(@round(x) - 3, @round(y) - 1, @round(w) + 6, @round(self.font.line_height) + 2, theme.label_backing);
        return self.text(x, y, string, colour) + 3;
    }
};

test "code points of text that is not valid UTF-8 never read past the end" {
    const expect = std.testing.expectEqual;
    // Valid: one, two and three bytes.
    var it: Codepoints = .{ .bytes = "a\u{e9}\u{3c3}\u{2013}" };
    try expect('a', it.next().?);
    try expect(0xe9, it.next().?);
    try expect(0x3c3, it.next().?);
    try expect(0x2013, it.next().?);
    try expect(null, it.next());
    // Cut in the middle of a two-byte and of a three-byte character.
    it = .{ .bytes = "ab\xc3" };
    try expect('a', it.next().?);
    try expect('b', it.next().?);
    try expect(0xFFFD, it.next().?);
    try expect(null, it.next());
    it = .{ .bytes = "\xe2\x80" };
    try expect(0xFFFD, it.next().?);
    try expect(null, it.next());
    // A continuation byte on its own, and a lead byte followed by something else.
    it = .{ .bytes = "\x80x\xc3y" };
    try expect(0xFFFD, it.next().?);
    try expect('x', it.next().?);
    try expect(0xFFFD, it.next().?);
    try expect('y', it.next().?);
    try expect(null, it.next());
}

test "the atlas packs glyphs on shelves until it has no room, and then places nothing" {
    const expect = std.testing.expectEqual;
    var pen: Font.Pen = .{};
    // The first beside the white block, the next after it with a pixel between.
    try expect([2]usize{ 5, 1 }, pen.fit(10, 12).?);
    try expect([2]usize{ 16, 1 }, pen.fit(8, 14).?);
    // One that does not fit across goes to a new shelf below the tallest of this one.
    try expect([2]usize{ 1, 16 }, pen.fit(atlas_size - 20, 9).?);
    // Fill: 24 x 24 glyphs to the bottom; then nothing fits, however small.
    var n: usize = 0;
    while (pen.fit(24, 24)) |at| : (n += 1) {
        try std.testing.expect(at[0] + 24 < atlas_size and at[1] + 24 < atlas_size);
    }
    try std.testing.expect(n > 300);
    try expect(null, pen.fit(24, 24));
    try expect(null, pen.fit(1, 30));
}

test "fixed-width text uses the fixed-width glyphs where there are, the ordinary ones elsewhere" {
    var atlas: [1]u8 = .{0};
    var f: Font = .{ .atlas = &atlas, .px = 14 };
    for (&f.glyphs, 0..) |*g, k| g.* = .{ .x = @intCast(10 + k), .y = 1, .w = 1, .h = 1, .advance = 7 };
    for (&f.mono, 0..) |*g, k| g.* = .{ .x = @intCast(300 + k), .y = 2, .w = 1, .h = 1, .advance = 9 };
    // Without `has_mono` (no monospace face, or no room): the ordinary glyphs.
    try std.testing.expectEqual(21, f.widthMono("abc"));
    f.has_mono = true;
    try std.testing.expectEqual(27, f.widthMono("abc"));
    try std.testing.expectEqual(21, f.width("abc"));
    // Beyond ASCII ("µ"), and an ASCII character the face lacked ('b'): ordinary.
    f.mono['b' - mono_first] = .{};
    try std.testing.expectEqual(9 + 7 + 9, f.widthMono("a\u{b5}c"));
    try std.testing.expectEqual(9 + 7 + 9, f.widthMono("abc"));
    // Drawn: the quads' atlas positions say which glyph each is, the pen moves by its
    // advance.
    var vertices: [6 * 4]Vertex = undefined;
    var batch: Batch = .{ .font = &f, .vertices = &vertices };
    try std.testing.expectEqual(25, batch.textMono(0, 0, "abc", .{ 255, 255, 255, 255 }));
    const s: f32 = atlas_size;
    try std.testing.expectEqual(@as(f32, 300 + 'a' - 32) / s, vertices[0].uv[0]);
    try std.testing.expectEqual(@as(f32, 10 + 'b' - 32) / s, vertices[6].uv[0]);
    try std.testing.expectEqual(9, vertices[6].pos[0]);
    try std.testing.expectEqual(16, vertices[12].pos[0]);
    batch.clear();
    _ = batch.text(0, 0, "a", .{ 255, 255, 255, 255 });
    try std.testing.expectEqual(@as(f32, 10 + 'a' - 32) / s, vertices[0].uv[0]);
}
