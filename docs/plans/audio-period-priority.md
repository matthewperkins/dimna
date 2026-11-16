# Plan: no JACK, the audio period as a setting, acquisition above PipeWire's thread

Read `docs/plans/README.md` first, then the result at the end of `docs/plans/jack-audio.md`
(why). Three changes the owner decided on 2026-11-16. They change behaviour, so this is
not a refactoring plan; what must stay as it is, is said for each.

You work on the rig over SSH, as `docs/plans/macos-step1-build.md` describes under "Where
you work" (same worktree, same branch, same rules: never the board, never the GUI binary,
no windows). Two things learned since: start builds and anything you time with
`chrt -o 0 nice -n -16 <command>` (an SSH session on the rig is at idle priority), and any
`rm -rf` in a script takes a quoted variable that was checked first (`set -u`, a `case` on
the expected prefix such as `/tmp/dimna-app-??????` from `mktemp -d`).

## 1. Remove the JACK output

On the rig JACK gave no lower latency than PipeWire and failed below 128 frames. Take out:
`src/gui/audio_jack.zig`; the `jack` and `auto` outputs, the `audio_output` config key and
`--audio-output`; `Shared.xruns` and the `, xruns N` at the end of the audio log line; the
tests that need a JACK server; `packaging/dimna-jack.service`; the launchers' JACK logic
(`dimna-launch.sh`, `dimna-desktop-launch.sh` back to what they were at `ad2d039`, byte for
byte: `git diff ad2d039 -- packaging/` must then show only what this plan adds, which is
nothing there); the JACK sections of `docs/tiles-and-audio.md` and `docs/install.md`.

Keep: `render(out, frames)` and its tests (the split-request test among them),
`max_request`, `src/gui/audio_alsa.zig`, the start-up line naming the output (it may go
back to not naming one if only one exists; your choice, say which). `render` is what the
Mac's Core Audio will call, so it must stay fit for a real-time callback and for varying
frame counts although ALSA never varies them.

## 2. The period as a setting

Today `audio_alsa.zig` asks for 128-frame periods and a buffer of two. Through PipeWire
the device's side of the latency is that buffer plus two of PipeWire's quanta, and the
quantum follows what dimna asks for only down to its own period. Measured on the rig
(board, normal priority): 128 gives 16.8 to 17.3 ms in all, 64 gives 10.1 ms, 32 gives
6.9 and 7.5 ms, without sound being dropped.

- A config key and an option (follow `args.zig`: something like `audio_period = 64` and
  `--audio-period 64`), in frames: a power of two from 16 to 1024, default 128 (today's
  behaviour, unchanged). Anything else is refused with a message, as other bad values are.
- The device buffer stays two periods. Everything that used the period keeps using what
  the device accepted (it may not accept what was asked: the log line says what it gave,
  as now).
- PipeWire's quantum: the ALSA plugin takes it from the environment variable
  `PIPEWIRE_LATENCY` (`<frames>/<rate>`). When the setting is not the default and the
  variable is not already set, dimna sets it to `<period>/48000` before any thread is
  started and before the device is opened (once, early in `main`: setting the environment
  from a threaded program is not safe later). If the user has set the variable, leave it.
  With the default period nothing is set (today's behaviour). Say in the docs that on a
  machine without PipeWire the variable does nothing.
- `docs/tiles-and-audio.md`: the setting, the figures above, and the advice to try 64
  first and to watch the gap and dropped counts in the log under the machine's real load
  (cameras, encoding) before settling on 32.
- Tests: the option and config key (values accepted and refused, the command line winning);
  the environment variable is set only when it should be (factor the decision into a
  function that returns what to set, and test that; do not change the test process's
  environment). No test opens a sound device.

## 3. Acquisition above PipeWire's thread

Through PipeWire, PipeWire's own thread inside dimna (`data-loop.0`) runs at SCHED_FIFO
80 on the rig: above the acquisition thread, which asks for 70. PipeWire asks for 88 by
default and gets what the user's limit allows (`ulimit -r` is 80 on the rig, from the
limits file). The owner wants acquisition above it.

- The acquisition thread asks for SCHED_FIFO **90**. If that is refused, it asks for the
  highest the limit allows (`RLIMIT_RTPRIO`; through `os.zig`, Linux only, macOS keeps
  ignoring the number) and logs once, as a warning, what it got and that the limit should
  be 95 (naming `packaging/99-dimna-realtime.conf`). If that is refused too, it carries on
  at normal priority with today's warning. `Acquisition.realtime` keeps its meaning.
- `packaging/99-dimna-realtime.conf`: `rtprio 95` (PipeWire then gets its 88, below 90).
  `packaging/install-user.sh` checks `ulimit -r` against 70 today: it should want 95 and
  say why. `docs/install.md` to match, with the one line an existing installation needs
  (edit the file in `/etc/security/limits.d/`, log out and in). An agent does not touch
  `/etc`; the owner does.
- Nothing else about the thread changes. The backfill thread's idle priority is untouched.
- Tests: on a thread of its own, the new function gets 90 when the limit allows and the
  limit's value when it does not. The second case needs a lower limit: run the test binary
  under `prlimit --rtprio=10:10` (or `ulimit -r 10` in a subshell) and show both runs; the
  test reads the limit and expects accordingly, so it passes on any machine and proves the
  fallback where the limit is low. The simulator never asks for real time
  (`realtime=false`), so no `--sim` run reaches this code: say so.

## Evidence

1. `zig build test --summary all` before and after, with the counts explained (tests
   removed with JACK, tests added), and `zig build test -Dgui=false --summary all`.
2. `git diff ad2d039 --stat -- packaging/ src/gui/` and a list of every trace of JACK left
   in the tree (`grep -rni jack src packaging docs README.md build.zig`, plans excepted),
   which should be none or explained.
3. The priority test under the rig's limit (80) and under a limit of 10, with output.
4. `zig build --release=safe`; `zig build release` passes its CHECK; `readelf -d` NEEDED
   unchanged.
5. `dimna-headless --sim 32,16 --seconds 10 --record /tmp/<yours>/a`: `CLEAN`,
   `dimna_read.py` `OK`.
6. `zig fmt --check src build.zig`; `sh -n` on the scripts you touched; the stored GUI
   outputs untouched.

Break it on purpose, once each: the period option accepting 48 (a test fails); the
environment decision overriding a variable the user set (a test fails); the fallback
asking for the limit plus one (the low-limit run fails or reports normal priority).

What the lead will get on the board: the default period against the baseline; 64 and 32
with the log's quantum and counts; the threads' priorities with acquisition at 80 (the
rig's limit until the owner raises it) and a soak.

## Files you may change

`src/gui/audio_out.zig`, `src/gui/audio_alsa.zig`, `src/gui/audio_jack.zig` (removed),
`src/gui/tests.zig`, `src/gui/args.zig`, `src/gui/main.zig`, `src/gui/pipeline.zig`,
`src/acquisition.zig` (the priority only), `src/os.zig`, `src/os_linux.zig`,
`src/os_darwin.zig` (the new function's macOS side: there is no such limit, return what
makes the caller behave as now), `packaging/dimna-jack.service` (removed),
`packaging/dimna-launch.sh`, `packaging/dimna-desktop-launch.sh`,
`packaging/99-dimna-realtime.conf`, `packaging/install-user.sh`,
`docs/tiles-and-audio.md`, `docs/install.md`. If `packaging/nfpm.yaml`, the CI scripts or
`README.md` state the old limit or the old priority, list where; change only `README.md`.

## Done means

The evidence and the break-it results are in your report; the three changes are separate
commits on `macos-port` in the rig's worktree; the worktree is clean; nothing of yours is
left in `/tmp`.
