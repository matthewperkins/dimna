//! Vulkan for the trace window: instance and device on a Wayland surface, the swapchain, a
//! ring of sample history that the GPU reads directly, and the pipeline that draws traces
//! from it (`shaders/traces.vert`).
//!
//! Only new samples cross to the GPU: each block is written once into the history ring
//! (mapped memory, device-local when the driver offers it). Everything per pixel (min/max
//! per column, scaling, layout) happens in the vertex shader.

const std = @import("std");
const vk = @import("vulkan");
const log = std.log.scoped(.gpu);

extern fn vkGetInstanceProcAddr(instance: ?vk.Instance, name: [*:0]const u8) vk.PfnVoidFunction;

pub const PresentMode = enum { auto, mailbox, immediate, fifo };

/// Where frames go.
pub const Target = union(enum) {
    /// A Wayland surface: the compositor shows the frames.
    wayland: struct { display: *anyopaque, surface: *anyopaque },
    /// A monitor that oez drives itself, named by its connector (e.g. "DP-2"). Needs the
    /// kernel's permission to drive it: no compositor on it (a text console), a lease, or a
    /// graphics card of its own.
    direct: []const u8,
};

const linux = std.os.linux;

/// Finds the DRM card and connector id of a connector name through sysfs.
fn findConnector(name: []const u8) ?struct { card: u32, connector_id: u32 } {
    var card: u32 = 0;
    while (card < 8) : (card += 1) {
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buf, "/sys/class/drm/card{d}-{s}/connector_id", .{ card, name }, 0) catch return null;
        const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) continue;
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        var buf: [32]u8 = undefined;
        const n = linux.read(fd, &buf, buf.len);
        if (linux.errno(n) != .SUCCESS) continue;
        const id = std.fmt.parseInt(u32, std.mem.trim(u8, buf[0..n], " \n"), 10) catch continue;
        return .{ .card = card, .connector_id = id };
    }
    return null;
}

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
};

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

    /// Sample history: `hist_cap` samples of `nch` interleaved int16, a ring indexed by
    /// absolute sample number.
    hist_buf: vk.Buffer = .null,
    hist_mem: vk.DeviceMemory = .null,
    hist: []i16 = &.{},
    hist_cap: usize = 0,
    nch: usize = 0,
    hist_device_local: bool = false,

    // Direct display only.
    direct: bool = false,
    drm_fd: i32 = -1,
    display: vk.DisplayKHR = .null,
    /// The monitor's refresh period in ns.
    refresh_period_ns: u64 = 0,
    present_id: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, target: Target, mode: PresentMode) !Gpu {
        const vkb = vk.BaseWrapper.load(vkGetInstanceProcAddr);
        const wayland_exts = [_][*:0]const u8{ "VK_KHR_surface", "VK_KHR_wayland_surface" };
        const direct_exts = [_][*:0]const u8{ "VK_KHR_surface", "VK_KHR_display", "VK_EXT_direct_mode_display", "VK_EXT_acquire_drm_display" };
        const instance_exts: []const [*:0]const u8 = if (target == .direct) &direct_exts else &wayland_exts;
        const instance_handle = try vkb.createInstance(&.{
            .p_application_info = &.{
                .p_application_name = "oez",
                .application_version = 0,
                .p_engine_name = "oez",
                .engine_version = 0,
                .api_version = @bitCast(vk.API_VERSION_1_2),
            },
            .enabled_extension_count = @intCast(instance_exts.len),
            .pp_enabled_extension_names = instance_exts.ptr,
        }, null);
        const vki = try gpa.create(vk.InstanceWrapper);
        errdefer gpa.destroy(vki);
        vki.* = vk.InstanceWrapper.load(instance_handle, vkb.dispatch.vkGetInstanceProcAddr.?);
        const instance = vk.InstanceProxy.init(instance_handle, vki);
        errdefer instance.destroyInstance(null);

        const pdevs = try instance.enumeratePhysicalDevicesAlloc(gpa);
        defer gpa.free(pdevs);

        var drm_fd: i32 = -1;
        errdefer if (drm_fd >= 0) {
            _ = linux.close(drm_fd);
        };
        var display: vk.DisplayKHR = .null;
        var display_pdev: ?vk.PhysicalDevice = null;
        var refresh_period_ns: u64 = 0;
        const surface = switch (target) {
            .wayland => |w| try instance.createWaylandSurfaceKHR(&.{ .display = @ptrCast(w.display), .surface = @ptrCast(w.surface) }, null),
            .direct => |name| blk: {
                // The monitor's DRM connector, a descriptor on its card, and from those the
                // Vulkan display. Opening the card makes us its master only if nobody else is.
                const conn = findConnector(name) orelse {
                    log.err("no connector named '{s}' under /sys/class/drm", .{name});
                    return error.NoSuchMonitor;
                };
                var path_buf: [32]u8 = undefined;
                const path = std.fmt.bufPrintSentinel(&path_buf, "/dev/dri/card{d}", .{conn.card}, 0) catch unreachable;
                const rc = linux.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
                if (linux.errno(rc) != .SUCCESS) {
                    log.err("cannot open {s}: {t}", .{ path, linux.errno(rc) });
                    return error.DisplayNotAvailable;
                }
                drm_fd = @intCast(rc);
                for (pdevs) |pd| {
                    display = instance.getDrmDisplayEXT(pd, drm_fd, conn.connector_id) catch continue;
                    display_pdev = pd;
                    break;
                }
                const pd = display_pdev orelse {
                    log.err("no Vulkan device drives connector {d} ({s})", .{ conn.connector_id, name });
                    return error.DisplayNotAvailable;
                };
                instance.acquireDrmDisplayEXT(pd, drm_fd, display) catch |e| {
                    log.err("cannot take over {s} ({t}): something else is driving it. Run from a text console, or with a lease or a graphics card of its own.", .{ name, e });
                    return error.DisplayNotAvailable;
                };
                // The largest mode, at its highest refresh rate.
                var mode_buf: [128]vk.DisplayModePropertiesKHR = undefined;
                var mode_count: u32 = mode_buf.len;
                _ = try instance.getDisplayModePropertiesKHR(pd, display, &mode_count, &mode_buf);
                const modes = mode_buf[0..mode_count];
                if (modes.len == 0) return error.DisplayNotAvailable;
                var best = modes[0];
                for (modes) |m| {
                    const a = @as(u64, m.parameters.visible_region.width) * m.parameters.visible_region.height;
                    const b = @as(u64, best.parameters.visible_region.width) * best.parameters.visible_region.height;
                    if (a > b or (a == b and m.parameters.refresh_rate > best.parameters.refresh_rate)) best = m;
                }
                refresh_period_ns = 1_000_000_000_000 / @as(u64, @max(best.parameters.refresh_rate, 1));
                log.info("{s}: {d}x{d} at {d:.3} Hz, driven directly", .{ name, best.parameters.visible_region.width, best.parameters.visible_region.height, @as(f64, @floatFromInt(best.parameters.refresh_rate)) / 1000.0 });
                // A plane that can show this display.
                var plane_buf: [64]vk.DisplayPlanePropertiesKHR = undefined;
                var plane_count: u32 = plane_buf.len;
                _ = try instance.getPhysicalDeviceDisplayPlanePropertiesKHR(pd, &plane_count, &plane_buf);
                const planes = plane_buf[0..plane_count];
                var plane: ?u32 = null;
                for (planes, 0..) |pl, i| {
                    if (pl.current_display != .null and pl.current_display != display) continue;
                    var supported_buf: [16]vk.DisplayKHR = undefined;
                    var supported_count: u32 = supported_buf.len;
                    _ = try instance.getDisplayPlaneSupportedDisplaysKHR(pd, @intCast(i), &supported_count, &supported_buf);
                    const supported = supported_buf[0..supported_count];
                    if (std.mem.indexOfScalar(vk.DisplayKHR, supported, display) != null) {
                        plane = @intCast(i);
                        break;
                    }
                }
                const plane_index = plane orelse return error.DisplayNotAvailable;
                break :blk try instance.createDisplayPlaneSurfaceKHR(&.{
                    .display_mode = best.display_mode,
                    .plane_index = plane_index,
                    .plane_stack_index = planes[plane_index].current_stack_index,
                    .transform = .{ .identity_khr = true },
                    .global_alpha = 1.0,
                    .alpha_mode = .{ .opaque_khr = true },
                    .image_extent = best.parameters.visible_region,
                }, null);
            },
        };
        errdefer instance.destroySurfaceKHR(surface, null);

        // A device with a queue family that does graphics and can present to this surface;
        // a discrete GPU if there is one (direct: the device that drives the monitor).
        var chosen: ?vk.PhysicalDevice = null;
        var chosen_family: u32 = 0;
        var chosen_discrete = false;
        for (pdevs) |pd| {
            if (display_pdev != null and pd != display_pdev.?) continue;
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
        // Direct display: present ids and waiting for a present tell when a frame reached
        // the screen (the role presentation feedback has on Wayland).
        const wayland_dev_exts = [_][*:0]const u8{"VK_KHR_swapchain"};
        const direct_dev_exts = [_][*:0]const u8{ "VK_KHR_swapchain", "VK_KHR_present_id", "VK_KHR_present_wait" };
        const device_exts: []const [*:0]const u8 = if (target == .direct) &direct_dev_exts else &wayland_dev_exts;
        var wait_feature: vk.PhysicalDevicePresentWaitFeaturesKHR = .{ .present_wait = .true };
        var id_feature: vk.PhysicalDevicePresentIdFeaturesKHR = .{ .present_id = .true, .p_next = &wait_feature };
        const device_handle = instance.createDevice(pdev, &.{
            .p_next = if (target == .direct) &id_feature else null,
            .queue_create_info_count = 1,
            .p_queue_create_infos = &[_]vk.DeviceQueueCreateInfo{.{ .queue_family_index = chosen_family, .queue_count = 1, .p_queue_priorities = &priority }},
            .enabled_extension_count = @intCast(device_exts.len),
            .pp_enabled_extension_names = device_exts.ptr,
        }, null) catch |e| {
            if (target == .direct) log.err("device creation failed ({t}); direct display needs VK_KHR_present_id and VK_KHR_present_wait", .{e});
            return e;
        };
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
            .direct = target == .direct,
            .drm_fd = drm_fd,
            .display = display,
            .refresh_period_ns = refresh_period_ns,
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
        // Direct display: FIFO, one frame in flight, flipped at the refresh.
        self.present_mode = if (target == .direct) .fifo_khr else switch (mode) {
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
        if (self.direct) {
            self.instance.releaseDisplayEXT(self.pdev, self.display) catch {};
            _ = linux.close(self.drm_fd);
        }
        self.instance.destroyInstance(null);
        self.gpa.destroy(self.vkd);
        self.gpa.destroy(self.vki);
    }

    fn createPipeline(self: *Gpu) !void {
        const dev = self.dev;
        self.set_layout = try dev.createDescriptorSetLayout(&.{
            .binding_count = 1,
            .p_bindings = &[_]vk.DescriptorSetLayoutBinding{.{
                .binding = 0,
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{ .vertex = true },
            }},
        }, null);
        self.pipeline_layout = try dev.createPipelineLayout(&.{
            .set_layout_count = 1,
            .p_set_layouts = &[_]vk.DescriptorSetLayout{self.set_layout},
            .push_constant_range_count = 1,
            .p_push_constant_ranges = &[_]vk.PushConstantRange{.{ .stage_flags = .{ .vertex = true }, .offset = 0, .size = @sizeOf(TraceParams) }},
        }, null);
        self.desc_pool = try dev.createDescriptorPool(&.{
            .max_sets = 1,
            .pool_size_count = 1,
            .p_pool_sizes = &[_]vk.DescriptorPoolSize{.{ .type = .storage_buffer, .descriptor_count = 1 }},
        }, null);
        var sets: [1]vk.DescriptorSet = undefined;
        try dev.allocateDescriptorSets(&.{ .descriptor_pool = self.desc_pool, .descriptor_set_count = 1, .p_set_layouts = &[_]vk.DescriptorSetLayout{self.set_layout} }, &sets);
        self.desc_set = sets[0];

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

    fn findMemoryType(self: *const Gpu, type_bits: u32, flags: vk.MemoryPropertyFlags) ?u32 {
        for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |t, i| {
            if (type_bits & (@as(u32, 1) << @intCast(i)) != 0 and t.property_flags.contains(flags)) return @intCast(i);
        }
        return null;
    }

    /// Creates the sample-history ring: at least `min_samples` samples (rounded up to a
    /// power of two) of `nch` channels. Call once before drawing.
    pub fn createHistory(self: *Gpu, nch: usize, min_samples: usize) !void {
        const dev = self.dev;
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

    /// Direct display: waits up to `timeout_ns` for the frame with present id `id` (the value
    /// of `present_id` after its `draw`) to reach the screen. True once it has.
    pub fn waitPresented(self: *Gpu, id: u64, timeout_ns: u64) !bool {
        const r = self.dev.waitForPresentKHR(self.swapchain, id, timeout_ns) catch |e| switch (e) {
            error.OutOfDateKHR => return true,
            else => return e,
        };
        return r == .success;
    }

    pub const DrawResult = enum {
        presented,
        /// The swapchain no longer fits the window: call `resize`.
        out_of_date,
        /// No swapchain image was free; nothing was drawn. Try again shortly.
        busy,
    };

    /// Draws one frame of traces and presents it. `before_present` runs right before the
    /// frame is handed to the compositor (frame callback and presentation feedback requests
    /// must be made then, so they attach to this frame's commit).
    pub fn draw(self: *Gpu, params: TraceParams, context: anytype, comptime before_present: fn (@TypeOf(context)) void) !DrawResult {
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
        if (params.rows > 0 and params.cols > 0 and self.hist_cap > 0) {
            dev.cmdBindPipeline(cmd, .graphics, self.pipeline);
            dev.cmdSetViewport(cmd, 0, &[_]vk.Viewport{.{ .x = 0, .y = 0, .width = @floatFromInt(self.extent.width), .height = @floatFromInt(self.extent.height), .min_depth = 0, .max_depth = 1 }});
            dev.cmdSetScissor(cmd, 0, &[_]vk.Rect2D{area});
            dev.cmdBindDescriptorSets(cmd, .graphics, self.pipeline_layout, 0, &[_]vk.DescriptorSet{self.desc_set}, null);
            dev.cmdPushConstants(cmd, self.pipeline_layout, .{ .vertex = true }, 0, @sizeOf(TraceParams), @ptrCast(&params));
            dev.cmdDraw(cmd, 2 * params.cols, params.rows, 0, 0);
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

        before_present(context);
        self.present_id += 1;
        const ids = [_]u64{self.present_id};
        const id_info: vk.PresentIdKHR = .{ .swapchain_count = 1, .p_present_ids = &ids };
        const result = dev.queuePresentKHR(self.queue, &.{
            .p_next = if (self.direct) &id_info else null,
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
