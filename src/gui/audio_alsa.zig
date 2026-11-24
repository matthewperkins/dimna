//! The spike audio monitor through ALSA: the `default` device (on the rig, PipeWire's ALSA
//! device), a thread of its own that writes one period at a time, blocking, each period
//! made by `AudioOut.render`. Moved here unchanged from `audio_out.zig`: the same device,
//! parameters, calls and log lines.

const std = @import("std");
const alsa = @import("gui_c");
const audio_out = @import("audio_out.zig");
const AudioOut = audio_out.AudioOut;
const log = std.log.scoped(.audio);

/// The open device.
pub const Device = struct {
    pcm: ?*alsa.snd_pcm_t,
};

/// Opens the default output device: float stereo at 48 kHz (or what is nearest), periods
/// of `period_frames` (or what is nearest) and two of them as the device's buffer. Sets
/// `out.fs_out`, `out.max_request` and `out.device_buffer` to what the device took.
pub fn open(out: *AudioOut, period_frames: u32) !Device {
    var pcm: ?*alsa.snd_pcm_t = null;
    if (alsa.snd_pcm_open(&pcm, "default", alsa.SND_PCM_STREAM_PLAYBACK, 0) < 0) return error.NoDevice;
    errdefer _ = alsa.snd_pcm_close(pcm);
    var hw: ?*alsa.snd_pcm_hw_params_t = null;
    if (alsa.snd_pcm_hw_params_malloc(&hw) < 0) return error.OutOfMemory;
    defer alsa.snd_pcm_hw_params_free(hw);
    if (alsa.snd_pcm_hw_params_any(pcm, hw) < 0) return error.DeviceParams;
    if (alsa.snd_pcm_hw_params_set_access(pcm, hw, alsa.SND_PCM_ACCESS_RW_INTERLEAVED) < 0) return error.DeviceParams;
    if (alsa.snd_pcm_hw_params_set_format(pcm, hw, alsa.SND_PCM_FORMAT_FLOAT_LE) < 0) return error.DeviceFormat;
    if (alsa.snd_pcm_hw_params_set_channels(pcm, hw, 2) < 0) return error.DeviceChannels;
    var rate: c_uint = 48000;
    if (alsa.snd_pcm_hw_params_set_rate_near(pcm, hw, &rate, null) < 0) return error.DeviceRate;
    // Small periods: each is latency. Two of them as the device's own buffer.
    var period: alsa.snd_pcm_uframes_t = period_frames;
    _ = alsa.snd_pcm_hw_params_set_period_size_near(pcm, hw, &period, null);
    var buffer: alsa.snd_pcm_uframes_t = period * 2;
    _ = alsa.snd_pcm_hw_params_set_buffer_size_near(pcm, hw, &buffer);
    if (alsa.snd_pcm_hw_params(pcm, hw) < 0) return error.DeviceParams;
    _ = alsa.snd_pcm_hw_params_get_period_size(hw, &period, null);
    _ = alsa.snd_pcm_hw_params_get_buffer_size(hw, &buffer);
    out.device_buffer = @intCast(buffer);
    _ = alsa.snd_pcm_hw_params_get_rate(hw, &rate, null);
    if (alsa.snd_pcm_prepare(pcm) < 0) return error.DevicePrepare;
    out.fs_out = @floatFromInt(rate);
    out.max_request.store(@intCast(period), .monotonic);
    return .{ .pcm = pcm };
}

/// What to set `PIPEWIRE_LATENCY` to before any thread starts and before the device is
/// opened, or null to leave the environment alone. Through PipeWire (ALSA's `default` on
/// most desktops) the device's side of the latency is its buffer plus two of PipeWire's
/// quanta, and the quantum follows the period asked for only down to PipeWire's own; its
/// ALSA plugin takes the quantum from this variable (`<frames>/<rate>`). Set to
/// `<period>/48000` when the period is not the default and the user has not set the
/// variable (`existing`, its value, or null when unset): a value the user set is kept, and
/// at the default period nothing is set. Without PipeWire the variable does nothing.
pub fn pipewireLatency(buf: *[32]u8, period: u32, existing: ?[]const u8) ?[:0]const u8 {
    if (period == audio_out.default_period or existing != null) return null;
    return std.fmt.bufPrintSentinel(buf, "{d}/48000", .{period}, 0) catch null;
}

test "pipewireLatency: set only for a period other than the default, and never over the user's" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqual(null, pipewireLatency(&buf, audio_out.default_period, null));
    try std.testing.expectEqual(null, pipewireLatency(&buf, audio_out.default_period, "256/48000"));
    try std.testing.expectEqualStrings("64/48000", pipewireLatency(&buf, 64, null).?);
    try std.testing.expectEqualStrings("32/48000", pipewireLatency(&buf, 32, null).?);
    try std.testing.expectEqualStrings("1024/48000", pipewireLatency(&buf, 1024, null).?);
    try std.testing.expectEqualStrings("16/48000", pipewireLatency(&buf, 16, null).?);
    // Set by the user, even to nothing: left as it is.
    try std.testing.expectEqual(null, pipewireLatency(&buf, 64, "256/48000"));
    try std.testing.expectEqual(null, pipewireLatency(&buf, 32, ""));
}

pub fn close(dev: Device) void {
    _ = alsa.snd_pcm_close(dev.pcm);
}

/// The output thread: one period made by `render`, written with a blocking write, until
/// `out.stop_flag` is set or the device stops.
pub fn outputLoop(out: *AudioOut) void {
    const pcm = out.alsa.?.pcm;
    const period: usize = out.max_request.load(.monotonic);
    const buf = out.gpa.alloc(f32, period * 2) catch return;
    defer out.gpa.free(buf);
    while (!out.stop_flag.load(.acquire)) {
        out.render(buf, period);
        const wrote = alsa.snd_pcm_writei(pcm, buf.ptr, period);
        if (wrote < 0) {
            // An xrun or a suspended device: start again.
            if (alsa.snd_pcm_recover(pcm, @intCast(wrote), 1) < 0) {
                log.warn("the audio device stopped: {s}", .{alsa.snd_strerror(@intCast(wrote))});
                out.shared.running.store(false, .release);
                return;
            }
        }
        var delay: alsa.snd_pcm_sframes_t = 0;
        if (alsa.snd_pcm_delay(pcm, &delay) == 0 and delay >= 0) out.device_delay.store(@intCast(delay), .monotonic);
    }
}
