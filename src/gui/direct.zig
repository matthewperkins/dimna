//! The display loop when oez drives a monitor itself, with no compositor (--direct).
//! Experimental, and older than most of the display's features: it has no input, control
//! window, sound, notes or review.

const std = @import("std");
const oez = @import("oez");
const gpu_mod = @import("gpu.zig");
const Gpu = gpu_mod.Gpu;
const font = @import("font.zig");
const control = @import("control.zig");
const Status = control.Status;
const notes_mod = @import("notes.zig");
const Args = @import("args.zig").Args;
const display_mod = @import("display.zig");
const Display = display_mod.Display;
const Text = display_mod.Text;
const makeDisplay = display_mod.makeDisplay;
const max_draws = display_mod.max_draws;
const refilterSamples = display_mod.refilterSamples;
const max_fills = display_mod.max_fills;
const runScript = @import("script.zig").runScript;
const Input = @import("window.zig").Input;
const panels_mod = oez.panels;
const Panel = panels_mod.Panel;
const Io = std.Io;
const log = std.log.scoped(.oez);

fn nowNs(io: Io) i128 {
    return Io.Clock.awake.now(io).nanoseconds;
}

/// The display loop when oez drives the monitor itself (--direct). One frame is in flight at
/// a time: draw `margin` before a refresh, wait until that frame is on screen, repeat. The
/// time a frame reached the screen comes from vkWaitForPresentKHR.
pub fn runDirect(io: Io, gpa: std.mem.Allocator, args: Args, layout: oez.types.Layout, acq: *oez.acquisition.Acquisition, reader: *oez.ring.LossyReader, blk: *oez.types.Block) !u8 {
    const fs = layout.sample_rate;
    var gpu = Gpu.init(gpa, .{ .direct = args.direct }, .fifo, null) catch |e| {
        log.err("direct display on {s} failed: {t}", .{ args.direct, e });
        return 1;
    };
    defer gpu.deinit();
    gpu.wait_render = true;
    var notes = notes_mod.Notes.init(args.doc);
    defer notes.deinit();
    var display = makeDisplay(args, &layout) orelse return 2;
    const history_samples: usize = @intFromFloat((Panel.span_max + 2.0) * fs);
    var feed = try oez.feed.Feed.init(gpa, &layout, &display.set, history_samples);
    defer feed.deinit(gpa);
    display.initial = display.set;
    try gpu.createHistory(feed.width, history_samples);
    try gpu.resize(0, 0);
    const period: i128 = gpu.refresh_period_ns;
    const margin_ms: f64 = if (args.margin_ms >= 0) args.margin_ms else 1.5;
    const margin: i128 = @intFromFloat(margin_ms * 1e6);
    log.info("{d}x{d}, refresh {d:.3} ms, drawing {d:.2} ms before each refresh", .{ gpu.extent.width, gpu.extent.height, @as(f64, @floatFromInt(period)) / 1e6, margin_ms });

    try acq.start();
    defer acq.join();

    var draws: [max_draws]gpu_mod.PanelDraw = undefined;
    var fills: [max_fills]gpu_mod.Fill = undefined;
    var text: Text = .{};
    text.init(gpa, &gpu, args);
    defer text.deinit(gpa);
    var batch = text.batch();
    var status: Status = .{};
    var newest: i64 = 0;
    var newest_acquired_ns: i128 = 0;
    var in_flight: u64 = 0; // present id awaited, 0 = none
    var in_flight_acquired: i128 = 0;
    var in_flight_since: i128 = 0;
    var draw_at: i128 = 0;
    var last_flip: i128 = 0;
    var script_pos: usize = 0;

    const t_start = nowNs(io);
    var next_report: i128 = t_start + std.time.ns_per_s;
    var frames: u64 = 0;
    var lat_sum: f64 = 0;
    var lat_min: f64 = std.math.inf(f64);
    var lat_max: f64 = 0;
    var missed: u64 = 0; // refreshes that passed without a new frame
    var render_sum: f64 = 0; // GPU time per frame, ms
    var render_max: f64 = 0;
    var worst_render: f64 = 0;
    var total_frames: u64 = 0;
    var total_missed: u64 = 0;
    var total_lat: f64 = 0;
    var worst: f64 = 0;

    while (!acq.done.load(.acquire)) {
        while (reader.next(blk)) {
            if (blk.len == 0) continue;
            gpu.writeSamples(blk.first_sample, try feed.rows(gpa, blk.first_sample, blk.samples(), blk.ttl[0..blk.len]));
            display.feedBlock(blk.first_sample, blk.samples(), layout.numChannels(), fs, blk.ttl[0..blk.len]);
            newest = blk.first_sample + @as(i64, @intCast(blk.len));
            newest_acquired_ns = blk.acquired_ns;
        }
        var input: Input = .{};
        if (args.script.len > 0) runScript(args.script, &script_pos, @as(f64, @floatFromInt(nowNs(io) - t_start)) / 1e9, &input, &display);
        if (display.applyInput(input)) break;
        // A panel's corners changed: filter its recent past again.
        if (gpu.hist_cap > 0) _ = try feed.sync(gpa, &display.set, refilterSamples(&display.set, fs), gpu.hist, gpu.hist_cap);

        var now = nowNs(io);
        if (in_flight != 0) {
            // Blocks for up to 1 ms, which also paces this loop.
            if (try gpu.waitPresented(in_flight, std.time.ns_per_ms)) {
                now = nowNs(io);
                const ms = @as(f64, @floatFromInt(now - in_flight_acquired)) / 1e6;
                lat_sum += ms;
                lat_min = @min(lat_min, ms);
                lat_max = @max(lat_max, ms);
                frames += 1;
                if (last_flip != 0 and now - last_flip > period + @divTrunc(period, 2)) missed += @intCast(@divTrunc(now - last_flip + @divTrunc(period, 2), period) - 1);
                last_flip = now;
                // Finished (not just started) `margin` before the next refresh.
                draw_at = now + period - margin - gpu.renderEstimateNs();
                in_flight = 0;
            } else if (now - in_flight_since > 2 * std.time.ns_per_s) {
                log.err("a frame was not shown within 2 s; giving up", .{});
                return 1;
            }
        } else if (newest > 0 and now >= draw_at) {
            const fr = display.frame(&gpu, &layout, newest, null, status, &notes, &batch, &draws, &fills);
            const result = try gpu.draw(fr.draws, fr.fills, fr.text, {}, struct {
                fn f(_: void) void {}
            }.f);
            switch (result) {
                .presented => {
                    in_flight = gpu.present_id;
                    in_flight_acquired = newest_acquired_ns;
                    in_flight_since = now;
                    const r = @as(f64, @floatFromInt(gpu.last_render_ns)) / 1e6;
                    render_sum += r;
                    render_max = @max(render_max, r);
                },
                .out_of_date => try gpu.resize(0, 0),
                .busy => {},
            }
        } else {
            const wait = std.math.clamp(draw_at - now, 0, std.time.ns_per_ms);
            if (wait > 0) io.sleep(.fromNanoseconds(@intCast(wait)), .awake) catch {};
        }

        if (now >= next_report) {
            const secs = @as(f64, @floatFromInt(now - t_start)) / 1e9;
            log.info("t={d:.0}s {d} fps, latency ms avg {d:.2} min {d:.2} max {d:.2}, refreshes without a new frame {d}, GPU ms per frame avg {d:.2} max {d:.2}, display lost {d} blocks, ring overflow {d}", .{
                secs, frames, if (frames > 0) lat_sum / @as(f64, @floatFromInt(frames)) else 0, if (frames > 0) lat_min else 0, lat_max, missed, if (frames > 0) render_sum / @as(f64, @floatFromInt(frames)) else 0, render_max, reader.lost, acq.ring_overflow.load(.monotonic),
            });
            status = .{ .valid = frames > 0, .latency_ms = if (frames > 0) lat_sum / @as(f64, @floatFromInt(frames)) else 0, .fps = frames, .lost = reader.lost };
            if (secs > 1.5) worst_render = @max(worst_render, render_max);
            render_sum = 0;
            render_max = 0;
            if (secs > 1.5) {
                total_frames += frames;
                total_missed += missed;
                total_lat += lat_sum;
                worst = @max(worst, lat_max);
            }
            frames = 0;
            lat_sum = 0;
            lat_min = std.math.inf(f64);
            lat_max = 0;
            missed = 0;
            next_report += std.time.ns_per_s;
        }
        if (args.seconds > 0 and @as(f64, @floatFromInt(now - t_start)) >= args.seconds * 1e9) break;
    }
    if (total_frames > 0) log.info("direct on {s}, margin {d:.2} ms: {d} frames, latency avg {d:.2} ms, worst {d:.2} ms, refreshes without a new frame {d}, slowest GPU frame {d:.2} ms", .{ args.direct, margin_ms, total_frames, total_lat / @as(f64, @floatFromInt(total_frames)), worst, total_missed, worst_render });
    if (acq.done.load(.acquire)) {
        log.err("acquisition ended early: {t}", .{acq.failure orelse error.Unknown});
        return 1;
    }
    return 0;
}
