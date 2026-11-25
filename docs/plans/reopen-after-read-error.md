# Plan: open the board again after a read error

Read `docs/plans/README.md` first; its rules apply. This is item 1 of
`docs/plans/improvements-2026-11.md`. Branch `imp/1-reopen-after-read-error`. The prototype
on the branch is **simulator only**: nothing here has been run against the board, and
nothing is to be merged until the owner has read this plan and the code.

## What happens today (read from the code at 0aa7e96, and checked)

`Acquisition.run` (`src/acquisition.zig`, the `readBlock` catch in `run`) stores the error
in `failure`, logs "acquisition stopped by a read error", and the thread returns. Nothing
opens the board again.

**The running recording is not closed by the failure.** The recorder is only a ring reader:
it has no idea acquisition ended. It keeps polling an empty ring.

- GUI (`src/gui/main.zig`, the comment above the main loop: "a recording in progress is
  kept until it is stopped"; `docs/control.md`, Alarms): the recording stays open and the
  control window still says *recording* (the clock runs on) until the user presses Stop or
  quits. Then it is closed normally: last chunk, `stop` event, `[final]`. The files hold
  every sample acquired before the error, and `[final]` looks exactly like a clean stop
  at the user's request: nothing in the recording says acquisition had ended, or when.
  `end_sample` is the last sample acquired; the stop time in `[final]` is when the user
  pressed Stop, which may be hours later.
- `dimna-headless` (`src/headless.zig`): `Soak.run` ends its loop when `acq.done` is set,
  `finishRecording` closes the recording with `[final]` (it holds every sample the
  consumer saw), and the program exits 1 ("acquisition thread ended early"). Again
  `[final]` does not say why.

**Corrections to the list (improvements-2026-11.md, item 1):**

1. `DIMNA_TEST_SIM_FAIL_AT` exists only in the GUI (`src/gui/env.zig`), not in
   `dimna-headless`. It makes the simulator fail at that second **and at every read after
   it** (the simulator's sample count stops advancing), so it cannot be used as it stands
   to test a restart: the restarted simulator starts at sample 0 again and would fail
   again at the same second.
2. **`NoDevice` never reaches the acquisition thread.** The USB layer has it
   (`src/usb.zig`, `usb_linux.zig`, `usb_darwin.zig`), but `oni_usb.zig`'s `readStream`
   logs it ("data read failed: NoDevice") and returns `ONI_EREADFAILURE`, and
   `oni.Context.readFrame` turns every liboni error into `error.OniFailed`. The d3xx
   driver is the same. So "what is not retried: a board that is gone (`NoDevice`)" cannot
   be decided from the read error. It can be decided at the **open**: liboni's
   `oni_init_ctx` returns the driver's code, and both drivers return `ONI_EDEVID` when no
   board is on the bus (`oni_usb.zig` `init`, `vendor/liboni/drivers/ft600/onidriver_ft600.c`).
   `Board.open` reports that as `error.NoBoard`, like every other open failure, but
   `oni.lastError()` still holds `ONI_EDEVID`. That is what the plan uses.
3. The rest is as the list says: `Board.start` makes the parser anew, so sample numbers
   start at 0 again (the first frame's counter is taken as sample 0); the alarm text is in
   the test at `src/gui/session.zig` ("... restart dimna"); `main` returns 1 when
   acquisition has ended.

## The owner's decisions (given)

- After a restart, the recording that was running is **closed**, with `[final]` saying why,
  and a **new recording folder** starts in the same session. Not one file with a gap.
- A plan file and a prototype with simulator tests; nothing merged before the owner has
  read both.

## What the board gets on a reopen

Nothing new. A reopen is the existing quit path followed by the existing launch path, in
the same order, with the settings in use:

1. `Acquisition.join` → `Board.stop` (as at quit or at an "Apply (restarts acquisition)"):
   `setContinuous(false)`, `setMaxTimestep(0)`, `stopHw`, `resetBoard`. On a link that has
   gone these fail; the failure is logged as a warning, as at quit today.
2. `Board.close` → `oni_destroy_ctx` (`oni_usb.zig` `destroyCtx`: FIFO reset GPIO, close the
   device), as at quit.
3. `Board.open(io, driver)`: `detect`, `initialize`, `scanPortsImpl`, as at launch.
4. `Board.applySettings(settings)`, as at launch (where it gets the config's settings): the
   settings are those last requested (`Acquisition.requested`: the config's, plus any change
   made from the control window since, which are all of the kinds launch applies).
5. `Board.start`, as at launch.

Not repeated, because they are once per process and still in effect: `mlockall`, and for
`--driver d3xx` the driver search folder. `oni_usb.register` is called again by
`Board.open`; it only stores the same table again.

What differs from a launch, and is not a register write: the host's counters
(`types.Health`) are reset by `start`, as at launch, so the callers add up what was counted
before (the alarms' counts and headless's summary keep the session's totals). The DAC
routing and TTL-out word are not carried over; nothing in the GUI or headless sets them
today, and `start` writes TTL out 0 as at launch.

After the reopen the layout (rate, headstages, channels per headstage, AUX, ADC) must be
the same as before. A port scan that finds a different set of headstages (a connector
half out) is a failed attempt; the board is closed and tried again at the next attempt.
The board ID is compared too: a different board on the bus is not continued with.

## Attempts, spacing, and waiting for a board that is gone

A small state machine in the core, `src/reopen.zig` (`Reopen`), with no I/O of its own
(the callers do the reopening; it says when). Its policy:

- **Attempts:** up to 6, after 0.5, 1, 2, 5, 10 and 30 s (about 48 s in all). The first
  waits half a second because after a glitch Linux often takes the device off the bus and
  back (re-enumeration), and udev must apply its permissions rule before the device can be
  opened; an open before that fails with `AccessDenied` (counted as an attempt).
- **A board that is gone** (`Board.open` fails with `ONI_EDEVID`: no FT600 with the board's
  product string on the bus) is **waited for, not retried**: looked for once a second, for
  as long as dimna runs, without using up an attempt. The alarm says it is waiting. When
  the board appears, the next attempt is made at once.
- **A run that fails again soon:** an attempt counts as used when it is made. The count goes
  back to 0 only when a restarted run has lasted 60 s. So a cable that fails every few
  seconds is opened again at most 6 times (6 new recording folders at most) and then left;
  one that fails once an hour is reopened every time.
- **Giving up:** after the 6th failed attempt, as today: the alarm "ACQUISITION STOPPED
  (...)", then, acknowledged, the warning "... restart dimna". The program does not exit
  (the user may still look at what is on screen and stop the recording).

## What is shown

On the display's red bar (and the control window, which shows the same alarms), with the
tone, until acknowledged (Shift+a or the button):

- while waiting for an attempt: `ACQUISITION STOPPED (OniFailed): opening the board again
  in 4 s (attempt 3 of 6)`;
- while the board is gone: `THE BOARD IS GONE (OniFailed): waiting for it to come back
  (12 s so far)`;
- after a restart: `ACQUISITION RESTARTED 1 time after a read error (OniFailed); 2.3 s not
  acquired; the recording goes on in a new folder` (the last part only when recording).
  This stays until acknowledged, like the other counted alarms; a second restart counts 2.
- after giving up: today's alarm and warning, unchanged.

The "not acquired" seconds are the host's clock from the read error to the first block of
the new run: an estimate, shown, never written as a sample count. The log says the same at
each step (`acquisition: opening the board again (attempt n of 6)`, `... the board is gone;
waiting for it`, `... acquisition restarted after a read error`).

New English messages only, in `src/gui/lang/en.zig`; the other languages show them in
English until translated (`i18n.zig` falls back per message).

## The recording

At the read error, if a recording is running:

1. it is closed at once, not when the reopen succeeds: the recorder records up to the last
   block acquired (all of them: acquisition has stopped), writes the `stop` event with the
   reason as its text, and `[final]` with a new key:

       [final]
       reason = "acquisition stopped by a read error (OniFailed)"

   Absent after a stop by the user. This adds a key to format v1 (readers that ignore
   unknown keys, `dimna_read.py` among them, are unaffected); `docs/recording.md` says so.
2. When the reopen succeeds, a new recording starts **before** acquisition is started
   again, so it has the first block of the new run, in the same session folder:
   `SESSION/ephys/` was the first, the next is `SESSION/ephys_2/`, then `ephys_3/`. The
   `current` link is not touched (it already points at the session). The new recording's
   `start` event text says what it continues: `after a read error (OniFailed); continues
   SESSION/ephys`. Its sample numbers start at 0 again, and each folder is a complete,
   self-consistent v1 recording that `dimna_read.py` verifies on its own.
3. If the user presses Stop while dimna is waiting to reopen, nothing new is started. If
   the attempts are given up, no new folder is made.

`dimna-headless` has no session folders; its next recording is a new
`ROOT/YYYY-MM-DD_HH-MM-SS/` beside the first, and the check at the end
("recorder wrote N samples but M were acquired") is made for each recording.

## Where the code goes

- `src/reopen.zig` (new, core): `Reopen`, the policy and its state; unit tests with a
  made-up clock.
- `src/acquisition.zig`: `Acquisition.reopenSource(settings, layout)`: joins the ended
  thread, has the source opened again, checks the layout, readies the thread to be
  started. `start` stays the start (so a recorder can be attached in between).
- `src/source.zig`: `Source.reopen(settings)`.
- `src/board.zig`: `Board.reopen(settings)` (close, `open`, `applySettings`, as above;
  `error.BoardAbsent` when no board is on the bus), and a `closed` flag so `close` is safe
  after a reopen that failed.
- `src/oni.zig`: `lastOpenFoundNoBoard()`, which reads `lastError() == ONI_EDEVID`.
- `src/sim.zig`: the read error happens a given number of times (`fail_times`, 1 by
  default; each run fails once at `fail_at_s` until used up), and `reopen` can be made to
  report the board gone or failing a given number of times.
- `src/record.zig`: `Recorder.setStopReason`, `[final] reason`, `Info.continue_in` (the
  `ephys_N` folder in an existing session), and the `start` event's text.
- `src/headless.zig`: the loop goes on through a restart; `DIMNA_TEST_SIM_FAIL_AT=<s>[,<times>]`
  with `--sim`, as the GUI has it.
- `src/gui/`: `pipeline.zig` (`Pipeline.reopen`: as `restart`, with the reopen in place of
  the new settings, and not started, so the recording can be attached first), `main.zig`
  (drives `Reopen`), `session.zig` (alarm texts; `Recording` closes with the reason and
  resumes in the session), `env.zig` (the `,times` part), `lang/en.zig`.

## Evidence

- `src/reopen_test.zig` (core, no window): the simulator fails at 0.3 s; the test reads the
  ring as a consumer would and keeps a copy of every block; the recording is closed with
  the reason, the source is opened again, a second recording starts, and after the second
  run both folders are read back: every sample of every block acquired before and after
  the failure is in one of them, in order, with nothing else; `[final] reason` is in the
  first; both verify with `tools/dimna_read.py` (run by the test when `python3` with numpy is
  there; said when skipped).
- `src/reopen.zig` unit tests: the spacing, the 6-attempt limit, the absent board not using
  attempts, the count going back to 0 after a stable run.
- `dimna-headless --sim` with `DIMNA_TEST_SIM_FAIL_AT`, by hand, its two folders verified
  with `dimna_read.py`.
- On the board: **not run**. Only the owner can (pulling the cable, or a USB reset of the
  port while acquiring). Until then the commits say "simulator only".

## Not covered

- The real failure modes of the board's USB link: whether after a glitch the FT600 comes
  back at all without a power cycle, how long re-enumeration takes, whether the board's
  gateware needs more than `initialize` after an unclean stop. All guessed.
- A read that hangs rather than fails: the USB read times out after 1 s and is tried
  again inside the driver, so a silent board raises no error. That stays the "no data"
  alarm, and is not reopened (it could be, after some seconds: an owner question).
- The GUI's part is compiled and its alarm texts are tested; the main loop's reopen is not
  run by any test (it needs a window). It can be tried on the simulator with
  `DIMNA_TEST_SIM_FAIL_AT`, by someone allowed to open windows.

## Questions for the owner

1. Folder names in the session: `ephys/`, `ephys_2/`, `ephys_3/`?
2. 6 attempts over about 48 s, then give up; and wait without limit for a board that is
   gone. Right? (The other way: wait for a gone board only so long.)
3. `[final] reason` as the only new key, still format version 1? Or also a key in the new
   recording's `[start]` naming the recording it continues (today only its `start` event
   says so)?
4. Should a board that has gone silent (no error, no data for N s) be reopened too?
