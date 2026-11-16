#!/bin/sh
# Builds metal_latency and runs it once per mode, one result line each.
# It opens windows and takes over the main screen for the fullscreen modes; Esc stops a run.
# usage: run-all.sh [SECONDS_PER_MODE]     (default 4)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${OUT:-$(mktemp -d)}
secs=${1:-4}
clang -fobjc-arc -O2 "$here/metal_latency.m" -framework Cocoa -framework Metal \
    -framework QuartzCore -o "$out/metal_latency"

run() { "$out/metal_latency" --seconds "$secs" "$@" 2>/dev/null || echo "FAILED or stopped: $*"; }

for where in "" "--fullscreen"; do
    run $where --sync on  --pace block
    run $where --sync on  --pace block --drawables 3
    run $where --sync on  --pace margin:2
    run $where --sync on  --pace margin:4
    run $where --sync on  --pace margin:8
    run $where --sync off --pace block
    run $where --sync off --pace free:3
    run $where --sync off --pace free:1
done
