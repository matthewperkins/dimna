//! Text for the display: one font at one pixel size, rasterized by FreeType into a
//! single-channel atlas (Latin-1: enough for labels, numbers and units such as µV), and laid
//! out as textured quads. No shaping: one glyph per code point, left to right.
//!
//! The atlas's top-left corner holds a block of full coverage, so solid rectangles go
//! through the same pipeline as text (`Batch.rect`).

const std = @import("std");
const c = @import("gui_c");
const log = std.log.scoped(.font);

pub const atlas_size = 512;
const first_cp = 32;
const last_cp = 255;
/// A few characters beyond Latin-1 that labels use: sigma, en dash, right arrow, a note.
const extra_cps = [_]u21{ 0x03C3, 0x2013, 0x2192, 0x266A };
const white_block = 4;

pub const Vertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    colour: [4]u8,
};

pub const Colour = [4]u8;

const Glyph = struct {
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

    /// Loads the font fontconfig picks for `family` (e.g. "sans-serif", "monospace",
    /// "Lato") at `px` pixels.
    pub fn init(gpa: std.mem.Allocator, family: [:0]const u8, px: u32) !Font {
        var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        const path = try findFont(family, &path_buf);

        var lib: c.FT_Library = null;
        if (c.FT_Init_FreeType(&lib) != 0) return error.FreeType;
        defer _ = c.FT_Done_FreeType(lib);
        var face: c.FT_Face = null;
        if (c.FT_New_Face(lib, path.ptr, 0, &face) != 0) {
            log.err("cannot load font {s}", .{path});
            return error.FontNotLoaded;
        }
        defer _ = c.FT_Done_Face(face);
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
        var pen_x: usize = white_block + 1;
        var pen_y: usize = 1;
        var shelf_h: usize = white_block;
        var index: usize = 0;
        while (index < font.glyphs.len) : (index += 1) {
            const cp: u32 = if (index <= last_cp - first_cp) @intCast(first_cp + index) else extra_cps[index - (last_cp - first_cp + 1)];
            // A character the font lacks stays empty (it is then drawn as "?").
            if (c.FT_Get_Char_Index(face, cp) == 0) continue;
            if (c.FT_Load_Char(face, cp, c.FT_LOAD_RENDER) != 0) continue;
            const slot = face.*.glyph;
            const bm = slot.*.bitmap;
            const w: usize = bm.width;
            const h: usize = bm.rows;
            if (pen_x + w + 1 > atlas_size) {
                pen_x = 1;
                pen_y += shelf_h + 1;
                shelf_h = 0;
            }
            if (pen_y + h + 1 > atlas_size) {
                log.warn("font atlas full at code point {d}; later glyphs are missing", .{cp});
                break;
            }
            for (0..h) |row| {
                const src: [*]const u8 = bm.buffer + row * @as(usize, @intCast(bm.pitch));
                @memcpy(atlas[(pen_y + row) * atlas_size + pen_x ..][0..w], src[0..w]);
            }
            font.glyphs[index] = .{
                .x = @intCast(pen_x),
                .y = @intCast(pen_y),
                .w = @intCast(w),
                .h = @intCast(h),
                .left = @intCast(slot.*.bitmap_left),
                .top = @intCast(slot.*.bitmap_top),
                .advance = @as(f32, @floatFromInt(slot.*.advance.x)) / 64.0,
            };
            pen_x += w + 1;
            shelf_h = @max(shelf_h, h);
        }
        log.info("font {s} at {d} px", .{ path, px });
        return font;
    }

    pub fn deinit(self: *Font, gpa: std.mem.Allocator) void {
        gpa.free(self.atlas);
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
        var w: f32 = 0;
        var it: Codepoints = .{ .bytes = text };
        while (it.next()) |cp| w += self.glyph(cp).advance;
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

fn findFont(family: [:0]const u8, buf: *[std.fs.max_path_bytes:0]u8) ![:0]const u8 {
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
        var pen = @round(x);
        const baseline = @round(y) + @round(self.font.ascent);
        var it: Codepoints = .{ .bytes = string };
        while (it.next()) |cp| {
            const g = self.font.glyph(cp);
            if (g.w > 0 and g.h > 0) {
                const gx = pen + @as(f32, @floatFromInt(g.left));
                const gy = baseline - @as(f32, @floatFromInt(g.top));
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
            pen += @round(g.advance);
        }
        return pen;
    }

    /// Text on a dark backing, so it stays readable over traces. Returns the x after it.
    pub fn label(self: *Batch, x: f32, y: f32, string: []const u8, colour: Colour) f32 {
        const w = self.font.width(string);
        self.rect(@round(x) - 3, @round(y) - 1, @round(w) + 6, @round(self.font.line_height) + 2, .{ 8, 10, 14, 200 });
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
