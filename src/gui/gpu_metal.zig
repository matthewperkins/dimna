//! Metal for the Mac's windows: the macOS backend of `gpu.zig`, which declares the types
//! used here and says what a backend must offer; `gpu_vulkan.zig` is Linux's, and this
//! file does what it does, in the same order. Metal and Core Animation are called through
//! an Objective-C shim (`metal_shim.m`, its C interface `metal_shim.h`); nothing here calls
//! the Objective-C runtime.
//!
//! - Memory: Apple silicon only, so every buffer is shared memory. The mapped slices
//!   (`hist`, `dec`, `rev`, `rev_cols`, `row_gains`, the text vertices) are the contents of
//!   Metal buffers in shared storage: written by the CPU, seen by the next frame with no
//!   copy and no flush.
//! - Shaders: `shaders/traces.metal` and `shaders/text.metal`, Metal Shading Language
//!   doing what the GLSL does, embedded and compiled from source when the first `Gpu` of
//!   the process is made (there is no offline `metal` compiler with the Command Line
//!   Tools), with fast math off. A compile error fails `init` with the compiler's message.
//!   Static asserts appended to the source hold the shader's `TraceParams` and text vertex
//!   to the layouts here.
//! - One frame in flight, as on Linux: a frame is begun only when the last one is finished
//!   (else `.busy`), so the text vertices and the atlas are rewritten in place.
//! - `share`: the process's renderers (display, control window, tiles) use one device, one
//!   compiled library and the three pipelines made from it (`MSContext`); each has its own
//!   command queue, buffers and atlas, as each draws from its own thread.
//!
//! Presenting (`PresentMode`): `immediate`, `mailbox` and `auto` free-run with the layer's
//! display sync off, and three drawables; `fifo` (the control and tile windows) has
//! display sync on and two (`drawables_sync_off` says why). `auto` is sync off because
//! that is what the Mac measured quickest (`docs/plans/macos-port.md`: about 5 ms
//! fullscreen, against 16 ms with sync on) and what Linux's `auto` picks where it can
//! (mailbox or immediate: never wait for the refresh). The Mac has no mailbox (frames
//! shown at the refresh, a newer one replacing a queued one, without waiting): `mailbox`
//! is sync off too, and tears like `immediate`. The layer presents
//! without a Core Animation transaction (`presentsWithTransaction` off), as soon as the
//! GPU is done.
//!
//! `draw` never waits for the GPU or for a drawable: Metal's `nextDrawable` blocks until
//! one is free (about a refresh even with sync off, measured), so the next drawable is
//! fetched ahead on a queue of the renderer's own and `draw` takes it if it is there; and
//! while the last frame is still on the GPU (its drawable can be handed out before the
//! display has let go of it, and the GPU then waits) `draw` says `.busy` too.

const std = @import("std");
const ms = @import("metal_shim");
const font = @import("font.zig");
const theme = @import("theme.zig");
const decimate = @import("dimna").decimate;
const os = @import("dimna").os;
const log = std.log.scoped(.gpu);

// What every backend and its callers agree on, declared once in gpu.zig.
const gpu = @import("gpu.zig");
const PresentMode = gpu.PresentMode;
const TraceParams = gpu.TraceParams;
const PixelRect = gpu.PixelRect;
const PanelDraw = gpu.PanelDraw;
const Fill = gpu.Fill;
const DrawResult = gpu.DrawResult;
const Size = gpu.Size;
const column_region = gpu.column_region;
const max_rows = gpu.max_rows;
const max_gain_panels = gpu.max_gain_panels;

/// What a window hands the GPU (`Window.gpuTarget`).
pub const Target = struct {
    /// The window's CAMetalLayer.
    layer: *anyopaque,
    /// Where `Gpu.draw` puts the frame's drawable (an id<CAMetalDrawable>, not
    /// retained for the window) before it calls `before_present`, and null again
    /// after presenting. The window's `beforePresent(tag)` reads it to attach its
    /// report of when the frame reached the screen.
    drawable: *?*anyopaque,
};

/// What a panel's draw gives the trace shader (`setVertexBytes`, buffer 3): its
/// `TraceParams`, then the four trace colours (`theme.trace`).
const ShaderParams = extern struct {
    params: TraceParams,
    pal: [12]f32,
};
comptime {
    // 14 words of TraceParams, then 12 of palette: the shader's `TraceParams` struct.
    std.debug.assert(@sizeOf(TraceParams) == 14 * 4);
    std.debug.assert(@offsetOf(ShaderParams, "pal") == @sizeOf(TraceParams));
    std.debug.assert(@sizeOf(ShaderParams) == 26 * 4);
    const info = @typeInfo(TraceParams).@"struct";
    for (info.field_names, info.field_types, 0..) |name, t, i| {
        std.debug.assert(t == u32 or t == f32);
        std.debug.assert(@offsetOf(TraceParams, name) == 4 * i);
    }
    std.debug.assert(@sizeOf(font.Vertex) == 20);
}

/// The shaders, as compiled: both sources, and static asserts that the shader's structs
/// have the layouts above (field by field, by name, offset and type), so a shader that
/// read a field at the wrong place does not compile.
const msl_source = @embedFile("shaders/traces.metal") ++ "\n" ++ @embedFile("shaders/text.metal") ++ msl_layout;

const msl_layout = blk: {
    @setEvalBranchQuota(20000);
    const p = std.fmt.comptimePrint;
    var s: []const u8 = "\n// ---- Appended by gpu_metal.zig: the layouts Zig hands these shaders. ----\n";
    s = s ++ p("static_assert(sizeof(TraceParams) == {d}, \"TraceParams: size\");\n", .{@sizeOf(ShaderParams)});
    const info = @typeInfo(TraceParams).@"struct";
    for (info.field_names, info.field_types) |name, t| {
        s = s ++ p("static_assert(__builtin_offsetof(TraceParams, {s}) == {d}, \"TraceParams.{s}: offset\");\n", .{ name, @offsetOf(TraceParams, name), name });
        s = s ++ p("static_assert(is_same<decltype(TraceParams::{s}), {s}>::value, \"TraceParams.{s}: type\");\n", .{ name, if (t == u32) "uint" else "float", name });
    }
    s = s ++ p("static_assert(__builtin_offsetof(TraceParams, pal) == {d}, \"TraceParams.pal: offset\");\n", .{@offsetOf(ShaderParams, "pal")});
    s = s ++ p("static_assert(sizeof(TextVertex) == {d}, \"TextVertex: size\");\n", .{@sizeOf(font.Vertex)});
    for ([_][]const u8{ "pos", "uv", "colour" }) |name| {
        s = s ++ p("static_assert(__builtin_offsetof(TextVertex, {s}) == {d}, \"TextVertex.{s}: offset\");\n", .{ name, @offsetOf(font.Vertex, name), name });
    }
    break :blk s;
};

/// Drawables a layer has (`maximumDrawableCount`). With display sync off, three: a frame
/// presented while an older one still waits to be shown takes its place (the older is
/// reported not presented), as with Vulkan's mailbox, so the newest frame is the one
/// shown. Measured on the M4's display (60 Hz), 4 s each, two rounds, presented time
/// less the time the frame's data was taken: median 5.6 and 4.1 ms in a window, 5.0 and
/// 5.4 ms fullscreen, against 7.0, 5.8, 6.0 and 6.1 ms with two. With display sync on
/// (`fifo`), three as well: drawn flat out, three queue a frame more than two (median 65
/// ms against 32 ms in a window), but dimna's windows draw once a refresh, and with two
/// the display found no drawable free every other refresh (a frame is shown a refresh
/// after it is presented): 26 frames a second fullscreen against 52 with three, both
/// about 20 ms behind.
const drawables_sync_off = 3;
const drawables_sync_on = 3;

pub const Gpu = struct {
    gpa: std.mem.Allocator,
    ctx: *ms.MSContext,
    /// False when the context (device, library, pipelines) belongs to another Gpu
    /// (`init`'s `share`).
    owns_ctx: bool = true,
    r: *ms.MSRenderer,
    /// The drawable's size in pixels, as read back from the layer at `resize` (0 x 0
    /// before it).
    width: u32 = 0,
    height: u32 = 0,

    /// The text vertex buffer, mapped; each frame's quads are copied into it.
    text_vertices: []font.Vertex = &.{},
    /// The font whose atlas this is (`textFont`): glyphs it draws on demand are copied to
    /// the atlas texture before the frame that uses them, only the rows that changed.
    text_font: ?*const font.Font = null,
    atlas_size: u32 = 0,
    /// Rows of the atlas not yet copied: [first, end).
    atlas_pending: ?[2]u32 = null,

    /// A factor on the vertical scale for every row of every panel (1 = the panel's own
    /// scale): panel `i`'s rows start at `i * max_rows`. Mapped; the shader reads it.
    row_gains: []f32 = &.{},

    /// Sample history: `hist_cap` samples of `nch` interleaved int16, a ring indexed by
    /// absolute sample number.
    hist: []i16 = &.{},
    hist_cap: usize = 0,
    nch: usize = 0,
    /// The decimated history beside it (`decimate.zig`): the minimum and maximum of every
    /// 16 samples, reaching further back than the samples. `writeSamples` fills both.
    dec: decimate.Ring = .{},
    /// The review history: the same shape as the live one, made when review is first
    /// used (`createReview`), filled by `review.zig`.
    rev: []i16 = &.{},
    /// Samples the review history holds (the time bases' need; the live sample ring may be
    /// shorter when memory is short).
    rev_cap: usize = 0,
    /// Review of long stretches: for each panel `column_region` pixel columns of `nch`
    /// words (a minimum and maximum as in the buckets), which the review session fills
    /// from the overview. Panel `i`'s pixel column `c`, history column `h`:
    /// `rev_cols[(i * column_region + c) * nch + h]`. Made with the review history.
    rev_cols: []u32 = &.{},

    /// With `wait_render`, `draw` waits for the GPU to finish the frame before presenting it,
    /// and records how long that took. For diagnostics only: it delays presenting.
    wait_render: bool = false,
    last_render_ns: u64 = 0,

    /// A renderer for `target`'s layer. `share`: another Gpu whose device, shader library
    /// and pipelines this one uses instead of making its own (it must outlive this one).
    pub fn init(gpa: std.mem.Allocator, target: Target, mode: PresentMode, share: ?*const Gpu) !Gpu {
        const ctx = if (share) |s| s.ctx else try createContext(msl_source);
        errdefer if (share == null) ms.ms_context_destroy(ctx);
        const sync = mode == .fifo;
        const drawables: c_int = if (sync) drawables_sync_on else drawables_sync_off;
        const r = ms.ms_renderer_create(ctx, target.layer, @ptrCast(target.drawable), @intFromBool(sync), drawables) orelse {
            log.err("the window's layer is not a CAMetalLayer", .{});
            return error.NotAMetalLayer;
        };
        errdefer ms.ms_renderer_destroy(r);
        var self: Gpu = .{ .gpa = gpa, .ctx = ctx, .owns_ctx = share == null, .r = r };
        try self.createGains();
        log.info("present mode {t}: display sync {s}, {d} drawables", .{ mode, if (sync) "on" else "off", drawables });
        return self;
    }

    /// A Gpu that draws into a texture of `width` x `height` pixels of its own instead of a
    /// layer, for tests (`drawOffscreen`, `readPixels`).
    fn initOffscreen(gpa: std.mem.Allocator, width: u32, height: u32, share: ?*const Gpu) !Gpu {
        const ctx = if (share) |s| s.ctx else try createContext(msl_source);
        errdefer if (share == null) ms.ms_context_destroy(ctx);
        const r = ms.ms_renderer_create_offscreen(ctx) orelse return error.NoCommandQueue;
        errdefer ms.ms_renderer_destroy(r);
        var self: Gpu = .{ .gpa = gpa, .ctx = ctx, .owns_ctx = share == null, .r = r };
        try self.createGains();
        try self.resize(width, height);
        return self;
    }

    /// The device, the shader library compiled from `source` and the pipelines.
    fn createContext(source: []const u8) !*ms.MSContext {
        var err: [4096]u8 = undefined;
        const ctx = makeContext(source, &err) catch |e| {
            const why = std.mem.sliceTo(&err, 0);
            switch (e) {
                error.NoMetalDevice => log.err("no Metal device", .{}),
                error.ShaderCompile => log.err("the shaders do not compile: {s}", .{why}),
                error.ShaderPipeline => log.err("cannot make the shaders' pipelines: {s}", .{why}),
            }
            return e;
        };
        var name: [256]u8 = undefined;
        var max_buffer: u64 = 0;
        var working_set: u64 = 0;
        var compile_ms: f64 = 0;
        ms.ms_context_info(ctx, &name, name.len, &max_buffer, &working_set, &compile_ms);
        log.info("Metal device: {s}; shaders compiled in {d:.1} ms; largest buffer {d:.0} MB, working set {d:.0} MB", .{
            std.mem.sliceTo(&name, 0),
            compile_ms,
            @as(f64, @floatFromInt(max_buffer)) / 1e6,
            @as(f64, @floatFromInt(working_set)) / 1e6,
        });
        return ctx;
    }

    /// `createContext` without the log: on failure, the reason (the compiler's message for
    /// `error.ShaderCompile`) is in `err`, zero-terminated.
    fn makeContext(source: []const u8, err: []u8) error{ NoMetalDevice, ShaderCompile, ShaderPipeline }!*ms.MSContext {
        var code: c_int = 0;
        return ms.ms_context_create(source.ptr, source.len, &code, err.ptr, err.len) orelse switch (code) {
            ms.MS_ERR_NO_DEVICE => error.NoMetalDevice,
            ms.MS_ERR_COMPILE => error.ShaderCompile,
            else => error.ShaderPipeline,
        };
    }

    /// The row factors: small, mapped for good, all 1 to start with.
    fn createGains(self: *Gpu) !void {
        const count = max_rows * max_gain_panels;
        const p = ms.ms_renderer_buffer(self.r, ms.MS_BUF_GAINS, count * @sizeOf(f32)) orelse return error.OutOfGpuMemory;
        self.row_gains = @as([*]f32, @ptrCast(@alignCast(p)))[0..count];
        @memset(self.row_gains, 1.0);
    }

    pub fn deinit(self: *Gpu) void {
        // Waits for the last frame; the buffers and the atlas go with the renderer.
        ms.ms_renderer_destroy(self.r);
        if (self.dec.cap > 0) self.dec.deinit(self.gpa);
        if (self.owns_ctx) ms.ms_context_destroy(self.ctx);
        self.* = undefined;
    }

    /// Sets up text drawing: uploads the glyph atlas (`size` x `size` coverage bytes) and
    /// makes room for `max_vertices` vertices per frame. Call once before drawing text.
    pub fn createText(self: *Gpu, atlas: []const u8, size: u32, max_vertices: usize) !void {
        std.debug.assert(atlas.len >= @as(usize, size) * size);
        if (ms.ms_renderer_atlas(self.r, atlas.ptr, size) != 0) return error.OutOfGpuMemory;
        self.atlas_size = size;
        const p = ms.ms_renderer_buffer(self.r, ms.MS_BUF_TEXT, max_vertices * @sizeOf(font.Vertex)) orelse return error.OutOfGpuMemory;
        self.text_vertices = @as([*]font.Vertex, @ptrCast(@alignCast(p)))[0..max_vertices];
    }

    /// The font whose atlas `createText` uploaded (it must outlive the drawing): glyphs it
    /// rasterizes later are copied to the GPU by `draw`.
    pub fn textFont(self: *Gpu, f: *const font.Font) void {
        self.text_font = f;
    }

    /// Creates the history: a ring of samples and a ring of buckets (`decimate.zig`), of
    /// `nch` history columns. The buckets cover at least `bucket_samples` samples. The
    /// sample ring holds `want_samples` (rounded up to a power of two) if Metal can make a
    /// buffer that large, else the largest power of two it can, down to `least_samples`;
    /// if not even that, `error.OutOfGpuMemory` (Linux then tries host memory: the Mac has
    /// only the one kind). A buffer can be made if it is no larger than the device's
    /// `maxBufferLength` and Metal has the memory; the shader's 32-bit indices also limit
    /// a ring to 2^32 int16 (8 GiB). Call before drawing, and again when the number of
    /// channels or the sample rate changes (the old history is dropped).
    pub fn createHistory(self: *Gpu, nch: usize, want_samples: usize, least_samples: usize, bucket_samples: usize) !void {
        if (self.hist_cap > 0) {
            // The review history has the live one's shape: it goes too. Each free waits
            // for the last frame.
            self.destroyReview();
            self.destroyDecimated();
            ms.ms_renderer_free_buffer(self.r, ms.MS_BUF_HIST);
            self.hist = &.{};
            self.hist_cap = 0;
        }
        // The buckets first, as on Linux.
        const dec_cap = try std.math.ceilPowerOfTwo(usize, bucket_samples / decimate.bucket);
        if (dec_cap * nch > 1 << 32) return error.OutOfGpuMemory;
        const dp = ms.ms_renderer_buffer(self.r, ms.MS_BUF_DEC, dec_cap * nch * 4) orelse return error.OutOfGpuMemory;
        errdefer ms.ms_renderer_free_buffer(self.r, ms.MS_BUF_DEC);
        const words: [*]u32 = @ptrCast(@alignCast(dp));
        self.dec = try decimate.Ring.init(self.gpa, words[0 .. dec_cap * nch], dec_cap, nch);
        errdefer self.destroyDecimated();

        const full = try std.math.ceilPowerOfTwo(usize, want_samples);
        const least = @min(full, try std.math.ceilPowerOfTwo(usize, least_samples));
        var cap = full;
        const p = while (true) : (cap /= 2) {
            const fits = cap * nch <= 1 << 32;
            if (fits) if (ms.ms_renderer_buffer(self.r, ms.MS_BUF_HIST, std.mem.alignForward(usize, cap * nch * 2, 4))) |got| break got;
            if (cap <= least) {
                log.err("Metal cannot make a sample history of {d} samples x {d} channels", .{ cap, nch });
                return error.OutOfGpuMemory;
            }
        };
        self.hist = @as([*]i16, @ptrCast(@alignCast(p)))[0 .. cap * nch];
        self.hist_cap = cap;
        self.rev_cap = full;
        self.nch = nch;
        log.info("sample history: {d} samples x {d} channels ({d:.1} MB); buckets of {d}: {d} ({d:.1} MB); shared memory", .{
            cap,
            nch,
            @as(f64, @floatFromInt(cap * nch * 2)) / 1e6,
            decimate.bucket,
            dec_cap,
            @as(f64, @floatFromInt(dec_cap * nch * 4)) / 1e6,
        });
        if (cap < full) log.warn("there is room for {d} samples of history, not {d}: overlaid triggered sweeps and a freeze reach back that far", .{ cap, full });
    }

    fn destroyDecimated(self: *Gpu) void {
        if (self.dec.cap == 0) return;
        self.dec.deinit(self.gpa);
        ms.ms_renderer_free_buffer(self.r, ms.MS_BUF_DEC);
    }

    /// Makes the review history (once): `rev_cap` samples of the live one's columns.
    pub fn createReview(self: *Gpu) !void {
        if (self.rev.len > 0 or self.hist_cap == 0) return;
        if (self.rev_cap * self.nch > 1 << 32) return error.OutOfGpuMemory;
        const bytes = std.mem.alignForward(usize, self.rev_cap * self.nch * 2, 4);
        const h = ms.ms_renderer_buffer(self.r, ms.MS_BUF_REV, bytes) orelse return error.OutOfGpuMemory;
        errdefer ms.ms_renderer_free_buffer(self.r, ms.MS_BUF_REV);
        // In place of the buckets, review has the pixel columns of long stretches.
        const words = max_gain_panels * column_region * self.nch;
        const c = ms.ms_renderer_buffer(self.r, ms.MS_BUF_REVC, words * 4) orelse return error.OutOfGpuMemory;
        self.rev = @as([*]i16, @ptrCast(@alignCast(h)))[0 .. self.rev_cap * self.nch];
        self.rev_cols = @as([*]u32, @ptrCast(@alignCast(c)))[0..words];
        log.info("review history: {d:.1} MB, shared memory", .{@as(f64, @floatFromInt(bytes)) / 1e6});
    }

    pub fn destroyReview(self: *Gpu) void {
        if (self.rev.len == 0) return;
        ms.ms_renderer_free_buffer(self.r, ms.MS_BUF_REV);
        ms.ms_renderer_free_buffer(self.r, ms.MS_BUF_REVC);
        self.rev = &.{};
        self.rev_cols = &.{};
    }

    /// Writes `count` samples (interleaved, `nch` each) at absolute sample number `first`,
    /// into the sample ring and the buckets.
    pub fn writeSamples(self: *Gpu, first: i64, samples: []const i16) void {
        const nch = self.nch;
        const count = samples.len / nch;
        var done: usize = 0;
        while (done < count) {
            const pos: usize = @intCast(@mod(first + @as(i64, @intCast(done)), @as(i64, @intCast(self.hist_cap))));
            const n = @min(count - done, self.hist_cap - pos);
            @memcpy(self.hist[pos * nch ..][0 .. n * nch], samples[done * nch ..][0 .. n * nch]);
            done += n;
        }
        self.dec.add(first, samples);
    }

    /// Sets the layer's drawable size to `width` x `height` pixels (1 to 16384 a side).
    pub fn resize(self: *Gpu, width: u32, height: u32) !void {
        var w: u32 = 0;
        var h: u32 = 0;
        if (ms.ms_renderer_resize(self.r, width, height, &w, &h) != 0) return error.OutOfGpuMemory;
        self.width = w;
        self.height = h;
    }

    /// No drawable yet: `resize` has not been called (nothing can be drawn).
    pub fn unsized(self: *const Gpu) bool {
        return self.width == 0;
    }

    /// The drawable's size in pixels, as the layer had it after `resize` (0 x 0 before).
    pub fn pixelSize(self: *const Gpu) Size {
        return .{ .width = self.width, .height = self.height };
    }

    /// `r` limited to the drawable, or null if nothing of it is on screen.
    fn clip(self: *const Gpu, r: PixelRect) ?PixelRect {
        if (r.x >= self.width or r.y >= self.height or r.w == 0 or r.h == 0) return null;
        return .{ .x = r.x, .y = r.y, .w = @min(r.w, self.width - r.x), .h = @min(r.h, self.height - r.y) };
    }

    /// Draws one frame (each panel in its own viewport, then the fills, then `text`: quads
    /// from a `font.Batch`, over everything) and presents it. `before_present` runs right
    /// before the frame is presented, with the drawable in the target's `drawable` slot.
    /// `.busy` (nothing drawn) when no drawable is free; `.out_of_date` when the layer's
    /// drawable size is no longer what `resize` set.
    pub fn draw(
        self: *Gpu,
        panels: []const PanelDraw,
        fills: []const Fill,
        text: []const font.Vertex,
        context: anytype,
        comptime before_present: fn (@TypeOf(context)) void,
    ) !DrawResult {
        self.takeDirty();
        switch (ms.ms_frame_begin(self.r, &theme.background)) {
            ms.MS_FRAME_OUT_OF_DATE => return .out_of_date,
            ms.MS_FRAME_BUSY => return .busy,
            else => {},
        }
        self.encode(panels, fills, text);
        const Box = struct { c: @TypeOf(context), _: u8 = 0 };
        var box: Box = .{ .c = context };
        const call = struct {
            fn f(p: ?*anyopaque) callconv(.c) void {
                const b: *Box = @ptrCast(@alignCast(p.?));
                before_present(b.c);
            }
        }.f;
        var render_ns: u64 = 0;
        ms.ms_frame_end(self.r, @intFromBool(self.wait_render), &render_ns, call, @ptrCast(&box));
        if (self.wait_render) self.last_render_ns = render_ns;
        return .presented;
    }

    /// `draw` for a Gpu from `initOffscreen`: the same frame, into its texture, committed
    /// and not waited for.
    fn drawOffscreen(self: *Gpu, panels: []const PanelDraw, fills: []const Fill, text: []const font.Vertex) void {
        self.takeDirty();
        _ = ms.ms_frame_begin_offscreen(self.r, &theme.background);
        self.encode(panels, fills, text);
        ms.ms_frame_end_offscreen(self.r);
    }

    /// Waits for the last frame of an offscreen Gpu and copies its pixels into `bgra`
    /// (width x height x 4 bytes, rows top first).
    fn readPixels(self: *Gpu, bgra: []u8) !void {
        if (ms.ms_renderer_read(self.r, bgra.ptr, bgra.len) != 0) return error.WrongSize;
    }

    /// Glyphs drawn on demand since the last frame: their rows, kept until copied.
    fn takeDirty(self: *Gpu) void {
        if (self.text_font) |f| if (f.takeDirty()) |d| {
            self.atlas_pending = if (self.atlas_pending) |p| .{ @min(p[0], d[0]), @max(p[1], d[1]) } else d;
        };
    }

    /// The frame between begin and end: the atlas rows, the panels, the fills, the text.
    /// The last frame is finished (begin waited for it), so the atlas and the text vertex
    /// buffer are free to be written.
    fn encode(self: *Gpu, panels: []const PanelDraw, fills: []const Fill, text: []const font.Vertex) void {
        if (self.atlas_pending) |rows| if (self.text_font) |f| if (self.atlas_size > 0 and f.atlas.len >= @as(usize, self.atlas_size) * self.atlas_size) {
            ms.ms_renderer_atlas_rows(self.r, f.atlas.ptr, rows[0], rows[1]);
        };
        self.atlas_pending = null;
        if (self.hist_cap > 0 and panels.len > 0) {
            var sp: ShaderParams = .{ .params = undefined, .pal = @bitCast(theme.trace) };
            for (panels) |pd| {
                const r = self.clip(pd.rect) orelse continue;
                if (pd.params.rows == 0 or pd.params.cols == 0) continue;
                sp.params = pd.params;
                ms.ms_frame_panel(self.r, r.x, r.y, r.w, r.h, @intFromBool(pd.review), &sp, @sizeOf(ShaderParams), 2 * pd.params.cols, pd.params.rows);
            }
        }
        for (fills) |f| {
            const r = self.clip(f.rect) orelse continue;
            ms.ms_frame_fill(self.r, r.x, r.y, r.w, r.h, &f.colour);
        }
        const ntext = @min(text.len, self.text_vertices.len);
        if (ntext > 0) {
            @memcpy(self.text_vertices[0..ntext], text[0..ntext]);
            ms.ms_frame_text(self.r, @intCast(ntext));
        }
    }
};

// ---- Tests ----
//
// They draw offscreen (`initOffscreen`) and read the pixels back: they need a Metal device
// but no window, and are skipped, saying so, where there is no device. The picture each
// expects is worked out from the GLSL (`shaders/traces.vert`, `text.vert`), which is what
// Linux draws: `shaderY` below is traces.vert's arithmetic, in pixels down from the top of
// the panel (Vulkan's clip space; the Metal shader turns it over only at the end).

const testing = std.testing;

fn skipBecause(comptime why: []const u8) error{SkipZigTest} {
    std.debug.print("skipped: " ++ why ++ "\n", .{});
    return error.SkipZigTest;
}

/// An offscreen Gpu of `w` x `h` pixels and the pixels of its last frame.
const Probe = struct {
    gpu: Gpu,
    /// BGRA, rows top first.
    px: []u8,
    w: u32,
    h: u32,

    fn init(w: u32, h: u32) !Probe {
        var g = Gpu.initOffscreen(testing.allocator, w, h, null) catch |e| switch (e) {
            error.NoMetalDevice => return skipBecause("no Metal device"),
            else => return e,
        };
        errdefer g.deinit();
        const px = try testing.allocator.alloc(u8, @as(usize, w) * h * 4);
        return .{ .gpu = g, .px = px, .w = w, .h = h };
    }

    fn deinit(self: *Probe) void {
        self.gpu.deinit();
        testing.allocator.free(self.px);
    }

    fn render(self: *Probe, panels: []const PanelDraw, fills: []const Fill, text: []const font.Vertex) !void {
        self.gpu.drawOffscreen(panels, fills, text);
        try self.gpu.readPixels(self.px);
    }

    /// The pixel at (x, y), as RGB.
    fn rgb(self: *const Probe, x: u32, y: u32) [3]u8 {
        const i = (@as(usize, y) * self.w + x) * 4;
        return .{ self.px[i + 2], self.px[i + 1], self.px[i] };
    }

    /// Not the background.
    fn lit(self: *const Probe, x: u32, y: u32) bool {
        const c = self.rgb(x, y);
        const b = backgroundRgb();
        for (c, b) |u, v| if (@abs(@as(i32, u) - v) > 2) return true;
        return false;
    }

    /// The first and last lit row of column `x`, and whether every row between is lit.
    fn column(self: *const Probe, x: u32) ?Span {
        var lo: ?u32 = null;
        var hi: u32 = 0;
        var count: u32 = 0;
        for (0..self.h) |y| if (self.lit(x, @intCast(y))) {
            if (lo == null) lo = @intCast(y);
            hi = @intCast(y);
            count += 1;
        };
        const l = lo orelse return null;
        return .{ .lo = l, .hi = hi, .solid = count == hi - l + 1 };
    }

    /// `column` within rows [from, to].
    fn columnBetween(self: *const Probe, x: u32, from: u32, to: u32) ?Span {
        var lo: ?u32 = null;
        var hi: u32 = 0;
        var count: u32 = 0;
        var y = from;
        while (y <= @min(to, self.h - 1)) : (y += 1) if (self.lit(x, y)) {
            if (lo == null) lo = y;
            hi = y;
            count += 1;
        };
        const l = lo orelse return null;
        return .{ .lo = l, .hi = hi, .solid = count == hi - l + 1 };
    }

    fn litCount(self: *const Probe) usize {
        var n: usize = 0;
        for (0..self.h) |y| for (0..self.w) |x| {
            if (self.lit(@intCast(x), @intCast(y))) n += 1;
        };
        return n;
    }
};

const Span = struct { lo: u32, hi: u32, solid: bool };

fn unorm(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

fn backgroundRgb() [3]u8 {
    return .{ unorm(theme.background[0]), unorm(theme.background[1]), unorm(theme.background[2]) };
}

fn traceRgb(ch: usize, gain: f32) [3]u8 {
    const c = theme.trace[ch & 3];
    return .{ unorm(c[0] * gain), unorm(c[1] * gain), unorm(c[2] * gain) };
}

fn expectRgb(want: [3]u8, got: [3]u8) !void {
    for (want, got) |w, g| if (@abs(@as(i32, w) - g) > 1) {
        std.debug.print("colour: want {any}, got {any}\n", .{ want, got });
        return error.TestExpectedEqual;
    };
}

/// Where traces.vert puts value `v` of row `row` (of `rows`) on a panel `h` pixels high, in
/// pixels down from the panel's top.
fn shaderY(rows: u32, row: u32, h: u32, v: f32, per_row: f32) f32 {
    const row_h = 2.0 / @as(f32, @floatFromInt(rows));
    const centre = -1.0 + (@as(f32, @floatFromInt(row)) + 0.5) * row_h;
    const y = centre - std.math.clamp(v / per_row, -1.5, 1.5) * row_h;
    return (y + 1) / 2 * @as(f32, @floatFromInt(h));
}

/// The pixel rows a flat line at `y` (pixels) of half thickness `half` (pixels) lights:
/// those whose centres lie inside it.
fn lineRows(y: f32, half: f32) Span {
    return .{
        .lo = @intFromFloat(@floor(y - half - 0.5) + 1),
        .hi = @intFromFloat(@ceil(y + half - 0.5) - 1),
        .solid = true,
    };
}

fn expectSpan(want: Span, got: ?Span) !void {
    const g = got orelse {
        std.debug.print("nothing lit; want rows {d}..{d}\n", .{ want.lo, want.hi });
        return error.TestExpectedEqual;
    };
    if (g.lo != want.lo or g.hi != want.hi or !g.solid) {
        std.debug.print("lit rows {d}..{d} (solid {}), want {d}..{d}\n", .{ g.lo, g.hi, g.solid, want.lo, want.hi });
        return error.TestExpectedEqual;
    }
}

/// Writes samples [first, first + count) of `nch` channels, sample `s` of channel `c` being
/// `f(s, c)`, through `writeSamples` (so the buckets are filled too).
fn writeAll(g: *Gpu, first: i64, count: usize, comptime f: fn (i64, usize) i16) !void {
    const block = 256;
    const buf = try testing.allocator.alloc(i16, block * g.nch);
    defer testing.allocator.free(buf);
    var done: usize = 0;
    while (done < count) {
        const n = @min(block, count - done);
        for (0..n) |i| for (0..g.nch) |c| {
            buf[i * g.nch + c] = f(first + @as(i64, @intCast(done + i)), c);
        };
        g.writeSamples(first + @as(i64, @intCast(done)), buf[0 .. n * g.nch]);
        done += n;
    }
}

/// A panel over the whole probe: `rows` rows from channel 0, `span` samples ending at
/// `newest`, 1000 units a row, the line 1.5 pixels thick (as the display draws it).
fn panelOf(p: *const Probe, rows: u32, newest: u32, span: f32) PanelDraw {
    return .{
        .rect = .{ .x = 0, .y = 0, .w = p.w, .h = p.h },
        .params = .{
            .nch = @intCast(p.gpu.nch),
            .cap_mask = @intCast(p.gpu.hist_cap - 1),
            .newest = newest,
            .first_ch = 0,
            .cols = p.w,
            .rows = rows,
            .span = span,
            .lsb_per_row = 1000,
            .half_px = 1.5 / @as(f32, @floatFromInt(p.h)),
        },
    };
}

fn constant(comptime v: i16) fn (i64, usize) i16 {
    return struct {
        fn f(s: i64, c: usize) i16 {
            _ = .{ s, c };
            return v;
        }
    }.f;
}

test "metal: the shaders compile (time printed); a broken one fails with the compiler's message" {
    var err: [4096]u8 = undefined;
    const ctx = Gpu.makeContext(msl_source, &err) catch |e| switch (e) {
        error.NoMetalDevice => return skipBecause("no Metal device"),
        else => {
            std.debug.print("{s}\n", .{std.mem.sliceTo(&err, 0)});
            return e;
        },
    };
    var name: [256]u8 = undefined;
    var max_buffer: u64 = 0;
    var working_set: u64 = 0;
    var compile_ms: f64 = 0;
    ms.ms_context_info(ctx, &name, name.len, &max_buffer, &working_set, &compile_ms);
    ms.ms_context_destroy(ctx);
    std.debug.print("Metal: {s}, shaders compiled in {d:.1} ms, largest buffer {d} bytes, working set {d} bytes\n", .{ std.mem.sliceTo(&name, 0), compile_ms, max_buffer, working_set });

    // A shader that reads a field the struct does not have.
    const broken = try std.mem.replaceOwned(u8, testing.allocator, msl_source, "p.half_px", "p.half_pix");
    defer testing.allocator.free(broken);
    try testing.expectError(error.ShaderCompile, Gpu.makeContext(broken, &err));
    const msg = std.mem.sliceTo(&err, 0);
    try testing.expect(std.mem.indexOf(u8, msg, "half_pix") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "error") != null);
}

test "metal: one channel at a constant value draws a horizontal line at the row of its value" {
    var p = try Probe.init(64, 100);
    defer p.deinit();
    try p.gpu.createHistory(1, 4096, 4096, 4096);
    try writeAll(&p.gpu, 0, 4096, constant(200));
    try p.render(&.{panelOf(&p, 1, 4096, 256)}, &.{}, &.{});
    // 200 units at 1000 a row: 0.2 rows up from the centre, pixel 30 of 100.
    const want = lineRows(shaderY(1, 0, 100, 200, 1000), 0.75);
    try testing.expectEqual(Span{ .lo = 29, .hi = 30, .solid = true }, want);
    for (1..63) |x| {
        try expectSpan(want, p.column(@intCast(x)));
        try expectRgb(traceRgb(0, 1), p.rgb(@intCast(x), 30));
    }
    // Nothing else (the two end columns are cut at their pixel centres).
    try testing.expect(p.litCount() <= 2 * 64);
}

test "metal: a step draws a vertical join between the two levels" {
    var p = try Probe.init(64, 100);
    defer p.deinit();
    try p.gpu.createHistory(1, 4096, 4096, 4096);
    // 0 before sample 3968, 400 from it on; the window is samples 3840 to 4095, 4 a column:
    // the step is the end of column 31.
    try writeAll(&p.gpu, 0, 4096, struct {
        fn f(s: i64, _: usize) i16 {
            return if (s < 3968) 0 else 400;
        }
    }.f);
    try p.render(&.{panelOf(&p, 1, 4096, 256)}, &.{}, &.{});
    const low = lineRows(shaderY(1, 0, 100, 0, 1000), 0.75);
    const high = lineRows(shaderY(1, 0, 100, 400, 1000), 0.75);
    try expectSpan(low, p.column(20));
    try expectSpan(high, p.column(45));
    try expectSpan(.{ .lo = high.lo, .hi = low.hi, .solid = true }, p.column(31));
}

test "metal: a sine stays inside its row's band, and reaches across most of it" {
    var p = try Probe.init(128, 200);
    defer p.deinit();
    try p.gpu.createHistory(4, 4096, 4096, 4096);
    // Amplitude 0.45 of a row: the band of each of the 4 rows is 50 pixels, the sine
    // reaches 22.5 pixels above and below its centre.
    try writeAll(&p.gpu, 0, 4096, struct {
        fn f(s: i64, c: usize) i16 {
            const t: f32 = @floatFromInt(s + @as(i64, @intCast(c)) * 9);
            return @intFromFloat(@round(450 * @sin(t * std.math.tau / 64)));
        }
    }.f);
    try p.render(&.{panelOf(&p, 4, 4096, 1024)}, &.{}, &.{});
    var lo: [4]u32 = @splat(std.math.maxInt(u32));
    var hi: [4]u32 = @splat(0);
    for (0..200) |y| for (1..127) |x| {
        if (!p.lit(@intCast(x), @intCast(y))) continue;
        // Which channel: by colour (the four rows have the four colours).
        const got = p.rgb(@intCast(x), @intCast(y));
        const ch = for (0..4) |k| {
            const want = traceRgb(k, 1);
            if (@abs(@as(i32, want[0]) - got[0]) <= 1 and @abs(@as(i32, want[1]) - got[1]) <= 1 and @abs(@as(i32, want[2]) - got[2]) <= 1) break k;
        } else return error.UnknownColour;
        try testing.expect(y >= ch * 50 and y < (ch + 1) * 50);
        lo[ch] = @min(lo[ch], @as(u32, @intCast(y)));
        hi[ch] = @max(hi[ch], @as(u32, @intCast(y)));
    };
    for (0..4) |k| {
        const centre: u32 = @intCast(k * 50 + 25);
        try testing.expect(lo[k] <= centre - 21 and lo[k] >= centre - 24);
        try testing.expect(hi[k] >= centre + 21 and hi[k] <= centre + 23);
    }
}

test "metal: many channels land in their own rows, in order" {
    var p = try Probe.init(64, 160);
    defer p.deinit();
    try p.gpu.createHistory(8, 1024, 1024, 1024);
    // Channel k at (k - 3.5) x 100 units: each row's line sits at its own offset.
    try writeAll(&p.gpu, 0, 1024, struct {
        fn f(_: i64, c: usize) i16 {
            return @as(i16, @intCast(c)) * 100 - 350;
        }
    }.f);
    try p.render(&.{panelOf(&p, 8, 1024, 256)}, &.{}, &.{});
    var seen: usize = 0;
    var y: u32 = 0;
    while (y < 160) : (y += 1) {
        if (!p.lit(32, y)) continue;
        const k = seen;
        const want = lineRows(shaderY(8, @intCast(k), 160, @as(f32, @floatFromInt(k)) * 100 - 350, 1000), 0.75);
        try testing.expectEqual(want.lo, y);
        try expectSpan(want, p.columnBetween(32, want.lo -| 3, want.hi + 3));
        try expectRgb(traceRgb(k, 1), p.rgb(32, y));
        y = want.hi;
        seen += 1;
    }
    try testing.expectEqual(8, seen);
}

/// The pixel columns in which the trace rises above `above` (a pixel row): where a spike is.
fn spikeColumns(p: *const Probe, above: u32, out: []u32) []u32 {
    var n: usize = 0;
    for (0..p.w) |x| {
        const s = p.column(@intCast(x)) orelse continue;
        if (s.lo < above and n < out.len) {
            out[n] = @intCast(x);
            n += 1;
        }
    }
    return out[0..n];
}

/// Zero everywhere but sample 4076 (20 before the newest of the windows below) and 4046
/// (50 before), which are 800.
fn twoSpikes(s: i64, _: usize) i16 {
    return if (s == 4076 or s == 4046) 800 else 0;
}

test "metal: first_ch: row 0 draws that channel, in its colour" {
    var p = try Probe.init(64, 100);
    defer p.deinit();
    try p.gpu.createHistory(4, 1024, 1024, 1024);
    try writeAll(&p.gpu, 0, 1024, struct {
        fn f(_: i64, c: usize) i16 {
            return @as(i16, @intCast(c)) * 100;
        }
    }.f);
    for ([_]u32{ 0, 2 }) |first| {
        var d = panelOf(&p, 1, 1024, 256);
        d.params.first_ch = first;
        try p.render(&.{d}, &.{}, &.{});
        const want = lineRows(shaderY(1, 0, 100, @floatFromInt(first * 100), 1000), 0.75);
        try expectSpan(want, p.column(30));
        try expectRgb(traceRgb(first, 1), p.rgb(30, want.lo));
    }
}

test "metal: rows: row k's centre is (k + 1/2) / rows of the panel" {
    var p = try Probe.init(64, 100);
    defer p.deinit();
    try p.gpu.createHistory(2, 1024, 1024, 1024);
    try writeAll(&p.gpu, 0, 1024, constant(0));
    try p.render(&.{panelOf(&p, 1, 1024, 256)}, &.{}, &.{});
    try expectSpan(lineRows(50, 0.75), p.column(30));
    try p.render(&.{panelOf(&p, 2, 1024, 256)}, &.{}, &.{});
    try expectSpan(lineRows(25, 0.75), p.columnBetween(30, 0, 49));
    try expectSpan(lineRows(75, 0.75), p.columnBetween(30, 50, 99));
}

test "metal: cols: the strip has a vertex at the centre of each of `cols` columns of the viewport" {
    var p = try Probe.init(64, 100);
    defer p.deinit();
    try p.gpu.createHistory(1, 1024, 1024, 1024);
    try writeAll(&p.gpu, 0, 1024, constant(0));
    // 16 columns over 64 pixels: the first vertex at x = 2, the last at x = 62.
    var d = panelOf(&p, 1, 1024, 256);
    d.params.cols = 16;
    try p.render(&.{d}, &.{}, &.{});
    try testing.expect(p.column(1) == null);
    try expectSpan(lineRows(50, 0.75), p.column(2));
    try expectSpan(lineRows(50, 0.75), p.column(61));
    try testing.expect(p.column(62) == null);
}

test "metal: span: a spike 20 samples before the newest is 20 / span of the way from the right" {
    var p = try Probe.init(64, 100);
    defer p.deinit();
    try p.gpu.createHistory(1, 4096, 4096, 4096);
    try writeAll(&p.gpu, 0, 4096, struct {
        fn f(s: i64, _: usize) i16 {
            return if (s == 4076) 800 else 0;
        }
    }.f);
    var buf: [64]u32 = undefined;
    // 64 samples: columns 43 (its end) and 44 (its start) hold sample 4076.
    try p.render(&.{panelOf(&p, 1, 4096, 64)}, &.{}, &.{});
    try testing.expectEqualSlices(u32, &.{ 43, 44 }, spikeColumns(&p, 40, &buf));
    // 128 samples, 2 a column: columns 53 and 54.
    try p.render(&.{panelOf(&p, 1, 4096, 128)}, &.{}, &.{});
    try testing.expectEqualSlices(u32, &.{ 53, 54 }, spikeColumns(&p, 40, &buf));
}

test "metal: lsb_per_row: the same value twice as far from the centre at half the units a row" {
    var p = try Probe.init(64, 100);
    defer p.deinit();
    try p.gpu.createHistory(1, 1024, 1024, 1024);
    try writeAll(&p.gpu, 0, 1024, constant(200));
    var d = panelOf(&p, 1, 1024, 256);
    try p.render(&.{d}, &.{}, &.{});
    try expectSpan(lineRows(30, 0.75), p.column(30));
    d.params.lsb_per_row = 500;
    try p.render(&.{d}, &.{}, &.{});
    try expectSpan(lineRows(10, 0.75), p.column(30));
}

test "metal: half_px: the line is 2 x half_px thick" {
    var p = try Probe.init(64, 100);
    defer p.deinit();
    try p.gpu.createHistory(1, 1024, 1024, 1024);
    try writeAll(&p.gpu, 0, 1024, constant(200));
    var d = panelOf(&p, 1, 1024, 256);
    d.params.half_px = 4.5 / 100.0;
    try p.render(&.{d}, &.{}, &.{});
    // 2.25 pixels each side of pixel 30.
    try expectSpan(.{ .lo = 28, .hi = 31, .solid = true }, p.column(30));
    try expectSpan(lineRows(30, 2.25), p.column(30));
}

test "metal: gain: the colour times gain" {
    var p = try Probe.init(64, 100);
    defer p.deinit();
    try p.gpu.createHistory(1, 1024, 1024, 1024);
    try writeAll(&p.gpu, 0, 1024, constant(0));
    var d = panelOf(&p, 1, 1024, 256);
    d.params.gain = 0.5;
    try p.render(&.{d}, &.{}, &.{});
    try expectRgb(traceRgb(0, 0.5), p.rgb(30, 50));
}

test "metal: row gains: the row's factor from gain_base scales its rows' units" {
    var p = try Probe.init(64, 100);
    defer p.deinit();
    try p.gpu.createHistory(1, 1024, 1024, 1024);
    try writeAll(&p.gpu, 0, 1024, constant(200));
    p.gpu.row_gains[max_rows] = 2;
    var d = panelOf(&p, 1, 1024, 256);
    try p.render(&.{d}, &.{}, &.{});
    try expectSpan(lineRows(30, 0.75), p.column(30));
    // Panel 1's first row: 2000 units a row, 0.1 rows up.
    d.params.gain_base = max_rows;
    try p.render(&.{d}, &.{}, &.{});
    try expectSpan(lineRows(40, 0.75), p.column(30));
}

test "metal: future: columns not yet reached are not drawn" {
    var p = try Probe.init(64, 100);
    defer p.deinit();
    try p.gpu.createHistory(1, 1024, 1024, 1024);
    try writeAll(&p.gpu, 0, 1024, constant(0));
    var d = panelOf(&p, 1, 1024, 64);
    try p.render(&.{d}, &.{}, &.{});
    try expectSpan(lineRows(50, 0.75), p.column(40));
    // Half the window in the future: the columns after 31 fold onto it.
    d.params.future = 32;
    try p.render(&.{d}, &.{}, &.{});
    try expectSpan(lineRows(50, 0.75), p.column(30));
    for (32..64) |x| try testing.expect(p.column(@intCast(x)) == null);
}

test "metal: phase: a sweep puts this pass left of the cursor and the last pass right of it" {
    var p = try Probe.init(64, 100);
    defer p.deinit();
    try p.gpu.createHistory(1, 4096, 4096, 4096);
    try writeAll(&p.gpu, 0, 4096, twoSpikes);
    var buf: [64]u32 = undefined;
    // Scrolling, one sample a column: 20 before the newest at columns 43-44, 50 before at
    // 13-14.
    var d = panelOf(&p, 1, 4096, 64);
    try p.render(&.{d}, &.{}, &.{});
    try testing.expectEqualSlices(u32, &.{ 13, 14, 43, 44 }, spikeColumns(&p, 40, &buf));
    // Sweeping, the cursor 30 samples into the pass: 20 before the newest is in this pass
    // at columns 9-10; 50 before is in the last pass, at 43-44.
    d.params.phase = 30;
    try p.render(&.{d}, &.{}, &.{});
    try testing.expectEqualSlices(u32, &.{ 9, 10, 43, 44 }, spikeColumns(&p, 40, &buf));
}

/// Constant over each 64 samples (from -300 to 300 by blocks), with spikes inside some
/// blocks (+700 at the 30th sample of every third, -700 at the 34th of every fifth): no
/// spike near a block's ends, so a column of 64 samples holds the same minimum and maximum
/// whether read sample by sample or by buckets.
fn blocks(s: i64, _: usize) i16 {
    const b = @divFloor(s, 64);
    const in = @mod(s, 64);
    if (@mod(b, 3) == 0 and in == 30) return 700;
    if (@mod(b, 5) == 0 and in == 34) return -700;
    return @intCast((@mod(b * 37, 11) - 5) * 60);
}

test "metal: samples, buckets and review columns of the same data light the same pixels" {
    var p = try Probe.init(64, 100);
    defer p.deinit();
    const newest = 65536;
    try p.gpu.createHistory(1, 8192, 8192, 1 << 16);
    try writeAll(&p.gpu, newest - 8192, 8192, blocks);
    try p.gpu.createReview();
    // Review columns of panel 0: what traces.vert's sample path takes into column c,
    // samples [fa, fb] (fb, the next column's first, included), none at or after newest.
    const span = 64 * 64;
    for (0..64) |c| {
        const fa: i64 = newest - span + @as(i64, @intCast(c)) * 64;
        var lo: i16 = std.math.maxInt(i16);
        var hi: i16 = std.math.minInt(i16);
        var s = fa;
        while (s <= @min(fa + 64, newest - 1)) : (s += 1) {
            lo = @min(lo, blocks(s, 0));
            hi = @max(hi, blocks(s, 0));
        }
        p.gpu.rev_cols[c] = @as(u32, @as(u16, @bitCast(lo))) | @as(u32, @as(u16, @bitCast(hi))) << 16;
    }

    const images = try testing.allocator.alloc(u8, 3 * p.px.len);
    defer testing.allocator.free(images);
    var d = panelOf(&p, 1, newest, span);
    d.params.lsb_per_row = 2000;
    // From samples.
    try p.render(&.{d}, &.{}, &.{});
    @memcpy(images[0..p.px.len], p.px);
    // From buckets (64 samples a column: as many as `bucket_cols`).
    d.params.dec_mask = @intCast(p.gpu.dec.cap - 1);
    try p.render(&.{d}, &.{}, &.{});
    @memcpy(images[p.px.len..][0..p.px.len], p.px);
    // From the review columns.
    d.params.dec_mask = gpu.from_columns;
    d.params.newest = 0;
    d.review = true;
    try p.render(&.{d}, &.{}, &.{});
    @memcpy(images[2 * p.px.len ..], p.px);

    try testing.expectEqualSlices(u8, images[0..p.px.len], images[p.px.len..][0..p.px.len]);
    try testing.expectEqualSlices(u8, images[0..p.px.len], images[2 * p.px.len ..]);
    // And the picture is the data's: each pixel column (at its vertex) spans its minimum
    // to its maximum; some have spikes.
    var spikes: usize = 0;
    for (1..63) |c| {
        const w = p.gpu.rev_cols[c];
        const lo: f32 = @floatFromInt(decimate.minOf(w));
        const hi: f32 = @floatFromInt(decimate.maxOf(w));
        if (hi == 700) spikes += 1;
        try expectSpan(.{
            .lo = lineRows(shaderY(1, 0, 100, hi, 2000), 0.75).lo,
            .hi = lineRows(shaderY(1, 0, 100, lo, 2000), 0.75).hi,
            .solid = true,
        }, p.column(@intCast(c)));
    }
    try testing.expect(spikes >= 15);
}

test "metal: the ring wraps: data written across the end of the history draws continuously" {
    var p = try Probe.init(64, 200);
    defer p.deinit();
    try p.gpu.createHistory(1, 1024, 1024, 1024);
    try testing.expectEqual(1024, p.gpu.hist_cap);
    // A ramp of 10 units a sample through samples 986 to 1049: ring positions 986 to 1023,
    // then 0 to 25. One sample a column, 2 pixels a sample.
    const ramp = struct {
        fn f(s: i64, _: usize) i16 {
            return @intCast((s - 1018) * 10);
        }
    }.f;
    try writeAll(&p.gpu, 0, 1050, ramp);
    try p.render(&.{panelOf(&p, 1, 1050, 64)}, &.{}, &.{});
    for (1..63) |x| {
        // Column x spans samples 986 + x and 987 + x.
        const s: i64 = 986 + @as(i64, @intCast(x));
        const top = shaderY(1, 0, 200, @floatFromInt(ramp(s + 1, 0)), 1000);
        const bottom = shaderY(1, 0, 200, @floatFromInt(ramp(s, 0)), 1000);
        const got = p.column(@intCast(x)) orelse {
            std.debug.print("x {d}: nothing lit; want {d:.2} to {d:.2}\n", .{ x, top, bottom });
            return error.TestExpectedEqual;
        };
        try testing.expect(got.solid);
        try testing.expect(@abs(@as(f32, @floatFromInt(got.lo)) - (top - 0.75)) <= 1.0);
        try testing.expect(@abs(@as(f32, @floatFromInt(got.hi)) - (bottom + 0.75)) <= 1.0);
    }
}

test "metal: nothing at or after newest is read" {
    var p = try Probe.init(64, 100);
    defer p.deinit();
    try p.gpu.createHistory(1, 1024, 1024, 1024);
    // 0 in the 128 samples before the newest (600), the largest value everywhere else in
    // the ring, sample 600 included.
    try writeAll(&p.gpu, 0, 1024, struct {
        fn f(s: i64, _: usize) i16 {
            return if (s >= 472 and s < 600) 0 else std.math.maxInt(i16);
        }
    }.f);
    // One sample a column; fewer samples than columns (the last column's start lies
    // between the last sample and the newest); a sweep with the cursor between two
    // samples; and 32 columns over the 64 pixels, so that the last column's own vertex
    // is not on a pixel's centre but the slope up to it crosses one.
    for ([_][3]f32{ .{ 64, -1, 64 }, .{ 40, -1, 64 }, .{ 64, 30.5, 64 }, .{ 64, -1, 32 } }) |case| {
        var d = panelOf(&p, 1, 600, case[0]);
        d.params.phase = case[1];
        d.params.cols = @intFromFloat(case[2]);
        try p.render(&.{d}, &.{}, &.{});
        for (2..63) |x| try expectSpan(lineRows(50, 0.75), p.column(@intCast(x)));
    }
}

test "metal: off scale: a dashed line near the edge of the row it left by" {
    var p = try Probe.init(64, 100);
    defer p.deinit();
    try p.gpu.createHistory(2, 1024, 1024, 1024);
    // Channel 0 at 2 rows up, channel 1 at 2 rows down (beyond 1.5 rows).
    try writeAll(&p.gpu, 0, 1024, struct {
        fn f(_: i64, c: usize) i16 {
            return if (c == 0) 2000 else -2000;
        }
    }.f);
    var d = panelOf(&p, 1, 1024, 256);
    for ([_]u32{ 0, 1 }) |ch| {
        d.params.first_ch = ch;
        try p.render(&.{d}, &.{}, &.{});
        // 0.42 rows from the centre: pixel 8 (above) or 92 (below) of 100.
        const edge: f32 = if (ch == 0) 8 else 92;
        // Dashes: columns 0-3, 8-11, ... drawn 1.5 pixels thick; the others not at all.
        for ([_]u32{ 1, 2, 9, 10, 17, 18 }) |x| try expectSpan(lineRows(edge, 0.75), p.column(x));
        for ([_]u32{ 5, 6, 13, 14, 21, 22 }) |x| try testing.expect(p.column(x) == null);
    }
}

test "metal: a panel draws inside its rectangle only" {
    var p = try Probe.init(128, 100);
    defer p.deinit();
    try p.gpu.createHistory(1, 4096, 4096, 4096);
    // Swinging 3 rows each way: clipped at 1.5 rows, beyond the panel's 40 pixels.
    try writeAll(&p.gpu, 0, 4096, struct {
        fn f(s: i64, _: usize) i16 {
            return if (@mod(s, 8) < 4) 3000 else -3000;
        }
    }.f);
    var d = panelOf(&p, 1, 4096, 256);
    d.rect = .{ .x = 32, .y = 20, .w = 64, .h = 40 };
    d.params.cols = 64;
    d.params.half_px = 1.5 / 40.0;
    try p.render(&.{d}, &.{}, &.{});
    var inside: usize = 0;
    for (0..100) |y| for (0..128) |x| {
        if (!p.lit(@intCast(x), @intCast(y))) continue;
        try testing.expect(x >= 32 and x < 96 and y >= 20 and y < 60);
        inside += 1;
    };
    // The envelope fills the panel from top to bottom.
    try testing.expect(inside > 60 * 40);
}

fn inRect(r: PixelRect, x: usize, y: usize) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
}

test "metal: fills replace exactly their rectangles with their colours, over the panels" {
    var p = try Probe.init(64, 64);
    defer p.deinit();
    try p.gpu.createHistory(1, 1024, 1024, 1024);
    try writeAll(&p.gpu, 0, 1024, constant(0));
    // The trace across rows 31 and 32; one fill over part of it, one cut by the
    // drawable's edge, one empty.
    const a: PixelRect = .{ .x = 10, .y = 20, .w = 20, .h = 20 };
    const b: PixelRect = .{ .x = 50, .y = 40, .w = 30, .h = 30 };
    const fills = [_]Fill{
        .{ .rect = a, .colour = .{ 1, 0, 0, 1 } },
        .{ .rect = b, .colour = .{ 0, 0.5, 1, 1 } },
        .{ .rect = .{ .x = 0, .y = 0, .w = 0, .h = 5 }, .colour = .{ 1, 1, 1, 1 } },
    };
    try p.render(&.{panelOf(&p, 1, 1024, 256)}, &fills, &.{});
    for (0..64) |y| for (0..64) |x| {
        const got = p.rgb(@intCast(x), @intCast(y));
        if (inRect(a, x, y)) {
            try expectRgb(.{ 255, 0, 0 }, got);
        } else if (inRect(b, x, y)) {
            try expectRgb(.{ 0, 128, 255 }, got);
        } else if ((y == 31 or y == 32) and x >= 1 and x < 63) {
            try expectRgb(traceRgb(0, 1), got);
        } else if (x >= 1 and x < 63) {
            try expectRgb(backgroundRgb(), got);
        }
    };
}

test "metal: text quads land where their vertices say, over the fills, with the atlas's coverage" {
    var p = try Probe.init(64, 64);
    defer p.deinit();
    // A 64 x 64 atlas: the full block in the corner (as font.zig's), and an 8 x 8 "glyph"
    // at (8, 8) whose coverage rises across and down.
    var atlas: [64 * 64]u8 = @splat(0);
    for (0..4) |y| @memset(atlas[y * 64 ..][0..4], 255);
    for (0..8) |y| for (0..8) |x| {
        atlas[(8 + y) * 64 + 8 + x] = @intCast((y * 8 + x) * 4);
    };
    try p.gpu.createText(&atlas, 64, 64);
    const blue: PixelRect = .{ .x = 16, .y = 16, .w = 16, .h = 16 };
    var batch_vertices: [64]font.Vertex = undefined;
    const t = 2.0 / 64.0;
    const red: font.Colour = .{ 255, 0, 0, 255 };
    const quads = [_]struct { x0: f32, y0: f32, x1: f32, y1: f32, uv0: [2]f32, uv1: [2]f32, c: font.Colour }{
        // The glyph at (20, 20), one texel a pixel, over the blue fill.
        .{ .x0 = 20, .y0 = 20, .x1 = 28, .y1 = 28, .uv0 = .{ 8.0 / 64.0, 8.0 / 64.0 }, .uv1 = .{ 16.0 / 64.0, 16.0 / 64.0 }, .c = red },
        // A half-transparent green rectangle (`Batch.rect`) on the background.
        .{ .x0 = 40, .y0 = 44, .x1 = 46, .y1 = 47, .uv0 = .{ t, t }, .uv1 = .{ t, t }, .c = .{ 0, 255, 0, 128 } },
    };
    var n: usize = 0;
    for (quads) |q| {
        const v = batch_vertices[n..][0..6];
        v[0] = .{ .pos = .{ q.x0, q.y0 }, .uv = q.uv0, .colour = q.c };
        v[1] = .{ .pos = .{ q.x1, q.y0 }, .uv = .{ q.uv1[0], q.uv0[1] }, .colour = q.c };
        v[2] = .{ .pos = .{ q.x1, q.y1 }, .uv = q.uv1, .colour = q.c };
        v[3] = v[0];
        v[4] = v[2];
        v[5] = .{ .pos = .{ q.x0, q.y1 }, .uv = .{ q.uv0[0], q.uv1[1] }, .colour = q.c };
        n += 6;
    }
    try p.render(&.{}, &.{.{ .rect = blue, .colour = .{ 0, 0, 1, 1 } }}, batch_vertices[0..n]);
    const bg = backgroundRgb();
    for (0..64) |y| for (0..64) |x| {
        const got = p.rgb(@intCast(x), @intCast(y));
        if (x >= 20 and x < 28 and y >= 20 and y < 28) {
            const cov: f32 = @floatFromInt(atlas[(8 + y - 20) * 64 + 8 + x - 20]);
            const a = cov / 255;
            try expectRgb(.{ unorm(a), 0, unorm(1 - a) }, got);
        } else if (inRect(blue, x, y)) {
            try expectRgb(.{ 0, 0, 255 }, got);
        } else if (x >= 40 and x < 46 and y >= 44 and y < 47) {
            const a: f32 = 128.0 / 255.0;
            const bgf = [3]f32{ theme.background[0], theme.background[1], theme.background[2] };
            try expectRgb(.{ unorm(bgf[0] * (1 - a)), unorm(a + bgf[1] * (1 - a)), unorm(bgf[2] * (1 - a)) }, got);
        } else {
            try expectRgb(bg, got);
        }
    };
}

test "metal: a glyph drawn into the atlas after the first frame shows in the next" {
    var f = font.Font.init(testing.allocator, "sans-serif", 14) catch return skipBecause("no sans-serif font");
    defer f.deinit(testing.allocator);
    const e = f.engine orelse return skipBecause("no text shaping (HarfBuzz) to draw a glyph on demand");
    var p = try Probe.init(64, 64);
    defer p.deinit();
    try p.gpu.createText(f.atlas, font.atlas_size, 64);
    p.gpu.textFont(&f);
    try p.render(&.{}, &.{}, &.{});
    // U+0142 is not among the glyphs made at start-up: laying it out draws it into the
    // atlas and marks its rows.
    const shaped = e.layout(f.atlas, "\u{142}") orelse return error.ShapingFailed;
    const g = shaped.glyphs[0].g;
    try testing.expect(g.w > 0 and g.h > 0 and g.w < 40 and g.h < 40);
    const size: f32 = font.atlas_size;
    const white: font.Colour = .{ 255, 255, 255, 255 };
    const x0: f32 = 10;
    const y0: f32 = 10;
    const x1 = x0 + @as(f32, @floatFromInt(g.w));
    const y1 = y0 + @as(f32, @floatFromInt(g.h));
    const uv0 = [2]f32{ @as(f32, @floatFromInt(g.x)) / size, @as(f32, @floatFromInt(g.y)) / size };
    const uv1 = [2]f32{ @as(f32, @floatFromInt(g.x + g.w)) / size, @as(f32, @floatFromInt(g.y + g.h)) / size };
    const v = [6]font.Vertex{
        .{ .pos = .{ x0, y0 }, .uv = uv0, .colour = white },
        .{ .pos = .{ x1, y0 }, .uv = .{ uv1[0], uv0[1] }, .colour = white },
        .{ .pos = .{ x1, y1 }, .uv = uv1, .colour = white },
        .{ .pos = .{ x0, y0 }, .uv = uv0, .colour = white },
        .{ .pos = .{ x1, y1 }, .uv = uv1, .colour = white },
        .{ .pos = .{ x0, y1 }, .uv = .{ uv0[0], uv1[1] }, .colour = white },
    };
    try p.render(&.{}, &.{}, &v);
    try testing.expectEqual(null, p.gpu.atlas_pending);
    var inked: usize = 0;
    for (0..g.h) |y| for (0..g.w) |x| {
        const cov: f32 = @floatFromInt(f.atlas[(g.y + y) * font.atlas_size + g.x + x]);
        if (cov > 0) inked += 1;
        const a = cov / 255;
        const want = unorm(theme.background[0] * (1 - a) + a);
        try expectRgb(.{ want, unorm(theme.background[1] * (1 - a) + a), unorm(theme.background[2] * (1 - a) + a) }, p.rgb(@intCast(10 + x), @intCast(10 + y)));
    };
    try testing.expect(inked > 10);
}

test "metal: histories made twice with different shapes, review made and dropped, deinit: nothing left" {
    const gpa = testing.allocator;
    var parent = Gpu.initOffscreen(gpa, 8, 8, null) catch |e| switch (e) {
        error.NoMetalDevice => return skipBecause("no Metal device"),
        else => return e,
    };
    defer parent.deinit();
    var atlas: [64 * 64]u8 = @splat(255);
    const live0 = ms.ms_live_objects();
    const bytes0 = ms.ms_context_allocated(parent.ctx);
    var bytes_in_use: u64 = 0;
    for (0..3) |_| {
        var g = try Gpu.initOffscreen(gpa, 64, 48, &parent);
        try testing.expectEqual(live0 + 1, ms.ms_live_objects());
        try g.createText(&atlas, 64, 600);
        try g.createHistory(4, 1 << 16, 1 << 14, 1 << 17);
        try writeAll(&g, 0, 1000, constant(5));
        try g.createReview();
        const one = [_]PanelDraw{.{ .rect = .{ .x = 0, .y = 0, .w = 64, .h = 48 }, .params = .{ .nch = 4, .cap_mask = 0xFFFF, .newest = 1000, .first_ch = 0, .cols = 64, .rows = 4, .span = 500, .lsb_per_row = 100, .half_px = 0.03 } }};
        g.drawOffscreen(&one, &.{}, &.{});
        try g.createHistory(7, 1 << 15, 1 << 12, 1 << 16);
        try testing.expectEqual(0, g.rev.len);
        try g.createReview();
        g.destroyReview();
        try g.createReview();
        g.drawOffscreen(&one, &.{}, &.{});
        bytes_in_use = ms.ms_context_allocated(parent.ctx);
        g.deinit();
        try testing.expectEqual(live0, ms.ms_live_objects());
        try testing.expectEqual(bytes0, ms.ms_context_allocated(parent.ctx));
    }
    // The check means something: the Gpu had a few MB while it was alive.
    try testing.expect(bytes_in_use > bytes0 + 1_000_000);
}

test "metal: drawing to a layer: the drawable in the slot for before_present only; out of date when its size changed" {
    const gpa = testing.allocator;
    const layer = ms.ms_test_layer_create() orelse return error.NoLayer;
    defer ms.ms_test_layer_release(layer);
    var slot: ?*anyopaque = null;
    var g = Gpu.init(gpa, .{ .layer = layer, .drawable = &slot }, .immediate, null) catch |e| switch (e) {
        error.NoMetalDevice => return skipBecause("no Metal device"),
        else => return e,
    };
    defer g.deinit();
    try testing.expect(g.unsized());
    try g.resize(64, 48);
    try testing.expectEqual(Size{ .width = 64, .height = 48 }, g.pixelSize());

    const Seen = struct { slot: *?*anyopaque, drawable: ?*anyopaque = null, calls: u32 = 0 };
    var seen: Seen = .{ .slot = &slot };
    const before = struct {
        fn f(s: *Seen) void {
            s.drawable = s.slot.*;
            s.calls += 1;
        }
    }.f;
    // For 200 ms, as a free-running display loop does: draw, and on `.busy` try again
    // shortly. No call waits for a drawable.
    const io = testing.io;
    var presented: u32 = 0;
    var busy: u32 = 0;
    var longest_ns: i128 = 0;
    const t0 = os.nowNs();
    while (os.nowNs() - t0 < 200 * std.time.ns_per_ms) {
        const a = os.nowNs();
        const r = try g.draw(&.{}, &.{}, &.{}, &seen, before);
        longest_ns = @max(longest_ns, os.nowNs() - a);
        try testing.expectEqual(null, slot);
        switch (r) {
            .presented => {
                presented += 1;
                try testing.expectEqual(presented, seen.calls);
                try testing.expect(seen.drawable != null);
                seen.drawable = null;
            },
            .busy => {
                busy += 1;
                try testing.expectEqual(presented, seen.calls);
            },
            .out_of_date => return error.TestUnexpectedResult,
        }
        try io.sleep(.fromMicroseconds(500), .awake);
    }
    std.debug.print("bare layer, 200 ms: {d} presented, {d} busy; longest draw {d:.2} ms\n", .{
        presented, busy, @as(f64, @floatFromInt(longest_ns)) / 1e6,
    });
    try testing.expect(presented >= 5);
    // No draw waits for a drawable: 3 ms is far above what one takes on a Mac's own GPU.
    // Not asked of a CI machine (the environment's `CI`): GitHub's runner draws through
    // "Apple Paravirtual device" and took 5.61 ms once (2026-11-24) with nothing waiting.
    if (std.c.getenv("CI") == null) try testing.expect(longest_ns < 3 * std.time.ns_per_ms);

    // With wait_render: the time the GPU took.
    g.wait_render = true;
    while (try g.draw(&.{}, &.{}, &.{}, &seen, before) != .presented) try io.sleep(.fromMicroseconds(500), .awake);
    try testing.expect(g.last_render_ns > 0);
    g.wait_render = false;

    // The layer's size changed behind the Gpu's back: out of date, nothing drawn.
    ms.ms_test_layer_set_size(layer, 100, 100);
    const calls = seen.calls;
    try testing.expectEqual(.out_of_date, try g.draw(&.{}, &.{}, &.{}, &seen, before));
    try testing.expectEqual(calls, seen.calls);
    try g.resize(100, 100);
    try testing.expectEqual(Size{ .width = 100, .height = 100 }, g.pixelSize());
}

// A speed check, not a test that can fail on a busy machine: off unless DIMNA_GPU_SPEED=1.
// Frames like the rig's, offscreen at 3456 x 2234: two panels side by side, 32 or 128
// channels, time bases of 1 s (17 samples a pixel column: from samples) and 10 s (174: from
// buckets), with 500 text quads and 10 fills. Prints, per case, the median and worst over
// 300 frames of the time to encode (CPU, begin to commit), of the GPU's own time, and of
// the whole frame (begin until the GPU is done).
test "metal: speed of a frame like the rig's (DIMNA_GPU_SPEED=1)" {
    const on = std.c.getenv("DIMNA_GPU_SPEED") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, std.mem.span(on), "1")) return error.SkipZigTest;
    const gpa = testing.allocator;
    const w = 3456;
    const h = 2234;
    var g = Gpu.initOffscreen(gpa, w, h, null) catch |e| switch (e) {
        error.NoMetalDevice => return skipBecause("no Metal device"),
        else => return e,
    };
    defer g.deinit();
    var atlas: [64 * 64]u8 = @splat(255);
    try g.createText(&atlas, 64, 3000);
    var verts: [3000]font.Vertex = undefined;
    var batch: font.Batch = .{ .font = undefined, .vertices = &verts };
    for (0..500) |i| {
        const f: f32 = @floatFromInt(i);
        batch.rect(@mod(f * 37, 3300), @mod(f * 53, 2200), 9, 14, .{ 230, 230, 230, 255 });
    }
    var fills: [10]Fill = undefined;
    for (&fills, 0..) |*f, i| f.* = .{ .rect = .{ .x = @intCast(i * 300), .y = 0, .w = 2, .h = h }, .colour = .{ 0.3, 0.3, 0.3, 1 } };
    const fs = 30000;
    for ([_]u32{ 32, 128 }) |nch| {
        try g.createHistory(nch, 34 * fs, 8 * fs, 62 * fs);
        // 12 s of noise, with a spike now and then.
        var prng = std.Random.DefaultPrng.init(nch);
        const block = try gpa.alloc(i16, 1000 * nch);
        defer gpa.free(block);
        var s: i64 = 0;
        while (s < 12 * fs) : (s += 1000) {
            for (block, 0..) |*v, k| v.* = if ((k / nch) % 997 == 0) 1500 else prng.random().intRangeAtMost(i16, -150, 150);
            g.writeSamples(s, block);
        }
        for ([_]f32{ 1, 10 }) |seconds| {
            var enc: [300]u64 = undefined;
            var gpu_t: [300]u64 = undefined;
            var whole: [300]u64 = undefined;
            for (0..300) |i| {
                const newest: u32 = @intCast(11 * fs + i * 100);
                var panels: [2]PanelDraw = undefined;
                for (&panels, 0..) |*pd, k| pd.* = .{
                    .rect = .{ .x = @intCast(k * w / 2), .y = 0, .w = w / 2, .h = h },
                    .params = .{
                        .nch = nch,
                        .cap_mask = @intCast(g.hist_cap - 1),
                        .newest = newest,
                        .first_ch = @intCast(k * nch / 2),
                        .cols = w / 2,
                        .rows = nch / 2,
                        .span = seconds * fs,
                        .lsb_per_row = 400,
                        .half_px = 1.5 / @as(f32, h),
                        .dec_mask = @intCast(g.dec.cap - 1),
                        .gain_base = @intCast(k * max_rows),
                    },
                };
                ms.ms_renderer_wait(g.r);
                const t0 = os.nowNs();
                g.drawOffscreen(&panels, &fills, verts[0..batch.len]);
                ms.ms_renderer_wait(g.r);
                whole[i] = @intCast(os.nowNs() - t0);
                ms.ms_renderer_times(g.r, &enc[i], &gpu_t[i]);
            }
            for ([_]*[300]u64{ &enc, &gpu_t, &whole }) |a| std.mem.sort(u64, a, {}, std.sort.asc(u64));
            std.debug.print("speed: {d} channels, {d} s, {d} x {d}: encode median {d:.3} worst {d:.3} ms; GPU median {d:.3} worst {d:.3} ms; frame median {d:.3} worst {d:.3} ms\n", .{
                nch,                                       seconds,                                   w,                                         h,
                @as(f64, @floatFromInt(enc[150])) / 1e6,   @as(f64, @floatFromInt(enc[299])) / 1e6,   @as(f64, @floatFromInt(gpu_t[150])) / 1e6, @as(f64, @floatFromInt(gpu_t[299])) / 1e6,
                @as(f64, @floatFromInt(whole[150])) / 1e6, @as(f64, @floatFromInt(whole[299])) / 1e6,
            });
        }
    }
}
