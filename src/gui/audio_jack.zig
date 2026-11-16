//! The spike audio monitor through a JACK server: a client named "dimna" with two output
//! ports (left, right), connected to the first two physical playback ports. The server's
//! real-time thread calls `process` once a period; it has `AudioOut.render` fill the
//! period into a scratch buffer made before the client was activated, and copies the two
//! channels to the ports.
//!
//! `libjack.so.0` is opened at run time (as `shape.zig` opens HarfBuzz): no JACK header
//! and no link dependency. dimna never starts a server (`JackNoStartServer`): without one
//! running, `open` fails and the caller decides (ALSA for `auto`, silence for `jack`).
//!
//! What the server says about us: its rate is the queue's (`fs_out`, known before the
//! feeder starts); its buffer size is `max_request`, kept by the buffer-size callback; the
//! playback latency of our ports (the most of either, in frames) is `device_delay`, kept
//! by the latency callback; each xrun it reports adds one to `Shared.xruns`. If the server
//! goes away, `running` goes false and the monitor is silent: there is no reconnecting.
//!
//! The process thread is libjack's, at the real-time priority the server gives its
//! clients (logged at start-up); dimna does not change it.

const std = @import("std");
const AudioOut = @import("audio_out.zig").AudioOut;
const Atomic = std.atomic.Value;
const log = std.log.scoped(.audio);

const Client = opaque {};
const Port = opaque {};
/// jack_latency_range_t (jack/types.h).
const LatencyRange = extern struct { min: u32, max: u32 };

// jack/types.h
/// JackNoStartServer, JackServerName (jack_options_t).
const option_no_start_server: c_int = 0x01;
const option_server_name: c_int = 0x04;
/// JackServerFailed (jack_status_t).
const status_server_failed: c_int = 0x10;
/// JackPortIsInput, JackPortIsOutput, JackPortIsPhysical (JackPortFlags).
const port_is_input: c_ulong = 0x1;
const port_is_output: c_ulong = 0x2;
const port_is_physical: c_ulong = 0x4;
/// JackPlaybackLatency (jack_latency_callback_mode_t: JackCaptureLatency is 0).
const playback_latency: c_int = 1;
/// What jack_connect returns for a connection already made (EEXIST on Linux).
const eexist: c_int = 17;
/// JACK_DEFAULT_AUDIO_TYPE.
const audio_type = "32 bit float mono audio";

/// The most frames one process callback can ask for: JACK2's largest buffer size
/// (BUFFER_SIZE_MAX). The scratch buffer is this size, so a buffer-size change never needs
/// a new one; a larger request would be filled in pieces.
pub const max_frames = 8192;

const ProcessCallback = *const fn (u32, ?*anyopaque) callconv(.c) c_int;
const PlainCallback = *const fn (?*anyopaque) callconv(.c) c_int;

/// The functions used, looked up by their field names (jack/jack.h, jack/thread.h).
pub const Api = struct {
    jack_client_open: *const fn ([*:0]const u8, c_int, ?*c_int, ...) callconv(.c) ?*Client,
    jack_client_close: *const fn (*Client) callconv(.c) c_int,
    jack_get_client_name: *const fn (*Client) callconv(.c) [*:0]const u8,
    jack_activate: *const fn (*Client) callconv(.c) c_int,
    jack_deactivate: *const fn (*Client) callconv(.c) c_int,
    jack_set_process_callback: *const fn (*Client, ProcessCallback, ?*anyopaque) callconv(.c) c_int,
    jack_set_buffer_size_callback: *const fn (*Client, ProcessCallback, ?*anyopaque) callconv(.c) c_int,
    jack_set_xrun_callback: *const fn (*Client, PlainCallback, ?*anyopaque) callconv(.c) c_int,
    jack_set_latency_callback: *const fn (*Client, *const fn (c_int, ?*anyopaque) callconv(.c) void, ?*anyopaque) callconv(.c) c_int,
    jack_on_shutdown: *const fn (*Client, *const fn (?*anyopaque) callconv(.c) void, ?*anyopaque) callconv(.c) void,
    jack_get_sample_rate: *const fn (*Client) callconv(.c) u32,
    jack_get_buffer_size: *const fn (*Client) callconv(.c) u32,
    jack_set_buffer_size: *const fn (*Client, u32) callconv(.c) c_int,
    jack_port_register: *const fn (*Client, [*:0]const u8, [*:0]const u8, c_ulong, c_ulong) callconv(.c) ?*Port,
    jack_port_get_buffer: *const fn (*Port, u32) callconv(.c) ?*anyopaque,
    jack_port_name: *const fn (*const Port) callconv(.c) [*:0]const u8,
    jack_get_ports: *const fn (*Client, ?[*:0]const u8, ?[*:0]const u8, c_ulong) callconv(.c) ?[*]?[*:0]const u8,
    jack_connect: *const fn (*Client, [*:0]const u8, [*:0]const u8) callconv(.c) c_int,
    jack_port_get_latency_range: *const fn (*Port, c_int, *LatencyRange) callconv(.c) void,
    jack_free: *const fn (?*anyopaque) callconv(.c) void,
    jack_client_real_time_priority: *const fn (*Client) callconv(.c) c_int,
    jack_set_error_function: *const fn (*const fn ([*:0]const u8) callconv(.c) void) callconv(.c) void,
    jack_set_info_function: *const fn (*const fn ([*:0]const u8) callconv(.c) void) callconv(.c) void,
};

/// Loaded by the thread that starts the audio output (`lib`), and only read after that.
var api_state: enum { untried, loaded, missing } = .untried;
var api: Api = undefined;

/// libjack, opened the first time this is called and kept open; null if it or one of its
/// functions is missing.
pub fn lib() ?*const Api {
    switch (api_state) {
        .loaded => return &api,
        .missing => return null,
        .untried => {},
    }
    api_state = .missing;
    var l = std.DynLib.open("libjack.so.0") catch return null;
    const info = @typeInfo(Api).@"struct";
    inline for (info.field_names, info.field_types) |field, FieldType| {
        @field(api, field) = l.lookup(FieldType, field) orelse {
            l.close();
            return null;
        };
    }
    // libjack prints its errors (e.g. "Cannot connect to server socket" when no server
    // runs, which `auto` expects) to stderr itself, from any of its threads; `open` says
    // why JACK is not used instead.
    api.jack_set_error_function(quiet);
    api.jack_set_info_function(quiet);
    api_state = .loaded;
    return &api;
}

fn quiet(_: [*:0]const u8) callconv(.c) void {}

/// The client, once `open` has made it (it lives in `AudioOut.jack`, which the callbacks
/// point at).
pub const Device = struct {
    out: *AudioOut,
    client: *Client,
    ports: [2]*Port,
    /// Interleaved stereo, `max_frames` frames, made before activation.
    scratch: []f32,
    /// The real-time priority of the client's process thread, as the server reports it
    /// (-1: not real-time).
    priority: c_int,
    active: bool = false,
    /// Set by the shutdown callback: the server is gone.
    gone: Atomic(bool) = .init(false),

    /// The client's name on the server ("dimna", or "dimna-01" if that was taken).
    pub fn name(self: *const Device) [*:0]const u8 {
        return api.jack_get_client_name(self.client);
    }
};

/// Connects to the server (`server`, or the default one) without starting one, registers
/// the two ports and the callbacks, and sets `out.fs_out`, `out.max_request` and
/// `out.device_buffer` from the server. Puts the client in `out.jack`; not yet active
/// (`activate`), so nothing calls `render` until then.
pub fn open(out: *AudioOut, server: ?[*:0]const u8) !void {
    const j = lib() orelse return error.NoLibjack;
    var status: c_int = 0;
    const client = (if (server) |s|
        j.jack_client_open("dimna", option_no_start_server | option_server_name, &status, s)
    else
        j.jack_client_open("dimna", option_no_start_server, &status)) orelse
        return if (status & status_server_failed != 0) error.NoServerRunning else error.ClientRefused;
    errdefer _ = j.jack_client_close(client);
    const left = j.jack_port_register(client, "left", audio_type, port_is_output, 0) orelse return error.NoPorts;
    const right = j.jack_port_register(client, "right", audio_type, port_is_output, 0) orelse return error.NoPorts;
    const scratch = try out.gpa.alloc(f32, 2 * max_frames);
    errdefer out.gpa.free(scratch);
    out.jack = .{
        .out = out,
        .client = client,
        .ports = .{ left, right },
        .scratch = scratch,
        .priority = j.jack_client_real_time_priority(client),
    };
    errdefer out.jack = null;
    const dev = &out.jack.?;
    if (j.jack_set_process_callback(client, process, dev) != 0 or
        j.jack_set_buffer_size_callback(client, bufferSize, dev) != 0 or
        j.jack_set_xrun_callback(client, xrun, dev) != 0 or
        j.jack_set_latency_callback(client, latency, dev) != 0) return error.CallbacksRefused;
    j.jack_on_shutdown(client, shutdown, dev);
    out.fs_out = @floatFromInt(j.jack_get_sample_rate(client));
    const frames = j.jack_get_buffer_size(client);
    out.max_request.store(frames, .monotonic);
    out.device_buffer = frames;
}

/// Starts the process callback and connects the ports to the first two physical playback
/// ports (one port only: both to it; none: left unconnected, with a warning).
pub fn activate(dev: *Device) !void {
    const j = &api;
    if (j.jack_activate(dev.client) != 0) return error.ActivateFailed;
    dev.active = true;
    const physical = j.jack_get_ports(dev.client, null, audio_type, port_is_physical | port_is_input);
    defer if (physical) |p| j.jack_free(@ptrCast(p));
    var count: usize = 0;
    if (physical) |p| while (p[count] != null) : (count += 1) {};
    if (count == 0) {
        log.warn("JACK: no physical playback ports; dimna's ports are not connected", .{});
        return;
    }
    for (dev.ports, 0..) |port, i| {
        const to = physical.?[@min(i, count - 1)].?;
        const rc = j.jack_connect(dev.client, j.jack_port_name(port), to);
        if (rc != 0 and rc != eexist) log.warn("JACK: cannot connect {s} to {s}", .{ j.jack_port_name(port), to });
    }
    readLatency(dev);
}

/// Stops the callbacks and leaves the server (also after it has gone away).
pub fn close(dev: *Device) void {
    const j = &api;
    if (dev.active and !dev.gone.load(.acquire)) _ = j.jack_deactivate(dev.client);
    _ = j.jack_client_close(dev.client);
    dev.out.gpa.free(dev.scratch);
    dev.active = false;
}

/// The server's real-time thread, once a period: `nframes` frames for each port. Calls
/// nothing that may block: `render` (atomics only), port buffers, copying.
fn process(nframes: u32, arg: ?*anyopaque) callconv(.c) c_int {
    const dev: *Device = @ptrCast(@alignCast(arg.?));
    const left: [*]f32 = @ptrCast(@alignCast(api.jack_port_get_buffer(dev.ports[0], nframes) orelse return 0));
    const right: [*]f32 = @ptrCast(@alignCast(api.jack_port_get_buffer(dev.ports[1], nframes) orelse return 0));
    var done: usize = 0;
    while (done < nframes) {
        const n = @min(nframes - done, max_frames);
        const buf = dev.scratch[0 .. 2 * n];
        dev.out.render(buf, n);
        split(buf, left[done..][0..n], right[done..][0..n]);
        done += n;
    }
    return 0;
}

/// Interleaved stereo into two channels.
pub fn split(interleaved: []const f32, left: []f32, right: []f32) void {
    for (left, right, 0..) |*l, *r, i| {
        l.* = interleaved[2 * i];
        r.* = interleaved[2 * i + 1];
    }
}

/// Called by JACK outside the process cycle when the server's buffer size changes.
fn bufferSize(nframes: u32, arg: ?*anyopaque) callconv(.c) c_int {
    const dev: *Device = @ptrCast(@alignCast(arg.?));
    dev.out.max_request.store(nframes, .monotonic);
    return 0;
}

fn xrun(arg: ?*anyopaque) callconv(.c) c_int {
    const dev: *Device = @ptrCast(@alignCast(arg.?));
    _ = dev.out.shared.xruns.fetchAdd(1, .monotonic);
    return 0;
}

/// Called by JACK when latencies change (the ports were connected, the graph changed).
fn latency(mode: c_int, arg: ?*anyopaque) callconv(.c) void {
    if (mode != playback_latency) return;
    readLatency(@ptrCast(@alignCast(arg.?)));
}

/// The playback latency of our ports, the most of either: from our ports to the edge of
/// the JACK graph, as the server and its driver report it.
fn readLatency(dev: *Device) void {
    var most: u32 = 0;
    for (dev.ports) |port| {
        var r: LatencyRange = .{ .min = 0, .max = 0 };
        api.jack_port_get_latency_range(port, playback_latency, &r);
        most = @max(most, r.max);
    }
    dev.out.device_delay.store(most, .monotonic);
}

/// The server has gone away (as a signal handler: flags only).
fn shutdown(arg: ?*anyopaque) callconv(.c) void {
    const dev: *Device = @ptrCast(@alignCast(arg.?));
    dev.gone.store(true, .release);
    dev.out.shared.running.store(false, .release);
}

// ---- tests ----

const testing = std.testing;

test "split: interleaved stereo into the two ports' buffers" {
    const inter = [_]f32{ 1, -1, 2, -2, 3, -3 };
    var l: [3]f32 = undefined;
    var r: [3]f32 = undefined;
    split(&inter, &l, &r);
    try testing.expectEqualSlices(f32, &.{ 1, 2, 3 }, &l);
    try testing.expectEqualSlices(f32, &.{ -1, -2, -3 }, &r);
}

const dimna = @import("dimna");
const audio_out = @import("audio_out.zig");

/// A second client for the test: two input ports fed from dimna's, and what reached them.
const Sink = struct {
    client: *Client,
    ins: [2]*Port,
    frames: Atomic(u64) = .init(0),
    /// Sum of squares of each channel, in millionths.
    energy: [2]Atomic(u64) = .{ .init(0), .init(0) },
    /// Spin this long (ns) in the next process call once, to make the server report an xrun.
    stall_ns: Atomic(u64) = .init(0),

    fn process(nframes: u32, arg: ?*anyopaque) callconv(.c) c_int {
        const self: *Sink = @ptrCast(@alignCast(arg.?));
        for (self.ins, 0..) |port, c| {
            const b: [*]const f32 = @ptrCast(@alignCast(api.jack_port_get_buffer(port, nframes) orelse return 0));
            var sum: f64 = 0;
            for (b[0..nframes]) |v| sum += v * v;
            _ = self.energy[c].fetchAdd(@intFromFloat(sum * 1e6), .monotonic);
        }
        _ = self.frames.fetchAdd(nframes, .monotonic);
        const stall = self.stall_ns.swap(0, .monotonic);
        if (stall > 0) {
            const until = dimna.clock.nowNs() + stall;
            while (dimna.clock.nowNs() < until) std.atomic.spinLoopHint();
        }
        return 0;
    }
};

/// Writes blocks of a known signal into the ring at the rate the board would (30 kHz),
/// until `stop` is set.
fn produce(ring: *dimna.ring.BlockRing, fs: f64, stop: *Atomic(bool)) void {
    const bs = ring.slots[0].capacity;
    const nch = ring.slots[0].num_channels;
    const block_ns: i128 = @intFromFloat(@as(f64, @floatFromInt(bs)) / fs * 1e9);
    var next = dimna.clock.nowNs();
    var sample: i64 = 0;
    var rng: u32 = 12345;
    while (!stop.load(.acquire)) {
        const now = dimna.clock.nowNs();
        if (now < next) {
            dimna.os.sleepNs(@intCast(next - now));
            continue;
        }
        next += block_ns;
        const blk = ring.writeSlot() orelse continue;
        for (0..bs) |s| {
            for (0..nch) |c| {
                rng ^= rng << 13;
                rng ^= rng >> 17;
                rng ^= rng << 5;
                // Noise of a few tens of units, and a spike-like dip every 25 ms.
                const noise: i32 = @as(i32, @intCast(rng % 81)) - 40;
                const dip: i32 = if (@mod(sample + @as(i64, @intCast(s)), 750) < 15) -400 else 0;
                blk.data[s * nch + c] = @intCast(noise + dip);
            }
            blk.hw_time[s] = @intCast(sample + @as(i64, @intCast(s)));
            blk.ttl[s] = 0;
        }
        blk.first_sample = sample;
        blk.len = bs;
        blk.acquired_ns = @intCast(dimna.clock.nowNs());
        ring.commit();
        sample += @intCast(bs);
    }
}

fn sleepMs(ms: u64) void {
    dimna.os.sleepNs(ms * std.time.ns_per_ms);
}

test "JACK: against a running server (DIMNA_TEST_JACK names it): frames are pulled, no gaps, no client left" {
    const server = std.c.getenv("DIMNA_TEST_JACK") orelse return error.SkipZigTest;
    const gpa = testing.allocator;
    const j = lib() orelse return error.NoLibjack;
    const fs_in = 30000.0;
    var ring = try dimna.ring.BlockRing.init(gpa, 512, 4, 128);
    defer ring.deinit(gpa);
    var shared: audio_out.Shared = .{};
    var settings: dimna.audio.Settings = .{};
    settings.channels[0] = 1;
    settings.num_channels = 1;
    shared.publish(&settings);
    // The alarm tone too, so that both ports carry sound whatever the chain makes of the
    // signal while it measures the noise.
    shared.alarm.store(true, .monotonic);
    var stop_producer: Atomic(bool) = .init(false);
    const producer = try std.Thread.spawn(.{}, produce, .{ &ring, fs_in, &stop_producer });
    defer {
        stop_producer.store(true, .release);
        producer.join();
    }

    const out = audio_out.AudioOut.start(gpa, &shared, &ring, fs_in, 4, 128, .{ .output = .jack, .jack_server = server }) orelse
        return error.NoJackOutput;
    var stopped = false;
    defer if (!stopped) out.stop();
    const dev = &out.jack.?;
    try testing.expect(shared.running.load(.acquire));
    var name_buf: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{s}", .{dev.name()});
    const server_frames = out.max_request.load(.monotonic);
    std.debug.print("\nJACK test: server {s}, client {s}, {d} Hz, buffer {d} frames, client thread priority {d}, process id {d}\n", .{
        server, name, out.fs_out, server_frames, dev.priority, dimna.os.getpid(),
    });

    // A second client that listens to dimna's ports.
    var status: c_int = 0;
    var sink: Sink = .{
        .client = j.jack_client_open("dimna-test-sink", option_no_start_server | option_server_name, &status, server) orelse return error.NoSink,
        .ins = undefined,
    };
    defer _ = j.jack_client_close(sink.client);
    for (&sink.ins, [_][*:0]const u8{ "in_left", "in_right" }) |*p, n| p.* = j.jack_port_register(sink.client, n, audio_type, port_is_input, 0) orelse return error.NoSink;
    try testing.expectEqual(0, j.jack_set_process_callback(sink.client, Sink.process, &sink));
    try testing.expectEqual(0, j.jack_activate(sink.client));
    for (dev.ports, sink.ins) |from, to| try testing.expectEqual(0, j.jack_connect(sink.client, j.jack_port_name(from), j.jack_port_name(to)));

    // Primed: the queue has reached its margin.
    var waited: usize = 0;
    while (!out.primed.load(.monotonic)) : (waited += 1) {
        if (waited > 1000) return error.NeverPrimed;
        sleepMs(10);
    }
    // The margin adapts first: each gap in the first seconds raises it by 1 ms (as with
    // ALSA, see audio_out.zig). Settled: no new gap for 3 s (at most 20 s of waiting).
    var calm: usize = 0;
    var last_gaps = shared.underruns.load(.monotonic);
    waited = 0;
    while (calm < 30) : (waited += 1) {
        if (waited > 200) return error.NeverSettled;
        sleepMs(100);
        const g = shared.underruns.load(.monotonic);
        calm = if (g == last_gaps) calm + 1 else 0;
        last_gaps = g;
    }
    std.debug.print("JACK test: settled after {d:.1} s with {d} gaps, margin {d} us\n", .{ @as(f64, @floatFromInt(waited)) / 10, last_gaps, shared.margin_us.load(.monotonic) });
    // Three seconds: frames pulled at the server's rate, the queue's fill moving, no gap.
    const t0 = dimna.clock.nowNs();
    const r0 = out.rendered.load(.monotonic);
    const s0 = sink.frames.load(.monotonic);
    const gaps0 = shared.underruns.load(.monotonic);
    var fill_min: u32 = std.math.maxInt(u32);
    var fill_max: u32 = 0;
    for (0..300) |_| {
        sleepMs(10);
        const f = out.fill.load(.monotonic);
        fill_min = @min(fill_min, f);
        fill_max = @max(fill_max, f);
    }
    const t1 = dimna.clock.nowNs();
    const r1 = out.rendered.load(.monotonic);
    const s1 = sink.frames.load(.monotonic);
    const gaps1 = shared.underruns.load(.monotonic);
    const secs = @as(f64, @floatFromInt(t1 - t0)) / 1e9;
    const rate = @as(f64, @floatFromInt(r1 - r0)) / secs;
    std.debug.print("JACK test: {d} frames in {d:.3} s = {d:.0} per s; the sink got {d}; queue fill {d} to {d} frames; gaps {d} then {d}; dropped {d}; playback latency {d} frames; margin {d} us; xruns {d}\n", .{
        r1 - r0, secs, rate, s1 - s0, fill_min, fill_max, gaps0, gaps1, shared.dropped.load(.monotonic), out.device_delay.load(.monotonic), shared.margin_us.load(.monotonic), shared.xruns.load(.monotonic),
    });
    try testing.expectApproxEqRel(out.fs_out, rate, 0.02);
    try testing.expect(s1 - s0 + 2 * server_frames >= r1 - r0 and s1 - s0 <= r1 - r0 + 2 * server_frames);
    try testing.expect(fill_max > 0 and fill_max != fill_min);
    try testing.expectEqual(gaps0, gaps1);
    try testing.expect(sink.energy[0].load(.monotonic) > 0 and sink.energy[1].load(.monotonic) > 0);

    // A client that overruns its period: the server reports an xrun, which is counted.
    const x0 = shared.xruns.load(.monotonic);
    sink.stall_ns.store(20 * std.time.ns_per_ms, .monotonic);
    sleepMs(300);
    std.debug.print("JACK test: xruns {d} after a 20 ms stall in the sink\n", .{shared.xruns.load(.monotonic) - x0});
    try testing.expect(shared.xruns.load(.monotonic) > x0);

    // The server's buffer size changes: max_request follows, frames still come.
    const other: u32 = if (server_frames == 128) 256 else 128;
    try testing.expectEqual(0, j.jack_set_buffer_size(sink.client, other));
    sleepMs(300);
    const r2 = out.rendered.load(.monotonic);
    sleepMs(300);
    std.debug.print("JACK test: buffer size {d}: max_request {d}, {d} frames in 0.3 s\n", .{ other, out.max_request.load(.monotonic), out.rendered.load(.monotonic) - r2 });
    try testing.expectEqual(other, out.max_request.load(.monotonic));
    try testing.expect(out.rendered.load(.monotonic) - r2 > @as(u64, @intFromFloat(out.fs_out * 0.25)));
    try testing.expectEqual(0, j.jack_set_buffer_size(sink.client, server_frames));
    sleepMs(100);

    // Stopped: no port of dimna's client is left on the server.
    out.stop();
    stopped = true;
    var pattern_buf: [160]u8 = undefined;
    const pattern = try std.fmt.bufPrintSentinel(&pattern_buf, "^{s}:", .{name}, 0);
    const left_over = j.jack_get_ports(sink.client, pattern.ptr, null, 0);
    defer if (left_over) |p| j.jack_free(@ptrCast(p));
    const ours = j.jack_get_ports(sink.client, "^dimna-test-sink:", null, 0);
    defer if (ours) |p| j.jack_free(@ptrCast(p));
    std.debug.print("JACK test: after stop, ports matching {s}: {s}; the sink's own ports still listed: {}\n", .{ pattern, if (left_over == null) "none" else "SOME", ours != null });
    try testing.expect(left_over == null);
    // The query works (it does find the sink's own ports).
    try testing.expect(ours != null);
}

test "JACK: the server going away (DIMNA_TEST_JACK_SHUTDOWN names it, and it is stopped meanwhile) silences the monitor" {
    const server = std.c.getenv("DIMNA_TEST_JACK_SHUTDOWN") orelse return error.SkipZigTest;
    const gpa = testing.allocator;
    var ring = try dimna.ring.BlockRing.init(gpa, 64, 4, 128);
    defer ring.deinit(gpa);
    var shared: audio_out.Shared = .{};
    const out = audio_out.AudioOut.start(gpa, &shared, &ring, 30000, 4, 128, .{ .output = .jack, .jack_server = server }) orelse
        return error.NoJackOutput;
    std.debug.print("\nJACK shutdown test: connected to {s}; stop the server now (waiting up to 30 s)\n", .{server});
    var waited: usize = 0;
    while (shared.running.load(.acquire)) : (waited += 1) {
        if (waited > 3000) {
            out.stop();
            return error.ServerStillThere;
        }
        sleepMs(10);
    }
    const r = out.rendered.load(.monotonic);
    sleepMs(200);
    std.debug.print("JACK shutdown test: running false after {d} ms; frames rendered in the 200 ms after: {d}\n", .{ waited * 10, out.rendered.load(.monotonic) - r });
    try testing.expect(out.jack.?.gone.load(.acquire));
    try testing.expectEqual(r, out.rendered.load(.monotonic));
    out.stop();
}
