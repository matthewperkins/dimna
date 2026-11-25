//! Text's system-specific part: font lookup, faces, glyph coverage, bidi and shaping. This
//! file holds what the backends and their callers (`font.zig`, `shape.zig`) agree on and the
//! choice of this system's backend, at compile time: the types are the backend's own, so a
//! caller calls the backend's functions directly; there is no indirect call. For now both
//! systems use `text_freetype.zig` (FreeType; HarfBuzz and FriBidi loaded at run time).
//!
//! Everything else about text is shared policy and stays in `font.zig` and `shape.zig`: the
//! fast path for the fixed glyphs, the atlas and its packing, the cache, the paragraph
//! direction and the isolation of Latin text inside right-to-left text, the visual order of
//! the runs (rule L2), the fallback order, which fonts are scaled to what, the rounding of
//! advances to whole pixels, the missing glyph.
//!
//! What a backend must offer, because the callers use it:
//!
//! - Font lookup, with `fontfind`'s meaning (patterns in fontconfig's syntax, the errors
//!   and nulls it documents): `findFont(pattern, buf)`, the name of the font for a pattern
//!   (what `Face.open` takes, with index 0; also what the log shows); `Matcher` (`init()`,
//!   `deinit()`, `match(pattern, family, buf)` giving a `Match`, `.path` and `.index`), the
//!   lookups an engine keeps for its life, for the named fallbacks and for a character no
//!   named font has.
//! - `Library`: `init() !Library` (`error.FreeType` if it cannot start), `deinit()`. Faces
//!   are opened from one and closed before it.
//! - `Face`: one font at one size.
//!   - `open(lib, name, index) !Face` (`error.FontNotLoaded`), `deinit()`.
//!   - Sizes: `setPixelSize(px) !void` (an em of `px` pixels; `error.FreeType`), the
//!     primary, fixed-width and symbol fonts; `setEmSize(em_px) ?f32`, an em of `em_px`
//!     pixels (as near as the backend sets sizes), giving the line height at that size
//!     (null: cannot be set); `sizeToLineHeight(target) ?f32`, the size at which the line
//!     height is nearest `target` pixels, giving that line height (null: not scalable).
//!   - Metrics at the size set: `ascent()` (top of the line to the baseline) and
//!     `lineHeight()`, in pixels; `ppem()`, the em in whole pixels.
//!   - `heightRatio(cp) ?f32`: the height of `cp`'s glyph outline as a fraction of the em,
//!     unscaled (null: no such glyph, an empty one, or a font that is not scalable); what
//!     `shape.zig` measures capitals (or alef) with to scale the fallbacks.
//!   - `glyphIndex(cp) u32`: the glyph for a code point, 0 if the face has none.
//!   - `render(gid) ?Coverage`: the glyph's bitmap at the size set (null: cannot be drawn).
//!     Valid until the next call on this face. The caller copies it into the atlas.
//! - `shaping() ?*const Shaping`: whether this system can shape (bidi and joined scripts),
//!   null if not (logged once by the backend). Safe from any thread; the first call may
//!   load libraries. Everything below takes the `Shaping` it returned.
//! - `bidiTypes(l, cps, types)`: each code point's bidi class, as the values in `bidi`
//!   below (others may be any other value).
//! - `Shaper`: what one engine keeps for bidi and shaping (buffers, scratch), `.{}` to
//!   start, `deinit(gpa)`.
//!   - `embeddingLevels(gpa, l, text, base, levels) !void`: the embedding level of each
//!     code point of a paragraph (`text`, with any isolates the caller put in), with base
//!     direction `base` (`bidi.par_ltr`, `bidi.par_rtl`, or `bidi.par_on`: from the first
//!     strong letter), rule L1 applied (trailing white space to the paragraph's level);
//!     `error.Bidi` if that failed. The caller orders the runs itself.
//!   - `shape(l, face, text, start, end, rtl) !Run`: `text[start..end]`, all in `face` and
//!     one direction, shaped (`text` whole is the context); the glyphs in visual order (left
//!     to right), `error.Shaping` if it could not. A `Run` is valid until the next call on
//!     this `Shaper`.
//!
//! Glyph ids (`Face.glyphIndex`, `Run`) are the face's own and only mean something to the
//! face they came from; the shared code keys its glyph map on (face, id).

const std = @import("std");
const builtin = @import("builtin");

const backend = switch (builtin.os.tag) {
    .linux, .macos => @import("text_freetype.zig"),
    else => @compileError("dimna has no text backend for this system yet"),
};

pub const findFont = backend.findFont;
pub const Matcher = backend.Matcher;
pub const Match = backend.Match;
pub const Library = backend.Library;
pub const Face = backend.Face;
pub const Shaping = backend.Shaping;
pub const shaping = backend.shaping;
pub const bidiTypes = backend.bidiTypes;
pub const Shaper = backend.Shaper;
pub const Run = backend.Run;

/// A glyph's bitmap: `rows` rows of `width` coverage bytes (0 none, 255 full), row `r` at
/// `pixels + r * pitch` (`pitch` is not negative where there are rows), placed `left` pixels
/// right of the pen and `top` pixels above the baseline (to its top row); the pen then moves
/// `advance` pixels.
pub const Coverage = struct {
    width: usize,
    rows: usize,
    pitch: i32,
    pixels: ?[*]const u8,
    left: i32,
    top: i32,
    advance: f32,
    /// False: a bitmap of another kind (colour), which the atlas cannot hold.
    gray: bool,
};

/// A glyph of a shaped run: which glyph of the face, its offset from the pen (x right, y up)
/// and the pen's advance after it, in pixels, not rounded.
pub const RunGlyph = struct {
    gid: u32,
    x_offset: f32,
    y_offset: f32,
    x_advance: f32,
};

/// The bidi classes the shared code looks at (`bidiTypes`), and the paragraph directions
/// (`Shaper.embeddingLevels`). The values are FriBidi's (fribidi-bidi-types.h: its masks
/// combined as there), so the FreeType backend passes FriBidi's through as they are; another
/// backend gives these values for these classes.
pub const bidi = struct {
    pub const L: u32 = 0x110;
    pub const R: u32 = 0x111;
    pub const AL: u32 = 0x113;
    pub const EN: u32 = 0x220;
    pub const ES: u32 = 0x10420;
    pub const ET: u32 = 0x20420;
    pub const NSM: u32 = 0x80020;
    pub const BS: u32 = 0x202840;
    /// The direction from the first strong character (FRIBIDI_PAR_ON).
    pub const par_on: u32 = 0x40;
    /// Left to right and right to left (FRIBIDI_PAR_LTR and _RTL: the types of L and R).
    pub const par_ltr: u32 = L;
    pub const par_rtl: u32 = R;
};

test "the shared text code calls no text library: everything goes through this file" {
    // The tokens of the libraries' C names, and the import of the translated headers.
    const forbidden = [_][]const u8{ "gui_c", "FT_", "hb_", "fribidi_" };
    const Shared = struct { name: []const u8, text: []const u8, has: []const u8 };
    const shared = [_]Shared{
        .{ .name = "font.zig", .text = @embedFile("font.zig"), .has = "pub const Font = struct" },
        .{ .name = "shape.zig", .text = @embedFile("shape.zig"), .has = "pub const Engine = struct" },
    };
    var bad: usize = 0;
    for (shared) |file| {
        // The file read is the one meant, not an empty or other one.
        try std.testing.expect(std.mem.indexOf(u8, file.text, file.has) != null);
        var line_no: usize = 1;
        var lines = std.mem.splitScalar(u8, file.text, '\n');
        while (lines.next()) |line| : (line_no += 1) {
            for (forbidden) |word| if (std.mem.indexOf(u8, line, word) != null) {
                std.debug.print("src/gui/{s}:{d}: {s} belongs in the text backend: {s}\n", .{ file.name, line_no, word, std.mem.trim(u8, line, " ") });
                bad += 1;
            };
        }
    }
    // The backend does use every one of them, so the spellings looked for are the ones in use.
    const ft = @embedFile("text_freetype.zig");
    for (forbidden) |word| try std.testing.expect(std.mem.indexOf(u8, ft, word) != null);
    try std.testing.expectEqual(0, bad);
}
