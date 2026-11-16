# Plan: spike audio through JACK, with ALSA as the fallback

Read `docs/plans/README.md` first. This is **not** a refactoring plan: it adds a second
way out for the spike audio and changes which one is used. What must not change is said
below. It replaces the audio half of step 5 in `docs/plans/macos-port.md`, and was put
ahead of the remaining port steps by the owner (2026-11-15).

You work on the rig over SSH, as `docs/plans/macos-step1-build.md` describes under "Where
you work" (same worktree, same branch, same rules: never the board, never the GUI binary,
no windows, a `/tmp` folder with your process id).

## Why

The audio monitor opens ALSA's `default` device, which on the rig is PipeWire. Of 16.8 ms
of audio latency (baseline in `macos-port.md`), 10.5 ms are on the device's side. The owner
has decided to let JACK2 (`jackd`) run the sound card directly while dimna runs, with
PipeWire and WirePlumber stopped. On the rig `jackd -R -P 60 -d alsa -d hw:PCH -r 48000
-p 64 -n 2` and the same with `-p 32` both started and ran 25 s idle without complaint
(the lead, same day; no client was connected).

Measured the same night through PipeWire (ALSA `default`, the board, 40 s runs): the
device's side is dimna's own two-period ALSA buffer (256 frames) plus two of PipeWire's
quanta. At the quantum dimna's request already gets (128): 10.6 ms. With
`PIPEWIRE_LATENCY=128/48000`: no change. With `PIPEWIRE_LATENCY=64/48000`: 7.9 ms, no gap
in 40 s. So PipeWire can be brought lower too, by shrinking dimna's period with the
quantum; `jackd` at 64 frames x 2 would be 2.7 ms with no second buffer. The notes in
`FROM_LINUX_DIMNA_AGENT_audio_seam.md` (on `main`) argue for measuring before choosing;
the owner chose JACK for the rig, and this plan keeps ALSA as the default elsewhere.

JACK asks a client for frames through a callback, as macOS's Core Audio does. So this step
also gives the audio output the shape the Mac needs: one function that fills N frames from
the queue, called by whichever device is in use.

## What to build

1. **One fill function, shared.** In `src/gui/audio_out.zig`, the part of `outputLoop`
   that is not ALSA becomes a function of `AudioOut` that fills `frames` interleaved stereo
   frames into a buffer it is given: the headroom measure (`min_fill`), `fill`, the pop,
   the zero fill, the gap count (only when `active` and `primed`), the alarm tone (its
   phase becomes a field). It must be fit for a real-time callback: no allocation, no lock,
   no logging, no system call. It must be right for a number of frames that differs from
   call to call. `period` is assumed fixed in three places. The headroom measure uses
   the frame count of the request being filled. The feeder's drop limit and its `primed`
   threshold mean "the largest request the device makes": a field `max_request`, readable
   from the feeder's thread, which ALSA sets to its period (the same numbers as now) and a
   callback device raises if it is ever asked for more.
2. **`src/gui/audio_alsa.zig`**: today's `open` and the output loop, moved, calling the
   fill function and then `snd_pcm_writei`, `snd_pcm_recover`, `snd_pcm_delay` exactly as
   now (same device name, parameters, blocking write, one period at a time).
3. **`src/gui/audio_jack.zig`**: a JACK client.
   - `libjack.so.0` is opened at run time with `std.DynLib`, as `shape.zig` opens HarfBuzz
     (a struct of function pointers looked up by name; no JACK header and no link
     dependency). If the library or a function is missing, or no server is running
     (`JackNoStartServer`: dimna never starts a server), JACK is not used.
   - Two output ports, connected to the first two physical playback ports. The process
     callback fills an interleaved scratch buffer made before activation (sized for the
     largest buffer the server may switch to, or re-made in the buffer-size callback, which
     JACK calls outside the process cycle) and splits it into the two ports' buffers.
   - `fs_out` is the server's rate and is known before the feeder starts (the resampling
     ratio is fixed there). `period` is the server's buffer size, updated by the
     buffer-size callback.
   - The device's delay for the latency read-out: the playback latency JACK reports for
     the ports (`jack_port_get_latency_range`, the maximum), in frames, where ALSA's
     `snd_pcm_delay` goes now. Say in the report what that figure includes and what it
     cannot (the converter and analogue path of the card).
   - xruns reported by the server are counted (a new counter in `Shared`) and shown in the
     once-a-second audio log line, after the existing fields. The control window is not
     changed.
   - If the server goes away (the shutdown callback), `running` goes false and the monitor
     is silent, as when the ALSA device stops. No reconnecting in this step; say so in the
     docs.
4. **Which one is used.** A config key and an option (follow `args.zig`'s conventions for
   names; something like `audio_output = "alsa" | "jack" | "auto"`, default `alsa`: on
   most distributions the JACK library is PipeWire's own, so `auto` as the default would
   move those users to another path for no gain; the rig sets `jack`):
   `auto` uses JACK when a server answers and ALSA otherwise; `jack` does not fall back
   (no sound, with a warning that says why); `alsa` never tries JACK. The start-up log line
   says which was taken.
5. **The service that takes the card.** `packaging/dimna-jack.service`, a systemd **user**
   unit that runs `jackd` on the sound card and declares `Conflicts=` with
   `pipewire.socket`, `pipewire-pulse.socket`, `pipewire.service`,
   `pipewire-pulse.service` and `wireplumber.service` (the sockets too: otherwise the next
   program that wants sound starts PipeWire again and the two fight over the card). The
   device, period and number of periods come from `Environment=` lines with defaults that
   are safe anywhere (`hw:0`, 64, 2), to be overridden per machine with a drop-in
   (`systemctl --user edit`); the rig's card is `hw:PCH`. `jackd` runs with `-R -P 60`:
   **below** dimna's acquisition thread (SCHED_FIFO 70). Sound must never be able to delay
   acquisition; say in the report what priority dimna's own JACK thread ends up with and
   how you know.
   `packaging/dimna-launch.sh` (and `dimna-desktop-launch.sh`): if that unit is installed
   for the user (`systemctl --user cat dimna-jack.service` succeeds), start it before
   dimna, and when dimna exits, however it exits, stop it and start PipeWire's sockets and
   services again. If it is not installed the launchers behave exactly as now. dimna itself
   never calls `systemctl`.
   You write and read these; you do **not** install the unit, start it, or stop PipeWire
   on the rig. The lead does that.
6. **Docs**: `docs/tiles-and-audio.md` (the two outputs, the key, what the latency figure
   means with each), `docs/install.md` (installing the unit, the drop-in for the card,
   what stops working while JACK holds the card: every program that plays through
   PipeWire or PulseAudio, and screen sharing through the desktop portal; `wayvnc` does
   not use PipeWire), `README.md` only where it names ALSA or PipeWire as the audio path.

## What must not change

- With ALSA in use, what reaches the device and when: the same parameters, the same
  blocking write per period, the same latency arithmetic and log line (apart from the new
  xrun field, which reads 0).
- The feeder: its reader, the processing chain in `audio.zig` (not yours to touch), the
  margin's adaptation, the rate trim, the drop rule, apart from `period` being read from
  an atomic.
- Acquisition, the recorder and the display are not touched. The audio threads still only
  read the ring through a lossy reader.

## Tests

`audio_out.zig` has no tests today and is not in `src/gui/tests.zig`. With the fill
function separate from the device, it can be tested without one. Add it to `tests.zig`
(none of its tests may open a sound device or need a server by default) and test at least:

- an empty queue gives zeros; a gap is counted only when `active` and `primed`;
- frames come out in the order pushed, across the queue's wrap, for frame counts that
  differ from call to call (1, 64, 100, 128, 1024);
- `min_fill` is what is left after the call, and `fill` what was there before;
- splitting a request changes nothing: with the same queue contents and the alarm on,
  64 then 64 frames are the same 128 frames as one request of 128, and as 37 then 91;
- the alarm tone: present while `alarm` is set, 0.15 s at the start of each second by the
  device's rate, continuous in phase across calls of different sizes, and added to what
  is playing;
- **against a real JACK server with no sound card**: a test that is skipped unless an
  environment variable names a server (for example `DIMNA_TEST_JACK=dimna-test`), and then
  connects to that server, starts the JACK backend on a ring you feed with known blocks,
  and checks that frames are pulled (the fill counter moves, the queue drains at the
  server's rate, no gap is counted once primed), and that stopping it leaves no client
  behind. You may run `jackd -n dimna-test-<pid> -d dummy -r 48000 -p 64` on the rig for
  this: the dummy driver opens no sound card and does not disturb PipeWire. Stop it
  afterwards and check no `jackd` of yours is left (`pgrep -af jackd`). Never run `jackd`
  with `-d alsa`.

## Evidence

1. `zig build test --summary all` before and after: the old counts plus your tests.
2. The dummy-server test, with its output, and `pgrep -af jackd` before and after.
3. The stored GUI outputs untouched (`git status` under `src/gui/testdata`).
4. `zig build --release=safe` builds; `readelf -d zig-out/bin/dimna` NEEDED is as before
   (no libjack); `zig build release` passes its CHECK (it would fail on a new NEEDED).
5. `zig fmt --check src build.zig`; `sh -n` on the launchers; `systemd-analyze --user
   verify packaging/dimna-jack.service` (say what it prints; it may complain about paths
   that only exist once installed).
6. The launcher's logic without touching the session: run it with a fake `systemctl` first
   on `PATH` (as the portability plan's step 4 did for `udevadm`) and a stand-in for the
   dimna binary, and show the calls it makes when the unit "is installed", when it is not,
   and when the stand-in exits non-zero or is killed.

Break it on purpose, once each: the gap count ignoring `primed` (a test fails); the
callback not popping (the dummy-server test fails); the launcher not restoring PipeWire
when dimna is killed (evidence 6 shows it).

What you cannot give, and the lead will get on the rig: the GUI on the board through ALSA
against the baseline (unchanged), and through JACK on `hw:PCH` (the latency read-out,
gaps, xruns, and that acquisition and the display figures are unaffected).

## Files you may change

`src/gui/audio_out.zig`, new `src/gui/audio_alsa.zig` and `src/gui/audio_jack.zig`,
`src/gui/tests.zig`, `src/gui/args.zig`, `src/gui/main.zig` (the option, the log line),
`src/gui/pipeline.zig` (starting the output), new `packaging/dimna-jack.service`,
`packaging/dimna-launch.sh`, `packaging/dimna-desktop-launch.sh`, `docs/tiles-and-audio.md`,
`docs/install.md`, `README.md`. If the release packaging (`nfpm.yaml`, `build.zig`'s
`release_packaging`, the install scripts) should carry the unit, do not change them: say
what would be needed.

## Done means

The evidence and the three break-it results are in your report; the report says what the
JACK latency figure includes; the work is committed on `macos-port` in the rig's worktree;
the worktree is clean; no `jackd` of yours is running; your `/tmp` folder is gone.
