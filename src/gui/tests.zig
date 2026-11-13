//! Root of the GUI's unit tests (`zig build test`). A test in a file of this module runs
//! only if the file is referenced from a `test` block here, so each file with tests is
//! listed below. None of these tests opens a window, connects to Wayland, creates a Vulkan
//! instance or opens a sound device: they are the GUI's pure logic.

test {
    _ = @import("control.zig");
    _ = @import("notes.zig");
    _ = @import("tiles.zig");
    _ = @import("ui.zig");
}
