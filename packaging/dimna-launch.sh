#!/bin/sh
# Launcher used by dimna.desktop: runs the built program and keeps its log, since a desktop
# launch has no terminal. Output is appended to ${XDG_STATE_HOME:-~/.local/state}/dimna/dimna.log.
# The program reads its settings from ${XDG_CONFIG_HOME:-~/.config}/dimna/config.toml.
# Build first: zig build --release=safe
root=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
state=${XDG_STATE_HOME:-$HOME/.local/state}/dimna
mkdir -p "$state"
echo "=== $(date '+%F %T') dimna $*" >>"$state/dimna.log"
exec "$root/zig-out/bin/dimna" "$@" >>"$state/dimna.log" 2>&1
