# The control window: recording, board settings, alarms, saving the view

[Back to the README](../README.md)

## Control window

A second, ordinary window (class `dimna-control`) shows the run's
status (display latency, frame rate, blocks the display skipped, ring overflow) and, for
every panel, buttons for what the keys do: view (scroll / sweep / triggered), time base or
trigger window, scale, filter and its corners, trigger line and number of overlaid sweeps,
reset; and Quit. The wheel over a stepper steps it. `--no-control` or `control = false`
leaves it out.

It opens small: the status line, Record, and one summary line each for Notes, Audio,
Spikes (the threshold's sigmas, with its − / +), Headstages and every panel. A click on a
heading (▸) opens that section's controls below it, another closes it. Headstages stays
open by itself while a restart is pending or the settings differ from the config file, so
Apply and "Save as default" cannot be hidden when they matter. Which sections are open is
saved by "Save view" (a `[control]` table of `views.toml`), but opening one is not by
itself a change that quitting asks about.

It runs on its own thread with its own Wayland connection (`src/gui/control.zig`), and
shares no lock with the display: the display publishes a snapshot of its panels, the
control window queues edits, and the display applies them between frames as it does key
presses. So a slow or hidden control window cannot delay a trace, and closing it leaves the
display running. Both windows use one Vulkan instance (with two, NVIDIA's driver crashed
at exit). The control window must not open on the neural display's monitor, or tearing
stops; a Hyprland rule places it:

    hl.window_rule({ name = "dimna-control", match = { class = "^dimna-control$" },
                     workspace = "1", float = true, move = "966 51", size = "938 561" })

With it open on the board (tearing on DP-2): 2.4 to 2.5 ms, as without.

## Recording

Record / Stop recording in the control window. Acquisition and the display
carry on throughout; each press of Record makes a new session (no restart of dimna). While
recording, the control window shows the time, size, how far the disk is behind and any
gaps, and the neural display shows "REC" with the time beside its latency read-out.
Under Record, idle or recording, a line says how much room is left where recordings go:
"disk: 87.0 GB free, about 7 h 26 min at this layout" (the time counted to the last
10 GB, at the rate the current channels and sample rate write; while recording, as the
alarms below see it). It is dim with more than 2 h left, amber below 2 h and red below
30 min. With less than 10 GB free, Record is refused: nothing is created, the line under it
says why ("not recording: 8.2 GB free under ..., at least 10 GB needed") and the
recording-failed alarm is raised until acknowledged. A
recording that fails (disk full, say) is shown as failed; acquisition is not affected and
what was written before stays valid. Quitting while recording closes the recording
properly first.

## Saving the view

`config.toml` is the rig's setup, written by hand, and dimna never
rewrites its panels. What you set in the control window or with keys and wheel (scale,
time base, mode, filter and corners, rows raw or hidden, per-row scales, CAR and its
rows, trigger settings, tint; the tiles' view and the detection thresholds) is kept in a
second file beside it, `views.toml`, written
by "Save view" in the control window (lit while there is something unsaved) and applied
on top of the config at launch. Panels are matched by name; a view for a panel that is
gone or has another number of rows is skipped. Delete `views.toml` to go back to the
config alone. Quitting with unsaved view changes asks, together with the board settings.

## Board settings

They start from the config file's `[board]` table (command-line
options win over it):

```toml
[board]
sample_rate = 30000
lower_hz = 1.0             # amplifier bandwidth, set on the headstage chips
upper_hz = 7500
dsp = true                 # the chips' digital high-pass (offset removal)
dsp_cutoff_hz = 0.5
half_channels = "A1"       # RHD2132 headstages wired for 16 channels (comma separated)
aux = false
adc = true
leds = false
```

The control window's Headstages section changes them for the run:

- **Amplifier band and DSP high-pass** apply at once and without a gap, also while
  recording (the change and the sample where it took effect go into the recording's
  `events.tsv`). The window shows the values the chips really use.
- **Sample rate and half-channel mode** change the shape of the data, so they are chosen
  first and then applied together with "Apply (restarts acquisition)": acquisition stops,
  the board is reconfigured, and everything that depends on the channel count or rate is
  rebuilt (the display is blank for a moment and its history starts again). Not offered
  while recording.
- **Save as default** writes the settings in use into the config's `[board]` table (only
  that table is rewritten; the file is replaced by rename, so a config that is a symlink
  becomes a plain file).
- **On quitting** (Ctrl+Q or Esc on the display, closing the display window, or Quit; plain
  `q` does not quit), if the settings differ from what the config gave at launch, the
  control window lists the differences and asks: save as default and quit, quit without
  saving, or cancel. A second request quits without saving.
- **While recording, nothing quits without asking.** The control window says a recording is
  running and offers Keep recording (the default) or Stop recording and quit; only those
  buttons answer, and asking to quit again changes nothing. Stop recording and quit closes
  the recording properly, then asks about unsaved settings as above. If the control window
  has been closed, a notice over the display says so instead, and a second Ctrl+Q (or Esc)
  while it is up, within 8 s, stops the recording and quits.
- **`SIGTERM`, `SIGINT` or `SIGHUP`** (a shutdown, Ctrl-C in the terminal that started dimna,
  that terminal closed) quit at once, without asking: whoever sends the signal has decided.
  The recording is closed properly first, as with Stop recording. A second signal ends
  dimna immediately, in case closing hangs.

## Alarms

Anything that means samples are not being kept puts a red bar across the top
of the neural display (and the control window) that stays until it is acknowledged (Shift+`a`
on the display, or the button), and sounds a short tone every second through the audio output, also
when the monitor is muted or off:

- the recording failed (a write error such as a full disk), or could not be started;
- blocks were lost because the recorder fell a whole ring (30 s) behind;
- the board itself dropped samples;
- the recording has gaps;
- no data has come from the board for 0.5 s (a USB read waits up to 1 s and then simply
  tries again, so a board that goes quiet raises no error of its own): the bar counts the
  seconds while it lasts, and says how many such spells there were until acknowledged.
  A quiet board is not opened again (the owner's choice); `dimna-headless` says it on
  stderr at once and every 5 s while it lasts, and exits 1;
- acquisition stopped on an error (a cable pulled, a read failure). The display stays up.
  The recording in progress is closed at once (its `[final]` says why), and the board is
  opened again, as at launch: up to 4 attempts, after 3, 10, 20 and 48 s; a board
  that is not on the bus at all is waited for, looked for every second, without using up
  an attempt (the bar says which). When it is running again the recording goes on in a new
  folder of the same session (`ephys_2/`, ...), and the bar says acquisition was restarted
  and how long was not acquired, until acknowledged. The attempts come back after a run of
  60 s. When every attempt has failed the bar says so; once acknowledged, an amber bar
  stays, since nothing is being read until dimna is restarted. (Simulator only so far:
  `docs/plans/reopen-after-read-error.md`.)

An amber bar warns earlier, while the disk is more than 5 s behind, and goes when it has
caught up.

**The disk filling.** While recording, dimna looks at the free space of the recording's
disk every 5 s and works out how long until it is full: from how fast the free space fell
over the last 5 minutes (so the cameras writing to the same disk count), the recorder's
own rate, or the rate the layout writes at, whichever is fastest (so there is a figure from
the first look), counting the last 10 GB as full (btrfs can refuse writes for want of
metadata space before its free space reaches 0). Under 2 hours an amber bar says how long
and how many GB are left; a red alarm, until acknowledged, under 2 hours, and again under
1 hour, 30 minutes, 5 minutes and 1 minute. On btrfs the free space moves only when a
transaction commits (every 120 s with `commit=120`), which is why the window is 5 minutes
and the recorder's rate is the floor. `DIMNA_TEST_DISK_RESERVE_GB=<GB>` counts that much
as full instead of 10 GB, for testing (`dimna-headless` reads it too). From the board a
value under 10 is ignored: a real recording always keeps 10 GB. With `--sim` it may be
less, down to 0, so the test scripts (`tools/crash-test.sh`, `tools/version-test.sh`, the
CI's simulator recordings) can record into a small `/tmp`; they set it to 1. On the simulator,
`DIMNA_TEST_SIM_STALL=<at s>,<for s>` makes it go quiet once and `DIMNA_TEST_SIM_FAIL_AT=<s>[,<times>]`
makes it fail with a read error (that many seconds into a run, for the first `times` runs, 1 by default). `DIMNA_TEST_RECORD_FAIL_AFTER=<samples>`, `DIMNA_TEST_RECORD_STALL=<samples>,<ms>`
and `DIMNA_TEST_RING_SECONDS=<s>` make these happen on purpose, for testing.
