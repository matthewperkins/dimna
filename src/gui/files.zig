//! Writing the files oEZ keeps settings in: the view file and the config's [board] table.

const std = @import("std");
const dimna = @import("dimna");
const panels_mod = dimna.panels;
const Io = std.Io;

/// The panels' settings, the tile window's view and the detection thresholds as the text of
/// a view file, in `buf`; null if it does not fit.
pub fn renderViews(
    buf: []u8,
    set: *const panels_mod.Set,
    tiles: *const dimna.tile_view.TileView,
    thresholds: *const dimna.thresholds.Thresholds,
    electrodes: usize,
) ?[]const u8 {
    var w: Io.Writer = .fixed(buf);
    panels_mod.renderViews(&w, set) catch return null;
    tiles.render(&w, electrodes) catch return null;
    thresholds.render(&w, electrodes) catch return null;
    return w.buffered();
}

/// Writes `text` to the file at `path`: beside it under a temporary name, synced, then
/// renamed over it, so the file is never seen half written.
pub fn writeAtomic(io: Io, path: []const u8, text: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    const name = std.fs.path.basename(path);
    try Io.Dir.cwd().createDirPath(io, dir_path);
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    var tmp_buf: [80]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, ".{s}.tmp", .{name});
    var f = try dir.createFile(io, tmp, .{});
    {
        errdefer f.close(io);
        try f.writeStreamingAll(io, text);
        try f.sync(io);
    }
    f.close(io);
    try Io.Dir.rename(dir, tmp, dir, name, io);
}

/// Writes `settings` into the config file's [board] table, leaving the rest of the file
/// as it is (a new file if there is none). Written beside the file and renamed over it.
pub fn saveBoard(io: Io, gpa: std.mem.Allocator, config_path: []const u8, settings: *const dimna.types.Settings) !void {
    const dir_path = std.fs.path.dirname(config_path) orelse ".";
    const name = std.fs.path.basename(config_path);
    try Io.Dir.cwd().createDirPath(io, dir_path);
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    const old: []const u8 = dir.readFileAlloc(io, name, gpa, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => try gpa.dupe(u8, ""),
        else => return e,
    };
    defer gpa.free(old);
    var table_buf: [512]u8 = undefined;
    const new = try dimna.board_config.replaceTable(gpa, old, dimna.board_config.render(&table_buf, settings));
    defer gpa.free(new);
    var tmp_buf: [80]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, ".{s}.tmp", .{name});
    var f = try dir.createFile(io, tmp, .{});
    {
        errdefer f.close(io);
        try f.writeStreamingAll(io, new);
        try f.sync(io);
    }
    f.close(io);
    try Io.Dir.rename(dir, tmp, dir, name, io);
}
