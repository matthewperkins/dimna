//! Numbers with units, as the display and the control window show them.

const std = @import("std");
const Panel = @import("oez").panels.Panel;

/// "500 ms" or "2.00 s".
pub fn fmtSpan(buf: []u8, s: f64) []const u8 {
    return (if (s < 0.9995) std.fmt.bufPrint(buf, "{d:.0} ms", .{s * 1000}) else std.fmt.bufPrint(buf, "{d:.2} s", .{s})) catch "";
}

/// A panel's scale per row with a unit that keeps the number readable: "400 µV", "1.50 mV",
/// "250 mV", "5.00 V".
pub fn fmtScale(buf: []u8, p: *const Panel) []const u8 {
    const v = p.scale;
    return (if (p.kind == .electrode)
        (if (v < 999.5) std.fmt.bufPrint(buf, "{d:.0} µV", .{v}) else std.fmt.bufPrint(buf, "{d:.2} mV", .{v / 1000}))
    else
        (if (v < 0.9995) std.fmt.bufPrint(buf, "{d:.0} mV", .{v * 1000}) else std.fmt.bufPrint(buf, "{d:.2} V", .{v}))) catch "";
}
