//! The GPU for a window: what the display, the control window and the tiles draw with. This
//! file holds what every backend and its callers agree on (the data handed to the GPU, the
//! constants, the result of a frame) and the choice of this system's backend, at compile
//! time: `Gpu` and `Target` are the backend's own, so a caller calls the backend's
//! functions directly; there is no indirect call. Linux: `gpu_vulkan.zig` (Vulkan on a
//! Wayland surface).
//!
//! What a backend's `Gpu` must offer, because the callers use it (main.zig, control.zig,
//! tiles.zig, display.zig, session.zig, pipeline.zig):
//!
//! - `init(gpa, target, mode, share)`: a renderer for `target` (from `Window.gpuTarget`)
//!   with present mode `mode`; `share`, another `Gpu` (or null) whose per-process setup
//!   (Vulkan: the instance) this one uses, which must outlive it. `deinit` gives everything
//!   back.
//! - `resize(width, height)`: makes the drawable for a window of that size (in the window's
//!   units, which are pixels); called before the first `draw`, when the window reports
//!   `resized`, and after `draw` returned `.out_of_date`.
//! - `unsized()`: true while there is no drawable yet (`resize` not yet called).
//! - `pixelSize()`: the drawable's size in pixels, which may differ from what `resize` was
//!   asked for (the panels and text are laid out to it).
//! - `draw(panels, fills, text, context, before_present)`: one frame (the trace panels,
//!   then the fills, then the text quads over everything) put on the screen.
//!   `before_present(context)` is called immediately before the frame is handed to the
//!   window system (the window's `beforePresent`, whose requests must attach to this
//!   frame). Returns a `DrawResult`; it does not wait for a free image (`.busy` instead).
//! - `createText(atlas, size, max_vertices)` once: the glyph atlas (`size` x `size`
//!   coverage bytes) and room for `max_vertices` text vertices per frame; `textFont(font)`:
//!   the font whose glyphs drawn later (`Font.takeDirty`) `draw` copies up before the frame
//!   that uses them.
//! - `createHistory(nch, want_samples, least_samples, bucket_samples)`: the live sample
//!   history and its buckets, made anew (the old ones dropped) when the shape of the data
//!   changes; `createReview()`: the review history, made once, when review is first used.
//! - `writeSamples(first, samples)`: a block of interleaved rows into the history and the
//!   buckets.
//!
//! Fields the callers read or write. The slices are mapped memory: written by the CPU,
//! never read back by it from the GPU, and visible to the next frame without a flush.
//!
//! - `hist` (`[]i16`), `hist_cap`, `nch`: the live history, `hist_cap` samples (a power of
//!   two, 0 before `createHistory`) of `nch` interleaved columns, a ring indexed by absolute
//!   sample number. The feed writes into it when it filters a panel's recent past again.
//! - `dec` (`decimate.Ring`): the buckets beside it (minimum and maximum of every
//!   `decimate.bucket` samples); the feed holds a pointer to it and rewrites buckets, the
//!   display reads `dec.cap`.
//! - `rev` (`[]i16`), `rev_cap`: the review history (`rev_cap` samples, `nch` columns), which
//!   review fills; `rev_cols` (`[]u32`): per panel `column_region` pixel columns of `nch`
//!   minimum/maximum words, which review fills from the overview. Empty until
//!   `createReview`.
//! - `row_gains` (`[]f32`): `max_rows` factors per panel for `max_gain_panels` panels,
//!   written by `Display.frame` every frame.
//! - `wait_render` (written): `draw` waits for the GPU to finish each frame before
//!   presenting it, and puts the time that took in `last_render_ns` (read). Diagnostics
//!   only: it delays presenting.
//!
//! A backend's `Target` is what its window hands it (`Window.gpuTarget`).

const builtin = @import("builtin");

const backend = switch (builtin.os.tag) {
    .linux => @import("gpu_vulkan.zig"),
    .macos => @import("gpu_metal.zig"),
    else => @compileError("dimna has no GPU backend for this system yet"),
};
pub const Gpu = backend.Gpu;
pub const Target = backend.Target;

/// How frames are presented (`--present`); where the system lacks the one asked for, the
/// backend falls back to presenting at the refresh.
pub const PresentMode = enum { auto, mailbox, immediate, fifo };

/// Matches `Params` in traces.vert.
pub const TraceParams = extern struct {
    nch: u32,
    cap_mask: u32,
    newest: u32,
    first_ch: u32,
    cols: u32,
    rows: u32,
    span: f32,
    lsb_per_row: f32,
    half_px: f32,
    /// Negative: scroll. Else sweep mode: samples since the current pass began.
    phase: f32 = -1,
    /// Samples at the right end of the window that do not exist yet (not drawn).
    future: f32 = 0,
    /// Brightness, 0..1.
    gain: f32 = 1,
    /// Where the panel's row factors start in `Gpu.row_gains`.
    gain_base: u32 = 0,
    /// Buckets in the decimated ring - 1: pixel columns that hold `bucket_cols` samples or
    /// more are drawn from buckets. 0: always from samples.
    dec_mask: u32 = 0,
};

/// Pixel columns per panel in `Gpu.rev_cols`: no panel is wider.
pub const column_region = 4096;
/// `TraceParams.dec_mask` of a panel drawn from `Gpu.rev_cols`.
pub const from_columns = 0xFFFF_FFFF;

/// Row factors per panel in `Gpu.row_gains` (matches the shader's limit).
pub const max_rows = 256;
pub const max_gain_panels = 16;

/// A rectangle of the display, in pixels.
pub const PixelRect = struct { x: u32, y: u32, w: u32, h: u32 };

/// One panel of traces: where on the display, and what to draw there.
pub const PanelDraw = struct {
    rect: PixelRect,
    params: TraceParams,
    /// Draw from the review history instead of the live one.
    review: bool = false,
};

/// A solid rectangle (dividers, markers), drawn over the panels.
pub const Fill = struct { rect: PixelRect, colour: [4]f32 };

/// The drawable's size in pixels (`Gpu.pixelSize`).
pub const Size = struct { width: u32, height: u32 };

/// How `Gpu.draw` ended.
pub const DrawResult = enum {
    presented,
    /// The swapchain no longer fits the window: call `resize`.
    out_of_date,
    /// No swapchain image was free; nothing was drawn. Try again shortly.
    busy,
};
