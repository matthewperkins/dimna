//! Text beyond the font's fixed glyphs (`font.zig`). Every such string is laid out by the
//! text backend (`text_backend.zig`), which finds the font for each character (the primary,
//! then fallbacks), and its glyphs are rasterised into the atlas here the first time they
//! are drawn. Latin Extended, Chinese and the like need nothing more: one
//! glyph per code point, left to right, as the fixed glyphs are laid out.
//!
//! A string with a character of a right-to-left or joined script (Persian, Hebrew, the
//! Indic scripts; combining marks) is also shaped: put in visual order and shaped by the
//! backend (FriBidi and HarfBuzz, loaded with dlopen the first time such a string is
//! drawn), given the string isolated as below and its paragraph direction. Where the system
//! cannot shape (`libs` is null), that text is laid out unshaped, left to right, and one
//! line in the log says so.
//!
//! The result is kept in a cache of laid-out strings, so a label drawn every frame is laid
//! out once.
//!
//! The paragraph direction of a shaped string is a setting of the engine (`Engine.rtl`),
//! chosen at start-up from the language (`start_rtl`). In a language read right to left,
//! every string with a right-to-left letter is laid out right to left, whatever comes first
//! ("{source} ..." with a Latin name first, a number first). Otherwise the direction is
//! that of the string's first strong letter (taken before the isolation below, which would
//! hide the Latin letters from the bidi algorithm's own rule). Numbers and
//! Latin text inside right-to-left text ("فیلتر 300-6000 Hz") are kept together as one
//! left-to-right block: each stretch from a Latin letter or a digit to the last Latin letter
//! or digit before the next right-to-left letter is isolated (as if between U+2066 and
//! U+2069). Plain Unicode bidi would otherwise turn the digits after an Arabic-script letter
//! into Arabic numbers and draw "300-6000" as "6000-300".

const std = @import("std");
const font = @import("font.zig");
const backend = @import("text_backend.zig");
const log = std.log.scoped(.font);

/// Laid-out strings kept (least recently used out).
pub const cache_entries = 2048;

/// The paragraph direction of the engines made from now on (`Engine.rtl`). Set once at
/// start-up, from the language, before any font is made.
pub var start_rtl: bool = false;

/// Bidi and shaping as the backend does them: null if this system cannot (the libraries
/// are missing; logged once). The first call may load them.
pub const Libs = backend.Shaping;
pub const libs = backend.shaping;
/// The bidi classes and paragraph directions the rules here look at.
const bidi = backend.bidi;

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

// ---- The engine ----

/// A glyph placed in a laid-out string: `x` pixels right of the string's origin (the pen
/// plus the backend's offset), `y` pixels above its baseline.
pub const Placed = struct {
    g: font.Glyph,
    x: i32,
    y: i32,
    /// Which font (index into `Engine.fonts.faces`) and which glyph of it.
    face: u8,
    gid: u32,
};

pub const Shaped = struct {
    glyphs: []const Placed,
    /// Pixels from the origin to the pen after the last glyph.
    width: f32,
};

pub const Engine = struct {
    gpa: std.mem.Allocator,
    /// The fonts, by index: the primary (0) and the fallbacks the backend found.
    fonts: backend.Fonts,
    /// Rasterised glyphs by (font, glyph index).
    glyphs: std.AutoHashMapUnmanaged(u64, font.Glyph) = .empty,
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
    /// False: never shape (tests of the path taken without shaping).
    allow_shaping: bool = true,
    /// A string with a right-to-left letter is laid out with a right-to-left paragraph
    /// direction (the language is read right to left); false: the direction of its first
    /// strong letter. Fixed when the engine is made (`start_rtl`), as the cache holds
    /// strings laid out with it.
    rtl: bool,
    cache: Cache = .{},
    // Scratch, reused from string to string.
    raw: std.ArrayList(u32) = .empty,
    raw_types: std.ArrayList(u32) = .empty,
    text: std.ArrayList(u32) = .empty,
    marks: std.ArrayList(bool) = .empty,
    mapped: std.ArrayList(backend.FaceGlyph) = .empty,
    laid: std.ArrayList(backend.RunGlyph) = .empty,
    out: std.ArrayList(Placed) = .empty,

    /// Takes `lib` and `primary` (set to the font's size) on success; on failure the caller
    /// still owns them. `f`: the font whose atlas and fixed glyphs this engine extends.
    pub fn create(gpa: std.mem.Allocator, lib: backend.Library, primary: backend.Face, f: *const font.Font) !*Engine {
        const self = try gpa.create(Engine);
        self.* = .{
            .gpa = gpa,
            .fonts = .init(gpa, lib, primary, f.px, f.line_height),
            .pen = f.pen,
            .rtl = start_rtl,
        };
        // The fixed glyphs the primary font drew are the same glyphs by index.
        for (f.glyphs, 0..) |g, k| {
            if (g.advance <= 0) continue;
            const gid = self.fonts.glyphIndex(0, font.Font.codepointAt(k));
            if (gid == 0) continue;
            self.glyphs.put(gpa, key(0, gid), g) catch {};
        }
        self.notdef = self.glyph(f.atlas, 0, 0);
        return self;
    }

    pub fn destroy(self: *Engine) void {
        const gpa = self.gpa;
        self.cache.deinit(gpa);
        self.fonts.deinit();
        self.glyphs.deinit(gpa);
        inline for (.{ "raw", "raw_types", "text", "marks", "mapped", "laid", "out" }) |name| {
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
        const bm = self.fonts.render(face_i, gid) orelse return error.NoGlyph;
        var g: font.Glyph = .{
            .left = @intCast(bm.left),
            .top = @intCast(bm.top),
            .advance = bm.advance,
        };
        const w: usize = bm.width;
        const h: usize = bm.rows;
        // Nothing to draw (a space), or not coverage (a colour bitmap): no room taken.
        if (w == 0 or h == 0 or !bm.gray) return g;
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
            const src: [*]const u8 = bm.pixels.? + row * @as(usize, @intCast(bm.pitch));
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

    /// Lays out `self.raw` into `self.out` without shaping: one glyph per code point, from
    /// the font that has it, left to right, each advance rounded as the fixed glyphs' are.
    fn simple(self: *Engine, atlas: []u8) !f32 {
        self.mapped.clearRetainingCapacity();
        try self.fonts.mapSimple(self.raw.items, &self.mapped);
        var pen: i32 = 0;
        for (self.mapped.items) |m| {
            const g = self.glyph(atlas, m.face, m.gid);
            try self.out.append(self.gpa, .{ .g = g, .x = pen, .y = 0, .face = m.face, .gid = m.gid });
            pen += @intFromFloat(@round(g.advance));
        }
        return @floatFromInt(pen);
    }

    /// Shapes `self.raw` into `self.out`: its paragraph direction and isolation decided here,
    /// laid out by the backend; returns the width.
    fn shape(self: *Engine, l: *const Libs, atlas: []u8) !f32 {
        const gpa = self.gpa;
        self.shaped_calls += 1;
        const raw = self.raw.items;
        if (raw.len == 0) return 0;
        try self.raw_types.resize(gpa, raw.len);
        backend.bidiTypes(l, raw, self.raw_types.items);
        const base = paragraphDirection(self.raw_types.items, self.rtl);
        try isolateLtr(gpa, raw, self.raw_types.items, &self.text, &self.marks);

        self.laid.clearRetainingCapacity();
        try self.fonts.layout(l, self.text.items, self.marks.items, base, &self.laid);
        var pen: i32 = 0;
        for (self.laid.items) |r| {
            const g = self.glyph(atlas, r.face, r.gid);
            try self.out.append(gpa, .{
                .g = g,
                .x = pen + whole(r.x_offset),
                .y = whole(r.y_offset),
                .face = r.face,
                .gid = r.gid,
            });
            pen += whole(r.x_advance);
        }
        return @floatFromInt(pen);
    }
};

/// Pixels to whole pixels, as the fixed glyphs' advances are rounded.
fn whole(v: f32) i32 {
    return @intFromFloat(@round(v));
}

/// The paragraph direction (`bidi.par_*`) for a string of bidi types `types`: right to left if `rtl`
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
// These load real fonts through the font lookup, and shaping where a test needs
// it (no window, no GPU). A test whose font or library is not installed is skipped, and
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

/// The font other than the primary that the backend draws `cp` with (found now if need
/// be): with FreeType the first named fallback that has it (or, if none has, the one the
/// lookup offers); with Core Text the one Core Text offers. Null if there is none.
fn fallbackFor(e: *Engine, cp: u32) ?u8 {
    var one: std.ArrayList(backend.FaceGlyph) = .empty;
    defer one.deinit(testing.allocator);
    e.fonts.mapSimple(&.{cp}, &one) catch return null;
    const g = one.items[0];
    return if (g.face == 0 or g.gid == 0) null else g.face;
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
        backend.bidiTypes(l, raw.items, types);
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
    if (!e.fonts.covers(0, 0x644)) return skipBecause("DejaVu Sans not installed");
    const la = try shapedCopy(&f, "\u{644}\u{627}");
    defer testing.allocator.free(la);
    try testing.expectEqual(1, la.len);
    try testing.expectEqual(0, la[0].face);
    try testing.expect(la[0].gid != 0);
    try testing.expect(la[0].gid != e.fonts.glyphIndex(0, 0x644));
    try testing.expect(la[0].gid != e.fonts.glyphIndex(0, 0x627));
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
        for ([_]u32{ 0x644, 0x627 }) |cp| try testing.expect(p.gid != f.engine.?.fonts.glyphIndex(ar, cp));
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
    // Leftmost, "300-6000 Hz" as drawn alone: the primary font's glyphs in the same order
    // and spacing; the Persian word is to their right. Of the primary font's glyphs, only
    // a space may be elsewhere (the one between the word and the block, which Core Text
    // draws with the primary font and FreeType with the Persian one).
    try testing.expect(all.len > latin.len);
    const block = all[0..latin.len];
    for (latin, block) |want, got| {
        try testing.expectEqual(0, got.face);
        try testing.expectEqual(want.gid, got.gid);
        try testing.expectEqual(want.x - latin[0].x, got.x - block[0].x);
    }
    const right_of_block = block[block.len - 1].x;
    var persian: usize = 0;
    for (all[block.len..]) |p| {
        if (p.face == 0) try testing.expectEqual(f.engine.?.fonts.glyphIndex(0, ' '), p.gid);
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
        try testing.expectEqual(e.fonts.glyphIndex(ar, cp), p.gid);
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
    if (e.fonts.cap_px) |cap| {
        try testing.expect(@abs(e.fonts.capPx(cjk).? - cap) <= 1);
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
    const gid = f.engine.?.fonts.glyphIndex(0, 0x142);
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
    const space = e.fonts.glyphIndex(0, ' ');
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
    // Its first glyphs; of the primary font's others, only the space before the word.
    try testing.expect(hz.len > latin.len);
    for (latin, hz[0..latin.len]) |want, p| {
        try testing.expectEqual(0, p.face);
        try testing.expectEqual(want.gid, p.gid);
        try testing.expectEqual(want.x - latin[0].x, p.x - h.latin[0]);
    }
    for (hz[latin.len..]) |p| {
        if (p.face == 0) try testing.expectEqual(space, p.gid);
    }
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
    const cap = e.fonts.cap_px orelse return skipBecause("the primary font has no capital H");
    const alef_px = e.fonts.capPx(ar).?;
    try testing.expect(@abs(alef_px - cap) <= 1);
    // Noto Sans Arabic's line is far taller than the primary's for the same letters, so
    // matching lines would have drawn alef at little more than half the height.
    try testing.expect(e.fonts.faces[ar].line_height > f.line_height);
}

// A record of what is drawn, to compare two builds (the text seam was moved behind
// `text_backend.zig` with this as its evidence). Not part of the usual run: set
// DIMNA_TEXT_DUMP to the file to write. For every message of every language, the strings
// the tests above shape and some fixed-width text, at 14 and 24 px, read left to right and
// right to left: one line per string and way of drawing it (`text`, `textMono`, `label`,
// `width`) with what it returned, the vertex count and a hash of the vertices; then each
// font's faces and a hash of its atlas.
test "dump: the vertices and atlas of strings in every language, for comparing builds" {
    const path = std.c.getenv("DIMNA_TEXT_DUMP") orelse return error.SkipZigTest;
    const gpa = testing.allocator;
    const i18n = @import("i18n.zig");
    var strings: std.ArrayList([]const u8) = .empty;
    defer strings.deinit(gpa);
    for (std.enums.values(i18n.Language)) |lang| {
        for (std.enums.values(i18n.Id)) |id| try strings.append(gpa, i18n.textOfIn(lang, id));
    }
    try strings.appendSlice(gpa, &.{
        "\u{633}\u{644}\u{627}\u{645}",                                                                 "\u{633}",                                                             "\u{644}",                                "\u{627}",
        "\u{644}\u{627}",                                                                               "\u{644}\u{645}",                                                      "\u{628}\u{627}",                         "\u{641}\u{6cc}\u{644}\u{62a}\u{631} 300-6000 Hz",
        "300-6000 Hz",
        "阈值",
        "\u{142}",                                                                                      "A   2.00 s   400\u{b5}V/row   300\u{2013}6000 Hz   \u{3c3} \u{2192}", "a \u{142}",                              "b \u{142}",
        "Simulator \u{641}\u{6cc}\u{644}\u{62a}\u{631}",                                                "Simulator",                                                           "12 \u{641}\u{6cc}\u{644}\u{62a}\u{631}", "\u{142}\u{f3}d\u{17a} 300 Hz",
        "\u{641} (-10 ms) \u{641}",                                                                     "\u{641} 50% \u{641} 2",                                               "\u{9608}\u{503c} 300-6000 Hz",           "\u{641}\u{6cc}\u{644}\u{62a}\u{631} 142-6000 Hz \u{6a9}\u{627}\u{646}\u{627}\u{644} 42",
        "\u{901a}\u{9053} 7 \u{9608}\u{503c} 21 \u{5fae}\u{4f0f} \u{6ee4}\u{6ce2}\u{5668} 300-6000 Hz", "e\u{301} a\u{308}",                                                   "\u{5e9}\u{5dc}\u{5d5}\u{5dd} abc",       "ab\xc3",
        "\x80x\xc3y",                                                                                   "\u{266a} \u{25b8} \u{25be}",                                          "",                                       " ",
        "\u{6f1}\u{6f2}\u{6f3} \u{66b}",
    });
    // Fixed-width text, as the display lays out in columns.
    const mono_strings = [_][]const u8{
        "  12.345 ms   -0.250 uV   ch 01 02 03",
        "0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz",
        "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~",
        "\u{b5}V \u{142} \u{641}",
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const vertices = try gpa.alloc(font.Vertex, 6 * 512);
    defer gpa.free(vertices);
    const saved_rtl = start_rtl;
    defer start_rtl = saved_rtl;
    for ([_][:0]const u8{ "sans-serif", "Lato", "DejaVu Sans" }) |family| {
        for ([_]u32{ 14, 24 }) |px| {
            for ([_]bool{ false, true }) |rtl| {
                start_rtl = rtl;
                var line: [256]u8 = undefined;
                var f = font.Font.init(gpa, family, px) catch |e| {
                    try out.appendSlice(gpa, try std.fmt.bufPrint(&line, "font {s} {d} px rtl {}: {t}\n", .{ family, px, rtl, e }));
                    continue;
                };
                defer f.deinit(gpa);
                const mono: []const u8 = if (f.addMono("monospace")) "mono" else |e| @errorName(e);
                var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
                const found = backend.findFont(family, &path_buf) catch "?";
                try out.appendSlice(gpa, try std.fmt.bufPrint(&line, "file {s}; shaping libraries loaded: {}\n", .{ found, libs() != null }));
                try out.appendSlice(gpa, try std.fmt.bufPrint(&line, "font {s} {d} px rtl {}: ascent {d} line {d} engine {} {s}\n", .{ family, px, rtl, f.ascent, f.line_height, f.engine != null, mono }));
                var batch: font.Batch = .{ .font = &f, .vertices = vertices };
                const Way = enum { text, textMono, label, width };
                for ([_][]const []const u8{ strings.items, &mono_strings }, 0..) |set, which| {
                    for (set, 0..) |s, k| {
                        for (std.enums.values(Way)) |way| {
                            batch.clear();
                            const x: f32 = 3.4;
                            const y: f32 = 7.6;
                            const white: font.Colour = .{ 255, 255, 255, 255 };
                            const r = switch (way) {
                                .text => batch.text(x, y, s, white),
                                .textMono => batch.textMono(x, y, s, white),
                                .label => batch.label(x, y, s, white),
                                .width => f.width(s),
                            };
                            const h = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(vertices[0..batch.len]));
                            try out.appendSlice(gpa, try std.fmt.bufPrint(&line, "{d}.{d} {t}: {x:0>8} {d} {x:0>16}\n", .{ which, k, way, @as(u32, @bitCast(r)), batch.len, h }));
                        }
                    }
                }
                if (f.engine) |e| {
                    for (e.fonts.faces[0..e.fonts.nfaces], 0..) |face, k| {
                        try out.appendSlice(gpa, try std.fmt.bufPrint(&line, "face {d}: line {d}\n", .{ k, face.line_height }));
                    }
                    try out.appendSlice(gpa, try std.fmt.bufPrint(&line, "named {d} cap {?d} glyphs {d} pen {d} {d} {d} full {}\n", .{ e.fonts.named, e.fonts.cap_px, e.glyphs.count(), e.pen.x, e.pen.y, e.pen.shelf_h, e.full }));
                }
                try out.appendSlice(gpa, try std.fmt.bufPrint(&line, "atlas {x:0>16} dirty {?any}\n", .{ std.hash.Wyhash.hash(0, f.atlas), f.takeDirty() }));
            }
        }
    }
    const file = try std.Io.Dir.cwd().createFile(testing.io, std.mem.span(path), .{});
    defer file.close(testing.io);
    try file.writeStreamingAll(testing.io, out.items);
}

/// The quads of `batch` composited over `rgb` (`w` x `h`, 3 bytes a pixel) as the windows'
/// renderers draw them: each quad's atlas texels, nearest, one to one; the colour's alpha
/// times the coverage, blended over what is there in 8-bit values.
fn composite(batch: *const font.Batch, rgb: []u8, w: usize, h: usize) void {
    const atlas = batch.font.atlas;
    const s: f32 = font.atlas_size;
    var q: usize = 0;
    while (q + 6 <= batch.len) : (q += 6) {
        const v0 = batch.vertices[q];
        const v2 = batch.vertices[q + 2];
        const x0 = @round(v0.pos[0]);
        const y0 = @round(v0.pos[1]);
        const x1 = @round(v2.pos[0]);
        const y1 = @round(v2.pos[1]);
        if (x1 <= x0 or y1 <= y0) continue;
        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                if (x < 0 or y < 0 or x >= @as(f32, @floatFromInt(w)) or y >= @as(f32, @floatFromInt(h))) continue;
                const u = v0.uv[0] + (x + 0.5 - x0) / (x1 - x0) * (v2.uv[0] - v0.uv[0]);
                const t = v0.uv[1] + (y + 0.5 - y0) / (y1 - y0) * (v2.uv[1] - v0.uv[1]);
                const tx: usize = @intFromFloat(@min(@max(u * s, 0), s - 1));
                const ty: usize = @intFromFloat(@min(@max(t * s, 0), s - 1));
                const cov: f32 = @floatFromInt(atlas[ty * font.atlas_size + tx]);
                const a = cov / 255.0 * @as(f32, @floatFromInt(v0.colour[3])) / 255.0;
                const px = rgb[(@as(usize, @intFromFloat(y)) * w + @as(usize, @intFromFloat(x))) * 3 ..][0..3];
                for (px, v0.colour[0..3]) |*d, c| {
                    const blended = @as(f32, @floatFromInt(c)) * a + @as(f32, @floatFromInt(d.*)) * (1 - a);
                    d.* = @intFromFloat(@round(@min(@max(blended, 0), 255)));
                }
            }
        }
    }
}

// A picture of sample text as this build draws it (the lead compares the two backends'):
// at 14, 20 and 24 px, each block at its size and below it magnified three times (nearest
// neighbour), on the display's background. Not part of the usual run: set DIMNA_TEXT_SHEET
// to the PNG file to write.
test "sheet: sample text drawn through the batch as the windows draw it, written as a PNG" {
    const path = std.c.getenv("DIMNA_TEXT_SHEET") orelse return error.SkipZigTest;
    const gpa = testing.allocator;
    const i18n = @import("i18n.zig");
    const theme = @import("theme.zig");
    const scheme = @import("scheme.zig");
    const Way = enum { text, mono, label };
    const Line = struct { s: []const u8, way: Way = .text };
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(gpa);
    try lines.appendSlice(gpa, &.{
        .{ .s = "A   2.00 s   400\u{b5}V/row   300-6000 Hz" },
        .{ .s = "A   2.00 s   400\u{b5}V/row   300-6000 Hz   (a label, on its backing)", .way = .label },
        .{ .s = "0123456789  +-.,:;/()[]{}%#&*=<>?!@  \u{b1}\u{b0}\u{d7}\u{f7}\u{b5}" },
        .{ .s = "  12.345 ms   -0.250 uV   ch 01 02 03   (fixed width)", .way = .mono },
        .{ .s = "\u{3c3}  \u{2013}  \u{2192}  \u{266a}  \u{25b8}  \u{25be}   (the six symbols)" },
    });
    for (std.enums.values(i18n.Language)) |lang| try lines.append(gpa, .{ .s = i18n.textOfIn(lang, .help_title) });
    try lines.appendSlice(gpa, &.{
        .{ .s = "\u{641}\u{6cc}\u{644}\u{62a}\u{631} 300-6000 Hz" },
        .{ .s = "\u{901a}\u{9053} 3   \u{9608}\u{503c} 5   \u{5fae}\u{4f0f}   \u{6ee4}\u{6ce2}\u{5668}   300-6000 Hz" },
    });
    const bg: [3]u8 = .{
        @intFromFloat(@round(theme.background[0] * 255)),
        @intFromFloat(@round(theme.background[1] * 255)),
        @intFromFloat(@round(theme.background[2] * 255)),
    };
    const vertices = try gpa.alloc(font.Vertex, 6 * 256);
    defer gpa.free(vertices);
    const margin = 8;
    const zoom = 3;
    // Each size's block, at 1x: a caption, then the lines.
    const Block = struct { rgb: []u8, w: usize, h: usize };
    var blocks: [3]Block = undefined;
    var made: usize = 0;
    defer for (blocks[0..made]) |b| gpa.free(b.rgb);
    var sheet_w: usize = 0;
    var sheet_h: usize = 0;
    for ([_]u32{ 14, 20, 24 }, 0..) |px, k| {
        var f = try font.Font.init(gpa, "sans-serif", px);
        defer f.deinit(gpa);
        f.addMono("monospace") catch {};
        var caption_buf: [64]u8 = undefined;
        const caption = try std.fmt.bufPrint(&caption_buf, "{d} px (above: as drawn; below: magnified {d}x)", .{ px, zoom });
        var w: f32 = f.width(caption);
        for (lines.items) |l| w = @max(w, if (l.way == .mono) f.widthMono(l.s) else f.width(l.s) + 6);
        const lh: usize = @intFromFloat(f.line_height + 4);
        const bw: usize = @as(usize, @intFromFloat(@ceil(w))) + 2 * margin;
        const bh: usize = (lines.items.len + 1) * lh + 2 * margin;
        const rgb = try gpa.alloc(u8, bw * bh * 3);
        for (0..bw * bh) |i| @memcpy(rgb[i * 3 ..][0..3], &bg);
        blocks[k] = .{ .rgb = rgb, .w = bw, .h = bh };
        made += 1;
        var batch: font.Batch = .{ .font = &f, .vertices = vertices };
        _ = batch.text(margin, margin, caption, theme.text_dim);
        composite(&batch, rgb, bw, bh);
        for (lines.items, 1..) |l, j| {
            batch.clear();
            const x: f32 = margin + 3;
            const y: f32 = @floatFromInt(margin + j * lh);
            _ = switch (l.way) {
                .text => batch.text(x, y, l.s, theme.text_bright),
                .mono => batch.textMono(x, y, l.s, theme.text_bright),
                .label => batch.label(x, y, l.s, theme.text_bright),
            };
            composite(&batch, rgb, bw, bh);
        }
        sheet_w = @max(sheet_w, bw * zoom);
        sheet_h += bh * (1 + zoom) + 2 * margin;
    }
    // The blocks one under the other, each at 1x and then magnified.
    const sheet = try gpa.alloc(u8, sheet_w * sheet_h * 3);
    defer gpa.free(sheet);
    @memset(sheet, 40);
    var top: usize = 0;
    for (blocks[0..made]) |b| {
        for (0..b.h) |y| @memcpy(sheet[((top + y) * sheet_w) * 3 ..][0 .. b.w * 3], b.rgb[y * b.w * 3 ..][0 .. b.w * 3]);
        top += b.h + margin;
        for (0..b.h * zoom) |y| for (0..b.w * zoom) |x| {
            @memcpy(sheet[((top + y) * sheet_w + x) * 3 ..][0..3], b.rgb[((y / zoom) * b.w + x / zoom) * 3 ..][0..3]);
        };
        top += b.h * zoom + margin;
    }
    const png = try scheme.encodePng(gpa, sheet, sheet_w, sheet_h);
    defer gpa.free(png);
    const file = try std.Io.Dir.cwd().createFile(testing.io, std.mem.span(path), .{});
    defer file.close(testing.io);
    try file.writeStreamingAll(testing.io, png);
    std.debug.print("text sheet {s}: {d} x {d} px\n", .{ path, sheet_w, sheet_h });
}

/// What every string draws to with a font of its own (`sans-serif` at 14 px): a hash of
/// each string's end and vertices, then of the atlas.
fn drawAllHash(gpa: std.mem.Allocator, strings: []const []const u8, vertices: []font.Vertex) !u64 {
    var f = try font.Font.init(gpa, "sans-serif", 14);
    defer f.deinit(gpa);
    var h = std.hash.Wyhash.init(0);
    var batch: font.Batch = .{ .font = &f, .vertices = vertices };
    for (strings) |s| {
        batch.clear();
        const end = batch.text(3.4, 7.6, s, .{ 255, 255, 255, 255 });
        h.update(std.mem.asBytes(&end));
        h.update(std.mem.sliceAsBytes(vertices[0..batch.len]));
    }
    h.update(f.atlas);
    return h.final();
}

// Three threads, each with its own font (as the three windows have), laying out and drawing
// every message of every language again and again, against what one thread alone drew. Not
// part of the usual run: set DIMNA_TEXT_THREADS to the seconds to run for.
test "threads: three fonts drawing every language at once draw what one alone does" {
    const env = std.c.getenv("DIMNA_TEXT_THREADS") orelse return error.SkipZigTest;
    const seconds = try std.fmt.parseInt(u32, std.mem.span(env), 10);
    const gpa = testing.allocator;
    const i18n = @import("i18n.zig");
    var strings: std.ArrayList([]const u8) = .empty;
    defer strings.deinit(gpa);
    for (std.enums.values(i18n.Language)) |lang| {
        for (std.enums.values(i18n.Id)) |id| try strings.append(gpa, i18n.textOfIn(lang, id));
    }
    try strings.append(gpa, "\u{641}\u{6cc}\u{644}\u{62a}\u{631} 300-6000 Hz");
    const vertices = try gpa.alloc(font.Vertex, 6 * 512);
    defer gpa.free(vertices);
    const want = try drawAllHash(gpa, strings.items, vertices);
    const Worker = struct {
        strings: []const []const u8,
        want: u64,
        until_ns: i96,
        rounds: usize = 0,
        wrong: usize = 0,
        failed: ?anyerror = null,

        fn run(self: *@This()) void {
            const vs = testing.allocator.alloc(font.Vertex, 6 * 512) catch |e| {
                self.failed = e;
                return;
            };
            defer testing.allocator.free(vs);
            while (std.Io.Clock.awake.now(testing.io).nanoseconds < self.until_ns) {
                const got = drawAllHash(testing.allocator, self.strings, vs) catch |e| {
                    self.failed = e;
                    return;
                };
                self.rounds += 1;
                if (got != self.want) self.wrong += 1;
            }
        }
    };
    const until = std.Io.Clock.awake.now(testing.io).nanoseconds + @as(i96, seconds) * std.time.ns_per_s;
    var workers: [3]Worker = @splat(.{ .strings = strings.items, .want = want, .until_ns = until });
    var threads: [3]std.Thread = undefined;
    for (&threads, &workers) |*t, *w| t.* = try std.Thread.spawn(.{}, Worker.run, .{w});
    for (threads) |t| t.join();
    for (workers, 0..) |w, k| {
        std.debug.print("thread {d}: {d} rounds of {d} strings, {d} not as one thread alone drew them\n", .{ k, w.rounds, strings.items.len, w.wrong });
        if (w.failed) |e| return e;
        try testing.expect(w.rounds > 0);
        try testing.expectEqual(0, w.wrong);
    }
}
