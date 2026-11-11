//! `oez --lease-probe`: lists the monitors the compositor offers for DRM leasing
//! (wp_drm_lease_device_v1). Read-only: it asks for nothing.

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const linux = std.os.linux;

const State = struct {
    devices: [4]?*wp.DrmLeaseDeviceV1 = @splat(null),
    num_devices: usize = 0,
    connectors: usize = 0,
};

fn onRegistry(registry: *wl.Registry, event: wl.Registry.Event, st: *State) void {
    switch (event) {
        .global => |g| {
            if (std.mem.eql(u8, std.mem.span(g.interface), std.mem.span(wp.DrmLeaseDeviceV1.interface.name)) and st.num_devices < st.devices.len) {
                const dev = registry.bind(g.name, wp.DrmLeaseDeviceV1, 1) catch return;
                dev.setListener(*State, onDevice, st);
                st.devices[st.num_devices] = dev;
                st.num_devices += 1;
            }
        },
        .global_remove => {},
    }
}

fn onDevice(_: *wp.DrmLeaseDeviceV1, event: wp.DrmLeaseDeviceV1.Event, st: *State) void {
    switch (event) {
        .drm_fd => |f| {
            std.debug.print("lease device: got a DRM descriptor (fd {d})\n", .{f.fd});
            _ = linux.close(f.fd);
        },
        .connector => |c| {
            st.connectors += 1;
            c.id.setListener(*State, onConnector, st);
        },
        .done => {},
        .released => {},
    }
}

fn onConnector(_: *wp.DrmLeaseConnectorV1, event: wp.DrmLeaseConnectorV1.Event, _: *State) void {
    switch (event) {
        .name => |n| std.debug.print("  leasable connector: {s}\n", .{n.name}),
        .description => |d| std.debug.print("    description: {s}\n", .{d.description}),
        .connector_id => |c| std.debug.print("    DRM connector id: {d}\n", .{c.connector_id}),
        .done, .withdrawn => {},
    }
}

pub fn run() u8 {
    const display = wl.Display.connect(null) catch return 1;
    defer display.disconnect();
    const registry = display.getRegistry() catch return 1;
    var st: State = .{};
    registry.setListener(*State, onRegistry, &st);
    // Globals, then the devices' events, then the connectors' events.
    for (0..3) |_| _ = display.roundtrip();
    std.debug.print("{d} lease device(s), {d} connector(s) offered for lease\n", .{ st.num_devices, st.connectors });
    return 0;
}
