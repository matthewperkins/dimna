#!/usr/bin/env bash
# Console test of dimna driving a monitor itself (no compositor).
#
# Run it from a text console, not from the desktop:
#   1. Ctrl+Alt+F3, log in.
#   2. ~/oEZ/oez/tools/direct-test.sh            (simulated signals, about a minute)
#      ~/oEZ/oez/tools/direct-test.sh --board    (also a run on the acquisition board)
#   3. Ctrl+Alt+F1 (or F2: whichever your desktop is on) to go back.
#
# It draws traces on the monitor for 10 s at each of several margins (how long before a
# refresh a frame is drawn) and prints one summary line per run. Logs: ~/oez-test/logs/.
# Ctrl+C stops it; the console comes back by itself.
set -u
MON="${DIMNA_DIRECT_MONITOR:-DP-2}"
BIN="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/dimna"
LOGS="$HOME/oez-test/logs"
mkdir -p "$LOGS"

if [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; then
    echo "This is a desktop session: the compositor is driving $MON, so dimna cannot take it."
    echo "Switch to a text console first (Ctrl+Alt+F3), log in, and run this again."
    exit 1
fi

echo "dimna direct display test on $MON. Each run is 10 s; watch $MON."
for m in 3 2 1.5 1 0.5 0.25; do
    "$BIN" --direct "$MON" --sim 32,16 --seconds 10 --margin-ms "$m" > "$LOGS/direct_m$m.log" 2>&1
    rc=$?
    line=$(grep "direct on" "$LOGS/direct_m$m.log" | sed 's/.*direct on/direct on/')
    if [ -n "$line" ]; then echo "$line"; else echo "margin $m ms: FAILED (exit $rc): $(grep -E 'error' "$LOGS/direct_m$m.log" | head -2 | tr '\n' ' ')"; fi
    [ $rc -ne 0 ] && [ -z "$line" ] && break
done

if [ "${1:-}" = "--board" ]; then
    # Both names of both programs: oers (now kalila) and oez (now dimna). -x for these
    # four, since -f would match any command line with a path in this checkout (~/oEZ/oez).
    if pgrep -f 'oers|kalila|open-ephys' > /dev/null || pgrep -x 'oez|oez-headless|dimna|dimna-headless' > /dev/null; then
        echo "oers, kalila, oez, dimna or the Open Ephys GUI is running and holds the board: skipping the board run."
    else
        echo "Board run (16-ch mode on A1), 20 s..."
        "$BIN" --direct "$MON" --16ch A1 --seconds 20 --margin-ms 1.5 > "$LOGS/direct_board.log" 2>&1
        grep "direct on" "$LOGS/direct_board.log" | sed 's/.*direct on/board: direct on/' || grep -E "error" "$LOGS/direct_board.log" | head -3
    fi
fi
echo "Done. Logs are in $LOGS (direct_m*.log). Switch back to the desktop with Ctrl+Alt+F${DIMNA_DESKTOP_VT:-1}."
