// The C interface of metal_shim.m, the Objective-C side of gpu_metal.zig (the Mac's
// renderer). Zig calls these and nothing of the Objective-C runtime. Translated by the
// build (`metal_shim` module).
//
// A context is the per-process part: the Metal device, the shader library compiled from
// source, and the three pipelines. A renderer draws into a CAMetalLayer (or, for tests, a
// texture of its own), with its own command queue, its buffers and its glyph atlas. One
// thread uses a renderer at a time; a context may be shared by renderers on several
// threads (everything in it is immutable once made).
//
// Every function that may make autoreleased objects drains its own pool, so they can be
// called from threads that have none.

#ifndef DIMNA_METAL_SHIM_H
#define DIMNA_METAL_SHIM_H

#include <stddef.h>
#include <stdint.h>

typedef struct MSContext MSContext;
typedef struct MSRenderer MSRenderer;

// How `ms_frame_begin` ended (and `gpu.DrawResult`'s meaning).
enum {
    MS_FRAME_READY = 0,
    MS_FRAME_OUT_OF_DATE = 1, // the layer's drawable size is not what `ms_renderer_resize` set
    MS_FRAME_BUSY = 2,        // no drawable free right now; nothing was done
};

// Why `ms_context_create` failed.
enum {
    MS_ERR_NO_DEVICE = 1,
    MS_ERR_COMPILE = 2,
    MS_ERR_PIPELINE = 3,
};

// A renderer's buffers, by what they hold. Bound at the trace shader's buffer(0..2): the
// live history (hist, gains, dec) or the review one (rev, gains, revc).
enum {
    MS_BUF_HIST = 0,
    MS_BUF_GAINS = 1,
    MS_BUF_DEC = 2,
    MS_BUF_REV = 3,
    MS_BUF_REVC = 4,
    MS_BUF_TEXT = 5,
    MS_BUF_COUNT = 6,
};

// The device and the library compiled from `source` (UTF-8, `source_len` bytes), with the
// pipelines `trace_*`, `text_*` and `fill_*`. NULL on failure, with `*code` (MS_ERR_*) and
// the reason (the compiler's message for MS_ERR_COMPILE) in `err`, zero-terminated.
MSContext *ms_context_create(const char *source, size_t source_len, int *code, char *err, size_t err_len);
void ms_context_destroy(MSContext *ctx);
// The device's name (zero-terminated, cut to `name_len`), its largest buffer, the memory
// it recommends using at most, and how long making the library and pipelines took.
void ms_context_info(const MSContext *ctx, char *name, size_t name_len, uint64_t *max_buffer, uint64_t *working_set, double *compile_ms);
// Bytes the device has allocated (`MTLDevice.currentAllocatedSize`).
uint64_t ms_context_allocated(const MSContext *ctx);

// A renderer for `layer` (a CAMetalLayer): sets its device, pixel format, display sync,
// number of drawables and the rest of what is the renderer's. `drawable_slot` is where a
// frame's drawable is put while `before_present` runs. NULL if `layer` is not a CAMetalLayer.
MSRenderer *ms_renderer_create(MSContext *ctx, void *layer, void **drawable_slot, int display_sync, int drawables);
// A renderer that draws into a texture of its own (made by `ms_renderer_resize`); tests.
MSRenderer *ms_renderer_create_offscreen(MSContext *ctx);
// Waits for the last frame, then lets go of everything (not of the layer's settings).
void ms_renderer_destroy(MSRenderer *r);
// Layer: sets its drawable size; offscreen: makes the texture. Both 1 to 16384 pixels a
// side. `*got_w`, `*got_h`: the size it then has. 0 on success.
int ms_renderer_resize(MSRenderer *r, uint32_t width, uint32_t height, uint32_t *got_w, uint32_t *got_h);
// Waits until the GPU has finished the last frame committed.
void ms_renderer_wait(MSRenderer *r);
// Makes buffer `slot` anew with `bytes` (shared memory, zeroed), after waiting for the
// last frame; the old one is let go. Returns its contents, or NULL (nothing is left in
// the slot) if Metal cannot make it or `bytes` is more than the device's largest buffer.
void *ms_renderer_buffer(MSRenderer *r, int slot, size_t bytes);
void ms_renderer_free_buffer(MSRenderer *r, int slot);
// The glyph atlas: `size` x `size` coverage bytes. 0 on success.
int ms_renderer_atlas(MSRenderer *r, const uint8_t *data, uint32_t size);
// Copies rows [first, end) of `data` (the whole atlas) into the atlas texture. Only while
// no frame is in flight: between `ms_frame_begin` and the first draw of the frame.
void ms_renderer_atlas_rows(MSRenderer *r, const uint8_t *data, uint32_t first, uint32_t end);

// One frame: begin, then panels, fills and text in that order, then end.
//
// Begin takes the layer's next drawable (fetched ahead, see MSNext in the .m) and starts a
// render pass on it, cleared to `clear` (RGBA). It waits for nothing: MS_FRAME_BUSY while
// the last frame is still on the GPU (one frame in flight, as on Linux) or no drawable
// has been fetched yet; MS_FRAME_OUT_OF_DATE when the layer's drawable size is not what
// the last resize set.
int ms_frame_begin(MSRenderer *r, const float clear[4]);
// The same on an offscreen renderer's texture: waits for the last frame, then
// MS_FRAME_READY.
int ms_frame_begin_offscreen(MSRenderer *r, const float clear[4]);
// One panel of traces: viewport and scissor (x, y, w, h), already inside the drawable;
// `params` (`params_len` bytes) at the shader's buffer(3); the review history if `review`
// and there is one.
void ms_frame_panel(MSRenderer *r, uint32_t x, uint32_t y, uint32_t w, uint32_t h, int review, const void *params, size_t params_len, uint32_t vertices, uint32_t instances);
// A solid rectangle (already inside the drawable) replacing what is under it.
void ms_frame_fill(MSRenderer *r, uint32_t x, uint32_t y, uint32_t w, uint32_t h, const float colour[4]);
// `vertices` from the start of the text buffer (MS_BUF_TEXT), over everything.
void ms_frame_text(MSRenderer *r, uint32_t vertices);
// Ends the pass and puts the frame on the screen (presented when the GPU is done, without
// a Core Animation transaction). The drawable is in `*drawable_slot`
// while `before_present(context)` runs, immediately before presenting, and the slot is
// NULL again afterwards. With `wait_render`, the frame is committed first and waited for,
// and `*render_ns` is how long that took; then it is presented.
void ms_frame_end(MSRenderer *r, int wait_render, uint64_t *render_ns, void (*before_present)(void *), void *context);
// Ends the pass and commits it (offscreen: nothing is presented).
void ms_frame_end_offscreen(MSRenderer *r);
// Offscreen: waits for the last frame and copies the texture out, BGRA, rows top first.
// 0 on success; non-zero if `len` is not width x height x 4.
int ms_renderer_read(MSRenderer *r, uint8_t *bgra, size_t len);
// The last frame finished: how long it took to encode (begin to commit, CPU) and how long
// the GPU worked on it (Metal's GPUStartTime to GPUEndTime).
void ms_renderer_times(const MSRenderer *r, uint64_t *encode_ns, uint64_t *gpu_ns);

// For tests: the number of the shim's own objects (contexts, renderers) alive, and a bare
// CAMetalLayer in no window (retained; release it with ms_test_layer_release).
long ms_live_objects(void);
void *ms_test_layer_create(void);
void ms_test_layer_set_size(void *layer, uint32_t width, uint32_t height);
void ms_test_layer_release(void *layer);

#endif
