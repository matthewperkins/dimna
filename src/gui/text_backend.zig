//! Text's system-specific part: font lookup, faces, glyph coverage, fallback fonts, bidi and
//! shaping. This file holds what the backends and their callers (`font.zig`, `shape.zig`)
//! agree on and the choice of this system's backend, at compile time: the types are the
//! backend's own, so a caller calls the backend's functions directly; there is no indirect
//! call. Linux uses `text_freetype.zig` (FreeType; HarfBuzz and FriBidi loaded at run time),
//! macOS `text_coretext.zig` (Core Text, CoreGraphics, ICU: all macOS's own).
//!
//! What is shared policy and stays in `font.zig` and `shape.zig`: the fixed glyphs and their
//! fast path; whether a string needs shaping at all; the paragraph direction rule and the
//! isolation of Latin and digit stretches inside right-to-left text (as code points, so
//! every backend lays out the same isolated string); the cache of laid-out strings; the
//! atlas, its packing, its dirty rows, "atlas full" and the missing glyph (face 0, glyph 0);
//! glyphs rasterised on demand, keyed by (face index, glyph id); the rounding of offsets and
//! advances to whole pixels. What is the backend's: which face draws a character (the
//! fallback order and the fallbacks themselves, found while laying out), how a fallback is
//! scaled to the primary, bidi levels and visual order, shaping.
//!
//! What a backend must offer, because the callers use it:
//!
//! - `findFont(pattern, buf)`: the name of the font for a pattern, with `fontfind`'s meaning
//!   (fontconfig's syntax; its errors); what `Face.open` takes, with index 0, and what the
//!   log shows. FreeType: a file's path. Core Text: the pattern as it will be made and the
//!   font's PostScript name (`sans-serif = .SFNS-Regular`). A family that is not installed
//!   is no error: another font stands in (fontconfig's substitute; Core Text: the system
//!   font, logged).
//! - `Library`: `init() !Library` (`error.FreeType` if FreeType cannot start; Core Text
//!   needs nothing started), `deinit()`. Faces are opened from one and closed before it.
//! - `Face`: one font at one size, for the fixed glyphs (`font.zig`).
//!   - `open(lib, name, index) !Face` (`error.FontNotLoaded`), `deinit()`.
//!   - `setPixelSize(px) !void`: an em of `px` pixels (`error.FreeType`, `error.CoreText`).
//!   - Metrics at that size: `ascent()` (top of the line to the baseline) and
//!     `lineHeight()`, in whole pixels (as FreeType rounds a scalable font's: the ascent
//!     up, the line height to the nearest pixel).
//!   - `glyphIndex(cp) u32`: the glyph for a code point, 0 if the face has none.
//!   - `render(gid) ?Coverage`: the glyph's bitmap (null: cannot be drawn). Valid until the
//!     next call on this face. The caller copies it into the atlas.
//! - `Fonts`: the fonts of one shaping engine, by index (`u8`; 0 is the primary).
//!   - `init(gpa, lib, primary, px, line_height) Fonts`: takes `lib` and `primary` (set to
//!     `px`, with that line height); may load fallbacks now (and log them). `deinit()`.
//!   - `glyphIndex(face, cp) u32` (0: none), `covers(face, cp) bool`, `render(face, gid)
//!     ?Coverage` (as `Face.render`).
//!   - `mapSimple(cps, out)`: for laying out without shaping, one `FaceGlyph` per code
//!     point, in logical order, each from the face that draws it (found now if need be).
//!     The caller places them left to right by their rendered advances.
//!   - `layout(l, text, marks, base, out) !void`: a paragraph laid out: `text` as the
//!     shared code isolated it (`marks[k]` true for the isolates it put in, U+2066 and
//!     U+2069, which draw nothing), with base direction `base` (`bidi.par_ltr`,
//!     `bidi.par_rtl`, or `bidi.par_on`: from the first strong letter); appends to `out`
//!     the glyphs in visual order, left to right, each with its face (found now if need
//!     be), glyph id, offsets and advance. A glyph may have no advance and no ink; the
//!     isolate marks' glyphs may be left out or given (as such). An error (out of memory,
//!     or the libraries failed) leaves `out` to be discarded: the caller lays the string out
//!     with `mapSimple` instead.
//!   - Fields the callers read: `nfaces`, and for the tests `named` (the primary and the
//!     named fallbacks; Core Text has none: 1), `cap_px` (the primary's capital height in
//!     pixels), `faces[k].line_height` (face `k`'s own), `capPx(k)` (face `k`'s capital, or
//!     alef, height in pixels at its size; FreeType scales fallbacks to the primary's
//!     capitals, Core Text does not).
//! - `shaping() ?*const Shaping`: whether this system can shape (bidi and joined scripts),
//!   null if not (logged once by the backend). Safe from any thread; the first call may
//!   load libraries. `Fonts.layout` and `bidiTypes` take what it returned.
//! - `bidiTypes(l, cps, types)`: each code point's bidi class, as the values in `bidi`
//!   below (others may be any other value); what the shared code decides the paragraph
//!   direction and the isolation with.
//!
//! Glyph ids are the face's own and only mean something to the face they came from; the
//! shared code keys its glyph map on (face index, id).

const std = @import("std");
const builtin = @import("builtin");

const backend = switch (builtin.os.tag) {
    .linux => @import("text_freetype.zig"),
    .macos => @import("text_coretext.zig"),
    else => @compileError("dimna has no text backend for this system yet"),
};

pub const findFont = backend.findFont;
pub const Library = backend.Library;
pub const Face = backend.Face;
pub const Fonts = backend.Fonts;
pub const Shaping = backend.Shaping;
pub const shaping = backend.shaping;
pub const bidiTypes = backend.bidiTypes;

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

/// A glyph from a face (`Fonts.mapSimple`).
pub const FaceGlyph = struct {
    face: u8,
    gid: u32,
};

/// A glyph of a laid-out paragraph (`Fonts.layout`): which face and glyph, its offset from
/// the pen (x right, y up) and the pen's advance after it, in pixels, not rounded.
pub const RunGlyph = struct {
    face: u8,
    gid: u32,
    x_offset: f32,
    y_offset: f32,
    x_advance: f32,
};

/// The bidi classes the shared code looks at (`bidiTypes`), and the paragraph directions
/// (`Fonts.layout`). The values are FriBidi's (fribidi-bidi-types.h: its masks
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
    // The tokens of the libraries' C names, and the import of the translated headers; then
    // Core Text's, CoreGraphics', CoreFoundation's and ICU's.
    const forbidden_ft = [_][]const u8{ "gui_c", "FT_", "hb_", "fribidi_" };
    const forbidden_ct = [_][]const u8{ "CTFont", "CTLine", "CGContext", "CFRelease", "u_charDirection" };
    const forbidden = forbidden_ft ++ forbidden_ct;
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
    // The backends do use every one of them, so the spellings looked for are the ones in use.
    const ft = @embedFile("text_freetype.zig");
    for (forbidden_ft) |word| try std.testing.expect(std.mem.indexOf(u8, ft, word) != null);
    const ct = @embedFile("text_coretext.zig");
    for (forbidden_ct) |word| try std.testing.expect(std.mem.indexOf(u8, ct, word) != null);
    try std.testing.expectEqual(0, bad);
}
