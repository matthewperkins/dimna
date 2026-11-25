# From kalila: live output settings and their copies (2026-11-25)

A note from the kalila session for whoever works on dimna next. It is not a plan and
nothing here has been run against dimna. The first part is what kalila found in its own
code; the second is what I saw reading dimna's source for the same pattern, as questions
to check, not findings.

## What happened in kalila

Four board settings can be changed while acquiring: the TTL output mode (software or DAC
threshold), the DAC high-pass (on/off and corner), and the audio noise slicer. In kalila
they existed in three places: the Outputs panel's settings, the board settings (the app's
copy and the board object's own), and the engine's snapshot while acquiring. Code copied
them between the three.

We tried to give them one owner on the condition that the registers written to the board
stayed identical. No option met that condition, and the reason was the useful result:
**the board-side copy was not redundant.** It was the value written at board open, at
every Apply and at the start of every acquisition, and it was saved in the config. It
held "the panel's values as of the last acquisition", which is not the panel's current
value after any edit made while idle.

Three quirks followed from that, all found by tracing who writes each copy and when the
board is programmed from it:

1. **An edit made while idle reached the board late.** The panel's values were only sent
   as live commands while acquiring. At Start the board was programmed from the board-side
   copy (old values), acquisition began, and the panel's values arrived one GUI frame
   later: about 16 ms of acquisition with the old DAC high-pass, noise slicer and TTL
   mode. An Apply while idle also wrote the old values.
2. **A live command still queued at Stop was lost.** The acquisition loop left without
   draining its command queue. The app had already recorded the new value as sent; after
   Stop it took the board's older value back, silently.
3. **The simulator did not record live commands in its settings**, the real board did.
   So a simulator session could save stale board-side values into the config, and the
   next open on the real board wrote them.

A fourth point that the trace made visible: the DAC high-pass coefficient is computed
from the *current sample rate*, so it has to be rewritten after every sample-rate change,
not only when the corner changes. kalila does this because every Apply reprograms the
live settings; a design that sends only what differs must not lose it.

kalila's fix (decided, being implemented): the panel owns the four values and they are
overlaid onto the board settings wherever settings are handed to the board (open, Apply),
so the board carries the current values before Start. The simulator records live
commands as the board does.

## The general shape of the quirk

Any setting that can be changed on the fly has at least two copies: what the user asked
for, and what the board was last told. The quirks live where the two are allowed to
differ and something programs the board, saves a file, or decides "nothing to do" from
the wrong one. The questions that found them:

- For each live setting, list every writer and reader of each copy.
- List every moment the board is programmed with it (open, apply, start, live command,
  reopen after a fault) and which copy that code reads.
- What does a diff of old against new use as "old", and can "old" claim a value the board
  never received?
- What is saved to the config, and which copy wins when the file is loaded?
- Does the simulator update the same state the real board does?

## What I saw in dimna (to verify; read only, nothing run)

dimna's design is simpler than kalila's was: one `Settings` struct, and
`Acquisition.applySettings` diffs the new settings against `Acquisition.requested` and
queues one command per changed field. `Board.live` writes the register and updates
`Board.settings`. So there are two copies: `requested` (caller's side) and the board's.
Things worth checking against the list above:

1. **Commands queued at Stop.** `Acquisition.run` pops commands after each block and
   leaves the loop when `stop_flag` is set, without draining the queue.
   `applySettings` has already set `requested = new`. If a command is still queued at
   that moment, `requested` claims a value the board did not get. Then:
   - Does the next start reprogram from `requested` (as `reopenSource(self.acq.requested)`
     does), or does `Board.start` → `applyLiveSettings` use the board's own, older copy?
   - If the latter, the next `applySettings` diffs against `requested`, sees no
     difference, and sends nothing: the board keeps the old value until that field is
     changed again.
   - Are the leftover commands still in the queue at the next start, and applied then
     with a sample stamp from the new run? Is `idle()` ever true again if they are
     dropped (`applied + failed == submitted`)?
2. **A command that fails on the board.** `apply` counts it in `failed` and logs an
   event, but `requested` already holds the new value. Same consequence as above: the
   diff will not resend it. Is the GUI told, and does anything put `requested` back?
3. **`QueueFull` part-way through `applySettings`.** The `try self.submit(...)` calls run
   in sequence and `requested = new` comes last. If the queue fills after some commands
   were queued, those are sent now and sent again on the retry. Probably harmless
   (same value twice), but each writes an event.
4. **The simulator.** `Sim.live` records only `set_ttl_out`; the real `Board.live`
   updates `settings` for the TTL mode, DAC high-pass and noise slicer. Anything that
   reads `source.settings()` after live changes (for instance
   `self.requested = self.source.settings()` at init, or a reopen) sees different state
   on the simulator than on the board. This is exactly kalila's quirk 3.
5. **What is saved.** The config is written from `acq.requested`. That is the user's
   intent, which is the better choice (kalila saved the board-side copy), but together
   with points 1 and 2 it means the file can hold a value the board never took, and the
   next launch then applies it. That is arguably right; it is worth deciding on purpose.
6. **Edits while not acquiring.** How does a change to these fields made while stopped
   reach the board: through `Board.applySettings` before start, so the registers are
   right before the first sample? Or only through the live path once running (kalila's
   quirk 1)?
7. **DAC high-pass and the sample rate.** `set_dac_hpf` is queued only when the enable or
   the corner differs. A sample-rate change is classified `.restart`; check that the
   restart path recomputes and rewrites the coefficient at the new rate
   (`applyLiveSettings` calls `setDacHpf(s.dac_hpf_hz)`, so it likely does if that runs
   after the rate change).
8. **`classify` and the per-field diff are two lists of the same fields.** A field added
   to one and not the other either never applies live or applies without being
   classified. kalila had the same shape (a comparison and a mirror). A test that walks
   every field of `Settings` and checks it is in exactly one class, and that every
   `.live` field produces a command, would pin it.

## A way to test it without a board

What worked in kalila: make "which commands would be sent" a pure function of (settings,
what was last sent) and pin it with a scripted sequence (first start, one edit, an edit
while idle, stop with a command pending, restart, a failed command). For dimna the
equivalent is a test around `applySettings`/`run` with a fake source that records the
commands it is given and can refuse one, asserting after each step that the fake's
settings equal `requested`, or that the difference is reported.

kalila's analysis is in its repository: `docs/plans/2026-11-25-improvements.md` (package
3e) and the test `board_and_outputs_keep_their_own_output_values_at_load` in
`app/src/config.rs`.
