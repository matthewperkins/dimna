#!/bin/sh
# Launcher used by oez.desktop: runs the built program and keeps its log, since a desktop
# launch has no terminal. Output is appended to ${XDG_STATE_HOME:-~/.local/state}/oez/oez.log.
# The program reads its settings from ${XDG_CONFIG_HOME:-~/.config}/oez/config.toml.
# Build first: zig build --release=safe
root=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
state=${XDG_STATE_HOME:-$HOME/.local/state}/oez
mkdir -p "$state"
echo "=== $(date '+%F %T') oez $*" >>"$state/oez.log"
exec "$root/zig-out/bin/oez" "$@" >>"$state/oez.log" 2>&1
