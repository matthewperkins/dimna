# Notes for the macOS-port agent: the audio seam, and whether to use JACK

From the Claude session that wrote dimna's Linux audio output, at the owner's request
(2026-11-15). These are notes for `docs/plans/macos-port.md` step 5 (the audio seam) and
step 11 (`audio_coreaudio.zig`), and for that plan's open item "What the Linux sound output
should be". They are not a plan handed out as they stand: fold what you agree with into
your step 5 plan, under `docs/plans/README.md`'s rules. Line numbers are from `main` at
`5bab0a5` (`src/gui/audio_out.zig`, which your branch has not changed except for imports).

## Summary

1. **Make the shared seam a pull function, `render(out, frames)`**, on Linux too. The ALSA
   loop calls it and then writes the period, exactly as now; Core Audio's callback calls
   the same function; a JACK backend, if one is ever wanted, would be a third caller. That
   gives both platforms the same shape without changing what Linux talks to.
2. **Do not switch Linux to JACK on the expectation that it lowers latency.** The part of
   today's latency on the device's side is set by PipeWire's quantum, which the JACK API
   does not bypass on most distributions. Measure the options below first.
3. **If JACK wins the measurement, add it as an optional backend** opened with `dlopen`
   (as `shape.zig` opens HarfBuzz), ALSA staying the default, so no package gains a JACK
   dependency.

## Why the seam should be a pull function

`AudioOut.outputLoop` (`audio_out.zig:206-247`) is already a render step followed by a
device write. Per period it:

- reads the queue's fill, records the least left after this period (`min_fill`, `:213-214`;
  the feeder's rate trim steers on this alone), and stores `fill`;
- pops up to one period from the `Fifo` (`:74-97`, single-producer single-consumer, atomics
  only: no lock, no allocation, so it is safe in a real-time callback as it is);
- zero-fills what the queue lacked, and counts an underrun only while the monitor is
  `active` and the queue has been `primed` (`:217-221`);
- mixes in the alarm tone (880 Hz, 0.15 s at the start of each second), keeping its phase
  across periods (`:222-234`);
- then `snd_pcm_writei`, `snd_pcm_recover` on an xrun, `snd_pcm_delay` into `device_delay`
  (`:235-246`).

Everything before `snd_pcm_writei` becomes

    /// Fills `out` (interleaved stereo, `frames` frames) from the queue; never blocks,
    /// never allocates, never takes a lock. Called by the backend's own output thread or
    /// callback, once per device request.
    fn render(self: *AudioOut, out: []f32, frames: usize) void

and the ALSA backend's loop is `render(buf, period)`, `writei`, `recover`, `delay`, as now.
Core Audio's render callback calls `render(ioData, inNumberFrames)` and reports its latency
into `device_delay` from the device's latency properties instead of `snd_pcm_delay`.

None of the audio rules in the project's CLAUDE.md ("preserve texture": held noise
calibration, gentle expander, linear limiter in the spike range, flat windowed-sinc
resampling, the linear reference mode) live in this function. They are all in the feeder
and `src/audio.zig`, before the queue, and are shared as they are.

### The three places that assume a fixed period

The macOS plan found them; here is what each is for and how to keep the Linux arithmetic
identical:

- `:213`, `left = avail -| self.period`: the headroom left after this request. Use the
  request's own `frames`. On ALSA, `frames` is always `self.period`, so it is the same value.
- `:349`, the feeder's drop limit (`margin + 2 * period + 12 ms`), and `:358`, the
  `primed` threshold (`margin + period`): both mean "the largest request the device makes".
  Replace `self.period` there with a field `max_request` (frames): ALSA sets it to the
  period, as today; Core Audio sets it to the device's maximum frames per slice
  (`kAudioUnitProperty_MaximumFramesPerSlice`), and raises it if a callback ever asks for
  more. Same numbers on Linux.
- Also `start`'s log line and the alarm's phase step (`:233`) use the period; the phase step
  becomes `frames`.

### Tests to add with the move (they run on both systems)

- **Splitting a request changes nothing:** with the same queue contents and the alarm on,
  `render(64)` then `render(64)` produces the same 128 frames as one `render(128)`, and as
  `render(37)` + `render(91)`. This is the test that proves variable callback sizes are
  safe, and that the alarm phase carries over.
- An empty queue gives zeros; an underrun is counted only when `active` and `primed`.
- `min_fill` after a sequence of requests equals the least headroom computed by hand.
- Break each once on purpose (README rule): e.g. reset the alarm phase per call, and show
  the split test failing.

On Linux the move is a refactor (README rule 8): the stored outputs, test counts and the
owner's audio figures (latency, queue and device parts, underruns, dropped) must not
change. An agent cannot get the audio figures (the GUI plays sound and opens windows); the
owner runs them, as for the other steps.

## On JACK, and where the latency is

The owner's rig, measured in the macOS plan's baseline: audio latency 15.6 to 19.2 ms,
about 5 ms of it dimna's queue (margin, a period, the feeder's chunking) and 10.5 ms on the
device's side (`snd_pcm_delay`). dimna opens ALSA's `default` device with 128-frame
periods and a two-period buffer (`:179-197`); on the rig `default` is PipeWire's ALSA
plugin.

What sets the 10.5 ms is PipeWire's graph, not the ALSA API. On the rig (read 2026-11-15
with `pw-metadata -n settings`): `clock.rate` 48000, `clock.quantum` 1024 (21 ms),
`clock.min-quantum` 32, `clock.force-quantum` 0. A client's requested latency pulls the
quantum down towards the smallest request, which is why dimna gets about 10 ms and not 21.

- **The JACK API on most distributions is PipeWire too** (`pipewire-jack`, the default on
  Fedora and current Ubuntu): a JACK client joins the same graph with the same quantum. So
  JACK there would give the same latency as ALSA's `default`.
- **Real `jackd` (jack2) on the card** does give low latency, but it needs the card to
  itself: PipeWire must release it (jack2 asks through device reservation), and desktop
  sound then stops or has to be bridged. The rig has `jack2` 1.9.22 installed and no
  `pipewire-jack`. Workable on a dedicated rig; one more thing to set up in every other lab,
  and a dependency the packages would otherwise not have.
- **Core Audio does not argue for JACK either.** What JACK and Core Audio share is the pull
  shape, and `render` gives dimna that shape on Linux without JACK.

### What to measure before choosing (the owner, on the rig, simulator only)

All four need the GUI with sound, so the owner runs them; `--sim` is enough (audio latency
does not need the board). 60 s each, alternating as the macOS plan's baseline does, the
monitor on one channel, reading the audio statistics (latency, queue and device parts,
underruns, dropped) from the log.

| | how | needs |
|---|---|---|
| A | today: ALSA `default` (PipeWire), 128-frame periods | nothing |
| B | the same, with PipeWire asked for 128 frames (`PIPEWIRE_LATENCY=128/48000` in dimna's environment; check in `pw-top` that the node's quantum actually changed, since whether the ALSA plugin honours it must be seen, not assumed) | nothing |
| C | the card directly (`hw:` or `plughw:`), bypassing PipeWire | a device name option (e.g. `audio_device` in the config, default `default`); desktop sound is unavailable while dimna holds the card |
| D | `jackd` on the card, dimna as a JACK client | a JACK backend first; only worth writing if B and C fall short |

If B brings the device side near 3 ms (128 frames at 48 kHz is 2.7 ms), JACK has nothing
left to win on Linux, and B is a one-line change. Underruns are the other half of the
result: a smaller quantum that underruns under load (cameras recording, a build) is worse
than today.

## Things to keep in mind for `audio_coreaudio.zig`

- The render callback runs on Core Audio's real-time thread: `render` must stay free of
  locks, allocation, logging and system calls, as it is now. Statistics stay atomics.
- `inNumberFrames` varies between calls and can exceed what was asked for; `max_request`
  (above) covers the feeder's arithmetic. Size any scratch buffer to the maximum frames per
  slice, allocated before the unit starts.
- The output sample rate is the device's (often 48000, but 44100 is common on Mac
  hardware): set `fs_out` from the stream format, as ALSA's `set_rate_near` result is used
  now. The resampler already handles any ratio.
- The device's buffer size is settable (`kAudioDevicePropertyBufferFrameSize`); 128 frames
  is the equivalent of today's ALSA request. Report the device's latency
  (`kAudioDevicePropertyLatency` + `kAudioDevicePropertySafetyOffset` + the buffer) into
  `device_delay`, so the read-out means the same on both systems.
- The alarm tone is in `render`, so the Mac gets it for free.
