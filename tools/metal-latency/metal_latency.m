// metal_latency: how long does a frame take to reach the screen on this Mac?
//
// A throwaway measurement for the macOS port question (not part of dimna). It opens one
// window with a Metal layer, draws a bar that sweeps across it, and for every frame records
// the time from "the newest data was taken" (stamped right after the drawable was obtained,
// just before drawing) to the time the system reports the frame was presented
// (MTLDrawable.presentedTime). One run = one mode; it prints one result line and exits.
//
//   --fullscreen        borderless window covering the main screen, above the menu bar
//                       (what lets macOS skip the compositor: "direct to display")
//   --sync on|off       CAMetalLayer.displaySyncEnabled (default on)
//   --pace block        draw as fast as nextDrawable allows (default)
//   --pace free:MS      draw every MS milliseconds
//   --pace margin:MS    draw MS milliseconds before the next refresh, predicted from the
//                       presentation times (dimna's refresh-locked pacing)
//   --drawables 2|3     CAMetalLayer.maximumDrawableCount (default 2)
//   --seconds S         how long to run (default 5)
//
// Esc quits early. The moving bar is the tearing check: if frames are shown mid-scan, the
// bar looks broken into offset pieces.
//
// Build: clang -fobjc-arc -O2 metal_latency.m -framework Cocoa -framework Metal \
//          -framework QuartzCore -o metal_latency

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <pthread.h>

typedef enum { PaceBlock, PaceFree, PaceMargin } Pace;

static struct {
    bool fullscreen;
    bool sync;
    Pace pace;
    double pace_ms;
    int drawables;
    double seconds;
} opt = { false, true, PaceBlock, 0, 2, 5 };

#define MAX_FRAMES 200000
static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
static double *latency_ms;   // presented - data stamp
static double *present_at;   // presentation times, in arrival order
static size_t n_presented, n_dropped, n_late;
static double last_present;  // newest presentation time seen
static double refresh_s;

static CAMetalLayer *layer;
static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static id<MTLRenderPipelineState> pipeline;

static double now_s(void) { return CACurrentMediaTime(); }

static void sleep_until(double t) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    double d = t - now_s();
    if (d <= 0) return;
    uint64_t ticks = (uint64_t)(d * 1e9 * (double)tb.denom / (double)tb.numer);
    mach_wait_until(mach_absolute_time() + ticks);
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}
static double pct(double *sorted, size_t n, double p) {
    if (n == 0) return NAN;
    size_t i = (size_t)(p * (double)(n - 1) + 0.5);
    return sorted[i];
}

static NSString *const shader_src =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct U { float x; float w; };\n"
     "struct VOut { float4 pos [[position]]; };\n"
     "vertex VOut vs(uint vid [[vertex_id]], constant U &u [[buffer(0)]]) {\n"
     "    VOut o;\n"
     "    o.pos = float4((vid & 1) ? u.x + u.w : u.x, (vid & 2) ? 1.0 : -1.0, 0.0, 1.0);\n"
     "    return o;\n"
     "}\n"
     "fragment float4 fs() { return float4(0.95, 0.9, 0.3, 1.0); }\n";

static void *render_thread(void *arg) {
    (void)arg;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    size_t frames = 0, waits_n = 0;
    double *waits = calloc(MAX_FRAMES, sizeof(double));
    double start = now_s(), last_draw = 0;

    while (now_s() - start < opt.seconds && frames < MAX_FRAMES) {
        @autoreleasepool {
            double aimed = 0;
            if (opt.pace == PaceFree) {
                sleep_until(last_draw + opt.pace_ms * 1e-3);
            } else if (opt.pace == PaceMargin) {
                os_unfair_lock_lock(&lock);
                double lp = last_present;
                os_unfair_lock_unlock(&lock);
                if (lp > 0) {
                    double margin = opt.pace_ms * 1e-3;
                    double k = ceil((now_s() + margin - lp) / refresh_s);
                    if (k < 1) k = 1;
                    aimed = lp + k * refresh_s;
                    sleep_until(aimed - margin);
                }
            }
            double asked = now_s();
            last_draw = asked;
            id<CAMetalDrawable> drawable = [layer nextDrawable];
            if (!drawable) continue;
            // The moment the newest data would be taken: everything after this is latency.
            double stamp = now_s();
            waits[waits_n++] = (stamp - asked) * 1e3;

            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = drawable.texture;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.06, 0.08, 1);
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
            // The bar crosses the window twice a second.
            struct { float x, w; } u = { (float)(-1.0 + 2.0 * fmod(stamp * 2.0, 1.0)), 0.02f };
            [enc setRenderPipelineState:pipeline];
            [enc setVertexBytes:&u length:sizeof u atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            [enc endEncoding];

            [drawable addPresentedHandler:^(id<MTLDrawable> d) {
                double p = d.presentedTime;
                os_unfair_lock_lock(&lock);
                if (p <= 0) {
                    n_dropped++;
                } else if (n_presented < MAX_FRAMES) {
                    latency_ms[n_presented] = (p - stamp) * 1e3;
                    present_at[n_presented] = p;
                    n_presented++;
                    if (p > last_present) last_present = p;
                    if (aimed > 0 && p - aimed > refresh_s / 2) n_late++;
                }
                os_unfair_lock_unlock(&lock);
            }];
            [cb presentDrawable:drawable];
            [cb commit];
            frames++;
        }
    }
    sleep_until(now_s() + 0.3); // let the last presentation reports arrive

    os_unfair_lock_lock(&lock);
    size_t n = n_presented;
    double *iv = calloc(n ? n : 1, sizeof(double));
    qsort(present_at, n, sizeof(double), cmp_double);
    size_t n_iv = 0;
    for (size_t i = 1; i < n; i++) iv[n_iv++] = (present_at[i] - present_at[i - 1]) * 1e3;
    qsort(iv, n_iv, sizeof(double), cmp_double);
    qsort(latency_ms, n, sizeof(double), cmp_double);
    qsort(waits, waits_n, sizeof(double), cmp_double);

    char pace[32];
    if (opt.pace == PaceBlock) snprintf(pace, sizeof pace, "block");
    else snprintf(pace, sizeof pace, "%s:%g", opt.pace == PaceFree ? "free" : "margin", opt.pace_ms);
    printf("%-10s sync=%-3s pace=%-9s drawables=%d | drawn %zu shown %zu dropped %zu late %zu | "
           "latency ms min %.2f med %.2f p95 %.2f max %.2f | shown every ms min %.2f med %.2f | "
           "wait for drawable ms med %.2f max %.2f\n",
           opt.fullscreen ? "fullscreen" : "window", opt.sync ? "on" : "off", pace, opt.drawables,
           frames, n, n_dropped, n_late,
           pct(latency_ms, n, 0), pct(latency_ms, n, 0.5), pct(latency_ms, n, 0.95), pct(latency_ms, n, 1),
           pct(iv, n_iv, 0), pct(iv, n_iv, 0.5),
           pct(waits, waits_n, 0.5), pct(waits, waits_n, 1));
    fflush(stdout);
    exit(0);
}

@interface MetalView : NSView
@end
@implementation MetalView
- (CALayer *)makeBackingLayer { return [CAMetalLayer layer]; }
- (BOOL)wantsUpdateLayer { return YES; }
@end

static void usage(void) {
    fprintf(stderr, "usage: metal_latency [--fullscreen] [--sync on|off] "
                    "[--pace block|free:MS|margin:MS] [--drawables 2|3] [--seconds S]\n");
    exit(2);
}

int main(int argc, const char **argv) {
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *v = i + 1 < argc ? argv[i + 1] : NULL;
        if (!strcmp(a, "--fullscreen")) opt.fullscreen = true;
        else if (!strcmp(a, "--sync") && v) { opt.sync = !strcmp(v, "on"); i++; }
        else if (!strcmp(a, "--drawables") && v) { opt.drawables = atoi(v); i++; }
        else if (!strcmp(a, "--seconds") && v) { opt.seconds = atof(v); i++; }
        else if (!strcmp(a, "--pace") && v) {
            if (!strcmp(v, "block")) opt.pace = PaceBlock;
            else if (!strncmp(v, "free:", 5)) { opt.pace = PaceFree; opt.pace_ms = atof(v + 5); }
            else if (!strncmp(v, "margin:", 7)) { opt.pace = PaceMargin; opt.pace_ms = atof(v + 7); }
            else usage();
            i++;
        } else usage();
    }
    if (opt.drawables != 2 && opt.drawables != 3) usage();
    latency_ms = calloc(MAX_FRAMES, sizeof(double));
    present_at = calloc(MAX_FRAMES, sizeof(double));

    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSScreen *screen = [NSScreen mainScreen];
        CGDirectDisplayID did = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(did);
        double hz = mode ? CGDisplayModeGetRefreshRate(mode) : 0;
        if (mode) CGDisplayModeRelease(mode);
        if (hz <= 0) hz = (double)screen.maximumFramesPerSecond;
        if (hz <= 0) hz = 60;
        refresh_s = 1.0 / hz;
        fprintf(stderr, "display: %.0f x %.0f points, scale %.0f, %.2f Hz\n",
                screen.frame.size.width, screen.frame.size.height, screen.backingScaleFactor, hz);

        NSRect frame = opt.fullscreen ? screen.frame : NSMakeRect(200, 200, 1200, 700);
        NSWindowStyleMask style = opt.fullscreen
            ? NSWindowStyleMaskBorderless
            : (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable);
        NSWindow *win = [[NSWindow alloc] initWithContentRect:frame styleMask:style
                                                      backing:NSBackingStoreBuffered defer:NO];
        win.title = @"metal_latency";
        win.opaque = YES;
        win.backgroundColor = NSColor.blackColor;
        if (opt.fullscreen) {
            win.level = NSMainMenuWindowLevel + 1;
            app.presentationOptions = NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar;
        }

        device = MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr, "no Metal device\n"); return 1; }
        queue = [device newCommandQueue];
        NSError *err = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:shader_src options:nil error:&err];
        if (!lib) { fprintf(stderr, "shader: %s\n", err.localizedDescription.UTF8String); return 1; }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"];
        pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!pipeline) { fprintf(stderr, "pipeline: %s\n", err.localizedDescription.UTF8String); return 1; }

        MetalView *view = [[MetalView alloc] initWithFrame:frame];
        view.wantsLayer = YES;
        layer = (CAMetalLayer *)view.layer;
        layer.device = device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = YES;
        layer.opaque = YES;
        layer.displaySyncEnabled = opt.sync;
        layer.maximumDrawableCount = (NSUInteger)opt.drawables;
        layer.contentsScale = screen.backingScaleFactor;
        layer.drawableSize = CGSizeMake(frame.size.width * screen.backingScaleFactor,
                                        frame.size.height * screen.backingScaleFactor);
        win.contentView = view;
        [win makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];

        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
            if (e.keyCode == 53) exit(1); // Esc
            return e;
        }];

        pthread_t th;
        pthread_create(&th, NULL, render_thread, NULL);
        [app run];
    }
    return 0;
}
