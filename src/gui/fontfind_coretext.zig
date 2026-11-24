//! Finding font files with Core Text: the macOS backend of `fontfind.zig`, which says what
//! the callers rely on. Core Text's C interface is declared here (its header translates to
//! some 17,000 declarations); FreeType, which opens what is found, is the GUI's own.
//!
//! How each pattern is answered:
//!
//! - `sans-serif` (also `sans` and the empty name): the system's interface font (SF, from
//!   `CTFontCreateUIFontForLanguage`); `monospace` (also `mono`): the user's fixed-pitch
//!   font (Menlo unless changed). Another name is a family: the font Core Text makes of it,
//!   if a family of that name (ignoring ASCII case) is installed; else, as with fontconfig,
//!   the sans-serif font stands in. Anything after a `:` but the character set is ignored.
//! - `...:charset=<hex>`: the font for the name, if FreeType finds the code point in it;
//!   else the font Core Text falls back to for that character (`CTFontCreateForString`);
//!   else the first installed font whose character set has it, regular faces first.
//! - `anyFontHas`: whether an installed font's character set has all the code points (and
//!   FreeType finds them in it).
//!
//! What is never done: asking Core Text to match a family that is not installed. Core Text
//! then offers to download it (Lato and many others are in Apple's catalogue of fonts to
//! download): the lookup blocks on a font agent with a user interface. So a family is first
//! looked for among the installed families, and then made with downloading and activation
//! turned off (`kCTFontDownloadableAttribute`, `kCTFontOptionsPreventAutoDownload`).
//!
//! What is passed over, as if it were not installed: a font that names no file, a file that
//! FreeType cannot open (on macOS 27, the interface's Chinese font, `.PingFang UI SC`, the
//! one Core Text falls back to for Chinese: its PingFangUI.ttc has only Apple's `hvgl`
//! outlines, which FreeType 2.14 cannot read; the downloaded PingFang SC asset it can), a
//! collection in which no face has the name Core Text gave, and LastResort (the font of
//! boxes drawn for characters no font has).
//!
//! The face's index in a collection (`.ttc`): Core Text gives a file and a PostScript name,
//! not an index, so the index is that of the face whose PostScript name FreeType reads as
//! the same (a file of one face: that face).

const std = @import("std");
const c = @import("gui_c");

// ---- CoreFoundation and Core Text (CoreFoundation.h, CoreText.h) ----

const CFIndex = isize;
const Boolean = u8;
const CFType = anyopaque;
const CFString = opaque {};
const CFArray = opaque {};
const CFDictionary = opaque {};
const CFURL = opaque {};
const CFCharacterSet = opaque {};
const CFNumber = opaque {};
const CTFont = opaque {};
const CTFontDescriptor = opaque {};
const CTFontCollection = opaque {};
const CFRange = extern struct { location: CFIndex, length: CFIndex };
/// CFDictionaryKeyCallBacks and CFDictionaryValueCallBacks: only their addresses are used.
const DictionaryCallBacks = extern struct { fields: [6]usize };

const kCFStringEncodingUTF8: u32 = 0x08000100;
const kCFStringEncodingUTF32LE: u32 = 0x1c000100;
const kCFNumberSInt32Type: CFIndex = 3;
/// CTFontUIFontType.
const kCTFontUIFontUserFixedPitch: u32 = 1;
const kCTFontUIFontSystem: u32 = 2;
/// CTFontOptions.
const kCTFontOptionsPreventAutoActivation: usize = 1 << 0;
const kCTFontOptionsPreventAutoDownload: usize = 1 << 1;
/// CTFontSymbolicTraits.
const kCTFontTraitItalic: u32 = 1 << 0;
const kCTFontTraitBold: u32 = 1 << 1;

extern "c" fn CFRelease(cf: *const CFType) void;
extern "c" fn CFStringCreateWithBytes(alloc: ?*const anyopaque, bytes: [*]const u8, len: CFIndex, encoding: u32, external: Boolean) ?*const CFString;
extern "c" fn CFStringGetCString(s: *const CFString, buf: [*]u8, size: CFIndex, encoding: u32) Boolean;
extern "c" fn CFStringGetLength(s: *const CFString) CFIndex;
extern "c" fn CFArrayGetCount(a: *const CFArray) CFIndex;
extern "c" fn CFArrayGetValueAtIndex(a: *const CFArray, i: CFIndex) ?*const CFType;
extern "c" fn CFDictionaryCreate(alloc: ?*const anyopaque, keys: [*]const *const CFType, values: [*]const *const CFType, n: CFIndex, key_callbacks: *const DictionaryCallBacks, value_callbacks: *const DictionaryCallBacks) ?*const CFDictionary;
extern "c" fn CFDictionaryGetValue(d: *const CFDictionary, key: *const CFType) ?*const CFType;
extern "c" fn CFNumberGetValue(n: *const CFNumber, number_type: CFIndex, out: *anyopaque) Boolean;
extern "c" fn CFURLGetFileSystemRepresentation(url: *const CFURL, resolve: Boolean, buf: [*]u8, len: CFIndex) Boolean;
extern "c" fn CFCharacterSetIsLongCharacterMember(set: *const CFCharacterSet, ch: u32) Boolean;
extern "c" const kCFTypeDictionaryKeyCallBacks: DictionaryCallBacks;
extern "c" const kCFTypeDictionaryValueCallBacks: DictionaryCallBacks;
extern "c" const kCFBooleanFalse: *const CFType;

extern "c" fn CTFontCreateUIFontForLanguage(ui_type: u32, size: f64, language: ?*const CFString) ?*const CTFont;
extern "c" fn CTFontCreateForString(current: *const CTFont, string: *const CFString, range: CFRange) ?*const CTFont;
extern "c" fn CTFontCreateWithFontDescriptorAndOptions(d: *const CTFontDescriptor, size: f64, matrix: ?*const anyopaque, options: usize) ?*const CTFont;
extern "c" fn CTFontCopyPostScriptName(f: *const CTFont) ?*const CFString;
extern "c" fn CTFontCopyFamilyName(f: *const CTFont) ?*const CFString;
extern "c" fn CTFontCopyAttribute(f: *const CTFont, attribute: *const CFString) ?*const CFType;
extern "c" fn CTFontDescriptorCreateWithAttributes(attributes: *const CFDictionary) ?*const CTFontDescriptor;
extern "c" fn CTFontDescriptorCopyAttribute(d: *const CTFontDescriptor, attribute: *const CFString) ?*const CFType;
extern "c" fn CTFontManagerCopyAvailableFontFamilyNames() ?*const CFArray;
extern "c" fn CTFontCollectionCreateFromAvailableFonts(options: ?*const CFDictionary) ?*const CTFontCollection;
extern "c" fn CTFontCollectionCreateMatchingFontDescriptors(collection: *const CTFontCollection) ?*const CFArray;
extern "c" const kCTFontURLAttribute: *const CFString;
extern "c" const kCTFontNameAttribute: *const CFString;
extern "c" const kCTFontFamilyNameAttribute: *const CFString;
extern "c" const kCTFontCharacterSetAttribute: *const CFString;
extern "c" const kCTFontDownloadableAttribute: *const CFString;
extern "c" const kCTFontTraitsAttribute: *const CFString;
extern "c" const kCTFontSymbolicTrait: *const CFString;

fn release(cf: anytype) void {
    CFRelease(@ptrCast(cf));
}

fn cfString(text: []const u8) ?*const CFString {
    return CFStringCreateWithBytes(null, text.ptr, @intCast(text.len), kCFStringEncodingUTF8, 0);
}

/// `s` as zero-terminated UTF-8 in `buf`, or null if it does not fit.
fn utf8(s: *const CFString, buf: []u8) ?[:0]const u8 {
    if (CFStringGetCString(s, buf.ptr, @intCast(buf.len), kCFStringEncodingUTF8) == 0) return null;
    const n = std.mem.indexOfScalar(u8, buf, 0) orelse return null;
    return buf[0..n :0];
}

// ---- What a pattern asks for ----

/// A family (or a generic name), and a code point the font must have.
const Pattern = struct {
    family: []const u8,
    cp: ?u21 = null,
};

/// The patterns of `fontfind.zig`: a name, then `:`-separated properties, of which only
/// `charset=<hex>` is read. Null if the character set is not a code point.
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

/// The name Core Text uses for the generic families, or null for a family name.
fn generic(family: []const u8) ?u32 {
    for ([_][]const u8{ "", "sans-serif", "sans" }) |n| if (std.ascii.eqlIgnoreCase(family, n)) return kCTFontUIFontSystem;
    for ([_][]const u8{ "monospace", "mono" }) |n| if (std.ascii.eqlIgnoreCase(family, n)) return kCTFontUIFontUserFixedPitch;
    return null;
}

// ---- The lookup ----

/// A font found: its file (in the caller's buffer) and the face's index in it.
pub const Match = struct { path: [:0]const u8, index: c_int };

/// A font as Core Text describes it: its file, its PostScript name, its family. Each is
/// owned (released by `deinit`).
const Candidate = struct {
    url: ?*const CFType,
    name: ?*const CFType,
    family: ?*const CFType,

    fn ofFont(f: *const CTFont) Candidate {
        return .{ .url = CTFontCopyAttribute(f, kCTFontURLAttribute), .name = @ptrCast(CTFontCopyPostScriptName(f)), .family = @ptrCast(CTFontCopyFamilyName(f)) };
    }

    fn ofDescriptor(d: *const CTFontDescriptor) Candidate {
        return .{
            .url = CTFontDescriptorCopyAttribute(d, kCTFontURLAttribute),
            .name = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute),
            .family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute),
        };
    }

    fn deinit(self: Candidate) void {
        inline for (.{ self.url, self.name, self.family }) |v| if (v) |x| release(x);
    }
};

/// What lookups share: FreeType (to check what Core Text found) and, made the first time
/// they are needed, the installed families' names and the installed fonts.
const Lookup = struct {
    lib: c.FT_Library,
    families: ?*const CFArray = null,
    fonts: ?*const CFArray = null,

    fn init() ?Lookup {
        var lib: c.FT_Library = null;
        if (c.FT_Init_FreeType(&lib) != 0) return null;
        return .{ .lib = lib };
    }

    fn deinit(self: *Lookup) void {
        if (self.families) |a| release(a);
        if (self.fonts) |a| release(a);
        _ = c.FT_Done_FreeType(self.lib);
    }

    /// The installed family named `family` (ignoring ASCII case), as Core Text spells it;
    /// null if there is none. Owned by `self`.
    fn installedFamily(self: *Lookup, family: []const u8) ?*const CFString {
        if (self.families == null) self.families = CTFontManagerCopyAvailableFontFamilyNames();
        const names = self.families orelse return null;
        var buf: [256]u8 = undefined;
        for (0..@intCast(CFArrayGetCount(names))) |i| {
            const s: *const CFString = @ptrCast(CFArrayGetValueAtIndex(names, @intCast(i)) orelse continue);
            const name = utf8(s, &buf) orelse continue;
            if (std.ascii.eqlIgnoreCase(name, family)) return s;
        }
        return null;
    }

    /// The font for a family or generic name (see the file's header); null if Core Text
    /// gives none. Owned by the caller.
    fn fontFor(self: *Lookup, family: []const u8) ?*const CTFont {
        if (generic(family)) |ui| return CTFontCreateUIFontForLanguage(ui, 0, null);
        const name = self.installedFamily(family) orelse return CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 0, null);
        const keys = [_]*const CFType{ kCTFontFamilyNameAttribute, kCTFontDownloadableAttribute };
        const values = [_]*const CFType{ name, kCFBooleanFalse };
        const attrs = CFDictionaryCreate(null, &keys, &values, keys.len, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse return null;
        defer release(attrs);
        const desc = CTFontDescriptorCreateWithAttributes(attrs) orelse return null;
        defer release(desc);
        return CTFontCreateWithFontDescriptorAndOptions(desc, 0, null, kCTFontOptionsPreventAutoActivation | kCTFontOptionsPreventAutoDownload);
    }

    /// `cand` as a match, if it is a file FreeType opens and the face has every one of
    /// `cps`: its path in `buf` and the face's index. With `face0`, the face checked is the
    /// file's first, whichever Core Text named (`findFont`'s callers open that one).
    fn usable(self: *Lookup, cand: Candidate, cps: []const u32, face0: bool, buf: *[std.fs.max_path_bytes:0]u8) ?Match {
        const url: *const CFURL = @ptrCast(cand.url orelse return null);
        var name_buf: [256]u8 = undefined;
        const name = utf8(@ptrCast(cand.name orelse return null), &name_buf) orelse return null;
        if (std.mem.indexOf(u8, name, "LastResort") != null) return null;
        if (CFURLGetFileSystemRepresentation(url, 1, buf, buf.len) == 0) return null;
        const path = std.mem.sliceTo(buf, 0);
        const index: c_int = if (face0) 0 else faceIndex(self.lib, path, name) orelse return null;
        var face: c.FT_Face = null;
        if (c.FT_New_Face(self.lib, path.ptr, index, &face) != 0) return null;
        defer _ = c.FT_Done_Face(face);
        for (cps) |cp| if (c.FT_Get_Char_Index(face, cp) == 0) return null;
        return .{ .path = path, .index = index };
    }

    /// The font for `p`; see the file's header.
    fn find(self: *Lookup, p: Pattern, face0: bool, buf: *[std.fs.max_path_bytes:0]u8) ?Match {
        const base = self.fontFor(p.family) orelse return null;
        defer release(base);
        const base_cand: Candidate = .ofFont(base);
        defer base_cand.deinit();
        const cp: u32 = p.cp orelse return self.usable(base_cand, &.{}, face0, buf);
        if (self.usable(base_cand, &.{cp}, face0, buf)) |m| return m;
        // The font Core Text draws the character with when the base lacks it.
        const bytes = std.mem.toBytes(std.mem.nativeToLittle(u32, cp));
        if (CFStringCreateWithBytes(null, &bytes, bytes.len, kCFStringEncodingUTF32LE, 0)) |s| {
            defer release(s);
            if (CTFontCreateForString(base, s, .{ .location = 0, .length = CFStringGetLength(s) })) |f| {
                defer release(f);
                const cand: Candidate = .ofFont(f);
                defer cand.deinit();
                if (self.usable(cand, &.{cp}, face0, buf)) |m| return m;
            }
        }
        return self.scan(&.{cp}, face0, buf);
    }

    /// The first installed font whose character set has all of `cps` and that is usable
    /// (regular faces first: neither bold nor italic).
    fn scan(self: *Lookup, cps: []const u32, face0: bool, buf: *[std.fs.max_path_bytes:0]u8) ?Match {
        if (self.fonts == null) {
            const all = CTFontCollectionCreateFromAvailableFonts(null) orelse return null;
            defer release(all);
            self.fonts = CTFontCollectionCreateMatchingFontDescriptors(all);
        }
        const fonts = self.fonts orelse return null;
        const n: usize = @intCast(CFArrayGetCount(fonts));
        for ([_]bool{ true, false }) |regular_only| {
            for (0..n) |i| {
                const d: *const CTFontDescriptor = @ptrCast(CFArrayGetValueAtIndex(fonts, @intCast(i)) orelse continue);
                if (regular_only and !isRegular(d)) continue;
                const set: *const CFCharacterSet = @ptrCast(CTFontDescriptorCopyAttribute(d, kCTFontCharacterSetAttribute) orelse continue);
                defer release(set);
                const has_all = for (cps) |cp| {
                    if (CFCharacterSetIsLongCharacterMember(set, cp) == 0) break false;
                } else true;
                if (!has_all) continue;
                const cand: Candidate = .ofDescriptor(d);
                defer cand.deinit();
                if (self.usable(cand, cps, face0, buf)) |m| return m;
            }
        }
        return null;
    }
};

/// Neither bold nor italic, by the descriptor's symbolic traits (none given: regular).
fn isRegular(d: *const CTFontDescriptor) bool {
    const traits: *const CFDictionary = @ptrCast(CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) orelse return true);
    defer release(traits);
    const n: *const CFNumber = @ptrCast(CFDictionaryGetValue(traits, kCTFontSymbolicTrait) orelse return true);
    var t: u32 = 0;
    if (CFNumberGetValue(n, kCFNumberSInt32Type, &t) == 0) return true;
    return t & (kCTFontTraitBold | kCTFontTraitItalic) == 0;
}

/// The index of the face of `path` whose PostScript name is `name` (a file of one face:
/// 0), or null if FreeType cannot open the file or no face has that name.
fn faceIndex(lib: c.FT_Library, path: [:0]const u8, name: []const u8) ?c_int {
    var face: c.FT_Face = null;
    if (c.FT_New_Face(lib, path.ptr, -1, &face) != 0) return null;
    const count = face.*.num_faces;
    _ = c.FT_Done_Face(face);
    if (count == 1) return 0;
    var k: c_int = 0;
    while (k < count) : (k += 1) {
        if (c.FT_New_Face(lib, path.ptr, k, &face) != 0) continue;
        defer _ = c.FT_Done_Face(face);
        const ps = c.FT_Get_Postscript_Name(face) orelse continue;
        if (std.mem.eql(u8, std.mem.span(ps), name)) return k;
    }
    return null;
}

// ---- The three lookups of fontfind.zig ----

/// Whether some installed font has every one of `cps` (false also if the lookup fails).
pub fn anyFontHas(cps: []const u32) bool {
    var l = Lookup.init() orelse return false;
    defer l.deinit();
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    return l.scan(cps, false, &buf) != null;
}

/// The file of the font for `pattern`. `error.FontNotFound`: nothing usable (or a
/// character set that is not a code point); `error.FontLookup`: FreeType could not start.
pub fn findFont(pattern: [:0]const u8, buf: *[std.fs.max_path_bytes:0]u8) ![:0]const u8 {
    const p = parse(pattern) orelse return error.FontNotFound;
    var l = Lookup.init() orelse return error.FontLookup;
    defer l.deinit();
    const m = l.find(p, true, buf) orelse return error.FontNotFound;
    return m.path;
}

/// Lookups kept for a shaping engine's life (the installed families and fonts are listed
/// once). A `Matcher` whose FreeType could not start matches nothing.
pub const Matcher = struct {
    lookup: ?Lookup,

    pub fn init() Matcher {
        return .{ .lookup = Lookup.init() };
    }

    pub fn deinit(self: *Matcher) void {
        if (self.lookup) |*l| l.deinit();
    }

    /// The font for `pattern_text` and the face's index; with `family`, only if the font
    /// found is of that family (ignoring ASCII case).
    pub fn match(self: *Matcher, pattern_text: [:0]const u8, family: ?[]const u8, buf: *[std.fs.max_path_bytes:0]u8) ?Match {
        const l = if (self.lookup) |*x| x else return null;
        const p = parse(pattern_text) orelse return null;
        if (family) |want| {
            // Only an installed family can be that family (and nothing is then made of a
            // name that is not installed).
            if (l.installedFamily(want) == null) return null;
            const f = l.fontFor(p.family) orelse return null;
            defer release(f);
            const name = CTFontCopyFamilyName(f) orelse return null;
            defer release(name);
            var name_buf: [256]u8 = undefined;
            if (!std.ascii.eqlIgnoreCase(utf8(name, &name_buf) orelse return null, want)) return null;
        }
        return l.find(p, false, buf);
    }
};

// ---- Tests ----

const testing = std.testing;

test "patterns: the name, and the character set as a code point" {
    try testing.expectEqualDeep(Pattern{ .family = "sans-serif" }, parse("sans-serif").?);
    try testing.expectEqualDeep(Pattern{ .family = "sans-serif", .cp = 0x266a }, parse("sans-serif:charset=266a").?);
    try testing.expectEqualDeep(Pattern{ .family = "Lato", .cp = 0x9608 }, parse("Lato:weight=80:charset=9608").?);
    try testing.expectEqualDeep(Pattern{ .family = "Noto Sans CJK SC" }, parse("Noto Sans CJK SC").?);
    try testing.expectEqual(null, parse("sans-serif:charset=xyz"));
    try testing.expectEqual(kCTFontUIFontSystem, generic("Sans-Serif").?);
    try testing.expectEqual(kCTFontUIFontUserFixedPitch, generic("monospace").?);
    try testing.expectEqual(null, generic("Menlo"));
}

/// FreeType's PostScript and family names of face `index` of `path`.
fn ftNames(lib: c.FT_Library, path: [:0]const u8, index: c_int, ps: []u8, family: []u8) !struct { []const u8, []const u8 } {
    var face: c.FT_Face = null;
    if (c.FT_New_Face(lib, path.ptr, index, &face) != 0) return error.FreeTypeCannotOpen;
    defer _ = c.FT_Done_Face(face);
    const p = std.mem.span(c.FT_Get_Postscript_Name(face) orelse return error.NoPostScriptName);
    const f = std.mem.span(@as(?[*:0]const u8, face.*.family_name) orelse return error.NoFamilyName);
    @memcpy(ps[0..p.len], p);
    @memcpy(family[0..f.len], f);
    return .{ ps[0..p.len], family[0..f.len] };
}

test "a face in a collection: the index is the face of the family and name Core Text found" {
    var m: Matcher = .init();
    defer m.deinit();
    const l = &m.lookup.?;
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    var seen_inner = false;
    // Families of the named fallbacks and others that macOS installs, whose regular face
    // is in a collection (`.ttc`); some not at its start.
    for ([_][:0]const u8{ "Heiti SC", "Songti SC", "Hiragino Sans GB", "Geeza Pro", "Damascus", "Menlo", "Helvetica Neue" }) |family| {
        const found = m.match(family, family, &buf) orelse {
            std.debug.print("{s}: not installed (or not usable)\n", .{family});
            continue;
        };
        // What Core Text says the face is.
        const f = l.fontFor(family).?;
        defer release(f);
        var ct_buf: [256]u8 = undefined;
        const ct_name = utf8(CTFontCopyPostScriptName(f).?, &ct_buf).?;
        var ps_buf: [256]u8 = undefined;
        var fam_buf: [256]u8 = undefined;
        const names = try ftNames(l.lib, found.path, found.index, &ps_buf, &fam_buf);
        try testing.expectEqualStrings(ct_name, names[0]);
        try testing.expect(std.ascii.eqlIgnoreCase(family, names[1]));
        if (found.index > 0) seen_inner = true;
    }
    // At least one was not the collection's first face (Heiti SC is the second of its
    // file, Songti SC's regular the seventh), so an index off by one is seen.
    try testing.expect(seen_inner);
}

/// Prints `what` and where it was found when DIMNA_FONT_REPORT is set (the report the port
/// keeps of what each pattern resolves to on a Mac).
fn report(comptime fmt: []const u8, args: anytype) void {
    if (std.c.getenv("DIMNA_FONT_REPORT") != null) std.debug.print(fmt ++ "\n", args);
}

test "every pattern the program asks for is a file FreeType opens, with the character asked for" {
    const font_zig_extra = [_]u21{ 0x03C3, 0x2013, 0x2192, 0x266A, 0x25B8, 0x25BE };
    var lib: c.FT_Library = null;
    try testing.expectEqual(0, c.FT_Init_FreeType(&lib));
    defer _ = c.FT_Done_FreeType(lib);
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    // findFont: the callers open face 0.
    for ([_][:0]const u8{ "sans-serif", "monospace", "Helvetica Neue", "Lato", "DejaVu Sans" }) |pattern| {
        const path = try findFont(pattern, &buf);
        var face: c.FT_Face = null;
        try testing.expectEqual(0, c.FT_New_Face(lib, path.ptr, 0, &face));
        defer _ = c.FT_Done_Face(face);
        try testing.expect(c.FT_Get_Char_Index(face, 'A') != 0);
        report("findFont {s}: {s} (face 0: {s})", .{ pattern, path, std.mem.span(c.FT_Get_Postscript_Name(face).?) });
    }
    var pattern_buf: [48:0]u8 = undefined;
    for (font_zig_extra ++ [_]u21{ 0x9608, 0x0641, 0x06CC }) |cp| {
        const pattern = try std.fmt.bufPrintSentinel(&pattern_buf, "sans-serif:charset={x}", .{cp}, 0);
        const path = try findFont(pattern, &buf);
        var face: c.FT_Face = null;
        try testing.expectEqual(0, c.FT_New_Face(lib, path.ptr, 0, &face));
        defer _ = c.FT_Done_Face(face);
        try testing.expect(c.FT_Get_Char_Index(face, cp) != 0);
        report("findFont {s}: {s} (face 0: {s})", .{ pattern, path, std.mem.span(c.FT_Get_Postscript_Name(face).?) });
    }
    // Matcher.match, as the shaping engine asks: a character no named font has, and the
    // named fallbacks of either system (Linux's are not installed on a Mac by default).
    var m: Matcher = .init();
    defer m.deinit();
    for ([_]u21{ 0x9608, 0x0641, 0x0E01, 0x05D0, 0x266A }) |cp| {
        const pattern = try std.fmt.bufPrintSentinel(&pattern_buf, "sans-serif:charset={x}", .{cp}, 0);
        const found = m.match(pattern, null, &buf) orelse return error.NoFontForCharacter;
        var face: c.FT_Face = null;
        try testing.expectEqual(0, c.FT_New_Face(lib, found.path.ptr, found.index, &face));
        defer _ = c.FT_Done_Face(face);
        try testing.expect(c.FT_Get_Char_Index(face, cp) != 0);
        report("match {s}: {s} face {d} ({s})", .{ pattern, found.path, found.index, std.mem.span(c.FT_Get_Postscript_Name(face).?) });
    }
    for ([_][:0]const u8{ "Hiragino Sans GB", "Heiti SC", "Geeza Pro", "Damascus", "PingFang SC", "Noto Sans CJK SC", "Vazirmatn", "Noto Sans Arabic" }) |family| {
        const found = m.match(family, family, &buf) orelse {
            report("match {s} (family): none", .{family});
            continue;
        };
        var face: c.FT_Face = null;
        try testing.expectEqual(0, c.FT_New_Face(lib, found.path.ptr, found.index, &face));
        _ = c.FT_Done_Face(face);
        report("match {s} (family): {s} face {d}", .{ family, found.path, found.index });
    }
    // A family that is not installed is no match for itself (and nothing is downloaded).
    try testing.expectEqual(null, m.match("Lato", "Lato", &buf));
    // anyFontHas: the languages' samples (i18n.needs).
    try testing.expect(anyFontHas(&.{ 0x9608, 0x503C }));
    try testing.expect(anyFontHas(&.{ 0x067E, 0x06CC, 0x0641 }));
    // A character no font has: nothing (LastResort's boxes do not count).
    try testing.expect(!anyFontHas(&.{0x10FFFD}));
    try testing.expectError(error.FontNotFound, findFont("sans-serif:charset=10fffd", &buf));
    try testing.expectEqual(null, m.match("sans-serif:charset=10fffd", null, &buf));
}
