//! The text backend on Core Text (`text_backend.zig` says what a backend offers), for macOS:
//! fonts, glyph coverage, fallbacks, bidi and shaping all by Core Text, CoreGraphics and
//! CoreFoundation, and bidi classes by ICU (`libicucore`). Nothing is loaded at run time and
//! nothing outside macOS is needed. Their C interfaces are declared by hand below (some 45
//! functions; the headers translate to many thousands of declarations); every struct they
//! return (`CGRect`, `CFRange` is only passed) is a plain C struct of doubles, which Zig's
//! C calling convention returns as C does, so no C file is needed.
//!
//! How each pattern is answered (`findFont`, `Face.open`):
//!
//! - `sans-serif` (also `sans` and the empty name): the system's interface font for labels
//!   (`CTFontCreateUIFontForLanguage`, `kCTFontUIFontLabel`: SF), with Core Text's own
//!   optical sizing (the optical size follows the pixel size); `monospace` (also `mono`):
//!   the user's fixed-pitch interface font (Menlo unless changed).
//! - Another name is a family: used if a family of that name (ignoring ASCII case) is among
//!   the installed families, and then made with activation and downloading turned off. A
//!   family that is not installed is never asked for (Core Text would offer to download
//!   it): `findFont` gives the system font instead and says so in the log.
//! - `<name>:charset=<hex>`: the font Core Text falls back to for that character from the
//!   font for the name (`CTFontCreateForString`); `error.FontNotFound` if that is LastResort
//!   (the font of boxes for characters no font has) or lacks the character.
//!
//! What `findFont` writes, what `Face.open` takes and the log shows: the pattern as it will
//! be made (the family as Core Text spells it, or `sans-serif` for one not installed), then
//! ` = ` and the PostScript name of the font it gave, e.g. `sans-serif = .SFNS-Regular`.
//! `Face.open` reads the part before ` = ` and makes the font again from it (a hidden system
//! font such as `.SFNS-Regular` cannot be made by its name).
//!
//! Sizes are pixels: a font of size `px` (points) drawn into a bitmap context with no scale
//! has an em of `px` pixels. Metrics are rounded as FreeType rounds a scalable font's
//! (`ascent` up, the line height to the nearest pixel), so rows of text stay a whole number
//! of pixels apart, as they are with FreeType. Glyphs are drawn into an 8-bit alpha-only
//! bitmap context with font smoothing, subpixel positioning and subpixel quantization off,
//! at a whole-pixel pen; the bitmap is the glyph's bounding box widened by a pixel each
//! side, then trimmed to its ink. Core Text does not hint: advances are fractional, and the
//! shared code rounds them as it rounds FreeType's.
//!
//! Faces of an engine (`Fonts`): the primary (0), then each font Core Text used in a line
//! or offered for a character, in the order first seen, the same font (`CFEqual`) being one
//! face. There are no named fallbacks and fallbacks are not scaled: Core Text's own choice
//! (SF Arabic, PingFang) at the primary's size. Past `max_faces` a font gets no face: its
//! glyphs are drawn as the primary's missing glyph (logged once).
//!
//! Every CF object made here is released; `live` counts those made and not yet released,
//! and a test checks it returns to zero.

const std = @import("std");
const text_backend = @import("text_backend.zig");
const Coverage = text_backend.Coverage;
const RunGlyph = text_backend.RunGlyph;
const bidi = text_backend.bidi;
const log = std.log.scoped(.font);

// ---- CoreFoundation, CoreGraphics, Core Text and ICU ----

const CFIndex = isize;
const Boolean = u8;
const CGFloat = f64;
const CFType = anyopaque;
const CFString = opaque {};
const CFArray = opaque {};
const CFDictionary = opaque {};
const CFAttributedString = opaque {};
const CTFont = opaque {};
const CTFontDescriptor = opaque {};
const CTParagraphStyle = opaque {};
const CTTypesetter = opaque {};
const CTLine = opaque {};
const CTRun = opaque {};
const CGContext = opaque {};
const CFRange = extern struct { location: CFIndex, length: CFIndex };
const CGPoint = extern struct { x: CGFloat, y: CGFloat };
const CGSize = extern struct { width: CGFloat, height: CGFloat };
const CGRect = extern struct { origin: CGPoint, size: CGSize };
/// CFDictionaryKeyCallBacks and CFDictionaryValueCallBacks: only their addresses are used.
const DictionaryCallBacks = extern struct { fields: [6]usize };
const ParagraphStyleSetting = extern struct { spec: u32, size: usize, value: *const anyopaque };

const kCFStringEncodingUTF8: u32 = 0x08000100;
/// CTFontUIFontType.
const kCTFontUIFontUserFixedPitch: u32 = 1;
const kCTFontUIFontLabel: u32 = 10;
/// CTFontOptions.
const kCTFontOptionsPreventAutoActivation: usize = 1 << 0;
const kCTFontOptionsPreventAutoDownload: usize = 1 << 1;
const kCTFontOrientationHorizontal: u32 = 1;
const kCTFontTraitColorGlyphs: u32 = 1 << 13;
const kCTParagraphStyleSpecifierBaseWritingDirection: u32 = 13;
/// CTWritingDirection (int8_t).
const kCTWritingDirectionNatural: i8 = -1;
const kCTWritingDirectionLeftToRight: i8 = 0;
const kCTWritingDirectionRightToLeft: i8 = 1;
const kCGImageAlphaOnly: u32 = 7;
/// The glyph Core Text puts where a character was deleted in shaping.
const deleted_glyph: u16 = 0xffff;

extern "c" fn CFRelease(cf: *const CFType) void;
extern "c" fn CFRetain(cf: *const CFType) *const CFType;
extern "c" fn CFEqual(a: *const CFType, b: *const CFType) Boolean;
extern "c" fn CFStringCreateWithBytes(alloc: ?*const anyopaque, bytes: [*]const u8, len: CFIndex, encoding: u32, external: Boolean) ?*const CFString;
extern "c" fn CFStringCreateWithCharacters(alloc: ?*const anyopaque, chars: [*]const u16, len: CFIndex) ?*const CFString;
extern "c" fn CFStringGetCString(s: *const CFString, buf: [*]u8, size: CFIndex, encoding: u32) Boolean;
extern "c" fn CFArrayGetCount(a: *const CFArray) CFIndex;
extern "c" fn CFArrayGetValueAtIndex(a: *const CFArray, i: CFIndex) ?*const CFType;
extern "c" fn CFDictionaryCreate(alloc: ?*const anyopaque, keys: [*]const *const CFType, values: [*]const *const CFType, n: CFIndex, key_callbacks: *const DictionaryCallBacks, value_callbacks: *const DictionaryCallBacks) ?*const CFDictionary;
extern "c" fn CFDictionaryGetValue(d: *const CFDictionary, key: *const CFType) ?*const CFType;
extern "c" fn CFAttributedStringCreate(alloc: ?*const anyopaque, s: *const CFString, attributes: *const CFDictionary) ?*const CFAttributedString;
extern "c" const kCFTypeDictionaryKeyCallBacks: DictionaryCallBacks;
extern "c" const kCFTypeDictionaryValueCallBacks: DictionaryCallBacks;
extern "c" const kCFBooleanFalse: *const CFType;

extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, width: usize, height: usize, bits_per_component: usize, bytes_per_row: usize, space: ?*const anyopaque, info: u32) ?*CGContext;
extern "c" fn CGContextRelease(cx: *CGContext) void;
extern "c" fn CGContextSetShouldAntialias(cx: *CGContext, on: bool) void;
extern "c" fn CGContextSetAllowsAntialiasing(cx: *CGContext, on: bool) void;
extern "c" fn CGContextSetAllowsFontSmoothing(cx: *CGContext, on: bool) void;
extern "c" fn CGContextSetShouldSmoothFonts(cx: *CGContext, on: bool) void;
extern "c" fn CGContextSetAllowsFontSubpixelPositioning(cx: *CGContext, on: bool) void;
extern "c" fn CGContextSetShouldSubpixelPositionFonts(cx: *CGContext, on: bool) void;
extern "c" fn CGContextSetAllowsFontSubpixelQuantization(cx: *CGContext, on: bool) void;
extern "c" fn CGContextSetShouldSubpixelQuantizeFonts(cx: *CGContext, on: bool) void;

extern "c" fn CTFontCreateUIFontForLanguage(ui_type: u32, size: CGFloat, language: ?*const CFString) ?*const CTFont;
extern "c" fn CTFontCreateForString(current: *const CTFont, string: *const CFString, range: CFRange) ?*const CTFont;
extern "c" fn CTFontCreateWithFontDescriptorAndOptions(d: *const CTFontDescriptor, size: CGFloat, matrix: ?*const anyopaque, options: usize) ?*const CTFont;
extern "c" fn CTFontCreateCopyWithAttributes(f: *const CTFont, size: CGFloat, matrix: ?*const anyopaque, attributes: ?*const CTFontDescriptor) ?*const CTFont;
extern "c" fn CTFontDescriptorCreateWithAttributes(attributes: *const CFDictionary) ?*const CTFontDescriptor;
extern "c" fn CTFontManagerCopyAvailableFontFamilyNames() ?*const CFArray;
extern "c" fn CTFontCopyPostScriptName(f: *const CTFont) ?*const CFString;
extern "c" fn CTFontCopyFamilyName(f: *const CTFont) ?*const CFString;
extern "c" fn CTFontCopyVariation(f: *const CTFont) ?*const CFDictionary;
extern "c" fn CTFontGetSize(f: *const CTFont) CGFloat;
extern "c" fn CTFontGetAscent(f: *const CTFont) CGFloat;
extern "c" fn CTFontGetDescent(f: *const CTFont) CGFloat;
extern "c" fn CTFontGetLeading(f: *const CTFont) CGFloat;
extern "c" fn CTFontGetSymbolicTraits(f: *const CTFont) u32;
extern "c" fn CTFontGetGlyphsForCharacters(f: *const CTFont, chars: [*]const u16, glyphs: [*]u16, count: CFIndex) bool;
extern "c" fn CTFontGetAdvancesForGlyphs(f: *const CTFont, orientation: u32, glyphs: [*]const u16, advances: ?[*]CGSize, count: CFIndex) f64;
extern "c" fn CTFontGetBoundingRectsForGlyphs(f: *const CTFont, orientation: u32, glyphs: [*]const u16, rects: ?[*]CGRect, count: CFIndex) CGRect;
extern "c" fn CTFontDrawGlyphs(f: *const CTFont, glyphs: [*]const u16, positions: [*]const CGPoint, count: usize, cx: *CGContext) void;
extern "c" fn CTParagraphStyleCreate(settings: [*]const ParagraphStyleSetting, count: usize) ?*const CTParagraphStyle;
extern "c" fn CTTypesetterCreateWithAttributedString(s: *const CFAttributedString) ?*const CTTypesetter;
extern "c" fn CTTypesetterCreateLine(ts: *const CTTypesetter, range: CFRange) ?*const CTLine;
extern "c" fn CTLineGetGlyphRuns(line: *const CTLine) *const CFArray;
extern "c" fn CTRunGetGlyphCount(run: *const CTRun) CFIndex;
extern "c" fn CTRunGetAttributes(run: *const CTRun) *const CFDictionary;
extern "c" fn CTRunGetGlyphs(run: *const CTRun, range: CFRange, buf: [*]u16) void;
extern "c" fn CTRunGetPositions(run: *const CTRun, range: CFRange, buf: [*]CGPoint) void;
extern "c" fn CTRunGetAdvances(run: *const CTRun, range: CFRange, buf: [*]CGSize) void;
extern "c" fn CTRunGetStringIndices(run: *const CTRun, range: CFRange, buf: [*]CFIndex) void;
extern "c" const kCTFontAttributeName: *const CFString;
extern "c" const kCTParagraphStyleAttributeName: *const CFString;
extern "c" const kCTFontFamilyNameAttribute: *const CFString;
extern "c" const kCTFontDownloadableAttribute: *const CFString;

/// ICU's UCharDirection of a code point (unicode/uchar.h; libicucore exports it unrenamed).
extern "c" fn u_charDirection(cp: i32) c_int;

/// CF objects made here and not yet released (`own`, `release`): for the test that checks
/// that everything made is released.
var live: std.atomic.Value(i64) = .init(0);

/// `x`, a CF object just made (or retained), counted as live.
fn own(x: anytype) @TypeOf(x) {
    if (x != null) _ = live.fetchAdd(1, .monotonic);
    return x;
}

fn release(cf: anytype) void {
    _ = live.fetchSub(1, .monotonic);
    CFRelease(@ptrCast(cf));
}

fn cfString(text: []const u8) ?*const CFString {
    return own(CFStringCreateWithBytes(null, text.ptr, @intCast(text.len), kCFStringEncodingUTF8, 0));
}

/// `s` as zero-terminated UTF-8 in `buf`, or null if it does not fit.
fn utf8(s: *const CFString, buf: []u8) ?[:0]const u8 {
    if (CFStringGetCString(s, buf.ptr, @intCast(buf.len), kCFStringEncodingUTF8) == 0) return null;
    const n = std.mem.indexOfScalar(u8, buf, 0) orelse return null;
    return buf[0..n :0];
}

/// `cp` in UTF-16 (one or two units; U+FFFD for what is not a character).
fn utf16(cp: u32, units: *[2]u16) []const u16 {
    if (cp < 0x10000) {
        units[0] = if (cp >= 0xd800 and cp <= 0xdfff) 0xfffd else @intCast(cp);
        return units[0..1];
    }
    if (cp > 0x10ffff) {
        units[0] = 0xfffd;
        return units[0..1];
    }
    const v = cp - 0x10000;
    units[0] = @intCast(0xd800 + (v >> 10));
    units[1] = @intCast(0xdc00 + (v & 0x3ff));
    return units[0..2];
}

/// The PostScript name of `f` in `buf` ("?" if it has none or it does not fit).
fn psName(f: *const CTFont, buf: []u8) []const u8 {
    const name = own(CTFontCopyPostScriptName(f)) orelse return "?";
    defer release(name);
    return utf8(name, buf) orelse "?";
}

fn isLastResort(f: *const CTFont) bool {
    var buf: [128]u8 = undefined;
    return std.mem.indexOf(u8, psName(f, &buf), "LastResort") != null;
}

/// Whether face `s` is font `b` (PostScript name `b_ps`): the same object, or the same
/// PostScript name, size and variation (each `CTFont` Core Text makes for a line or a
/// character is a new object, which `CFEqual` does not find equal to another made the same
/// way).
fn sameFont(s: *const State, b: *const CTFont, b_ps: []const u8) bool {
    const a = s.font;
    if (a == b) return true;
    if (CTFontGetSize(a) != CTFontGetSize(b)) return false;
    if (!std.mem.eql(u8, s.ps_buf[0..s.ps_len], b_ps)) return false;
    const va = own(CTFontCopyVariation(a));
    defer if (va) |v| release(v);
    const vb = own(CTFontCopyVariation(b));
    defer if (vb) |v| release(v);
    if (va == null or vb == null) return va == null and vb == null;
    return CFEqual(va.?, vb.?) != 0;
}

fn glyphOf(f: *const CTFont, cp: u32) u32 {
    var units: [2]u16 = undefined;
    const u = utf16(cp, &units);
    var glyphs: [2]u16 = .{ 0, 0 };
    if (!CTFontGetGlyphsForCharacters(f, u.ptr, &glyphs, @intCast(u.len))) return 0;
    return glyphs[0];
}

// ---- What a pattern asks for ----

/// A family (or a generic name), and a code point the font must have.
const Pattern = struct {
    family: []const u8,
    cp: ?u21 = null,
};

/// fontconfig's syntax as `fontfind.zig` describes it: a name, then `:`-separated
/// properties, of which only `charset=<hex>` is read. Null if the character set is not a
/// code point.
fn parse(text: []const u8) ?Pattern {
    var parts = std.mem.splitScalar(u8, text, ':');
    var p: Pattern = .{ .family = std.mem.trim(u8, parts.first(), " ") };
    while (parts.next()) |prop| {
        const name = "charset=";
        if (!std.mem.startsWith(u8, prop, name)) continue;
        p.cp = std.fmt.parseInt(u21, prop[name.len..], 16) catch return null;
    }
    return p;
}

/// The interface font kind for a generic name, or null for a family name.
fn generic(family: []const u8) ?u32 {
    for ([_][]const u8{ "", "sans-serif", "sans" }) |n| if (std.ascii.eqlIgnoreCase(family, n)) return kCTFontUIFontLabel;
    for ([_][]const u8{ "monospace", "mono" }) |n| if (std.ascii.eqlIgnoreCase(family, n)) return kCTFontUIFontUserFixedPitch;
    return null;
}

/// The installed family named `family` (ignoring ASCII case), as Core Text spells it, in
/// `buf`; null if there is none.
fn installedFamily(family: []const u8, buf: []u8) ?[]const u8 {
    const names = own(CTFontManagerCopyAvailableFontFamilyNames()) orelse return null;
    defer release(names);
    for (0..@intCast(CFArrayGetCount(names))) |i| {
        const s: *const CFString = @ptrCast(CFArrayGetValueAtIndex(names, @intCast(i)) orelse continue);
        const name = utf8(s, buf) orelse continue;
        if (std.ascii.eqlIgnoreCase(name, family)) return name;
    }
    return null;
}

/// The font for `p` at `size` (0: the kind's own size), owned by the caller; null if the
/// family is not installed (it is then not asked for), or Core Text has no font with the
/// character asked for.
fn fontFor(p: Pattern, size: f64) ?*const CTFont {
    const base = if (generic(p.family)) |kind| own(CTFontCreateUIFontForLanguage(kind, size, null)) orelse return null else blk: {
        var buf: [256]u8 = undefined;
        const installed = installedFamily(p.family, &buf) orelse return null;
        const name = cfString(installed) orelse return null;
        defer release(name);
        const keys = [_]*const CFType{ kCTFontFamilyNameAttribute, kCTFontDownloadableAttribute };
        const values = [_]*const CFType{ name, kCFBooleanFalse };
        const attrs = own(CFDictionaryCreate(null, &keys, &values, keys.len, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)) orelse return null;
        defer release(attrs);
        const desc = own(CTFontDescriptorCreateWithAttributes(attrs)) orelse return null;
        defer release(desc);
        break :blk own(CTFontCreateWithFontDescriptorAndOptions(desc, size, null, kCTFontOptionsPreventAutoActivation | kCTFontOptionsPreventAutoDownload)) orelse return null;
    };
    const cp = p.cp orelse return base;
    defer release(base);
    return fallbackFor(base, cp);
}

/// The font Core Text draws `cp` with when `base` is the font asked for (`base` itself if it
/// has it), owned by the caller; null if that is LastResort or lacks it.
fn fallbackFor(base: *const CTFont, cp: u32) ?*const CTFont {
    var units: [2]u16 = undefined;
    const u = utf16(cp, &units);
    const s = own(CFStringCreateWithCharacters(null, u.ptr, @intCast(u.len))) orelse return null;
    defer release(s);
    const f = own(CTFontCreateForString(base, s, .{ .location = 0, .length = @intCast(u.len) })) orelse return null;
    if (isLastResort(f) or glyphOf(f, cp) == 0) {
        release(f);
        return null;
    }
    return f;
}

/// Whether some installed font has every one of `cps` (`fontfind.anyFontHas` on macOS): the
/// font Core Text draws the first with must have the others too. False for none.
pub fn anyFontHas(cps: []const u32) bool {
    if (cps.len == 0) return false;
    const base = own(CTFontCreateUIFontForLanguage(kCTFontUIFontLabel, 0, null)) orelse return false;
    defer release(base);
    const f = fallbackFor(base, cps[0]) orelse return false;
    defer release(f);
    for (cps) |cp| if (glyphOf(f, cp) == 0) return false;
    return true;
}

/// What separates the pattern from the font's PostScript name in what `findFont` writes.
const name_sep = " = ";

/// The font for `pattern` (see the file's header), written into `buf`: the pattern as it
/// will be made, ` = `, the PostScript name. `error.FontNotFound`: a character set that is
/// not a code point, or no font with that character.
pub fn findFont(pattern: [:0]const u8, buf: *[std.fs.max_path_bytes:0]u8) ![:0]const u8 {
    var p = parse(pattern) orelse return error.FontNotFound;
    var family_buf: [256]u8 = undefined;
    if (generic(p.family)) |kind| {
        p.family = if (kind == kCTFontUIFontLabel) "sans-serif" else "monospace";
    } else if (installedFamily(p.family, &family_buf)) |name| {
        p.family = name;
    } else {
        log.warn("font family '{s}' is not installed: the system font is used", .{p.family});
        p.family = "sans-serif";
    }
    const f = fontFor(p, 0) orelse return error.FontNotFound;
    defer release(f);
    var ps_buf: [256]u8 = undefined;
    const ps = psName(f, &ps_buf);
    return (if (p.cp) |cp|
        std.fmt.bufPrintSentinel(buf, "{s}:charset={x}" ++ name_sep ++ "{s}", .{ p.family, cp, ps }, 0)
    else
        std.fmt.bufPrintSentinel(buf, "{s}" ++ name_sep ++ "{s}", .{ p.family, ps }, 0)) catch error.FontNotFound;
}

// ---- Faces ----

/// Core Text needs nothing started.
pub const Library = struct {
    pub fn init() !Library {
        return .{};
    }

    pub fn deinit(self: Library) void {
        _ = self;
    }
};

/// The bitmap context glyphs are drawn into, reused (grown when a glyph does not fit).
/// Memory row 0 is the top of the context; its user space has y up from the bottom row.
const Raster = struct {
    pixels: []u8 = &.{},
    w: usize = 0,
    h: usize = 0,
    cg: ?*CGContext = null,

    fn ensure(self: *Raster, w: usize, h: usize) bool {
        if (self.cg != null and w <= self.w and h <= self.h) return true;
        const nw = @max(w, self.w, 64);
        const nh = @max(h, self.h, 64);
        const pixels = std.heap.c_allocator.alloc(u8, nw * nh) catch return false;
        const cg = own(CGBitmapContextCreate(pixels.ptr, nw, nh, 8, nw, null, kCGImageAlphaOnly)) orelse {
            std.heap.c_allocator.free(pixels);
            return false;
        };
        self.deinit();
        CGContextSetShouldAntialias(cg, true);
        CGContextSetAllowsAntialiasing(cg, true);
        CGContextSetAllowsFontSmoothing(cg, false);
        CGContextSetShouldSmoothFonts(cg, false);
        CGContextSetAllowsFontSubpixelPositioning(cg, false);
        CGContextSetShouldSubpixelPositionFonts(cg, false);
        CGContextSetAllowsFontSubpixelQuantization(cg, false);
        CGContextSetShouldSubpixelQuantizeFonts(cg, false);
        self.* = .{ .pixels = pixels, .w = nw, .h = nh, .cg = cg };
        return true;
    }

    fn deinit(self: *Raster) void {
        if (self.cg) |cg| {
            _ = live.fetchSub(1, .monotonic);
            CGContextRelease(cg);
        }
        if (self.pixels.len > 0) std.heap.c_allocator.free(self.pixels);
        self.* = .{};
    }
};

/// A face's own state, on the heap so that copies of a `Face` share it.
const State = struct {
    font: *const CTFont,
    /// The pattern it was made from (`Face.open`), to make it again at another size; empty
    /// for a font Core Text gave (a fallback).
    pattern_buf: [256]u8 = undefined,
    pattern_len: usize = 0,
    /// The font's PostScript name (`sameFont`).
    ps_buf: [128]u8 = undefined,
    ps_len: usize = 0,
    raster: Raster = .{},

    /// Takes `f` as the font (the one before is released by the caller).
    fn setFont(self: *State, f: *const CTFont) void {
        self.font = f;
        var buf: [128]u8 = undefined;
        const name = psName(f, &buf);
        @memcpy(self.ps_buf[0..name.len], name);
        self.ps_len = name.len;
    }
};

pub const Face = struct {
    s: *State,

    /// What `findFont` wrote (the part before ` = ` is read); `index` must be 0.
    /// `error.FontNotLoaded`: a pattern that cannot be read, a family that is not installed,
    /// no font with the character asked for.
    pub fn open(lib: Library, name: [:0]const u8, index: c_int) !Face {
        _ = lib;
        if (index != 0) return error.FontNotLoaded;
        const request = name[0 .. std.mem.indexOf(u8, name, name_sep) orelse name.len];
        const p = parse(request) orelse return error.FontNotLoaded;
        if (request.len > @as(State, undefined).pattern_buf.len) return error.FontNotLoaded;
        const f = fontFor(p, 0) orelse return error.FontNotLoaded;
        const face = ofFont(f) catch |e| {
            release(f);
            return e;
        };
        @memcpy(face.s.pattern_buf[0..request.len], request);
        face.s.pattern_len = request.len;
        return face;
    }

    /// A face for `f`, which it takes.
    fn ofFont(f: *const CTFont) !Face {
        const s = std.heap.c_allocator.create(State) catch return error.FontNotLoaded;
        s.* = .{ .font = f };
        s.setFont(f);
        return .{ .s = s };
    }

    pub fn deinit(self: Face) void {
        self.s.raster.deinit();
        release(self.s.font);
        std.heap.c_allocator.destroy(self.s);
    }

    /// An em of `px` pixels: the font made again at that size from its pattern (so the
    /// optical size follows), or a copy of a fallback at that size. `error.CoreText`.
    pub fn setPixelSize(self: Face, px: u32) !void {
        const size: f64 = @floatFromInt(px);
        const f = if (self.s.pattern_len > 0)
            fontFor(parse(self.s.pattern_buf[0..self.s.pattern_len]).?, size) orelse return error.CoreText
        else
            own(CTFontCreateCopyWithAttributes(self.s.font, size, null, null)) orelse return error.CoreText;
        release(self.s.font);
        self.s.setFont(f);
    }

    /// Rounded up, as FreeType rounds a scalable font's ascender.
    pub fn ascent(self: Face) f32 {
        return @floatCast(@ceil(CTFontGetAscent(self.s.font)));
    }

    /// Ascent, descent and leading, to the nearest pixel, as FreeType rounds a scalable
    /// font's height.
    pub fn lineHeight(self: Face) f32 {
        const f = self.s.font;
        return @floatCast(@round(CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f)));
    }

    pub fn glyphIndex(self: Face, cp: u32) u32 {
        return glyphOf(self.s.font, cp);
    }

    /// Coverage drawn by Core Text (see the file's header). Null: not a glyph of this face.
    pub fn render(self: Face, gid: u32) ?Coverage {
        const g: u16 = std.math.cast(u16, gid) orelse return null;
        const f = self.s.font;
        var adv: CGSize = undefined;
        _ = CTFontGetAdvancesForGlyphs(f, kCTFontOrientationHorizontal, @ptrCast(&g), @ptrCast(&adv), 1);
        var empty: Coverage = .{ .width = 0, .rows = 0, .pitch = 0, .pixels = null, .left = 0, .top = 0, .advance = @floatCast(adv.width), .gray = true };
        var box: CGRect = undefined;
        _ = CTFontGetBoundingRectsForGlyphs(f, kCTFontOrientationHorizontal, @ptrCast(&g), @ptrCast(&box), 1);
        if (!(box.size.width > 0 and box.size.height > 0)) return empty;
        // The box in whole pixels, a pixel wider each side than the outline's.
        const x0: i32 = @as(i32, @intFromFloat(@floor(box.origin.x))) - 1;
        const x1: i32 = @as(i32, @intFromFloat(@ceil(box.origin.x + box.size.width))) + 1;
        const y0: i32 = @as(i32, @intFromFloat(@floor(box.origin.y))) - 1;
        const y1: i32 = @as(i32, @intFromFloat(@ceil(box.origin.y + box.size.height))) + 1;
        const w: usize = @intCast(x1 - x0);
        const h: usize = @intCast(y1 - y0);
        const r = &self.s.raster;
        if (w > 4096 or h > 4096 or !r.ensure(w, h)) return null;
        // The glyph's box at the bottom-left of the context: memory rows r.h - h .. r.h.
        const first = r.h - h;
        for (first..r.h) |row| @memset(r.pixels[row * r.w ..][0..w], 0);
        const pen: CGPoint = .{ .x = @floatFromInt(-x0), .y = @floatFromInt(-y0) };
        CTFontDrawGlyphs(f, @ptrCast(&g), @ptrCast(&pen), 1, r.cg.?);
        // Trimmed to the ink.
        var top: usize = first;
        var bottom: usize = r.h;
        var left: usize = w;
        var right: usize = 0;
        for (first..r.h) |row| {
            const line = r.pixels[row * r.w ..][0..w];
            for (line, 0..) |px, x| if (px != 0) {
                left = @min(left, x);
                right = @max(right, x + 1);
            };
        }
        if (right == 0) return empty;
        while (std.mem.allEqual(u8, r.pixels[top * r.w ..][left..right], 0)) top += 1;
        while (std.mem.allEqual(u8, r.pixels[(bottom - 1) * r.w ..][left..right], 0)) bottom -= 1;
        empty = .{
            .width = right - left,
            .rows = bottom - top,
            .pitch = @intCast(r.w),
            .pixels = r.pixels[top * r.w + left ..].ptr,
            .left = x0 + @as(i32, @intCast(left)),
            .top = y1 - @as(i32, @intCast(top - first)),
            .advance = @floatCast(adv.width),
            .gray = CTFontGetSymbolicTraits(f) & kCTFontTraitColorGlyphs == 0,
        };
        return empty;
    }

    /// The height of the face's capital H, or of its alef where it has no H, in pixels at
    /// its size (its bounding box); null if it has neither.
    fn capHeight(self: Face) ?f32 {
        for ([_]u32{ 'H', 0x0627 }) |cp| {
            const gid = self.glyphIndex(cp);
            if (gid == 0) continue;
            const g: u16 = @intCast(gid);
            var box: CGRect = undefined;
            _ = CTFontGetBoundingRectsForGlyphs(self.s.font, kCTFontOrientationHorizontal, @ptrCast(&g), @ptrCast(&box), 1);
            if (box.size.height > 0) return @floatCast(box.size.height);
        }
        return null;
    }
};

// ---- Shaping and bidi: always there ----

/// Nothing to load: Core Text shapes and lays out, ICU gives bidi classes.
pub const Shaping = struct { always: bool = true };
const shaping_value: Shaping = .{};

pub fn shaping() ?*const Shaping {
    return &shaping_value;
}

/// ICU's class of each code point, as the values of `text_backend.bidi`; a class the shared
/// code does not look at is given as FriBidi's ON (0x40).
pub fn bidiTypes(l: *const Shaping, cps: []const u32, types: []u32) void {
    _ = l;
    for (cps, types) |cp, *t| t.* = bidiType(u_charDirection(@intCast(@min(cp, 0x10ffff))));
}

/// ICU's UCharDirection to `text_backend.bidi`.
fn bidiType(dir: c_int) u32 {
    return switch (dir) {
        0 => bidi.L,
        1 => bidi.R,
        2 => bidi.EN,
        3 => bidi.ES,
        4 => bidi.ET,
        7 => bidi.BS,
        13 => bidi.AL,
        17 => bidi.NSM,
        9 => 0x800, // WS
        else => 0x40, // ON
    };
}

// ---- An engine's fonts, fallbacks and layout ----

/// Fonts one engine may hold: the primary and those Core Text used for other characters.
pub const max_faces = 16;
const no_face: u8 = 0xff;

/// Marks, joiners and controls: drawn with the font of the character before them (as
/// `text_freetype.zig` decides, for `mapSimple`).
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

/// The fonts of one engine: the primary (0), then every font Core Text drew a run with or
/// offered for a character, the same font once.
pub const Fonts = struct {
    gpa: std.mem.Allocator,
    faces: [max_faces]FontFace = undefined,
    nfaces: u8 = 0,
    /// The faces there were before any fallback: the primary alone (Core Text has no named
    /// fallbacks).
    named: u8 = 1,
    /// Faces it may hold (`max_faces`; lowered by a test).
    limit: u8 = max_faces,
    /// The primary's line height.
    line_height: f32,
    /// The height of the primary's capital H in pixels (`capPx(0)`), for the tests: the
    /// fallbacks' letters are not scaled to it, but stand within a pixel or two of it.
    cap_px: ?f32 = null,
    /// Characters the primary lacks: the face Core Text offered for each (`no_face`: none).
    best: std.AutoHashMapUnmanaged(u21, u8) = .empty,
    /// A font past `limit` was met (logged once).
    full: bool = false,
    // Scratch, reused from string to string.
    units: std.ArrayList(u16) = .empty,
    cp_of: std.ArrayList(u32) = .empty,
    glyphs: std.ArrayList(u16) = .empty,
    positions: std.ArrayList(CGPoint) = .empty,
    advances: std.ArrayList(CGSize) = .empty,
    indices: std.ArrayList(CFIndex) = .empty,

    pub const FontFace = struct {
        face: Face,
        /// Pixels from the top of one line to the next (`Face.lineHeight`).
        line_height: f32,
    };

    /// Takes `primary`, set to `px` pixels with line height `line_height`.
    pub fn init(gpa: std.mem.Allocator, lib: Library, primary: Face, px: u32, line_height: f32) Fonts {
        _ = lib;
        _ = px;
        var self: Fonts = .{ .gpa = gpa, .line_height = line_height };
        self.faces[0] = .{ .face = primary, .line_height = line_height };
        self.nfaces = 1;
        self.cap_px = primary.capHeight();
        return self;
    }

    pub fn deinit(self: *Fonts) void {
        const gpa = self.gpa;
        for (self.faces[0..self.nfaces]) |face| face.face.deinit();
        self.best.deinit(gpa);
        inline for (.{ "units", "cp_of", "glyphs", "positions", "advances", "indices" }) |name| {
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

    /// The height of face `k`'s capital H (or alef) in pixels at its size; null if it has
    /// none (for tests).
    pub fn capPx(self: *const Fonts, k: u8) ?f32 {
        return self.faces[k].face.capHeight();
    }

    /// The face of `font` (not taken: retained if it is new); null if it is new and there is
    /// no room.
    fn faceOf(self: *Fonts, font: *const CTFont) ?u8 {
        // The object itself first (a line's run in the primary font is often the primary).
        for (self.faces[0..self.nfaces], 0..) |face, k| {
            if (face.face.s.font == font) return @intCast(k);
        }
        var buf: [128]u8 = undefined;
        const ps = psName(font, &buf);
        for (self.faces[0..self.nfaces], 0..) |face, k| {
            if (sameFont(face.face.s, font, ps)) return @intCast(k);
        }
        if (self.nfaces >= self.limit) {
            if (!self.full) log.warn("{d} fonts in use: text in another ({s}) draws as the missing glyph", .{ self.limit, ps });
            self.full = true;
            return null;
        }
        const retained: *const CTFont = @ptrCast(own(@as(?*const CFType, CFRetain(font))).?);
        const face = Face.ofFont(retained) catch {
            release(retained);
            return null;
        };
        const at = self.nfaces;
        self.faces[at] = .{ .face = face, .line_height = face.lineHeight() };
        self.nfaces += 1;
        log.info("face {d}: {s} at {d:.1} px line height", .{ at, ps, self.faces[at].line_height });
        return at;
    }

    /// Which face draws `cp`, after a character drawn with `current`.
    fn faceFor(self: *Fonts, cp: u32, current: ?u8) u8 {
        if (current) |f| {
            if (isMark(cp)) return f;
            if (isNeutral(cp) and self.covers(f, cp)) return f;
        }
        if (self.covers(0, cp)) return 0;
        const cp21: u21 = std.math.cast(u21, cp) orelse return 0;
        const found = self.best.get(cp21) orelse blk: {
            const f: u8 = if (fallbackFor(self.faces[0].face.s.font, cp)) |font| inner: {
                defer release(font);
                break :inner self.faceOf(font) orelse no_face;
            } else no_face;
            self.best.put(self.gpa, cp21, f) catch {};
            break :blk f;
        };
        return if (found == no_face) 0 else found;
    }

    /// One glyph per code point, from the face Core Text offers for it, in logical order.
    pub fn mapSimple(self: *Fonts, cps: []const u32, out: *std.ArrayList(text_backend.FaceGlyph)) !void {
        var current: ?u8 = null;
        for (cps) |cp| {
            const f = self.faceFor(cp, current);
            current = f;
            try out.append(self.gpa, .{ .face = f, .gid = self.glyphIndex(f, cp) });
        }
    }

    /// A `CTTypesetter` line of `text` in the primary font with base direction `base`; its
    /// runs' glyphs (visual order, left to right) with their positions as offsets from the
    /// pen and advances. The isolate marks' glyphs are left out.
    pub fn layout(self: *Fonts, l: *const Shaping, text: []const u32, marks: []const bool, base: u32, out: *std.ArrayList(RunGlyph)) !void {
        _ = l;
        const gpa = self.gpa;
        self.units.clearRetainingCapacity();
        self.cp_of.clearRetainingCapacity();
        for (text, 0..) |cp, k| {
            var buf: [2]u16 = undefined;
            for (utf16(cp, &buf)) |u| {
                try self.units.append(gpa, u);
                try self.cp_of.append(gpa, @intCast(k));
            }
        }
        if (self.units.items.len == 0) return;
        const str = own(CFStringCreateWithCharacters(null, self.units.items.ptr, @intCast(self.units.items.len))) orelse return error.CoreText;
        defer release(str);
        const dir: i8 = if (base == bidi.par_rtl) kCTWritingDirectionRightToLeft else if (base == bidi.par_ltr) kCTWritingDirectionLeftToRight else kCTWritingDirectionNatural;
        const setting = [_]ParagraphStyleSetting{.{ .spec = kCTParagraphStyleSpecifierBaseWritingDirection, .size = @sizeOf(i8), .value = &dir }};
        const style = own(CTParagraphStyleCreate(&setting, setting.len)) orelse return error.CoreText;
        defer release(style);
        const keys = [_]*const CFType{ kCTFontAttributeName, kCTParagraphStyleAttributeName };
        const values = [_]*const CFType{ self.faces[0].face.s.font, style };
        const attrs = own(CFDictionaryCreate(null, &keys, &values, keys.len, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)) orelse return error.CoreText;
        defer release(attrs);
        const astr = own(CFAttributedStringCreate(null, str, attrs)) orelse return error.CoreText;
        defer release(astr);
        const ts = own(CTTypesetterCreateWithAttributedString(astr)) orelse return error.CoreText;
        defer release(ts);
        const line = own(CTTypesetterCreateLine(ts, .{ .location = 0, .length = 0 })) orelse return error.CoreText;
        defer release(line);

        const runs = CTLineGetGlyphRuns(line);
        var pen: f64 = 0;
        for (0..@intCast(CFArrayGetCount(runs))) |r| {
            const run: *const CTRun = @ptrCast(CFArrayGetValueAtIndex(runs, @intCast(r)) orelse continue);
            const n: usize = @intCast(@max(CTRunGetGlyphCount(run), 0));
            if (n == 0) continue;
            try self.glyphs.resize(gpa, n);
            try self.positions.resize(gpa, n);
            try self.advances.resize(gpa, n);
            try self.indices.resize(gpa, n);
            const all: CFRange = .{ .location = 0, .length = 0 };
            CTRunGetGlyphs(run, all, self.glyphs.items.ptr);
            CTRunGetPositions(run, all, self.positions.items.ptr);
            CTRunGetAdvances(run, all, self.advances.items.ptr);
            CTRunGetStringIndices(run, all, self.indices.items.ptr);
            // The run's font as a face; one past the limit draws as the missing glyph.
            const font: ?*const CTFont = @ptrCast(CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName));
            const face: ?u8 = if (font) |f| self.faceOf(f) else 0;
            for (self.glyphs.items, self.positions.items, self.advances.items, self.indices.items) |g, pos, adv, unit| {
                if (g == deleted_glyph) continue;
                if (unit >= 0 and unit < self.cp_of.items.len and marks[self.cp_of.items[@intCast(unit)]]) continue;
                try out.append(gpa, .{
                    .face = face orelse 0,
                    .gid = if (face != null) g else 0,
                    .x_offset = @floatCast(pos.x - pen),
                    .y_offset = @floatCast(pos.y),
                    .x_advance = @floatCast(adv.width),
                });
                pen += adv.width;
            }
        }
    }
};

// ---- Tests ----

const testing = std.testing;

/// `findFont`'s answer for `pattern`, opened at `px`.
fn openAt(pattern: [:0]const u8, px: u32, buf: *[std.fs.max_path_bytes:0]u8) !Face {
    const name = try findFont(pattern, buf);
    const face = try Face.open(.{}, name, 0);
    errdefer face.deinit();
    try face.setPixelSize(px);
    return face;
}

fn familyOf(face: Face, buf: []u8) []const u8 {
    const name = own(CTFontCopyFamilyName(face.s.font)) orelse return "?";
    defer release(name);
    return utf8(name, buf) orelse "?";
}

test "the font for each pattern: the interface fonts, an installed family, a character's fallback" {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var b2: [256]u8 = undefined;
    const Case = struct { pattern: [:0]const u8, name: []const u8, ps: []const u8 };
    for ([_]Case{
        .{ .pattern = "sans-serif", .name = "sans-serif = ", .ps = ".SFNS" },
        .{ .pattern = "Sans", .name = "sans-serif = ", .ps = ".SFNS" },
        .{ .pattern = "monospace", .name = "monospace = ", .ps = "Menlo" },
        .{ .pattern = "helvetica neue", .name = "Helvetica Neue = ", .ps = "HelveticaNeue" },
        // The note the display marks a channel with: not in SF; Helvetica Neue has it.
        .{ .pattern = "sans-serif:charset=266a", .name = "sans-serif:charset=266a = ", .ps = "HelveticaNeue" },
        // One SF has: SF itself.
        .{ .pattern = "sans-serif:charset=3c3", .name = "sans-serif:charset=3c3 = ", .ps = ".SFNS" },
    }) |case| {
        const name = try findFont(case.pattern, &buf);
        testing.expect(std.mem.startsWith(u8, name, case.name) and std.mem.indexOf(u8, name, case.ps) != null) catch |e| {
            std.debug.print("{s}: {s}\n", .{ case.pattern, name });
            return e;
        };
        const face = try openAt(case.pattern, 14, &buf);
        defer face.deinit();
        try testing.expect(std.mem.startsWith(u8, psName(face.s.font, &b2), case.ps));
        try testing.expectEqual(14, CTFontGetSize(face.s.font));
        try testing.expect(face.glyphIndex('A') != 0);
    }
    // The character asked for is in the face made.
    const note = try openAt("sans-serif:charset=266a", 20, &buf);
    defer note.deinit();
    try testing.expect(note.glyphIndex(0x266a) != 0);
    // The fixed-pitch face is fixed-pitch.
    const mono = try openAt("monospace", 14, &buf);
    defer mono.deinit();
    const wi = mono.render(mono.glyphIndex('i')).?.advance;
    try testing.expectEqual(wi, mono.render(mono.glyphIndex('W')).?.advance);
    // A character no font has, and a character set that is not a code point.
    try testing.expectError(error.FontNotFound, findFont("sans-serif:charset=10fffd", &buf));
    try testing.expectError(error.FontNotFound, findFont("sans-serif:charset=xyz", &buf));
    try testing.expectEqual(kCTFontUIFontLabel, generic("Sans-Serif").?);
    try testing.expectEqual(null, generic("Menlo"));
}

test "a family that is not installed: the system font, never asked for by name" {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var fam: [256]u8 = undefined;
    // Gibberish, so in no catalogue of fonts to download; and checked absent first.
    const bogus = "Zqxj Nonexistent Dimna Family 7731";
    try testing.expectEqual(null, installedFamily(bogus, &fam));
    const name = try findFont(bogus, &buf);
    try testing.expect(std.mem.startsWith(u8, name, "sans-serif = .SFNS"));
    // Face.open of the name itself is refused (nothing made of it).
    try testing.expectError(error.FontNotLoaded, Face.open(.{}, bogus, 0));
    try testing.expectError(error.FontNotLoaded, Face.open(.{}, "sans-serif", 1));
    // Lato, which the tests ask for, is in Apple's catalogue of fonts to download: when it is
    // not installed it is not asked for either.
    if (installedFamily("Lato", &fam) == null) {
        try testing.expect(std.mem.startsWith(u8, try findFont("Lato", &buf), "sans-serif = "));
        try testing.expectError(error.FontNotLoaded, Face.open(.{}, "Lato", 0));
    }
}

test "the system font's metrics, rounded as FreeType rounds them" {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    // SF at 14, 20, 24 px: Core Text's ascent 13.535, 19.336, 23.203 and line (ascent,
    // descent, leading) 16.488, 23.555, 28.266 (tools/coretext-probe/results/metrics.txt);
    // FreeType's hinted metrics of SFNS.ttf are 14/16, 20/24, 24/28.
    for ([_][3]u32{ .{ 14, 14, 16 }, .{ 20, 20, 24 }, .{ 24, 24, 28 } }) |want| {
        const face = try openAt("sans-serif", want[0], &buf);
        defer face.deinit();
        std.debug.print("sans-serif at {d} px: ascent {d:.3} -> {d}, line {d:.3} -> {d}\n", .{
            want[0],
            CTFontGetAscent(face.s.font),
            face.ascent(),
            CTFontGetAscent(face.s.font) + CTFontGetDescent(face.s.font) + CTFontGetLeading(face.s.font),
            face.lineHeight(),
        });
        try testing.expectEqual(@as(f32, @floatFromInt(want[1])), face.ascent());
        try testing.expectEqual(@as(f32, @floatFromInt(want[2])), face.lineHeight());
    }
}

/// Draws glyph `g` of `face` into a context of its own with a wide margin, and checks that
/// every pixel of ink there is in `cov` at the same place, and the rest of `cov` is the same.
fn expectCoverageMatches(face: Face, g: u16, cov: Coverage) !void {
    const size = 160;
    const margin = 48;
    var pixels: [size * size]u8 = @splat(0);
    const cg = CGBitmapContextCreate(&pixels, size, size, 8, size, null, kCGImageAlphaOnly).?;
    defer CGContextRelease(cg);
    CGContextSetAllowsFontSmoothing(cg, false);
    CGContextSetShouldSmoothFonts(cg, false);
    CGContextSetAllowsFontSubpixelPositioning(cg, false);
    CGContextSetShouldSubpixelPositionFonts(cg, false);
    CGContextSetAllowsFontSubpixelQuantization(cg, false);
    CGContextSetShouldSubpixelQuantizeFonts(cg, false);
    const pen: CGPoint = .{ .x = margin, .y = margin };
    CTFontDrawGlyphs(face.s.font, @ptrCast(&g), @ptrCast(&pen), 1, cg);
    // The baseline is memory row size - margin - 1's bottom edge: row `size - margin - top`
    // is the bitmap's top row.
    var ink: usize = 0;
    for (0..size) |row| for (0..size) |x| {
        const v = pixels[row * size + x];
        const bx: i64 = @as(i64, @intCast(x)) - margin - cov.left;
        const by: i64 = @as(i64, @intCast(row)) - (size - margin - cov.top);
        const inside = bx >= 0 and by >= 0 and bx < cov.width and by < cov.rows;
        if (!inside) {
            if (v != 0) {
                std.debug.print("glyph {d}: ink {d} at ({d}, {d}) outside its box\n", .{ g, v, bx, by });
                return error.InkOutsideTheBox;
            }
            continue;
        }
        ink += v;
        const got = cov.pixels.?[@as(usize, @intCast(by)) * @as(usize, @intCast(cov.pitch)) + @as(usize, @intCast(bx))];
        if (got != v) {
            std.debug.print("glyph {d}: coverage {d} at ({d}, {d}), drawn alone {d}\n", .{ g, got, bx, by, v });
            return error.CoverageDiffers;
        }
    };
    try testing.expect(ink > 0);
}

test "coverage: every glyph's ink is inside its box, at its bearings, as Core Text draws it" {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    for ([_]u32{ 14, 24 }) |px| {
        const face = try openAt("sans-serif", px, &buf);
        defer face.deinit();
        // Round letters, descenders, a tall one, thin strokes.
        for ("AgjpQy|/W@1\u{c5}") |ch| {
            const gid = face.glyphIndex(ch);
            const cov = face.render(gid).?;
            try testing.expect(cov.gray);
            try testing.expect(cov.width > 0 and cov.rows > 0);
            try testing.expect(cov.advance > 0);
            // Trimmed to its ink: the outer rows and columns each have some.
            const p = cov.pixels.?;
            const pitch: usize = @intCast(cov.pitch);
            try testing.expect(!std.mem.allEqual(u8, p[0..cov.width], 0));
            try testing.expect(!std.mem.allEqual(u8, p[(cov.rows - 1) * pitch ..][0..cov.width], 0));
            try expectCoverageMatches(face, @intCast(gid), cov);
        }
        // A space: nothing to draw, an advance.
        const space = face.render(face.glyphIndex(' ')).?;
        try testing.expectEqual(0, space.width * space.rows);
        try testing.expect(space.advance > 0);
        // 'g' goes below the baseline, 'A' sits on it.
        try testing.expect(face.render(face.glyphIndex('g')).?.top < face.render(face.glyphIndex('g')).?.rows);
        const a = face.render(face.glyphIndex('A')).?;
        try testing.expect(@abs(@as(i64, a.top) - @as(i64, @intCast(a.rows))) <= 1);
    }
    // A colour glyph is not coverage.
    var b2: [64]u8 = undefined;
    if (installedFamily("Apple Color Emoji", &b2) != null) {
        const emoji = try openAt("Apple Color Emoji", 20, &buf);
        defer emoji.deinit();
        const gid = emoji.glyphIndex(0x1F600);
        if (gid != 0) try testing.expect(!emoji.render(gid).?.gray);
    }
}

/// An engine's fonts with the system font as the primary, at `px`.
fn testFonts(px: u32) !Fonts {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const face = try openAt("sans-serif", px, &buf);
    return .init(testing.allocator, .{}, face, px, face.lineHeight());
}

fn codepoints(comptime s: []const u8) []const u32 {
    comptime {
        var out: []const u32 = &.{};
        var it = std.unicode.Utf8View.initComptime(s).iterator();
        while (it.nextCodepoint()) |cp| out = out ++ [_]u32{cp};
        const final = out[0..out.len].*;
        return &final;
    }
}

test "the faces: each font Core Text draws with once, the same for a line and for a character" {
    var fonts = try testFonts(14);
    defer fonts.deinit();
    var out: std.ArrayList(RunGlyph) = .empty;
    defer out.deinit(testing.allocator);
    const text = comptime codepoints("A \u{641}\u{6cc}\u{644}\u{62a}\u{631} \u{9608}\u{503c} \u{266a}");
    const marks: [text.len]bool = @splat(false);
    try fonts.layout(shaping().?, text, &marks, bidi.par_ltr, &out);
    // SF, then Core Text's Persian, Chinese and the note's fonts.
    try testing.expectEqual(4, fonts.nfaces);
    var seen: [max_faces]bool = @splat(false);
    for (out.items) |g| {
        seen[g.face] = true;
        try testing.expect(g.gid != 0);
    }
    for (seen[0..4]) |s| try testing.expect(s);
    var b: [128]u8 = undefined;
    for (fonts.faces[1..4]) |f| std.debug.print("fallback face: {s}\n", .{psName(f.face.s.font, &b)});
    // Laid out again, and its characters one by one: no new face, the same ones.
    const n = out.items.len;
    try fonts.layout(shaping().?, text, &marks, bidi.par_ltr, &out);
    try testing.expectEqual(4, fonts.nfaces);
    try testing.expectEqualSlices(RunGlyph, out.items[0..n], out.items[n..]);
    var simple: std.ArrayList(text_backend.FaceGlyph) = .empty;
    defer simple.deinit(testing.allocator);
    try fonts.mapSimple(comptime codepoints("\u{644}\u{9608}\u{266a}A"), &simple);
    try testing.expectEqual(4, fonts.nfaces);
    for (simple.items, [_]u32{ 0x644, 0x9608, 0x266a, 'A' }) |g, cp| {
        try testing.expect(g.gid != 0);
        try testing.expectEqual(fonts.glyphIndex(g.face, cp), g.gid);
    }
    try testing.expect(simple.items[0].face != 0 and simple.items[1].face != 0 and simple.items[2].face != 0);
    try testing.expectEqual(0, simple.items[3].face);
    // Each line height and cap height is the face's own (not scaled to the primary's).
    for (fonts.faces[0..4], 0..) |f, k| {
        try testing.expectEqual(f.face.lineHeight(), f.line_height);
        std.debug.print("face {d}: line {d}, capitals {?d:.2} px\n", .{ k, f.line_height, fonts.capPx(@intCast(k)) });
    }
}

test "the faces: past the limit, a font's glyphs are the missing glyph" {
    var fonts = try testFonts(14);
    defer fonts.deinit();
    fonts.limit = 2;
    var out: std.ArrayList(RunGlyph) = .empty;
    defer out.deinit(testing.allocator);
    const text = comptime codepoints("\u{9608}A\u{644}");
    const marks: [text.len]bool = @splat(false);
    try fonts.layout(shaping().?, text, &marks, bidi.par_ltr, &out);
    try testing.expectEqual(2, fonts.nfaces);
    try testing.expect(fonts.full);
    var missing: usize = 0;
    for (out.items) |g| {
        if (g.gid == 0) {
            try testing.expectEqual(0, g.face);
            try testing.expect(g.x_advance > 0);
            missing += 1;
        }
    }
    try testing.expect(missing >= 1);
    var simple: std.ArrayList(text_backend.FaceGlyph) = .empty;
    defer simple.deinit(testing.allocator);
    try fonts.mapSimple(comptime codepoints("\u{266a}"), &simple);
    try testing.expectEqual(text_backend.FaceGlyph{ .face = 0, .gid = 0 }, simple.items[0]);
}

test "layout: the base direction is the one given; the isolate marks draw nothing" {
    var fonts = try testFonts(14);
    defer fonts.deinit();
    var out: std.ArrayList(RunGlyph) = .empty;
    defer out.deinit(testing.allocator);
    // "Ab <LRI>12<PDI> فی": with left-to-right the Latin is on the left, with right-to-left
    // on the right; natural takes the first strong letter's (Latin: left to right).
    const text = comptime codepoints("Ab \u{2066}12\u{2069} \u{641}\u{6cc}");
    const marks = [_]bool{ false, false, false, true, false, false, true, false, false, false };
    var first_face: [3]u8 = undefined;
    for ([_]u32{ bidi.par_ltr, bidi.par_rtl, bidi.par_on }, 0..) |base, k| {
        out.clearRetainingCapacity();
        try fonts.layout(shaping().?, text, &marks, base, &out);
        // A, b, space, 1, 2, space, and the Persian (two glyphs or more): no isolates.
        try testing.expect(out.items.len >= 8 and out.items.len <= 9);
        first_face[k] = out.items[0].face;
        // The digits in order, left to right, whatever the direction.
        var one: ?usize = null;
        for (out.items, 0..) |g, j| if (g.face == 0 and g.gid == fonts.glyphIndex(0, '1')) {
            one = j;
        };
        try testing.expectEqual(fonts.glyphIndex(0, '2'), out.items[one.? + 1].gid);
    }
    try testing.expectEqual(0, first_face[0]);
    try testing.expect(first_face[1] != 0);
    try testing.expectEqual(0, first_face[2]);
}

test "bidi types: ICU's classes as the values the shared code looks at" {
    const cps = [_]u32{ 'a', 0x5d0, 0x641, '3', '-', '%', 0x64b, '\n', ' ', 0x6f3, 0x2066 };
    const want = [_]u32{ bidi.L, bidi.R, bidi.AL, bidi.EN, bidi.ES, bidi.ET, bidi.NSM, bidi.BS };
    var got: [cps.len]u32 = undefined;
    bidiTypes(shaping().?, &cps, &got);
    try testing.expectEqualSlices(u32, &want, got[0..want.len]);
    // The others: none of those values (Persian digits are EN in Unicode, as FriBidi has).
    for (got[want.len..], cps[want.len..]) |t, cp| {
        if (cp == 0x6f3) {
            try testing.expectEqual(bidi.EN, t);
            continue;
        }
        for (want) |w| try testing.expect(t != w);
    }
}

test "everything made is released: a font's faces, lines and contexts" {
    const before = live.load(.monotonic);
    {
        var fonts = try testFonts(20);
        defer fonts.deinit();
        var out: std.ArrayList(RunGlyph) = .empty;
        defer out.deinit(testing.allocator);
        const text = comptime codepoints("Port A \u{641}\u{6cc}\u{644}\u{62a}\u{631} \u{2066}300-6000 Hz\u{2069} \u{9608}\u{503c} \u{266a}");
        var marks: [text.len]bool = @splat(false);
        for (text, &marks) |cp, *m| m.* = cp == 0x2066 or cp == 0x2069;
        for (0..3) |_| try fonts.layout(shaping().?, text, &marks, bidi.par_rtl, &out);
        for (out.items) |g| _ = fonts.render(g.face, g.gid);
        var simple: std.ArrayList(text_backend.FaceGlyph) = .empty;
        defer simple.deinit(testing.allocator);
        try fonts.mapSimple(comptime codepoints("\u{142}\u{4e00}\u{25b8}"), &simple);
        try testing.expect(live.load(.monotonic) > before);
        var buf: [std.fs.max_path_bytes:0]u8 = undefined;
        _ = try findFont("Zqxj Nonexistent Dimna Family 7731", &buf);
        _ = try findFont("sans-serif:charset=266a", &buf);
    }
    try testing.expectEqual(before, live.load(.monotonic));
}
