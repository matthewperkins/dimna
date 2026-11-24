//! The spike audio monitor through Core Audio: the macOS backend of the sound device, chosen
//! in `audio_out.zig` where Linux's is `audio_alsa.zig`. The system's default output
//! device, through Apple's default output audio unit; Core Audio's own real-time thread
//! asks for frames through a callback, which calls `AudioOut.render` and nothing else.
//! Core Audio's C interface is declared here (AudioToolbox.h translates to some 14,000
//! declarations).
//!
//! What `open` sets, so that the figures mean what they mean on Linux:
//!
//! - `fs_out`: the device's nominal rate (`kAudioDevicePropertyNominalSampleRate`); the unit
//!   is given float stereo at that rate, so it converts nothing but the channel count.
//! - The device's buffer: `audio_period` frames asked for (`kAudioDevicePropertyBufferFrameSize`,
//!   within `kAudioDevicePropertyBufferFrameSizeRange`), and what it then reports is used.
//! - `max_request`: that buffer, or the largest buffer the device says it may pass
//!   (`kAudioDevicePropertyUsesVariableBufferFrameSizes`) where it has the property.
//! - `device_delay`: what the device reports as the time from a frame handed over to its
//!   being heard, in frames: its latency (`kAudioDevicePropertyLatency`, output), its
//!   safety offset (`kAudioDevicePropertySafetyOffset`, output), its first output stream's
//!   latency (`kAudioStreamPropertyLatency`) and its buffer. Fixed once the device is open
//!   (Linux's `snd_pcm_delay` is read after every period).
//!
//! The output thread `audio_out.zig` starts only starts the unit, waits for `stop_flag` and
//! stops it again: the frames are asked for by Core Audio's thread, not by this one.

const std = @import("std");
const dimna = @import("dimna");
const audio_out = @import("audio_out.zig");
const AudioOut = audio_out.AudioOut;
const log = std.log.scoped(.audio);

// ---- Core Audio and AudioToolbox (CoreAudio/AudioHardware.h, AudioToolbox/AudioUnit.h) ----

const OSStatus = i32;
const AudioObjectID = u32;
const AudioUnit = *opaque {};
const AudioComponent = *opaque {};

fn fourcc(comptime s: *const [4]u8) u32 {
    return @as(u32, s[0]) << 24 | @as(u32, s[1]) << 16 | @as(u32, s[2]) << 8 | s[3];
}

const AudioObjectPropertyAddress = extern struct { selector: u32, scope: u32, element: u32 };
const AudioComponentDescription = extern struct {
    type: u32,
    sub_type: u32,
    manufacturer: u32,
    flags: u32 = 0,
    flags_mask: u32 = 0,
};
const AudioStreamBasicDescription = extern struct {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,
    reserved: u32 = 0,
};
const AudioBuffer = extern struct { channels: u32, byte_size: u32, data: ?*anyopaque };
const AudioBufferList = extern struct { count: u32, buffers: [1]AudioBuffer };
const AudioValueRange = extern struct { minimum: f64, maximum: f64 };
const AURenderCallback = *const fn (?*anyopaque, *u32, *const anyopaque, u32, u32, ?*AudioBufferList) callconv(.c) OSStatus;
const AURenderCallbackStruct = extern struct { proc: AURenderCallback, ref: ?*anyopaque };

const kAudioObjectSystemObject: AudioObjectID = 1;
const kAudioObjectPropertyScopeGlobal = fourcc("glob");
const kAudioObjectPropertyScopeOutput = fourcc("outp");
const kAudioObjectPropertyElementMain: u32 = 0;
const kAudioObjectPropertyName = fourcc("lnam");
const kAudioDevicePropertyNominalSampleRate = fourcc("nsrt");
const kAudioDevicePropertyBufferFrameSize = fourcc("fsiz");
const kAudioDevicePropertyBufferFrameSizeRange = fourcc("fsz#");
const kAudioDevicePropertyUsesVariableBufferFrameSizes = fourcc("vfsz");
const kAudioDevicePropertyLatency = fourcc("ltnc");
const kAudioDevicePropertySafetyOffset = fourcc("saft");
const kAudioDevicePropertyStreams = fourcc("stm#");
const kAudioStreamPropertyLatency = kAudioDevicePropertyLatency;

const kAudioUnitType_Output = fourcc("auou");
const kAudioUnitSubType_DefaultOutput = fourcc("def ");
const kAudioUnitManufacturer_Apple = fourcc("appl");
const kAudioUnitScope_Global: u32 = 0;
const kAudioUnitScope_Input: u32 = 1;
const kAudioUnitProperty_StreamFormat: u32 = 8;
const kAudioUnitProperty_MaximumFramesPerSlice: u32 = 14;
const kAudioUnitProperty_SetRenderCallback: u32 = 23;
const kAudioOutputUnitProperty_CurrentDevice: u32 = 2000;
const kAudioOutputUnitProperty_IsRunning: u32 = 2001;
const kAudioFormatLinearPCM = fourcc("lpcm");
const kAudioFormatFlagIsFloat: u32 = 1 << 0;
const kAudioFormatFlagIsPacked: u32 = 1 << 3;

extern "c" fn AudioObjectGetPropertyData(id: AudioObjectID, address: *const AudioObjectPropertyAddress, qualifier_size: u32, qualifier: ?*const anyopaque, size: *u32, data: *anyopaque) OSStatus;
extern "c" fn AudioObjectSetPropertyData(id: AudioObjectID, address: *const AudioObjectPropertyAddress, qualifier_size: u32, qualifier: ?*const anyopaque, size: u32, data: *const anyopaque) OSStatus;
extern "c" fn AudioComponentFindNext(after: ?AudioComponent, desc: *const AudioComponentDescription) ?AudioComponent;
extern "c" fn AudioComponentInstanceNew(component: AudioComponent, out: *?AudioUnit) OSStatus;
extern "c" fn AudioComponentInstanceDispose(unit: AudioUnit) OSStatus;
extern "c" fn AudioUnitGetProperty(unit: AudioUnit, id: u32, scope: u32, element: u32, data: *anyopaque, size: *u32) OSStatus;
extern "c" fn AudioUnitSetProperty(unit: AudioUnit, id: u32, scope: u32, element: u32, data: ?*const anyopaque, size: u32) OSStatus;
extern "c" fn AudioUnitInitialize(unit: AudioUnit) OSStatus;
extern "c" fn AudioUnitUninitialize(unit: AudioUnit) OSStatus;
extern "c" fn AudioOutputUnitStart(unit: AudioUnit) OSStatus;
extern "c" fn AudioOutputUnitStop(unit: AudioUnit) OSStatus;
// The device's name (a CFString), for the log line.
extern "c" fn CFStringGetCString(s: *const anyopaque, buf: [*]u8, size: isize, encoding: u32) u8;
extern "c" fn CFRelease(cf: *const anyopaque) void;

/// A property of an audio object (device or stream), of type `T`; null if it has none.
fn objectProperty(comptime T: type, id: AudioObjectID, selector: u32, scope: u32) ?T {
    const address: AudioObjectPropertyAddress = .{ .selector = selector, .scope = scope, .element = kAudioObjectPropertyElementMain };
    var value: T = undefined;
    var size: u32 = @sizeOf(T);
    if (AudioObjectGetPropertyData(id, &address, 0, null, &size, @ptrCast(&value)) != 0 or size != @sizeOf(T)) return null;
    return value;
}

fn unitProperty(comptime T: type, unit: AudioUnit, id: u32, scope: u32) ?T {
    var value: T = undefined;
    var size: u32 = @sizeOf(T);
    if (AudioUnitGetProperty(unit, id, scope, 0, @ptrCast(&value), &size) != 0 or size != @sizeOf(T)) return null;
    return value;
}

fn setUnitProperty(unit: AudioUnit, id: u32, scope: u32, value: anytype) OSStatus {
    return AudioUnitSetProperty(unit, id, scope, 0, value, @sizeOf(@TypeOf(value.*)));
}

// ---- The device ----

/// The open device: the output unit and the device it plays on.
pub const Device = struct {
    unit: AudioUnit,
    device: AudioObjectID,
};

/// What `open` found, for the log line and the device test.
pub const Report = struct {
    name: [128]u8 = @splat(0),
    rate: f64 = 0,
    asked: u32 = 0,
    buffer: u32 = 0,
    max_request: u32 = 0,
    max_frames_per_slice: u32 = 0,
    latency: u32 = 0,
    safety_offset: u32 = 0,
    stream_latency: u32 = 0,

    pub fn nameText(self: *const Report) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
};

/// Of the last `open`, read on the opening thread only.
pub var last_report: Report = .{};

/// Opens the default output device: float stereo at its own rate, a buffer of
/// `period_frames` (or what the device takes). Sets `out.fs_out`, `out.max_request`,
/// `out.device_buffer` and `out.device_delay` (see the file's header). The unit is made and
/// set up, not started (`outputLoop` starts it).
pub fn open(out: *AudioOut, period_frames: u32) !Device {
    const desc: AudioComponentDescription = .{
        .type = kAudioUnitType_Output,
        .sub_type = kAudioUnitSubType_DefaultOutput,
        .manufacturer = kAudioUnitManufacturer_Apple,
    };
    const component = AudioComponentFindNext(null, &desc) orelse return error.NoDevice;
    var maybe_unit: ?AudioUnit = null;
    if (AudioComponentInstanceNew(component, &maybe_unit) != 0) return error.NoDevice;
    const unit = maybe_unit orelse return error.NoDevice;
    errdefer _ = AudioComponentInstanceDispose(unit);
    const device = unitProperty(AudioObjectID, unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global) orelse return error.NoDevice;
    if (device == 0) return error.NoDevice;
    var r: Report = .{ .asked = period_frames };
    if (objectProperty(*const anyopaque, device, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal)) |name| {
        _ = CFStringGetCString(name, &r.name, r.name.len - 1, 0x08000100);
        CFRelease(name);
    }
    r.rate = objectProperty(f64, device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal) orelse return error.DeviceRate;
    if (!(r.rate >= 8000 and r.rate <= 768000)) return error.DeviceRate;

    // The device's buffer: the period asked for, within what it allows.
    var want: u32 = period_frames;
    if (objectProperty(AudioValueRange, device, kAudioDevicePropertyBufferFrameSizeRange, kAudioObjectPropertyScopeGlobal)) |range| {
        want = @intFromFloat(std.math.clamp(@as(f64, @floatFromInt(want)), range.minimum, range.maximum));
    }
    const address: AudioObjectPropertyAddress = .{ .selector = kAudioDevicePropertyBufferFrameSize, .scope = kAudioObjectPropertyScopeGlobal, .element = kAudioObjectPropertyElementMain };
    _ = AudioObjectSetPropertyData(device, &address, 0, null, @sizeOf(u32), &want);
    r.buffer = objectProperty(u32, device, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal) orelse return error.DeviceParams;
    if (r.buffer == 0) return error.DeviceParams;
    r.max_request = @max(r.buffer, objectProperty(u32, device, kAudioDevicePropertyUsesVariableBufferFrameSizes, kAudioObjectPropertyScopeGlobal) orelse 0);

    // What the callback is given: interleaved float stereo at the device's rate.
    const format: AudioStreamBasicDescription = .{
        .sample_rate = r.rate,
        .format_id = kAudioFormatLinearPCM,
        .format_flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .bytes_per_packet = 8,
        .frames_per_packet = 1,
        .bytes_per_frame = 8,
        .channels_per_frame = 2,
        .bits_per_channel = 32,
    };
    if (setUnitProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, &format) != 0) return error.DeviceFormat;
    // The unit renders no more than this per call; never less than a request.
    r.max_frames_per_slice = unitProperty(u32, unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global) orelse 0;
    if (r.max_frames_per_slice < r.max_request) {
        _ = setUnitProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, &r.max_request);
        r.max_frames_per_slice = unitProperty(u32, unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global) orelse 0;
    }
    const callback: AURenderCallbackStruct = .{ .proc = renderCallback, .ref = out };
    if (setUnitProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, &callback) != 0) return error.DeviceParams;
    if (AudioUnitInitialize(unit) != 0) return error.DevicePrepare;
    errdefer _ = AudioUnitUninitialize(unit);

    // The device's own figures, read after the unit is set up (they may follow the format).
    r.latency = objectProperty(u32, device, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput) orelse 0;
    r.safety_offset = objectProperty(u32, device, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput) orelse 0;
    if (objectProperty(AudioObjectID, device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)) |stream| {
        r.stream_latency = objectProperty(u32, stream, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal) orelse 0;
    }

    out.fs_out = r.rate;
    out.device_buffer = r.buffer;
    out.max_request.store(r.max_request, .monotonic);
    out.device_delay.store(r.latency + r.safety_offset + r.stream_latency + r.buffer, .monotonic);
    log.info("Core Audio: {s}, {d} Hz, buffer {d} frames ({d} asked), largest request {d}; latency {d} + safety offset {d} + stream {d} + buffer frames", .{
        r.nameText(), r.rate, r.buffer, period_frames, r.max_request, r.latency, r.safety_offset, r.stream_latency,
    });
    last_report = r;
    return .{ .unit = unit, .device = device };
}

pub fn close(dev: Device) void {
    _ = AudioUnitUninitialize(dev.unit);
    _ = AudioComponentInstanceDispose(dev.unit);
}

/// Core Audio's real-time thread: `inNumberFrames` frames into the one interleaved buffer.
/// `render` only: nothing here blocks, allocates, locks or logs.
fn renderCallback(ref: ?*anyopaque, flags: *u32, time: *const anyopaque, bus: u32, frames: u32, data: ?*AudioBufferList) callconv(.c) OSStatus {
    _ = .{ flags, time, bus };
    const out: *AudioOut = @ptrCast(@alignCast(ref orelse return 0));
    const list = data orelse return 0;
    if (list.count == 0) return 0;
    const buf = &list.buffers[0];
    const samples: [*]f32 = @ptrCast(@alignCast(buf.data orelse return 0));
    const n = @min(frames, buf.byte_size / 8);
    out.render(samples[0 .. 2 * n], n);
    return 0;
}

/// The output thread: starts the unit, waits until `out.stop_flag` is set, and stops it
/// (when `AudioOutputUnitStop` returns, the callback is no longer called).
pub fn outputLoop(out: *AudioOut) void {
    const unit = out.alsa.?.unit;
    if (AudioOutputUnitStart(unit) != 0) {
        log.warn("the audio device did not start; the monitor is silent", .{});
        out.shared.running.store(false, .release);
        return;
    }
    while (!out.stop_flag.load(.acquire)) dimna.os.sleepNsOnce(10 * std.time.ns_per_ms);
    _ = AudioOutputUnitStop(unit);
}

/// Whether the unit is running (for the test).
fn isRunning(dev: Device) bool {
    return (unitProperty(u32, dev.unit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global) orelse 0) != 0;
}

// ---- Tests ----

const testing = std.testing;

// Opens the real output device; off unless DIMNA_TEST_AUDIO=1. It plays silence only: the
// ring stays empty, so the monitor is never active, and the alarm is off.
test "the default output device pulls frames at its rate, within the largest request, and stops" {
    const want = std.c.getenv("DIMNA_TEST_AUDIO") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, std.mem.span(want), "1")) return error.SkipZigTest;
    const gpa = testing.allocator;
    var ring = try dimna.ring.BlockRing.init(gpa, 8, 1, 128);
    defer ring.deinit(gpa);
    var shared: audio_out.Shared = .{};
    const a = AudioOut.start(gpa, &shared, &ring, 30000, 1, 128, audio_out.default_period) orelse return error.NoAudioDevice;
    // Stopped (before the ring is freed) whatever fails below.
    var stopped = false;
    defer if (!stopped) a.stop();
    try testing.expect(!shared.alarm.load(.monotonic));
    const r = last_report;
    const max_request = a.max_request.load(.monotonic);
    try testing.expectEqual(r.max_request, max_request);
    try testing.expect(shared.running.load(.acquire));

    // Half a second, measured from a tenth of a second in (the device's start is not timed).
    dimna.os.sleepNs(100 * std.time.ns_per_ms);
    const t0 = dimna.os.nowNs();
    const n0 = a.rendered.load(.monotonic);
    dimna.os.sleepNs(500 * std.time.ns_per_ms);
    const t1 = dimna.os.nowNs();
    const n1 = a.rendered.load(.monotonic);
    const rate = @as(f64, @floatFromInt(n1 - n0)) / (@as(f64, @floatFromInt(t1 - t0)) / 1e9);
    std.debug.print(
        \\audio device: {s}; {d} Hz; buffer {d} frames ({d} asked); largest request {d}; frames per slice {d}
        \\  reported latency {d} + safety offset {d} + stream {d} + buffer {d} = {d} frames ({d:.2} ms)
        \\  frames asked for in {d:.3} s: {d} ({d:.0} per second); largest request after: {d}; underruns {d}
        \\
    , .{
        r.nameText(),                           r.rate,          r.buffer,         r.asked,                        r.max_request,                     r.max_frames_per_slice,
        r.latency,                              r.safety_offset, r.stream_latency, r.buffer,                       a.device_delay.load(.monotonic),   @as(f64, @floatFromInt(a.device_delay.load(.monotonic))) / r.rate * 1e3,
        @as(f64, @floatFromInt(t1 - t0)) / 1e9, n1 - n0,         rate,             a.max_request.load(.monotonic), shared.underruns.load(.monotonic),
    });
    try testing.expect(@abs(rate - a.fs_out) < 0.05 * a.fs_out);
    // No request was larger than `max_request` (render raises it when one is).
    try testing.expectEqual(max_request, a.max_request.load(.monotonic));
    // Silence: the monitor was never on, so nothing counted as a gap.
    try testing.expect(!a.active.load(.monotonic));
    try testing.expectEqual(0, shared.underruns.load(.monotonic));

    // Stopped as `AudioOut.stop` does (its joins done here, to look before the device is
    // closed): the unit is not running and the callback is no longer called.
    a.stop_flag.store(true, .release);
    a.feeder.?.join();
    a.output.?.join();
    a.feeder = null;
    a.output = null;
    try testing.expect(!isRunning(a.alsa.?));
    const after = a.rendered.load(.monotonic);
    dimna.os.sleepNs(50 * std.time.ns_per_ms);
    try testing.expectEqual(after, a.rendered.load(.monotonic));
    stopped = true;
    a.stop();
    try testing.expect(!shared.running.load(.acquire));
}
