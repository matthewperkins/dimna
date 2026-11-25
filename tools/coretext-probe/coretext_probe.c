// What Core Text gives, measured (docs/plans/macos-text-step2-probe.md). A throwaway probe:
// opens no window, plays nothing, touches no USB device, and asks only for fonts that are
// installed. See README.md for how to build and run it.
//
//   coretext_probe MODE [options]
//   MODE: glyph | metrics | fonts | lines | bidi | cost | threads
//   options: -v (per-glyph rows), --out DIR (PGM files), --seconds N (threads)
#include <CoreText/CoreText.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_TRUETYPE_TABLES_H
#include FT_SIZES_H
#include <harfbuzz/hb.h>
#include <harfbuzz/hb-ft.h>
#include <fribidi/fribidi.h>

static int verbose = 0;
static const char *outdir = NULL;
static int seconds = 10;

static double now_us(void) {
    return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000.0;
}

// ---------------------------------------------------------------- helpers

static void cfs_to_buf(CFStringRef s, char *buf, size_t n) {
    buf[0] = 0;
    if (s) CFStringGetCString(s, buf, (CFIndex)n, kCFStringEncodingUTF8);
}

static CFStringRef cfs(const char *s) {
    return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
}

static CFStringRef cfs_u32(const uint32_t *cps, int n) {
    return CFStringCreateWithBytes(NULL, (const UInt8 *)cps, (CFIndex)n * 4, kCFStringEncodingUTF32LE, false);
}

static int u8enc(uint32_t cp, char *o) {
    if (cp < 0x80) { o[0] = (char)cp; return 1; }
    if (cp < 0x800) { o[0] = (char)(0xC0 | cp >> 6); o[1] = (char)(0x80 | (cp & 63)); return 2; }
    if (cp < 0x10000) { o[0] = (char)(0xE0 | cp >> 12); o[1] = (char)(0x80 | ((cp >> 6) & 63)); o[2] = (char)(0x80 | (cp & 63)); return 3; }
    o[0] = (char)(0xF0 | cp >> 18); o[1] = (char)(0x80 | ((cp >> 12) & 63)); o[2] = (char)(0x80 | ((cp >> 6) & 63)); o[3] = (char)(0x80 | (cp & 63));
    return 4;
}

static int u8dec(const char *s, uint32_t *out, int max) {
    int n = 0;
    const unsigned char *p = (const unsigned char *)s;
    while (*p && n < max) {
        uint32_t c = *p;
        int len = 1;
        if (c >= 0xF0) { c &= 7; len = 4; } else if (c >= 0xE0) { c &= 15; len = 3; } else if (c >= 0xC0) { c &= 31; len = 2; }
        for (int i = 1; i < len; i++) c = c << 6 | (p[i] & 63);
        out[n++] = c;
        p += len;
    }
    return n;
}

static void print_cp(uint32_t c) {
    char b[8];
    if (c == 0x2066) fputs("<LRI>", stdout);
    else if (c == 0x2069) fputs("<PDI>", stdout);
    else { int k = u8enc(c, b); fwrite(b, 1, (size_t)k, stdout); }
}

static void print_cps(const uint32_t *cps, int n) {
    for (int i = 0; i < n; i++) print_cp(cps[i]);
}

static void font_names(CTFontRef f, char *ps, size_t psn, char *fam, size_t famn) {
    CFStringRef a = CTFontCopyPostScriptName(f);
    CFStringRef b = CTFontCopyFamilyName(f);
    cfs_to_buf(a, ps, psn);
    cfs_to_buf(b, fam, famn);
    if (a) CFRelease(a);
    if (b) CFRelease(b);
}

static void font_file(CTFontRef f, char *buf, size_t n) {
    buf[0] = 0;
    CFURLRef u = CTFontCopyAttribute(f, kCTFontURLAttribute);
    if (u) {
        CFURLGetFileSystemRepresentation(u, true, (UInt8 *)buf, (CFIndex)n);
        CFRelease(u);
    }
}

static int cmp_d(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

typedef struct { double med, p99, max, min, mean; } Stats;

static Stats stats_of(double *v, int n) {
    qsort(v, (size_t)n, sizeof(double), cmp_d);
    Stats s = { v[n / 2], v[(int)((n - 1) * 0.99)], v[n - 1], v[0], 0 };
    for (int i = 0; i < n; i++) s.mean += v[i];
    s.mean /= n;
    return s;
}

static void print_stats(const char *what, Stats s) {
    printf("  %-62s median %8.2f  mean %8.2f  p99 %8.2f  worst %9.2f  best %7.2f us\n", what, s.med, s.mean, s.p99, s.max, s.min);
}

// ---------------------------------------------------------------- FreeType and Core Text faces

static FT_Library ftlib;

typedef struct {
    const char *name, *path;
    int index;
    int kind; // 0 latin, 1 chinese, 2 persian
    double opsz; // != 0: not the optical size Core Text picks from the size (-1: none)
} Spec;

static const Spec specs[] = {
    { "System (SFNS.ttf)", "/System/Library/Fonts/SFNS.ttf", 0, 0, 0 },
    { "Helvetica Neue", "/System/Library/Fonts/HelveticaNeue.ttc", 0, 0, 0 },
    { "Menlo", "/System/Library/Fonts/Menlo.ttc", 0, 0, 0 },
    { "Hiragino Sans GB", "/System/Library/Fonts/Hiragino Sans GB.ttc", 0, 1, 0 },
    { "Geeza Pro", "/System/Library/Fonts/GeezaPro.ttc", 0, 2, 0 },
    { "System (SFNS.ttf), CT optical sizing none", "/System/Library/Fonts/SFNS.ttf", 0, 0, -1 },
};
static const int nspecs = sizeof specs / sizeof specs[0];

static const uint32_t latin_cps[] = { 'P', 'o', 'r', 't', ' ', 'A', '3', '0', '-', '6', 'H', 'z', 0xb5, 'V', '/', 'w', '.' };
static const uint32_t zh_cps[] = { 0x901a, 0x9053, 0x9608, 0x503c, 0x6ee4, 0x6ce2, 0x5668, 0x5fae, 0x4f0f };
static const uint32_t fa_cps[] = { 0x641, 0x6cc, 0x644, 0x62a, 0x631, 0x6a9, 0x627, 0x646, 0x633, 0x645, 0x628, '3', '0', '-', '6' };

static const uint32_t *spec_cps(const Spec *s, int *n) {
    if (s->kind == 1) { *n = sizeof zh_cps / 4; return zh_cps; }
    if (s->kind == 2) { *n = sizeof fa_cps / 4; return fa_cps; }
    *n = sizeof latin_cps / 4;
    return latin_cps;
}

static FT_Face ft_open(const Spec *s, int px) {
    FT_Face f = NULL;
    if (FT_New_Face(ftlib, s->path, s->index, &f)) { fprintf(stderr, "FT_New_Face failed: %s\n", s->path); exit(1); }
    FT_Set_Pixel_Sizes(f, 0, (FT_UInt)px);
    return f;
}

// The CTFont for the face of `path` whose PostScript name is `ps`, at `px` (a font size in
// Core Text is in points; drawn into a context with no scale, one point is one pixel).
// Made from the file itself (CTFontManagerCreateFontDescriptorsFromURL registers nothing).
static CTFontRef ct_from_file_opsz(const char *path, const char *ps, int index, double px, double opsz, int *how) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CFArrayRef ds = CTFontManagerCreateFontDescriptorsFromURL(url);
    CFRelease(url);
    if (!ds) return NULL;
    CTFontDescriptorRef pick = NULL;
    *how = -1;
    for (CFIndex i = 0; i < CFArrayGetCount(ds); i++) {
        CTFontDescriptorRef d = (CTFontDescriptorRef)CFArrayGetValueAtIndex(ds, i);
        CFStringRef n = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute);
        char b[256];
        cfs_to_buf(n, b, sizeof b);
        if (n) CFRelease(n);
        if (ps && strcmp(b, ps) == 0) { pick = d; *how = (int)i; break; }
    }
    if (!pick && index < CFArrayGetCount(ds)) { pick = (CTFontDescriptorRef)CFArrayGetValueAtIndex(ds, index); *how = -2 - index; }
    CTFontDescriptorRef use = pick ? (CTFontDescriptorRef)CFRetain(pick) : NULL;
    if (use && opsz != 0) {
        // opsz < 0: kCTFontOpticalSizeAttribute "none" (no automatic optical sizing: the
        // file's default instance, as FreeType draws it); opsz > 0: that optical size.
        CFTypeRef val = opsz < 0 ? (CFTypeRef)CFSTR("none") : (CFTypeRef)CFNumberCreate(NULL, kCFNumberDoubleType, &opsz);
        const void *k[] = { kCTFontOpticalSizeAttribute };
        const void *v[] = { val };
        CFDictionaryRef at = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CTFontDescriptorRef d2 = CTFontDescriptorCreateCopyWithAttributes(use, at);
        CFRelease(at);
        if (opsz > 0) CFRelease(val);
        CFRelease(use);
        use = d2;
    }
    CTFontRef f = use ? CTFontCreateWithFontDescriptor(use, px, NULL) : NULL;
    if (use) CFRelease(use);
    CFRelease(ds);
    return f;
}

static CTFontRef ct_from_file(const char *path, const char *ps, int index, double px, int *how) {
    return ct_from_file_opsz(path, ps, index, px, 0, how);
}

// ---------------------------------------------------------------- coverage bitmaps

#define CW 128
#define CH 128
#define OX 40
#define OY 40 // the baseline is OY pixels above the bottom edge: memory row CH - OY is the first row above it

typedef struct {
    int left, top, w, h; // like FreeType's: pixels right of the origin, pixels above the baseline
    long sum;
} Ink;

static Ink ink_of(const uint8_t *c) {
    int x0 = CW, x1 = -1, y0 = CH, y1 = -1;
    long sum = 0;
    for (int y = 0; y < CH; y++)
        for (int x = 0; x < CW; x++)
            if (c[y * CW + x]) {
                sum += c[y * CW + x];
                if (x < x0) x0 = x;
                if (x > x1) x1 = x;
                if (y < y0) y0 = y;
                if (y > y1) y1 = y;
            }
    Ink k = { 0, 0, 0, 0, sum };
    if (x1 >= 0) { k.left = x0 - OX; k.top = (CH - OY) - y0; k.w = x1 - x0 + 1; k.h = y1 - y0 + 1; }
    return k;
}

typedef struct { int smooth, subpix; const char *name; } CgCfg;
static const CgCfg cfgs[] = {
    { 0, 0, "smooth off, subpixel off" },
    { 1, 0, "smooth ON,  subpixel off" },
    { 0, 1, "smooth off, subpixel ON " },
    { 1, 1, "smooth ON,  subpixel ON " },
};

static void set_cfg(CGContextRef cx, const CgCfg *cfg) {
    CGContextSetShouldAntialias(cx, true);
    CGContextSetAllowsAntialiasing(cx, true);
    CGContextSetAllowsFontSmoothing(cx, cfg->smooth);
    CGContextSetShouldSmoothFonts(cx, cfg->smooth);
    CGContextSetAllowsFontSubpixelPositioning(cx, cfg->subpix);
    CGContextSetShouldSubpixelPositionFonts(cx, cfg->subpix);
    CGContextSetAllowsFontSubpixelQuantization(cx, !cfg->subpix);
    CGContextSetShouldSubpixelQuantizeFonts(cx, !cfg->subpix);
}

// Coverage of one glyph drawn with the pen at (OX + fx, baseline).
static void ct_render(CTFontRef f, CGGlyph g, double fx, const CgCfg *cfg, uint8_t *out) {
    memset(out, 0, CW * CH);
    CGContextRef cx = CGBitmapContextCreate(out, CW, CH, 8, CW, NULL, kCGImageAlphaOnly);
    set_cfg(cx, cfg);
    CGPoint p = { OX + fx, OY };
    CTFontDrawGlyphs(f, &g, &p, 1, cx);
    CGContextRelease(cx);
}

typedef struct { Ink ink; double adv, lin; } FtG;

static int ft_render(FT_Face face, unsigned gid, int flags, uint8_t *out, FtG *r) {
    memset(out, 0, CW * CH);
    if (FT_Load_Glyph(face, gid, FT_LOAD_RENDER | flags)) return 0;
    FT_GlyphSlot s = face->glyph;
    FT_Bitmap *b = &s->bitmap;
    r->adv = s->advance.x / 64.0;
    r->lin = s->linearHoriAdvance / 65536.0;
    for (unsigned j = 0; j < b->rows; j++)
        for (unsigned i = 0; i < b->width; i++) {
            int x = OX + s->bitmap_left + (int)i;
            int y = (CH - OY) - s->bitmap_top + (int)j;
            if (x >= 0 && x < CW && y >= 0 && y < CH) out[y * CW + x] = b->buffer[j * (unsigned)b->pitch + i];
        }
    r->ink = ink_of(out);
    return 1;
}

// Mean absolute coverage difference over the union of the two inks' boxes, and the largest.
static void diff(const uint8_t *a, const uint8_t *b, double *mean, int *mx) {
    int x0 = CW, x1 = -1, y0 = CH, y1 = -1;
    for (int y = 0; y < CH; y++)
        for (int x = 0; x < CW; x++)
            if (a[y * CW + x] || b[y * CW + x]) {
                if (x < x0) x0 = x;
                if (x > x1) x1 = x;
                if (y < y0) y0 = y;
                if (y > y1) y1 = y;
            }
    *mean = 0;
    *mx = 0;
    if (x1 < 0) return;
    long s = 0;
    for (int y = y0; y <= y1; y++)
        for (int x = x0; x <= x1; x++) {
            int d = abs(a[y * CW + x] - b[y * CW + x]);
            s += d;
            if (d > *mx) *mx = d;
        }
    *mean = (double)s / ((x1 - x0 + 1) * (y1 - y0 + 1));
}

// ---------------------------------------------------------------- Q1: glyph coverage

static void write_pgm(const char *name, const uint8_t *p, int w, int h) {
    if (!outdir) return;
    char path[1024];
    snprintf(path, sizeof path, "%s/%s", outdir, name);
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); return; }
    fprintf(f, "P5\n%d %d\n255\n", w, h);
    fwrite(p, 1, (size_t)w * (size_t)h, f);
    fclose(f);
    printf("  wrote %s (%dx%d)\n", path, w, h);
}

static void ascii_art(const char *title, const uint8_t *p, int w, int h) {
    static const char ramp[] = " .:-=+*#%@";
    printf("  %s\n", title);
    for (int y = 0; y < h; y++) {
        printf("  |");
        for (int x = 0; x < w; x++) putchar(ramp[p[y * w + x] * 9 / 255]);
        printf("|\n");
    }
}

// Adds the glyph canvas `src` (origin at OX, baseline at CH-OY) into `dst` at pen `ipen`
// and baseline row `base`.
static void blit(uint8_t *dst, int W, int H, const uint8_t *src, int ipen, int base) {
    for (int y = 0; y < CH; y++)
        for (int x = 0; x < CW; x++) {
            uint8_t v = src[y * CW + x];
            if (!v) continue;
            int dx = ipen + (x - OX), dy = base - ((CH - OY) - y);
            if (dx >= 0 && dx < W && dy >= 0 && dy < H) { int s = dst[dy * W + dx] + v; dst[dy * W + dx] = s > 255 ? 255 : (uint8_t)s; }
        }
}

// "Port A 300-6000 Hz" at `px`: the pen moves by whole pixels, as dimna's does (FreeType:
// the hinted advance; Core Text: its advance rounded). FreeType is drawn hinted (as dimna
// does) and unhinted at the same pens.
// The font's optical-size axis value, NaN if it has none.
static double ct_opsz(CTFontRef f) {
    double cur = NAN;
    CFDictionaryRef var = CTFontCopyVariation(f);
    if (var) {
        int idv = 0x6f70737a; // 'opsz'
        CFNumberRef id = CFNumberCreate(NULL, kCFNumberIntType, &idv);
        CFNumberRef c = CFDictionaryGetValue(var, id);
        if (c) CFNumberGetValue(c, kCFNumberDoubleType, &cur);
        CFRelease(id);
        CFRelease(var);
    }
    return cur;
}

static void render_string_pair(const Spec *sp, int spi, int px) {
    FT_Face ft = ft_open(sp, px);
    int how;
    CTFontRef ct = ct_from_file_opsz(sp->path, FT_Get_Postscript_Name(ft), sp->index, px, sp->opsz, &how);
    const char *text = "Port A 300-6000 Hz";
    uint32_t cps[64];
    int n = u8dec(text, cps, 64);
    int W = px * 12 + 8, H = px * 2, base = px + px / 4;
    uint8_t *ctimg = calloc((size_t)W * H, 1), *ftimg = calloc((size_t)W * H, 1), *fuimg = calloc((size_t)W * H, 1), *csimg = calloc((size_t)W * H, 1);
    uint8_t *dimg = calloc((size_t)W * H, 1);
    uint8_t *t1 = malloc(CW * CH), *t2 = malloc(CW * CH);
    int pen_ct = 4, pen_ft = 4;
    for (int i = 0; i < n; i++) {
        UniChar u = (UniChar)cps[i];
        CGGlyph g = 0;
        CTFontGetGlyphsForCharacters(ct, &u, &g, 1);
        unsigned fg = FT_Get_Char_Index(ft, cps[i]);
        CGSize adv;
        CTFontGetAdvancesForGlyphs(ct, kCTFontOrientationHorizontal, &g, &adv, 1);
        ct_render(ct, g, 0, &cfgs[0], t1);
        blit(ctimg, W, H, t1, pen_ct, base); // Core Text's own pens
        blit(csimg, W, H, t1, pen_ft, base); // Core Text's glyphs at FreeType's pens
        pen_ct += (int)round(adv.width);
        FtG r;
        ft_render(ft, fg, 0, t2, &r);
        blit(ftimg, W, H, t2, pen_ft, base);
        FtG ru;
        ft_render(ft, fg, FT_LOAD_NO_HINTING, t2, &ru);
        blit(fuimg, W, H, t2, pen_ft, base);
        pen_ft += (int)round(r.adv);
    }
    long sc = 0, sf = 0, su = 0;
    for (int i = 0; i < W * H; i++) { sc += ctimg[i]; sf += ftimg[i]; su += fuimg[i]; }
    printf("\"%s\", %s at %d px: string width with whole-pixel pens: CT %d px, FT %d px; total coverage CT %ld, FT hinted %ld, FT unhinted %ld (CT/FT hinted %.3f)\n",
           text, sp->name, px, pen_ct - 4, pen_ft - 4, sc, sf, su, (double)sc / (double)sf);
    struct { const char *what; uint8_t *a, *b; } pairs[] = {
        { "CT at CT's own pens   vs FT hinted at FT's pens  ", ctimg, ftimg },
        { "CT at FT's pens       vs FT hinted               ", csimg, ftimg },
        { "CT at FT's pens       vs FT unhinted             ", csimg, fuimg },
    };
    for (int k = 0; k < 3; k++) {
        long sd = 0;
        int md = 0, inkpx = 0;
        for (int i = 0; i < W * H; i++) {
            int d = abs(pairs[k].a[i] - pairs[k].b[i]);
            if (k == 0) dimg[i] = (uint8_t)d;
            sd += d;
            if (d > md) md = d;
            if (pairs[k].a[i] || pairs[k].b[i]) inkpx++;
        }
        printf("  %s: mean |diff| over pixels with ink in either %.1f of 255, max %d (%d such pixels)\n", pairs[k].what, (double)sd / inkpx, md, inkpx);
    }
    char nm[128];
    snprintf(nm, sizeof nm, "s%d_ct_%d.pgm", spi, px); write_pgm(nm, ctimg, W, H);
    snprintf(nm, sizeof nm, "s%d_ct_at_ft_pens_%d.pgm", spi, px); write_pgm(nm, csimg, W, H);
    snprintf(nm, sizeof nm, "s%d_ft_%d.pgm", spi, px); write_pgm(nm, ftimg, W, H);
    snprintf(nm, sizeof nm, "s%d_ft_unhinted_%d.pgm", spi, px); write_pgm(nm, fuimg, W, H);
    snprintf(nm, sizeof nm, "s%d_diff_own_pens_%d.pgm", spi, px); write_pgm(nm, dimg, W, H);
    if (px == 14) {
        int from = base - 12, rows = 16, cols = 60;
        uint8_t *a = malloc((size_t)cols * rows), *b = malloc((size_t)cols * rows);
        for (int y = 0; y < rows; y++)
            for (int x = 0; x < cols; x++) { a[y * cols + x] = ctimg[(from + y) * W + x]; b[y * cols + x] = ftimg[(from + y) * W + x]; }
        ascii_art("Core Text (font smoothing off), its own pens, 'Port A':", a, cols, rows);
        ascii_art("FreeType (hinted, as dimna), 'Port A':", b, cols, rows);
        free(a); free(b);
    }
    free(ctimg); free(ftimg); free(fuimg); free(csimg); free(dimg); free(t1); free(t2);
    CFRelease(ct);
    FT_Done_Face(ft);
}

static void mode_glyph(void) {
    int sizes[] = { 14, 20, 24 };
    printf("== Q1: glyph coverage: Core Text (CTFontDrawGlyphs into an 8-bit kCGImageAlphaOnly CGBitmapContext, no CTM scale) against FreeType (FT_Set_Pixel_Sizes, FT_LOAD_RENDER)\n");
    printf("   Size: CTFontCreateWithFontDescriptor(desc, px) drawn into an unscaled context: 1 pt = 1 pixel (checked below: CT upem and advances scale as FT's do).\n\n");
    for (int si = 0; si < 3; si++) {
        int px = sizes[si];
        for (int fi = 0; fi < nspecs; fi++) {
            const Spec *sp = &specs[fi];
            FT_Face ft = ft_open(sp, px);
            const char *ps = FT_Get_Postscript_Name(ft);
            int how = 0;
            CTFontRef ct = ct_from_file_opsz(sp->path, ps, sp->index, px, sp->opsz, &how);
            if (!ct) { printf("%s: no CTFont from file\n", sp->name); continue; }
            char cps_[256], fam[256];
            font_names(ct, cps_, sizeof cps_, fam, sizeof fam);
            int ncp;
            const uint32_t *cp = spec_cps(sp, &ncp);
            uint8_t *c1 = malloc(CW * CH), *c2 = malloc(CW * CH), *f0 = malloc(CW * CH), *fu = malloc(CW * CH);
            printf("-- %s at %d px: FT ps=%s upem=%ld; CT ps=%s (descriptor %d) size=%.1f upem=%u opsz=%.1f\n", sp->name, px, ps, (long)ft->units_per_EM, cps_, how, CTFontGetSize(ct), CTFontGetUnitsPerEm(ct), ct_opsz(ct));
            int gid_mismatch = 0, n = 0, adv_whole = 0, left_same = 0, top_same = 0, wh_same = 0;
            double max_adv_h = 0, max_adv_l = 0, sum_adv_h = 0, sum_adv_l = 0;
            double mean_h[4] = { 0 }, mean_u[4] = { 0 };
            int max_h[4] = { 0 }, max_u[4] = { 0 };
            long ink_ct[4] = { 0 }, ink_fh = 0, ink_fu = 0;
            double frac_shift[4][4] = { { 0 } };
            for (int i = 0; i < ncp; i++) {
                UniChar u = (UniChar)cp[i];
                CGGlyph g = 0;
                CTFontGetGlyphsForCharacters(ct, &u, &g, 1);
                unsigned fg = FT_Get_Char_Index(ft, cp[i]);
                if (g != fg) { gid_mismatch++; if (verbose) printf("   gid mismatch U+%04X ct=%u ft=%u\n", cp[i], g, fg); }
                if (!fg || !g) continue;
                FtG fh, fun;
                if (!ft_render(ft, fg, 0, f0, &fh)) continue;
                ft_render(ft, fg, FT_LOAD_NO_HINTING, fu, &fun);
                CGSize adv;
                CTFontGetAdvancesForGlyphs(ct, kCTFontOrientationHorizontal, &g, &adv, 1);
                n++;
                if (fabs(adv.width - round(adv.width)) < 1e-6) adv_whole++;
                double dh = fabs(adv.width - fh.adv), dl = fabs(adv.width - fh.lin);
                if (dh > max_adv_h) max_adv_h = dh;
                if (dl > max_adv_l) max_adv_l = dl;
                sum_adv_h += dh; sum_adv_l += dl;
                ink_fh += fh.ink.sum; ink_fu += fun.ink.sum;
                for (int k = 0; k < 4; k++) {
                    ct_render(ct, g, 0, &cfgs[k], c1);
                    Ink ci = ink_of(c1);
                    if (k == 0) {
                        if (ci.left == fh.ink.left) left_same++;
                        if (ci.top == fh.ink.top) top_same++;
                        if (ci.w == fh.ink.w && ci.h == fh.ink.h) wh_same++;
                        if (verbose)
                            printf("   U+%04X gid %u: advance CT %.3f, FT hinted %.0f, FT linear %.3f | ink CT l%d t%d %dx%d, FT hinted l%d t%d %dx%d, FT unhinted l%d t%d %dx%d\n",
                                   cp[i], g, adv.width, fh.adv, fh.lin, ci.left, ci.top, ci.w, ci.h, fh.ink.left, fh.ink.top, fh.ink.w, fh.ink.h, fun.ink.left, fun.ink.top, fun.ink.w, fun.ink.h);
                    }
                    double m; int x;
                    diff(c1, f0, &m, &x); mean_h[k] += m; if (x > max_h[k]) max_h[k] = x;
                    diff(c1, fu, &m, &x); mean_u[k] += m; if (x > max_u[k]) max_u[k] = x;
                    ink_ct[k] += ci.sum;
                    for (int q = 1; q < 4; q++) {
                        ct_render(ct, g, q * 0.25, &cfgs[k], c2);
                        double mm; int xx;
                        diff(c1, c2, &mm, &xx);
                        frac_shift[k][q] += mm;
                    }
                }
            }
            printf("   %d glyphs; glyph-id mismatches CT vs FT: %d\n", n, gid_mismatch);
            if (n) {
                printf("   advance: CT a whole number of pixels for %d/%d; |CT - FT hinted| mean %.3f max %.3f; |CT - FT unhinted (linear)| mean %.4f max %.4f px\n",
                       adv_whole, n, sum_adv_h / n, max_adv_h, sum_adv_l / n, max_adv_l);
                printf("   ink box, CT (smooth off) vs FT hinted: same left %d/%d, same top %d/%d, same width and height %d/%d\n", left_same, n, top_same, n, wh_same, n);
                printf("   total coverage over the %d glyphs: FT hinted %ld, FT unhinted %ld\n", n, ink_fh, ink_fu);
                for (int k = 0; k < 4; k++)
                    printf("   CT %s: coverage sum %ld (x%.3f of FT hinted) | vs FT hinted: mean %.2f max %d | vs FT unhinted: mean %.2f max %d | CT at pen +.25/.5/.75 against itself at 0: mean %.2f %.2f %.2f\n",
                           cfgs[k].name, ink_ct[k], (double)ink_ct[k] / (double)ink_fh, mean_h[k] / n, max_h[k], mean_u[k] / n, max_u[k],
                           frac_shift[k][1] / n, frac_shift[k][2] / n, frac_shift[k][3] / n);
            }
            free(c1); free(c2); free(f0); free(fu);
            CFRelease(ct);
            FT_Done_Face(ft);
        }
        printf("\n");
    }
    printf("-- which pixel formats give coverage: 'Port A' glyphs, system UI font at 14 px, summed coverage and difference to the alpha-only result\n");
    {
        CTFontRef f = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 14, NULL);
        const char *txt = "Port A";
        uint8_t *a = malloc(CW * CH), *b = malloc(CW * CH);
        for (int smooth = 0; smooth < 2; smooth++) {
            long sa = 0, sg = 0, sgi = 0, srgb = 0;
            double dg = 0;
            int mg = 0;
            for (const char *p = txt; *p; p++) {
                UniChar u = (UniChar)*p;
                CGGlyph g;
                CTFontGetGlyphsForCharacters(f, &u, &g, 1);
                CgCfg cfg = { smooth, 0, "" };
                ct_render(f, g, 0, &cfg, a);
                sa += ink_of(a).sum;
                // 8-bit DeviceGray, black cleared, white fill: the gray value is coverage.
                memset(b, 0, CW * CH);
                CGColorSpaceRef gs = CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2);
                CGContextRef cx = CGBitmapContextCreate(b, CW, CH, 8, CW, gs, kCGImageAlphaNone);
                set_cfg(cx, &cfg);
                CGContextSetGrayFillColor(cx, 1.0, 1.0);
                CGPoint pt = { OX, OY };
                CTFontDrawGlyphs(f, &g, &pt, 1, cx);
                CGContextRelease(cx);
                CGColorSpaceRelease(gs);
                sg += ink_of(b).sum;
                double m; int x;
                diff(a, b, &m, &x);
                dg += m; if (x > mg) mg = x;
                // The same on white, black fill: 255 - value is coverage.
                memset(b, 255, CW * CH);
                gs = CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2);
                cx = CGBitmapContextCreate(b, CW, CH, 8, CW, gs, kCGImageAlphaNone);
                set_cfg(cx, &cfg);
                CGContextSetGrayFillColor(cx, 0.0, 1.0);
                CTFontDrawGlyphs(f, &g, &pt, 1, cx);
                CGContextRelease(cx);
                CGColorSpaceRelease(gs);
                for (int k = 0; k < CW * CH; k++) b[k] = (uint8_t)(255 - b[k]);
                sgi += ink_of(b).sum;
                (void)srgb;
            }
            printf("  smoothing %s: alpha-only (kCGImageAlphaOnly, no color space) coverage %ld | DeviceGray white-on-black %ld (mean diff to alpha-only over glyph boxes %.2f, max %d) | gray black-on-white inverted %ld\n",
                   smooth ? "ON " : "off", sa, sg, dg / 6, mg, sgi);
        }
        free(a); free(b);
        CFRelease(f);
    }
    printf("-- a string, whole-pixel pens\n");
    int which[] = { 0, 5, 1 };
    for (int w = 0; w < 3; w++)
        for (int si = 0; si < 3; si++) render_string_pair(&specs[which[w]], which[w], sizes[si]);
}

// ---------------------------------------------------------------- Q2: metrics

static void mode_metrics(void) {
    int sizes[] = { 14, 20, 24 };
    printf("== Q2: metrics (px). FT: size.metrics (hinted, whole pixels: what dimna reads) and unrounded from the face's design units; CT: CTFontGetAscent etc. (unrounded)\n");
    for (int fi = 0; fi < nspecs; fi++) {
        const Spec *sp = &specs[fi];
        for (int si = 0; si < 3; si++) {
            int px = sizes[si];
            FT_Face ft = ft_open(sp, px);
            int how;
            CTFontRef ct = ct_from_file_opsz(sp->path, FT_Get_Postscript_Name(ft), sp->index, px, sp->opsz, &how);
            double up = ft->units_per_EM;
            double ct_asc = CTFontGetAscent(ct), ct_desc = CTFontGetDescent(ct), ct_lead = CTFontGetLeading(ct);
            printf("%-18s %2d px | FT hinted: ascender %.0f descender %.0f height %.0f | FT unrounded: asc %.3f desc %.3f height %.3f (hhea asc %d desc %d lineGap %d, upem %.0f)\n",
                   sp->name, px, ft->size->metrics.ascender / 64.0, ft->size->metrics.descender / 64.0, ft->size->metrics.height / 64.0,
                   ft->ascender * px / up, -ft->descender * px / up, ft->height * px / up, ft->ascender, ft->descender, ft->height - (ft->ascender - ft->descender), up);
            printf("%-18s %2d px | CT: ascent %.3f descent %.3f leading %.3f -> line height (asc+desc+lead) %.3f; capHeight %.3f xHeight %.3f (CT upem %u)\n",
                   "", px, ct_asc, ct_desc, ct_lead, ct_asc + ct_desc + ct_lead, CTFontGetCapHeight(ct), CTFontGetXHeight(ct), CTFontGetUnitsPerEm(ct));
            // dimna's capRatio: the height of the glyph H (or alef where there is no Latin) with FT_LOAD_NO_SCALE, over upem.
            uint32_t cands[] = { 'H', 0x627 };
            for (int ci = 0; ci < 2; ci++) {
                unsigned g = FT_Get_Char_Index(ft, cands[ci]);
                if (!g) continue;
                FT_Load_Glyph(ft, g, FT_LOAD_NO_SCALE);
                double fth = ft->glyph->metrics.height / up * px;
                UniChar u = (UniChar)cands[ci];
                CGGlyph cg = 0;
                CTFontGetGlyphsForCharacters(ct, &u, &cg, 1);
                CGRect r;
                CTFontGetBoundingRectsForGlyphs(ct, kCTFontOrientationHorizontal, &cg, &r, 1);
                printf("%-18s %2d px | U+%04X ink height: FT (dimna's capRatio * px) %.3f | CT bounding rect height %.3f (y %.3f to %.3f)\n", "", px, cands[ci], fth, r.size.height, r.origin.y, r.origin.y + r.size.height);
                if (ci == 0) break;
            }
            // Alef where H came first.
            if (sp->kind == 2) {
                unsigned g = FT_Get_Char_Index(ft, 0x627);
                FT_Load_Glyph(ft, g, FT_LOAD_NO_SCALE);
                double fth = ft->glyph->metrics.height / up * px;
                UniChar u = 0x627;
                CGGlyph cg = 0;
                CTFontGetGlyphsForCharacters(ct, &u, &cg, 1);
                CGRect r;
                CTFontGetBoundingRectsForGlyphs(ct, kCTFontOrientationHorizontal, &cg, &r, 1);
                printf("%-18s %2d px | alef U+0627 ink height: FT %.3f | CT bounding rect %.3f (y %.3f to %.3f) | CT capHeight of the font %.3f\n", "", px, fth, r.size.height, r.origin.y, r.origin.y + r.size.height, CTFontGetCapHeight(ct));
            }
            CFRelease(ct);
            FT_Done_Face(ft);
        }
    }
}

// ---------------------------------------------------------------- Q3: which font

static void describe_font(const char *label, CTFontRef f) {
    if (!f) { printf("  %-34s -> NULL\n", label); return; }
    char ps[256], fam[256], file[1024], full[256];
    font_names(f, ps, sizeof ps, fam, sizeof fam);
    CFStringRef fn = CTFontCopyFullName(f);
    cfs_to_buf(fn, full, sizeof full);
    if (fn) CFRelease(fn);
    font_file(f, file, sizeof file);
    CFArrayRef axes = CTFontCopyVariationAxes(f);
    CFDictionaryRef var = CTFontCopyVariation(f);
    printf("  %-34s -> ps=%s family=%s full=%s size=%.1f\n", label, ps, fam, full, CTFontGetSize(f));
    printf("  %-34s    file=%s upem=%u variable=%s\n", "", file, CTFontGetUnitsPerEm(f), axes ? "yes" : "no");
    if (axes) {
        for (CFIndex i = 0; i < CFArrayGetCount(axes); i++) {
            CFDictionaryRef a = CFArrayGetValueAtIndex(axes, i);
            CFNumberRef id = CFDictionaryGetValue(a, kCTFontVariationAxisIdentifierKey), mn = CFDictionaryGetValue(a, kCTFontVariationAxisMinimumValueKey),
                        mx = CFDictionaryGetValue(a, kCTFontVariationAxisMaximumValueKey), df = CFDictionaryGetValue(a, kCTFontVariationAxisDefaultValueKey);
            CFStringRef nm = CFDictionaryGetValue(a, kCTFontVariationAxisNameKey);
            char nb[64]; cfs_to_buf(nm, nb, sizeof nb);
            long idv = 0; double mnv = 0, mxv = 0, dfv = 0, cur = NAN;
            CFNumberGetValue(id, kCFNumberLongType, &idv); CFNumberGetValue(mn, kCFNumberDoubleType, &mnv); CFNumberGetValue(mx, kCFNumberDoubleType, &mxv); CFNumberGetValue(df, kCFNumberDoubleType, &dfv);
            if (var) { CFNumberRef c = CFDictionaryGetValue(var, id); if (c) CFNumberGetValue(c, kCFNumberDoubleType, &cur); }
            char tag[5] = { (char)(idv >> 24), (char)(idv >> 16), (char)(idv >> 8), (char)idv, 0 };
            printf("  %-34s    axis '%s' (%s): min %.1f default %.1f max %.1f; this instance: %.2f\n", "", tag, nb, mnv, dfv, mxv, cur);
        }
        CFRelease(axes);
    }
    if (var) CFRelease(var);
}

static const char *ui_names[] = {
    "User", "UserFixedPitch", "System", "EmphasizedSystem", "SmallSystem", "SmallEmphasizedSystem", "MiniSystem", "MiniEmphasizedSystem",
    "Views", "Application", "Label", "MenuTitle", "MenuItem", "MenuItemMark", "MenuItemCmdKey", "WindowTitle", "PushButton",
    "UtilityWindowTitle", "AlertHeader", "SystemDetail", "EmphasizedSystemDetail", "Toolbar", "SmallToolbar", "Message", "Palette", "ToolTip", "ControlContent",
};

static int family_installed(const char *name) {
    CFArrayRef inst = CTFontManagerCopyAvailableFontFamilyNames();
    int found = 0;
    for (CFIndex k = 0; k < CFArrayGetCount(inst); k++) {
        char b[256]; cfs_to_buf(CFArrayGetValueAtIndex(inst, k), b, sizeof b);
        if (strcasecmp(b, name) == 0) { found = 1; break; }
    }
    CFRelease(inst);
    return found;
}

static void mode_fonts(void) {
    printf("== Q3: which font\n");
    printf("-- CTFontCreateUIFontForLanguage, 14 px, language NULL\n");
    for (int t = 0; t < (int)(sizeof ui_names / sizeof ui_names[0]); t++) {
        CTFontRef f = CTFontCreateUIFontForLanguage((CTFontUIFontType)t, 14, NULL);
        char label[64]; snprintf(label, sizeof label, "UI kind %d %s", t, ui_names[t]);
        if (f) {
            char ps[256], fam[256]; font_names(f, ps, sizeof ps, fam, sizeof fam);
            printf("  %-34s -> %-28s family %-22s asc %.2f desc %.2f\n", label, ps, fam, CTFontGetAscent(f), CTFontGetDescent(f));
            CFRelease(f);
        } else printf("  %-34s -> NULL\n", label);
    }
    printf("-- size 0 (the kind's own size) for System, UserFixedPitch, Label\n");
    int kinds[] = { kCTFontUIFontSystem, kCTFontUIFontUserFixedPitch, kCTFontUIFontLabel };
    for (int i = 0; i < 3; i++) {
        CTFontRef f = CTFontCreateUIFontForLanguage((CTFontUIFontType)kinds[i], 0, NULL);
        char label[64]; snprintf(label, sizeof label, "size 0, %s", ui_names[kinds[i]]);
        describe_font(label, f);
        if (f) CFRelease(f);
    }
    printf("-- the system UI font in detail at 14, 20, 24 px (does the optical size follow the size?)\n");
    int sz[] = { 14, 20, 24 };
    for (int i = 0; i < 3; i++) {
        CTFontRef f = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, sz[i], NULL);
        char label[64]; snprintf(label, sizeof label, "System at %d px", sz[i]);
        describe_font(label, f);
        UniChar u[3] = { 'H', 'n', 'i' }; CGGlyph g[3]; CGSize adv[3];
        CTFontGetGlyphsForCharacters(f, u, g, 3);
        CTFontGetAdvancesForGlyphs(f, kCTFontOrientationHorizontal, g, adv, 3);
        printf("  %-34s    advances (px): H %.4f n %.4f i %.4f; glyph ids H %u n %u i %u\n", "", adv[0].width, adv[1].width, adv[2].width, g[0], g[1], g[2]);
        CFRelease(f);
    }
    printf("-- the system UI font for languages\n");
    {
        const char *lang[] = { "fa", "zh-Hans", "ar", "en" };
        for (int i = 0; i < 4; i++) {
            CFStringRef l = cfs(lang[i]);
            CTFontRef g = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 14, l);
            char label[64]; snprintf(label, sizeof label, "System, language %s", lang[i]);
            if (g) { char ps[256], fam[256]; font_names(g, ps, sizeof ps, fam, sizeof fam); printf("  %-34s -> %s (%s)\n", label, ps, fam); CFRelease(g); }
            CFRelease(l);
        }
    }
    printf("-- the file SFNS.ttf (what dimna's sans-serif is today), a CTFont made from it at 14 px, and FreeType's view of it\n");
    {
        FT_Face ft = ft_open(&specs[0], 14);
        int how; CTFontRef f = ct_from_file(specs[0].path, FT_Get_Postscript_Name(ft), 0, 14, &how);
        describe_font("SFNS.ttf from file", f);
        printf("  FT's face: ps=%s, variation flag %s, upem %ld\n", FT_Get_Postscript_Name(ft), (ft->face_flags & FT_FACE_FLAG_MULTIPLE_MASTERS) ? "yes (multiple masters)" : "no", (long)ft->units_per_EM);
        CFRelease(f); FT_Done_Face(ft);
    }
    printf("-- families by name, only if listed by CTFontManagerCopyAvailableFontFamilyNames (CTFontCreateWithName, 14 px)\n");
    const char *fams[] = { "Helvetica Neue", "Menlo", "Geeza Pro", "Hiragino Sans GB", "Damascus", "Heiti SC", "PingFang SC", "SF Arabic", "Courier" };
    for (size_t i = 0; i < sizeof fams / sizeof fams[0]; i++) {
        if (!family_installed(fams[i])) { printf("  %-34s -> not among the installed family names: not asked for\n", fams[i]); continue; }
        CFStringRef n = cfs(fams[i]);
        CTFontRef f = CTFontCreateWithName(n, 14, NULL);
        describe_font(fams[i], f);
        if (f) CFRelease(f);
        CFRelease(n);
    }
    printf("-- the fixed-width system font\n");
    {
        CTFontRef f = CTFontCreateUIFontForLanguage(kCTFontUIFontUserFixedPitch, 14, NULL);
        describe_font("UserFixedPitch 14", f);
        UniChar u[2] = { 'i', 'W' }; CGGlyph g[2]; CGSize adv[2];
        CTFontGetGlyphsForCharacters(f, u, g, 2);
        CTFontGetAdvancesForGlyphs(f, kCTFontOrientationHorizontal, g, adv, 2);
        printf("  advances i %.4f W %.4f; monospace trait: %s\n", adv[0].width, adv[1].width, (CTFontGetSymbolicTraits(f) & kCTFontTraitMonoSpace) ? "yes" : "no");
        CFRelease(f);
    }
    printf("-- a name that is not installed, asked for without a download\n");
    {
        // How it was made sure that nothing is downloaded: (1) the name is gibberish, so it
        // is in no catalogue of downloadable fonts; (2) the list of installed families is
        // searched first and the name is absent; (3) the descriptor says
        // kCTFontDownloadableAttribute = false and the font is made with
        // kCTFontOptionsPreventAutoActivation | kCTFontOptionsPreventAutoDownload.
        const char *bogus = "Zqxj Nonexistent Probe Family 7731";
        int found = family_installed(bogus);
        printf("  '%s' among the installed families: %s\n", bogus, found ? "YES" : "no");
        if (!found) {
            CFStringRef n = cfs(bogus);
            const void *keys[] = { kCTFontFamilyNameAttribute, kCTFontDownloadableAttribute };
            const void *vals[] = { n, kCFBooleanFalse };
            CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CTFontDescriptorRef d = CTFontDescriptorCreateWithAttributes(attrs);
            CTFontRef f = CTFontCreateWithFontDescriptorAndOptions(d, 14, NULL, kCTFontOptionsPreventAutoActivation | kCTFontOptionsPreventAutoDownload);
            describe_font("CTFontCreateWithFontDescriptorAndOptions", f);
            if (f) CFRelease(f);
            CFRelease(d); CFRelease(attrs); CFRelease(n);
        }
    }
    printf("-- fallback: CTFontCreateForString(system UI font at 14 px, one character)\n");
    {
        CTFontRef base = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 14, NULL);
        struct { uint32_t cp; const char *what; } cs[] = {
            { 0x3c3, "sigma" }, { 0x2013, "en dash" }, { 0x2192, "right arrow" }, { 0x266a, "eighth note" }, { 0x25b8, "small right triangle" }, { 0x25be, "small down triangle" },
            { 0x901a, "Chinese tong" }, { 0x9053, "Chinese dao" }, { 0x644, "Persian/Arabic lam" }, { 0x6cc, "Persian yeh" }, { 'A', "A (no fallback needed)" }, { 0xb5, "micro" },
        };
        for (size_t i = 0; i < sizeof cs / sizeof cs[0]; i++) {
            CFStringRef s = cfs_u32(&cs[i].cp, 1);
            CTFontRef f = CTFontCreateForString(base, s, CFRangeMake(0, CFStringGetLength(s)));
            char label[64]; snprintf(label, sizeof label, "U+%04X %s", cs[i].cp, cs[i].what);
            char ps[256], fam[256], file[1024];
            font_names(f, ps, sizeof ps, fam, sizeof fam);
            font_file(f, file, sizeof file);
            int ftok = 0, ftgid = 0;
            if (file[0]) {
                FT_Face ff;
                if (FT_New_Face(ftlib, file, 0, &ff) == 0) { ftok = 1; ftgid = (int)FT_Get_Char_Index(ff, cs[i].cp); FT_Done_Face(ff); }
            }
            printf("  %-34s -> %-30s fam %-20s size %.2f file %s | FT opens face 0: %s, has the char: %s\n", label, ps, fam, CTFontGetSize(f), file[0] ? file : "(none)", ftok ? "yes" : "no", ftgid ? "yes" : "no");
            CFRelease(f); CFRelease(s);
        }
        CFRelease(base);
    }
}

// ---------------------------------------------------------------- Q4: a line laid out

static int is_rtl_letter(uint32_t c) {
    return (c >= 0x590 && c <= 0x8FF) || (c >= 0xFB1D && c <= 0xFDFF) || (c >= 0xFE70 && c <= 0xFEFF);
}
static int is_latin_or_digit(uint32_t c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || (c >= 0xC0 && c <= 0x24F && c != 0xD7 && c != 0xF7);
}

// shape.zig's rule, simplified: in a string with a right-to-left letter, each stretch from
// a Latin letter or digit to the last Latin letter or digit before the next right-to-left
// letter is put between U+2066 and U+2069.
static int isolate(const uint32_t *in, int n, uint32_t *out) {
    int has = 0;
    for (int i = 0; i < n; i++) if (is_rtl_letter(in[i])) has = 1;
    if (!has) { memcpy(out, in, (size_t)n * 4); return n; }
    int o = 0;
    for (int i = 0; i < n;) {
        if (is_latin_or_digit(in[i])) {
            int last = i;
            int j = i;
            while (j < n && !is_rtl_letter(in[j])) { if (is_latin_or_digit(in[j])) last = j; j++; }
            out[o++] = 0x2066;
            for (int k = i; k <= last; k++) out[o++] = in[k];
            out[o++] = 0x2069;
            i = last + 1;
        } else out[o++] = in[i++];
    }
    return o;
}

static CTParagraphStyleRef pstyle(int base) {
    CTWritingDirection d = base < 0 ? kCTWritingDirectionNatural : base == 0 ? kCTWritingDirectionLeftToRight : kCTWritingDirectionRightToLeft;
    CTParagraphStyleSetting s = { kCTParagraphStyleSpecifierBaseWritingDirection, sizeof d, &d };
    return CTParagraphStyleCreate(&s, 1);
}

static CFAttributedStringRef attr_string(CTFontRef font, CFStringRef str, int base) {
    CTParagraphStyleRef ps = pstyle(base);
    const void *keys[] = { kCTFontAttributeName, kCTParagraphStyleAttributeName };
    const void *vals[] = { font, ps };
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef as = CFAttributedStringCreate(NULL, str, attrs);
    CFRelease(attrs);
    CFRelease(ps);
    return as;
}

// A line, by a typesetter (base direction from the paragraph style, or a forced embedding
// level), or by CTLineCreateWithAttributedString.
static CTLineRef make_line(CTFontRef font, const uint32_t *cps, int n, int base, int forced_level, int via_typesetter) {
    CFStringRef s = cfs_u32(cps, n);
    CFAttributedStringRef as = attr_string(font, s, base);
    CTLineRef line;
    if (!via_typesetter) {
        line = CTLineCreateWithAttributedString(as);
    } else {
        CTTypesetterRef ts;
        if (forced_level >= 0) {
            CFNumberRef lv = CFNumberCreate(NULL, kCFNumberIntType, &forced_level);
            const void *k[] = { kCTTypesetterOptionForcedEmbeddingLevel };
            const void *v[] = { lv };
            CFDictionaryRef o = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            ts = CTTypesetterCreateWithAttributedStringAndOptions(as, o);
            CFRelease(o);
            CFRelease(lv);
        } else ts = CTTypesetterCreateWithAttributedString(as);
        line = CTTypesetterCreateLine(ts, CFRangeMake(0, 0));
        CFRelease(ts);
    }
    CFRelease(as);
    CFRelease(s);
    return line;
}

// UTF-16 index to the code point at it (the strings used here are all in the BMP).
static void dump_line(CTLineRef line, const uint32_t *cps, int n, int detail) {
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    CFIndex nr = CFArrayGetCount(runs);
    double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    printf("    %ld run(s), typographic width %.3f px\n", (long)nr, width);
    int vis_idx[512];
    int nv = 0;
    for (CFIndex r = 0; r < nr; r++) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, r);
        CFIndex ng = CTRunGetGlyphCount(run);
        CTRunStatus st = CTRunGetStatus(run);
        CFRange rg = CTRunGetStringRange(run);
        CTFontRef rf = CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
        char ps[128], fam[128];
        font_names(rf, ps, sizeof ps, fam, sizeof fam);
        CGGlyph *gl = malloc(sizeof(CGGlyph) * (size_t)(ng + 1));
        CGPoint *pos = malloc(sizeof(CGPoint) * (size_t)(ng + 1));
        CGSize *adv = malloc(sizeof(CGSize) * (size_t)(ng + 1));
        CFIndex *idx = malloc(sizeof(CFIndex) * (size_t)(ng + 1));
        CTRunGetGlyphs(run, CFRangeMake(0, 0), gl);
        CTRunGetPositions(run, CFRangeMake(0, 0), pos);
        CTRunGetAdvances(run, CFRangeMake(0, 0), adv);
        CTRunGetStringIndices(run, CFRangeMake(0, 0), idx);
        printf("    run %ld: %s%s chars [%ld,%ld) font %s (%s) size %.2f, %ld glyphs, run width %.3f\n", (long)r, (st & kCTRunStatusRightToLeft) ? "RTL" : "LTR",
               (st & kCTRunStatusNonMonotonic) ? " non-monotonic" : "", (long)rg.location, (long)(rg.location + rg.length), ps, fam, CTFontGetSize(rf), (long)ng,
               CTRunGetTypographicBounds(run, CFRangeMake(0, 0), NULL, NULL, NULL));
        if (detail) {
            printf("      glyphs (gid@x+advance[char index]):");
            for (CFIndex g = 0; g < ng; g++) printf(" %u@%.2f+%.2f[%ld]", gl[g], pos[g].x, adv[g].width, (long)idx[g]);
            printf("\n");
        }
        for (CFIndex g = 0; g < ng && nv < 512; g++) vis_idx[nv++] = (int)idx[g];
        free(gl); free(pos); free(adv); free(idx);
    }
    printf("    left to right, one entry per glyph (the character it stands for): ");
    for (int i = 0; i < nv; i++) {
        print_cp(vis_idx[i] < n ? cps[vis_idx[i]] : '?');
        if (i + 1 < nv) fputs(" ", stdout);
    }
    printf("\n");
}

struct Case { const char *label; const char *text; };

static void mode_lines(void) {
    printf("== Q4: lines through CTTypesetter/CTLine, the system UI font at 14 px (no cascade list: Core Text's own fallback)\n");
    CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 14, NULL);
    struct Case cases[] = {
        { "Latin", "Port A" },
        { "Persian word (seen lam alef meem)", "سلام" },
        { "Persian with a range", "فیلتر 300-6000 Hz" },
        { "Chinese label", "通道 3 阈值 5" },
        { "Latin name then Persian", "Port A فیلتر" },
    };
    int bases[] = { -1, 0, 1 };
    const char *bname[] = { "natural", "forced LTR", "forced RTL" };
    for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++) {
        uint32_t cps[128], iso[256];
        int n = u8dec(cases[c].text, cps, 128);
        int ni = isolate(cps, n, iso);
        printf("-- %s: ", cases[c].label); print_cps(cps, n); printf("  (%d code points)\n", n);
        for (int with = 0; with < 2; with++) {
            if (with && ni == n) continue;
            for (int b = 0; b < 3; b++) {
                const uint32_t *s = with ? iso : cps;
                int sn = with ? ni : n;
                printf("  base %s, %s\n", bname[b], with ? "with U+2066/U+2069 around the Latin/digit stretches" : "plain");
                CTLineRef a = make_line(font, s, sn, bases[b], -1, 1);
                dump_line(a, s, sn, verbose || c == 2 || c == 1);
                if (!with && b == 0) {
                    CTLineRef l2 = make_line(font, s, sn, bases[b], -1, 0);
                    CFArrayRef r1 = CTLineGetGlyphRuns(a), r2 = CTLineGetGlyphRuns(l2);
                    int same = CFArrayGetCount(r1) == CFArrayGetCount(r2);
                    for (CFIndex i = 0; same && i < CFArrayGetCount(r1); i++) {
                        CTRunRef x = (CTRunRef)CFArrayGetValueAtIndex(r1, i), y = (CTRunRef)CFArrayGetValueAtIndex(r2, i);
                        CFIndex ng = CTRunGetGlyphCount(x);
                        if (ng != CTRunGetGlyphCount(y) || ng > 256) { same = 0; break; }
                        CGGlyph gx[256], gy[256]; CGPoint px[256], py[256];
                        CTRunGetGlyphs(x, CFRangeMake(0, 0), gx); CTRunGetGlyphs(y, CFRangeMake(0, 0), gy);
                        CTRunGetPositions(x, CFRangeMake(0, 0), px); CTRunGetPositions(y, CFRangeMake(0, 0), py);
                        for (CFIndex g = 0; g < ng; g++) if (gx[g] != gy[g] || px[g].x != py[g].x) same = 0;
                    }
                    printf("    CTLineCreateWithAttributedString (natural) gives the same glyphs and positions as the typesetter's line: %s\n", same ? "yes" : "NO");
                    CFRelease(l2);
                }
                CFRelease(a);
            }
        }
    }
    // Can the fallback order be chosen (dimna names Geeza Pro and Hiragino Sans GB)? A cascade list.
    printf("-- a cascade list (kCTFontCascadeListAttribute: Geeza Pro, Hiragino Sans GB; both installed) on the system UI font\n");
    if (family_installed("Geeza Pro") && family_installed("Hiragino Sans GB")) {
        CTFontDescriptorRef d1 = CTFontDescriptorCreateWithNameAndSize(CFSTR("GeezaPro"), 0);
        CTFontDescriptorRef d2 = CTFontDescriptorCreateWithNameAndSize(CFSTR("HiraginoSansGB-W3"), 0);
        const void *ds[] = { d1, d2 };
        CFArrayRef list = CFArrayCreate(NULL, ds, 2, &kCFTypeArrayCallBacks);
        const void *k[] = { kCTFontCascadeListAttribute };
        const void *v[] = { list };
        CFDictionaryRef at = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CTFontDescriptorRef base = CTFontCopyFontDescriptor(font);
        CTFontDescriptorRef nd = CTFontDescriptorCreateCopyWithAttributes(base, at);
        CTFontRef cf = CTFontCreateWithFontDescriptor(nd, 14, NULL);
        const char *ts[] = { "فیلتر 300-6000 Hz", "通道 3 阈值 5" };
        for (int t = 0; t < 2; t++) {
            uint32_t cps[64], iso[128];
            int n = u8dec(ts[t], cps, 64);
            int ni = isolate(cps, n, iso);
            CTLineRef l = make_line(cf, iso, ni, t == 0 ? 1 : -1, -1, 1);
            printf("  "); print_cps(iso, ni); printf("\n");
            dump_line(l, iso, ni, 0);
            CFRelease(l);
        }
        CFRelease(cf); CFRelease(nd); CFRelease(base); CFRelease(at); CFRelease(list); CFRelease(d1); CFRelease(d2);
    } else printf("  (Geeza Pro or Hiragino Sans GB not installed: not run)\n");
    CFRelease(font);
}

// ---------------------------------------------------------------- Q5: bidi apart from shaping

static void mode_bidi(void) {
    printf("== Q5: bidi apart from shaping?\n");
    CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 14, NULL);
    printf("-- (a) kCTTypesetterOptionForcedEmbeddingLevel (the header: any directional control characters are then ignored)\n");
    const char *strs[] = { "فیلتر 300-6000 Hz", "300-6000 Hz", "سلام", "Port A فیلتر" };
    for (int s = 0; s < 4; s++) {
        uint32_t cps[128];
        int n = u8dec(strs[s], cps, 128);
        for (int lv = 0; lv <= 2; lv++) {
            printf("  string "); print_cps(cps, n); printf(", forced level %d\n", lv);
            CTLineRef l = make_line(font, cps, n, -1, lv, 1);
            dump_line(l, cps, n, 0);
            CFRelease(l);
        }
    }
    printf("-- (b) what a line says about direction: one RTL bit per run, no level. A paragraph with isolates, natural direction (LTR first letter):\n");
    {
        uint32_t cps[128], iso[256];
        int n = u8dec("A فیلتر 300-6000 Hz سلام B", cps, 128);
        int ni = isolate(cps, n, iso);
        CTLineRef l = make_line(font, iso, ni, -1, -1, 1);
        dump_line(l, iso, ni, 0);
        CFRelease(l);
    }
    printf("-- (c) ICU in the system: this SDK's usr/include/unicode has uchar.h (bidi class of a code point) but no ubidi.h\n");
    {
        void *h = dlopen("/usr/lib/libicucore.dylib", RTLD_LAZY);
        printf("  dlopen libicucore: %s\n", h ? "ok" : "failed");
        const char *syms[] = { "u_charDirection", "u_getIntPropertyValue", "ubidi_open", "ubidi_setPara", "ubidi_getLevels", "ubidi_getVisualMap", "ubidi_writeReordered" };
        for (size_t i = 0; i < sizeof syms / sizeof syms[0]; i++) printf("  dlsym %-22s %s\n", syms[i], dlsym(h ? h : RTLD_DEFAULT, syms[i]) ? "found" : "not found");
        typedef int (*dirf)(int32_t);
        dirf u_charDirection = (dirf)dlsym(h ? h : RTLD_DEFAULT, "u_charDirection");
        if (u_charDirection) {
            uint32_t t[] = { 'A', '3', '-', ' ', 0x644, 0x6cc, 0x6f3, 0x2066, 0x2069, 0x4e2d };
            printf("  u_charDirection (ICU UCharDirection: 0 L, 1 R, 2 EN, 3 ES, 4 ET, 5 AN, 6 CS, 7 B, 8 S, 9 WS, 10 ON, 13 AL, 19 LRI, 22 PDI):");
            for (size_t i = 0; i < sizeof t / 4; i++) printf(" U+%04X=%d", t[i], u_charDirection((int32_t)t[i]));
            printf("\n");
        }
        // The levels, by hand-declared prototypes (no header for them in the SDK).
        typedef void *(*ubidi_open_f)(void);
        typedef void (*ubidi_setPara_f)(void *, const uint16_t *, int32_t, uint8_t, uint8_t *, int *);
        typedef const uint8_t *(*ubidi_getLevels_f)(void *, int *);
        typedef int (*ubidi_getBase_f)(const uint16_t *, int32_t);
        typedef void (*ubidi_close_f)(void *);
        ubidi_open_f uopen = (ubidi_open_f)dlsym(h, "ubidi_open");
        ubidi_setPara_f uset = (ubidi_setPara_f)dlsym(h, "ubidi_setPara");
        ubidi_getLevels_f ulev = (ubidi_getLevels_f)dlsym(h, "ubidi_getLevels");
        ubidi_getBase_f ubase = (ubidi_getBase_f)dlsym(h, "ubidi_getBaseDirection");
        ubidi_close_f uclose = (ubidi_close_f)dlsym(h, "ubidi_close");
        printf("  dlsym ubidi_getBaseDirection %s, ubidi_close %s\n", ubase ? "found" : "not found", uclose ? "found" : "not found");
        if (uopen && uset && ulev) {
            const char *tests[] = { "فیلتر 300-6000 Hz", "Port A فیلتر", "300-6000 Hz فیلتر" };
            for (int t = 0; t < 3; t++) {
                uint32_t cps[64];
                int n = u8dec(tests[t], cps, 64);
                CFStringRef s = cfs_u32(cps, n);
                uint16_t u16[128];
                CFIndex len = CFStringGetLength(s);
                CFStringGetCharacters(s, CFRangeMake(0, len), u16);
                for (int pl = 0; pl < 2; pl++) {
                    void *b = uopen();
                    int err = 0;
                    uset(b, u16, (int32_t)len, (uint8_t)pl, NULL, &err);
                    const uint8_t *lv = ulev(b, &err);
                    printf("  ubidi_setPara paragraph level %d, \"%s\": err %d, levels", pl, tests[t], err);
                    for (CFIndex i = 0; lv && i < len; i++) printf(" %d", lv[i]);
                    printf("\n");
                    uclose(b);
                }
                if (ubase) printf("  ubidi_getBaseDirection (rule P2; 0 LTR, 1 RTL, 3 neutral): %d\n", ubase(u16, (int32_t)len));
                CFRelease(s);
            }
        }
    }
    CFRelease(font);
}

// ---------------------------------------------------------------- Q6: cost

static const char *latin40 = "A%d   %d.%02d s   %dµV/row   300-6000 Hz";
static const char *persian_fmt = "فیلتر %d-6000 Hz کانال %d";

typedef struct { int glyphs; uint64_t hash; } LayoutSummary;

// Lays a string out with Core Text and reads every glyph, position and advance out, as a
// backend would to fill dimna's `Placed` list.
static LayoutSummary ct_layout(CTFontRef font, const uint32_t *cps, int n, int base) {
    CTLineRef line = make_line(font, cps, n, base, -1, 0);
    LayoutSummary r = { 0, 1469598103934665603ULL };
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex i = 0; i < CFArrayGetCount(runs); i++) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, i);
        CFIndex ng = CTRunGetGlyphCount(run);
        CGGlyph gl[256]; CGPoint pos[256]; CGSize adv[256];
        if (ng > 256) ng = 256;
        CTRunGetGlyphs(run, CFRangeMake(0, ng), gl);
        CTRunGetPositions(run, CFRangeMake(0, ng), pos);
        CTRunGetAdvances(run, CFRangeMake(0, ng), adv);
        for (CFIndex g = 0; g < ng; g++) {
            r.hash = (r.hash ^ gl[g]) * 1099511628211ULL;
            r.hash = (r.hash ^ (uint64_t)llround(pos[g].x * 64)) * 1099511628211ULL;
            r.hash = (r.hash ^ (uint64_t)llround(adv[g].width * 64)) * 1099511628211ULL;
            r.glyphs++;
        }
    }
    CFRelease(line);
    return r;
}

static uint64_t ct_raster_hash(CTFontRef font, const uint32_t *cps, int n, uint8_t *buf, int w, int h) {
    uint64_t hash = 1469598103934665603ULL;
    for (int i = 0; i < n; i++) {
        UniChar u = (UniChar)cps[i];
        CGGlyph g;
        CTFontGetGlyphsForCharacters(font, &u, &g, 1);
        memset(buf, 0, (size_t)w * (size_t)h);
        CGContextRef cx = CGBitmapContextCreate(buf, (size_t)w, (size_t)h, 8, (size_t)w, NULL, kCGImageAlphaOnly);
        CGContextSetShouldSmoothFonts(cx, false);
        CGContextSetAllowsFontSmoothing(cx, false);
        CGPoint p = { 4, 4 };
        CTFontDrawGlyphs(font, &g, &p, 1, cx);
        CGContextRelease(cx);
        for (int k = 0; k < w * h; k++) hash = (hash ^ buf[k]) * 1099511628211ULL;
    }
    return hash;
}

static void mode_cost(void) {
    const int N = 3000;
    double *v = malloc(sizeof(double) * (size_t)N);
    printf("== Q6: cost (%d repetitions each; microseconds per operation)\n", N);
    printf("-- a face made\n");
    {
        double t0 = now_us();
        CTFontRef f = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 14, NULL);
        printf("  first CTFontCreateUIFontForLanguage in this process: %.1f us\n", now_us() - t0);
        CFRelease(f);
        for (int i = 0; i < N; i++) {
            double t = now_us();
            f = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 14 + (i % 3), NULL);
            v[i] = now_us() - t;
            CFRelease(f);
        }
        print_stats("CT: UI system font at 14/15/16 px (released each time)", stats_of(v, N));
        CFStringRef nm = cfs("Geeza Pro");
        for (int i = 0; i < N; i++) {
            double t = now_us();
            f = CTFontCreateWithName(nm, 14 + (i % 3) * 0.5, NULL);
            v[i] = now_us() - t;
            CFRelease(f);
        }
        print_stats("CT: CTFontCreateWithName(\"Geeza Pro\") (installed)", stats_of(v, N));
        CFRelease(nm);
        int how;
        FT_Face ff;
        FT_New_Face(ftlib, specs[0].path, 0, &ff);
        const char *ps = FT_Get_Postscript_Name(ff);
        t0 = now_us();
        f = ct_from_file(specs[0].path, ps, 0, 14, &how);
        printf("  first CTFont from the file SFNS.ttf (URL -> descriptors -> font): %.1f us\n", now_us() - t0);
        CFRelease(f);
        for (int i = 0; i < 300; i++) {
            double t = now_us();
            f = ct_from_file(specs[0].path, ps, 0, 14, &how);
            v[i] = now_us() - t;
            CFRelease(f);
        }
        print_stats("CT: CTFont from a file path, n=300", stats_of(v, 300));
        FT_Done_Face(ff);
        double t = now_us();
        FT_New_Face(ftlib, specs[0].path, 0, &ff); FT_Set_Pixel_Sizes(ff, 0, 14);
        printf("  first FT_New_Face + FT_Set_Pixel_Sizes (SFNS.ttf): %.1f us\n", now_us() - t);
        FT_Done_Face(ff);
        for (int i = 0; i < N; i++) {
            t = now_us();
            FT_New_Face(ftlib, specs[0].path, 0, &ff); FT_Set_Pixel_Sizes(ff, 0, 14);
            v[i] = now_us() - t;
            FT_Done_Face(ff);
        }
        print_stats("FT: FT_New_Face + FT_Set_Pixel_Sizes, SFNS.ttf", stats_of(v, N));
        for (int i = 0; i < N; i++) {
            t = now_us();
            FT_New_Face(ftlib, specs[4].path, 0, &ff); FT_Set_Pixel_Sizes(ff, 0, 14);
            v[i] = now_us() - t;
            FT_Done_Face(ff);
        }
        print_stats("FT: FT_New_Face + FT_Set_Pixel_Sizes, GeezaPro.ttc", stats_of(v, N));
    }
    CTFontRef sys = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 14, NULL);
    printf("-- a Latin line of about 40 characters (every string different)\n");
    {
        char buf[160];
        uint32_t cps[160];
        int n = 0;
        for (int i = 0; i < N; i++) {
            snprintf(buf, sizeof buf, latin40, i % 8, i % 20, i % 100, 50 * (i % 16) + i / 100);
            n = u8dec(buf, cps, 160);
            double t = now_us();
            CTLineRef line = make_line(sys, cps, n, -1, -1, 0);
            v[i] = now_us() - t;
            CFRelease(line);
        }
        printf("  (the last string has %d code points)\n", n);
        print_stats("CT: string + attributed string + CTLine only", stats_of(v, N));
        for (int i = 0; i < N; i++) {
            snprintf(buf, sizeof buf, latin40, i % 8, i % 20, i % 100, 50 * (i % 16) + i / 100);
            n = u8dec(buf, cps, 160);
            double t = now_us();
            LayoutSummary r = ct_layout(sys, cps, n, -1);
            v[i] = now_us() - t;
            if (r.glyphs == 0) printf("no glyphs?\n");
        }
        print_stats("CT: the line, then every glyph, position, advance read out", stats_of(v, N));
        for (int i = 0; i < N; i++) {
            double t = now_us();
            ct_layout(sys, cps, n, -1);
            v[i] = now_us() - t;
        }
        print_stats("CT: the same string every time, full path", stats_of(v, N));
        FT_Face ft = ft_open(&specs[0], 14);
        hb_font_t *hf = hb_ft_font_create_referenced(ft);
        hb_ft_font_set_load_flags(hf, FT_LOAD_DEFAULT);
        hb_buffer_t *hb = hb_buffer_create();
        for (int i = 0; i < N; i++) {
            snprintf(buf, sizeof buf, latin40, i % 8, i % 20, i % 100, 50 * (i % 16) + i / 100);
            n = u8dec(buf, cps, 160);
            double t = now_us();
            hb_buffer_clear_contents(hb);
            hb_buffer_add_codepoints(hb, cps, n, 0, n);
            hb_buffer_set_direction(hb, HB_DIRECTION_LTR);
            hb_buffer_guess_segment_properties(hb);
            hb_shape(hf, hb, NULL, 0);
            unsigned cnt;
            hb_glyph_info_t *info = hb_buffer_get_glyph_infos(hb, &cnt);
            hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(hb, &cnt);
            v[i] = now_us() - t;
            if (!info || !pos) printf("?\n");
        }
        print_stats("for scale: HarfBuzz (hb-ft, 14 px) shaping the same kind of line", stats_of(v, N));
        hb_buffer_destroy(hb); hb_font_destroy(hf); FT_Done_Face(ft);
    }
    printf("-- a Persian line of about 30 characters\n");
    {
        char buf[160];
        uint32_t cps[160], iso[320];
        for (int i = 0; i < N; i++) {
            snprintf(buf, sizeof buf, persian_fmt, 100 + i % 900, i);
            int n = u8dec(buf, cps, 160);
            int ni = isolate(cps, n, iso);
            double t = now_us();
            LayoutSummary r = ct_layout(sys, iso, ni, 1);
            v[i] = now_us() - t;
            if (r.glyphs == 0) printf("no glyphs?\n");
        }
        print_stats("CT: isolates added, base RTL, line + glyphs read out", stats_of(v, N));
        for (int i = 0; i < N; i++) {
            snprintf(buf, sizeof buf, persian_fmt, 100 + i % 900, i);
            int n = u8dec(buf, cps, 160);
            double t = now_us();
            LayoutSummary r = ct_layout(sys, cps, n, 1);
            v[i] = now_us() - t;
            if (r.glyphs == 0) printf("no glyphs?\n");
        }
        print_stats("CT: no isolates, base RTL", stats_of(v, N));
        FT_Face ft = ft_open(&specs[4], 14);
        hb_font_t *hf = hb_ft_font_create_referenced(ft);
        hb_ft_font_set_load_flags(hf, FT_LOAD_DEFAULT);
        hb_buffer_t *hb = hb_buffer_create();
        for (int i = 0; i < N; i++) {
            snprintf(buf, sizeof buf, persian_fmt, 100 + i % 900, i);
            int n = u8dec(buf, cps, 160);
            double t = now_us();
            FriBidiCharType types[160]; FriBidiBracketType bt[160]; FriBidiLevel lev[160];
            FriBidiParType base = FRIBIDI_PAR_RTL;
            fribidi_get_bidi_types(cps, n, types);
            fribidi_get_bracket_types(cps, n, types, bt);
            fribidi_get_par_embedding_levels_ex(types, bt, n, &base, lev);
            hb_buffer_clear_contents(hb);
            hb_buffer_add_codepoints(hb, cps, n, 0, n);
            hb_buffer_set_direction(hb, HB_DIRECTION_RTL);
            hb_buffer_guess_segment_properties(hb);
            hb_shape(hf, hb, NULL, 0);
            unsigned cnt;
            hb_glyph_info_t *info = hb_buffer_get_glyph_infos(hb, &cnt);
            hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(hb, &cnt);
            v[i] = now_us() - t;
            if (!info || !pos) printf("?\n");
        }
        print_stats("for scale: FriBidi levels + HarfBuzz, one Geeza Pro run (no isolation)", stats_of(v, N));
        hb_buffer_destroy(hb); hb_font_destroy(hf); FT_Done_Face(ft);
    }
    printf("-- a Chinese line of about 30 characters (the benchmark's kind, with the fallback font)\n");
    {
        char buf[160];
        uint32_t cps[160];
        for (int i = 0; i < N; i++) {
            snprintf(buf, sizeof buf, "通道 %d 阈值 %d 微伏 滤波器 300-6000 Hz", i, i * 3);
            int n = u8dec(buf, cps, 160);
            double t = now_us();
            LayoutSummary r = ct_layout(sys, cps, n, -1);
            v[i] = now_us() - t;
            if (r.glyphs == 0) printf("no glyphs?\n");
        }
        print_stats("CT: Chinese + digits + Latin, natural direction", stats_of(v, N));
    }
    printf("-- one glyph rasterised at 14 px\n");
    {
        uint8_t buf[24 * 24];
        UniChar u = 'g'; CGGlyph g;
        CTFontGetGlyphsForCharacters(sys, &u, &g, 1);
        for (int i = 0; i < N; i++) {
            double t = now_us();
            memset(buf, 0, sizeof buf);
            CGContextRef cx = CGBitmapContextCreate(buf, 24, 24, 8, 24, NULL, kCGImageAlphaOnly);
            CGContextSetShouldSmoothFonts(cx, false);
            CGContextSetAllowsFontSmoothing(cx, false);
            CGPoint p = { 4, 6 };
            CTFontDrawGlyphs(sys, &g, &p, 1, cx);
            CGContextRelease(cx);
            v[i] = now_us() - t;
        }
        print_stats("CT: context made + CTFontDrawGlyphs + context freed (24x24)", stats_of(v, N));
        CGContextRef cx = CGBitmapContextCreate(buf, 24, 24, 8, 24, NULL, kCGImageAlphaOnly);
        CGContextSetShouldSmoothFonts(cx, false);
        CGContextSetAllowsFontSmoothing(cx, false);
        for (int i = 0; i < N; i++) {
            double t = now_us();
            memset(buf, 0, sizeof buf);
            CGPoint p = { 4, 6 };
            CTFontDrawGlyphs(sys, &g, &p, 1, cx);
            v[i] = now_us() - t;
        }
        print_stats("CT: context reused, clear + CTFontDrawGlyphs (the same glyph)", stats_of(v, N));
        CTFontRef zh = CTFontCreateForString(sys, CFSTR("道"), CFRangeMake(0, 1));
        int m = 0;
        for (int i = 0; i < 2000; i++) {
            UniChar uc = (UniChar)(0x4e00 + i);
            CGGlyph gg;
            if (!CTFontGetGlyphsForCharacters(zh, &uc, &gg, 1)) continue;
            double t = now_us();
            memset(buf, 0, sizeof buf);
            CGPoint p = { 2, 4 };
            CTFontDrawGlyphs(zh, &gg, &p, 1, cx);
            v[m++] = now_us() - t;
        }
        print_stats("CT: 2000 different CJK ideographs, fallback font, context reused", stats_of(v, m));
        CFRelease(zh);
        // 2000 different glyph ids of the system font (each drawn for the first time).
        m = 0;
        long inked = 0;
        for (int i = 0; i < 2000; i++) {
            CGGlyph gg = (CGGlyph)(100 + i);
            double t = now_us();
            memset(buf, 0, sizeof buf);
            CGPoint p = { 2, 4 };
            CTFontDrawGlyphs(sys, &gg, &p, 1, cx);
            v[m++] = now_us() - t;
            for (unsigned k = 0; k < sizeof buf; k++) inked += buf[k] != 0;
        }
        print_stats("CT: 2000 different glyph ids of the system font, context reused", stats_of(v, m));
        printf("  (%ld inked pixels over those 2000 glyphs, so they were drawn)\n", inked);
        CGContextRelease(cx);
        FT_Face ft = ft_open(&specs[0], 14);
        unsigned fg = FT_Get_Char_Index(ft, 'g');
        for (int i = 0; i < N; i++) {
            double t = now_us();
            FT_Load_Glyph(ft, fg, FT_LOAD_RENDER);
            v[i] = now_us() - t;
        }
        print_stats("FT: FT_Load_Glyph(FT_LOAD_RENDER), SFNS.ttf, the same glyph", stats_of(v, N));
        m = 0;
        for (int i = 0; i < 2000; i++) {
            double t = now_us();
            FT_Load_Glyph(ft, (FT_UInt)(100 + i), FT_LOAD_RENDER);
            v[m++] = now_us() - t;
        }
        print_stats("FT: 2000 different glyph ids of SFNS.ttf, FT_LOAD_RENDER", stats_of(v, m));
        FT_Face fz = ft_open(&specs[3], 14);
        m = 0;
        for (int i = 0; i < 2000; i++) {
            unsigned gi = FT_Get_Char_Index(fz, 0x4e00 + (uint32_t)i);
            if (!gi) continue;
            double t = now_us();
            FT_Load_Glyph(fz, gi, FT_LOAD_RENDER);
            v[m++] = now_us() - t;
        }
        print_stats("FT: 2000 different CJK ideographs, Hiragino Sans GB", stats_of(v, m));
        FT_Done_Face(fz);
        FT_Done_Face(ft);
    }
    CFRelease(sys);
    free(v);
}

// ---------------------------------------------------------------- Q7: threads

typedef struct {
    double seconds;
    CTFontRef shared;
    uint64_t ref_hash;
    uint64_t iters, mismatches;
} Work;

static uint64_t one_iteration(CTFontRef font, uint8_t *bitmap, int bw, int bh) {
    uint64_t h = 1469598103934665603ULL;
    const char *lines[] = { "A3   12.05 s   150µV/row   300-6000 Hz", "فیلتر 300-6000 Hz کانال 12", "通道 3 阈值 5 滤波器" };
    for (int l = 0; l < 3; l++) {
        uint32_t cps[160], iso[320];
        int n = u8dec(lines[l], cps, 160);
        int ni = isolate(cps, n, iso);
        LayoutSummary r = ct_layout(font, iso, ni, l == 1 ? 1 : -1);
        h = (h ^ r.hash) * 1099511628211ULL;
    }
    uint32_t g8[] = { 'P', 'o', 'r', 't', 'g', 0x901a, 0x644, 'H' };
    h = (h ^ ct_raster_hash(font, g8, 8, bitmap, bw, bh)) * 1099511628211ULL;
    return h;
}

static void *worker(void *arg) {
    Work *w = arg;
    CTFontRef font = w->shared ? w->shared : CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 14, NULL);
    uint8_t bitmap[24 * 24];
    double end = now_us() + w->seconds * 1e6;
    while (now_us() < end) {
        uint64_t h = one_iteration(font, bitmap, 24, 24);
        if (h != w->ref_hash) w->mismatches++;
        w->iters++;
    }
    if (!w->shared) CFRelease(font);
    return NULL;
}

static void run_threads(int nthreads, double secs, int share, uint64_t ref, const char *label) {
    pthread_t th[8];
    Work w[8];
    CTFontRef shared = share ? CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 14, NULL) : NULL;
    double t0 = now_us();
    for (int i = 0; i < nthreads; i++) {
        memset(&w[i], 0, sizeof w[i]);
        w[i].seconds = secs; w[i].shared = shared; w[i].ref_hash = ref;
        pthread_create(&th[i], NULL, worker, &w[i]);
    }
    uint64_t tot = 0, bad = 0;
    for (int i = 0; i < nthreads; i++) { pthread_join(th[i], NULL); tot += w[i].iters; bad += w[i].mismatches; }
    double el = (now_us() - t0) / 1e6;
    printf("  %-46s %d thread(s), %.1f s: %llu iterations (", label, nthreads, el, (unsigned long long)tot);
    for (int i = 0; i < nthreads; i++) printf("%s%llu", i ? ", " : "", (unsigned long long)w[i].iters);
    printf("); %.0f/s total, %.0f/s per thread; results differing from the single-thread reference: %llu\n", (double)tot / el, (double)tot / el / nthreads, (unsigned long long)bad);
    if (shared) CFRelease(shared);
}

static void mode_threads(void) {
    printf("== Q7: threads. One iteration = three lines laid out (Latin, Persian with isolates, Chinese; glyphs, positions, advances hashed) + 8 glyphs rasterised, each into a context made for it, hashed.\n");
    CTFontRef f = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 14, NULL);
    uint8_t bitmap[24 * 24];
    uint64_t ref = one_iteration(f, bitmap, 24, 24);
    uint64_t ref2 = one_iteration(f, bitmap, 24, 24);
    printf("  reference hash %016llx (second call %016llx: %s)\n", (unsigned long long)ref, (unsigned long long)ref2, ref == ref2 ? "same" : "DIFFERENT");
    CFRelease(f);
    run_threads(1, 3, 0, ref, "baseline, own CTFont");
    run_threads(3, seconds, 0, ref, "each thread makes its own CTFont (as dimna)");
    run_threads(3, 5, 1, ref, "three threads share one CTFont (not dimna)");
}

// ---------------------------------------------------------------- main

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: coretext_probe glyph|metrics|fonts|lines|bidi|cost|threads [-v] [--out DIR] [--seconds N]\n"); return 2; }
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "-v")) verbose = 1;
        else if (!strcmp(argv[i], "--out") && i + 1 < argc) outdir = argv[++i];
        else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) seconds = atoi(argv[++i]);
    }
    if (FT_Init_FreeType(&ftlib)) return 1;
    FT_Int ma, mi, pa;
    FT_Library_Version(ftlib, &ma, &mi, &pa);
    printf("FreeType %d.%d.%d (vendor/freetype, static); HarfBuzz %s; FriBidi %s\n", ma, mi, pa, hb_version_string(), FRIBIDI_VERSION);
    const char *m = argv[1];
    if (!strcmp(m, "glyph")) mode_glyph();
    else if (!strcmp(m, "metrics")) mode_metrics();
    else if (!strcmp(m, "fonts")) mode_fonts();
    else if (!strcmp(m, "lines")) mode_lines();
    else if (!strcmp(m, "bidi")) mode_bidi();
    else if (!strcmp(m, "cost")) mode_cost();
    else if (!strcmp(m, "threads")) mode_threads();
    else { fprintf(stderr, "unknown mode %s\n", m); return 2; }
    return 0;
}
