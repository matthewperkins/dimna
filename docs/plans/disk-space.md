# Plan: free disk space, seen before it matters

Read `docs/plans/README.md` first. This replaces item 2 of `improvements-2026-11.md` (a
fallback place to record, and retries on the same files). The owner set item 2 aside: a
fallback disk is weak insurance (an sshfs mount or a USB disk hangs rather than failing,
and an sshfs sync does not mean the bytes are on a disk), it changes how every recording
is written, and it invites not watching the free space. The prototype stays on branch
`imp/2-recorder-fallback`, unmerged. On the rig the likely failure is a full disk: the
recordings go to `~/dimna-recordings` on `/home` (btrfs, NVMe), 91 % full on 2026-11-25
with 87 GB free, about 8 hours at 32 + 16 channels and 30 kHz.

**The recorder is not touched.** No change to `record.zig`, to what is written, or to when.

## What is there already (checked on `main`, `cc44e0c`)

- `session.DiskWatch` (`src/gui/session.zig`): while recording, a `statfs` every 5 s; time
  left from the faster of the falling free space (the cameras may write to the same disk)
  and the recorder's own rate, over the last 5 minutes. It counts the last 5 GB as full
  (`reserve_bytes`; btrfs can refuse writes for want of metadata space before the free
  space reaches 0, and its free space moves only at a commit, every 120 s on the rig).
  `DIMNA_TEST_DISK_RESERVE_GB` raises the reserve for testing.
- `session.Alarms`: a warning under 30 min left, an alarm under 5 min and again under
  1 min, each until acknowledged. Texts in every language (`alarm_disk_full_in`,
  `warn_disk_full_in`).
- The control window shows the recording's length, GB and samples, and "behind" when the
  recorder lags; **nothing about free space**.

## What is missing

1. **Before recording, nothing is shown.** `DiskWatch` runs only while recording, and gives
   no figure until it has two looks (5 s). The free space when you press Record, and how
   long that lasts, is not on screen.
2. **The thresholds are for a recording already in trouble.** 30 minutes of warning comes
   too late for anyone not at the rig (an overnight session).
3. **`dimna-headless` watches nothing.** A headless recording that fills the disk ends in
   "recording FAILED" with no warning before.

## The design

### The rate a recording will write, known before it starts

`bytes_per_s = layout.width × 2 × sample_rate`, plus the index (64 B a chunk, about 640 B/s
at 30 kHz) and TTL (negligible). From the layout, so it is known while idle and changes
with the channel count, AUX/ADC and the rate. A function in the core (`src/disk.zig`,
below), with a unit test against a real recording's file sizes.

### `DiskWatch` moved to the core

`DiskWatch` and `freeBytes` move from `src/gui/session.zig` to a new `src/disk.zig`
(exported from `root.zig`) so the headless program can use them. A move, not a rewrite
(README rule 8): the GUI behaves the same. One addition: `left` takes the expected rate as
a floor, so there is a figure from the first look instead of after two.

### The control window, recording section, always

One line under the Record button, idle or recording:

    disk: 87 GB free, about 8 h 20 min at this layout

dim when more than 2 h is left, the warning colour below it, the alarm colour
below the first alarm threshold. While idle it is refreshed every 5 s with the same
`statfs` (microseconds); while recording it is `DiskWatch`'s figure (which also sees the
cameras). New message keys in every language (`docs/plans/translations.md` steps).

### The reserve: 10 GB (owner, 2026-11-25)

`reserve_bytes` goes from 5 GB to **10 GB**: the last 10 GB of the disk count as full, in
every figure of time left. Not configurable below 10 GB (a larger value may be set).

### Pressing Record with little room (owner, 2026-11-25)

- **Less than 10 GB free: the recording is refused.** Nothing is created; the recording
  section says why ("not recording: 8.2 GB free on /home, at least 10 GB needed"), as the
  other refusals to start do (`recording_failed` path, an alarm until acknowledged).
- 10 GB or more but under 2 h left: the recording starts, with the warning up at once.

### Thresholds (owner, 2026-11-25)

Time left (counted to the 10 GB reserve) is raised at **2 h, 1 h and 30 min**, each as an
alarm until acknowledged and raised again only below the next, as the disk alarms are
today; below 2 h the warning line stays. The existing final alarms at 5 min and 1 min stay.
So `disk_alarm_s = { 2 h, 1 h, 30 min, 5 min, 1 min }` and `disk_warn_s = 2 h`. Constants,
not config keys (the owner did not ask for them to be set per rig).

### `dimna-headless`

- At the start of a recording, one line: `disk: 87 GB free at /home/.../dimna-recordings,
  about 8 h 20 min at 48 channels, 30000 Hz`.
- Less than 10 GB free: refuse to start, exit 2, with the figures.
- With `--seconds N` and a recording needing more than the free space less the 10 GB
  reserve: refuse to start, exit 2, with the figures (owner, 2026-11-25). No override.
- Without `--seconds`, the same alarms at 2 h, 1 h, 30 min, 5 min and 1 min left, as lines
  on stderr.
- While recording, the same `DiskWatch` every 5 s; a line on stderr when a threshold is
  crossed (`WARNING: the disk is full in about 1 h 50 min (12.3 GB left)`), once per
  threshold.
- `DIMNA_TEST_DISK_RESERVE_GB` read by headless too, so all of this can be tested with the
  simulator on a disk that is not full.

## Tests (core, no window)

- `bytesPerSecond` against the sizes of a `dimna-headless --sim` recording's files after
  N s (within the index's rounding).
- `DiskWatch` with the rate floor: a figure from the first look; the existing tests
  unchanged.
- Headless: with `DIMNA_TEST_DISK_RESERVE_GB` set to (free − 1 GB), `--seconds 3600`
  refuses with exit 2; with the reserve set above the free space, any recording refuses;
  a short recording with the reserve set to leave ~2 minutes prints the alarm lines.
- GUI refusal: the function that decides (free, reserve) → refuse or start, tested
  without a window. All `--sim`, temp folders under `/tmp`.
- Each broken on purpose once (README).

The control-window line needs a window to see; its text is built by a function tested
without one, as the other status texts are.

## Files

`src/disk.zig` (new), `src/root.zig`, `src/gui/session.zig` (the move), `src/gui/main.zig`,
`src/gui/control.zig`, `src/gui/control_view.zig` or wherever the snapshot carries the
figures, `src/gui/lang/*.zig`, `src/headless.zig`,
`docs/control.md`, `docs/recording.md` (a paragraph: no fallback, watch the space; why).

## Not covered

- A disk that fails other than by filling (I/O errors, a hung mount): unchanged, the
  "RECORDING FAILED" alarm.
- Space taken by other programs faster than the 5-minute window can see.
- Deleting or moving old recordings for the user.

## Decided by the owner (2026-11-25)

Alarms at 2 h, 1 h and 30 min left (plus the existing 5 and 1 min); a 10 GB reserve; a
recording refused with less than 10 GB free; headless refuses a `--seconds` the disk cannot
hold.
