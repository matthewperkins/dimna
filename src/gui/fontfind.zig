//! Finding font files: the three lookups text needs, and the choice of this system's
//! backend, at compile time (there is no indirect call). Linux: `fontfind_fontconfig.zig`.
//! Everything after a lookup is shared: FreeType opens the file, HarfBuzz and FriBidi
//! shape (`font.zig`, `shape.zig`).
//!
//! What a backend must understand: exactly the patterns the program asks for, which are
//! fontconfig's syntax:
//!
//! - a family or a generic name: the config's `font` (default `sans-serif`; any name the
//!   user writes, such as `Lato`), given to `Font.init` by the display, the control window
//!   and the tiles; `DIMNA_FIT_FONT` or `sans-serif` in the control window's fit check;
//!   `Lato` and `DejaVu Sans` in the tests (`findFont`);
//! - `monospace`, for the display's fixed-width glyphs (`Font.addMono`, `findFont`);
//! - `sans-serif:charset=<hex>`: a sans-serif font that has the code point `<hex>`
//!   (lower-case hexadecimal, no prefix), for a symbol the primary font lacks (`findFont`,
//!   from `Font.init`) and for a character no named font has (`Matcher.match` without a
//!   family, from `shape.zig`);
//! - the named fallbacks `Noto Sans CJK SC`, `Vazirmatn`, `Noto Sans Arabic`, each as both
//!   the pattern and the family that must match (`Matcher.match`);
//! - for `anyFontHas`, code points, not a pattern: the samples of the languages that need a
//!   font of their own (`i18n.needs`: Chinese, Persian).
//!
//! What "no such font" looks like:
//!
//! - `findFont`: `error.FontNotFound` (nothing matched, the match names no file, or its path
//!   does not fit the buffer), or `error.Fontconfig` (the lookup could not start, or the
//!   pattern could not be read). A family that is not installed is not an error with
//!   fontconfig: it answers with the font it substitutes.
//! - `anyFontHas`: false (also when the lookup itself fails).
//! - `Matcher.match`: null. With a family, also null unless one of the found font's family
//!   names is that family, ignoring ASCII case (fontconfig always offers something). A
//!   `Matcher` whose `init` could not load its configuration matches nothing.
//!
//! A path found is a zero-terminated path of a file FreeType can open (`FT_New_Face`);
//! `Matcher.match` also gives the face's index in it (a collection holds several),
//! `findFont`'s callers open face 0.

const std = @import("std");
const builtin = @import("builtin");

const backend = switch (builtin.os.tag) {
    .linux => @import("fontfind_fontconfig.zig"),
    .macos => @import("fontfind_coretext.zig"),
    else => @compileError("dimna has no font lookup for this system yet"),
};

/// The path of the font file for `pattern` (see above), written into `buf`.
pub const findFont = backend.findFont;
/// Whether some installed font has every one of these code points.
pub const anyFontHas = backend.anyFontHas;
/// A font file's path (in the caller's buffer) and the face's index in it.
pub const Match = backend.Match;
/// Lookups kept for a while (a shaping engine's life): `init()`, `deinit()`, and
/// `match(pattern, family, buf)`, the font for a pattern, with a family only if it is
/// that family.
pub const Matcher = backend.Matcher;

test "anyFontHas: Latin yes, an unassigned code point no" {
    try std.testing.expect(anyFontHas(&.{ 'A', 'z' }));
    try std.testing.expect(!anyFontHas(&.{0x10FFFD}));
}
