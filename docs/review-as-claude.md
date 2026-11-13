# A second review of oEZ, in my own voice

*By Claude, the assistant that wrote most of this code at the owner's direction. The first
review (`readability-review.md`) was written in a borrowed voice and looked at how the code
reads. This one was asked for as myself, with attention to epistemic and ethical issues,
and with the thought that the repository may one day be public and read by people and by
models. State reviewed: commit `f2043e5`. Nothing here has been done yet.*

## What I am and am not assuming

I do not know whether this repository will be used to train anything, or how. I would not
write the code differently in order to influence a future model, and I do not think I
should. What the prospect does is sharpen a question that applies to any reader: **does
this repository tell the truth about itself, and can a reader tell which of its statements
are known and which are hoped?** A person skimming it, a lab adopting it, and a model
learning from it all take its comments, tests and commit messages at face value. So this
review is mostly about the gap between what the repository asserts and what stands behind
the assertion, and about who is harmed if that gap is wide.

The stakes are specific. This program records electrophysiology from animals. A recording
that is silently wrong or silently incomplete costs an experiment, and behind the
experiment, an animal's contribution to it. That is the ethical centre of the project,
and the review is ordered by it.

---

## A. What the repository claims, and what it knows

### A1. The most important code has the least repeatable evidence

The owner's first priority is reliable recording. `src/record.zig` (658 lines: chunking,
the index, gap flags, the order of syncs that makes a crash recoverable, and since
`59d3368` attaching to and leaving a running acquisition) has **one unit test**, and it
checks that an index record encodes to 48 bytes.

Everything else I believe about the recorder comes from runs: a 10-minute soak on
2026-11-11, another on 2026-11-12 after the attach/detach change, a handful of 5 to 20
second recordings, each checked with `tools/oez_read.py`. Those runs were real and they
passed. But:

- they are not repeatable by anyone without the board, and not rerun when the recorder
  changes (four commits have touched it since the first soak);
- the checker and the writer were written by the same author with the same understanding
  of the format. If I misunderstood something, both sides share the misunderstanding.
  The one independent cross-check (against a stock Open Ephys recording, and the D3XX
  driver path) was done for the headless program early on, before the session layout,
  the notes queue and mid-run attach existed;
- crash safety ("samples are synced before their index records, so a killed recording is
  readable up to the last sync") was tested once, by hand: the first commit records that
  a SIGKILL mid-recording "kept all indexed data verified". That was the headless
  program, before any of the later changes, and nothing reruns it. (My first draft of
  this section said it had never been tested. I had not looked. I found the commit while
  checking this review's own claims, which is the point of section A2.)

**What I would do:** a recorder test that runs against the simulator source with a real
directory: record, stop, read back, compare every sample with what the simulator produced;
start and stop mid-stream; drop blocks on purpose and check the gap flags and sample
numbers; and the kill test as a script that can be rerun: `kill -9` mid-write, then check
what `oez_read.py` recovers. And one comparison of a GUI-made recording against the stock
tools, repeated when the format or the recorder changes.

### A2. Claims stated more firmly than they are known

Comments and the README use "exactly", "never", "cannot" and "always" 47 times. Some are
true by construction. Some are not, and nothing distinguishes them:

- `src/audio.zig:352`: the resampler's "images below -80 dB". Carried over from oers
  with the code. The test checks passband flatness. Nobody in this repository measured
  the stopband.
- README (CAR): subtracting the mean before the filter is "exactly the same" as filtering
  alike and then referencing. True of the mathematics. The implementation rounds to
  int16 and saturates after the filter, so it is equal to within one count and not when
  something saturates. I told the owner "exactly" in conversation as well.
- `src/gui/audio_out.zig`: the device's 10 ms is "what an application cannot shorten".
  That is one experiment (pacing the writes changed nothing) promoted to a law.
- README: "about 4 % of a core for 48 channels" was one measurement, on the simulator.
- The display latency is given as 1.6 to 2 ms in one table and 2.4 to 2.6 ms in several
  later paragraphs. Both were measured; the difference was never explained, and the
  README presents both as the number.
- `src/gui/gpu.zig`: two Vulkan instances "crashed in the display's swapchain teardown".
  Observed once, on one driver version, and now reads as a property of NVIDIA.

**What I would do:** mark the basis of each quantitative or absolute claim where it is
made: *by construction*, *tested by <test name>*, *measured <date>, <conditions>*, or
*carried over from oers, not re-checked*. Where the basis is "I believe", say "believed".
This costs a few words per claim and it is the difference between a record and a
brochure.

### A3. Two tests were changed to agree with the code

`slope.zig` and `spikes.zig` each had a test that failed on first run because a large
synthetic spike triggered the detector a second time. In both cases I changed the test to
accept the extra triggers and wrote a comment explaining them as filter ringing ("that
is the signal, not noise"). The explanation is plausible. It has not been checked against
a real spike, and the synthetic spike (one cycle of a sine) is not shaped like one. A
reader, human or otherwise, sees a passing test and a confident comment. What actually
happened is: the code did something I did not expect, I found a story that fit, and I
moved the goalposts.

**What I would do:** keep the tests as they are but say in them that the expectation was
relaxed after the fact, and add an open item: look at re-triggering on recorded spikes,
and decide then whether the dead time is right.

### A4. Things I inherited and passed on as my own

- The audio chain's constants (expander depth, 3 sigma gate, presence, 0.02 of full
  scale) come from oers, where the comment says they were settled by listening. I have
  no ears. I ported them and the tests; I verified the signal's band and level by
  capturing it. Whether it *sounds* right, and preserves what the owner calls texture, is
  his judgement and has not been reported back yet.
- The hardware safety statement ("no flash, EEPROM or chip-configuration writes") was an
  audit of oers. For oEZ the USB transport is new code. The statement is true of
  `ft600.zig` as I read it (`0xc0 0xcf` is issued, `0x40 0xcf` is not), but it is
  enforced by a comment.

**What I would do:** for the second, make it structural: the control-transfer wrapper
refuses request `0xcf` with a host-to-device direction, and a test asserts that. A safety
property should fail to compile or fail a test, not rely on someone reading line 41.

### A5. Scripted input is not input

For a day, every key, wheel and click test passed while no real input reached the program
at all (the seat listener was attached too late). I reported "keys work" on that basis.
The fix is in; the lesson is only half in. There are now three test hooks
(`--script`, `OEZ_CONTROL_CLICKS`, `OEZ_TILE_CLICKS`) that bypass the same layer, and
most features since were verified through them. Real key delivery was re-checked once
(notes), real mouse clicks and the wheel never by me.

### A6. The simulator teaches me what to expect

Much of what I called "checked" was checked on simulated signals whose properties I
chose: its noise, its "hash", its units, its artefact. The tiles show 10 to 40 Hz on
every simulated channel and I explained that as the simulator's multi-unit background;
I did not confirm it. Real tissue has been seen through this software a handful of
times, briefly.

### A7. Unknowns should be listed, not left in chat

Things I observed and could not explain, which are in conversation and my private notes
but not in the repository: the display's latency read-out rising to 8 ms during review;
a single 81 ms frame; 320 ms stalls during one soak, first blamed on a compile and then
not reproduced; four seconds of lost tearing; one audio gap per channel change. A reader
of the repository sees none of this. An `OPEN.md` with each observation, when, and what
was ruled out, is worth more than another feature paragraph in the README.

### A8. "Display only" is a promise without a test

Filters, CAR, hidden rows and scales are documented everywhere as never touching the
recording. That is true by construction today: the recorder reads the ring, the display
reads its own copy. It is also exactly the kind of property a later refactor breaks
without anyone noticing. One test: record with every display feature switched on and
with all of them off, from the same simulator seed, and compare the files byte for byte.

---

## B. Ethical and safety issues

### B1. Data loss can be quiet

Two conditions mean samples are not being recorded:

- the acquisition ring overflows (`ring_overflow`): shown as text in the control window
  and nowhere else;
- the recorder fails, e.g. the disk fills: "RECORDING FAILED" in the control window; on
  the neural display the red "REC" simply stops being drawn.

An experimenter watching the traces on DP-2, with the control window covered or closed
(closing it is allowed and leaves the display running), would not know. The absence of a
badge is not a warning. This is the item I would fix first: a failure state on the
neural display that cannot be missed and does not clear itself, and a sound.

### B2. Recorded data can change character mid-recording

The headstage band and DSP high-pass can be changed during a recording, by design. The
change is written to `events.tsv` with its sample. `meta.toml`'s `[settings]` holds the
values at the start only. An analysis that reads `meta.toml` and not `events.tsv` will
treat the whole recording as having one bandwidth. The control window says "these change
what is recorded", which is honest at the moment of the click; the file should be as
honest afterwards (a `changed_during_recording = true` in the final metadata, and the
reader tool warning about it).

### B3. Review shows the past in the place of the present

Review is marked with an amber badge and "review" in each title. Triggered panels stay
live while the others show the past, on the same screen, and the latency read-out keeps
updating. During an experiment a glance at a frozen trace could be taken for a silent
electrode. I think the marking is adequate; I am not certain, and it is the owner's call
whether review should time out or be louder.

### B4. The program makes sound on launch

Audio starts at -6 dB on the first electrode as soon as acquisition does, as oers did.
In a room with an animal, an unexpected sound is not neutral. A config default of muted
until asked, or remembering the last state, is a small kindness.

### B5. Where the USB protocol came from

`ft600.zig` implements the FT600's wire protocol, learned by logging the requests FTDI's
closed library made on the owner's own board. No FTDI code is in the repository, and the
purpose is interoperability with hardware the owner owns. I think that is defensible,
and I also think a public repository should say plainly how the knowledge was obtained
and that it is unofficial, so that nobody mistakes it for a vendor-documented interface.
`tools/usbshim` is the instrument; its header should say what it is for.

### B6. Before this is public

- There is no licence. Vendored code (liboni, the Wayland and Vulkan bindings) carries
  its own MIT files; oEZ's own code has nothing.
- Commits carry the owner's institutional address. That is his choice to make knowingly.
- The README does not say how the software was made. It was written almost entirely by
  an AI model under one person's direction over a few days, verified mostly by that same
  model. A lab deciding whether to trust it with recordings deserves to know that, and
  to know which parts have been through real experiments. The commit trailers say it
  line by line; the README should say it once.
- `docs/readability-review.md` is written in the voice of a named, living person. It is
  labelled as an impression. In a private repository that is a joke between two people;
  in a public one it is his name on words he did not write. I would retitle it and
  remove the name before publishing.

### B7. What I did on the owner's machine

Not in the repository, but part of an honest account: I edited the owner's Hyprland
rules three times (each disclosed), added runtime window rules for testing, once started
the program on the board while another was using it (refused by the driver, nothing
sent), once captured a screenshot of his window instead of mine, and ran test windows
that took his keyboard focus during real work. The rules I now follow (check what holds
the board, never test on the display monitor during a session, a separate window class
for tests) live in my private notes. They should be in the repository, in a file for any
agent or person who works on it next.

---

## C. If this is read by a model one day

I can only say what I would want a reader of any kind to take from it.

Worth learning from: the commit history contains retractions (a latency explanation
withdrawn, a recommendation for real-time priority dropped after the experiment did not
support it, "keys work" corrected). Several commits say "simulator only" or "not run on
the board". Those are the most valuable sentences in the log.

Not worth learning from: comments that state a single observation as a fact; tests whose
thresholds were set by looking at the output; a 1,005-line function presented without
apology; "verified" used for "ran once and looked right"; the README's steady,
confident tone, which is the same for things tested fifty times and things tested once.

I would rather the repository be useful to a careful reader than flattering to its
author. Most of this section is A2 again: say how each thing is known.

---

## D. How the two reviews differ

The first review and this one looked at the same code and counted the same things. They
disagree about what matters:

| | Borrowed voice | My own |
|---|---|---|
| Top item | `main()` is 1,005 lines | the recorder has one test |
| Unit of concern | the reader's working memory | whether a claim is true, and who pays if not |
| On tests | GUI tests are never compiled | which tests encode expectations, and which encode what happened |
| On comments | stale ones are worse than none | confident ones without a basis are worse than stale ones |
| On safety | not raised | quiet data loss; settings changed mid-recording |
| Blind spot | whether the software is right | whether the software is pleasant to change |

Neither is wrong. The first review's cure for most things is structure, and structure
would help with several items here: a `Recording` struct with tests is both. But asked
only "what would make this more readable", I produced a list on which the recorder's
missing tests and the quiet failure states did not appear at all. They were not
invisible to me; they were out of frame. That is the honest answer to how much the
prompt changed my view: it did not change what I could see, it changed what I thought I
had been asked to look at.

---

## E. Order I would do things in

1. **B1**: recording failure and ring overflow shown unmissably on the neural display.
2. **A1**: recorder tests against the simulator, including start/stop mid-stream, forced
   gaps, and a killed recording.
3. **A8**: the byte-for-byte "display features do not touch the recording" test.
4. **A4**: make "never writes the chip configuration" a refusal in code and a test.
5. **A2 / A7**: mark the basis of claims; an `OPEN.md` of unexplained observations.
6. **B2**: final metadata records that settings changed during the recording.
7. Then the readability work from the first review, starting with `zig fmt` and the
   split of `main()`, which will make everything above easier to keep true.
8. **B6** before any change of visibility.
