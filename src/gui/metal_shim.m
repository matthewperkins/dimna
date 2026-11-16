// The Objective-C side of gpu_metal.zig: Metal and Core Animation behind the C interface
// of metal_shim.h, which says what each function does. Compiled with ARC.
//
// The per-frame path (ms_frame_*) allocates nothing of its own: the render pass descriptor
// is made once per renderer; the command buffer, its encoder and the drawable are Metal's.
// Each function drains its own autorelease pool, as the drawing threads have none.

#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h>
#include "metal_shim.h"

static atomic_long live_objects;

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static void put_string(char *out, size_t len, const char *s) {
    if (len == 0) return;
    size_t n = strlen(s);
    if (n >= len) n = len - 1;
    memcpy(out, s, n);
    out[n] = 0;
}

@interface MSCtx : NSObject {
@public
    id<MTLDevice> device;
    id<MTLLibrary> library;
    id<MTLRenderPipelineState> traces;
    id<MTLRenderPipelineState> fill;
    id<MTLRenderPipelineState> text;
    double compile_ms;
}
@end

@implementation MSCtx
- (instancetype)init {
    self = [super init];
    if (self) atomic_fetch_add(&live_objects, 1);
    return self;
}
- (void)dealloc {
    atomic_fetch_sub(&live_objects, 1);
}
@end

// The layer's next drawable, fetched ahead of the frame that draws into it: nextDrawable
// blocks until a drawable is free (until a refresh with display sync on, and about one
// even with it off: measured 7.6 ms on a 120 Hz display, every frame, though every
// drawable presented before had been reported presented), and `Gpu.draw` must not. So it
// is called on a serial queue of the renderer's own, one call at a time, and the frame
// takes what it has fetched, or returns MS_FRAME_BUSY at once if nothing is there yet.
// Held by the renderer and by the fetch in progress, so a fetch that ends after the
// renderer is gone touches nothing freed.
@interface MSNext : NSObject {
@public
    os_unfair_lock lock;
    id<CAMetalDrawable> drawable;
    BOOL fetching;
    CAMetalLayer *layer;
    dispatch_queue_t queue;
}
@end

@implementation MSNext
@end

// Starts fetching the next drawable unless one is there or on its way.
static void fetch_next(MSNext *next) {
    os_unfair_lock_lock(&next->lock);
    BOOL start = !next->drawable && !next->fetching;
    if (start) next->fetching = YES;
    os_unfair_lock_unlock(&next->lock);
    if (!start) return;
    dispatch_async(next->queue, ^{
        @autoreleasepool {
            // nil after the layer's timeout of a second; the next frame asks again.
            id<CAMetalDrawable> d = [next->layer nextDrawable];
            os_unfair_lock_lock(&next->lock);
            next->drawable = d;
            next->fetching = NO;
            os_unfair_lock_unlock(&next->lock);
        }
    });
}

// The drawable fetched, if there is one (the caller then owns it), and the next fetch begun.
static id<CAMetalDrawable> take_next(MSNext *next) {
    os_unfair_lock_lock(&next->lock);
    id<CAMetalDrawable> d = next->drawable;
    next->drawable = nil;
    os_unfair_lock_unlock(&next->lock);
    fetch_next(next);
    return d;
}

// What a renderer's frame binds last, so a panel after a panel of the same history binds
// nothing again.
enum { BOUND_NONE, BOUND_LIVE, BOUND_REVIEW, BOUND_FILL, BOUND_TEXT };

@interface MSRend : NSObject {
@public
    MSCtx *ctx;
    id<MTLCommandQueue> queue;
    CAMetalLayer *layer; // nil: offscreen
    void **slot;
    MSNext *next;
    id<MTLTexture> target; // offscreen
    uint32_t width, height;
    id<MTLBuffer> buf[MS_BUF_COUNT];
    id<MTLTexture> atlas;
    uint32_t atlas_size;
    MTLRenderPassDescriptor *pass;
    // The last frame committed (one in flight at a time).
    id<MTLCommandBuffer> last;
    // The frame being encoded.
    id<MTLCommandBuffer> cb;
    id<MTLRenderCommandEncoder> enc;
    id<CAMetalDrawable> drawable;
    int bound;
    uint64_t begun_ns;
    uint64_t encode_ns;
    uint64_t gpu_ns;
}
@end

@implementation MSRend
- (instancetype)init {
    self = [super init];
    if (self) atomic_fetch_add(&live_objects, 1);
    return self;
}
- (void)dealloc {
    atomic_fetch_sub(&live_objects, 1);
}
@end

static inline MSCtx *ctx_of(const MSContext *c) { return (__bridge MSCtx *)(const void *)c; }
static inline MSRend *rend_of(MSRenderer *r) { return (__bridge MSRend *)(void *)r; }

// ---- The context ----

static id<MTLRenderPipelineState> make_pipeline(id<MTLDevice> dev, id<MTLLibrary> lib, NSString *vs, NSString *fs, BOOL blend, NSError **err) {
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:vs];
    pd.fragmentFunction = [lib newFunctionWithName:fs];
    if (!pd.vertexFunction || !pd.fragmentFunction) return nil;
    MTLRenderPipelineColorAttachmentDescriptor *ca = pd.colorAttachments[0];
    ca.pixelFormat = MTLPixelFormatBGRA8Unorm;
    if (blend) {
        // As text.frag's pipeline on Linux: colour over, alpha added.
        ca.blendingEnabled = YES;
        ca.rgbBlendOperation = MTLBlendOperationAdd;
        ca.alphaBlendOperation = MTLBlendOperationAdd;
        ca.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        ca.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        ca.sourceAlphaBlendFactor = MTLBlendFactorOne;
        ca.destinationAlphaBlendFactor = MTLBlendFactorOne;
    }
    return [dev newRenderPipelineStateWithDescriptor:pd error:err];
}

MSContext *ms_context_create(const char *source, size_t source_len, int *code, char *err, size_t err_len) {
    @autoreleasepool {
        *code = 0;
        put_string(err, err_len, "");
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            *code = MS_ERR_NO_DEVICE;
            put_string(err, err_len, "no Metal device");
            return NULL;
        }
        NSString *src = [[NSString alloc] initWithBytes:source length:source_len encoding:NSUTF8StringEncoding];
        if (!src) {
            *code = MS_ERR_COMPILE;
            put_string(err, err_len, "the shader source is not UTF-8");
            return NULL;
        }
        MTLCompileOptions *opt = [MTLCompileOptions new];
        // Fast math off: the trace shader's comparisons (off scale, the bucket choice) and
        // divisions are to come out as written.
        opt.mathMode = MTLMathModeSafe;
        opt.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsPrecise;
        uint64_t t0 = now_ns();
        NSError *e = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:opt error:&e];
        if (!lib) {
            *code = MS_ERR_COMPILE;
            put_string(err, err_len, e ? e.localizedDescription.UTF8String : "the shader library was not made");
            return NULL;
        }
        MSCtx *c = [MSCtx new];
        c->device = dev;
        c->library = lib;
        c->traces = make_pipeline(dev, lib, @"trace_vertex", @"trace_fragment", NO, &e);
        if (c->traces) c->fill = make_pipeline(dev, lib, @"fill_vertex", @"fill_fragment", NO, &e);
        if (c->fill) c->text = make_pipeline(dev, lib, @"text_vertex", @"text_fragment", YES, &e);
        if (!c->text) {
            *code = MS_ERR_PIPELINE;
            put_string(err, err_len, e ? e.localizedDescription.UTF8String : "a shader function is missing");
            return NULL;
        }
        c->compile_ms = (double)(now_ns() - t0) / 1e6;
        return (__bridge_retained MSContext *)c;
    }
}

void ms_context_destroy(MSContext *ctx) {
    @autoreleasepool {
        // Back to ARC, which lets go of it here.
        (void)CFBridgingRelease((CFTypeRef)ctx);
    }
}

void ms_context_info(const MSContext *ctx, char *name, size_t name_len, uint64_t *max_buffer, uint64_t *working_set, double *compile_ms) {
    @autoreleasepool {
        MSCtx *c = ctx_of(ctx);
        put_string(name, name_len, c->device.name.UTF8String);
        *max_buffer = c->device.maxBufferLength;
        *working_set = c->device.recommendedMaxWorkingSetSize;
        *compile_ms = c->compile_ms;
    }
}

uint64_t ms_context_allocated(const MSContext *ctx) {
    return ctx_of(ctx)->device.currentAllocatedSize;
}

// ---- The renderer ----

static MSRend *new_renderer(MSContext *ctx) {
    MSRend *r = [MSRend new];
    r->ctx = ctx_of(ctx);
    r->queue = [r->ctx->device newCommandQueue];
    r->pass = [MTLRenderPassDescriptor new];
    r->pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    r->pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    return r;
}

MSRenderer *ms_renderer_create(MSContext *ctx, void *layer_ptr, void **drawable_slot, int display_sync, int drawables) {
    @autoreleasepool {
        id obj = (__bridge id)layer_ptr;
        if (![obj isKindOfClass:[CAMetalLayer class]]) return NULL;
        MSRend *r = new_renderer(ctx);
        if (!r->queue) return NULL;
        CAMetalLayer *layer = obj;
        r->layer = layer;
        r->slot = drawable_slot;
        r->next = [MSNext new];
        r->next->lock = OS_UNFAIR_LOCK_INIT;
        r->next->layer = layer;
        r->next->queue = dispatch_queue_create("dimna.gpu.next-drawable", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        // Set in a transaction of its own: this thread has no run loop to commit an
        // implicit one.
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        layer.device = r->ctx->device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        // Drawn into, never read or sampled: lets the system keep it in its fastest form.
        layer.framebufferOnly = YES;
        // Every pixel is drawn opaque.
        layer.opaque = YES;
        layer.displaySyncEnabled = display_sync ? YES : NO;
        layer.maximumDrawableCount = (NSUInteger)drawables;
        // Presented as soon as the GPU is done, not with a Core Animation transaction.
        layer.presentsWithTransaction = NO;
        // nextDrawable gives up after a second rather than never (it is called ahead, on
        // a queue of its own: see MSNext).
        layer.allowsNextDrawableTimeout = YES;
        [CATransaction commit];
        return (__bridge_retained MSRenderer *)r;
    }
}

MSRenderer *ms_renderer_create_offscreen(MSContext *ctx) {
    @autoreleasepool {
        MSRend *r = new_renderer(ctx);
        if (!r->queue) return NULL;
        return (__bridge_retained MSRenderer *)r;
    }
}

static void wait_last(MSRend *r) {
    id<MTLCommandBuffer> cb = r->last;
    if (!cb) return;
    [cb waitUntilCompleted];
    double t = cb.GPUEndTime - cb.GPUStartTime;
    r->gpu_ns = t > 0 ? (uint64_t)(t * 1e9) : 0;
    r->last = nil;
}

void ms_renderer_wait(MSRenderer *rr) {
    @autoreleasepool {
        wait_last(rend_of(rr));
    }
}

void ms_renderer_destroy(MSRenderer *rr) {
    @autoreleasepool {
        MSRend *r = (__bridge_transfer MSRend *)(void *)rr;
        wait_last(r);
        r = nil;
    }
}

static uint32_t side(uint32_t v) { return v < 1 ? 1 : v > 16384 ? 16384 : v; }

int ms_renderer_resize(MSRenderer *rr, uint32_t width, uint32_t height, uint32_t *got_w, uint32_t *got_h) {
    @autoreleasepool {
        MSRend *r = rend_of(rr);
        uint32_t w = side(width), h = side(height);
        if (r->layer) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            r->layer.drawableSize = CGSizeMake(w, h);
            [CATransaction commit];
            CGSize s = r->layer.drawableSize;
            r->width = (uint32_t)s.width;
            r->height = (uint32_t)s.height;
            fetch_next(r->next);
        } else {
            wait_last(r);
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget;
            td.storageMode = MTLStorageModeShared;
            r->target = [r->ctx->device newTextureWithDescriptor:td];
            if (!r->target) {
                r->width = r->height = 0;
                return 1;
            }
            r->width = w;
            r->height = h;
        }
        *got_w = r->width;
        *got_h = r->height;
        return 0;
    }
}

void *ms_renderer_buffer(MSRenderer *rr, int slot, size_t bytes) {
    @autoreleasepool {
        MSRend *r = rend_of(rr);
        wait_last(r);
        r->buf[slot] = nil;
        if (bytes == 0) bytes = 4;
        if (bytes > r->ctx->device.maxBufferLength) return NULL;
        // Shared memory (Apple silicon has no other): written by the CPU, read by the next
        // frame without a copy or a flush. Only the CPU writes it, so Metal need not track
        // it; frees wait for the last frame (wait_last above).
        id<MTLBuffer> b = [r->ctx->device newBufferWithLength:bytes options:MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked];
        if (!b) return NULL;
        r->buf[slot] = b;
        return b.contents;
    }
}

void ms_renderer_free_buffer(MSRenderer *rr, int slot) {
    @autoreleasepool {
        MSRend *r = rend_of(rr);
        wait_last(r);
        r->buf[slot] = nil;
    }
}

int ms_renderer_atlas(MSRenderer *rr, const uint8_t *data, uint32_t size) {
    @autoreleasepool {
        MSRend *r = rend_of(rr);
        wait_last(r);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:size height:size mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        // Shared, so the rows glyphs drawn later change are copied in by the CPU while no
        // frame is in flight (ms_renderer_atlas_rows), with no staging buffer or blit.
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> t = [r->ctx->device newTextureWithDescriptor:td];
        if (!t) return 1;
        [t replaceRegion:MTLRegionMake2D(0, 0, size, size) mipmapLevel:0 withBytes:data bytesPerRow:size];
        r->atlas = t;
        r->atlas_size = size;
        return 0;
    }
}

void ms_renderer_atlas_rows(MSRenderer *rr, const uint8_t *data, uint32_t first, uint32_t end) {
    MSRend *r = rend_of(rr);
    uint32_t size = r->atlas_size;
    if (!r->atlas) return;
    if (end > size) end = size;
    if (end <= first) return;
    [r->atlas replaceRegion:MTLRegionMake2D(0, first, size, end - first) mipmapLevel:0 withBytes:data + (size_t)first * size bytesPerRow:size];
}

// ---- One frame ----

static void begin_pass(MSRend *r, id<MTLTexture> texture, const float clear[4]) {
    MTLRenderPassColorAttachmentDescriptor *ca = r->pass.colorAttachments[0];
    ca.texture = texture;
    ca.clearColor = MTLClearColorMake(clear[0], clear[1], clear[2], clear[3]);
    // The resources are the renderer's and live until the frame is waited for.
    r->cb = [r->queue commandBufferWithUnretainedReferences];
    r->enc = [r->cb renderCommandEncoderWithDescriptor:r->pass];
    ca.texture = nil;
    r->bound = BOUND_NONE;
}

int ms_frame_begin(MSRenderer *rr, const float clear[4]) {
    @autoreleasepool {
        MSRend *r = rend_of(rr);
        r->begun_ns = now_ns();
        // The last frame still on the GPU: busy, not a wait. Its drawable may have been
        // handed out before the display let go of it, and the GPU then waits for it (about
        // a refresh, measured on a layer in no window).
        if (r->last && r->last.status < MTLCommandBufferStatusCompleted) return MS_FRAME_BUSY;
        wait_last(r);
        CGSize s = r->layer.drawableSize;
        if ((uint32_t)s.width != r->width || (uint32_t)s.height != r->height) return MS_FRAME_OUT_OF_DATE;
        id<CAMetalDrawable> d = take_next(r->next);
        if (!d) return MS_FRAME_BUSY;
        // Fetched before the last resize: of the old size. Let go; the next is the new.
        if (d.texture.width != r->width || d.texture.height != r->height) return MS_FRAME_BUSY;
        r->drawable = d;
        begin_pass(r, d.texture, clear);
        return MS_FRAME_READY;
    }
}

int ms_frame_begin_offscreen(MSRenderer *rr, const float clear[4]) {
    @autoreleasepool {
        MSRend *r = rend_of(rr);
        r->begun_ns = now_ns();
        wait_last(r);
        begin_pass(r, r->target, clear);
        return MS_FRAME_READY;
    }
}

void ms_frame_panel(MSRenderer *rr, uint32_t x, uint32_t y, uint32_t w, uint32_t h, int review, const void *params, size_t params_len, uint32_t vertices, uint32_t instances) {
    @autoreleasepool {
        MSRend *r = rend_of(rr);
        id<MTLRenderCommandEncoder> enc = r->enc;
        if (!r->buf[MS_BUF_HIST] || !r->buf[MS_BUF_DEC] || !r->buf[MS_BUF_GAINS]) return;
        int want = review && r->buf[MS_BUF_REV] && r->buf[MS_BUF_REVC] ? BOUND_REVIEW : BOUND_LIVE;
        if (r->bound != want) {
            if (r->bound != BOUND_LIVE && r->bound != BOUND_REVIEW) [enc setRenderPipelineState:r->ctx->traces];
            [enc setVertexBuffer:r->buf[want == BOUND_REVIEW ? MS_BUF_REV : MS_BUF_HIST] offset:0 atIndex:0];
            [enc setVertexBuffer:r->buf[MS_BUF_GAINS] offset:0 atIndex:1];
            [enc setVertexBuffer:r->buf[want == BOUND_REVIEW ? MS_BUF_REVC : MS_BUF_DEC] offset:0 atIndex:2];
            r->bound = want;
        }
        [enc setViewport:(MTLViewport){ x, y, w, h, 0, 1 }];
        [enc setScissorRect:(MTLScissorRect){ x, y, w, h }];
        [enc setVertexBytes:params length:params_len atIndex:3];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:vertices instanceCount:instances];
    }
}

void ms_frame_fill(MSRenderer *rr, uint32_t x, uint32_t y, uint32_t w, uint32_t h, const float colour[4]) {
    @autoreleasepool {
        MSRend *r = rend_of(rr);
        id<MTLRenderCommandEncoder> enc = r->enc;
        if (r->bound != BOUND_FILL) {
            [enc setRenderPipelineState:r->ctx->fill];
            [enc setViewport:(MTLViewport){ 0, 0, r->width, r->height, 0, 1 }];
            r->bound = BOUND_FILL;
        }
        [enc setScissorRect:(MTLScissorRect){ x, y, w, h }];
        [enc setFragmentBytes:colour length:4 * sizeof(float) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
}

void ms_frame_text(MSRenderer *rr, uint32_t vertices) {
    @autoreleasepool {
        MSRend *r = rend_of(rr);
        id<MTLRenderCommandEncoder> enc = r->enc;
        if (!r->buf[MS_BUF_TEXT] || !r->atlas || vertices == 0) return;
        [enc setRenderPipelineState:r->ctx->text];
        r->bound = BOUND_TEXT;
        [enc setViewport:(MTLViewport){ 0, 0, r->width, r->height, 0, 1 }];
        [enc setScissorRect:(MTLScissorRect){ 0, 0, r->width, r->height }];
        float size[2] = { (float)r->width, (float)r->height };
        [enc setVertexBuffer:r->buf[MS_BUF_TEXT] offset:0 atIndex:0];
        [enc setVertexBytes:size length:sizeof size atIndex:1];
        [enc setFragmentTexture:r->atlas atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:vertices];
    }
}

void ms_frame_end(MSRenderer *rr, int wait_render, uint64_t *render_ns, void (*before_present)(void *), void *context) {
    @autoreleasepool {
        MSRend *r = rend_of(rr);
        [r->enc endEncoding];
        r->enc = nil;
        id<MTLCommandBuffer> cb = r->cb;
        r->cb = nil;
        id<CAMetalDrawable> d = r->drawable;
        r->drawable = nil;
        r->encode_ns = now_ns() - r->begun_ns;
        if (wait_render) {
            [cb commit];
            uint64_t t0 = now_ns();
            [cb waitUntilCompleted];
            *render_ns = now_ns() - t0;
            *r->slot = (__bridge void *)d;
            before_present(context);
            [d present];
        } else {
            *r->slot = (__bridge void *)d;
            before_present(context);
            [cb presentDrawable:d];
            [cb commit];
        }
        *r->slot = NULL;
        r->last = cb;
    }
}

void ms_frame_end_offscreen(MSRenderer *rr) {
    @autoreleasepool {
        MSRend *r = rend_of(rr);
        [r->enc endEncoding];
        r->enc = nil;
        r->encode_ns = now_ns() - r->begun_ns;
        [r->cb commit];
        r->last = r->cb;
        r->cb = nil;
    }
}

int ms_renderer_read(MSRenderer *rr, uint8_t *bgra, size_t len) {
    @autoreleasepool {
        MSRend *r = rend_of(rr);
        wait_last(r);
        if (!r->target || len != (size_t)r->width * r->height * 4) return 1;
        [r->target getBytes:bgra bytesPerRow:(NSUInteger)r->width * 4 fromRegion:MTLRegionMake2D(0, 0, r->width, r->height) mipmapLevel:0];
        return 0;
    }
}

void ms_renderer_times(const MSRenderer *rr, uint64_t *encode_ns, uint64_t *gpu_ns) {
    MSRend *r = (__bridge MSRend *)(const void *)rr;
    *encode_ns = r->encode_ns;
    *gpu_ns = r->gpu_ns;
}

// ---- For tests ----

long ms_live_objects(void) { return atomic_load(&live_objects); }

void *ms_test_layer_create(void) {
    @autoreleasepool {
        return (__bridge_retained void *)[CAMetalLayer layer];
    }
}

void ms_test_layer_set_size(void *layer, uint32_t width, uint32_t height) {
    @autoreleasepool {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        ((__bridge CAMetalLayer *)layer).drawableSize = CGSizeMake(width, height);
        [CATransaction commit];
    }
}

void ms_test_layer_release(void *layer) {
    @autoreleasepool {
        (void)CFBridgingRelease((CFTypeRef)layer);
    }
}
