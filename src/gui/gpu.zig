//! Vulkan for the trace window: instance and device on a Wayland surface, the swapchain, a
//! ring of sample history that the GPU reads directly, and the pipeline that draws traces
//! from it (`shaders/traces.vert`).
//!
//! Only new samples cross to the GPU: each block is written once into the history ring
//! (mapped memory, device-local when the driver offers it). Everything per pixel (min/max
//! per column, scaling, layout) happens in the vertex shader.

const std = @import("std");
const vk = @import("vulkan");
const font = @import("font.zig");
const log = std.log.scoped(.gpu);

extern fn vkGetInstanceProcAddr(instance: ?vk.Instance, name: [*:0]const u8) vk.PfnVoidFunction;

pub const PresentMode = enum { auto, mailbox, immediate, fifo };

/// Where frames go: a Wayland surface, which the compositor shows.
pub const Target = struct { display: *anyopaque, surface: *anyopaque };

const linux = std.os.linux;

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
};

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

pub const Gpu = struct {
    gpa: std.mem.Allocator,
    vki: *vk.InstanceWrapper,
    vkd: *vk.DeviceWrapper,
    instance: vk.InstanceProxy,
    dev: vk.DeviceProxy,
    pdev: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    queue: vk.Queue,
    queue_family: u32,
    mem_props: vk.PhysicalDeviceMemoryProperties,
    /// False when the instance belongs to another Gpu (`init`'s `share`).
    owns_instance: bool = true,

    surface_format: vk.SurfaceFormatKHR = undefined,
    present_mode: vk.PresentModeKHR = .fifo_khr,
    swapchain: vk.SwapchainKHR = .null,
    extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    images: []vk.Image = &.{},
    views: []vk.ImageView = &.{},
    framebuffers: []vk.Framebuffer = &.{},
    render_pass: vk.RenderPass = .null,
    cmd_pool: vk.CommandPool = .null,
    cmd: vk.CommandBuffer = undefined,
    image_available: vk.Semaphore = .null,
    render_done: vk.Semaphore = .null,
    in_flight: vk.Fence = .null,

    set_layout: vk.DescriptorSetLayout = .null,
    pipeline_layout: vk.PipelineLayout = .null,
    pipeline: vk.Pipeline = .null,
    desc_pool: vk.DescriptorPool = .null,
    desc_set: vk.DescriptorSet = .null,
    /// The same, with the review history in place of the live one.
    rev_set: vk.DescriptorSet = .null,
    /// The review history: the same shape as the live one, made when review is first
    /// used (`createReview`), filled by `review.zig`.
    rev_buf: vk.Buffer = .null,
    rev_mem: vk.DeviceMemory = .null,
    rev: []i16 = &.{},

    // Text and solid rectangles (`shaders/text.vert`): the glyph atlas, and a vertex buffer
    // that each frame's quads are copied into.
    text_set_layout: vk.DescriptorSetLayout = .null,
    text_layout: vk.PipelineLayout = .null,
    text_pipeline: vk.Pipeline = .null,
    text_pool: vk.DescriptorPool = .null,
    text_set: vk.DescriptorSet = .null,
    atlas_image: vk.Image = .null,
    atlas_mem: vk.DeviceMemory = .null,
    atlas_view: vk.ImageView = .null,
    sampler: vk.Sampler = .null,
    text_buf: vk.Buffer = .null,
    text_mem: vk.DeviceMemory = .null,
    text_vertices: []font.Vertex = &.{},

    /// A factor on the vertical scale for every row of every panel (1 = the panel's own
    /// scale): panel `i`'s rows start at `i * max_rows`. Mapped; the shader reads it.
    gain_buf: vk.Buffer = .null,
    gain_mem: vk.DeviceMemory = .null,
    row_gains: []f32 = &.{},

    /// Sample history: `hist_cap` samples of `nch` interleaved int16, a ring indexed by
    /// absolute sample number.
    hist_buf: vk.Buffer = .null,
    hist_mem: vk.DeviceMemory = .null,
    hist: []i16 = &.{},
    hist_cap: usize = 0,
    nch: usize = 0,
    hist_device_local: bool = false,

    /// With `wait_render`, `draw` waits for the GPU to finish the frame before presenting it,
    /// and records how long that took. For diagnostics only: under a compositor it costs
    /// latency, since the compositor shows the frame a refresh later whenever it was
    /// finished. (How long the GPU takes is not constant: at this light load the card drops
    /// to a low power state after a few seconds; measured, 450 MHz of 3105 MHz, the time
    /// per frame rose from 0.37 ms to 1.5 ms, peaks 3.8 ms.)
    wait_render: bool = false,
    last_render_ns: u64 = 0,

    /// `share`: another Gpu whose Vulkan instance this one uses instead of creating its
    /// own (it must outlive this one). A second window needs this: with two instances in
    /// one process, NVIDIA's driver crashed in the first once the second was destroyed.
    pub fn init(gpa: std.mem.Allocator, target: Target, mode: PresentMode, share: ?*const Gpu) !Gpu {
        const vkb = vk.BaseWrapper.load(vkGetInstanceProcAddr);
        const instance_exts = [_][*:0]const u8{ "VK_KHR_surface", "VK_KHR_wayland_surface" };
        const instance_handle = if (share) |s| s.instance.handle else try vkb.createInstance(&.{
            .p_application_info = &.{
                .p_application_name = "oez",
                .application_version = 0,
                .p_engine_name = "oez",
                .engine_version = 0,
                .api_version = @bitCast(vk.API_VERSION_1_2),
            },
            .enabled_extension_count = @intCast(instance_exts.len),
            .pp_enabled_extension_names = &instance_exts,
        }, null);
        const vki = if (share) |s| s.vki else try gpa.create(vk.InstanceWrapper);
        errdefer if (share == null) gpa.destroy(vki);
        if (share == null) vki.* = vk.InstanceWrapper.load(instance_handle, vkb.dispatch.vkGetInstanceProcAddr.?);
        const instance = vk.InstanceProxy.init(instance_handle, vki);
        errdefer if (share == null) instance.destroyInstance(null);

        const pdevs = try instance.enumeratePhysicalDevicesAlloc(gpa);
        defer gpa.free(pdevs);

        const surface = try instance.createWaylandSurfaceKHR(&.{ .display = @ptrCast(target.display), .surface = @ptrCast(target.surface) }, null);
        errdefer instance.destroySurfaceKHR(surface, null);

        // A device with a queue family that does graphics and can present to this surface;
        // a discrete GPU if there is one.
        var chosen: ?vk.PhysicalDevice = null;
        var chosen_family: u32 = 0;
        var chosen_discrete = false;
        for (pdevs) |pd| {
            const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pd, gpa);
            defer gpa.free(families);
            for (families, 0..) |f, i| {
                if (!f.queue_flags.graphics) continue;
                if (try instance.getPhysicalDeviceSurfaceSupportKHR(pd, @intCast(i), surface) != .true) continue;
                const props = instance.getPhysicalDeviceProperties(pd);
                const discrete = props.device_type == .discrete_gpu;
                if (chosen == null or (discrete and !chosen_discrete)) {
                    chosen = pd;
                    chosen_family = @intCast(i);
                    chosen_discrete = discrete;
                }
                break;
            }
        }
        const pdev = chosen orelse return error.NoSuitableGpu;
        const props = instance.getPhysicalDeviceProperties(pdev);
        log.info("Vulkan device: {s}", .{std.mem.sliceTo(&props.device_name, 0)});

        const priority = [_]f32{1.0};
        const device_exts = [_][*:0]const u8{"VK_KHR_swapchain"};
        const device_handle = try instance.createDevice(pdev, &.{
            .queue_create_info_count = 1,
            .p_queue_create_infos = &[_]vk.DeviceQueueCreateInfo{.{ .queue_family_index = chosen_family, .queue_count = 1, .p_queue_priorities = &priority }},
            .enabled_extension_count = @intCast(device_exts.len),
            .pp_enabled_extension_names = &device_exts,
        }, null);
        const vkd = try gpa.create(vk.DeviceWrapper);
        errdefer gpa.destroy(vkd);
        vkd.* = vk.DeviceWrapper.load(device_handle, vki.dispatch.vkGetDeviceProcAddr.?);
        const dev = vk.DeviceProxy.init(device_handle, vkd);
        errdefer dev.destroyDevice(null);

        var self: Gpu = .{
            .gpa = gpa,
            .vki = vki,
            .vkd = vkd,
            .instance = instance,
            .dev = dev,
            .pdev = pdev,
            .surface = surface,
            .queue = dev.getDeviceQueue(chosen_family, 0),
            .queue_family = chosen_family,
            .mem_props = instance.getPhysicalDeviceMemoryProperties(pdev),
            .owns_instance = share == null,
        };

        // Surface format: 8-bit BGRA or RGBA, not sRGB-encoded (colours are written as is).
        const formats = try instance.getPhysicalDeviceSurfaceFormatsAllocKHR(pdev, surface, gpa);
        defer gpa.free(formats);
        self.surface_format = formats[0];
        for (formats) |f| {
            if (f.format == .b8g8r8a8_unorm or f.format == .r8g8b8a8_unorm) {
                self.surface_format = f;
                break;
            }
        }
        // Drawing is paced by the compositor's frame callbacks, so presenting must never
        // block: mailbox or immediate if offered, FIFO as the fallback.
        const modes = try instance.getPhysicalDeviceSurfacePresentModesAllocKHR(pdev, surface, gpa);
        defer gpa.free(modes);
        const has = struct {
            fn f(list: []const vk.PresentModeKHR, m: vk.PresentModeKHR) bool {
                return std.mem.indexOfScalar(vk.PresentModeKHR, list, m) != null;
            }
        }.f;
        self.present_mode = switch (mode) {
            .auto => if (has(modes, .mailbox_khr)) .mailbox_khr else if (has(modes, .immediate_khr)) .immediate_khr else .fifo_khr,
            .mailbox => if (has(modes, .mailbox_khr)) .mailbox_khr else .fifo_khr,
            .immediate => if (has(modes, .immediate_khr)) .immediate_khr else .fifo_khr,
            .fifo => .fifo_khr,
        };
        log.info("surface format {t}, present mode {t}", .{ self.surface_format.format, self.present_mode });

        self.render_pass = try dev.createRenderPass(&.{
            .attachment_count = 1,
            .p_attachments = &[_]vk.AttachmentDescription{.{
                .format = self.surface_format.format,
                .samples = .{ .@"1" = true },
                .load_op = .clear,
                .store_op = .store,
                .stencil_load_op = .dont_care,
                .stencil_store_op = .dont_care,
                .initial_layout = .undefined,
                .final_layout = .present_src_khr,
            }},
            .subpass_count = 1,
            .p_subpasses = &[_]vk.SubpassDescription{.{
                .pipeline_bind_point = .graphics,
                .color_attachment_count = 1,
                .p_color_attachments = &[_]vk.AttachmentReference{.{ .attachment = 0, .layout = .color_attachment_optimal }},
            }},
        }, null);
        self.cmd_pool = try dev.createCommandPool(&.{ .flags = .{ .reset_command_buffer = true }, .queue_family_index = chosen_family }, null);
        var cmds: [1]vk.CommandBuffer = undefined;
        try dev.allocateCommandBuffers(&.{ .command_pool = self.cmd_pool, .level = .primary, .command_buffer_count = 1 }, &cmds);
        self.cmd = cmds[0];
        self.image_available = try dev.createSemaphore(&.{}, null);
        self.render_done = try dev.createSemaphore(&.{}, null);
        self.in_flight = try dev.createFence(&.{ .flags = .{ .signaled = true } }, null);
        try self.createPipeline();
        return self;
    }

    pub fn deinit(self: *Gpu) void {
        const dev = self.dev;
        dev.deviceWaitIdle() catch {};
        self.destroySwapchainViews();
        if (self.swapchain != .null) dev.destroySwapchainKHR(self.swapchain, null);
        if (self.hist_buf != .null) {
            dev.unmapMemory(self.hist_mem);
            dev.destroyBuffer(self.hist_buf, null);
            dev.freeMemory(self.hist_mem, null);
        }
        self.destroyReview();
        if (self.gain_buf != .null) {
            dev.unmapMemory(self.gain_mem);
            dev.destroyBuffer(self.gain_buf, null);
            dev.freeMemory(self.gain_mem, null);
        }
        if (self.text_buf != .null) {
            dev.unmapMemory(self.text_mem);
            dev.destroyBuffer(self.text_buf, null);
            dev.freeMemory(self.text_mem, null);
            dev.destroySampler(self.sampler, null);
            dev.destroyImageView(self.atlas_view, null);
            dev.destroyImage(self.atlas_image, null);
            dev.freeMemory(self.atlas_mem, null);
            dev.destroyPipeline(self.text_pipeline, null);
            dev.destroyPipelineLayout(self.text_layout, null);
            dev.destroyDescriptorPool(self.text_pool, null);
            dev.destroyDescriptorSetLayout(self.text_set_layout, null);
        }
        dev.destroyPipeline(self.pipeline, null);
        dev.destroyPipelineLayout(self.pipeline_layout, null);
        dev.destroyDescriptorPool(self.desc_pool, null);
        dev.destroyDescriptorSetLayout(self.set_layout, null);
        dev.destroyFence(self.in_flight, null);
        dev.destroySemaphore(self.render_done, null);
        dev.destroySemaphore(self.image_available, null);
        dev.destroyCommandPool(self.cmd_pool, null);
        dev.destroyRenderPass(self.render_pass, null);
        dev.destroyDevice(null);
        self.instance.destroySurfaceKHR(self.surface, null);
        self.gpa.destroy(self.vkd);
        if (self.owns_instance) {
            self.instance.destroyInstance(null);
            self.gpa.destroy(self.vki);
        }
    }

    fn createPipeline(self: *Gpu) !void {
        const dev = self.dev;
        self.set_layout = try dev.createDescriptorSetLayout(&.{
            .binding_count = 2,
            .p_bindings = &[_]vk.DescriptorSetLayoutBinding{
                .{ .binding = 0, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .vertex = true } },
                .{ .binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .vertex = true } },
            },
        }, null);
        self.pipeline_layout = try dev.createPipelineLayout(&.{
            .set_layout_count = 1,
            .p_set_layouts = &[_]vk.DescriptorSetLayout{self.set_layout},
            .push_constant_range_count = 1,
            .p_push_constant_ranges = &[_]vk.PushConstantRange{.{ .stage_flags = .{ .vertex = true }, .offset = 0, .size = @sizeOf(TraceParams) }},
        }, null);
        self.desc_pool = try dev.createDescriptorPool(&.{
            .max_sets = 2,
            .pool_size_count = 1,
            .p_pool_sizes = &[_]vk.DescriptorPoolSize{.{ .type = .storage_buffer, .descriptor_count = 4 }},
        }, null);
        var sets: [2]vk.DescriptorSet = undefined;
        try dev.allocateDescriptorSets(&.{ .descriptor_pool = self.desc_pool, .descriptor_set_count = 2, .p_set_layouts = &[_]vk.DescriptorSetLayout{ self.set_layout, self.set_layout } }, &sets);
        self.desc_set = sets[0];
        self.rev_set = sets[1];

        // The row factors: small, mapped for good, all 1 to start with.
        const gain_count = max_rows * max_gain_panels;
        self.gain_buf = try dev.createBuffer(&.{ .size = gain_count * @sizeOf(f32), .usage = .{ .storage_buffer = true }, .sharing_mode = .exclusive }, null);
        const greq = dev.getBufferMemoryRequirements(self.gain_buf);
        self.gain_mem = try dev.allocateMemory(&.{ .allocation_size = greq.size, .memory_type_index = self.findMemoryType(greq.memory_type_bits, .{ .host_visible = true, .host_coherent = true }) orelse return error.NoHostVisibleMemory }, null);
        try dev.bindBufferMemory(self.gain_buf, self.gain_mem, 0);
        const gptr: [*]f32 = @ptrCast(@alignCast((try dev.mapMemory(self.gain_mem, 0, vk.WHOLE_SIZE, .{})) orelse return error.MapFailed));
        self.row_gains = gptr[0..gain_count];
        @memset(self.row_gains, 1.0);
        dev.updateDescriptorSets(&[_]vk.WriteDescriptorSet{.{
            .dst_set = self.desc_set,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = &[_]vk.DescriptorBufferInfo{.{ .buffer = self.gain_buf, .offset = 0, .range = vk.WHOLE_SIZE }},
            .p_texel_buffer_view = undefined,
        }}, null);

        const vert_code align(4) = @embedFile("traces.vert.spv").*;
        const frag_code align(4) = @embedFile("traces.frag.spv").*;
        const vert = try dev.createShaderModule(&.{ .code_size = vert_code.len, .p_code = @ptrCast(&vert_code) }, null);
        defer dev.destroyShaderModule(vert, null);
        const frag = try dev.createShaderModule(&.{ .code_size = frag_code.len, .p_code = @ptrCast(&frag_code) }, null);
        defer dev.destroyShaderModule(frag, null);

        const stages = [_]vk.PipelineShaderStageCreateInfo{
            .{ .stage = .{ .vertex = true }, .module = vert, .p_name = "main" },
            .{ .stage = .{ .fragment = true }, .module = frag, .p_name = "main" },
        };
        const dynamic = [_]vk.DynamicState{ .viewport, .scissor };
        const blend_attachment = [_]vk.PipelineColorBlendAttachmentState{.{
            .blend_enable = .false,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
            .color_write_mask = .{ .r = true, .g = true, .b = true, .a = true },
        }};
        const info = [_]vk.GraphicsPipelineCreateInfo{.{
            .stage_count = stages.len,
            .p_stages = &stages,
            .p_vertex_input_state = &.{},
            .p_input_assembly_state = &.{ .topology = .triangle_strip, .primitive_restart_enable = .false },
            .p_viewport_state = &.{ .viewport_count = 1, .scissor_count = 1 },
            .p_rasterization_state = &.{
                .depth_clamp_enable = .false,
                .rasterizer_discard_enable = .false,
                .polygon_mode = .fill,
                .cull_mode = .{},
                .front_face = .counter_clockwise,
                .depth_bias_enable = .false,
                .depth_bias_constant_factor = 0,
                .depth_bias_clamp = 0,
                .depth_bias_slope_factor = 0,
                .line_width = 1,
            },
            .p_multisample_state = &.{ .rasterization_samples = .{ .@"1" = true }, .sample_shading_enable = .false, .min_sample_shading = 1, .alpha_to_coverage_enable = .false, .alpha_to_one_enable = .false },
            .p_color_blend_state = &.{ .logic_op_enable = .false, .logic_op = .copy, .attachment_count = 1, .p_attachments = &blend_attachment, .blend_constants = .{ 0, 0, 0, 0 } },
            .p_dynamic_state = &.{ .dynamic_state_count = dynamic.len, .p_dynamic_states = &dynamic },
            .layout = self.pipeline_layout,
            .render_pass = self.render_pass,
            .subpass = 0,
            .base_pipeline_index = -1,
        }};
        var pipelines: [1]vk.Pipeline = undefined;
        _ = try dev.createGraphicsPipelines(.null, &info, null, &pipelines);
        self.pipeline = pipelines[0];
    }

    /// Sets up text drawing: uploads the glyph atlas (`size` x `size` coverage bytes) and
    /// makes room for `max_vertices` vertices per frame. Call once before drawing text.
    pub fn createText(self: *Gpu, atlas: []const u8, size: u32, max_vertices: usize) !void {
        const dev = self.dev;
        const host: vk.MemoryPropertyFlags = .{ .host_visible = true, .host_coherent = true };

        // The atlas image, filled through a staging buffer.
        self.atlas_image = try dev.createImage(&.{
            .image_type = .@"2d",
            .format = .r8_unorm,
            .extent = .{ .width = size, .height = size, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1" = true },
            .tiling = .optimal,
            .usage = .{ .sampled = true, .transfer_dst = true },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        }, null);
        const ireq = dev.getImageMemoryRequirements(self.atlas_image);
        self.atlas_mem = try dev.allocateMemory(&.{ .allocation_size = ireq.size, .memory_type_index = self.findMemoryType(ireq.memory_type_bits, .{ .device_local = true }) orelse return error.NoImageMemory }, null);
        try dev.bindImageMemory(self.atlas_image, self.atlas_mem, 0);

        const staging = try dev.createBuffer(&.{ .size = atlas.len, .usage = .{ .transfer_src = true }, .sharing_mode = .exclusive }, null);
        defer dev.destroyBuffer(staging, null);
        const sreq = dev.getBufferMemoryRequirements(staging);
        const smem = try dev.allocateMemory(&.{ .allocation_size = sreq.size, .memory_type_index = self.findMemoryType(sreq.memory_type_bits, host) orelse return error.NoHostVisibleMemory }, null);
        defer dev.freeMemory(smem, null);
        try dev.bindBufferMemory(staging, smem, 0);
        const sptr: [*]u8 = @ptrCast((try dev.mapMemory(smem, 0, vk.WHOLE_SIZE, .{})) orelse return error.MapFailed);
        @memcpy(sptr[0..atlas.len], atlas);
        dev.unmapMemory(smem);

        const range: vk.ImageSubresourceRange = .{ .aspect_mask = .{ .color = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 };
        const cmd = self.cmd;
        try dev.resetCommandBuffer(cmd, .{});
        try dev.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit = true } });
        dev.cmdPipelineBarrier(cmd, .{ .top_of_pipe = true }, .{ .transfer = true }, .{}, null, null, &[_]vk.ImageMemoryBarrier{.{
            .src_access_mask = .{},
            .dst_access_mask = .{ .transfer_write = true },
            .old_layout = .undefined,
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.atlas_image,
            .subresource_range = range,
        }});
        dev.cmdCopyBufferToImage(cmd, staging, self.atlas_image, .transfer_dst_optimal, &[_]vk.BufferImageCopy{.{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = size, .height = size, .depth = 1 },
        }});
        dev.cmdPipelineBarrier(cmd, .{ .transfer = true }, .{ .fragment_shader = true }, .{}, null, null, &[_]vk.ImageMemoryBarrier{.{
            .src_access_mask = .{ .transfer_write = true },
            .dst_access_mask = .{ .shader_read = true },
            .old_layout = .transfer_dst_optimal,
            .new_layout = .shader_read_only_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = self.atlas_image,
            .subresource_range = range,
        }});
        try dev.endCommandBuffer(cmd);
        try dev.queueSubmit(self.queue, &[_]vk.SubmitInfo{.{ .command_buffer_count = 1, .p_command_buffers = &[_]vk.CommandBuffer{cmd} }}, .null);
        try dev.queueWaitIdle(self.queue);

        self.atlas_view = try dev.createImageView(&.{
            .image = self.atlas_image,
            .view_type = .@"2d",
            .format = .r8_unorm,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = range,
        }, null);
        // Glyph quads sit on whole pixels, so texels map one to one.
        self.sampler = try dev.createSampler(&.{
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .mip_lod_bias = 0,
            .anisotropy_enable = .false,
            .max_anisotropy = 1,
            .compare_enable = .false,
            .compare_op = .always,
            .min_lod = 0,
            .max_lod = 0,
            .border_color = .float_transparent_black,
            .unnormalized_coordinates = .false,
        }, null);

        // The vertex buffer, mapped for good.
        const vbytes: vk.DeviceSize = max_vertices * @sizeOf(font.Vertex);
        self.text_buf = try dev.createBuffer(&.{ .size = vbytes, .usage = .{ .vertex_buffer = true }, .sharing_mode = .exclusive }, null);
        const vreq = dev.getBufferMemoryRequirements(self.text_buf);
        self.text_mem = try dev.allocateMemory(&.{ .allocation_size = vreq.size, .memory_type_index = self.findMemoryType(vreq.memory_type_bits, host) orelse return error.NoHostVisibleMemory }, null);
        try dev.bindBufferMemory(self.text_buf, self.text_mem, 0);
        const vptr: [*]font.Vertex = @ptrCast(@alignCast((try dev.mapMemory(self.text_mem, 0, vk.WHOLE_SIZE, .{})) orelse return error.MapFailed));
        self.text_vertices = vptr[0..max_vertices];

        self.text_set_layout = try dev.createDescriptorSetLayout(&.{
            .binding_count = 1,
            .p_bindings = &[_]vk.DescriptorSetLayoutBinding{.{
                .binding = 0,
                .descriptor_type = .combined_image_sampler,
                .descriptor_count = 1,
                .stage_flags = .{ .fragment = true },
            }},
        }, null);
        self.text_layout = try dev.createPipelineLayout(&.{
            .set_layout_count = 1,
            .p_set_layouts = &[_]vk.DescriptorSetLayout{self.text_set_layout},
            .push_constant_range_count = 1,
            .p_push_constant_ranges = &[_]vk.PushConstantRange{.{ .stage_flags = .{ .vertex = true }, .offset = 0, .size = 8 }},
        }, null);
        self.text_pool = try dev.createDescriptorPool(&.{
            .max_sets = 1,
            .pool_size_count = 1,
            .p_pool_sizes = &[_]vk.DescriptorPoolSize{.{ .type = .combined_image_sampler, .descriptor_count = 1 }},
        }, null);
        var sets: [1]vk.DescriptorSet = undefined;
        try dev.allocateDescriptorSets(&.{ .descriptor_pool = self.text_pool, .descriptor_set_count = 1, .p_set_layouts = &[_]vk.DescriptorSetLayout{self.text_set_layout} }, &sets);
        self.text_set = sets[0];
        dev.updateDescriptorSets(&[_]vk.WriteDescriptorSet{.{
            .dst_set = self.text_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = &[_]vk.DescriptorImageInfo{.{ .sampler = self.sampler, .image_view = self.atlas_view, .image_layout = .shader_read_only_optimal }},
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        }}, null);

        const vert_code align(4) = @embedFile("text.vert.spv").*;
        const frag_code align(4) = @embedFile("text.frag.spv").*;
        const vert = try dev.createShaderModule(&.{ .code_size = vert_code.len, .p_code = @ptrCast(&vert_code) }, null);
        defer dev.destroyShaderModule(vert, null);
        const frag = try dev.createShaderModule(&.{ .code_size = frag_code.len, .p_code = @ptrCast(&frag_code) }, null);
        defer dev.destroyShaderModule(frag, null);
        const stages = [_]vk.PipelineShaderStageCreateInfo{
            .{ .stage = .{ .vertex = true }, .module = vert, .p_name = "main" },
            .{ .stage = .{ .fragment = true }, .module = frag, .p_name = "main" },
        };
        const dynamic = [_]vk.DynamicState{ .viewport, .scissor };
        const blend_attachment = [_]vk.PipelineColorBlendAttachmentState{.{
            .blend_enable = .true,
            .src_color_blend_factor = .src_alpha,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one,
            .alpha_blend_op = .add,
            .color_write_mask = .{ .r = true, .g = true, .b = true, .a = true },
        }};
        const bindings = [_]vk.VertexInputBindingDescription{.{ .binding = 0, .stride = @sizeOf(font.Vertex), .input_rate = .vertex }};
        const attributes = [_]vk.VertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(font.Vertex, "pos") },
            .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(font.Vertex, "uv") },
            .{ .location = 2, .binding = 0, .format = .r8g8b8a8_unorm, .offset = @offsetOf(font.Vertex, "colour") },
        };
        const info = [_]vk.GraphicsPipelineCreateInfo{.{
            .stage_count = stages.len,
            .p_stages = &stages,
            .p_vertex_input_state = &.{
                .vertex_binding_description_count = bindings.len,
                .p_vertex_binding_descriptions = &bindings,
                .vertex_attribute_description_count = attributes.len,
                .p_vertex_attribute_descriptions = &attributes,
            },
            .p_input_assembly_state = &.{ .topology = .triangle_list, .primitive_restart_enable = .false },
            .p_viewport_state = &.{ .viewport_count = 1, .scissor_count = 1 },
            .p_rasterization_state = &.{
                .depth_clamp_enable = .false,
                .rasterizer_discard_enable = .false,
                .polygon_mode = .fill,
                .cull_mode = .{},
                .front_face = .counter_clockwise,
                .depth_bias_enable = .false,
                .depth_bias_constant_factor = 0,
                .depth_bias_clamp = 0,
                .depth_bias_slope_factor = 0,
                .line_width = 1,
            },
            .p_multisample_state = &.{ .rasterization_samples = .{ .@"1" = true }, .sample_shading_enable = .false, .min_sample_shading = 1, .alpha_to_coverage_enable = .false, .alpha_to_one_enable = .false },
            .p_color_blend_state = &.{ .logic_op_enable = .false, .logic_op = .copy, .attachment_count = 1, .p_attachments = &blend_attachment, .blend_constants = .{ 0, 0, 0, 0 } },
            .p_dynamic_state = &.{ .dynamic_state_count = dynamic.len, .p_dynamic_states = &dynamic },
            .layout = self.text_layout,
            .render_pass = self.render_pass,
            .subpass = 0,
            .base_pipeline_index = -1,
        }};
        var pipelines: [1]vk.Pipeline = undefined;
        _ = try dev.createGraphicsPipelines(.null, &info, null, &pipelines);
        self.text_pipeline = pipelines[0];
    }

    fn findMemoryType(self: *const Gpu, type_bits: u32, flags: vk.MemoryPropertyFlags) ?u32 {
        for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |t, i| {
            if (type_bits & (@as(u32, 1) << @intCast(i)) != 0 and t.property_flags.contains(flags)) return @intCast(i);
        }
        return null;
    }

    /// Creates the sample-history ring: at least `min_samples` samples (rounded up to a
    /// power of two) of `nch` channels. Call before drawing, and again when the number of
    /// channels or the sample rate changes (the old history is dropped).
    pub fn createHistory(self: *Gpu, nch: usize, min_samples: usize) !void {
        const dev = self.dev;
        if (self.hist_buf != .null) {
            try dev.deviceWaitIdle();
            // The review history has the live one's shape: it goes too.
            self.destroyReview();
            dev.unmapMemory(self.hist_mem);
            dev.destroyBuffer(self.hist_buf, null);
            dev.freeMemory(self.hist_mem, null);
            self.hist_buf = .null;
            self.hist = &.{};
            self.hist_cap = 0;
        }
        const cap = try std.math.ceilPowerOfTwo(usize, min_samples);
        const bytes: vk.DeviceSize = std.mem.alignForward(u64, cap * nch * 2, 4);
        self.hist_buf = try dev.createBuffer(&.{ .size = bytes, .usage = .{ .storage_buffer = true }, .sharing_mode = .exclusive }, null);
        const req = dev.getBufferMemoryRequirements(self.hist_buf);
        // Prefer memory on the card that the CPU can also write (the GPU then reads it
        // locally); else ordinary host memory, which the GPU reads over the bus.
        const host: vk.MemoryPropertyFlags = .{ .host_visible = true, .host_coherent = true };
        var mem_type = self.findMemoryType(req.memory_type_bits, host.merge(.{ .device_local = true }));
        self.hist_device_local = mem_type != null;
        if (mem_type == null) mem_type = self.findMemoryType(req.memory_type_bits, host);
        self.hist_mem = dev.allocateMemory(&.{ .allocation_size = req.size, .memory_type_index = mem_type orelse return error.NoHostVisibleMemory }, null) catch |e| blk: {
            // The device-local, host-visible heap can be small: fall back to host memory.
            if (!self.hist_device_local) return e;
            self.hist_device_local = false;
            break :blk try dev.allocateMemory(&.{ .allocation_size = req.size, .memory_type_index = self.findMemoryType(req.memory_type_bits, host) orelse return error.NoHostVisibleMemory }, null);
        };
        try dev.bindBufferMemory(self.hist_buf, self.hist_mem, 0);
        const ptr = (try dev.mapMemory(self.hist_mem, 0, vk.WHOLE_SIZE, .{})) orelse return error.MapFailed;
        const p: [*]i16 = @ptrCast(@alignCast(ptr));
        self.hist = p[0 .. cap * nch];
        @memset(self.hist, 0);
        self.hist_cap = cap;
        self.nch = nch;
        dev.updateDescriptorSets(&[_]vk.WriteDescriptorSet{.{
            .dst_set = self.desc_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_image_info = undefined,
            .p_buffer_info = &[_]vk.DescriptorBufferInfo{.{ .buffer = self.hist_buf, .offset = 0, .range = vk.WHOLE_SIZE }},
            .p_texel_buffer_view = undefined,
        }}, null);
        log.info("sample history: {d} samples x {d} channels ({d:.1} MB, {s})", .{ cap, nch, @as(f64, @floatFromInt(bytes)) / 1e6, if (self.hist_device_local) "on the card" else "host memory" });
    }

    /// Makes the review history (once): the live one's size and shape.
    pub fn createReview(self: *Gpu) !void {
        if (self.rev_buf != .null or self.hist_cap == 0) return;
        const dev = self.dev;
        const bytes: vk.DeviceSize = std.mem.alignForward(u64, self.hist_cap * self.nch * 2, 4);
        const buf = try dev.createBuffer(&.{ .size = bytes, .usage = .{ .storage_buffer = true }, .sharing_mode = .exclusive }, null);
        errdefer dev.destroyBuffer(buf, null);
        const req = dev.getBufferMemoryRequirements(buf);
        const host: vk.MemoryPropertyFlags = .{ .host_visible = true, .host_coherent = true };
        // As for the live history: on the card if that memory can be mapped, else host.
        var mem: vk.DeviceMemory = .null;
        if (self.findMemoryType(req.memory_type_bits, host.merge(.{ .device_local = true }))) |t| {
            mem = dev.allocateMemory(&.{ .allocation_size = req.size, .memory_type_index = t }, null) catch .null;
        }
        if (mem == .null) mem = try dev.allocateMemory(&.{ .allocation_size = req.size, .memory_type_index = self.findMemoryType(req.memory_type_bits, host) orelse return error.NoHostVisibleMemory }, null);
        errdefer dev.freeMemory(mem, null);
        try dev.bindBufferMemory(buf, mem, 0);
        const ptr = (try dev.mapMemory(mem, 0, vk.WHOLE_SIZE, .{})) orelse return error.MapFailed;
        const p: [*]i16 = @ptrCast(@alignCast(ptr));
        self.rev = p[0 .. self.hist_cap * self.nch];
        @memset(self.rev, 0);
        self.rev_buf = buf;
        self.rev_mem = mem;
        const writes = [_]vk.WriteDescriptorSet{
            .{ .dst_set = self.rev_set, .dst_binding = 0, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .storage_buffer, .p_image_info = undefined, .p_buffer_info = &[_]vk.DescriptorBufferInfo{.{ .buffer = buf, .offset = 0, .range = vk.WHOLE_SIZE }}, .p_texel_buffer_view = undefined },
            .{ .dst_set = self.rev_set, .dst_binding = 1, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = .storage_buffer, .p_image_info = undefined, .p_buffer_info = &[_]vk.DescriptorBufferInfo{.{ .buffer = self.gain_buf, .offset = 0, .range = vk.WHOLE_SIZE }}, .p_texel_buffer_view = undefined },
        };
        dev.updateDescriptorSets(&writes, null);
        log.info("review history: {d:.1} MB", .{@as(f64, @floatFromInt(bytes)) / 1e6});
    }

    pub fn destroyReview(self: *Gpu) void {
        if (self.rev_buf == .null) return;
        self.dev.deviceWaitIdle() catch {};
        self.dev.unmapMemory(self.rev_mem);
        self.dev.destroyBuffer(self.rev_buf, null);
        self.dev.freeMemory(self.rev_mem, null);
        self.rev_buf = .null;
        self.rev = &.{};
    }

    /// Writes `count` samples (interleaved, `nch` each) at absolute sample number `first`.
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
    }

    fn destroySwapchainViews(self: *Gpu) void {
        for (self.framebuffers) |f| self.dev.destroyFramebuffer(f, null);
        for (self.views) |v| self.dev.destroyImageView(v, null);
        self.gpa.free(self.framebuffers);
        self.gpa.free(self.views);
        self.gpa.free(self.images);
        self.framebuffers = &.{};
        self.views = &.{};
        self.images = &.{};
    }

    /// (Re)creates the swapchain for a window of `width` x `height` pixels.
    pub fn resize(self: *Gpu, width: u32, height: u32) !void {
        const dev = self.dev;
        try dev.deviceWaitIdle();
        self.destroySwapchainViews();
        const caps = try self.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(self.pdev, self.surface);
        // On Wayland the surface has no size of its own: the swapchain defines it.
        self.extent = if (caps.current_extent.width != 0xFFFF_FFFF) caps.current_extent else .{
            .width = std.math.clamp(width, caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(height, caps.min_image_extent.height, caps.max_image_extent.height),
        };
        var count = @max(caps.min_image_count + 1, 3);
        if (caps.max_image_count > 0) count = @min(count, caps.max_image_count);
        const old = self.swapchain;
        self.swapchain = try dev.createSwapchainKHR(&.{
            .surface = self.surface,
            .min_image_count = count,
            .image_format = self.surface_format.format,
            .image_color_space = self.surface_format.color_space,
            .image_extent = self.extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment = true },
            .image_sharing_mode = .exclusive,
            .pre_transform = caps.current_transform,
            .composite_alpha = .{ .opaque_khr = true },
            .present_mode = self.present_mode,
            .clipped = .true,
            .old_swapchain = old,
        }, null);
        if (old != .null) dev.destroySwapchainKHR(old, null);
        self.images = try dev.getSwapchainImagesAllocKHR(self.swapchain, self.gpa);
        self.views = try self.gpa.alloc(vk.ImageView, self.images.len);
        self.framebuffers = try self.gpa.alloc(vk.Framebuffer, self.images.len);
        for (self.images, 0..) |img, i| {
            self.views[i] = try dev.createImageView(&.{
                .image = img,
                .view_type = .@"2d",
                .format = self.surface_format.format,
                .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
                .subresource_range = .{ .aspect_mask = .{ .color = true }, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 },
            }, null);
            self.framebuffers[i] = try dev.createFramebuffer(&.{
                .render_pass = self.render_pass,
                .attachment_count = 1,
                .p_attachments = &[_]vk.ImageView{self.views[i]},
                .width = self.extent.width,
                .height = self.extent.height,
                .layers = 1,
            }, null);
        }
    }

    /// `r` limited to the swapchain image, or null if nothing of it is on screen.
    fn clip(self: *const Gpu, r: PixelRect) ?vk.Rect2D {
        if (r.x >= self.extent.width or r.y >= self.extent.height or r.w == 0 or r.h == 0) return null;
        return .{
            .offset = .{ .x = @intCast(r.x), .y = @intCast(r.y) },
            .extent = .{ .width = @min(r.w, self.extent.width - r.x), .height = @min(r.h, self.extent.height - r.y) },
        };
    }

    pub const DrawResult = enum {
        presented,
        /// The swapchain no longer fits the window: call `resize`.
        out_of_date,
        /// No swapchain image was free; nothing was drawn. Try again shortly.
        busy,
    };

    /// Draws one frame (each panel in its own viewport, then the fills, then `text`: quads
    /// from a `font.Batch`, over everything) and presents it.
    /// `before_present` runs right before the frame is handed to the compositor (frame
    /// callback and presentation feedback requests must be made then, so they attach to
    /// this frame's commit).
    pub fn draw(self: *Gpu, panels: []const PanelDraw, fills: []const Fill, text: []const font.Vertex, context: anytype, comptime before_present: fn (@TypeOf(context)) void) !DrawResult {
        const dev = self.dev;
        _ = try dev.waitForFences(&[_]vk.Fence{self.in_flight}, .true, std.math.maxInt(u64));
        const acquired = dev.acquireNextImageKHR(self.swapchain, 0, self.image_available, .null) catch |e| switch (e) {
            error.OutOfDateKHR => return .out_of_date,
            else => return e,
        };
        if (acquired.result == .not_ready or acquired.result == .timeout) return .busy;
        try dev.resetFences(&[_]vk.Fence{self.in_flight});

        const cmd = self.cmd;
        try dev.resetCommandBuffer(cmd, .{});
        try dev.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit = true } });
        const area: vk.Rect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent };
        dev.cmdBeginRenderPass(cmd, &.{
            .render_pass = self.render_pass,
            .framebuffer = self.framebuffers[acquired.image_index],
            .render_area = area,
            .clear_value_count = 1,
            .p_clear_values = &[_]vk.ClearValue{.{ .color = .{ .float_32 = .{ 0.04, 0.045, 0.055, 1.0 } } }},
        }, .@"inline");
        if (self.hist_cap > 0 and panels.len > 0) {
            dev.cmdBindPipeline(cmd, .graphics, self.pipeline);
            var bound_review: ?bool = null;
            for (panels) |pd| {
                const r = self.clip(pd.rect) orelse continue;
                if (pd.params.rows == 0 or pd.params.cols == 0) continue;
                // The live history, or the review one for a panel in review.
                const from_review = pd.review and self.rev_buf != .null;
                if (bound_review != from_review) {
                    dev.cmdBindDescriptorSets(cmd, .graphics, self.pipeline_layout, 0, &[_]vk.DescriptorSet{if (from_review) self.rev_set else self.desc_set}, null);
                    bound_review = from_review;
                }
                dev.cmdSetViewport(cmd, 0, &[_]vk.Viewport{.{ .x = @floatFromInt(r.offset.x), .y = @floatFromInt(r.offset.y), .width = @floatFromInt(r.extent.width), .height = @floatFromInt(r.extent.height), .min_depth = 0, .max_depth = 1 }});
                dev.cmdSetScissor(cmd, 0, &[_]vk.Rect2D{r});
                dev.cmdPushConstants(cmd, self.pipeline_layout, .{ .vertex = true }, 0, @sizeOf(TraceParams), @ptrCast(&pd.params));
                dev.cmdDraw(cmd, 2 * pd.params.cols, pd.params.rows, 0, 0);
            }
        }
        for (fills) |f| {
            const r = self.clip(f.rect) orelse continue;
            dev.cmdClearAttachments(
                cmd,
                &[_]vk.ClearAttachment{.{ .aspect_mask = .{ .color = true }, .color_attachment = 0, .clear_value = .{ .color = .{ .float_32 = f.colour } } }},
                &[_]vk.ClearRect{.{ .rect = r, .base_array_layer = 0, .layer_count = 1 }},
            );
        }
        // The previous frame is finished (the fence above), so the vertex buffer is free.
        const ntext = @min(text.len, self.text_vertices.len);
        if (ntext > 0) {
            @memcpy(self.text_vertices[0..ntext], text[0..ntext]);
            dev.cmdBindPipeline(cmd, .graphics, self.text_pipeline);
            dev.cmdBindDescriptorSets(cmd, .graphics, self.text_layout, 0, &[_]vk.DescriptorSet{self.text_set}, null);
            dev.cmdSetViewport(cmd, 0, &[_]vk.Viewport{.{ .x = 0, .y = 0, .width = @floatFromInt(self.extent.width), .height = @floatFromInt(self.extent.height), .min_depth = 0, .max_depth = 1 }});
            dev.cmdSetScissor(cmd, 0, &[_]vk.Rect2D{area});
            const size = [2]f32{ @floatFromInt(self.extent.width), @floatFromInt(self.extent.height) };
            dev.cmdPushConstants(cmd, self.text_layout, .{ .vertex = true }, 0, 8, @ptrCast(&size));
            dev.cmdBindVertexBuffers(cmd, 0, &[_]vk.Buffer{self.text_buf}, &[_]vk.DeviceSize{0});
            dev.cmdDraw(cmd, @intCast(ntext), 1, 0, 0);
        }
        dev.cmdEndRenderPass(cmd);
        try dev.endCommandBuffer(cmd);

        try dev.queueSubmit(self.queue, &[_]vk.SubmitInfo{.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = &[_]vk.Semaphore{self.image_available},
            .p_wait_dst_stage_mask = &[_]vk.PipelineStageFlags{.{ .color_attachment_output = true }},
            .command_buffer_count = 1,
            .p_command_buffers = &[_]vk.CommandBuffer{cmd},
            .signal_semaphore_count = 1,
            .p_signal_semaphores = &[_]vk.Semaphore{self.render_done},
        }}, self.in_flight);

        if (self.wait_render) {
            var ts: linux.timespec = undefined;
            _ = linux.clock_gettime(.MONOTONIC, &ts);
            const t0 = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
            _ = try dev.waitForFences(&[_]vk.Fence{self.in_flight}, .true, std.math.maxInt(u64));
            _ = linux.clock_gettime(.MONOTONIC, &ts);
            self.last_render_ns = @intCast(@as(i128, ts.sec) * 1_000_000_000 + ts.nsec - t0);
        }
        before_present(context);
        const result = dev.queuePresentKHR(self.queue, &.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = &[_]vk.Semaphore{self.render_done},
            .swapchain_count = 1,
            .p_swapchains = &[_]vk.SwapchainKHR{self.swapchain},
            .p_image_indices = &[_]u32{acquired.image_index},
        }) catch |e| switch (e) {
            error.OutOfDateKHR => return .out_of_date,
            else => return e,
        };
        return if (result == .suboptimal_khr) .out_of_date else .presented;
    }
};
