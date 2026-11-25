# Recordings: where they go, the format, and how the recorder is tested

[Back to the README](../README.md)

## Sessions

Sessions go under `record_dir` (config; default `~/dimna-recordings`):

    ~/dimna-recordings/
      2026-11-12_14-03-22/        one session = one press of Record
        ephys/                    the recording (format below)
        video/                    by convention: what the camera recorder writes
      current -> 2026-11-12_14-03-22    link to the newest session

`current` is repointed (atomically) whenever a recording starts, so other programs can
write beside the ephys data without being told the folder's name:

    ./record.sh --out-root "$(realpath ~/dimna-recordings/current)/video"

Start the dimna recording first, so every camera trigger edge is in its TTL files.

### Free space: one disk, watched

A recording is written to one place, `record_dir`, and nowhere else: there is no fallback
disk, and a write that fails is not retried on other files. On the rig the likely failure is
a full disk, and a second disk is weak insurance against it (an sshfs mount or a USB disk
hangs rather than failing, an sshfs sync does not mean the bytes are on a disk, and every
recording would be written differently). So the free space is watched instead, before it
matters (`src/disk.zig`):

- The last 10 GB of the disk count as full in every figure of time left (btrfs can refuse
  writes for want of metadata space before its free space reaches 0). This is not
  configurable below 10 GB.
- A recording is not started with less than 10 GB free: nothing is created, and the
  control window (or `dimna-headless`, with exit status 2) says why. `dimna-headless
  --seconds N` is also refused when N seconds at the layout's rate need more than the free
  space less the 10 GB.
- The control window shows, under Record, the free space and how long it lasts at the
  layout's rate (channels × 2 bytes × the sample rate, and the index), idle or recording.
- While recording, the time left is raised as an alarm at 2 h, 1 h, 30 min, 5 min and
  1 min (each once, until acknowledged), with a warning below 2 h. `dimna-headless`
  prints the free space at the start and a `WARNING:` line on stderr at each of these.

What is not covered: a disk that fails other than by filling (I/O errors, a hung mount:
the recording is shown as failed), space taken by other programs faster than the
5-minute window sees, and deleting or moving old recordings.

## Recording format (v1)

One folder per recording, `ROOT/YYYY-MM-DD_HH-MM-SS/`. All binary files are little-endian and
append-only; `meta.toml` describes everything and is replaced atomically.

| file | contents |
|---|---|
| `samples.i16` | int16 `[n_samples][num_channels]`, raw as acquired; value × `bit_volts` = µV (electrodes) or V |
| `index.bin` | 48 B per ~100 ms chunk: `first_sample i64, n_samples u32, flags u32, byte_offset u64, wall_ns i64, board_clock u64, crc32 u32, pad u32` |
| `ttl_sample.i64` | sample number of each TTL-input change (first entry = initial state) |
| `ttl_word.u16` | the 8-line input word from that sample on (bit k = line k+1) |
| `events.tsv` | `sample<TAB>kind<TAB>text` |
| `meta.toml` | channels, scales, headstages, board, settings; `[final]` only after a clean stop |

`meta.toml` names the format `format = "dimna-recording"`, `format_version = 1`. Recordings
made before the program was renamed from oEZ say `oez-recording`, in the same version 1;
`tools/dimna_read.py` reads both.

`format_version` changes only when a reader of version 1 would misread the new files. Keys
added to `meta.toml` keep version 1: a reader that ignores keys it does not know reads the
recording as before, and a reader that wants a new key must allow for its absence in older
recordings.

### Settings changed during a recording

The amplifier band, the DSP high-pass, fast settle and the board LEDs (which put a ~1 kHz
tone on the ADC inputs) can be changed while recording. `[settings]` holds the values at the
start; each change is a line of `events.tsv`, stamped with the estimated sample it reached the board
at. Every other key of `[settings]` needs a restart, which is refused while recording.
`[final]` says whether any change was made, with the number of `events.tsv` lines of each
kind (keys added in version 1, absent in older recordings):

    settings_changed = true          # any of the four below is not 0
    amplifier_events = 2             # kind "amplifier": band, DSP, fast settle as applied
    amplifier_failed_events = 0      # kind "amplifier_failed": may have taken effect in part
    leds_events = 0                  # kind "leds"
    leds_failed_events = 0           # kind "output_failed", text "set_leds ...": may have taken effect
    events_dropped = 0               # events never written: their queue (256) was full

When `events_dropped` is not 0, `events.tsv` and the counts above may be short: a count of
0 is then not proof that nothing changed. (`leds_failed_events` and `events_dropped` were
added after the other four; a recording may have those without these.)

When `settings_changed` is true, `[settings]` does not hold for the whole recording; read
`events.tsv` for where it changed. `tools/dimna_read.py` warns, lists the changes, and checks
the counts against `events.tsv`. An interrupted recording has no `[final]`; the reader still
warns from `events.tsv`.

What wrote the recording: `software = "dimna 0.2.1"`, the version in `build.zig.zon` (the
build passes it in; it is typed nowhere else), and, beside it, `software_commit`: the git
commit the program was built from, 40 hex digits, with `-dirty` after them when a tracked
file differed from that commit at build time (untracked files do not count). The key is
left out, never guessed, when the build could not know the commit: no git, a source tree
that is not a git checkout of its own (a release tarball unpacked, a copy), a checkout git
refuses (owned by another user, without `safe.directory`), or `zig build -Dgit=false`.
`software_commit` was added within version 1 (recordings from before it lack it); a reader
that ignores keys it does not know is unaffected, so `format_version` stays 1.
`tools/version-test.sh` builds dimna-headless with git, with `-Dgit=false` and with git
not on `PATH`, records a second from the simulator with each, and checks both keys.

### Which channels belong together: groups

A spike sorter needs to know which channels can see the same unit. dimna knows no
coordinates and writes none. What the user can say, in the config (or `dimna-headless
--probe A1=each,B1=4`), is how each headstage's channels group:

    [[probe]]
    headstage = "A1"
    name = "microwire bundle, 16 wires"   # optional, free text
    group = "each"     # every channel alone: wires too far apart to share a unit, or of
                       # unknown geometry (a bundle): each is sorted on its own
                       # "all": one group (a shank); a number n: groups of n (4: tetrodes)

A recording then has, in `[channels]`, `group`: one number per channel, the same for
channels to be sorted together, -1 where nothing is said (a headstage with no probe named,
AUX, ADC). A group's number is the index of its first channel, so it is the same in every
recording of the same layout and never shared between headstages. The `[[probe]]` tables
are written as given, for the connected headstages. Both are keys added in version 1,
absent from recordings made before them and from recordings with no probe named: a reader
must then decide for itself (the owner's pipeline gave every wire its own place 1 mm from
the next, which is `group = "each"`).

### After a read error

(Simulator only so far; `docs/plans/reopen-after-read-error.md`.) The recording is closed
at once, and the board is opened again. Once it runs, the recording goes on in a new folder
of the same session, `SESSION/ephys_2/` (then `ephys_3/`, ...; dimna-headless, which has no
sessions, makes a new `ROOT/YYYY-MM-DD_HH-MM-SS/`). Each folder is a complete v1 recording,
and each numbers its samples from 0. Keys added within version 1 (absent in older
recordings, and absent here except after such a restart):

    # in the recording that was closed:
    [final]
    reason = "acquisition stopped by a read error (OniFailed)"   # also its `stop` event's text

    # in the one that goes on:
    [start]
    first_sample = 0
    continues = "/home/me/dimna-recordings/2026-11-12_14-03-22/ephys"   # the folder before it
    continues_end_sample = 1830000   # that recording's [final] end_sample, in its numbering
    gap_estimate_s = 3.214           # time acquired by neither (estimate, see below)

`reason` is absent after a stop by the user. `gap_estimate_s` is from the host's clock:
from the arrival of the earlier recording's last block to that of this one's first block,
less that block's own duration. Samples are not counted across the gap (the board's sample
counter starts again), so it is an estimate, good to a few milliseconds; it is written at
the clean stop, with `[final]` (an interrupted recording has `continues` and
`continues_end_sample` but not this key). The new recording's `start` event says what it
continues, too. `tools/dimna_read.py` prints both.

Crash safety: once a second `samples.i16` is synced, then the index records for it are written
and synced, so every index record points at data already on disk. After a crash the indexed
data is CRC-verifiable and any tail beyond it is kept but unverified.

`tools/dimna_compare.py A B` compares two recordings of the same headstages (layout, noise
profile, AUX and ADC levels). `tools/usbshim/usbshim.c` is the LD_PRELOAD logger used to learn
the FT600 protocol from D3XX.

`tools/dimna_read.py` is a reference reader (numpy + standard library) and verifier:

    python3 tools/dimna_read.py ~/oez-test/2026-11-11_11-53-24

Use explicit little-endian dtypes (`'<i2'`, `'<i8'`, `'<u2'`) in other readers.

Display features (filters, reference, hidden rows, spike detection, slope trigger, audio) never
change what is recorded. `src/independence_test.zig` (in `zig build test`) records one
deterministic stream with and without all of them running beside the recorder and checks that
both recordings are byte for byte what was generated. `tools/display-independence-test.sh` does
the same through the GUI on the simulator; it opens windows, so never run it during an experiment.

### Testing the recorder

`zig build test` includes `src/record_test.zig`: a producer thread feeds the ring blocks whose
every value is a function of (sample number, channel), and each recording is read back and
checked (every sample, every TTL change, index offsets, CRCs and gap flags, `events.tsv`,
`[final]`, its counts of settings changes against `events.tsv`). It covers a whole stream, attaching to a running stream, stopping while the
producer carries on (and the ring being let go), lost blocks, an injected write failure, and
events from both queues. `tools/crash-test.sh [SECONDS]` records from the simulator, kills
`dimna-headless` with `kill -9` after that many seconds, and checks with `dimna_read.py` that the
indexed part verifies, that the recording is marked interrupted, and that the unverified tail
is under 1.5 s. Neither touches the board. The crash test kills the process only (the page
cache survives), so it says nothing about power loss or a full disk.
