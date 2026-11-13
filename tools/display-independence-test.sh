#!/usr/bin/env bash
# End-to-end check that display features never change what is recorded.
#
#   *** THIS OPENS WINDOWS (the display, the control window and the tile window) for about
#   *** half a minute. DO NOT RUN IT DURING AN EXPERIMENT, or while another dimna is open:
#   *** its windows can land over yours and take clicks. It uses the simulator only
#   *** (--sim), never the board, and plays no sound (--no-audio).
#
# It runs the GUI on the simulator twice, 12 s each, under DIMNA_APP_ID=dimna-test:
#   plain  two panels, nothing else (no tiles window);
#   full   every display feature on: a band, raw_rows, hide, car_ref/car_subtract, a
#          triggered panel with a slope trigger (trigger_channel), a TTL panel, a tint,
#          and the spike tiles.
# Each run clicks Record in the control window 2 s after start (DIMNA_CONTROL_CLICKS) and
# records into its own scratch folder. Then the two recordings are compared over the
# sample numbers they share: every sample of every channel, and the TTL edges.
#
# This works because the simulator is deterministic by sample number within one run:
# fixed seeds (src/sim.zig), one acquisition start, and nothing in either run changes a
# board setting (a restart would carry the generator on and break the comparison).
#
#   tools/display-independence-test.sh          (from anywhere; needs zig-out/bin/dimna)
#   KEEP=1 tools/display-independence-test.sh   keeps the scratch folder afterwards
#
# Exit status 0 if the recordings agree, 1 if not, 2 if the test could not be run.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/zig-out/bin/dimna"
TOOLS="$ROOT/tools"
SECONDS_RUN=12

if [ ! -x "$BIN" ]; then
    echo "no $BIN: build first (zig build --release=safe)"
    exit 2
fi
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    echo "no Wayland session: this needs the desktop (it opens windows)"
    exit 2
fi
# Both names of both programs: oers (now kalila) and oez (now dimna).
if pgrep -x 'oers|kalila|oez|oez-headless|dimna|dimna-headless' > /dev/null; then
    echo "oers, kalila, oez or dimna is running: not starting test windows beside it (it may be recording)."
    exit 2
fi

S="$(mktemp -d "/tmp/dimna-display-independence-$$-XXXX")"
cleanup() {
    if [ "${KEEP:-0}" = 1 ]; then echo "scratch kept: $S"; else rm -rf "$S"; fi
}
trap cleanup EXIT

mkdir -p "$S/plain/cfg/dimna" "$S/full/cfg/dimna" "$S/plain/rec" "$S/full/rec" "$S/plain/state" "$S/full/state"

# --sim 32,16: the simulator puts its headstages in slots A1, A2, ...: A1 has 32 channels
# (0..31), A2 16 (32..47).
cat > "$S/plain/cfg/dimna/config.toml" <<EOF
record_dir = "$S/plain/rec"
tiles = false

[[panel]]
source = "A1"
rect = [0.0, 0.0, 0.5, 1.0]

[[panel]]
source = "A2"
rect = [0.5, 0.0, 0.5, 1.0]
EOF

cat > "$S/full/cfg/dimna/config.toml" <<EOF
record_dir = "$S/full/rec"

[ttl]
line1 = "camera"
line2 = "laser"

[[panel]]
name = "A1"
source = "A1"
rect = [0.0, 0.0, 0.5, 0.85]
band = [300, 6000]
raw_rows = [9, 10, 11, 12]
raw_scale = 2000
hide = [29, 30, 31, 32]
car_ref = [1, 2, 3, 4, 5, 6, 7, 8]
car_subtract = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 13, 14]
tint = 2

[[panel]]
name = "A2"
source = "A2"
rect = [0.5, 0.0, 0.5, 0.85]
band = [10, 0]
car = true
mode = "triggered"
trigger_channel = 3

[[panel]]
source = "ttl"
rect = [0.0, 0.85, 1.0, 0.15]
lines = [1, 2]
EOF

run() {
    local name="$1"
    echo "run '$name': $SECONDS_RUN s, windows open..."
    DIMNA_APP_ID=dimna-test \
    XDG_CONFIG_HOME="$S/$name/cfg" \
    XDG_STATE_HOME="$S/$name/state" \
    DIMNA_CONTROL_CLICKS="2:45,94" \
        "$BIN" --sim 32,16 --no-audio --seconds "$SECONDS_RUN" > "$S/$name/dimna.log" 2>&1
    local rc=$?
    if [ $rc -ne 0 ]; then
        echo "run '$name' exited with $rc; log: $S/$name/dimna.log"
        tail -5 "$S/$name/dimna.log"
        return 1
    fi
}

run plain || { KEEP=1; exit 2; }
run full || { KEEP=1; exit 2; }

# The session layout: <record_dir>/<date_time>/ephys/, with <record_dir>/current pointing at it.
find_rec() {
    local d
    for d in "$1"/current/ephys "$1"/*/ephys; do
        if [ -f "$d/meta.toml" ]; then echo "$d"; return 0; fi
    done
    return 1
}
A="$(find_rec "$S/plain/rec")" || { echo "run 'plain' made no recording (did the Record click at 45,94 miss? see $S/plain/dimna.log)"; KEEP=1; exit 2; }
B="$(find_rec "$S/full/rec")" || { echo "run 'full' made no recording (did the Record click at 45,94 miss? see $S/full/dimna.log)"; KEEP=1; exit 2; }
echo "plain: $A"
echo "full:  $B"

python3 -I - "$TOOLS" "$A" "$B" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
import numpy as np
from dimna_read import Recording

a, b = Recording(sys.argv[2]), Recording(sys.argv[3])
bad = []
for name, r in (("plain", a), ("full", b)):
    problems, tail = r.verify()
    if problems:
        bad.append(f"{name}: {problems[:3]}")
    if not r.complete:
        bad.append(f"{name}: no [final] in meta.toml (not closed cleanly)")
if a.num_channels != b.num_channels:
    bad.append(f"channel counts differ: {a.num_channels} vs {b.num_channels}")
if bad:
    print("FAIL:", *bad, sep="\n  ")
    sys.exit(1)

na, nb = a.sample_numbers(), b.sample_numbers()
shared, ia, ib = np.intersect1d(na, nb, assume_unique=True, return_indices=True)
lo, hi = (int(shared[0]), int(shared[-1]) + 1) if shared.size else (0, 0)
secs = shared.size / a.sample_rate
print(f"plain: samples {int(na[0])}..{int(na[-1]) + 1}; full: {int(nb[0])}..{int(nb[-1]) + 1}; "
      f"shared {shared.size} samples ({secs:.1f} s)")
if secs < 5:
    print("FAIL: less than 5 s in common; the recordings did not overlap enough to say anything")
    sys.exit(1)

sa, sb = a.samples[ia], b.samples[ib]
diff = np.argwhere(sa != sb)
if diff.size:
    row, ch = diff[0]
    print(f"FAIL: {len(diff)} sample values differ; first at sample {int(shared[row])}, "
          f"channel {a.channel_names[ch]}: plain {int(sa[row, ch])}, full {int(sb[row, ch])}")
    bad.append("samples")
else:
    print(f"samples: identical on all {a.num_channels} channels over the shared range")

def word_at(r, s):
    return int(r.ttl_word[np.searchsorted(r.ttl_sample, s, side="right") - 1])

def edges(r):
    keep = (r.ttl_sample > lo) & (r.ttl_sample < hi)
    return r.ttl_sample[keep], r.ttl_word[keep]

ea, eb = edges(a), edges(b)
if word_at(a, lo) != word_at(b, lo):
    print(f"FAIL: TTL word at sample {lo}: plain 0x{word_at(a, lo):x}, full 0x{word_at(b, lo):x}")
    bad.append("ttl start")
if ea[0].size != eb[0].size or np.any(ea[0] != eb[0]) or np.any(ea[1] != eb[1]):
    print(f"FAIL: TTL edges differ in the shared range: {ea[0].size} vs {eb[0].size} edges")
    bad.append("ttl edges")
else:
    print(f"TTL: the same {ea[0].size} edges in the shared range")
if ea[0].size == 0:
    print("FAIL: no TTL edges in the shared range (the simulator pulses line 1 every second)")
    bad.append("no ttl")

if bad:
    sys.exit(1)
print("PASS: the display features left the recording unchanged")
EOF
status=$?
[ $status -ne 0 ] && KEEP=1
exit $status
