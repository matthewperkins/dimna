const std = @import("std");
const wayland = @import("wayland");
const vk = @import("vulkan");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const wp = wayland.client.wp;
const zwp = wayland.client.zwp;

extern fn vkGetInstanceProcAddr(instance: ?vk.Instance, name: [*:0]const u8) vk.PfnVoidFunction;

pub fn main() !void {
    const display = try wl.Display.connect(null);
    defer display.disconnect();
    const vkb = vk.BaseWrapper.load(vkGetInstanceProcAddr);
    const ver: vk.Version = @bitCast(try vkb.enumerateInstanceVersion());
    std.debug.print("wayland fd {d}; vulkan loader {d}.{d}.{d}; {s} {s} {s} {s}; spv {d}+{d} bytes\n", .{
        display.getFd(), ver.major, ver.minor, ver.patch,
        xdg.WmBase.interface.name, wp.Presentation.interface.name, zwp.PointerGesturesV1.interface.name, wl.Seat.interface.name,
        @embedFile("traces.vert.spv").len, @embedFile("traces.frag.spv").len,
    });
}
